#!/usr/bin/env bash
# test-one-kernel-strip.sh -- the one-kernel strip must delete, and then prove it did.
#
# WHY. `filter_substrate_kernel_artifacts()` removes the substrate's Debian
# kernel/module/binary debs+udebs from the merged /cdrom pool when
# NCZ_ONE_KERNEL=1. Nothing else inspects that pool: `chk_one_kernel()` in
# build/check-layers.sh reads the squashfs LAYERS (boot/vmlinuz, lib/modules,
# Debian dpkg info), not /cdrom/pool. So before cycle 494 the strip could remove
# nothing at all and the medium would still ship a second kernel's installer
# modules while every gate reported PASS.
#
# The writer now verifies its own result with the SAME predicate it deletes with,
# and fails closed. This suite exercises that pair directly:
#   1. the delete-list matches the Debian artifacts and spares the NCZ kernel;
#   2. the filter removes exactly that list;
#   3. after the filter the list is empty, i.e. the verification would pass;
#   4. a pool that still holds one (simulating a strip that did not run) is
#      reported -- the check is not vacuous;
#   5. the degenerate name that used to slip through the writer's older regex
#      ("foo-modules--di") is now caught.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WRITER="$ROOT/build/iso/write-usb-image.py"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

[ -s "$WRITER" ] || { echo "missing $WRITER"; exit 1; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-ones.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

# the writer must CALL the assertion right after the strip -- testing the function
# alone would pass even if the call site were deleted.
if grep -q 'filter_substrate_kernel_artifacts(stage_dir / "pool")' "$WRITER" \
   && grep -q 'assert_one_kernel_pool(stage_dir / "pool")' "$WRITER"; then
    f_line=$(grep -n 'filter_substrate_kernel_artifacts(stage_dir / "pool")' "$WRITER" | head -1 | cut -d: -f1)
    a_line=$(grep -n 'assert_one_kernel_pool(stage_dir / "pool")' "$WRITER" | head -1 | cut -d: -f1)
    [ "$a_line" -gt "$f_line" ] \
        && ok "the writer verifies the pool right after stripping it (line $a_line > $f_line)" \
        || bad "the pool is verified BEFORE the strip (assert $a_line, filter $f_line)"
else
    bad "the writer does not both filter and verify the merged pool"
fi

python3 - "$WRITER" "$T" <<'PY' > "$T/out" 2>&1
import importlib.util, os, pathlib, sys
writer, tmp = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("wui", writer)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

pool = pathlib.Path(tmp) / "pool" / "main"
pool.mkdir(parents=True)

debian = [
    "linux-image-7.1.13+deb14-amd64.deb",
    "linux-headers-7.1.13+deb14-amd64.deb",
    "base-modules-7.2.15+deb14-amd64-di_7.2.15-1_amd64.udeb",
    "nic-modules-7.2.15+deb14-amd64-di_7.2.15-1_amd64.udeb",
    "linux-base-7.2.15+deb14-amd64-di_7.2.15-1_amd64.udeb",
    "foo-modules--di_1-1_amd64.udeb",              # the degenerate name from cycle 487
]
keep = [
    "bash_5.2-1_amd64.deb",
    "libpcre2-8-0-udeb_10.49-1_amd64.udeb",
    "ncz-linux-image-cixmini-7.3.0_amd64.deb",    # NCZ kernel: must be spared
    "ncz-screensavers-plugin_0.3.26_amd64.deb",
]
for n in debian + keep:
    (pool / n).write_bytes(b"x")

listed = {p.name for p in m.list_substrate_kernel_artifacts(pool)}
want = set(debian)
print(("PASS" if listed == want else "FAIL") + f" the delete-list is exactly the Debian kernel artifacts ({len(listed)} listed, wanted {len(want)})")
if listed != want:
    print("        unexpected:", sorted(listed - want), "missed:", sorted(want - listed))
for n in keep:
    print(("PASS" if n not in listed else "FAIL") + f" spared: {n}")

removed = m.filter_substrate_kernel_artifacts(pool)
print(("PASS" if removed == len(want) else "FAIL") + f" the filter removed exactly {len(want)} file(s) (removed {removed})")
after = {p.name for p in m.list_substrate_kernel_artifacts(pool)}
print(("PASS" if not after else "FAIL") + " after the strip the verification list is empty (the writer would not raise)")
left = sorted(p.name for p in pool.iterdir())
print(("PASS" if set(left) == set(keep) else "FAIL") + f" the kept files are untouched ({len(left)} left)")
if set(left) != set(keep):
    print("        left:", left)

# 4. the fail-closed call must RAISE on a pool that still holds one, and must not
#    raise on a clean pool.  Asserting the list is not the same as asserting the
#    writer refuses to ship.
try:
    m.assert_one_kernel_pool(pool)
    print("PASS the clean pool passes the assertion (no raise)")
except RuntimeError as e:
    print(f"FAIL a clean pool raised: {e}")
(pool / "xtables-addons-modules-7.2.15+deb14-amd64-di_1_amd64.udeb").write_bytes(b"x")
try:
    m.assert_one_kernel_pool(pool)
    print("FAIL a dirty pool did NOT raise -- the strip's result would go unverified")
except RuntimeError as e:
    msg = str(e)
    ok_msg = "left 1 Debian kernel artifact" in msg and "xtables-addons" in msg
    print(("PASS" if ok_msg else "FAIL") + f" a dirty pool raises and names the file: {msg[:90]}")
PY
rc=$?
while IFS= read -r line; do
    case "$line" in
        PASS*) ok "${line#PASS }" ;;
        FAIL*) bad "${line#FAIL }" ;;
        "        "*) echo "$line" ;;
    esac
done < "$T/out"
[ "$rc" = 0 ] || bad "the strip check itself failed (rc=$rc)"

echo "test-one-kernel-strip: $pass passed, $fail failed"
[ "$fail" = 0 ]
