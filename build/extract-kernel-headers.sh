#!/usr/bin/env bash
# extract-kernel-headers.sh — produce kernel-headers asset for one of LTS/NEXT
#
# r75 task #66: DKMS (NPU/GPU drivers) requires linux-headers-$KVER on the
# target. Cix's build-kernel.sh (`bindeb-pkg`) already produces a
# linux-headers-*.deb but the cix-installer pipeline never captured it.
#
# This script:
#   1. takes a built kernel source tree + KVER
#   2. produces an unprivileged tarball containing `lib/modules/$KVER/build/`
#      with the build infra DKMS needs (Makefile, scripts/, include/,
#      arch/<a>/include/, .config, Module.symvers, tools/objtool if present)
#   3. writes the tarball to assets/kernel/<lts|next>/headers-cixmini.tar.zst
#
# Why a tarball rather than the bindeb-pkg .deb:
#   - Matches the existing modules-cixmini.tgz pattern (10-our-kernel.sh
#     already does tar-extract into /usr; one more tar is trivial)
#   - .deb name embeds version + revision which drift between rebuilds
#   - Avoids the `dpkg -i` post-install failure modes if Apt sources lock
#   - Smaller (zstd vs gzip; ~25% smaller for typical header trees)
#
# Usage:
#   extract-kernel-headers.sh --kernel-src /path/to/cixmini-msr1-src/linux \
#                              --kver 7.2.0-sky1-ncz \
#                              --output assets/kernel/edge/headers-cixmini.tar.zst
set -euo pipefail

KSRC=""
KBUILD=""
KVER=""
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --kernel-src) KSRC="$2"; shift 2 ;;
        --build-dir)  KBUILD="$2"; shift 2 ;;
        --kver)       KVER="$2"; shift 2 ;;
        --output)     OUT="$2";  shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Split (O=) builds. Yocto's kernel.bbclass always builds out-of-tree: the
# recipe work dir holds kernel-source/ (S) and build/ (B). The generated
# headers, .config, Module.symvers and the COMPILED scripts/ host tools live in
# B; the header sources and the real top-level Makefile live in S. Neither dir
# alone produces a usable /lib/modules/$KVER/build, which is why running this
# script against B failed with "post-stage scripts/ Makefiles missing"
# (2026-08-02, first time it was ever run -- it had no caller before then).
#
# With --build-dir we stage S first and then OVERLAY B, so generated content
# wins, and we deliberately keep S's top-level Makefile: B's is a 328-byte stub
# that redirects to the absolute source path, which does not exist on target.
# The result is a single self-contained tree where objtree == srctree, the same
# shape Debian's linux-headers packages ship.
[ -d "$KSRC" ]    || { echo "ERROR: --kernel-src not a dir: $KSRC" >&2; exit 1; }
[ -n "$KVER" ]    || { echo "ERROR: --kver required" >&2; exit 1; }
[ -n "$OUT" ]     || { echo "ERROR: --output required" >&2; exit 1; }
if [ -n "$KBUILD" ]; then
    [ -d "$KBUILD" ] || { echo "ERROR: --build-dir not a dir: $KBUILD" >&2; exit 1; }
else
    KBUILD="$KSRC"
fi
[ -f "$KSRC/Makefile" ]         || { echo "ERROR: $KSRC/Makefile missing" >&2; exit 1; }
[ -f "$KBUILD/Module.symvers" ] || { echo "ERROR: $KBUILD/Module.symvers missing — kernel not yet built?" >&2; exit 1; }
[ -f "$KBUILD/.config" ]        || { echo "ERROR: $KBUILD/.config missing — kernel not configured?" >&2; exit 1; }

for t in zstd tar find rsync; do
    command -v "$t" >/dev/null 2>&1 || { echo "ERROR: missing tool: $t" >&2; exit 1; }
done

ARCH="${ARCH:-arm64}"
STAGE=$(mktemp -d -t cix-headers-XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

ROOT="$STAGE/lib/modules/$KVER/build"
mkdir -p "$ROOT/arch/$ARCH"

if [ "$KBUILD" = "$KSRC" ]; then
    echo "[extract] $KVER from $KSRC ($ARCH, in-tree build)"
else
    echo "[extract] $KVER ($ARCH, split build)"
    echo "[extract]   source: $KSRC"
    echo "[extract]   build : $KBUILD"
fi

# Header sources come from the SOURCE tree; every generated artefact is
# overlaid from the BUILD tree afterwards. Run each rsync twice (src, then
# build) so the generated copy always wins.
stage_pair() {   # <relative subdir> <rsync filter args...>
    local sub="$1"; shift
    [ -d "$KSRC/$sub" ] && { mkdir -p "$ROOT/$sub"; rsync -a "$@" "$KSRC/$sub/" "$ROOT/$sub/"; }
    [ -d "$KBUILD/$sub" ] && [ "$KBUILD" != "$KSRC" ] && \
        { mkdir -p "$ROOT/$sub"; rsync -a "$@" "$KBUILD/$sub/" "$ROOT/$sub/"; }
    return 0
}

# Top-level files DKMS Module.builder reads. The Makefile MUST come from the
# source tree (a split build dir holds only a redirect stub pointing at an
# absolute path that does not exist on the target); everything else is a build
# product and must come from the build dir.
[ -e "$KSRC/Makefile" ] && cp -a "$KSRC/Makefile" "$ROOT/Makefile"
for f in Kbuild Kconfig; do
    [ -e "$KSRC/$f" ] && cp -a "$KSRC/$f" "$ROOT/$f"
done
for f in .config Module.symvers System.map Kbuild; do
    [ -e "$KBUILD/$f" ] && cp -a "$KBUILD/$f" "$ROOT/$f"
done

# EVERY Makefile/Kbuild/Kconfig in the tree. Kbuild descends through these for
# an `M=` build: without arch/$ARCH/Makefile the build dies immediately with
# "No rule to make target .../arch/arm64/Makefile" (caught 2026-08-02 by the
# module-build smoke test -- the old pattern list only staged
# arch/$ARCH/include and arch/$ARCH/tools). This mirrors what Debian's
# linux-headers packages ship. It is a few thousand small text files.
echo "[extract] staging build-system Makefiles/Kbuild/Kconfig from source"
( cd "$KSRC" && find . \( -name Makefile -o -name 'Makefile.*' -o -name Kbuild \
    -o -name 'Kbuild.*' -o -name 'Kconfig*' \) -type f -print0 ) \
    | ( cd "$KSRC" && rsync -a --files-from=- --from0 . "$ROOT/" )

stage_pair include --include='*/' \
    --include='Makefile' --include='Kbuild' --include='Kconfig*' \
    --include='*.h' --include='*.S' --include='*.s' \
    --include='*.lds' --include='*.lds.S' \
    --include='*.sh' --include='*.pl' --include='*.py' \
    --include='*.c' \
    --exclude='*'

stage_pair "arch/$ARCH/include" --include='*/' \
    --include='Makefile' --include='Kbuild' --include='Kconfig*' \
    --include='*.h' --include='*.S' --include='*.s' \
    --include='*.lds' --include='*.lds.S' \
    --include='*.sh' --include='*.pl' \
    --exclude='*'

# scripts/ — compiled scripts (mod, basic, kconfig binaries) used by DKMS
mkdir -p "$ROOT/scripts"
stage_pair scripts \
    --exclude='*.o' \
    --exclude='*.cmd' \
    --exclude='*.tmp' \
    --exclude='.tmp_versions/'

# arch-specific tools
stage_pair "arch/$ARCH/tools" --exclude='*.o' --exclude='*.cmd' --exclude='*.tmp'

# Generated content from the BUILD tree, copied WHOLESALE rather than through
# the extension filters above. include/config/ holds kernel.release, auto.conf
# and the per-symbol stamps, and include/generated/ holds autoconf.h and the
# vdso/asm-offsets output -- none of which match a *.h/*.c pattern list, so the
# filtered copy silently dropped them (caught 2026-08-02: kernel.release was
# absent from the first tarball).
if [ "$KBUILD" != "$KSRC" ]; then
    echo "[extract] overlaying generated headers from the build dir"
    for sub in include/config include/generated "arch/$ARCH/include/generated"; do
        [ -d "$KBUILD/$sub" ] || continue
        mkdir -p "$ROOT/$sub"
        rsync -a --exclude='*.o' --exclude='*.cmd' "$KBUILD/$sub/" "$ROOT/$sub/"
    done
    # arm64 links modules against a generated linker script.
    for lds in "arch/$ARCH/kernel/module.lds" "arch/$ARCH/kernel/vmlinux.lds"; do
        [ -f "$KBUILD/$lds" ] || continue
        mkdir -p "$ROOT/$(dirname "$lds")"
        cp -a "$KBUILD/$lds" "$ROOT/$lds"
    done
fi

# Sources the TARGET needs to rebuild host tools with `make modules_prepare`.
# Without these the rebuild dies before it can produce modpost:
#   scripts/selinux/mdp   -> needs security/selinux/include/classmap.h
#   include/generated/timeconst.h -> needs kernel/time/timeconst.bc
# Measured on O6N 2026-08-17 while porting to 7.2 final.
for extra in security/selinux/include kernel/time/timeconst.bc; do
    [ -e "$KSRC/$extra" ] || continue
    mkdir -p "$ROOT/$(dirname "$extra")"
    rsync -a "$KSRC/$extra" "$ROOT/$(dirname "$extra")/"
done

# tools/objtool (kernel >=4.20 needs this for some .ko builds)
if [ -d "$KSRC/tools/objtool" ]; then
    mkdir -p "$ROOT/tools"
    rsync -a "$KSRC/tools/" "$ROOT/tools/" \
        --include='objtool/***' \
        --include='build/***' \
        --include='include/***' \
        --include='Makefile*' \
        --include='lib/***' \
        --exclude='*'
fi

# /lib/modules/$KVER/source symlink isn't needed for DKMS rebuild; skip.
# /lib/modules/$KVER/build is the canonical target.

# Symlink build → ../../usr/src/linux-headers-$KVER pattern is what apt's
# linux-headers .deb does. We don't replicate that; DKMS reads
# /lib/modules/$KVER/build directly.

# Sanity: did we capture the basics?
[ -f "$ROOT/Makefile" ]                   || { echo "ERROR: post-stage Makefile missing" >&2; exit 1; }
[ -f "$ROOT/.config" ]                    || { echo "ERROR: post-stage .config missing" >&2; exit 1; }
[ -f "$ROOT/Module.symvers" ]             || { echo "ERROR: post-stage Module.symvers missing" >&2; exit 1; }
[ -f "$ROOT/scripts/Makefile" ] \
    || [ -f "$ROOT/scripts/Makefile.build" ] \
    || { echo "ERROR: post-stage scripts/ Makefiles missing" >&2; exit 1; }
# Generated headers only exist after a real build; their absence means we
# staged a source tree that was never compiled, which DKMS cannot use.
[ -f "$ROOT/include/generated/autoconf.h" ] \
    || { echo "ERROR: post-stage include/generated/autoconf.h missing — build dir not staged?" >&2; exit 1; }
[ -d "$ROOT/include/config" ] \
    || { echo "ERROR: post-stage include/config/ missing — build dir not staged?" >&2; exit 1; }
# A split build dir ships a stub Makefile that redirects to an absolute source
# path; if that leaked through, every on-target DKMS build would fail.
if grep -q 'Makefile.*: no such file\|^# Automatically generated by' "$ROOT/Makefile" 2>/dev/null \
   && ! grep -qE '^VERSION[[:space:]]*=' "$ROOT/Makefile"; then
    echo "ERROR: staged top-level Makefile looks like a redirect stub, not the real kernel Makefile" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
# PIN THE LOCALVERSION SO A TARGET-SIDE REBUILD CANNOT RENAME THE KERNEL.
#
# The tarball ships the correct identity:
#   include/generated/utsrelease.h -> #define UTS_RELEASE "<kver>"
#   include/config/kernel.release  -> <kver>
# but `make modules_prepare` on the target REGENERATES both from the tree's own
# config. Yocto applies the suffix via KERNEL_LOCALVERSION at build time, which
# leaves CONFIG_LOCALVERSION="" and no localversion-* file in the tree -- so the
# regeneration silently renames the kernel back to its base version.
#
# Measured on O6N 2026-08-17: a tree shipped as 7.2.0-sky1-ncz came out of
# modules_prepare as 7.2.0, and every DKMS module was then stamped
#   vermagic: 7.2.0 SMP preempt mod_unload aarch64
# against a running 7.2.0-sky1-ncz kernel. modprobe rejects that as
# "Exec format error", which looks like a corrupt or wrong-arch module and is
# neither -- all six accelerator modules were dead on a kernel that had booted
# perfectly.
#
# Writing the suffix as a localversion file makes the tree self-consistent, so
# a regeneration reproduces the same release string instead of a different one.
_base=$(sed -n 's/^VERSION = *//p;' "$ROOT/Makefile" 2>/dev/null | head -1)
_patch=$(sed -n 's/^PATCHLEVEL = *//p' "$ROOT/Makefile" 2>/dev/null | head -1)
_sub=$(sed -n 's/^SUBLEVEL = *//p' "$ROOT/Makefile" 2>/dev/null | head -1)
if [ -n "$_base" ] && [ -n "$_patch" ]; then
    _kbase="$_base.$_patch${_sub:+.$_sub}"
    case "$KVER" in
        "$_kbase"?*)
            _suffix=${KVER#"$_kbase"}
            printf '%s\n' "$_suffix" > "$ROOT/localversion-ncz"
            echo "[extract] pinned localversion '$_suffix' (base $_kbase -> $KVER)"
            ;;
        *) echo "[extract] NOTE: $KVER does not extend base $_kbase; no localversion pinned" ;;
    esac
fi

# STRIP NON-PORTABLE HOST TOOLS.
#
# A Yocto build links its host tools against the uninative sysroot, e.g.
#   interpreter: /ybuild/tmp/sysroots-uninative/aarch64-linux/lib/ld-linux-aarch64.so.1
# That path exists only inside the build container, so on a target the binary
# is present, executable, right architecture -- and still fails with
#   /bin/sh: 1: .../scripts/basic/fixdep: not found
# because it is the LOADER that is missing, not the file. Every DKMS module
# then dies with "Error 127" on its first object file, which reads like a
# source incompatibility and is not one. Measured on O6N 2026-08-17: all six
# accelerator modules (mali_kbase, aipu, amvx, panthor, mgm, pma) failed this
# way against 7.2 final, and all six built once the tools were rebuilt on the
# target.
#
# So ship the SOURCES and let the target rebuild them (`make modules_prepare`),
# which is what post-install/10-our-kernel.sh now does. A tool whose loader IS
# present (a natively-built tree) is kept as-is.
_stripped=0
for _t in scripts/basic/fixdep scripts/mod/modpost scripts/mod/mk_elfconfig; do
    [ -f "$ROOT/$_t" ] || continue
    _interp=$(readelf -l "$ROOT/$_t" 2>/dev/null | sed -n 's/.*interpreter: \([^]]*\)].*/\1/p' | head -1)
    case "$_interp" in
        ""|/lib/*|/usr/lib/*) : ;;                       # portable, keep
        *) rm -f "$ROOT/$_t"; _stripped=$((_stripped + 1)) ;;
    esac
done
[ "$_stripped" -gt 0 ] && echo "[extract] stripped $_stripped non-portable host tool(s); target will rebuild them"

TMP_OUT="$OUT.tmp"
tar -C "$STAGE" \
    --owner=0 --group=0 \
    -cf - "lib/modules/$KVER/build" \
    | zstd -19 -T0 -q -o "$TMP_OUT"
mv "$TMP_OUT" "$OUT"

SIZE=$(du -h "$OUT" | cut -f1)
COUNT=$(find "$ROOT" -type f | wc -l)
echo "[extract] OK — $SIZE ($COUNT files) → $OUT"
