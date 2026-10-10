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
# FAIL-CLOSED: this gate is only useful if it cannot PASS by accident, so it
# refuses to pass when the input is not an ELF, when `strings` fails, or when
# the binary carries no shader `#error` at all (which would mean the SceneFX
# source never reached the build, e.g. the patch helper silently stopped
# reaching the wrap).  Set NCZ_SHADER_GATE_ALLOW_NO_SCENEFX=1 to inspect a
# legitimately shader-less binary.
#
# usage: check-singularity-shaders.sh <labwc-binary> [<labwc-binary> ...]
#   exit 0 clean; 1 a quoted #error is embedded or shaders are absent; 2 usage/
#   missing file/not-ELF/tooling error (all fail the build).
set -uo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 <labwc-binary> [...]" >&2; exit 2; }
command -v strings >/dev/null 2>&1 || { echo "check-singularity-shaders: 'strings' not found" >&2; exit 2; }
require_shaders="${NCZ_SHADER_GATE_ALLOW_NO_SCENEFX:+0}"; require_shaders="${require_shaders:-1}"

is_elf() { [ -r "$1" ] && [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }

rc=0
for bin in "$@"; do
	if [ ! -f "$bin" ]; then
		echo "check-singularity-shaders: no such file: $bin" >&2
		rc=2; continue
	fi
	if ! is_elf "$bin"; then
		echo "check-singularity-shaders: not an ELF: $bin" >&2
		rc=2; continue
	fi
	# Capture strings output ONCE and fail closed if it errors (a `strings | grep
	# || true` would let a read failure look like a clean binary).
	local_strings="$(strings -a "$bin")" || { echo "check-singularity-shaders: strings failed on $bin" >&2; rc=2; continue; }
	bad="$(printf '%s\n' "$local_strings" | grep -c '#error "' || true)"
	total="$(printf '%s\n' "$local_strings" | grep -c '#error' || true)"
	bad="${bad:-0}"; total="${total:-0}"
	if [ "$bad" -ne 0 ]; then
		echo "FAIL: $bin embeds ${bad} quoted '#error \"' shader line(s)." >&2
		echo "      libmali (CIX Sky1, Valhall r53p0) rejects the double quote even in a" >&2
		echo "      disabled branch; labwc cannot create its SceneFX fx renderer (black screen)." >&2
		echo "      Fix: build/patch-singularity-scenefx.sh + assets/singularity/scenefx-patches/." >&2
		printf '%s\n' "$local_strings" | grep '#error "' | sed 's/^/        /' >&2
		rc=1
	elif [ "$require_shaders" = 1 ] && [ "$total" -eq 0 ]; then
		echo "FAIL: $bin embeds no shader '#error' at all -- SceneFX/SceneFX-preamble shaders" >&2
		echo "      are expected in a labwc payload.  A shader-less binary means the payload" >&2
		echo "      build lost its SceneFX sources (patch helper did not reach the wrap)." >&2
		rc=1
	else
		echo "OK: $bin -- no quoted #error shader (embedded #error lines: ${total})"
	fi
done
exit "$rc"
