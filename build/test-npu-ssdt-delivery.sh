#!/bin/bash
# test-npu-ssdt-delivery.sh -- prove the MS-R1 NPU ACPI SSDT is actually
# DELIVERED into the initrd, board-gated, and idempotent.
#
# WHY THIS TEST EXISTS
# --------------------
# The MS-R1 shipped twice (r289, r290) logging
#     "only 0 of 3 NPU cores usable - disabling NPU"
# while the repo "had" an SSDT fix, because the fix was a compiled blob plus a
# prepend that the initramfs generator silently discarded. This test is written
# against the PROPERTY THAT MATTERS: after an initrd build on an MS-R1, the
# image contains an uncompressed early CPIO carrying
# kernel/firmware/acpi/ssdt-npucre.aml; on a Radxa/Orion board it contains
# nothing of the sort. It tests the unit boundary (the decision helper), the
# archive format (the kernel's contract), and the generator wiring (the thing
# that was missing).
#
# NO HARDWARE, NO ROOT. /sys is a fixture tree (NCZ_SYS_ROOT) and the hook is
# driven directly with DESTDIR/INITRD pointed into a temp dir. The real /sys and
# the repo's assets are never written.
#
# CASES
#   T1  iasl compiles the committed .asl -> a valid SSDT .aml (build-time step)
#   T2  early CPIO layout: newc, uncompressed, exactly kernel/firmware/acpi/ssdt-npucre.aml
#   T3  DMI gate: MS-R1 / "Micro Computer (HK)" -> apply
#   T4  DMI gate: Radxa Orion O6N / Orange Pi -> skip (never inject)
#   T5  ACPI signal: CIXH4000 present, <3 CIXH4010 cores -> apply
#   T6  ACPI signal: 3 CIXH4010 cores natively -> skip
#   T7  unknown board, no ACPI signal -> skip, and no stderr in the "apply" path
#   T8  operator override file wins over DMI (force / skip)
#   T9  idempotent: two builds are byte-identical; hook re-run is a no-op
#   T10 initramfs-tools hook: stages the table only on an MS-R1 fixture
#   T11 dracut module: check() always claims the module; install() is a no-op
#       on a non-MS-R1 fixture and stages the CPIO on an MS-R1 fixture
#   T12 the CPIO the hook writes is one the kernel's loader would accept
#       (magic + inner ACPI header signature/length self-consistency)
#   T13 the MEDIUM STAGER produces the table: build/iso/write-usb-image.py
#       must call build/iso/ncz_ssdt.py's ensure_npu_ssdt_aml() for arm64,
#       which compiles assets/npu/ssdt-npucre.asl and raises (never warns)
#       when it cannot. This is the case that would have caught the release
#       that shipped "only 0 of 3 NPU cores usable".
#
# Requires: bash, cpio, iasl (acpica-tools). Skips iasl cases with SKIP if the
# tool is absent rather than failing a host that cannot compile.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LIB="$REPO/post-install/lib/npu-ssdt.sh"
HOOK="$REPO/assets/initramfs/hooks/ncz-npu-ssdt"
PUHOOK="$REPO/assets/initramfs/post-update.d/zz-ncz-npu-ssdt"
MOD="$REPO/assets/dracut/modules.d/91ncz-npu-ssdt/module-setup.sh"
ASL="$REPO/assets/npu/ssdt-npucre.asl"
AML_NAME=ssdt-npucre.aml
ENTRY=kernel/firmware/acpi/$AML_NAME

W="$(mktemp -d "${TMPDIR:-/tmp}/npu-ssdt-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT

pass=0; fail=0; skip=0
ok()   { printf '  [PASS] %s\n' "$*"; pass=$((pass+1)); }
no()   { printf '  [FAIL] %s\n' "$*" >&2; fail=$((fail+1)); }
sk()   { printf '  [SKIP] %s\n' "$*"; skip=$((skip+1)); }

for f in "$LIB" "$HOOK" "$PUHOOK" "$MOD" "$ASL"; do
    [ -f "$f" ] || { echo "FATAL: missing required file: $f" >&2; exit 1; }
done

# --- fixture: a fake /sys with DMI + ACPI device tree --------------------
# mkfix <dir> <product_name> <sys_vendor> <product_family> <n_cores> <has_4000>
mkfix() {
    local d="$1" pn="$2" sv="$3" pf="$4" nc="$5" npu="$6" i
    mkdir -p "$d/class/dmi/id" "$d/bus/acpi/devices"
    [ -n "$pn" ] && printf '%s\n' "$pn" > "$d/class/dmi/id/product_name"
    [ -n "$sv" ] && printf '%s\n' "$sv" > "$d/class/dmi/id/sys_vendor"
    [ -n "$pf" ] && printf '%s\n' "$pf" > "$d/class/dmi/id/product_family"
    for ((i=0; i<nc; i++)); do mkdir -p "$d/bus/acpi/devices/CIXH4010:0$i"; done
    [ "$npu" = 1 ] && mkdir -p "$d/bus/acpi/devices/CIXH4000:00"
    return 0
}

# decide <sysfixture> [meta] -> apply|skip  (stderr discarded)
decide() {
    ( # shellcheck source=/dev/null
      . "$LIB"
      NCZ_SYS_ROOT="$1" ncz_npu_ssdt_decision "${2:-$W/meta/nonexistent}" 2>/dev/null )
}

# --- T1: compile the committed .asl with iasl ---------------------------
echo "T1  build-time .asl -> .aml compilation"
if command -v iasl >/dev/null 2>&1; then
    mkdir -p "$W/aml"
    cp "$ASL" "$W/aml/"
    if ( cd "$W/aml" && iasl -p "$AML_NAME" ssdt-npucre.asl >/dev/null 2>&1 ) \
            && [ -s "$W/aml/$AML_NAME" ]; then
        sig=$(head -c 4 "$W/aml/$AML_NAME")
        if [ "$sig" = "SSDT" ]; then
            ok "iasl produced an SSDT .aml from the committed .asl"
        else
            no "compiled table signature is '$sig', expected SSDT"
        fi
    else
        # iasl exits non-zero on warnings-with-errors; the table may still exist.
        if [ -s "$W/aml/$AML_NAME" ] && [ "$(head -c 4 "$W/aml/$AML_NAME")" = "SSDT" ]; then
            ok "iasl produced the SSDT .aml (non-zero exit, table valid)"
        else
            no "iasl could not compile $(basename "$ASL")"
        fi
    fi
else
    sk "iasl not installed (acpica-tools) -- cannot test compilation"
    # Synthesize a header-only table so the remaining cases still run.
    mkdir -p "$W/aml"
    python3 -c '
import struct, sys
open(sys.argv[1], "wb").write(b"SSDT" + struct.pack("<I", 36) + b"\x00"*28)
' "$W/aml/$AML_NAME"
fi

# --- meta tree the hook/CPIO builder reads --------------------------------
mkdir -p "$W/meta/assets/npu"
cp "$W/aml/$AML_NAME" "$W/meta/assets/npu/$AML_NAME"

# --- T2: early CPIO layout -----------------------------------------------
echo "T2  early CPIO layout (uncompressed newc, exact entry)"
out="$W/out.cpio"
# shellcheck source=post-install/lib/npu-ssdt.sh
if ( . "$LIB"; ncz_npu_ssdt_build_early_cpio "$out" "$W/meta" ) >/dev/null 2>&1 && [ -s "$out" ]; then
    magic=$(head -c 6 "$out")
    [ "$magic" = "070701" ] && ok "archive magic is 070701 (newc, uncompressed)" \
        || no "archive magic is '$magic', expected 070701"
    # Directories are legitimately present (the kernel walks the path); what
    # matters is that the ONLY regular file is the expected table -- no second
    # table, no stray payload, nothing under a path the loader ignores.
    # cpio -it alone does not mark directories; use the verbose form and keep
    # only non-directory entries (leading '-' in the mode field).
    files=$(cpio -itv < "$out" 2>/dev/null | grep '^-' | awk '{print $NF}' | sort | tr '\n' ' ')
    if [ "$files" = "$ENTRY " ]; then
        ok "archive's only regular file is $ENTRY"
    else
        no "archive regular files are '$files', expected only '$ENTRY'"
    fi
    # zstd/gzip magic must not be present: the kernel skips compressed members.
    case "$(head -c 4 "$out" | od -An -tx1 | tr -d ' \n')" in
        28b52ffd|1f8b*) no "archive is compressed -- the kernel would ignore it" ;;
        *) ok "archive is not compressed" ;;
    esac
else
    no "could not build the early CPIO from the fixture meta tree"
fi

# --- T3/T4: DMI gate -----------------------------------------------------
echo "T3  DMI gate: MS-R1 variants resolve to apply"
mkfix "$W/s_msr1_pn" "MS-R1"                 ""             ""        0 0
mkfix "$W/s_msr1_sv" ""                      "Micro Computer (HK) Limited" "" 0 0
mkfix "$W/s_msr1_pf" ""                      ""             "MS-R1"   0 0
for fx in s_msr1_pn s_msr1_sv s_msr1_pf; do
    r=$(decide "$W/$fx")
    [ "$r" = "apply" ] && ok "$fx -> apply" || no "$fx -> '$r', expected apply"
done

echo "T4  DMI gate: known-good boards resolve to skip"
mkfix "$W/s_o6n"    "Orion O6N"              "Radxa Computer (Shenzhen) Co., Ltd." "Orion O6" 0 1
mkfix "$W/s_o6"     "Orion O6"               "Radxa Computer (Shenzhen) Co., Ltd." ""        0 1
mkfix "$W/s_opi6"   "Orange Pi 6 Plus"       "Shenzhen Xunlong Software CO.,Limited" ""     0 1
# Adversarial: an O6N whose DMI ALSO carries a matching vendor string must
# still be skipped -- the allow-list has to win over the vendor fallback.
mkfix "$W/s_o6n_adv" "Orion O6N"             "Micro Computer (HK) Limited" ""        0 1
for fx in s_o6n s_o6 s_opi6 s_o6n_adv; do
    r=$(decide "$W/$fx")
    [ "$r" = "skip" ] && ok "$fx -> skip" || no "$fx -> '$r', expected skip"
done

# --- T5/T6: functional ACPI signal wins --------------------------------
echo "T5  ACPI: CIXH4000 with 0/3 cores -> apply (the actual MS-R1 symptom)"
mkfix "$W/s_acpi_gap" "" "" "" 0 1
r=$(decide "$W/s_acpi_gap"); [ "$r" = "apply" ] && ok "0/3 cores -> apply" || no "-> '$r', expected apply"
mkfix "$W/s_acpi_gap2" "" "" "" 2 1
r=$(decide "$W/s_acpi_gap2"); [ "$r" = "apply" ] && ok "2/3 cores -> apply" || no "-> '$r', expected apply"

echo "T6  ACPI: 3 cores enumerate natively -> skip (even with no DMI)"
mkfix "$W/s_acpi_ok" "" "" "" 3 1
r=$(decide "$W/s_acpi_ok"); [ "$r" = "skip" ] && ok "3/3 cores -> skip" || no "-> '$r', expected skip"

# --- T7: unknown board ---------------------------------------------------
echo "T7  unknown board, no ACPI signal -> skip"
mkfix "$W/s_unknown" "Some Laptop" "Some Vendor" "Some Family" 0 0
r=$(decide "$W/s_unknown"); [ "$r" = "skip" ] && ok "unknown -> skip" || no "-> '$r', expected skip"
# A skip must be SILENT on stdout (exactly one token) so callers can compare.
n=$(decide "$W/s_unknown" | wc -l)
[ "$n" -le 1 ] && ok "decision output is a single token" || no "decision printed $n lines"

# --- T8: operator override ----------------------------------------------
echo "T8  operator override file wins over DMI"
mkdir -p "$W/meta_force"
printf 'force\n' > "$W/meta_force/NPU_SSDT"
r=$(decide "$W/s_o6n" "$W/meta_force")
[ "$r" = "apply" ] && ok "force on a known-good board -> apply" || no "-> '$r', expected apply"
mkdir -p "$W/meta_skip"
printf 'skip\n' > "$W/meta_skip/NPU_SSDT"
r=$(decide "$W/s_msr1_pn" "$W/meta_skip")
[ "$r" = "skip" ] && ok "skip on an MS-R1 -> skip" || no "-> '$r', expected skip"

# --- T9: idempotency -----------------------------------------------------
echo "T9  idempotency"
( # shellcheck source=post-install/lib/npu-ssdt.sh
  . "$LIB"; ncz_npu_ssdt_build_early_cpio "$W/a.cpio" "$W/meta" ) >/dev/null 2>&1
sleep 1
( # shellcheck source=post-install/lib/npu-ssdt.sh
  . "$LIB"; ncz_npu_ssdt_build_early_cpio "$W/b.cpio" "$W/meta" ) >/dev/null 2>&1
if cmp -s "$W/a.cpio" "$W/b.cpio"; then
    ok "two builds one second apart are byte-identical (epoch-0 mtimes)"
else
    no "rebuild produced a different archive -- not reproducible"
fi

# --- T10: the initramfs-tools hook -------------------------------------
echo "T10 initramfs-tools hook stages the table, board-gated"
# The hook sources the decision helper from an absolute path; run it with a
# PATH shim that returns the fixture's lib, and a fake hook-functions.
mkdir -p "$W/shim"
cat > "$W/shim/hook-functions" <<'EOF'
# minimal stand-in for /usr/share/initramfs-tools/hook-functions
:
EOF
# Simpler and more faithful: copy the lib into the meta tree the hook looks for.
mkdir -p "$W/meta/post-install/lib"
cp "$LIB" "$W/meta/post-install/lib/npu-ssdt.sh"
mkdir -p "$W/fake_etc"
for fx in s_msr1_pn s_o6n; do
    dest="$W/initrd-$fx"
    rm -rf "$dest"; mkdir -p "$dest"
    # Drive the hook with the real code, overriding the helper search path via
    # a rewritten copy in a sandbox (the shipped hook is not parameterisable
    # by design: it must work unattended on the target).
    hook_copy="$W/hook-$fx"
    sed "s#/usr/local/lib/cix-installer#$W/meta#g; s#/cdrom/ncz-payload#$W/meta#g" \
        "$HOOK" > "$hook_copy"
    NCZ_SYS_ROOT="$W/$fx" NCZ_NPU_SSDT_META="$W/meta" DESTDIR="$dest" \
    bash -c ". '$W/shim/hook-functions'; . '$hook_copy'" >/dev/null 2>&1
    if [ "$fx" = "s_msr1_pn" ]; then
        if [ -f "$dest/$ENTRY" ]; then
            ok "MS-R1 fixture: hook staged $ENTRY"
        else
            no "MS-R1 fixture: hook did NOT stage $ENTRY"
        fi
    else
        if [ -z "$(find "$dest" -name '*.aml' 2>/dev/null)" ]; then
            ok "O6N fixture: hook staged no table (correctly gated)"
        else
            no "O6N fixture: hook staged an SSDT -- DMI gate bypassed"
        fi
    fi
done

# --- T11: the dracut module -------------------------------------------
echo "T11 dracut module claims every image, acts only on MS-R1"
# module-setup.sh is written for dracut: $initdir, derror() and the module
# framework. Stand in for them and call check()/install() directly.
cat > "$W/dracut_shim.sh" <<'EOF'
derror()  { echo "derror: $*" >&2; }
dwarn()   { echo "dwarn: $*" >&2; }
dinstdir() { mkdir -p "$initdir/$1"; }
EOF
# NB: module-setup.sh is not a plain script -- it defines functions and expects
# the dracut framework. Source it, then call into it.
mod_case() {
    local fx="$1" id="$W/mod-$1"
    rm -rf "$id" "$W/acpi-$fx"; mkdir -p "$id"
    ( set +u
      . "$W/dracut_shim.sh"
      # $initdir is the dracut module framework's staging root.
      # shellcheck disable=SC2034
      initdir="$id"
      # NCZ_SYS_ROOT must be in the environment BEFORE module-setup.sh runs:
      # it resolves the decision helper and the meta dir at source time.
      export NCZ_SYS_ROOT="$W/$fx"
      export NCZ_NPU_SSDT_LIB="$LIB"
      export NCZ_NPU_SSDT_META="$W/meta"
      # The module populates the host-side acpi_table_dir dracut reads for its
      # native early-CPIO. Redirect it: the test must never touch /etc.
      export NCZ_NPU_ACPI_DIR="$W/acpi-$fx"
      # shellcheck source=/dev/null
      . "$MOD"
      _c=0; check || _c=$?
      _i=0; install || _i=$?
      a=no; c=no; t=no
      [ -f "$id/usr/share/ncz/acpi/$AML_NAME" ] && a=yes
      [ -f "$id/usr/share/ncz/acpi-early/npu-acpi-override.cpio" ] && c=yes
      [ -f "$W/acpi-$fx/$AML_NAME" ] && t=yes
      printf 'check:%s install:%s aml:%s cpio:%s tbl:%s' "$_c" "$_i" "$a" "$c" "$t"
    ) 2>/dev/null
}
r=$(mod_case s_msr1_pn)
case "$r" in
    check:0*install:0*aml:yes*cpio:yes*tbl:yes*) ok "MS-R1 fixture: $r" ;;
    *) no "MS-R1 fixture: $r (expected check:0 install:0 aml:yes cpio:yes tbl:yes)" ;;
esac
r=$(mod_case s_o6n)
case "$r" in
    check:0*install:0*aml:no*cpio:no*tbl:no*) ok "O6N fixture: $r" ;;
    *) no "O6N fixture: $r (expected check:0 install:0 aml:no cpio:no tbl:no)" ;;
esac
# The native dracut path only works if the installer enables the knob for the
# board and the module fills the directory it points at.
if grep -q 'acpi_override="yes"' "$REPO/post-install/80-npu.sh" \
   && grep -q 'acpi_table_dir=' "$REPO/post-install/80-npu.sh"; then
    ok "80-npu.sh enables dracut acpi_override + acpi_table_dir on apply boards"
else
    no "80-npu.sh does not enable dracut's native ACPI override (kernel upgrades lose the NPU)"
fi

# --- T12: what the hook wrote is what the kernel would accept -----------
echo "T12 kernel acceptance shape (magic + ACPI header self-consistency)"
c="$W/initrd-s_msr1_pn/$ENTRY"
if [ -f "$c" ]; then
    python3 - "$c" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
ok = True
if len(d) < 36:
    print("  [FAIL] table shorter than the 36-byte ACPI header"); sys.exit(1)
sig = d[:4].decode("ascii", "replace")
length = struct.unpack("<I", d[4:8])[0]
if sig != "SSDT":
    print(f"  [FAIL] signature {sig!r}, expected SSDT"); ok = False
else:
    print(f"  [PASS] inner table signature SSDT, length field {length}B")
if length != len(d):
    print(f"  [FAIL] header length {length} != file size {len(d)}"); ok = False
else:
    print("  [PASS] header length matches file size (kernel walks tables by it)")
sys.exit(0 if ok else 1)
PY
    if [ $? -eq 0 ]; then pass=$((pass+2)); else fail=$((fail+1)); fi
else
    no "no staged table from T10 to inspect"
fi

echo "T13 the medium stager must produce the table (build/iso/ncz_ssdt.py)"
# WHY: the 2026-10-28 root cause. Every unit above could pass while a real
# image shipped assets/npu/ with only the .asl, because nothing in the build
# ever compiled it -- the only caller of build/build-npu-ssdt.sh was
# build/stage-canonical-assets.sh, which no stage runs. write-usb-image.py is
# the ONE place that stages assets/* onto the medium, so it must call the
# stager for arm64 and must fail the build when it cannot.
STAGER="$REPO/build/iso/ncz_ssdt.py"
MEDIUM="$REPO/build/iso/write-usb-image.py"
if [ -f "$STAGER" ]; then ok "build/iso/ncz_ssdt.py exists"; else no "build/iso/ncz_ssdt.py missing"; fi
if grep -q 'ensure_npu_ssdt_aml' "$MEDIUM" 2>/dev/null; then
    ok "write-usb-image.py stages the table via ensure_npu_ssdt_aml()"
else
    no "write-usb-image.py does not call ensure_npu_ssdt_aml() (an arm64 image would ship no NPU table)"
fi
if command -v python3 >/dev/null 2>&1; then
    TW="$W/stager"; mkdir -p "$TW/repo/assets/npu"
    cp "$ASL" "$TW/repo/assets/npu/ssdt-npucre.asl"
    # arm64 with iasl present -> builds a valid table
    if command -v iasl >/dev/null 2>&1; then
        rc=$( cd "$TW/repo" && python3 - "$STAGER" <<'PY'
import sys, importlib.util, hashlib
from pathlib import Path
spec = importlib.util.spec_from_file_location("ncz_ssdt", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p = m.ensure_npu_ssdt_aml(Path.cwd(), "arm64", log=lambda s: None)
d = Path(p).read_bytes()
assert d[:4] == b"SSDT" and d.count(b"CIXH4010") == 3, "bad table"
cpio = Path.cwd()/"assets"/"npu"/"npu-acpi-override.cpio"
assert cpio.is_file(), "early CPIO not staged (the target cannot copy it to /boot)"
c = cpio.read_bytes()
assert c[:6] == b"070701", "early CPIO is not newc"
assert b"kernel/firmware/acpi/ssdt-npucre.aml" in c, "early CPIO names the wrong entry"
assert b"TRAILER!!!" in c, "early CPIO has no trailer"
h1 = hashlib.sha256(c).hexdigest()
m.ensure_npu_ssdt_aml(Path.cwd(), "arm64", log=lambda s: None)
h2 = hashlib.sha256(Path(cpio).read_bytes()).hexdigest()
assert h1 == h2, "early CPIO is not reproducible across runs"
print(p)
PY
        ) && ok "arm64: compiles ssdt-npucre.aml + reproducible newc early CPIO ($rc)" \
          || no "arm64: ensure_npu_ssdt_aml did not produce a valid table + CPIO"
    else
        sk "iasl absent -- cannot prove the compile path on this host"
    fi
    # amd64 is a no-op (no CIX NPU on amd64 images)
    rm -f "$TW/repo/assets/npu/$AML_NAME"
    ( cd "$TW/repo" && python3 - "$STAGER" <<'PY'
import sys, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("ncz_ssdt", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
p = m.ensure_npu_ssdt_aml(Path.cwd(), "amd64", log=lambda s: None)
assert p is None, "amd64 must not stage a table"
assert not (Path.cwd()/"assets"/"npu"/"ssdt-npucre.aml").exists()
PY
    ) && ok "amd64: no-op (no CIX NPU)" || no "amd64: stager did something unexpected"
    # arm64 with neither iasl nor a staged table must FAIL LOUDLY
    if command -v iasl >/dev/null 2>&1; then
        if ( cd "$TW/repo" && PATH=/nonexistent /usr/bin/python3 - "$STAGER" <<'PY'
import sys, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("ncz_ssdt", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.ensure_npu_ssdt_aml(Path.cwd(), "arm64", log=lambda s: None)
except RuntimeError as e:
    assert "acpica-tools" in str(e), "error must name the fix"
    sys.exit(0)
sys.exit(3)
PY
        ); then ok "arm64 without iasl: raises naming acpica-tools (build stops)"
        else no "arm64 without iasl: did not raise with the actionable message"; fi
    fi
    # missing .asl is fatal
    mv "$TW/repo/assets/npu/ssdt-npucre.asl" "$TW/repo/assets/npu/x.asl"
    if ( cd "$TW/repo" && python3 - "$STAGER" <<'PY'
import sys, importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("ncz_ssdt", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
try:
    m.ensure_npu_ssdt_aml(Path.cwd(), "arm64", log=lambda s: None)
except RuntimeError:
    sys.exit(0)
sys.exit(1)
PY
    ); then ok "missing committed .asl is fatal"; else no "missing .asl did not fail"; fi
else
    sk "python3 absent -- stager contract untested here"
fi

# --- summary ------------------------------------------------------------
echo ""
echo "test-npu-ssdt-delivery: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ] || exit 1
exit 0
