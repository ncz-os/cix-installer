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
# FAIL-CLOSED: a missing/unreadable input, a non-ELF file, a `strings` failure,
# or an empty read all FAIL.  It never reports OK because it could not read the
# binary.
#
# usage: check-singularity-shaders.sh <labwc-binary> [<labwc-binary> ...]
#   exit 0 clean; 1 defect or unreadable input; 2 usage
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <labwc-binary> [...]" >&2; exit 2; }

rc=0
for bin in "$@"; do
	if [ ! -f "$bin" ]; then
		echo "FAIL: no such file: $bin" >&2
		rc=1
		continue
	fi
	# Must be an ELF binary; a stray text file / truncated artifact is a defect.
	if ! head -c 4 "$bin" 2>/dev/null | od -An -tx1 | grep -q '7f 45 4c 46'; then
		echo "FAIL: $bin is not an ELF binary (or is unreadable)" >&2
		rc=1
		continue
	fi
	# `strings` must succeed; an error here must NOT silently count as 0 matches.
	if ! embedded="$(strings -a "$bin" 2>/dev/null)"; then
		echo "FAIL: 'strings' failed on $bin -- cannot verify, failing closed" >&2
		rc=1
		continue
	fi
	bad="$(printf '%s\n' "$embedded" | grep -c '#error "' || true)"
	total="$(printf '%s\n' "$embedded" | grep -c '#error' || true)"
	bad="${bad:-0}"; total="${total:-0}"
	if [ "$bad" -ne 0 ]; then
		echo "FAIL: $bin embeds ${bad} quoted '#error \"' shader line(s)." >&2
		echo "      libmali (CIX Sky1, Valhall r53p0) rejects the double quote even in a" >&2
		echo "      disabled branch; labwc cannot create its SceneFX fx renderer (black screen)." >&2
		echo "      Fix: build/patch-singularity-scenefx.sh + assets/singularity/scenefx-patches/." >&2
		printf '%s\n' "$embedded" | grep '#error "' | sed 's/^/        /' >&2
		rc=1
	else
		echo "OK: $bin -- no quoted #error shader (embedded #error lines: ${total})"
	fi
done
exit "$rc"
