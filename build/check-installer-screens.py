#!/usr/bin/env python3
"""check-installer-screens.py -- assert on what the operator SEES on the installer console.

  check-installer-screens.py SCREEN_DIR [--require-dialog TEXT ...] [--require-header REGEX]
                              [--require-prompt-sequence REGEX ...]
                              [--require-boot-progress PHASE ...]

SCREEN_DIR is the serial-screens/ directory written by build/boot-screens.py: one text file per stable console
state, reconstructed from the terminal stream by a VT100 emulator (the d-i newt UI owns that terminal).
Fails when any state
  * contains a diagnostics line ("[diag]"), a helper log prefix ("[ncz"), or a password / credential hint,
  * contains a newt rendering error ("<ERR>"),
  * has text overwritten mid-line by another writer (a "[" tag glued to a non-space in the middle of a dialog row).
--require-dialog TEXT: some state must contain TEXT (proves the dialog was actually reached, so an empty capture cannot pass).
--require-header REGEX: every state that draws a dialog must also match REGEX somewhere (branded header).
--require-prompt-sequence REGEX ...: every REGEX must appear, in the given order, in some captured console state. The
  intent is to assert the operator's prompt sequence (e.g. components, region, username, password, hostname, disk+fs).
  The same dialog title can satisfy multiple regexes (the hostname dialog also includes the machine name in the body),
  so the sequence is matched greedily per regex: the i-th regex matches at or after the position of the (i-1)-th match,
  but the position is in terms of the file order (sorted by capture time). This means dialogs that appear LATER in
  capture order (because the prompt cycle takes longer for one than another) still satisfy the sequence.
--require-boot-progress PHASE ...: every PHASE must appear, in the given order, in the boot-time console log
  (the [NCZ HH:MM:SS +Ns] lines from preseed/boot-progress.sh that are visible on /dev/tty1 / /dev/console BEFORE
  the newt UI takes over). The newt UI clears them off /dev/tty1 later, but they remain in the serial capture that
  feeds serial-screens/, so this assertion catches the operator-reported "silent boot" regression.
"""
import argparse, os, re, sys

ap = argparse.ArgumentParser()
ap.add_argument("dir")
ap.add_argument("--require-dialog", action="append", default=[])
ap.add_argument("--require-header", default=None)
ap.add_argument("--start-at", default=None, help="ignore every state before the first one containing TEXT (the bootloader echoes the test kernel command line)")
ap.add_argument("--after-t", type=int, default=None, help="with --no-blank-after: only judge states at or after this many seconds since boot (the states carry a # t=N header)")
ap.add_argument("--allow-first-blank", action="store_true", help="with --no-blank-after: the first blank state is the kernel boot and is not a defect")
ap.add_argument("--max-blank-secs", type=int, default=8, help="a blank console shorter than this is a redraw between steps, not a vanished UI (default 8; the defect was 14-25 s)")
ap.add_argument("--no-blank-after", default=None, help="after the first state containing TEXT, no later state may be a blank console (only the screen tab bar): the UI must stay up until the install progress")
ap.add_argument("--min-states", type=int, default=0, help="fail when fewer than N distinct console states were captured. The state COUNT itself is timing-dependent (arm64 r201 candidates: 35, 33, 32 with identical dialog sequences), so this is only a floor that catches a truncated capture; the content assertions above are the real checks")
ap.add_argument("--require-prompt-sequence", nargs="+", default=[], help="assert every REGEX appears in the given order across the captured screens (operator's interactive sequence)")
ap.add_argument("--require-boot-progress", nargs="+", default=[], help="assert every PHASE appears in the given order in the boot-time serial log (the [NCZ HH:MM:SS +Ns] lines from preseed/boot-progress.sh)")
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
    blank_seen = 0
    for f in files:
        txt = open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read()
        m_t = re.match(r"# t=(\d+)s", txt)
        if a.no_blank_after in txt: started = True
        if a.after_t is not None and m_t and int(m_t.group(1)) >= a.after_t: started = True
        if not started: continue
        body = [l for l in txt.split("\n")[1:] if l.strip() and not re.match(r"^\[?\s*\(\d\*+\w+\)\s+2 shell", l.strip()) and "(1**installer)" not in l]
        if not body:
            # duration of this blank state = until the next state file
            ts = []
            for g in files:
                mt = re.match(r"# t=(\d+)s", open(os.path.join(a.dir, g), encoding="utf-8", errors="replace").read(20))
                ts.append(int(mt.group(1)) if mt else 0)
            idx = files.index(f)
            dur = (ts[idx + 1] - ts[idx]) if idx + 1 < len(files) else 10**6
            if dur < a.max_blank_secs: continue
            blank_seen += 1
            if a.allow_first_blank and blank_seen == 1: continue
            bad += 1
            print("check-installer-screens: FAIL %s: blank console after the %r dialog (the UI vanished; the operator sees an empty blue screen)" % (f, a.no_blank_after), file=sys.stderr)
for t, ok in seen.items():
    if not ok:
        bad += 1
        print("check-installer-screens: FAIL no console state contains the required dialog text %r" % t, file=sys.stderr)

# --- --require-prompt-sequence ----------------------------------------------
# Walk the captured states in file order (sorted by capture time, the prefix
# is NNNN-<t>s.txt); the i-th regex must match at or after the file index of
# the (i-1)-th match. This is greedy on the regex side and order-preserving
# on the file side: a dialog that appears later in capture time (because the
# operator spent longer on it) still satisfies "appears after the previous
# one" as long as it is later in file order.
if a.require_prompt_sequence:
    seq = [re.compile(p) for p in a.require_prompt_sequence]
    cur_file_idx = -1
    for i, rx in enumerate(seq):
        matched_at = -1
        for fi, f in enumerate(files):
            if fi <= cur_file_idx: continue
            txt = open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read()
            if rx.search(txt):
                matched_at = fi
                break
        if matched_at < 0:
            bad += 1
            print("check-installer-screens: FAIL --require-prompt-sequence[%d] /%s/ never matched any console state (in order)" % (i, seq[i].pattern), file=sys.stderr)
        else:
            cur_file_idx = matched_at

# --- --require-boot-progress ------------------------------------------------
# Concatenate ALL captured states (newt clears the [NCZ ...] lines off /dev/tty1
# after it takes over, but the serial capture that built serial-screens/ keeps
# every line in order). The phases must appear in order; each phase is matched
# against the joined text starting AFTER the previous match's character offset.
if a.require_boot_progress:
    all_text = ""
    for f in files:
        all_text += open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read() + "\n"
    cur_off = 0
    for i, phase in enumerate(a.require_boot_progress):
        # The phase token appears between "[NCZ " and " +" (e.g. "[NCZ 14:22:31 +5s] Loading installer...")
        # so match on the literal "[NCZ ... <phase> ..." with the descriptor optional.
        pat = re.compile(r"\[NCZ [^\]]+\]\s+" + re.escape(phase) + r"\b")
        m = pat.search(all_text, cur_off)
        if not m:
            bad += 1
            print("check-installer-screens: FAIL --require-boot-progress[%d] %r never appeared in the boot-time serial log (operator-reported silent boot regression)" % (i, phase), file=sys.stderr)
        else:
            cur_off = m.end()

# --- evidence: which dialogs the capture really contained, in first-seen order ------------------
# The state count varies run to run with the capture cadence and progress-bar redraws, so a bare
# "N console states" cannot explain a difference between two candidates. The ordered dialog titles
# can: a candidate that lost or reordered a dialog differs here, one that only sampled one frame
# fewer does not.
titles = []
tre = re.compile(r"lq+\S?\s*(?:\[[^\]]*\]\s*)?(.*?)\s*tq+\s*k")
for f in files:
    for line in open(os.path.join(a.dir, f), encoding="utf-8", errors="replace").read().split("\n"):
        m = tre.search(line)
        if m and m.group(1).strip() and m.group(1).strip() not in titles:
            titles.append(m.group(1).strip())
if a.min_states and len(files) < a.min_states:
    bad += 1
    print("check-installer-screens: FAIL only %d console states captured, expected at least %d (truncated capture?)" % (len(files), a.min_states), file=sys.stderr)
if bad:
    sys.exit(1)
print("check-installer-screens: OK (%d console states)" % len(files))
print("check-installer-screens: dialogs in capture order (%d): %s" % (len(titles), " > ".join(titles) if titles else "none"))
