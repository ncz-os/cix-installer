#!/bin/bash
# check-early-command-size.sh [--print-joined] [preseed.cfg]
#   -- fail if preseed/early_command cannot survive d-i's preseed loader.
#
# d-i joins the backslash-continued value exactly as preseed-common's
# /usr/bin/debconf-set-selections does (1.127, lines 42-53 of the script in
# the netinst initrd): whole-line "#" comments at column 0 and blank lines are
# dropped first, every remaining line loses its leading whitespace, a line
# ending in "\" loses that backslash and is joined to the next with ONE
# space, and the first line without a trailing backslash ends the value. The
# joined string is one physical line; /bin/preseed_command hands it to
# `sh -c`.
#
# Shapes this gate refuses, each one a real installer-killing incident:
#
#   * SIZE: above a threshold the db_get reply is lost, confmodule reads EOF
#     and dies in `return ""` ("preseed_command: return: line 88: Illegal
#     number"). Measured 2026-09-29 (arm64, KVM): 15,634 bytes FAILS; 12.4 KB
#     and 11.5 KB install. The budget sits just above the largest size proven
#     to work, so growth has to be a conscious act (move logic into a helper
#     under preseed/ instead, see hostname-suggest.sh).
#   * COMMENT inside the value, either shape:
#       - without a trailing backslash it ENDS the value: every command after
#         it is silently dropped (2026-10-06: the medium mount never ran and
#         d-i stopped at "Incorrect installation media detected");
#       - WITH a trailing backslash it is joined into the one-line command, so
#         "#" comments out every command after it on that line -- that is
#         ALL of them. 2026-10-26 (Preview4, both arches): nine such lines
#         inside an if-block left the `if` unclosed, `sh -c` failed with
#         "Syntax error: end of file unexpected (expecting "fi")", and d-i
#         tried to show preseed/command_failed with COMMAND=<this value>.
#         cdebconf 0.283 asserts on that (see HAZARD below) and the installer
#         hung at the first screen.
#   * BACKSLASH anywhere but the line end: `echo` in the loader interprets
#     escapes, so printf's \n became a real newline on 2026-10-06 and the
#     stored value stopped there (unterminated quote, nothing runs).
#   * SYNTAX: the joined command must parse (`sh -n`) under dash and, when
#     present, busybox ash (the installer's /bin/sh). A command that does not
#     parse never runs and trips the HAZARD below.
#   * HAZARD: this value contains shell `${...}` expansions. When the command
#     exits non-zero, /bin/preseed_command does
#     `db_subst preseed/command_failed COMMAND "$command"` and displays the
#     question; cdebconf 0.283 expands "${COMMAND}" and then re-scans the
#     result for `${!directive}` (src/question.c question_get_field ->
#     strexpand -> lookup_directive, which asserts '!' == directive[0]).
#     Any `${x}` from this value aborts the debconf frontend: "debconf:
#     ./src/question.c:276: lookup_directive: Assertion `'!' ==
#     directive[0]' failed." -- no error dialog, the install just hangs. So
#     the command must never return non-zero: it runs under `set +e` and its
#     LAST statement must be `true` (or `exit 0`). This gate pins that.
#
# --print-joined prints the joined one-line command (what d-i stores) and
# exits 0 without checking; build/test-early-command-shape.sh and
# build/check-early-command-initrd.sh use it.
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PRINT_JOINED=0
if [ "${1:-}" = "--print-joined" ]; then PRINT_JOINED=1; shift; fi
CFG="${1:-$ROOT/preseed/preseed.cfg}"
BUDGET="${NCZ_EARLY_COMMAND_BUDGET:-13000}"

[ -r "$CFG" ] || { echo "check-early-command-size: cannot read $CFG" >&2; exit 2; }

# Join exactly as the loader does and report structural faults. Output is one
# line "KIND:detail" followed, for KIND=OK, by the joined command.
# join_value KEY -> that report for one preseed key (KIND=ABSENT when the file
# has no such line).
join_value() {
python3 -I - "$CFG" "$1" <<'EOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
name = sys.argv[2]
key = re.escape(name)
lines = text.split("\n")
idx = [i for i, l in enumerate(lines) if re.match(r"^\s*d-i\s+" + key + r"\s+string(\s|$)", l)]
if not idx:
    print("ABSENT:no 'd-i %s string' line" % name)
    sys.exit(0)
if len(idx) != 1:
    print("ERR:expected exactly one 'd-i %s string' line, found %d" % (name, len(idx)))
    sys.exit(0)
k = idx[0]
# The loader's view of the file: `grep -v '^#\|^[[:space:]]*$'` (column-0
# comments and blank lines vanish BEFORE continuation is evaluated), CR dropped.
first = re.sub(r"^\s*d-i\s+" + key + r"\s+string\s*", "", lines[k].replace("\r", ""))
cur = first
parts = []
n = k
while True:
    body = cur.rstrip()
    core = body[:-1] if body.endswith("\\") else body
    stripped = core.strip()
    if n != k and stripped.startswith("#"):
        # An indented comment inside the value (a column-0 one never reaches
        # here: the loader drops it before joining). Either shape is fatal.
        shape = ("joined into the one-line command (its '#' comments out every command after it)"
                 if body.endswith("\\") else "ends the value (every command after it is dropped)")
        print("COMMENT:line %d is a comment inside the value and %s: %s" % (n + 1, shape, stripped[:80]))
        sys.exit(0)
    if "\\" in core:
        print("BACKSLASH:line %d has a backslash inside the value (the loader's echo interprets escapes): %s" % (n + 1, stripped[:80]))
        sys.exit(0)
    parts.append(stripped)
    if not body.endswith("\\"):
        break
    # continuation: next loader-visible line
    n += 1
    while n < len(lines) and (lines[n].startswith("#") or lines[n].strip() == ""):
        n += 1
    if n >= len(lines):
        print("ERR:line %d continues past the end of the file" % (n))
        sys.exit(0)
    cur = lines[n].replace("\r", "")
# The loader keeps "d-i preseed/early_command string" as the first joined
# part and rest_line() strips it, so an empty first part is dropped and the
# rest is joined with single spaces.
if parts and parts[0] == "":
    parts = parts[1:]
joined = " ".join(parts)
print("OK:%d" % len(joined.encode("utf-8")))
print(joined)
EOF
}
report="$(join_value preseed/early_command)"

kind="${report%%:*}"
detail="${report#*:}"
detail="${detail%%$'\n'*}"
joined="${report#*$'\n'}"

case "$kind" in
    ERR|ABSENT) echo "check-early-command-size: $detail" >&2; exit 2 ;;
    COMMENT|BACKSLASH)
        echo "check-early-command-size: FAIL: preseed/early_command $detail" >&2
        echo "check-early-command-size:       move comments above the d-i line (see the header of this script); no backslash anywhere but the line end." >&2
        exit 1 ;;
    OK) ;;
    *) echo "check-early-command-size: unexpected parser output: ${report:0:200}" >&2; exit 2 ;;
esac

if [ "$PRINT_JOINED" = 1 ]; then
    printf '%s\n' "$joined"
    exit 0
fi

len="$detail"
if [ "$len" -gt "$BUDGET" ]; then
    echo "check-early-command-size: FAIL: preseed/early_command is $len bytes, budget $BUDGET (15,634 is known to break d-i media detection)." >&2
    echo "check-early-command-size:       move logic into a helper script (preseed/*.sh, baked via BAKED_HELPERS) and call it." >&2
    exit 1
fi

# SYNTAX: the joined one-liner must parse in every shell that may run it.
tmp="$(mktemp "${TMPDIR:-/tmp}/ncz-early-command.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$joined" > "$tmp"
shells=""
for sh_cmd in "dash" "busybox sh" "/bin/sh"; do
    set -- $sh_cmd
    command -v "$1" >/dev/null 2>&1 || continue
    [ "$1" = /bin/sh ] && [ -n "$shells" ] && continue   # /bin/sh only as a last resort
    if ! err="$($sh_cmd -n "$tmp" 2>&1)"; then
        echo "check-early-command-size: FAIL: the joined preseed/early_command does not parse under '$sh_cmd -n':" >&2
        echo "check-early-command-size:       ${err//$tmp/early_command}" >&2
        echo "check-early-command-size:       (d-i runs it as one line via sh -c; a parse error exits 2, and cdebconf 0.283 then aborts on the error dialog -- see the HAZARD note in this script)" >&2
        exit 1
    fi
    shells="$shells ${1##*/}"
done

# HAZARD: the command must not be able to return non-zero (see header).
if ! printf '%s' "$joined" | grep -qE '(^|;|&&|\|\|)[[:space:]]*(true|exit 0)[[:space:]]*$'; then
    echo "check-early-command-size: FAIL: the joined preseed/early_command must end with 'true' (or 'exit 0')." >&2
    echo "check-early-command-size:       a non-zero exit makes d-i display preseed/command_failed with COMMAND=<this value>, and cdebconf 0.283 asserts on the \${...} expansions it contains (lookup_directive, question.c:276): the installer hangs instead of showing the error." >&2
    exit 1
fi
if ! printf '%s' "$joined" | grep -qE '(^|;)[[:space:]]*set \+e[[:space:]]*;'; then
    echo "check-early-command-size: FAIL: the joined preseed/early_command must start with 'set +e ;' (same reason: it must never return non-zero)." >&2
    exit 1
fi

# The other preseed commands are ALLOWED to fail: partman/early_command exits
# non-zero on purpose when the operator declines the erase confirmation (or the
# chooser aborts), and preseed/late_command exits with late.sh's status. Each
# failure displays preseed/command_failed with COMMAND=<the value>, so the
# HAZARD above applies in full: a `${...}` in the value aborts the debconf
# frontend instead of showing the error. 2026-10-26 (Preview4 arm64 UI check):
# the chooser aborted, partman/early_command's "${_blk#/sys}" crashed cdebconf
# and d-i fell back to the syslog window. Same joiner rules, no `${`, and the
# joined value must parse.
others=""
for key in partman/early_command preseed/late_command; do
    r="$(join_value "$key")"
    k="${r%%:*}"; d="${r#*:}"; d="${d%%$'\n'*}"; j="${r#*$'\n'}"
    case "$k" in
        ABSENT) continue ;;
        ERR) echo "check-early-command-size: $d" >&2; exit 2 ;;
        COMMENT|BACKSLASH)
            echo "check-early-command-size: FAIL: $key $d" >&2
            exit 1 ;;
        OK) ;;
        *) echo "check-early-command-size: unexpected parser output for $key: ${r:0:200}" >&2; exit 2 ;;
    esac
    if printf '%s' "$j" | grep -qF '${'; then
        echo "check-early-command-size: FAIL: $key contains a \${...} expansion: $(printf '%s' "$j" | grep -oE '\$\{[^}]*\}' | head -3 | tr '\n' ' ')" >&2
        echo "check-early-command-size:       it can exit non-zero; d-i then shows preseed/command_failed with COMMAND=<this value> and cdebconf 0.283 asserts on \${...} (lookup_directive, question.c:276), so the installer frontend dies instead of showing the error. Use \$var, or move the logic into a preseed/*.sh helper." >&2
        exit 1
    fi
    printf '%s\n' "$j" > "$tmp"
    for sh_cmd in "dash" "busybox sh"; do
        set -- $sh_cmd
        command -v "$1" >/dev/null 2>&1 || continue
        if ! err="$($sh_cmd -n "$tmp" 2>&1)"; then
            echo "check-early-command-size: FAIL: the joined $key does not parse under '$sh_cmd -n': ${err//$tmp/$key}" >&2
            exit 1
        fi
    done
    others="$others $key"
done

echo "check-early-command-size: OK ($len bytes, budget $BUDGET; parses under:${shells}; ends with true; no \${...} in:${others:- (none present)})"
