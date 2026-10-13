#!/bin/bash
# Stage a built kernel into its own dated asset dir, repoint a channel pointer
# (assets/kernel/mainline for 7.2.x, assets/kernel/edge for test-only 7.3.x),
# run the mandatory gates, and package. Idempotent: safe to re-run.
#
# Notes that cost time to learn, kept so the next run does not relearn them:
#  - assets/kernel/{mainline,edge} are SYMLINKS to dated dirs. r262 gets its OWN dir so
#    r261 remains intact and rollback is a symlink flip.
#  - r262's patches are all in drivers/gpu/drm/cix/*, which build as MODULES
#    (linlon-dp, trilin-dpsub), NOT into vmlinuz. With SOURCE_DATE_EPOCH pinned
#    an identical Image is the CORRECT result; the staleness check therefore
#    looks at the modules, and only fails if nothing shipped changed.
#  - modules live at image/usr/lib/modules (usr-merged) but the tarball must
#    contain lib/modules/... paths, so tar runs from image/usr.
#  - dkms-abi-gate takes a headers DIRECTORY, not the tarball.
set -euo pipefail
# REPO is overridable via NCZ_INSTALLER_DIR, matching release-kernel.sh's
# convention (release-kernel.sh sets this when it calls stage-kernel.sh).
# The historical default stays ~/isobuild/cix-installer so an interactive
# invocation behaves identically. Without this env var, release-kernel.sh
# running against an installer at e.g. ~/kernel-port-v726 (the dispatch
# host's actual checkout) would silently stage against ~/isobuild/cix-installer
# instead -- measured 2026-09-22 on the arm64 build host: step 4 wrote the staged kernel to
# ~/isobuild/cix-installer/assets/kernel/r275-7.3.0-rc3-... even though the
# caller passed NCZ_INSTALLER_DIR=~/kernel-port-v726.
REPO="${NCZ_INSTALLER_DIR:-$HOME/isobuild/cix-installer}"
# Where dated release dirs actually get written. Defaults to the historical
# local location (unchanged behavior). Set NCZ_KERNEL_STAGING_ROOT to a path
# under the shared yocto-shared export (<NCZ_YOCTO_SHARED_DIR>/kernel-staging,
# whose mount point differs per build host -- same NFS
# export, both hosts also expose it at /nfs-shared via a compat symlink so a
# checked-in edge symlink resolves identically regardless of which host built
# it) so a kernel built on one host is immediately usable by mkosi/image work on
# another, without a manual copy step.
STAGING_ROOT="${NCZ_KERNEL_STAGING_ROOT:-$REPO/assets/kernel}"
# Which channel pointer this staging run repoints. The class is checked
# against the KVER below: a -rc kernel may only be staged as edge and a
# release kernel only as mainline, so a test kernel can never silently
# become the shipping one again (2026-09-28: staging r278 rc5 repointed the
# single shipping pointer; b63676d9 had to revert it by hand).
CHANNEL="${NCZ_KERNEL_CHANNEL:-mainline}"
case "$CHANNEL" in mainline|edge) ;; *) echo "FAIL: NCZ_KERNEL_CHANNEL=$CHANNEL (want mainline or edge)"; exit 1 ;; esac
POINTER="$REPO/assets/kernel/$CHANNEL"
mkdir -p "$STAGING_ROOT"
# Derive the work dir from what was actually built instead of hardcoding a PV.
# A version bump (7.2+ncz -> 7.2.3+ncz) otherwise silently stages the PREVIOUS
# build directory, which still exists and still looks valid.
W=${NCZ_KERNEL_WORKDIR:-$(ls -dt ~/ybuild/tmp/work/cixmini-nclawzero-linux/linux-cix-sky1-ncz/*+ncz 2>/dev/null | head -1)}
[ -n "$W" ] && [ -d "$W" ] || { echo "FAIL: no kernel work dir found"; exit 1; }
REV=${BUILD_REV:?set BUILD_REV, e.g. BUILD_REV=r263}
STAMP=$(date +%Y%m%d)
KVER=$(ls "$W/image/usr/lib/modules" 2>/dev/null | head -1)
[ -n "$KVER" ] || { echo "FAIL: cannot determine KVER"; exit 1; }
case "$CHANNEL:$KVER" in
    mainline:*-rc[0-9]*) echo "FAIL: $KVER is a prerelease; stage it with NCZ_KERNEL_CHANNEL=edge"; exit 1 ;;
    edge:*-rc[0-9]*) ;;
    edge:*) echo "FAIL: $KVER is not a prerelease; the edge channel is 7.3.x -rc test kernels only"; exit 1 ;;
esac
DEST=$STAGING_ROOT/${REV}-${KVER}-${STAMP}
# Compare against the previous RELEASE, not against whatever the channel
# pointer currently points at. A re-run of this same REV has already repointed
# it at its own dir, so comparing to it compares the build against ITSELF and the staleness
# guard then reports "cached output reused" for a perfectly fresh build.
PREV=$(readlink -f "$POINTER" 2>/dev/null || true)
case "${PREV:+$(basename "$PREV")}" in
    "${REV}-"*)
        echo "note: $CHANNEL already points at a ${REV} staging ($(basename "$PREV")) -- re-run."
        # grep -v exits 1 when EVERY staged dir belongs to this REV (a
        # genuinely first build on a host with no prior release staged) --
        # under set -e that failure propagates through the command
        # substitution and killed the whole script silently right here.
        # || true lets a real "no previous release yet" case leave PREV
        # empty instead of crashing.
        PREV=$(ls -dt "$STAGING_ROOT"/*-sky1-ncz-* 2>/dev/null | grep -v "/${REV}-" | head -1 || true)
        echo "      comparing against the release before it: ${PREV:-<none>}"
        ;;
esac
echo "KVER=$KVER  channel=$CHANNEL  dest=$DEST  previous=$PREV"

IMG=$(find "$W" -name Image -path "*arch/arm64/boot*" | head -1)
[ -n "$IMG" ] || { echo "FAIL: no Image built"; exit 1; }

# --- staleness: compare what these patches actually touch -------------------
MOD_CHANGED=0
if [ -f "$PREV/modules-cixmini.tgz" ]; then
    rm -rf /tmp/.prevmod && mkdir -p /tmp/.prevmod
    tar -xzf "$PREV/modules-cixmini.tgz" -C /tmp/.prevmod 2>/dev/null || true
    for m in linlon-dp trilin-dpsub; do
        n=$(find "$W/image" -name "$m.ko*" | head -1); o=$(find /tmp/.prevmod -name "$m.ko*" | head -1)
        [ -n "$n" ] && [ -n "$o" ] || continue
        nm=$(xz -dcf "$n" | md5sum | cut -d' ' -f1); om=$(xz -dcf "$o" | md5sum | cut -d' ' -f1)
        [ "$nm" != "$om" ] && { echo "module $m CHANGED"; MOD_CHANGED=1; } || echo "module $m unchanged"
    done
else
    MOD_CHANGED=1
fi
IMG_MD5=$(md5sum "$IMG" | cut -d' ' -f1)
PREV_IMG_MD5=$(md5sum "$PREV/Image-cixmini.bin" 2>/dev/null | cut -d' ' -f1 || echo "")
[ "$IMG_MD5" = "$PREV_IMG_MD5" ] && echo "note: vmlinuz identical to previous release (expected: module-only change)"
if [ "$IMG_MD5" = "$PREV_IMG_MD5" ] && [ "$MOD_CHANGED" = 0 ]; then
    echo "FAIL: neither vmlinuz nor the display modules changed. Cached output reused."; exit 1
fi

# --- stage every asset together, unconditionally ----------------------------
mkdir -p "$DEST"
cp -f "$IMG" "$DEST/Image-cixmini.bin"
printf '%s' "$KVER" > "$DEST/KVER"
CFG=$(find "$W" -name .config -path "*build*" | head -1); [ -n "$CFG" ] && cp -f "$CFG" "$DEST/config-$KVER"
tar -C "$W/image/usr" -czf "$DEST/modules-cixmini.tgz" "lib/modules/$KVER"
"$REPO/build/extract-kernel-headers.sh" --kernel-src "$W/kernel-source" \
    --build-dir "$W/build" --kver "$KVER" --output "$DEST/headers-cixmini.tar.zst"

# dkms-abi-gate wants a DIRECTORY of staged headers
HDRDIR=$DEST/headers-dir
rm -rf "$HDRDIR" && mkdir -p "$HDRDIR"
tar -I zstd -xf "$DEST/headers-cixmini.tar.zst" -C "$HDRDIR"

# A relative symlink only works when DEST is a sibling of the pointer (the old,
# local-default layout). Once staging moves to the shared root, pointer and DEST
# are in different directories entirely, so it must be absolute there -- but
# an absolute symlink in the local-default case would tie assets/kernel/$CHANNEL
# (a checked-in file) to one machine's home-directory path, breaking on any
# other clone. Keep the old relative form exactly when nothing opted in.
if [ "$STAGING_ROOT" = "$REPO/assets/kernel" ]; then
    ln -sfn "$(basename "$DEST")" "$POINTER"
else
    ln -sfn "$DEST" "$POINTER"
fi
echo "=== staged:"; ls -la "$DEST" | head -8

echo "=== GATE 1: KVM boot + PCI collision lint"
"$REPO/build/kvm-kernel-gate.sh" "$DEST/Image-cixmini.bin" "$DEST/config-$KVER"
echo "=== GATE 2: dkms ABI"
"$REPO/build/dkms-abi-gate.sh" "$DEST/Image-cixmini.bin" "$HDRDIR/lib/modules/$KVER/build" --config "$DEST/config-$KVER"
# release-kernel.sh does packaging itself, in a Debian container, because this
# host may have no dpkg-deb. Skip it here rather than failing the whole staging
# run after the gates have already passed.
if [ "$CHANNEL" = edge ]; then
    echo "=== packaging: SKIPPED (edge is test-only; build-kernel-debs.sh packages mainline only)"
elif [ "${NCZ_SKIP_PACKAGING:-0}" = 1 ]; then
    echo "=== packaging: SKIPPED (NCZ_SKIP_PACKAGING=1; caller packages)"
else
    echo "=== packaging as $REV"
    cd "$REPO" && BUILD_REV="$REV" build/build-kernel-debs.sh
fi
[ "$CHANNEL" = edge ] || ls -la "$REPO/build/kernel-debs/" | tail -4
