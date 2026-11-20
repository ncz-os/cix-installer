#!/usr/bin/env bash
# Tests for build/check-sky1-scmi-boot-gate.sh.
#
# Both-directions proof (Duty-2 rule 3): an rc1-shaped journal must PASS and
# an rc2-shaped journal (the O6N 2026-11-11 'mailbox not free' regression)
# must FAIL, as must each missing required pattern on its own. The fixtures
# use the exact O6N boot-journal lines from the 15:30Z/16:00Z evidence.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$REPO_ROOT/build/check-sky1-scmi-boot-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- (a) rc1-shaped journal -> PASS -----------------------------------------
cat >"$TMP/good.log" <<'EOF'
ACPI: activating SCMI protocol 0x11
ACPI: activating SCMI protocol 0x15
clk-sky1-acpi: Mapped 207 ACPI clock lookup entries
EOF
bash "$GATE" "$TMP/good.log" >/dev/null \
    || fail "(a) rc1-shaped journal must PASS"
echo "PASS (a): rc1-shaped journal passes"

# --- (b) rc2-shaped journal (mailbox not free) -> FAIL ----------------------
cat >"$TMP/bad.log" <<'EOF'
arm-scmi arm-scmi.2.auto: scmi_protocol scmi_dev.3: __mbox_bind_client: mailbox not free
arm-scmi arm-scmi.2.auto: failed to request SCMI Tx mailbox
arm-scmi arm-scmi.2.auto: failed to setup channel for protocol:0x18
clk-sky1-acpi: No SCMI clocks mapped yet
EOF
if bash "$GATE" "$TMP/bad.log" >/dev/null 2>&1; then
    fail "(b) rc2-shaped journal (mailbox not free) must FAIL"
fi
echo "PASS (b): rc2-shaped journal (mailbox not free) fails"

# --- (c) missing SCMI activation -> FAIL ------------------------------------
printf 'clk-sky1-acpi: Mapped 207 ACPI clock lookup entries\n' >"$TMP/noprot.log"
if bash "$GATE" "$TMP/noprot.log" >/dev/null 2>&1; then
    fail "(c) missing 'ACPI: activating SCMI protocol' must FAIL"
fi
echo "PASS (c): missing SCMI activation fails"

# --- (d) missing clk-sky1-acpi Mapped -> FAIL -------------------------------
printf 'ACPI: activating SCMI protocol 0x11\n' >"$TMP/noclk.log"
if bash "$GATE" "$TMP/noclk.log" >/dev/null 2>&1; then
    fail "(d) missing 'clk-sky1-acpi ... Mapped' must FAIL"
fi
echo "PASS (d): missing clk-sky1-acpi Mapped fails"

# --- (e) usage error exits non-zero -----------------------------------------
if bash "$GATE" >/dev/null 2>&1; then
    fail "(e) usage error must exit non-zero"
fi
echo "PASS (e): usage error exits non-zero"

echo "sky1-scmi-boot-gate tests: 5 passed, 0 failed"
