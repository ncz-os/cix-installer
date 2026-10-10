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
# Scratch is never placed on tmpfs (fleet rule): the default outdir is under
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
if [ -z "$OUT" ]; then
    OUT="$HOME/Projects/scenefx-smoke-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$OUT/tmp"
# Never build on tmpfs: refuse a tmpfs outdir, and keep cc's own temp files off it.
if command -v findmnt >/dev/null 2>&1; then
    fstype="$(findmnt -no FSTYPE -T "$OUT" 2>/dev/null || true)"
    case "$fstype" in
        tmpfs|ramfs) echo "refusing to build on $fstype: $OUT (fleet rule: scratch never on tmpfs)" >&2; exit 2 ;;
    esac
fi
export TMPDIR="$OUT/tmp"

# NCZ_GPU_ENV_NO_IMPORT: do not mutate the caller's dbus/systemd environment.
export NCZ_GPU_ENV_NO_IMPORT=1
if [ -r /usr/local/bin/ncz-gpu-env ]; then
    # shellcheck disable=SC1091
    . /usr/local/bin/ncz-gpu-env
fi
echo "NCZ_GPU_BACKEND=${NCZ_GPU_BACKEND:-<unset>}"

echo "== building shader_probe =="
[ -f "$HERE/shader_probe.c" ] || { echo "missing $HERE/shader_probe.c" >&2; exit 2; }
LFLAG=""
[ -d /opt/cixgpu-pro/lib/aarch64-linux-gnu ] && LFLAG="-L/opt/cixgpu-pro/lib/aarch64-linux-gnu"
# shellcheck disable=SC2086
cc -O1 -o "$OUT/shader_probe" "$HERE/shader_probe.c" -I/usr/include $LFLAG \
    -lEGL -lGLESv2 -lgbm 2>&1 | tee "$OUT/build.log"

echo "== generating formatted shaders =="
python3 "$HERE/make_shaders.py" "$ROOT" "$OUT/shaders"

echo "== compiling every program through the target driver =="
set +e
"$OUT/shader_probe" "$OUT/shaders/manifest.tsv" 2>&1 | tee "$OUT/probe.log"
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
