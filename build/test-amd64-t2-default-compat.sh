#!/bin/bash
# test-amd64-t2-default-compat.sh -- prove the amd64 T2 DEFAULT entry gets
# pcie_ports=compat exactly once while every other boot entry stays free of it
# (operator directive 2026-10-05, unified 7.3 policy: the token moved from the
# retired edge entry to the default entry).
#
# This exercises the REAL option strings out of
# assets/refind/ncz-refind-refresh-amd64.sh: the option-assembly, the append
# guard and the T2-cmdline blocks are extracted from the shipped script and
# sourced, so the tested code is the shipped code (same style as
# build/test-amd64-kernel-classifier.sh).
#
# Contract asserted:
#   * the token is on the amd64 DEFAULT options only -- never console, never
#     rescue, never the rescue-partition;
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
extract_between() { awk -v b="$2" -v e="$3" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$1"; }
extract_between "$SRC" 'NCZ-DEFAULT-OPTIONS-BEGIN' 'NCZ-DEFAULT-OPTIONS-END' > "$W/region.sh"
extract_between "$SRC" 'NCZ-DEFAULT-GUARD-BEGIN' 'NCZ-DEFAULT-GUARD-END' > "$W/guard.sh"
extract_between "$SRC" 'NCZ-T2-CMDLINE-BEGIN' 'NCZ-T2-CMDLINE-END' > "$W/cmdline.sh"
for f in cmdline region guard; do
    [ -s "$W/$f.sh" ] || { echo "EXTRACT FAILED: $W/$f.sh empty (markers missing?)"; exit 2; }
done
grep -q 'STABLE_OPTIONS=' "$W/region.sh" || { echo "EXTRACT FAILED: region has no STABLE_OPTIONS"; exit 2; }
grep -q 'RESCUEPART_OPTIONS=' "$W/region.sh" || { echo "EXTRACT FAILED: region has no RESCUEPART_OPTIONS"; exit 2; }
grep -q 'case ' "$W/guard.sh" || { echo "EXTRACT FAILED: guard has no case"; exit 2; }

# ---- dynamic: run the real option-assembly region ------------------------
run_region() { # run_region <root_opts> <splash> [t2]
    local ropts="$1" splash="$2" t2="${3:-1}"
    (
        set -uo pipefail
        STABLE_AVAILABLE=1
        ROOT_OPTS="$ropts"
        STABLE_CMDLINE_BASE="console=ttyS0,115200 console=tty0 systemd.condition_first_boot=false audit_backlog_limit=8192"
        SPLASH="$splash"
        RESCUEPART_PARTUUID="1111-2222"
        if [ "$t2" = "1" ]; then
            NCZ_T2_DEFAULT_EXTRA_CMDLINE="$TOKEN"
            ncz_is_t2_hardware() { return 0; }
        else
            NCZ_T2_DEFAULT_EXTRA_CMDLINE=""
            ncz_is_t2_hardware() { return 1; }
        fi
        # shellcheck disable=SC1090
        . "$W/region.sh"
        printf 'STABLE_OPTIONS=%s\n' "$STABLE_OPTIONS"
        printf 'STABLE_CONSOLE_OPTIONS=%s\n' "$STABLE_CONSOLE_OPTIONS"
        printf 'RESCUE_OPTIONS=%s\n' "$RESCUE_OPTIONS"
        printf 'RESCUEPART_OPTIONS=%s\n' "$RESCUEPART_OPTIONS"
    )
}
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

echo "=== the token is set conditionally inside the T2-gated block ==="
eq "token assigned exactly once" \
   "$(grep -c 'NCZ_T2_DEFAULT_EXTRA_CMDLINE="pcie_ports=compat"' "$SRC" | tr -d ' ')" "1"
eq "assignment lives in the T2-gated block" \
   "$(grep -c 'NCZ_T2_DEFAULT_EXTRA_CMDLINE="pcie_ports=compat"' "$W/cmdline.sh" | tr -d ' ')" "1"
eq "the block calls the T2 detector" \
   "$(grep -c 'if ncz_is_t2_hardware; then' "$W/cmdline.sh" | tr -d ' ')" "1"
eq "literal token only in the assignment (no stray hardcode)" \
   "$(grep -nE '^[^#]*pcie_ports=compat' "$SRC" | grep -v 'NCZ_T2_DEFAULT_EXTRA_CMDLINE=' | wc -l | tr -d ' ')" "0"

echo "=== T2: the default entry carries the token, no other entry does ==="
out="$(run_region "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3" 1)"
stable="$(field "$out" STABLE_OPTIONS)"
stable_con="$(field "$out" STABLE_CONSOLE_OPTIONS)"
rescue="$(field "$out" RESCUE_OPTIONS)"
rescuepart="$(field "$out" RESCUEPART_OPTIONS)"
eq "default entry carries the token exactly once" "$(count_token "$stable")" "1"
eq "console entry has no token" "$(count_token "$stable_con")" "0"
eq "rescue entry has no token" "$(count_token "$rescue")" "0"
eq "rescue-partition entry has no token" "$(count_token "$rescuepart")" "0"
case " $stable " in *" $TOKEN "*) ok "default carries the token as a whole word";; *) nok "token not delimited in default options";; esac

echo "=== non-T2: no token anywhere ==="
out="$(run_region "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet" 0)"
eq "no token when not T2" "$(count_token "$out")" "0"

echo "=== operator options are preserved ==="
out="$(run_region "root=PARTUUID=abc rootwait rootfstype=ext4 rw my_user_opt=1 another=2" "quiet" 1)"
stable="$(field "$out" STABLE_OPTIONS)"
case " $stable " in *" my_user_opt=1 "*) ok "operator option my_user_opt preserved";; *) nok "operator option dropped: $stable";; esac
case " $stable " in *" another=2 "*) ok "operator option another preserved";; *) nok "second operator option dropped: $stable";; esac
eq "default still carries the token exactly once" "$(count_token "$stable")" "1"

echo "=== three refreshes: token stays exactly once ==="
n=1
while [ "$n" -le 3 ]; do
    out="$(run_region "root=PARTUUID=abc rootwait rootfstype=ext4 rw" "quiet loglevel=3" 1)"
    stable="$(field "$out" STABLE_OPTIONS)"
    eq "refresh #$n default token count" "$(count_token "$stable")" "1"
    n=$((n+1))
done

echo "=== append guard is idempotent (token already present) ==="
guard_case() {
    (
        set -uo pipefail
        STABLE_OPTIONS="$1"
        NCZ_T2_DEFAULT_EXTRA_CMDLINE="$TOKEN"
        . "$W/guard.sh"
        printf '%s' "$STABLE_OPTIONS"
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

echo "=== arm64 never carries the T2 token ==="
eq "arm64 defines no T2 constant" \
   "$(grep -c 'NCZ_T2_DEFAULT_EXTRA_CMDLINE' "$ARM64_SRC" | tr -d ' ')" "0"
eq "arm64 has no pcie_ports=compat" \
   "$(grep -c 'pcie_ports=compat' "$ARM64_SRC" | tr -d ' ')" "0"

echo "=== the default menuentry is the one that renders STABLE_OPTIONS ==="
eq "exactly one menuentry renders \$STABLE_OPTIONS" \
   "$(grep -cE 'options[[:space:]]+\\?"?\$\{?STABLE_OPTIONS\}?\\?"?' "$SRC" | tr -d ' ')" "1"

echo
echo "=== amd64 T2 default-compat test: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
