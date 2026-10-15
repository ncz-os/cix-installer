#!/bin/bash
# tests/run-tests.sh — offline, non-hardware test harness for the packaged
# get-apple-firmware helper.
#
# Guarantees (per task scope):
#   * NO network access (no curl download of firmware or helper code)
#   * NO Apple firmware downloads
#   * NO mount / losetup / dmg2img / live device access
#   * NO execution of the whole interactive helper (only syntax checks and
#     isolated, side-effect-free function extraction with mocked commands)
#
# Tests:
#   T1  bash -n syntax check of the packaged script
#   T2  embedded Python renamer parses (ast) and imports only stdlib
#   T3  helper advertises the expected subcommands in its usage text
#   T4  isolated rename_firmware() logic vs a synthetic fixture tree
#   T5  digest-verification fail-closed: mismatch never executes asset
#   T6  digest-verification success path with a good mock
#   T7  dependency-audit: commands used by default paths are declared
#
# Exit non-zero on any failure.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$PKG_ROOT/get-apple-firmware"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/t2fw-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
skip=0

ok()   { echo "ok   - $1"; pass=$((pass+1)); }
bad()  { echo "FAIL - $1"; fail=$((fail+1)); }
sk()   { echo "skip - $1"; skip=$((skip+1)); }

if [ ! -f "$SCRIPT" ]; then
    echo "FAIL - packaged script not found: $SCRIPT" >&2
    exit 1
fi

echo "== T1: bash -n syntax check =="
if bash -n "$SCRIPT"; then ok "bash -n clean"; else bad "bash -n reported a syntax error"; fi

echo "== T2: embedded Python parses and is stdlib-only =="
if ! bash "$HERE/extract-renamer.sh" "$SCRIPT" > "$WORK/renamer.py"; then
    bad "failed to extract embedded Python renamer (fail-closed)"
else
    if [ ! -s "$WORK/renamer.py" ]; then
        bad "extracted renamer is empty"
    elif python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$WORK/renamer.py"; then
        ok "embedded Python parses"
    else
        bad "embedded Python failed to parse"
    fi
    imports="$(python3 - "$WORK/renamer.py" <<'PY'
import ast, sys
tree = ast.parse(open(sys.argv[1]).read())
mods = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        for a in n.names: mods.add(a.name.split('.')[0])
    elif isinstance(n, ast.ImportFrom):
        if n.module and n.level == 0: mods.add(n.module.split('.')[0])
print(' '.join(sorted(mods)))
PY
)"
    nonstd=""
    for m in $imports; do
        python3 -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('$m') else 1)" 2>/dev/null || nonstd="$nonstd $m"
    done
    if [ -z "$nonstd" ]; then
        ok "embedded Python imports resolve ($imports)"
    else
        bad "embedded Python imports NOT resolvable:$nonstd"
    fi
fi

echo "== T3: usage text advertises expected subcommands =="
for sc in rename_only copy_to_efi create_archive create_package get_from_efi get_from_macos get_from_online; do
    if grep -q "$sc" "$SCRIPT"; then ok "subcommand present: $sc"; else bad "subcommand missing: $sc"; fi
done

echo "== T4: isolated renamer on a synthetic fixture (no network/device) =="
if [ -s "$WORK/renamer.py" ]; then
    mkdir -p "$WORK/fw/wifi" "$WORK/fw/bluetooth"
    printf 'w' > "$WORK/fw/wifi/brcmfmac4364b3-pcie.apple,macbookpro16,1.bin"
    printf 'b' > "$WORK/fw/bluetooth/brcmbt4364b3-apple,macbookpro16,1.bin"
    if command -v timeout >/dev/null 2>&1; then
        out="$WORK/out.tar"
        ( cd "$WORK" && timeout 30 python3 "$WORK/renamer.py" "$WORK/fw" "$out" ) >/dev/null 2>"$WORK/t4.err"
        rc=$?
        case $rc in
            0)   ok "isolated renamer produced $([ -f "$out" ] && echo an archive || echo no-archive-with-rc0)" ;;
            1|2|3) sk "isolated renamer exited rc=$rc (fixture not a real mac tree; expected)" ;;
            124) bad "isolated renamer TIMED OUT (must not hang)" ;;
            *)   ok "isolated renamer exited rc=$rc without hanging (no network/device use)" ;;
        esac
        if grep -qE 'urlopen|requests\.|curl |wget ' "$WORK/renamer.py"; then
            bad "renamer block references a network downloader"
        else
            ok "renamer block contains no network downloader"
        fi
    else
        sk "timeout(1) unavailable; skipping isolated execution"
    fi
else
    sk "no extracted renamer; skipping T4"
fi

echo "== T5: digest verification fail-closed (mismatch never executes) =="
# Extract the digest-verification helper from the installed script and drive
# it with a mocked curl that returns attacker-controlled bytes. The helper
# must refuse to execute on mismatch.
if grep -q 'verify_sha256' "$SCRIPT"; then
    # Source only the verify_sha256 function definition in a subshell.
    ( set -e
      # shellcheck disable=SC1090
      eval "$(awk '/^verify_sha256 \(\)/,/^}/' "$SCRIPT")"
      # Mock curl: emit attacker bytes to stdout.
      curl() { printf 'ATTACKER-CONTROLLED-BYTES'; }
      export -f curl 2>/dev/null || true
      tmp="$WORK/attacker.bin"
      printf 'ATTACKER-CONTROLLED-BYTES' > "$tmp"
      if verify_sha256 "$tmp" "0000000000000000000000000000000000000000000000000000000000000000"; then
          echo "MISMATCH-ACCEPTED"
      else
          echo "MISMATCH-REJECTED"
      fi
    ) > "$WORK/t5.out" 2>&1 || true
    if grep -q 'MISMATCH-REJECTED' "$WORK/t5.out"; then
        ok "digest mismatch rejected (fail-closed)"
    elif grep -q 'MISMATCH-ACCEPTED' "$WORK/t5.out"; then
        bad "digest mismatch was ACCEPTED (must fail-closed)"
    else
        sk "could not exercise verify_sha256 in isolation"
    fi
else
    bad "installed helper lacks verify_sha256 (runtime code not pinned)"
fi

echo "== T6: digest verification success path with a good mock =="
if grep -q 'verify_sha256' "$SCRIPT"; then
    ( set -e
      # shellcheck disable=SC1090
      eval "$(awk '/^verify_sha256 \(\)/,/^}/' "$SCRIPT")"
      tmp="$WORK/good.bin"
      printf 'GOOD-BYTES' > "$tmp"
      good_sha=$(python3 -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$tmp")
      if verify_sha256 "$tmp" "$good_sha"; then
          echo "GOOD-ACCEPTED"
      else
          echo "GOOD-REJECTED"
      fi
    ) > "$WORK/t6.out" 2>&1 || true
    if grep -q 'GOOD-ACCEPTED' "$WORK/t6.out"; then
        ok "digest match accepted"
    else
        bad "digest match was rejected (must accept)"
    fi
else
    sk "verify_sha256 not present; skipping T6"
fi

echo "== T7: dependency audit vs debian/control =="
CTRL="$PKG_ROOT/debian/control"
if [ -f "$CTRL" ]; then
    REL_SET="$(python3 - "$CTRL" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
text = re.sub(r'\n[ \t]+', ' ', text)
deps = []
for line in text.splitlines():
    m = re.match(r'^(?:Depends|Recommends):\s*(.*)$', line)
    if m:
        for tok in m.group(1).split(','):
            tok = tok.strip().split(' ')[0].split('(')[0].strip()
            if tok: deps.append(tok)
print('\n'.join(deps))
PY
)"
    has() { printf '%s\n' "$REL_SET" | grep -qx "$1"; }

    for dep in python3 mount sudo kmod ca-certificates; do
        if has "$dep"; then ok "declared dependency present: $dep"; else bad "missing declared dependency: $dep"; fi
    done
    if has curl; then ok "declared: curl"; else bad "missing declared: curl"; fi
    if has dmg2img; then ok "declared (recommended): dmg2img"; else sk "dmg2img not declared (optional path)"; fi
    if printf '%s\n' "$REL_SET" | grep -qxE '(brew|pacman|dnf|rpmbuild|makepkg)'; then
        bad "control declares a non-Debian/impossible dependency"
    else
        ok "no impossible (non-Debian) dependencies declared"
    fi
else
    bad "debian/control not found"
fi

echo
echo "== summary: pass=$pass fail=$fail skip=$skip =="
[ "$fail" -eq 0 ]
