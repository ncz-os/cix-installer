#!/bin/bash
# Standalone build of the patched singularity lockscreen (+ lock_framesrc hook)
# and the test frame source, so the lock suite can run without the whole
# desktop payload. Derived from the prior reference helper; this version
# builds against the FINAL patched shell C sources and the matching loginui
# sources from the current payload subprojects tree, with explicit source
# paths so nothing is implied by the host.
#
# Environment
#   WORK           scratch dir (default /work). Holds build artifacts and tmp/.
#   SHELL_SRC      path to the singularity-shell source tree (the meson root,
#                  which contains protocols/, src/lockscreen/, ...)
#   LOGINUI_SRC    path to the singularity-loginui source tree (contains
#                  loginui.h, widget.h, src/*.c)
#   PKG_CONFIG     optional, may be set to a specific pkg-config binary
#
# Sources are referenced through $SHELL_SRC and $LOGINUI_SRC so the script
# never builds against stale copies. There is no "old copied C" embedded here.
set -euo pipefail

: "${WORK:=/work}"
export WORK

# Resolve the shell sources: prefer the explicit env, else look for the
# payload under ../../work/singularity-desktop/subprojects relative to this
# script (handy in CI), else fail fast.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "${SHELL_SRC:-}" ]; then
    for c in \
        "$HERE/../../work/singularity-desktop/subprojects/singularity-shell" \
        "$HERE/../../../work/singularity-desktop/subprojects/singularity-shell" \
        "/work/singularity-desktop/subprojects/singularity-shell"; do
        if [ -f "$c/src/lockscreen/lock_main.c" ]; then SHELL_SRC="$c"; break; fi
    done
fi
if [ -z "${LOGINUI_SRC:-}" ]; then
    for c in \
        "$HERE/../../work/singularity-desktop/subprojects/singularity-loginui" \
        "$HERE/../../../work/singularity-desktop/subprojects/singularity-loginui" \
        "/work/singularity-desktop/subprojects/singularity-loginui"; do
        if [ -f "$c/loginui.h" ] && [ -f "$c/src/brand.c" ]; then LOGINUI_SRC="$c"; break; fi
    done
fi

if [ -z "${SHELL_SRC:-}" ] || [ ! -f "$SHELL_SRC/src/lockscreen/lock_main.c" ]; then
    echo "build.sh: could not locate singularity-shell sources" >&2
    echo "  set SHELL_SRC to the singularity-shell meson root" >&2
    exit 1
fi
if [ -z "${LOGINUI_SRC:-}" ] || [ ! -f "$LOGINUI_SRC/loginui.h" ]; then
    echo "build.sh: could not locate singularity-loginui sources" >&2
    echo "  set LOGINUI_SRC to the singularity-loginui meson root" >&2
    exit 1
fi
export SHELL_SRC LOGINUI_SRC

# Headers / input paths, all explicit. The lock headers come from the shell
# tree; the protocol headers are generated from the shell's xml by
# wayland-scanner (matches meson.build). The loginui headers come from
# LOGINUI_SRC root.
LOGINUI_HDR="$LOGINUI_SRC"
LOCK_HDR="$SHELL_SRC/src/lockscreen"
PROTO_XML="$SHELL_SRC/protocols/ext-session-lock-v1.xml"

for f in "$PROTO_XML" "$LOCK_HDR/lock_framesrc.h" "$LOCK_HDR/lock_framesrc_proto.h" \
         "$LOCK_HDR/lock_main.c" "$LOCK_HDR/lock_framesrc.c" "$LOCK_HDR/lock_framesrc_testsrc.c" \
         "$LOCK_HDR/pam_auth.c" "$LOCK_HDR/lock_media.c" "$LOCK_HDR/lock_notifs.c" "$LOCK_HDR/lock_fprint.c" \
         "$LOGINUI_HDR/loginui.h" "$LOGINUI_HDR/widget.h"; do
    if [ ! -f "$f" ]; then
        echo "build.sh: missing required source/header: $f" >&2
        exit 1
    fi
done

PKGS="wayland-client xkbcommon cairo pangocairo gdk-pixbuf-2.0 gio-2.0"
CFLAGS_BASE="-O2 -g -Wall -Wextra -Wno-unused-parameter -I$WORK -I. -I$LOGINUI_HDR -I$LOCK_HDR"
CFL=$(pkg-config --cflags $PKGS)
LIBS="$(pkg-config --libs $PKGS) -lpam -lm"

mkdir -p "$WORK/obj/loginui" "$WORK/obj/lock-off" "$WORK/obj/lock-on"

# Generate the ext-session-lock-v1 protocol C/H next to the lock sources (it is
# generated unconditionally by singularity-shell/meson.build; matches the names
# the lock C sources include).
PROTO_C="$WORK/ext-session-lock-v1-protocol.c"
PROTO_H="$WORK/ext-session-lock-v1-client-protocol.h"
wayland-scanner client-header "$PROTO_XML" "$PROTO_H"
wayland-scanner private-code  "$PROTO_XML" "$PROTO_C"

# Compile the loginui C sources (the ones the lock main links against).
# Determinism: one .o per .c, fixed order.
for f in "$LOGINUI_SRC"/src/*.c; do
    base="$(basename "${f%.c}")"
    gcc $CFLAGS_BASE $CFL -I"$LOGINUI_HDR" -c "$f" -o "$WORK/obj/loginui/${base}.o"
done

# Compile a lock variant. $1 is the -D flag string (may be empty), $2 is the
# output suffix ("on" or "off"). Inside each variant we assemble the exact
# object set we need; lock_framesrc.c only compiles when the feature flag is on.
build_variant() {
    local def="$1" name="$2"
    local dir="$WORK/obj/lock-$name"
    mkdir -p "$dir"
    local objs=()
    for f in lock_main.c pam_auth.c lock_media.c lock_notifs.c lock_fprint.c; do
        gcc $CFLAGS_BASE $def $CFL -I"$LOGINUI_HDR" -I"$LOCK_HDR" \
            -c "$LOCK_HDR/$f" -o "$dir/${f%.c}.o"
        objs+=("$dir/${f%.c}.o")
    done
    if [ -n "$def" ]; then
        gcc $CFLAGS_BASE $def $CFL -I"$LOGINUI_HDR" -I"$LOCK_HDR" \
            -c "$LOCK_HDR/lock_framesrc.c" -o "$dir/lock_framesrc.o"
        objs+=("$dir/lock_framesrc.o")
    fi
    gcc $CFLAGS_BASE $CFL -I"$LOGINUI_HDR" -I"$LOCK_HDR" \
        -c "$PROTO_C" -I"$WORK" -o "$dir/proto.o"
    objs+=("$dir/proto.o")
    gcc "${objs[@]}" "$WORK"/obj/loginui/*.o \
        -o "$WORK/singularity-lockscreen-$name" $LIBS
}

build_variant ""           "off"
build_variant "-DLOCK_FRAMESRC" "on"

# The deterministic frame source is also small and standalone (no Wayland, no
# GPU), so we keep the on-feature buildable without the desktop payload.
gcc $CFLAGS_BASE $CFL -I"$LOGINUI_HDR" -I"$LOCK_HDR" \
    "$LOCK_HDR/lock_framesrc_testsrc.c" \
    -o "$WORK/singularity-lock-framesrc-testsrc" $LIBS

ls -l "$WORK/singularity-lockscreen-off" \
       "$WORK/singularity-lockscreen-on" \
       "$WORK/singularity-lock-framesrc-testsrc"
