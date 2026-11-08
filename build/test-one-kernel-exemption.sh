#!/usr/bin/env bash
# test-one-kernel-exemption.sh -- the substrate kernel-udeb exemption must be
# opt-in, must cover every place the installer's udebs appear, and must not
# widen to the finished image.
#
# WHY THIS EXISTS. docs/ONE-KERNEL.md removes the substrate's Debian kernel/module
# udebs from the medium; the provenance gate used to demand authorization for them
# anyway, so an image could not pass. The exemption is wired now, and each failure
# mode is silent:
#
#   * DEFAULT-ON -- a trust root that never asked for it stops checking those bytes.
#                   It must read release.conf (NCZ_ONE_KERNEL_SUBSTRATE_UDEBS=exempt)
#                   and default to off.
#   * INCOMPLETE -- the installer's udebs appear in THREE places: the pool's
#                   Packages records, the pool's orphan walk, and the initrd's dpkg
#                   status (at the initrd's own build version, which is OLDER than
#                   the pool's). Missing any one leaves the build blocked; the third
#                   was found by running the build end to end, cycle 496.
#   * WIDENING   -- if the flag reached the finished-image scan, an image that still
#                   carried a second kernel's installer modules would pass. It also
#                   holds only for d-i kernel udeb NAMES (-di) inside the substrate
#                   whose sha256 manifests/base.pin pins; the behaviour is tested
#                   end to end in build/test-provenance-predict.sh section 5.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/build/forky-provenance.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
report() {
    local f="$1"
    [ -s "$f" ] || { bad "$(basename "$f") produced no output"; return; }
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
    except BaseException as e:  # noqa: BLE001 - the strict parser exits
        return f"error:{type(e).__name__}"

for value, want, label in [
    (None, False, "no key at all: the exemption is OFF"),
    ("exempt", True, "the exact value 'exempt' turns it on"),
    ("EXEMPT", False, "case matters: 'EXEMPT' does not"),
    ("yes", False, "another word does not"),
]:
    got = ctx(value)
    print(("PASS" if got == want else "FAIL") + f" {label} (got {got!r})")

# an EMPTY value is a hard parse error, not "off" -- assert the error, not a guess
got = ctx("")
print(("PASS" if str(got).startswith("error:") or got is False else "FAIL") +
      f" an empty value does not silently mean on (got {got!r})")
PY
report "$T/switch"

# --- 2. coverage: all three sites, one shared predicate ----------------------------
python3 - "$SRC" > "$T/sites" 2>&1 <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
nl = chr(10)

def body(fn):
    i = src.index("def " + fn)
    nxt = src.find(nl + "def ", i + 1)
    return src[i:(nxt if nxt != -1 else len(src))]

recs = body("authorize_records")
print(("PASS" if "exempt_substrate_kernel" in recs else "FAIL") +
      " the pool's Packages records honour the opt-in exemption")
print(("PASS" if "orphan pool file not listed in any Packages index" in recs else "FAIL") +
      " the pool's orphan walk lives in that same function (one implementation)")

noarch = body("classify_noarch")
ok_noarch = ("substrate_scan" in noarch and "one-kernel-exempt" in noarch
             and "_di_kernel_udeb(name)" in noarch)
print(("PASS" if ok_noarch else "FAIL") +
      " the initrd dpkg status honours the same exemption (the third site)")
print(("PASS" if recs.count("_di_kernel_udeb(") == 2 else "FAIL") +
      " the pool records and the orphan walk use the same d-i kernel-udeb predicate")
dik = body("_di_kernel_udeb")
print(("PASS" if ('endswith("-di")' in dik and "KERNEL_ARTIFACT_RE.search" in dik) else "FAIL") +
      " that predicate is the kernel-artifact pattern narrowed to d-i udeb names (-di)")
sub = body("scan_substrate_iso")
print(("PASS" if ("_ncz_build_context" in sub and "_pinned_substrate_shas" in sub) else "FAIL") +
      " the substrate scan needs BOTH the release.conf opt-in and the base.pin sha256")
print(("PASS" if src.count("KERNEL_ARTIFACT_RE = re.compile") == 1 else "FAIL") +
      " the kernel predicate is defined once, not copied per site")
PY
report "$T/sites"

# --- 3. scope: one call site, and the finished-image scan is not it -----------------
python3 - "$SRC" > "$T/scope" 2>&1 <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split(chr(10))
calls = [ln for ln in lines if "exempt_substrate_kernel=_okx" in ln]
print(("PASS" if len(calls) == 1 else "FAIL") +
      f" exactly one call site passes the exemption (found {len(calls)})")
idx = [n for n, ln in enumerate(lines) if "exempt_substrate_kernel=_okx" in ln]
if idx:
    start = max(n for n, ln in enumerate(lines[:idx[0]]) if ln.startswith("def "))
    fn = lines[start].split("(")[0]
    print(("PASS" if "scan_substrate_iso" in fn else "FAIL") +
          f" it is used only inside {fn}()")
image = [ln for ln in lines if "authorize_pool(ref, base" in ln]
print(("PASS" if image and all("exempt_substrate_kernel" not in ln for ln in image) else "FAIL") +
      " the FINISHED-IMAGE scan does not pass it (an image must still be clean)")
PY
report "$T/scope"

echo "test-one-kernel-exemption: $pass passed, $fail failed"
[ "$fail" = 0 ]
