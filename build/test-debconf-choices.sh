#!/bin/sh
# test-debconf-choices.sh -- every NCZ debconf select/multiselect template keeps VALUES in Choices-C: and the
# operator-facing LABELS in Choices:. cdebconf returns the Choices-C entry from db_get and matches Default:
# against it; swapping the two made the disk chooser reject its own answer and the component dialog record
# "none" (2026-10-17, CHIMERA). Static: literal Choices-C entries must be single tokens, and variable ones must
# not be one of the known label lists.
set -u
cd "$(dirname "$0")/.."
TMPF=$(mktemp "${TMPDIR:-$PWD}/choices.XXXXXX"); : > "$TMPF"
fail=0; n=0
for f in preseed/*.sh; do
    grep -n '^Choices-C:' "$f" | while IFS= read -r line; do
        val=${line#*Choices-C: }
        case "$val" in
            *'${LABELS}'*|*'${_CHOICES_C}'*|*'${CHOICES_LABELS}'*)
                echo "FAIL $f:${line%%:*}: Choices-C carries a label list ($val)"; echo x >> "$TMPF" ;;
            *'$'*) : ;;
            *)  echo "$val" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | while IFS= read -r tok; do
                    case "$tok" in *' '*|*'('*) echo "FAIL $f:${line%%:*}: Choices-C entry '$tok' is a label, not a value"; echo x >> "$TMPF" ;; esac
                done ;;
        esac
    done
    c=$(grep -c '^Choices-C:' "$f"); l=$(grep -c '^Choices:' "$f")
    [ "$c" -le "$l" ] || { echo "FAIL $f: $c Choices-C lines but only $l Choices lines"; fail=1; }
    n=$((n + c))
done
[ -s "${TMPF}" ] && fail=1
rm -f "$TMPF"
[ "$n" -ge 4 ] || { echo "FAIL: expected at least 4 Choices-C templates, found $n"; fail=1; }
[ $fail = 0 ] && echo "test-debconf-choices: OK ($n templates)"
exit $fail
