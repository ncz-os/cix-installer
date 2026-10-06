#!/bin/bash
# test-amd64-edge-compat.sh -- prove the amd64 T2 edge entry gets
# pcie_ports=compat exactly once, and ONLY on Apple T2 hardware, while every
# other boot entry and every non-T2 machine stays free of it (operator
# directive 2026-10-05).
#
# Two layers are exercised, both against the SHIPPED code:
#   1. the DMI detector assets/refind/ncz-t2-detect.sh, sourced directly with
#      NCZ_DMI_ROOT pointed at fake /sys/class/dmi/id trees;
#   2. the real option-assembly and T2-cmdline blocks of
#      assets/refind/ncz-refind-refresh-amd64.sh, extracted between explicit
#      BEGIN/END markers added for exactly this purpose (no shape/indentation
#      guessing) and sourced with the fake DMI root.
#
# Contract asserted:
#   * MacBookPro16,1 -> yes; MacBookPro11,1 (pre-T2) -> no; ASUS desktop ->
#     no; QEMU/KVM -> no; Apple with an unlisted product -> no; missing DMI
#     files -> no (fail closed); an iMac19,x T2 model -> yes;
#   * the token is on the amd64 EDGE options only -- never stable, never
#     stable-console, never rescue -- and only when the machine is T2;
#   * it is present exactly once after one refresh and after three refreshes
#     (idempotent, and it never appears on a generic PC);
#   * appending it preserves the operator's own options;
#   * the arm64 refresh script never carries it.
#
# Exit 0 = all checks pass; 1 = one or more failed; 2 = extraction failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"
HELPER="$REPO/assets/refind/ncz-t2-detect.sh"
ARM64_SRC="$REPO/assets/refind/ncz-refind-refresh.sh"
for f in "$SRC" "$HELPER" "$ARM64_SRC"; do
    [ -f "$f" ] || { echo "EXTRACT FAILED: $f not found"; exit 2; }
done

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else nok "$1: got '$2' want '$3'"; fi; }
count_token() { printf '%s' "$1" | grep -o -- 'pcie_ports=compat' | wc -l | tr -d ' '; }

TOKEN="pcie_ports=compat"

# ---- extract the shipped code between explicit markers ------------------
# No assumptions about indentation or the surrounding shape: the marker
# comments are part of the shipped script and the test fails (exit 2) if a
# marker or its body goes missing.
extract_between() { # extract_between <file> <begin-marker> <end-marker>
    awk -v b="$2" -v e="$3" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"
}
extract_between "$SRC" 'NCZ-T2-CMDLINE-BEGIN' 'NCZ-T2-CMDLINE-END'  > "$W/cmdline.sh"
extract_between "$SRC" 'NCZ-EDGE-OPTIONS-BEGIN' 'NCZ-EDGE-OPTIONS-END' > "$W/region.sh"
extract_between "$SRC" 'NCZ-EDGE-GUARD-BEGIN' 'NCZ-EDGE-GUARD-END'    > "$W/guard.sh"
for f in cmdline region guard; do
    [ -s "$W/$f.sh" ] || { echo "EXTRACT FAILED: $f block empty/markers missing"; exit 2; }
done
grep -q 'EDGE_OPTIONS=' "$W/region.sh"      || { echo "EXTRACT FAILED: region has no EDGE_OPTIONS"; exit 2; }
grep -q 'EDGE_AVAILABLE' "$W/region.sh"     || { echo "EXTRACT FAILED: region has no EDGE_AVAILABLE branch"; exit 2; }
grep -q 'RESCUEPART_OPTIONS=' "$W/region.sh" || { echo "EXTRACT FAILED: region has no RESCUEPART_OPTIONS"; exit 2; }
grep -q 'case ' "$W/guard.sh"               || { echo "EXTRACT FAILED: guard has no case"; exit 2; }
grep -q 'ncz_is_t2_hardware' "$W/cmdline.sh" || { echo "EXTRACT FAILED: cmdline block does not call ncz_is_t2_hardware"; exit 2; }

# ---- 1. DMI detector unit tests -----------------------------------------
mkdmi() { # mkdmi <name> <vendor> <product>
    mkdir -p "$W/dmi/$1"
    printf '%s\n' "$2" > "$W/dmi/$1/sys_vendor"
    printf '%s\n' "$3" > "$W/dmi/$1/product_name"
}
detect() { # detect <dmi-root> -> yes|no
    ( NCZ_DMI_ROOT="$1"
      # shellcheck source=/dev/null
      . "$HELPER"
      if ncz_is_t2_hardware; then printf 'yes'; else printf 'no'; fi )
}
echo "=== DMI detection: real T2 models are yes ==="
mkdmi mbp16   "Apple Inc." "MacBookPro16,1"
mkdmi mbp15   "Apple Inc." "MacBookPro15,4"
mkdmi mba9    "Apple Inc." "MacBookAir9,1"
mkdmi imac19  "Apple Inc." "iMac19,1"      # brief's list includes iMac19,x
mkdmi imac20  "Apple Inc." "iMac20,2"
mkdmi imacpro "Apple Inc." "iMacPro1,1"
mkdmi mini    "Apple Inc." "Macmini8,1"
mkdmi macpro  "Apple Inc." "MacPro7,1"
mkdmi legacy  "Apple Computer, Inc." "MacBookPro16,1"
eq "MacBookPro16,1"          "$(detect "$W/dmi/mbp16")"   "yes"
eq "MacBookPro15,4"          "$(detect "$W/dmi/mbp15")"   "yes"
eq "MacBookAir9,1"           "$(detect "$W/dmi/mba9")"    "yes"
eq "iMac19,1"                "$(detect "$W/dmi/imac19")"  "yes"
eq "iMac20,2"                "$(detect "$W/dmi/imac20")"  "yes"
eq "iMacPro1,1"              "$(detect "$W/dmi/imacpro")" "yes"
eq "Macmini8,1"              "$(detect "$W/dmi/mini")"    "yes"
eq "MacPro7,1"               "$(detect "$W/dmi/macpro")"  "yes"
eq "legacy Apple vendor"     "$(detect "$W/dmi/legacy")"  "yes"

echo "=== DMI detection: everything else is no (fail closed) ==="
mkdmi mbp11  "Apple Inc." "MacBookPro11,1"                 # pre-T2 Intel Mac
mkdmi asus   "ASUSTeK COMPUTER INC." "PRIME Z390-A"        # generic desktop
mkdmi qemu   "QEMU" "Standard PC (Q35 + ICH9, 2009)"       # VM
mkdmi unlist "Apple Inc." "MacBookPro14,3"                 # Apple, not T2
mkdir -p "$W/dmi/missing"                                  # no DMI files at all
mkdir -p "$W/dmi/emptyprod"                                # vendor but empty product
printf '%s\n' "Apple Inc." > "$W/dmi/emptyprod/sys_vendor"
: > "$W/dmi/emptyprod/product_name"
eq "MacBookPro11,1 (pre-T2)"  "$(detect "$W/dmi/mbp11")"     "no"
eq "ASUS desktop"             "$(detect "$W/dmi/asus")"      "no"
eq "QEMU/KVM"                 "$(detect "$W/dmi/qemu")"      "no"
eq "Apple unlisted model"     "$(detect "$W/dmi/unlist")"    "no"
eq "missing DMI files"        "$(detect "$W/dmi/missing")"   "no"
eq "empty product_name"       "$(detect "$W/dmi/emptyprod")" "no"

# ---- 2. the shipped T2-cmdline block decides the constant ---------------
# Runs the REAL extracted block (which sources the REAL shipped helper) with
# a fake DMI root, and reads back NCZ_T2_EDGE_EXTRA_CMDLINE.
cmdline_for() { # cmdline_for <dmi-root> -> token or ""
    ( NCZ_DMI_ROOT="$1"; INSTALLER_META="$REPO"
      # shellcheck disable=SC1090
      . "$W/cmdline.sh" >/dev/null
      printf '%s' "$NCZ_T2_EDGE_EXTRA_CMDLINE" )
}
echo "=== shipped cmdline block gates on DMI ==="
eq "T2 Mac sets the token"        "$(cmdline_for "$W/dmi/mbp16")"   "$TOKEN"
eq "generic PC leaves it empty"   "$(cmdline_for "$W/dmi/asus")"    ""
eq "pre-T2 Mac leaves it empty"   "$(cmdline_for "$W/dmi/mbp11")"   ""
eq "QEMU leaves it empty"         "$(cmdline_for "$W/dmi/qemu")"    ""
eq "missing DMI leaves it empty"  "$(cmdline_for "$W/dmi/missing")" ""
# Fail closed if the helper itself is absent from the staged tree.
eq "absent helper fails closed" \
   "$( NCZ_DMI_ROOT="$W/dmi/mbp16" INSTALLER_META="$W/no-such-meta"; . "$W/cmdline.sh" >/dev/null; printf '%s' "$NCZ_T2_EDGE_EXTRA_CMDLINE" )" ""

# ---- 3. option assembly: token scope and idempotence --------------------
run_region() { # run_region <stable_avail> <edge_avail> <root_opts> <splash> <token>
    local sa="$1" ea="$2" ropts="$3" splash="$4" tok="$5"
    (
        set -uo pipefail
        STABLE_AVAILABLE="$sa"; EDGE_AVAILABLE="$ea"
        ROOT_OPTS="$ropts"
        STABLE_CMDLINE_BASE="console=ttyS0,115200 console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
        SPLASH="$splash"
        RESCUEPART_PARTUUID="1111-2222"
        NCZ_T2_EDGE_EXTRA_CMDLINE="$tok"
        # shellcheck disable=SC1090
        . "$W/region.sh"
        printf 'STABLE_OPTIONS=%s\n' "$STABLE_OPTIONS"
        printf 'STABLE_CONSOLE_OPTIONS=%s\n' "$STABLE_CONSOLE_OPTIONS"
        printf 'EDGE_OPTIONS=%s\n' "$EDGE_OPTIONS"
        printf 'RESCUEPART_OPTIONS=%s\n' "$RESCUEPART_OPTIONS"
    )
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "=== T2: edge gets the token once, nothing else does ==="
out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3" "$TOKEN")"
stable="$(field "$out" STABLE_OPTIONS)"
stable_con="$(field "$out" STABLE_CONSOLE_OPTIONS)"
edge="$(field "$out" EDGE_OPTIONS)"
rescue="$(field "$out" RESCUEPART_OPTIONS)"
eq "edge carries the token exactly once" "$(count_token "$edge")" "1"
eq "stable default entry has no token"   "$(count_token "$stable")" "0"
eq "stable-console entry has no token"   "$(count_token "$stable_con")" "0"
eq "rescue entry has no token"           "$(count_token "$rescue")" "0"
case " $edge " in *" $TOKEN "*) ok "edge carries the token as a whole word";; *) nok "token not delimited in edge options";; esac

echo "=== generic PC: no token anywhere ==="
out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3" "")"
eq "no token on a generic PC" "$(count_token "$out")" "0"

echo "=== operator options are preserved ==="
out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw my_user_opt=1 another=2" "quiet" "$TOKEN")"
edge="$(field "$out" EDGE_OPTIONS)"
case " $edge " in *" my_user_opt=1 "*) ok "operator option my_user_opt preserved";; *) nok "operator option dropped: $edge";; esac
case " $edge " in *" another=2 "*) ok "second operator option another preserved";; *) nok "second operator option dropped: $edge";; esac
eq "edge still carries the token exactly once" "$(count_token "$edge")" "1"

echo "=== three refreshes: token stays exactly once ==="
n=1
while [ "$n" -le 3 ]; do
    out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3" "$TOKEN")"
    edge="$(field "$out" EDGE_OPTIONS)"
    eq "refresh #$n edge token count" "$(count_token "$edge")" "1"
    n=$((n+1))
done

echo "=== edge unavailable: no token anywhere ==="
out="$(run_region 1 0 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet" "$TOKEN")"
eq "edge options empty when edge absent" "$(field "$out" EDGE_OPTIONS)" ""
eq "no token when edge absent" "$(count_token "$out")" "0"

echo "=== append guard is idempotent (token already present) ==="
guard_case() { # guard_case <initial-EDGE_OPTIONS> <token>
    (
        set -uo pipefail
        EDGE_OPTIONS="$1"
        NCZ_T2_EDGE_EXTRA_CMDLINE="$2"
        # shellcheck disable=SC1090
        . "$W/guard.sh"
        printf '%s' "$EDGE_OPTIONS"
    )
}
got="$(guard_case 'root=x console=tty0 systemd.unit=multi-user.target' "$TOKEN")"
eq "guard appends once when absent" "$(count_token "$got")" "1"
case " $got " in *" $TOKEN "*) ok "guard produced a delimited token";; *) nok "guard token not delimited: $got";; esac
got="$(guard_case "root=x console=tty0 $TOKEN systemd.unit=multi-user.target" "$TOKEN")"
eq "guard does not duplicate an existing token" "$(count_token "$got")" "1"
got="$(guard_case "root=x console=tty0 $TOKEN c" "$TOKEN")"
eq "guard leaves trailing options intact" "$(count_token "$got")" "1"
case " $got " in *" c "*) ok "guard kept the option after the token";; *) nok "guard dropped trailing option: $got";; esac
got="$(guard_case 'root=x console=tty0' "")"
eq "guard is a no-op with an empty token" "$(count_token "$got")" "0"

# ---- 4. arm64 never carries it ------------------------------------------
echo "=== arm64 never carries the T2 edge token ==="
eq "arm64 defines no edge-extra constant" "$(grep -c 'NCZ_T2_EDGE_EXTRA_CMDLINE' "$ARM64_SRC" | tr -d ' ')" "0"
eq "arm64 has no pcie_ports=compat"       "$(grep -c 'pcie_ports=compat' "$ARM64_SRC" | tr -d ' ')" "0"
eq "arm64 sources no T2 helper"           "$(grep -c 'ncz-t2-detect' "$ARM64_SRC" | tr -d ' ')" "0"

echo "=== the shipped script wires the token to the edge entry only ==="
eq "literal token assigned exactly once" \
   "$(grep -c 'NCZ_T2_EDGE_EXTRA_CMDLINE="pcie_ports=compat"' "$SRC" | tr -d ' ')" "1"
examined="$(sed -n '/NCZ-T2-CMDLINE-BEGIN/,/NCZ-T2-CMDLINE-END/p' "$SRC")"
eq "token assignment is inside the T2-gated block" \
   "$(printf '%s\n' "$examined" | grep -c 'NCZ_T2_EDGE_EXTRA_CMDLINE="pcie_ports=compat"' | tr -d ' ')" "1"
eq "refresh script points at the shipped T2 helper" \
   "$(grep -c '^NCZ_T2_DETECT_LIB="\$INSTALLER_META/assets/refind/ncz-t2-detect.sh"$' "$SRC" | tr -d ' ')" "1"
eq "refresh script sources the T2 helper" \
   "$(grep -c '^[[:space:]]*\.[[:space:]]*"\$NCZ_T2_DETECT_LIB"$' "$SRC" | tr -d ' ')" "1"
# Exactly one menuentry renders $EDGE_OPTIONS; allow quoting/brace variations.
eq "exactly one menuentry renders \$EDGE_OPTIONS" \
   "$(grep -cE 'options[[:space:]]+\\?"?\$\{?EDGE_OPTIONS\}?\\?"?' "$SRC" | tr -d ' ')" "1"

echo
echo "=== amd64 edge compat test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
