#!/bin/bash
# check-singularity-shaders.sh -- static regression gate for the O6N/Mali
# SceneFX black-screen (2026-10-10).
#
# A built labwc embeds SceneFX's GLSL as C byte strings.  If any embedded
# `#error` directive is quoted, the CIX/ARM libmali GLES compiler rejects the
# double quote -- "L0001: Unknown character '"'(34)" -- even inside a disabled
# preprocessor branch, so labwc cannot create its fx renderer and the Sky1
# Mali boot is a black screen.  Mesa/Panthor discard the inactive block and are
# unaffected, which is exactly why this shipped.
#
# This is the static half of the gate -- it catches the defect in any payload
# build (amd64 and arm64) with no GPU needed.  The hardware half is
# assets/singularity/scenefx-smoke/ (run_probe.sh on a Mali host).
#
# usage: check-singularity-shaders.sh <labwc-binary> [<labwc-binary> ...]
#   exit 0 clean; 1 a quoted #error is embedded; 2 usage/no binary
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <labwc-binary> [...]" >&2; exit 2; }

rc=0
for bin in "$@"; do
	if [ ! -f "$bin" ]; then
		echo "check-singularity-shaders: no such file: $bin" >&2
		rc=2
		continue
	fi
	bad="$(strings -a "$bin" | grep -c '#error "' || true)"
	total="$(strings -a "$bin" | grep -c '#error' || true)"
	if [ "${bad:-0}" -ne 0 ]; then
		echo "FAIL: $bin embeds ${bad} quoted '#error \"' shader line(s)." >&2
		echo "      libmali (CIX Sky1, Valhall r53p0) rejects the double quote even in a" >&2
		echo "      disabled branch; labwc cannot create its SceneFX fx renderer (black screen)." >&2
		echo "      Fix: build/patch-singularity-scenefx.sh + assets/singularity/scenefx-patches/." >&2
		strings -a "$bin" | grep '#error "' | sed 's/^/        /' >&2
		rc=1
	else
		echo "OK: $bin -- no quoted #error shader (embedded #error lines: ${total:-0})"
	fi
done
exit "$rc"
