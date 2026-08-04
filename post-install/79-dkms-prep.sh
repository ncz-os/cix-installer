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
#      A stock install has no dkms, gcc, make, flex, bison, bc, or libelf.
#
# This script is idempotent and never fatal: a failure here costs DKMS rebuilds
# on future kernel upgrades, but the prebuilt overlays in assets/kernel/ still
# carry the boot, so it must not take an install down with it.
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
for t in dkms gcc make flex bison bc; do
    command -v "$t" >/dev/null 2>&1 || MISSING="$MISSING $t"
done
[ -e /usr/include/libelf.h ] || MISSING="$MISSING libelf"
if [ -n "$MISSING" ]; then
    echo "[79] installing build toolchain:$MISSING"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dkms build-essential flex bison bc libelf-dev libselinux1-dev \
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
need_rebuild=0
for tool in scripts/basic/fixdep scripts/mod/modpost; do
    if [ ! -x "$B/$tool" ]; then
        need_rebuild=1
    elif command -v file >/dev/null 2>&1 && \
         file "$B/$tool" 2>/dev/null | grep -q 'sysroots-uninative'; then
        need_rebuild=1
    fi
done

if [ "$need_rebuild" = "1" ]; then
    echo "[79] rebuilding kernel host tools natively (shipped ones are Yocto build-host binaries)"
    SEL="$B/scripts/selinux/Makefile"
    SELBAK=""
    if [ -f "$SEL" ]; then
        SELBAK="$(mktemp)"; cp -a "$SEL" "$SELBAK"; : > "$SEL"
    fi
    # modules_prepare builds scripts/mod/modpost; it later fails on other
    # generated sources the headers package omits (kernel/time/timeconst.bc),
    # which does not matter -- modpost and fixdep are built by then.
    make -C "$B" modules_prepare >/dev/null 2>&1 || true
    [ -n "$SELBAK" ] && { cp -a "$SELBAK" "$SEL"; rm -f "$SELBAK"; }

    for tool in scripts/basic/fixdep scripts/mod/modpost; do
        if [ -x "$B/$tool" ] && ! file "$B/$tool" 2>/dev/null | grep -q 'sysroots-uninative'; then
            echo "[79]   $tool -> native"
        else
            echo "[79]   WARNING: $tool still unusable; DKMS builds will fail"
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
