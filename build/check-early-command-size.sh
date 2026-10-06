#!/bin/bash
# check-early-command-size.sh [preseed.cfg] -- fail if preseed/early_command is too large.
#
# d-i hands the joined early_command string to /bin/preseed_command through a
# debconf `db_get`. Above a size threshold that reply is lost: confmodule reads
# EOF and dies in `return ""` ("preseed_command: return: line 88: Illegal
# number"), early_command never runs, the ext4 install medium is never mounted
# at /cdrom, and d-i stops at "Incorrect installation media detected".
#
# Measured 2026-09-29 (arm64, KVM): 15,634 bytes FAILS; 12.4 KB and 11.5 KB
# install. The exact cliff is somewhere between; the budget below sits just
# above the largest size proven to work, so growth has to be a conscious act
# (move logic into a helper under preseed/ instead, see hostname-suggest.sh).
#
# The joined length is what d-i sees: continuation backslashes removed, leading
# whitespace of continuation lines dropped, lines joined with one space.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CFG="${1:-$ROOT/preseed/preseed.cfg}"
BUDGET="${NCZ_EARLY_COMMAND_BUDGET:-13000}"

[ -r "$CFG" ] || { echo "check-early-command-size: cannot read $CFG" >&2; exit 2; }

len="$(python3 - "$CFG" <<'EOF'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
idx = [i for i, l in enumerate(lines) if l.startswith("d-i preseed/early_command string")]
if len(idx) != 1:
    print("ERR:expected exactly one 'd-i preseed/early_command string' line, found %d" % len(idx))
    sys.exit(0)
k = idx[0]
buf = lines[k].split("string", 1)[1]
parts = []
while True:
    cur = buf.rstrip()
    core = cur[:-1] if cur.endswith("\\") else cur
    if "\\" in core:
        # d-i's cdebconf interprets backslash escapes in a preseeded value
        # (printf's \n became a real newline on 2026-10-06): the stored value
        # ends there with an open quote and the whole command fails to parse.
        print("COMMENT:line %d has a backslash inside the value: %s" % (k + 1, core.strip()[:80]))
        sys.exit(0)
    if cur.endswith("\\"):
        parts.append(cur[:-1])
        k += 1
        buf = lines[k]
    else:
        parts.append(cur)
        break
if cur.strip().startswith("#"):
    # A comment line inside the continued value has no trailing backslash, so
    # it ENDS the value: the shell sees the appended text as a comment and
    # every command after it is silently dropped (2026-10-06: the medium
    # mount never ran; d-i stopped at "Incorrect installation media detected").
    print("COMMENT:line %d ends the value on a comment: %s" % (k + 1, cur.strip()[:80]))
    sys.exit(0)
print(len(" ".join(p.strip() for p in parts).encode("utf-8")))
EOF
)"

case "$len" in
    ERR:*) echo "check-early-command-size: ${len#ERR:}" >&2; exit 2 ;;
    COMMENT:*)
        echo "check-early-command-size: FAIL: preseed/early_command ${len#COMMENT:}" >&2
        echo "check-early-command-size:       d-i drops everything after it; move comments above the d-i line and avoid backslash escapes." >&2
        exit 1 ;;
esac

if [ "$len" -gt "$BUDGET" ]; then
    echo "check-early-command-size: FAIL: preseed/early_command is $len bytes, budget $BUDGET (15,634 is known to break d-i media detection)." >&2
    echo "check-early-command-size:       move logic into a helper script (preseed/*.sh, baked via BAKED_HELPERS) and call it." >&2
    exit 1
fi
echo "check-early-command-size: OK ($len bytes, budget $BUDGET)"
