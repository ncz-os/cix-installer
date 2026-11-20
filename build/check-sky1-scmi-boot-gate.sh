#!/usr/bin/env bash
# check-sky1-scmi-boot-gate.sh - kernel-side SCMI boot gate (Sky1/O6N).
#
# Per ORCHESTRATOR 2026-11-11 16:00Z (O6N rc2 root cause: the SCMI Tx mailbox
# double-bind that leaves clk-sky1-acpi unprobed and GPU/DPU deferred), a
# Sky1 kernel boot journal must show
#   - "ACPI: activating SCMI protocol"   (arm-scmi activated the protocols)
#   - "clk-sky1-acpi" ... "Mapped"       (ACPI clocks mapped, exact case:
#                                         "No SCMI clocks mapped yet" must
#                                         NOT count as mapped)
# and must show ZERO
#   - "mailbox not free"                 (the double-bind signature)
#
# Part of the kernel acceptance checklist ("KVM gate" step): run it against
# the KVM boot journal of any Sky1 kernel build before staging a one-shot
# O6N boot entry.
#
# Usage: check-sky1-scmi-boot-gate.sh <journal-or-dmesg-file>
# Exit 0 = gate PASS, 1 = gate FAIL, 2 = usage/unreadable input.
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <journal-or-dmesg-file>" >&2
    exit 2
fi
FILE="$1"
if [ ! -r "$FILE" ]; then
    echo "FAIL: cannot read $FILE" >&2
    exit 2
fi

rc=0

if grep -q "ACPI: activating SCMI protocol" "$FILE"; then
    echo "PASS: SCMI protocols activated (ACPI: activating SCMI protocol)"
else
    echo "FAIL: 'ACPI: activating SCMI protocol' not found (arm-scmi did not activate protocols)"
    rc=1
fi

if grep "clk-sky1-acpi" "$FILE" | grep -q "Mapped"; then
    echo "PASS: clk-sky1-acpi mapped ACPI clocks"
else
    echo "FAIL: 'clk-sky1-acpi ... Mapped' not found (CIXHA010 unprobed; GPU/DPU will defer)"
    rc=1
fi

if grep -q "mailbox not free" "$FILE"; then
    echo "FAIL: 'mailbox not free' present (SCMI Tx mailbox double-bind)"
    rc=1
else
    echo "PASS: zero 'mailbox not free'"
fi

exit "$rc"
