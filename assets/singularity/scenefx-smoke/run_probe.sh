#!/bin/bash
# run_probe.sh -- HARDWARE smoke gate: compile every SceneFX/labwc GLSL program
# through the target GLES driver and fail if any does not compile or link.
#
# Run this on a board whose GPU stack the payload actually uses:
#   * CIX Sky1 Mali vendor stack (O6N `sky1.gpu=vendor`): exports the CIX
#     EGL vendor library and builds shader_probe against libmali.
#   * any GLES board: the probe falls back to the system GLES driver.
#
# usage: run_probe.sh <scenefx-source-root> [outdir] [--require-mali]
#   <scenefx-source-root> is a sceneFX checkout, or a labwc build tree whose
#   subprojects/scenefx holds one. Defaults to $PWD.
#   --require-mali: fail unless the run used the vendor Mali stack
#   (NCZ_GPU_BACKEND=mali AND the driver reports GL_VENDOR=ARM), so a Mesa run
#   can never be recorded as a Mali-verified result.
#
# Scratch is never placed on tmpfs (project rule): the default outdir is under
# $HOME/Projects, TMPDIR is redirected into it, and a tmpfs target is refused.
set -euo pipefail

ROOT="$PWD"
OUT=""
REQUIRE_MALI=0
pos=()
for a in "$@"; do
    case "$a" in
        --require-mali) REQUIRE_MALI=1 ;;
        *) pos+=("$a") ;;
    esac
done
[ "${#pos[@]}" -ge 1 ] && ROOT="${pos[0]}"
[ "${#pos[@]}" -ge 2 ] && OUT="${pos[1]}"

if [ -f "$ROOT/common.vert" ]; then
    :
elif [ -f "$ROOT/render/fx_renderer/shaders/common.vert" ]; then
    :
elif [ -f "$ROOT/subprojects/scenefx/render/fx_renderer/shaders/common.vert" ]; then
    ROOT="$ROOT/subprojects/scenefx"
else
    echo "no scenefx shaders under $ROOT" >&2; exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# Scratch NEVER on tmpfs (scratch-and-cleanup policy).  If
# no outdir is given, default under ~/Projects and REFUSE a tmpfs target.
if [ -z "$OUT" ]; then
    OUT="$HOME/Projects/scenefx-smoke-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT"
fstype="$(findmnt -no FSTYPE -T "$OUT" 2>/dev/null || stat -f -c %T "$OUT" 2>/dev/null || echo unknown)"
case "$fstype" in
    tmpfs|ramfs) echo "run_probe: refusing to use a $fstype scratch dir ($OUT); pass an outdir on real disk" >&2; exit 2 ;;
esac
mkdir -p "$OUT/tmp"
export TMPDIR="$OUT/tmp"

# Vendor GPU env (Mali) if this board ships the NCZ selector.  NCZ_GPU_ENV_NO_IMPORT
# stops ncz-gpu-env from mutating the shell/dbus environment; a source failure is
# fatal (a silent failure would smoke-test the wrong driver).
export NCZ_GPU_ENV_NO_IMPORT=1
if [ -r /usr/local/bin/ncz-gpu-env ]; then
    # shellcheck disable=SC1091
    . /usr/local/bin/ncz-gpu-env || { echo "run_probe: sourcing ncz-gpu-env failed" >&2; exit 2; }
fi
unset LIBGL_ALWAYS_SOFTWARE || true
echo "NCZ_GPU_BACKEND=${NCZ_GPU_BACKEND:-<unset>}"

echo "== building shader_probe =="
[ -f "$HERE/shader_probe.c" ] || { echo "missing $HERE/shader_probe.c" >&2; exit 2; }
# Resolve a usable link line on hosts that ship only the versioned sonames
# (O6N has libgbm.so.1 but no libgbm.so dev symlink).  Prefer the plain -l
# flags, fall back to -l:<soname>.  The CIX vendor lib dir is used only if it
# exists.
LIBS=()
libdirs=(-L/opt/cixgpu-pro/lib/aarch64-linux-gnu -L/opt/cixgpu-pro/lib)
for d in /usr/lib/aarch64-linux-gnu /usr/lib; do [ -d "$d" ] && libdirs+=(-L"$d"); done
for spec in "EGL:libEGL.so.1" "GLESv2:libGLESv2.so.2" "gbm:libgbm.so.1"; do
    name="${spec%%:*}"; soname="${spec#*:}"
    probe_so="$(for d in "${libdirs[@]}"; do d="${d#-L}"; [ -e "$d/lib$name.so" ] && { echo "$d/lib$name.so"; break; }; done)"
    if [ -n "$probe_so" ]; then LIBS+=("-l$name"); else LIBS+=("-l:$soname"); fi
done
cc -O1 -o "$OUT/shader_probe" "$HERE/shader_probe.c" -I/usr/include "${libdirs[@]}" "${LIBS[@]}" 2>&1 | tee "$OUT/build.log"
[ -x "$OUT/shader_probe" ] || { echo "run_probe: shader_probe did not build" >&2; exit 2; }

# Shaders: reuse a pre-generated dir (NCZ_SMOKE_SHADERS_DIR) or generate from
# the scenefx source root.
if [ -n "${NCZ_SMOKE_SHADERS_DIR:-}" ] && [ -f "$NCZ_SMOKE_SHADERS_DIR/manifest.tsv" ]; then
    SH="$NCZ_SMOKE_SHADERS_DIR"
    echo "== using pre-generated shaders in $SH =="
else
    echo "== generating formatted shaders =="
    python3 "$HERE/make_shaders.py" "$ROOT" "$OUT/shaders"
    SH="$OUT/shaders"
fi

echo "== compiling every program through the target driver =="
set +e
# Make_shaders emits manifest paths relative to the shaders dir, so run from it.
( cd "$SH" && "$OUT/shader_probe" manifest.tsv ) 2>&1 | tee "$OUT/probe.log"
rc="${PIPESTATUS[0]}"
set -e

if [ "$REQUIRE_MALI" = 1 ]; then
    if [ "${NCZ_GPU_BACKEND:-}" != mali ] || ! grep -q 'GL_VENDOR * = ARM' "$OUT/probe.log"; then
        echo "FAIL(--require-mali): run was not on the vendor Mali stack" >&2
        echo "  NCZ_GPU_BACKEND=${NCZ_GPU_BACKEND:-<unset>}; $(grep -E 'GL_VENDOR|GL_RENDERER' "$OUT/probe.log" | sed 's/^/  /')" >&2
        rc=1
    fi
fi

echo "probe rc=$rc  (logs: $OUT)"
exit "$rc"
