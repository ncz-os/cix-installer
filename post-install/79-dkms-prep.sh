#!/bin/bash
# 79-dkms-prep.sh — make the shipped kernel headers usable for DKMS.
#
# Operator directive: all CIX accelerator drivers ship out-of-tree via DKMS.
# That is impossible on a stock install, because the kernel-headers tree we ship
# is a Yocto BUILD-HOST artifact, not a target-usable one. Four separate defects,
# each of which alone makes every DKMS build fail. All four were found the hard
# way on O6N (.3) against 7.2.0-rc6-sky1-ncz:
#
#   1. HOST TOOLS ARE FOREIGN BINARIES.
#      scripts/basic/fixdep and scripts/mod/modpost are ELF aarch64 but linked
#      against Yocto's uninative loader:
#          interpreter /ybuild/tmp/sysroots-uninative/aarch64-linux/lib/ld-linux-aarch64.so.1
#      That path does not exist here, so execve fails and the kernel build
#      reports "/bin/sh: 1: .../fixdep: not found" for a file that is plainly
#      present. Rebuild them natively.
#
#   2. THE LOCALVERSION SUFFIX IS NOT IN THE SHIPPED CONFIG.
#      Yocto passes KERNEL_LOCALVERSION="-sky1-ncz" out-of-band, so the shipped
#      .config carries CONFIG_LOCALVERSION="" and there is no localversion* file.
#      Anything that regenerates the release string on target therefore produces
#      "7.2.0-rc6" instead of "7.2.0-rc6-sky1-ncz", every DKMS module is stamped
#      with that vermagic, and NONE of them load. Same class of bug as the rc5
#      hardcode in cix-gpu-kmd_1.0.bb, one layer further down: the release string
#      must be derivable from the shipped artifacts, never re-guessed.
#      Fix: write a localversion-* file, which kbuild appends verbatim.
#
#   3. GENERATED SOURCES ARE MISSING.
#      scripts/selinux/mdp needs security/selinux/include/classmap.h, which the
#      headers package does not ship, and it aborts the whole `scripts` target
#      before modpost is reached. mdp is a policy-authoring tool irrelevant to
#      building modules, so neutralise its subdir for the duration of the build
#      rather than vendor generated headers we would then have to keep in sync.
#
#   4. NO TOOLCHAIN.
#      A stock install has no dkms, gcc, make, flex, bison, bc, libelf, or the
#      aarch64-linux-gnu-gcc driver that the Mali DKMS makefile invokes.
#
# This script is idempotent and never fatal: a failure here costs DKMS rebuilds
# on future kernel upgrades, but the prebuilt overlays in assets/kernel/ still
# carry the boot, so it must not take an install down with it.
# NCZ-PLATFORM-GUARD: sky1-arm64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order matches
# run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then dpkg. An
# undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    arm64|aarch64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not sky1-arm64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch
set -uo pipefail

echo "[79] preparing kernel headers for DKMS"

# --- resolve the kernel we are preparing ------------------------------------
KVER="${KVER_NEXT:-}"
if [ -z "$KVER" ]; then
    # newest installed kernel that has a build tree
    for d in /lib/modules/*/build; do
        [ -d "$d" ] || continue
        k="${d%/build}"; k="${k#/lib/modules/}"
        KVER="$k"
    done
fi
if [ -z "$KVER" ] || [ ! -d "/lib/modules/$KVER/build" ]; then
    echo "[79] no kernel build tree found — skipping (DKMS will be unavailable)"
    exit 0
fi
B="/lib/modules/$KVER/build"
echo "[79] target kernel $KVER"

# --- 4. toolchain ------------------------------------------------------------
MISSING=""
for t in dkms gcc aarch64-linux-gnu-gcc make flex bison bc; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -e /usr/include/libelf.h ] || MISSING="$MISSING libelf"
if [ -n "$MISSING" ]; then
    echo "[79] installing build toolchain:$MISSING"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dkms build-essential gcc gcc-aarch64-linux-gnu make flex bison bc \
        libelf-dev libselinux-dev \
        >/dev/null 2>&1 \
        && echo "[79] toolchain installed" \
        || echo "[79] WARNING: toolchain install failed — DKMS rebuilds will not work"
fi

# --- 2. localversion ---------------------------------------------------------
# Derive the suffix from KVER itself rather than hardcoding it: KVER is
# "<upstream>-<suffix>", e.g. 7.2.0-rc6-sky1-ncz -> -sky1-ncz. Hardcoding a
# literal here is precisely the bug this whole exercise exists to remove.
# sed -E is portable across GNU and BSD; the \+ form is a GNU-only extension and
# silently matched nothing when this was first written, which made SUFFIX the
# WHOLE version string and would have produced a doubled release like
# "7.2.0-rc67.2.0-rc6-sky1-ncz". Guard the result rather than trust the regex.
BASE=$(printf '%s' "$KVER" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?).*$/\1/')
SUFFIX=""
case "$KVER" in
    "$BASE"?*) [ -n "$BASE" ] && SUFFIX="${KVER#"$BASE"}" ;;
esac
case "$SUFFIX" in
    -*) : ;;                       # a real localversion always starts with '-'
    *)  SUFFIX="" ;;
esac
if [ -n "$SUFFIX" ]; then
    if [ ! -e "$B/localversion-ncz" ] || \
       [ "$(cat "$B/localversion-ncz" 2>/dev/null)" != "$SUFFIX" ]; then
        printf '%s\n' "$SUFFIX" > "$B/localversion-ncz"
        echo "[79] wrote localversion-ncz = $SUFFIX"
    else
        echo "[79] localversion-ncz already correct ($SUFFIX)"
    fi
else
    echo "[79] WARNING: could not derive a localversion suffix from $KVER;" \
         "DKMS modules may be built with the wrong vermagic"
fi

# --- 1 + 3. native host tools, with selinux/mdp neutralised ------------------
# Detect an unusable host tool by TRYING TO RUN IT, not by inspecting it with
# file(1). An earlier version gated this on `command -v file`, which meant that
# on a minimal system without file(1) the check silently concluded the tools
# were fine and skipped the rebuild -- leaving every later DKMS build to fail
# with the same baffling "not found" on a binary that exists. Exec is also the
# ground truth here: what matters is whether the loader can start it.
# 126 = found but not executable, 127 = interpreter/file not found.
tool_usable() {
    [ -x "$1" ] || return 1
    "$1" --version >/dev/null 2>&1
    case $? in
        126|127) return 1 ;;   # cannot exec: wrong ABI or missing loader
        *)       return 0 ;;   # ran (a usage error is still a successful exec)
    esac
}

# Every host tool a DKMS build runs. genksyms is one of them: a module that
# exports symbols (aipu) runs it for CONFIG_MODVERSIONS, and the shipped r285
# headers carry a genksyms linked against Yocto's uninative loader even when
# fixdep and modpost are already native (r201 arm64 KVM gate: "genksyms: not
# found", no aipu.ko). Checking only fixdep/modpost skipped the rebuild.
HOST_TOOLS="scripts/basic/fixdep scripts/mod/modpost scripts/genksyms/genksyms"

need_rebuild=0
for tool in $HOST_TOOLS; do
    tool_usable "$B/$tool" || need_rebuild=1
done

if [ "$need_rebuild" = "1" ]; then
    echo "[79] rebuilding kernel host tools natively (shipped ones are Yocto build-host binaries)"
    SEL="$B/scripts/selinux/Makefile"
    SELBAK=""
    # Restore the neutralised Makefile even if we are interrupted: leaving it
    # truncated would quietly break future kernel builds in a way that looks
    # nothing like its cause.
    restore_selinux() {
        [ -n "${SELBAK:-}" ] && [ -f "$SELBAK" ] && cp -a "$SELBAK" "$SEL"
        [ -n "${SELBAK:-}" ] && rm -f "$SELBAK"
        SELBAK=""
    }
    trap 'restore_selinux' EXIT INT TERM
    if [ -f "$SEL" ]; then
        SELBAK="$(mktemp)"; cp -a "$SEL" "$SELBAK"; : > "$SEL"
    fi
    # modules_prepare builds scripts/mod/modpost; it also fails on other
    # generated sources the headers package omits (kernel/time/timeconst.bc)
    # and, with CONFIG_DEBUG_INFO_BTF_MODULES kept (pahole installed), on
    # tools/bpf/resolve_btfids (no tools/ sources: scripts/utilities.mak,
    # linux/kasan-checks.h). Those do not matter for DKMS, but a failing job
    # stops make from starting the rest, and under -j that left modpost unbuilt
    # (2026-10-06: every DKMS build then died on "No rule to make target
    # .../scripts/mod/modpost"). -k keeps going so modpost and fixdep get built.
    # Keep the log: this step failing is the difference between DKMS working and
    # not, and "somewhere in a discarded make run" is not a debuggable report.
    LOG=/var/log/ncz-dkms-prep.log
    if ! make -k -C "$B" -j"$(nproc 2>/dev/null || echo 2)" modules_prepare \
            >>"$LOG" 2>&1; then
        echo "[79] modules_prepare returned non-zero (expected: the headers omit" \
             "some generated sources); see $LOG"
    fi
    restore_selinux
    trap - EXIT INT TERM

    for tool in $HOST_TOOLS; do
        if tool_usable "$B/$tool"; then
            echo "[79]   $tool -> native"
        else
            echo "[79]   WARNING: $tool still unusable; DKMS builds will fail" \
                 "(see $LOG)"
        fi
    done
else
    echo "[79] host tools already native"
fi

# --- verify: the release string the tree will stamp must equal KVER ----------
REL=$(cat "$B/include/config/kernel.release" 2>/dev/null || true)
if [ -n "$REL" ] && [ "$REL" != "$KVER" ]; then
    echo "[79] WARNING: build tree reports release '$REL' but kernel is '$KVER' —" \
         "DKMS modules would be stamped with the wrong vermagic and refuse to load"
elif [ -n "$REL" ]; then
    echo "[79] release string OK ($REL)"
fi

echo "[79] DKMS prep done"
exit 0
