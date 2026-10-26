#!/bin/bash
# test-early-command-shape.sh -- build/check-early-command-size.sh must refuse
# every preseed/early_command shape that has killed the installer, and must
# accept the real preseed.cfg.
#
# Regression pinned here (2026-10-26, Preview4, both arches, cix-installer
# d9d64be1): nine indented comment lines WITH trailing backslashes inside the
# early_command's Apple-hardware if-block. d-i's loader joins the value into
# one line, so the first "#" commented out everything after it, the `if` was
# never closed, `sh -c` exited 2 with "Syntax error: end of file unexpected
# (expecting "fi")", preseed_command tried to display preseed/command_failed
# with COMMAND=<the value>, and cdebconf 0.283 aborted on the `${...}`
# expansions inside it ("debconf: ./src/question.c:276: lookup_directive:
# Assertion `'!' == directive[0]' failed." then "/bin/preseed_command:
# return: line 88: Illegal number:"). Both KVM gates then timed out with no
# partition table on the target.
#
# Cases (each a minimal preseed written to a scratch dir, plus the real file
# with the d9d64be1 block re-inserted):
#   real        the repository preseed.cfg                       -> OK
#   d9d64be1    the real file with the 2026-10-17 comment block  -> FAIL (COMMENT)
#   comment-bs  "# ..." with trailing backslash inside an if     -> FAIL (COMMENT)
#   comment-end "# ..." without backslash (ends the value)       -> FAIL (COMMENT)
#   col0        column-0 "#" inside the continuation: the loader -> OK
#               drops it before joining, the value survives
#   syntax      unclosed `if`, no comment at all                 -> FAIL (sh -n)
#   escape      printf '...\n' inside the value                  -> FAIL (BACKSLASH)
#   nonzero     last statement is not `true`                     -> FAIL (HAZARD)
#   no-set+e    does not start with `set +e ;`                   -> FAIL (HAZARD)
#   budget      over NCZ_EARLY_COMMAND_BUDGET                    -> FAIL (size)
#   joined      --print-joined of the real file parses under     -> OK
#               dash -n (and busybox sh -n when present) and is
#               exactly one line
#
# With NCZ_DI_INITRD_ROOT=<unpacked netinst initrd> and root (or passwordless
# sudo), build/check-early-command-initrd.sh additionally runs the REAL
# loader chain from the initrd (debconf-set-selections -> db_get -> sh -n)
# in a chroot of a scratch copy; otherwise that part is reported as SKIP.
set -u
cd "$(dirname "$0")/.."
CHECK=build/check-early-command-size.sh
PRESEED=preseed/preseed.cfg
PASS=0; FAIL=0
t="$(mktemp -d "${TMPDIR:-/tmp}/ncz-early-command-shape.XXXXXX")"
trap 'rm -rf "$t"' EXIT

ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1: $2"; }

# expect <case> <0|1> <must-match-regex-on-stderr> <preseed file> [env...]
expect() {
    local name="$1" want="$2" pat="$3" file="$4"; shift 4
    local out rc
    out="$(env "$@" bash "$CHECK" "$file" 2>&1)"; rc=$?
    if [ "$want" = 0 ]; then
        if [ $rc -eq 0 ]; then ok "$name (accepted)"; else bad "$name" "expected OK, rc=$rc: $out"; fi
    else
        if [ $rc -eq 0 ]; then bad "$name" "expected FAIL, got OK: $out"
        elif ! printf '%s' "$out" | grep -qE -- "$pat"; then bad "$name" "failed for the wrong reason (want /$pat/): $out"
        else ok "$name (refused: $(printf '%s' "$out" | head -1 | cut -c1-110))"; fi
    fi
}

mk() {   # mk <file> <<'EOF' body EOF  -- a minimal preseed around the value
    cat > "$1"
}

# --- real file ---------------------------------------------------------------
expect real 0 "" "$PRESEED"

# --- the d9d64be1 block re-inserted into the real file -----------------------
python3 -I - "$PRESEED" "$t/d9d64be1.cfg" <<'EOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read().split("\n")
anchor = [i for i, l in enumerate(src) if "early_command: Apple hardware -- skipping nic-wireless-modules" in l]
assert len(anchor) == 1, anchor
block = [
    "        # Do NOT unbind brcmfmac from the card here even if it is bound anyway \\",
    "        # (initramfs autoload, another loader, or a blacklist that did not \\",
    "        # take): an unbound brcmfmac lets the PCI core drop the T2 BCM4364 to \\",
    "        # D3cold, and this early_command has no counterpart that binds it back \\",
    "        # before the installed system resumes for the first time -- Wi-Fi is \\",
    "        # then gone until reboot (docs/T2-BRCMFMAC-RESUME.md). The blocklist \\",
    "        # plus net-pick.sh's refusal to pick a wireless iface (rank 9) already \\",
    "        # keep netcfg off the radio; build/test-t2-wifi-no-unload.sh fails the \\",
    "        # build if this loop ever unbinds or unloads a wireless driver again. \\",
]
out = src[:anchor[0]] + block + src[anchor[0]:]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out))
EOF
expect d9d64be1 1 "COMMENT|comment inside the value" "$t/d9d64be1.cfg"
# The same file must also fail the pure syntax check if the comment gate were
# ever removed: prove the joined text really does not parse.
python3 -I - "$t/d9d64be1.cfg" "$t/d9d64be1.joined" <<'EOF'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
k = [i for i, l in enumerate(lines) if l.startswith("d-i preseed/early_command string")][0]
parts = []; cur = lines[k].split("string", 1)[1]
while True:
    body = cur.rstrip()
    core = body[:-1] if body.endswith("\\") else body
    parts.append(core.strip())
    if not body.endswith("\\"): break
    k += 1; cur = lines[k]
open(sys.argv[2], "w").write(" ".join(p for p in parts if p) + "\n")
EOF
if dash -n "$t/d9d64be1.joined" 2>/dev/null; then
    bad d9d64be1-dash "the joined d9d64be1 command parses under dash -n; the incident shape no longer reproduces"
else
    ok "d9d64be1-dash (joined command does not parse under dash -n, as in the incident)"
fi

# --- minimal fixtures ----------------------------------------------------------
mk "$t/comment-bs.cfg" <<'EOF'
d-i debian-installer/locale string en_US.UTF-8
d-i preseed/early_command string \
    set +e ; \
    if [ -e /x ] ; then \
        # a comment with a trailing backslash \
        echo hi ; \
    fi ; \
    true
EOF
expect comment-bs 1 "COMMENT|comment inside the value" "$t/comment-bs.cfg"

mk "$t/comment-end.cfg" <<'EOF'
d-i preseed/early_command string \
    set +e ; \
    echo one ; \
    # this comment ends the value
    echo two ; \
    true
EOF
expect comment-end 1 "COMMENT|comment inside the value" "$t/comment-end.cfg"

mk "$t/col0.cfg" <<'EOF'
d-i preseed/early_command string \
    set +e ; \
    if [ -e /x ] ; then \
# a column-0 comment: the loader drops it before joining
        echo hi ; \
    fi ; \
    true
EOF
expect col0 0 "" "$t/col0.cfg"

mk "$t/syntax.cfg" <<'EOF'
d-i preseed/early_command string \
    set +e ; \
    if [ -e /x ] ; then \
        echo hi ; \
    true
EOF
expect syntax 1 "does not parse" "$t/syntax.cfg"

mk "$t/escape.cfg" <<'EOF'
d-i preseed/early_command string \
    set +e ; \
    printf 'a\n' ; \
    true
EOF
expect escape 1 "BACKSLASH|backslash inside the value" "$t/escape.cfg"

mk "$t/nonzero.cfg" <<'EOF'
d-i preseed/early_command string \
    set +e ; \
    echo "${NCZREV:-x}" ; \
    sh /tmp/helper.sh
EOF
expect nonzero 1 "must end with 'true'" "$t/nonzero.cfg"

mk "$t/no-set-e.cfg" <<'EOF'
d-i preseed/early_command string \
    echo "${NCZREV:-x}" ; \
    true
EOF
expect no-set+e 1 "must start with 'set \+e ;'" "$t/no-set-e.cfg"

expect budget 1 "budget" "$PRESEED" NCZ_EARLY_COMMAND_BUDGET=100

# --- the joined real value --------------------------------------------------------
if bash "$CHECK" --print-joined "$PRESEED" > "$t/real.joined"; then
    if [ "$(wc -l < "$t/real.joined")" = 1 ] && dash -n "$t/real.joined" 2>"$t/dash.err"; then
        ok "joined (one line, $(wc -c < "$t/real.joined") bytes, dash -n clean)"
    else
        bad joined "$(cat "$t/dash.err")"
    fi
    if command -v busybox >/dev/null 2>&1; then
        if busybox sh -n "$t/real.joined" 2>"$t/bb.err"; then ok "joined-busybox (busybox sh -n clean)"; else bad joined-busybox "$(cat "$t/bb.err")"; fi
    fi
else
    bad joined "--print-joined failed"
fi

# --- the real loader chain from a netinst initrd (optional) ---------------------
if [ -n "${NCZ_DI_INITRD_ROOT:-}" ]; then
    out="$(bash build/check-early-command-initrd.sh "$NCZ_DI_INITRD_ROOT" "$PRESEED" 2>&1)"; rc=$?
    if [ $rc -eq 77 ]; then
        echo "  SKIP initrd-chain ($out)"
    else
        if [ $rc -eq 0 ]; then ok "initrd-chain real ($(printf '%s' "$out" | tail -1 | cut -c1-100))"; else bad initrd-chain-real "$out"; fi
        out="$(bash build/check-early-command-initrd.sh "$NCZ_DI_INITRD_ROOT" "$t/d9d64be1.cfg" 2>&1)"; rc=$?
        if [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "does not parse"; then
            ok "initrd-chain d9d64be1 (real loader chain stored it and its /bin/sh -n refused it)"
        else
            bad initrd-chain-d9d64be1 "expected the stored incident value to fail /bin/sh -n (rc=1), got rc=$rc: $out"
        fi
    fi
else
    echo "  SKIP initrd-chain (set NCZ_DI_INITRD_ROOT=<unpacked netinst initrd>, needs root or sudo)"
fi

echo "test-early-command-shape: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
