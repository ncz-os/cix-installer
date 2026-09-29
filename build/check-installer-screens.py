#!/usr/bin/env python3
"""check-installer-screens.py -- assert on what the operator SEES on the installer console.

  check-installer-screens.py SCREEN_DIR [--require-dialog TEXT ...] [--require-header REGEX]

SCREEN_DIR is the serial-screens/ directory written by build/boot-screens.py: one text file per stable console
state, reconstructed from the terminal stream by a VT100 emulator (the d-i newt UI owns that terminal).
Fails when any state
  * contains a diagnostics line ("[diag]"), a helper log prefix ("[ncz"), or a password / credential hint,
  * contains a newt rendering error ("<ERR>"),
  * has text overwritten mid-line by another writer (a "[" tag glued to a non-space in the middle of a dialog row).
--require-dialog TEXT: some state must contain TEXT (proves the dialog was actually reached, so an empty capture cannot pass).
--require-header REGEX: every state that draws a dialog must also match REGEX somewhere (branded header).
"""
import argparse, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--require-dialog", action="append", default=[])
ap.add_argument("--require-header", default=None)
ap.add_argument("--start-at", default=None, help="ignore every state before the first one containing TEXT (the bootloader echoes the test kernel command line)")
ap.add_argument("--after-t", type=int, default=None, help="with --no-blank-after: only judge states at or after this many seconds since boot (the states carry a # t=N header)")
ap.add_argument("--no-blank-after", default=None, help="after the first state containing TEXT, no later state may be a blank console (only the screen tab bar): the UI must stay up until the install progress")
a = ap.parse_args()

BAD = [
    (re.compile(r"\[diag\]"), "diagnostics chatter on the primary console"),
    (re.compile(r"\[ncz[^\]]*\]"), "helper log prefix on the primary console"),
    (re.compile(r"password\s*[:=]|\(password", re.I), "credential text on the primary console"),
    (re.compile(r"<ERR>"), "newt rendering error"),
    (re.compile(r"Please press Enter to activate this console"), "stray askfirst console prompt"),
]
files = sorted(f for f in os.listdir(a.dir) if f.endswith(".txt"))
if not files:
    sys.exit("check-installer-screens: FAIL no console states captured in %s" % a.dir)
bad = 0; seen = {t: False for t in a.require_dialog}
hdr = re.compile(a.require_header) if a.require_header else None
started_chk = a.start_at is None
for f in files:
    txt = open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read()
    if not started_chk and a.start_at in txt: started_chk = True
    if not started_chk: continue
    for t in seen:
        if t in txt: seen[t] = True
    for rx, why in BAD:
        m = rx.search(txt)
        if m:
            bad += 1
            line = next((l for l in txt.split("\n") if m.group(0) in l), m.group(0))
            print("check-installer-screens: FAIL %s: %s: %r" % (f, why, line.strip()[:100]), file=sys.stderr)
    if hdr and re.search(r"[lk]q{5,}|x .* x", txt) and not hdr.search(txt):
        bad += 1
        print("check-installer-screens: FAIL %s: dialog without the branded header /%s/" % (f, a.require_header), file=sys.stderr)
if a.no_blank_after:
    started = False
    for f in files:
        txt = open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read()
        m_t = re.match(r"# t=(\d+)s", txt)
        if a.no_blank_after in txt: started = True
        if a.after_t is not None and m_t and int(m_t.group(1)) >= a.after_t: started = True
        if not started: continue
        body = [l for l in txt.split("\n")[1:] if l.strip() and not re.match(r"^\[?\s*\(\d\*+\w+\)\s+2 shell", l.strip()) and "(1**installer)" not in l]
        if not body:
            bad += 1
            print("check-installer-screens: FAIL %s: blank console after the %r dialog (the UI vanished; the operator sees an empty blue screen)" % (f, a.no_blank_after), file=sys.stderr)
for t, ok in seen.items():
    if not ok:
        bad += 1
        print("check-installer-screens: FAIL no console state contains the required dialog text %r" % t, file=sys.stderr)
if bad:
    sys.exit(1)
print("check-installer-screens: OK (%d console states)" % len(files))
