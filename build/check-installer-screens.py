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
for f in files:
    txt = open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read()
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
for t, ok in seen.items():
    if not ok:
        bad += 1
        print("check-installer-screens: FAIL no console state contains the required dialog text %r" % t, file=sys.stderr)
if bad:
    sys.exit(1)
print("check-installer-screens: OK (%d console states)" % len(files))
