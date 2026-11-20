#!/bin/bash
# test-sky1-mali-only-74.sh -- the 7.4 Sky1 kernel line is MALI ONLY (operator
# 2026-11-16: "release will use 7.4 kernel, no edge and 7.3 will be retired";
# the r303 7.4.0-rc3 build is Mali only, CONFIG_DRM_PANTHOR off, no panthor
# module or package).
#
# Every assertion below is made against the COMMITTED pins and asset trees, so
# it fails closed for any future arm64 pin that re-introduces Panthor (a config
# that enables CONFIG_DRM_PANTHOR, a panthor module/firmware package in the
# image payload, or a staged panthor.ko for the pinned kver), and it fails if
# the vendor Mali stack (mali_kbase + the Mali userspace) disappears.
#
# It does NOT touch the Mali userspace itself: it only asserts the pins.
set -u
cd "$(dirname "$0")/.."
fail=0; bad() { echo "FAIL: $*"; fail=1; }; ok() { echo "ok:   $*"; }

DK=assets/kernel/default-kernel.json
KVER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["arm64"]["kver"])' "$DK")
PKG=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["arm64"]["pkgversion"])' "$DK")
MKVER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["variants"]["mainline"]["kver"])' assets/kernel-manifest.json)
SKVER=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kver"])' assets/kernel/sky1-manifest.json)

case "$KVER" in
    7.4.*) ok "arm64 pin is the 7.4 line ($KVER)" ;;
    *) bad "arm64 pin '$KVER' is not the 7.4 line" ;;
esac
[ "$MKVER" = "$KVER" ] && ok "kernel-manifest variants.mainline.kver == $KVER" || bad "kernel-manifest mainline kver '$MKVER' != '$KVER'"
[ "$SKVER" = "$KVER" ] && ok "sky1-manifest kver == $KVER" || bad "sky1-manifest kver '$SKVER' != '$KVER'"

# 1. No panthor module is staged for the pinned kver, and the ACTUAL built
#    kernel artifacts carry none either. The overlay mirror is checked (a
#    panthor.ko there is direct evidence the tree builds Panthor), and when the
#    r303 build is present on the host its linux-image deb and modules tarball
#    are inspected too -- those are the authoritative build outputs, so the
#    check cannot pass vacuously on a missing overlay directory alone.
PANTHOR_HITS=""
if compgen -G "assets/kernel/panthor/$KVER/*.ko" >/dev/null 2>&1; then
    PANTHOR_HITS="overlay: $(ls assets/kernel/panthor/"$KVER"/*.ko | tr '\n' ' ')"
fi
SK_STAGING=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("staging_dir",""))' assets/kernel/sky1-manifest.json)
# staging_dir is committed, but it is interpolated into a filesystem path, so
# refuse anything with a parent component, a leading '/', or a component outside the
# pool naming alphabet (kernel-staging/<build>/). Fail closed rather than read
# outside the pool if the manifest is ever wrong.
case "$SK_STAGING" in
    ""|/*|*..*) bad "sky1-manifest staging_dir '$SK_STAGING' is not a safe relative path"; SK_STAGING="";;
    *[!A-Za-z0-9._/-]*) bad "sky1-manifest staging_dir '$SK_STAGING' has disallowed characters"; SK_STAGING="";;
esac
STAGE_POOL="${NCZ_KERNEL_POOL_ROOT:-$PWD/downloads}/$SK_STAGING"
ARTIFACTS_CHECKED=0
if [ -d "$STAGE_POOL" ]; then
    # Match the exact pinned package version, not "the first deb": the pool can
    # hold more than one revision and the wrong one would give a false pass.
    deb=$(ls "$STAGE_POOL"/debs/linux-image-*_"${PKG}"_*.deb 2>/dev/null | head -1)
    if [ -n "$deb" ] && command -v dpkg-deb >/dev/null 2>&1; then
        ARTIFACTS_CHECKED=$((ARTIFACTS_CHECKED+1))
        gotver=$(dpkg-deb -f "$deb" Version 2>/dev/null)
        if [ "$gotver" != "$PKG" ]; then
            bad "staged deb $(basename "$deb") Version '$gotver' != pinned pkgversion '$PKG'"
        fi
        if dpkg-deb -c "$deb" 2>/dev/null | grep -qi panthor; then
            PANTHOR_HITS="$PANTHOR_HITS deb($(basename "$deb")) has panthor"
        fi
    fi
    tgz=$(ls "$STAGE_POOL"/modules-*.tgz 2>/dev/null | head -1)
    if [ -n "$tgz" ]; then
        ARTIFACTS_CHECKED=$((ARTIFACTS_CHECKED+1))
        if tar tzf "$tgz" 2>/dev/null | grep -qi panthor; then
            PANTHOR_HITS="$PANTHOR_HITS modules-tgz has panthor"
        fi
    fi
fi
if [ -n "$PANTHOR_HITS" ]; then
    bad "panthor present for the 7.4 pin:$PANTHOR_HITS"
elif [ "$ARTIFACTS_CHECKED" -gt 0 ]; then
    ok "no panthor module: overlay clean and $ARTIFACTS_CHECKED real build artifact(s) (deb + modules tgz) carry none"
else
    ok "no panthor .ko staged for $KVER (staging pool not mounted; overlay + manifest checks only)"
fi

# 2. The pinned Sky1 config must not enable CONFIG_DRM_PANTHOR. The config is
#    recorded by sha256 in the manifest; the reference is asserted to be the
#    7.4 config, and any staged copy on the build host is grepped when present.
CFGREF=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["identity"]["config_reference"])' assets/kernel/sky1-manifest.json)
# The staging dir is recorded in the manifest (kernel-staging/<build>), so the
# host grep targets the SAME tree the manifest was captured from instead of a
# guessed name (SK_STAGING is resolved once, in section 1).
case "$CFGREF" in
    config-"$KVER"*) ok "manifest config_reference names the $KVER config" ;;
    *) bad "manifest config_reference '$CFGREF' is not the $KVER config" ;;
esac
CFG_CHECKED=0
for cand in "assets/kernel/mainline/config-$KVER" \
            "$STAGE_POOL/config-$KVER"; do
    [ "$(basename "$cand")" = "config-$KVER" ] || continue
    [ -s "$cand" ] || continue
    CFG_CHECKED=$((CFG_CHECKED+1))
    if grep -q '^CONFIG_DRM_PANTHOR=y' "$cand" || grep -q '^CONFIG_DRM_PANTHOR=m' "$cand"; then
        bad "$cand enables CONFIG_DRM_PANTHOR (Sky1 is Mali only)"
    else
        ok "$cand does not enable CONFIG_DRM_PANTHOR"
    fi
done
# The manifest's config_reference is the committed proof; a host copy is only
# present when the staging pool is mounted, so requiring one would make this
# test fail on a developer checkout. Assert the committed reference is present
# (checked above) and, when the pool IS mounted, that a config was really read.
if [ -d "$STAGE_POOL" ] && [ "$CFG_CHECKED" -eq 0 ]; then
    bad "staging dir $STAGE_POOL is mounted but no config-$KVER was found to check"
elif [ "$CFG_CHECKED" -gt 0 ]; then
    ok "CONFIG_DRM_PANTHOR checked against $CFG_CHECKED staged config file(s)"
fi

# 3. No panthor package in the image payload lists or the reviewed ledger.
for f in manifests/ncz-packages.tsv manifests/components.tsv manifests/desktop.pkgs \
         manifests/install-extra.pkgs manifests/server.pkgs; do
    [ -f "$f" ] || continue
    # Match only a package whose NAME (first TSV field, or the whole line for
    # .pkgs lists) is a panthor driver/firmware package. A substring mention
    # ('some-panthor-package') or prose note is not a panthor package.
    if awk -F'\t' '
        { name = (NF > 1 ? $1 : $0); sub(/^[[:space:]]+/, "", name); sub(/[[:space:]].*$/, "", name) }
        name ~ /^panthor(-|$)/ || name == "panthor-cix" || name == "panthor-firmware" || name == "linux-panthor" { found = 1 }
        END { exit !found }
    ' "$f"; then
        bad "$f names a panthor package/module"
    else
        ok "$f has no panthor entry"
    fi
done

# 4. The Mali stack is REQUIRED at the pinned kver: mali_kbase.ko must be
#    mirrored for $KVER and the Mali userspace packages must be listed.
for ko in mali_kbase.ko memory_group_manager.ko protected_memory_allocator.ko; do
    [ -s "assets/kernel/mali/$KVER/$ko" ] && ok "mali overlay $ko staged for $KVER" || bad "mali overlay $ko missing for $KVER"
done
# The Mali userspace ships as the vendor cix-gpu-umd deb (libmali + its OpenCL
# ICD), registered in the component registry for every arm64 variant.
grep -qP '^cix-gpu-umd\t' manifests/components.tsv \
    && ok "components registry carries the Mali userspace (cix-gpu-umd)" || bad "components registry lacks cix-gpu-umd"
awk -F'\t' '$1=="cix-gpu-umd" && $4=="arm64" && $5 ~ /desktop/ && $5 ~ /server/ {found=1} END{exit !found}' manifests/components.tsv \
    && ok "cix-gpu-umd is arm64 + desktop + server" || bad "cix-gpu-umd is not registered for arm64 desktop and server"
grep -q '^ocl-icd-libopencl1$' manifests/desktop.pkgs && ok "desktop lists ocl-icd-libopencl1 (Mali OpenCL runtime)" || bad "desktop lacks ocl-icd-libopencl1"

# 5. The arm64 rEFInd generator never emits a Panthor entry. The 2026-11-16 Mali-only order removed
#    the entry at the source (the PANTHOR_ENTRY flag and probe are gone, marked NCZ-PANTHOR-ENTRY-REMOVED);
#    build/test-no-panthor-boot.sh proves the behaviour, this re-asserts the mechanism for the 7.4 line.
if grep -q 'NCZ-PANTHOR-ENTRY-REMOVED' assets/refind/ncz-refind-refresh.sh \
   && ! grep -q -E '^[[:space:]]*PANTHOR_ENTRY=1' assets/refind/ncz-refind-refresh.sh \
   && ! grep -q 'ncz_panthor_module_present()' assets/refind/ncz-refind-refresh.sh; then
    ok "arm64 generator has the Panthor entry removed at the source"
else
    bad "arm64 generator still carries a Panthor entry path"
fi

# 6. The ledger rows for the pinned kernel are the 7.4 package versions, and no
#    7.3.x kernel package remains in the image payload lists.
grep -qP "^linux-image-cixmini\t\Q$PKG\E\tarm64" manifests/ncz-packages.tsv \
    && ok "ledger linux-image-cixmini == $PKG" || bad "ledger linux-image-cixmini is not $PKG"
if grep -qP '^linux-(image|headers)-(cixmini|[0-9][^\t]*)\t7\.3\.' manifests/ncz-packages.tsv; then
    bad "ledger still carries a 7.3.x kernel package row"
else
    ok "ledger carries no 7.3.x kernel package row"
fi

exit $fail
