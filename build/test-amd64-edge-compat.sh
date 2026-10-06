#!/bin/bash
# test-amd64-edge-compat.sh -- prove the amd64 T2 edge entry gets
# pcie_ports=compat exactly once while every other boot entry stays free
# of it (operator directive 2026-10-05).
#
# This exercises the REAL option strings out of
# assets/refind/ncz-refind-refresh-amd64.sh: the constant block and the
# STABLE_OPTIONS / STABLE_CONSOLE_OPTIONS / EDGE_OPTIONS / RESCUEPART_OPTIONS
# assembly region are extracted from the shipped script and sourced, so the
# tested code is the shipped code (same style as
# build/test-amd64-kernel-classifier.sh).
#
# Contract asserted:
#   * the token is on the amd64 EDGE options only -- never stable, never
#     stable-console, never rescue;
#   * it is present exactly once after one refresh and after three refreshes
#     (idempotent -- no accumulation);
#   * appending it preserves the operator's own options;
#   * the arm64 refresh script never carries it.
#
# Exit 0 = all checks pass; 1 = one or more failed; 2 = extraction failure.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"
ARM64_SRC="$REPO/assets/refind/ncz-refind-refresh.sh"
[ -f "$SRC" ] || { echo "EXTRACT FAILED: $SRC not found"; exit 2; }
[ -f "$ARM64_SRC" ] || { echo "EXTRACT FAILED: $ARM64_SRC not found"; exit 2; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
nok() { echo "  FAIL  $1"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else nok "$1: got '$2' want '$3'"; fi; }
count_token() { printf '%s' "$1" | grep -o -- 'pcie_ports=compat' | wc -l | tr -d ' '; }

TOKEN="pcie_ports=compat"

# ---- extract the shipped code -------------------------------------------
# The option-assembly, append-guard and T2-cmdline blocks carry explicit
# BEGIN/END markers in the shipped script, so extraction is byte-exact and
# independent of the surrounding shape or indentation.
extract_between() { awk -v b="$2" -v e="$3" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
extract_between "$SRC" 'NCZ-EDGE-OPTIONS-BEGIN' 'NCZ-EDGE-OPTIONS-END' > "$W/region.sh"
extract_between "$SRC" 'NCZ-EDGE-GUARD-BEGIN' 'NCZ-EDGE-GUARD-END' > "$W/guard.sh"
extract_between "$SRC" 'NCZ-T2-CMDLINE-BEGIN' 'NCZ-T2-CMDLINE-END' > "$W/cmdline.sh"
for f in cmdline region guard; do
    [ -s "$W/$f.sh" ] || { echo "EXTRACT FAILED: $W/$f.sh empty (markers missing?)"; exit 2; }
done
grep -q 'EDGE_OPTIONS=' "$W/region.sh" || { echo "EXTRACT FAILED: region has no EDGE_OPTIONS"; exit 2; }
grep -q 'EDGE_AVAILABLE' "$W/region.sh" || { echo "EXTRACT FAILED: region has no EDGE_AVAILABLE branch"; exit 2; }
grep -q 'RESCUEPART_OPTIONS=' "$W/region.sh" || { echo "EXTRACT FAILED: region has no RESCUEPART_OPTIONS"; exit 2; }
grep -q 'case ' "$W/guard.sh" || { echo "EXTRACT FAILED: guard has no case"; exit 2; }

# ---- dynamic: run the real option-assembly region ------------------------
run_region() { # run_region <stable_avail> <edge_avail> <root_opts> <splash>
    local sa="$1" ea="$2" ropts="$3" splash="$4"
    (
        set -uo pipefail
        STABLE_AVAILABLE="$sa"; EDGE_AVAILABLE="$ea"
        ROOT_OPTS="$ropts"
        STABLE_CMDLINE_BASE="console=ttyS0,115200 console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
        SPLASH="$splash"
        RESCUEPART_PARTUUID="1111-2222"
        NCZ_T2_EDGE_EXTRA_CMDLINE="$TOKEN"
        # shellcheck disable=SC1090
        . "$W/region.sh"
        printf 'STABLE_OPTIONS=%s\n' "$STABLE_OPTIONS"
        printf 'STABLE_CONSOLE_OPTIONS=%s\n' "$STABLE_CONSOLE_OPTIONS"
        printf 'EDGE_OPTIONS=%s\n' "$EDGE_OPTIONS"
        printf 'RESCUEPART_OPTIONS=%s\n' "$RESCUEPART_OPTIONS"
    )
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "=== the token is set conditionally inside the T2-gated block ==="
eq "token assigned exactly once" \
   "$(grep -c 'NCZ_T2_EDGE_EXTRA_CMDLINE="pcie_ports=compat"' "$SRC" | tr -d ' ')" "1"
eq "assignment lives in the T2-gated block" \
   "$(grep -c 'NCZ_T2_EDGE_EXTRA_CMDLINE="pcie_ports=compat"' "$W/cmdline.sh" | tr -d ' ')" "1"
eq "the block calls the T2 detector" \
   "$(grep -c 'if ncz_is_t2_hardware; then' "$W/cmdline.sh" | tr -d ' ')" "1"
# The literal token must not be hardcoded anywhere except that assignment;
# the append path goes through the variable. Comment lines are ignored.
eq "literal token only in the assignment (no stray hardcode)" \
   "$(grep -nE '^[^#]*pcie_ports=compat' "$SRC" | grep -v 'NCZ_T2_EDGE_EXTRA_CMDLINE=' | wc -l | tr -d ' ')" "0"

echo "=== default/stable and edge both available (typical boot) ==="
out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3")"
stable="$(field "$out" STABLE_OPTIONS)"
stable_con="$(field "$out" STABLE_CONSOLE_OPTIONS)"
edge="$(field "$out" EDGE_OPTIONS)"
rescue="$(field "$out" RESCUEPART_OPTIONS)"
eq "edge carries the token exactly once" "$(count_token "$edge")" "1"
eq "stable entry has no token" "$(count_token "$stable")" "0"
eq "stable-console entry has no token" "$(count_token "$stable_con")" "0"
eq "rescue entry has no token" "$(count_token "$rescue")" "0"
case " $edge " in *" $TOKEN "*) ok "edge carries the token as a whole word";; *) nok "token not delimited in edge options";; esac

echo "=== operator options are preserved ==="
out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw my_user_opt=1 another=2" "quiet")"
edge="$(field "$out" EDGE_OPTIONS)"
case " $edge " in *" my_user_opt=1 "*) ok "operator option my_user_opt preserved";; *) nok "operator option dropped: $edge";; esac
case " $edge " in *" another=2 "*) ok "operator option another preserved";; *) nok "second operator option dropped: $edge";; esac
eq "edge still carries the token exactly once" "$(count_token "$edge")" "1"

echo "=== three refreshes: token stays exactly once ==="
n=1
while [ "$n" -le 3 ]; do
    out="$(run_region 1 1 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3")"
    edge="$(field "$out" EDGE_OPTIONS)"
    eq "refresh #$n edge token count" "$(count_token "$edge")" "1"
    n=$((n+1))
done

echo "=== edge unavailable: no token anywhere ==="
out="$(run_region 1 0 "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet")"
edge="$(field "$out" EDGE_OPTIONS)"
eq "edge options empty when edge absent" "$edge" ""
eq "no token when edge absent" "$(count_token "$out")" "0"

echo "=== append guard is idempotent (token already present) ==="
guard_case() { # guard_case <initial-EDGE_OPTIONS>
    (
        set -uo pipefail
        EDGE_OPTIONS="$1"
        NCZ_T2_EDGE_EXTRA_CMDLINE="$TOKEN"
        . "$W/guard.sh"
        printf '%s' "$EDGE_OPTIONS"
    )
}
got="$(guard_case 'root=x console=tty0 systemd.unit=multi-user.target')"
eq "guard appends once when absent" "$(count_token "$got")" "1"
case " $got " in *" $TOKEN "*) ok "guard produced a delimited token";; *) nok "guard token not delimited: $got";; esac
got="$(guard_case "root=x console=tty0 $TOKEN systemd.unit=multi-user.target")"
eq "guard does not duplicate an existing token" "$(count_token "$got")" "1"
got="$(guard_case "root=x console=tty0 $TOKEN c")"
eq "guard leaves trailing options intact" "$(count_token "$got")" "1"
case " $got " in *" c "*) ok "guard kept the option after the token";; *) nok "guard dropped trailing option: $got";; esac

echo "=== arm64 never carries the T2 edge token ==="
eq "arm64 defines no edge-extra constant" \
   "$(grep -c 'NCZ_T2_EDGE_EXTRA_CMDLINE' "$ARM64_SRC" | tr -d ' ')" "0"
eq "arm64 has no pcie_ports=compat" \
   "$(grep -c 'pcie_ports=compat' "$ARM64_SRC" | tr -d ' ')" "0"

echo "=== the edge menuentry is the one that renders EDGE_OPTIONS ==="
# Guard against a future refactor that wires the token somewhere else: the
# only entry that renders $EDGE_OPTIONS is the Edge menuentry. Allow the
# usual quoting/brace variations so a harmless reformat is not a failure.
eq "exactly one menuentry renders \$EDGE_OPTIONS" \
   "$(grep -cE 'options[[:space:]]+\\?"?\$\{?EDGE_OPTIONS\}?\\?"?' "$SRC" | tr -d ' ')" "1"

echo
echo "=== amd64 edge compat test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
