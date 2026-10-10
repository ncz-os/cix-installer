#!/usr/bin/env bash
# test-singularity-mali-shaders.sh -- offline regression gate for the O6N/Mali
# SceneFX black-screen (2026-10-10). No GPU, no compiler, no network.
#
# Proves:
#   * build/check-singularity-shaders.sh PASSES a clean ELF and FAILS
#     (fail-closed) on a quoted `#error`, a non-ELF file and a missing file;
#   * assets/singularity/scenefx-patches/0001-*.patch de-quotes ONLY the two
#     `#error` lines and nothing else.
# The hardware half is assets/singularity/scenefx-smoke/run_probe.sh.
#
# 0 pass, 1 fail.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/build/check-singularity-shaders.sh"
PATCH="$ROOT/assets/singularity/scenefx-patches/0001-render-fx_renderer-shaders-do-not-quote-the-shader-preamble-error.patch"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$GATE" ] || fail "gate not executable: $GATE"
[ -f "$PATCH" ] || fail "scenefx patch missing: $PATCH"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ncz-mali-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# Minimal synthetic ELF: the gate only checks the 4-byte magic + strings output.
# r203 integration: a REAL patched SceneFX/labwc payload still embeds the
# (now-unquoted) `#error Missing shader preamble` preamble in every SceneFX
# shader, so a "clean ELF" here carries one unquoted `#error` line -- otherwise
# it would look like a shader-less binary, which the fail-closed gate (and
# build/test-singularity-shaders-gate.sh) deliberately rejects.
clean_elf() { { printf '\x7f\x45\x4c\x46'; printf 'const char *s = "#error Missing shader preamble";\n'; } > "$1"; }
bad_elf()   { { printf '\x7f\x45\x4c\x46'; printf 'const char *s = "x";\n#error "Missing shader preamble"\n'; } > "$1"; }

clean_elf "$tmp/clean"
bad_elf   "$tmp/bad"
printf 'plain text, not an ELF\n' > "$tmp/notelf"

bash "$GATE" "$tmp/clean" >/dev/null 2>&1 || fail "gate rejected a clean ELF"
if bash "$GATE" "$tmp/bad" >/dev/null 2>&1; then
    fail "gate passed a quoted #error (fail-open)"
fi
if bash "$GATE" "$tmp/notelf" >/dev/null 2>&1; then
    fail "gate passed a non-ELF file (fail-open)"
fi
if bash "$GATE" "$tmp/does-not-exist" >/dev/null 2>&1; then
    fail "gate passed a missing file (fail-open)"
fi

# The patch must de-quote exactly the two `#error` lines and change nothing else.
[ "$(grep -c '^-#error "Missing shader preamble"$' "$PATCH")" = 2 ] \
    || fail "patch does not remove exactly 2 quoted #error lines"
[ "$(grep -c '^+#error Missing shader preamble$' "$PATCH")" = 2 ] \
    || fail "patch does not add exactly 2 unquoted #error lines"
other="$(grep -E '^[+-]' "$PATCH" | grep -vE '^(\+\+\+|---)' | grep -vcE '^[+-]#error' || true)"
[ "${other:-0}" = 0 ] || fail "patch changes lines other than the two #error directives ($other)"

echo "OK: check-singularity-shaders.sh fails closed; scenefx patch de-quotes only the two #error lines"
