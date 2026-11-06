#!/usr/bin/env python3
"""Prove a `grep -q` -> `grep ... >/dev/null` conversion changed nothing but the q.

`grep -q` in a pipe is a pipefail hazard: grep exits at the first match, the
producer gets EPIPE, and `set -o pipefail` turns a successful match into a
failure. The fix is to drop -q and send stdout to /dev/null, which keeps the
exit status identical. A blind text transform can get this wrong in ways that
still parse and still pass a lint:

  * the redirect lands INSIDE a quoted pattern, silently changing what the test
    looks for;
  * a whole flag token is mangled (-qF, -Eqx, -qai);
  * whitespace inside a pattern changes;
  * a q is dropped with no redirect added, or vice versa.

The check pairs each -/+ line by simple command. Inside a command, the text must
be identical once q flags and bare null-redirects are normalised away, and the
number of q flags removed must equal the number of redirects added.

The scanner respects single quotes (no escapes inside), double quotes (backslash
escapes), unquoted backslash escapes, and `#` comments, and it does not mistake
the `&` of `2>&1` / `>&2` for a command separator.

Usage:
    check-grepq-conversion.py DIFF
    check-grepq-conversion.py --self-test

Exit 0 when every grep line is explained, 1 otherwise.
"""
import sys

BARE_REDIRECT = ">/dev/null"
BS = chr(92)


def scan(line):
    """Return [(is_quoted, text)] with comments dropped and escapes kept verbatim."""
    segs, buf, i = [], "", 0
    n = len(line)

    def flush():
        nonlocal buf
        if buf:
            segs.append((False, buf))
            buf = ""

    while i < n:
        c = line[i]
        if c in "'\"":
            flush()
            j = i + 1
            quoted = c
            while j < n:
                if line[j] == BS and c == '"' and j + 1 < n:
                    quoted += line[j:j + 2]
                    j += 2
                    continue
                quoted += line[j]
                if line[j] == c:
                    j += 1
                    break
                j += 1
            segs.append((True, quoted))
            i = j
            continue
        if c == BS and i + 1 < n:
            buf += line[i:i + 2]
            i += 2
            continue
        if c == "#" and (i == 0 or line[i - 1] in " \t"):
            break                                   # comment: rest of line ignored
        buf += c
        i += 1
    flush()
    return segs


def collapse(t):
    res, prev_space = [], False
    for c in t:
        if c in " \t":
            if not prev_space:
                res.append(" ")
            prev_space = True
        else:
            res.append(c)
            prev_space = False
    out = "".join(res)
    for punct in ";|&)":
        out = out.replace(" " + punct, punct)
    return out


def normalize(segs):
    return "".join(t if isq else collapse(t) for isq, t in segs).strip()


def drop_q(segs):
    """Drop q from every unquoted grep flag cluster. Returns (segs, count)."""
    out, n = [], 0
    for isq, t in segs:
        if not isq:
            pos = 0
            while True:
                idx = t.find("grep", pos)
                if idx == -1:
                    break
                k = idx + 4
                while k < len(t) and t[k] in " \t":
                    k += 1
                if k < len(t) and t[k] == "-":
                    e = k
                    while e < len(t) and (t[e].isalnum() or t[e] == "-"):
                        e += 1
                    flag = t[k:e]
                    if "q" in flag:
                        newflag = flag.replace("q", "")
                        if newflag in ("", "-"):
                            t = t[:k] + t[e:]
                        else:
                            t = t[:k] + newflag + t[e:]
                        n += 1
                        pos = idx + 4
                        continue
                pos = idx + 4
        out.append((isq, t))
    return out, n


def remove_redirects(segs):
    """Remove every unquoted bare '>/dev/null' (never '2>/dev/null')."""
    out, n = [], 0
    for isq, t in segs:
        if not isq:
            i = 0
            while True:
                i = t.find(BARE_REDIRECT, i)
                if i == -1:
                    break
                if i > 0 and t[i - 1].isdigit():
                    i += len(BARE_REDIRECT)
                    continue
                t = t[:i] + t[i + len(BARE_REDIRECT):]
                n += 1
        out.append((isq, t))
    return out, n


def split_commands(segs):
    """Split at unquoted shell operators: && || ; | |& and a lone & (not 2>&1)."""
    pieces, buf = [], ""
    prev = ""                                        # last character emitted
    for isq, t in segs:
        if isq:
            buf += t
            prev = t[-1] if t else prev
            continue
        i = 0
        while i < len(t):
            c = t[i]
            two = t[i:i + 2]
            if two in ("&&", "||"):
                pieces.append(buf); buf = ""
                prev = "&" if two == "&&" else "|"
                i += 2
                continue
            if two == "|&":
                pieces.append(buf); buf = ""
                prev = "&"
                i += 2
                continue
            if c in ";|":
                pieces.append(buf); buf = ""
                prev = c
                i += 1
                continue
            if c == "&":
                # `>&2` and `2>&1` are redirections, not separators
                before = t[i - 1] if i > 0 else prev
                after = t[i + 1] if i + 1 < len(t) else ""
                if before == ">" or after == ">":
                    buf += c
                    prev = c
                    i += 1
                    continue
                pieces.append(buf); buf = ""
                prev = c
                i += 1
                continue
            buf += c
            prev = c
            i += 1
    pieces.append(buf)
    return [p for p in pieces if p.strip()]


def is_candidate_pair(before, after):
    """True when either side looks like a grep that could have been converted."""
    return is_candidate(before) or is_candidate(after)


def is_candidate(line):
    """True when a line either has a piped grep or a grep carrying a q flag.

    A filename that merely contains "grep" (build/test-pipefail-grep.sh) is not a
    candidate, and neither is a line without any grep.
    """
    if "grep" not in line:
        return False
    if "|" in line:
        return True
    if BARE_REDIRECT in line:
        return True                 # already carries the redirect being checked
    _, q = drop_q(scan(line))
    return q > 0


def check_pair(before, after):
    """One conversion per simple command: q removed <=> redirect added."""
    bp = split_commands(scan(before))
    ap = split_commands(scan(after))
    if len(bp) != len(ap):
        return False, ("command structure changed: %d simple command(s) -> %d"
                       % (len(bp), len(ap)))
    total_q = total_r = 0
    for bcmd, acmd in zip(bp, ap):
        b1, q_before = drop_q(scan(bcmd))
        b1, r_before = remove_redirects(b1)
        a1, q_after = drop_q(scan(acmd))
        a1, r_after = remove_redirects(a1)
        bn, an = normalize(b1), normalize(a1)
        q_removed = q_before - q_after
        r_added = r_after - r_before
        if bn != an:
            return False, ("pattern or argument text changed in %r: %r vs %r"
                           % (bcmd.strip()[:60], bn, an))
        if q_removed != r_added:
            return False, ("unpaired change in %r: %d q flag(s) removed but "
                           "%d redirect(s) added" % (bcmd.strip()[:60],
                                                     q_removed, r_added))
        if q_removed < 0 or r_added < 0:
            return False, ("a q flag was added or a redirect removed in %r"
                           % bcmd.strip()[:60])
        total_q += q_removed
        total_r += r_added
    if not (total_q or total_r):
        return False, "line differs but no q/redirect change explains it"
    return True, "q removed=%d redirects added=%d" % (total_q, total_r)


def hunks(text):
    cur = []
    for raw in text.splitlines():
        if raw.startswith("diff ") or raw.startswith("@@"):
            if cur:
                yield cur
            cur = []
        elif raw.startswith("---") or raw.startswith("+++"):
            continue
        else:
            cur.append(raw)
    if cur:
        yield cur


def run(text, verbose=False):
    ok = bad = 0
    for h in hunks(text):
        minus = [l[1:] for l in h if l.startswith("-")]
        plus = [l[1:] for l in h if l.startswith("+")]
        if not minus:
            continue                    # pure additions (new files) have no pair
        if len(minus) != len(plus):
            # unequal counts: pair by content, so a converted line inside an
            # otherwise skewed hunk is still verified rather than skipped
            used = [False] * len(plus)
            unpaired = 0
            for before in minus:
                if not is_candidate(before):
                    continue          # only removed lines can be verified here
                matched = False
                for idx, after in enumerate(plus):
                    if used[idx]:
                        continue
                    good, detail = check_pair(before, after)
                    if good:
                        used[idx] = True
                        ok += 1
                        matched = True
                        if verbose:
                            print("  OK   %s" % detail)
                        break
                if not matched:
                    unpaired += 1
                    bad += 1
                    print("  BAD  no counterpart explains this line")
                    print("     - %s" % before.strip()[:160])
            if unpaired == 0:
                continue
            continue
        for before, after in zip(minus, plus):
            if not is_candidate_pair(before, after):
                continue              # no grep here to convert
            good, detail = check_pair(before, after)
            if good:
                ok += 1
                if verbose:
                    print("  OK   %s" % detail)
            else:
                bad += 1
                print("  BAD  %s" % detail)
                print("     - %s" % before.strip()[:160])
                print("     + %s" % after.strip()[:160])
    return ok, bad


# Good pairs: 1 plain, 2 multi-letter flag clusters, 1 with 2>&1, 1 with an
# escaped double quote inside the pattern. Bad pairs: redirect inside a quoted
# pattern, pattern whitespace changed, q lost its redirect, redirect appeared
# without a q, and a comment carrying a phantom q.
SELF_TEST = """diff --git a/x.sh b/x.sh
@@ -1,12 +1,12 @@
-grep -q 'PATTERN' "$f" && ok
+grep 'PATTERN' "$f" >/dev/null && ok
-grep -qF -- "$pkg"; then
+grep -F -- "$pkg" >/dev/null; then
-grep -Eqx "RE" &&
+grep -Ex "RE" >/dev/null &&
-vm 2>&1 | grep -q 'booted'
+vm 2>&1 | grep 'booted' >/dev/null
-grep -q "a @BS@"b@BS@" c" "$f"
+grep "a @BS@"b@BS@" c" "$f" >/dev/null
-grep -q "a >/dev/null b" "$f"
+grep "a b" "$f" >/dev/null
-grep -q 'keep me' "$f"
+grep 'keep  me' "$f" >/dev/null
-grep -q 'lost its redirect' "$f"
+grep 'lost its redirect' "$f"
-grep 'gained a redirect' "$f"
+grep 'gained a redirect' "$f" >/dev/null
-grep 'no q here' "$f" >/dev/null  # was grep -q 'x'
+grep 'no q here' "$f" >/dev/null
-grep 'stderr kept' "$f" >&2
+grep 'stderr kept' "$f" >&2 >/dev/null
""".replace("@BS@", BS)

GOOD_EXPECTED = 5
BAD_EXPECTED = 6


def self_test():
    ok, bad = run(SELF_TEST.replace("@@", "@@"))
    failures = []
    if ok != GOOD_EXPECTED:
        failures.append("expected %d legitimate conversions to pass, got %d"
                        % (GOOD_EXPECTED, ok))
    if bad != BAD_EXPECTED:
        failures.append("expected %d corruptions to be caught, got %d"
                        % (BAD_EXPECTED, bad))
    if failures:
        for f in failures:
            print("SELF-TEST FAIL: %s" % f)
        return 1
    print("self-test: %d conversions accepted, %d corruptions caught -- good"
          % (GOOD_EXPECTED, BAD_EXPECTED))
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print("usage: %s DIFF | --self-test" % argv[0])
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as fh:
        ok, bad = run(fh.read())
    print("conversion check: %d ok, %d suspect" % (ok, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
