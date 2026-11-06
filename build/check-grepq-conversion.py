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
  * whitespace inside a pattern changes.

This checker compares each -/+ pair in a unified diff after a symmetric
normalisation: on BOTH sides every q flag is dropped and every bare
`>/dev/null` is removed. Quoted text is never touched, so if a pattern's text
changed -- including a redirect inserted inside it -- the two sides differ and
the line is reported.

Usage:
    check-grepq-conversion.py DIFF
    check-grepq-conversion.py --self-test

Exit 0 when every grep line is explained, 1 otherwise.
"""
import sys

BARE_REDIRECT = ">/dev/null"


def segments(s):
    """Split into (quoted?, text) so only unquoted text is ever modified."""
    out, buf, i, q, start = [], "", 0, None, 0
    while i < len(s):
        c = s[i]
        if q is None:
            if c in "'\"":
                if buf:
                    out.append((False, buf))
                    buf = ""
                q = c
                start = i
                i += 1
                continue
            buf += c
            i += 1
        else:
            if c == q:
                out.append((True, s[start:i + 1]))
                buf = ""
                q = None
            i += 1
    if q is not None:
        out.append((True, s[start:]))
    if buf:
        out.append((False, buf))
    return out


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


def check_pair(before, after):
    """Return (ok, detail) for one -/+ pair."""
    b, q_before = drop_q(segments(before))
    b, r_before = remove_redirects(b)
    a, q_after = drop_q(segments(after))
    a, r_after = remove_redirects(a)
    bn, an = normalize(b), normalize(a)
    q_removed = q_before - q_after
    r_added = r_after - r_before
    if bn != an:
        return False, "pattern or argument text changed: %r vs %r" % (bn, an)
    if q_removed < 0:
        return False, "a q flag was added, not removed"
    if r_added < 0:
        return False, "a redirect was removed, not added"
    if not (q_removed or r_added):
        return False, "line differs but neither a q nor a redirect explains it"
    return True, "q removed=%d redirects added=%d" % (q_removed, r_added)


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
        if len(minus) != len(plus):
            print("HUNK SKEW %+d -- hunk skipped, pairs not positional"
                  % (len(minus) - len(plus)))
            bad += 1
            continue
        for before, after in zip(minus, plus):
            if "grep" not in before:
                continue
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


SELF_TEST = """diff --git a/x.sh b/x.sh
@@ -1,5 +1,5 @@
-grep -q 'PATTERN' "$f" && ok
+grep 'PATTERN' "$f" >/dev/null && ok
-grep -qF -- "$pkg"; then
+grep -F -- "$pkg" >/dev/null; then
-grep -Eqx "RE" &&
+grep -Ex "RE" >/dev/null &&
-grep -q "a >/dev/null b" "$f"
+grep "a b" "$f" >/dev/null
-grep -q 'keep me' "$f"
+grep 'keep  me' "$f" >/dev/null
"""


def self_test():
    """Three legitimate conversions must pass; two corruptions must be caught."""
    ok, bad = run(SELF_TEST)
    failures = []
    if ok != 3:
        failures.append("expected 3 legitimate conversions to pass, got %d" % ok)
    if bad != 2:
        failures.append("expected 2 corruptions to be caught, got %d" % bad)
    if failures:
        for f in failures:
            print("SELF-TEST FAIL: %s" % f)
        return 1
    print("self-test: 3 conversions accepted, 2 corruptions caught -- good")
    return 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--self-test":
        return self_test()
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-3].strip())
        print("usage: %s DIFF | --self-test" % argv[0])
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as fh:
        ok, bad = run(fh.read())
    print("conversion check: %d ok, %d suspect" % (ok, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
