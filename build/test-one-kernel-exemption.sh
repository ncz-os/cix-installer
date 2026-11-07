#!/usr/bin/env bash
# test-one-kernel-exemption.sh -- the substrate kernel-udeb exemption must be
# opt-in, and it must not widen to the finished image.
#
# WHY THIS EXISTS. docs/ONE-KERNEL.md removes the substrate's Debian kernel/module
# udebs from the medium; the provenance gate used to demand authorization for them
# anyway, so an image could not pass. The exemption is now wired, and the two ways
# it could go wrong are both silent:
#
#   * DEFAULT-ON  -- a trust root that never asked for it stops checking those
#                    bytes. It must read release.conf
#                    (NCZ_ONE_KERNEL_SUBSTRATE_UDEBS=exempt) and default to off.
#   * WIDENING    -- if the flag reached the finished-image scan, an image that
#                    still carried a second kernel's installer modules would pass.
#                    Only the substrate INPUT scan sets it.
#
# It also asserts the exemption uses the one unified kernel predicate rather than a
# fourth copy of the pattern.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/build/forky-provenance.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
report() {  # report <file-of-PASS/FAIL-lines>
    local f="$1"
    while IFS= read -r line; do
        case "$line" in
            PASS*) ok "${line#PASS }" ;;
            FAIL*) bad "${line#FAIL }" ;;
            "        "*) echo "$line" ;;
        esac
    done < "$f"
}

[ -s "$SRC" ] || { echo "missing $SRC"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-okx.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

# --- 1. the switch: off by default, on only for the exact value --------------------
python3 - "$SRC" "$T" > "$T/switch" 2>&1 <<'PY'
import importlib.util, pathlib, sys
src, tmp = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("fp", src)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

root = pathlib.Path(tmp) / "root"; root.mkdir(parents=True)

def ctx(value):
    rc = root / "release.conf"
    rc.write_text("" if value is None else f"NCZ_ONE_KERNEL_SUBSTRATE_UDEBS={value}\n")
    try:
        return m._ncz_build_context(str(root))
    except Exception as e:  # noqa: BLE001
        return f"raised {type(e).__name__}: {e}"

for value, want, label in [
    (None, False, "no key at all: the exemption is OFF"),
    ("exempt", True, "the exact value 'exempt' turns it on"),
    ("EXEMPT", False, "case matters: 'EXEMPT' does not"),
    ("yes", False, "another word does not"),
]:
    got = ctx(value)
    print(("PASS" if got == want else "FAIL") + f" {label} (got {got!r})")

# an EMPTY value is a hard error, not "off": release.conf is parsed strictly, and
# measured behaviour is die("has trailing junk/unquoted whitespace").  Assert the
# error rather than pretending the empty case means false.
try:
    got = ctx("")
    print(("FAIL" if got else "FAIL") + f" an empty value was accepted (got {got!r}) -- expected a hard error")
except SystemExit as e:
    print("PASS an empty value is refused by the parser (rc=%s)" % e.code)
except Exception as e:  # noqa: BLE001
    print("PASS an empty value is refused by the parser (%s)" % type(e).__name__)
PY
report "$T/switch"

# --- 2. scope: exactly one call site, and it is the substrate input scan ------------
python3 - "$SRC" > "$T/scope" 2>&1 <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
# the call site spans lines, so count the ARGUMENT rather than a line that holds both
calls = [ln for ln in lines if "exempt_substrate_kernel=_okx" in ln]
print(("PASS" if len(calls) == 1 else "FAIL") +
      f" exactly one call site passes the exemption (found {len(calls)})")
for c in calls:
    print("        " + c.strip()[:120])
# ...and it must sit inside the substrate-ISO scanner, not somewhere generic
idx = [n for n, ln in enumerate(lines) if "exempt_substrate_kernel=_okx" in ln]
if idx:
    start = max(n for n, ln in enumerate(lines[:idx[0]]) if ln.startswith("def "))
    fn = lines[start].split("(")[0]
    print(("PASS" if "scan_substrate_iso" in fn else "FAIL") +
          f" the exemption is used only inside {fn}()")
# the finished-image scan is the one that reads authorize_pool(ref, base, ...)
image = [ln for ln in lines if "authorize_pool(ref, base" in ln]
print(("PASS" if image and all("exempt_substrate_kernel" not in ln for ln in image) else "FAIL") +
      " the FINISHED-IMAGE scan does not pass it (an image must still have a clean pool)")
defs = len(re.findall(r"KERNEL_ARTIFACT_RE\s*=\s*re\.compile", src))
print(("PASS" if defs == 1 else "FAIL") + f" the kernel predicate is defined once ({defs})")
PY
report "$T/scope"

# --- 3. and it is not a fourth copy of the pattern ----------------------------------
if grep -q 'KERNEL_ARTIFACT_RE.search(key\[0\])' "$SRC" && \
   grep -q 'KERNEL_ARTIFACT_RE.search(os.path.basename(p)' "$SRC"; then
    ok "both exemption sites use the shared KERNEL_ARTIFACT_RE"
else
    bad "an exemption site uses its own pattern instead of KERNEL_ARTIFACT_RE"
fi

echo "test-one-kernel-exemption: $pass passed, $fail failed"
[ "$fail" = 0 ]
