#!/bin/bash
# run_probe.sh -- HARDWARE smoke gate: compile every SceneFX/labwc GLSL program
# through the target GLES driver and fail if any does not compile or link.
#
# Run this on a board whose GPU stack the payload actually uses:
#   * CIX Sky1 Mali vendor stack (O6N `sky1.gpu=vendor`): exports the CIX
#     EGL vendor library and builds shader_probe against libmali.
#   * any GLES board: the probe falls back to the system GLES driver.
#
# It is the hardware half of the O6N/Mali regression gate; the static half is
# build/check-singularity-shaders.sh (runs in every payload build).
#
# usage: run_probe.sh <path-to-scenefx-source-root> [outdir]
#   <scenefx-source-root> is a sceneFX checkout, or a labwc build tree whose
#   subprojects/scenefx holds one. Defaults to $PWD.
set -euo pipefail

ROOT="${1:-$PWD}"
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
# Scratch NEVER on tmpfs (policy, ~/.claude/rules/scratch-and-cleanup.md).  If
# no outdir is given, default under ~/Projects and REFUSE a tmpfs target.
OUT="${2:-$HOME/Projects/scenefx-smoke-$(date -u +%Y%m%dT%H%M%SZ)}"
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
if [ -r /usr/local/bin/ncz-gpu-env ]; then
    export NCZ_GPU_ENV_NO_IMPORT=1
    # shellcheck disable=SC1091
    . /usr/local/bin/ncz-gpu-env || { echo "run_probe: sourcing ncz-gpu-env failed" >&2; exit 2; }
fi
unset LIBGL_ALWAYS_SOFTWARE || true

echo "== building shader_probe =="
cc -O1 -o "$OUT/shader_probe" "$HERE/shader_probe.c" \
    -I/usr/include -L/opt/cixgpu-pro/lib/aarch64-linux-gnu \
    -lEGL -lGLESv2 -lgbm 2>&1 | tee "$OUT/build.log"

echo "== generating formatted shaders =="
python3 "$HERE/make_shaders.py" "$ROOT" "$OUT/shaders"

echo "== compiling every program through the target driver =="
set +e
"$OUT/shader_probe" "$OUT/shaders/manifest.tsv" 2>&1 | tee "$OUT/probe.log"
rc="${PIPESTATUS[0]}"
set -e
echo "probe rc=$rc  (logs: $OUT)"
exit "$rc"
