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
ap.add_argument("--boot-blank-max-secs", type=int, default=0, help="with --no-blank-after: when the marker is in the FIRST captured state (the bootloader frame), the blank state right after it is the kernel and initrd load, not a vanished UI; allow it up to N seconds (default 0 = off). Every later blank is judged by --max-blank-secs")
ap.add_argument("--no-blank-after", default=None, help="after the first state containing TEXT, no later state may be a blank console (only the screen tab bar): the UI must stay up until the install progress")
ap.add_argument("--min-states", type=int, default=0, help="fail when fewer than N distinct console states were captured. The state COUNT itself is timing-dependent (arm64 r201 candidates: 35, 33, 32 with identical dialog sequences; the 2026-10-27 Preview4 candidate: 14, also complete), so this is only a floor that catches a truncated capture; the content assertions above are the real checks. Pick N from the dialog COUNT the harness is guaranteed to capture (one stable state per answered dialog, boot-screens.py pump()), not from a particular run's cadence")
ap.add_argument("--require-prompt-sequence", nargs="+", default=[], help="assert every REGEX appears in the given order across the captured screens (operator's interactive sequence)")
ap.add_argument("--require-boot-progress", nargs="+", default=[], help="assert every PHASE appears in the given order in the boot-time serial log (the [NCZ HH:MM:SS +Ns] lines from preseed/boot-progress.sh)")
ap.add_argument("--min-dialogs", type=int, default=0, help="fail unless at least N distinct dialog titles were extracted from the captured states (proves the dialog order is real; a capture whose frames could not be parsed fails instead of printing 'none')")
ap.add_argument("--last-state-matches", default=None, help="fail unless the LAST captured state matches REGEX. The --min-states floor counts all captured files, including repeated states of one long phase, so it can pass a capture that ended early WHILE STILL CONTAINING every dialog; this check pins the capture's end point. The 8bf4e6e9 gate (2026-10-27): a cut right after the erase confirmation left 13 of 14 states with all 10 dialogs present, which the floor alone cannot catch; a complete run's final state is the install progress dialog, so pin that")
ap.add_argument("--require-login-line", default=None, help="assert at least one captured primary-console state shows the installer diagnostics login line matching REGEX (preseed/ncz-ui.sh ncz_ui_diag_login; docs/RECOVERY-LOGINS.md)")
a = ap.parse_args()

# The capture harness renders the d-i newt UI through pyte, which turns the terminal's ACS line-drawing set into
# Unicode box characters; the older fixtures (and slang on a raw terminal) use the ACS letters. Everything below
# matches the ACS letters, so normalise once on read. r201: without this every frame regex was dead on real
# captures: the header check never fired and the dialog list always printed "none".
BOX = str.maketrans("\u250c\u2510\u2514\u2518\u2500\u2502\u251c\u2524\u252c\u2534\u253c", "lkmjqxtuwvn")
def rd(path, n=-1):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read(n).translate(BOX)

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
    txt = rd(os.path.join(a.dir, f))
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
    # d-i's own progress dialogs ("Installing the base system", a bar and "N%") are not NCZ prompts and carry no brand.
    if hdr and re.search(r"[lk]q{5,}|lu .* tk|x .* x", txt) and not re.search(r"x\s+\d{1,3}%\s+x", txt) and not hdr.search(txt):
        bad += 1
        print("check-installer-screens: FAIL %s: dialog without the branded header /%s/" % (f, a.require_header), file=sys.stderr)
if a.no_blank_after:
    started = False
    start_idx = None
    blank_seen = 0
    for f in files:
        txt = rd(os.path.join(a.dir, f))
        m_t = re.match(r"# t=(\d+)s", txt)
        if a.no_blank_after in txt: started = True
        if a.after_t is not None and m_t and int(m_t.group(1)) >= a.after_t: started = True
        if not started: continue
        if start_idx is None: start_idx = files.index(f)
        body = [l for l in txt.split("\n")[1:] if l.strip() and not re.match(r"^\[?\s*\(\d\*+\w+\)\s+2 shell", l.strip()) and "(1**installer)" not in l]
        if not body:
            # duration of this blank state = until the next state file
            ts = []
            for g in files:
                mt = re.match(r"# t=(\d+)s", rd(os.path.join(a.dir, g), 20))
                ts.append(int(mt.group(1)) if mt else 0)
            idx = files.index(f)
            dur = (ts[idx + 1] - ts[idx]) if idx + 1 < len(files) else 10**6
            if dur < a.max_blank_secs: continue
            # The kernel and initrd load right after the bootloader frame: only that one state, and only when judging
            # started at the very first capture, is bounded by --boot-blank-max-secs instead.
            if a.boot_blank_max_secs and start_idx == 0 and idx == 1 and dur <= a.boot_blank_max_secs:
                print("check-installer-screens: note %s: %d s blank after the bootloader frame (kernel and initrd load; limit %d s)" % (f, dur, a.boot_blank_max_secs))
                continue
            blank_seen += 1
            if a.allow_first_blank and blank_seen == 1: continue
            bad += 1
            print("check-installer-screens: FAIL %s: blank console after the %r dialog (the UI vanished; the operator sees an empty blue screen)" % (f, a.no_blank_after), file=sys.stderr)
def joined(t):
    # box borders off and wrapped lines joined: an 80-column console wraps the login line
    # ("... diagnostics login: root / set by" / "ncz_diag_pw"), in dialog titles and the banner alike
    return re.sub(r"\s+", " ", re.sub("[\u2500-\u257f|]", " ", t))
if a.require_login_line:
    lrx = re.compile(a.require_login_line)
    def raw(path):  # rd() maps the box characters to their ACS letters; joined() needs them as they are
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    nlogin = sum(1 for f in files if lrx.search(rd(os.path.join(a.dir, f))) or lrx.search(joined(raw(os.path.join(a.dir, f)))))
    if nlogin == 0:
        bad += 1
        print("check-installer-screens: FAIL no console state shows the diagnostics login line /%s/" % a.require_login_line, file=sys.stderr)
    else:
        print("check-installer-screens: diagnostics login line shown in %d of %d console states" % (nlogin, len(files)))
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
            txt = rd(os.path.join(a.dir, f))
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
        all_text += rd(os.path.join(a.dir, f)) + "\n"
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
# A newt title bar is a whole frame line: l qqq u TITLE t qqq k (a long title leaves no q's, "lu TITLE tk").
# Anchored, with the box structure required, so body text containing an "l" ... "t k" is never read as a title.
tre = re.compile(r"^\s*l(?:q*u(?=\s)|q{3,})\s*(?:\[[^\]]*\]\s*)?(\S.*?)\s+tq*\s*k\s*$")
for f in files:
    lines = rd(os.path.join(a.dir, f)).split("\n")
    for line in lines:
        m = tre.search(line)
        if m and m.group(1).strip() and m.group(1).strip() not in titles:
            titles.append(m.group(1).strip())
frames = sum(1 for f in files if re.search(r"[lk]q{5,}|lu .* tk", rd(os.path.join(a.dir, f))))
if frames and not titles:
    bad += 1
    print("check-installer-screens: FAIL %d console state(s) draw a dialog frame but NO dialog title could be parsed from any of them (the title extraction is broken for this capture; the dialog order is unverified)" % frames, file=sys.stderr)
if a.min_dialogs and len(titles) < a.min_dialogs:
    bad += 1
    print("check-installer-screens: FAIL only %d dialog title(s) extracted (%s), expected at least %d" % (len(titles), " > ".join(titles) or "none", a.min_dialogs), file=sys.stderr)
if a.min_states and len(files) < a.min_states:
    bad += 1
    print(f"check-installer-screens: FAIL only {len(files)} console states captured, expected at least {a.min_states} (truncated capture?)", file=sys.stderr)
# --- --last-state-matches: pin the capture's END point ---------------------------------
# The --min-states floor counts all captured files, including the repeated states one long
# install phase emits, so it cannot by itself distinguish a complete capture from one that
# stopped early while still holding every dialog. A complete desktop run always ends inside
# the install progress phase (the screen goes blank at shutdown, and pump() stops writing
# stable states once the screen stops changing), so its final state carries the install
# progress dialog. Judging ONLY the last state: a cut right after the erase confirmation
# leaves the final state as the erase review and fails here.
#
# "Last" means the LATEST recorded capture time, not the last name in sorted order: every
# state carries a `# t=<N>s` header (the harness' own capture clock), and a name with a
# non-zero-padded second field (e.g. 14-00138s.txt) sorts lexicographically FIRST while
# being chronologically LAST, so files[-1] would judge the wrong state. Select by the
# recorded timestamp; fall back to sorted order when no state carries a header.
if a.last_state_matches:
    if not files:
        # No captured state at all: the end point cannot be judged. Report it instead of
        # indexing files[-1] (IndexError) -- a directory of zero states is always a
        # truncation, and the --min-states floor (when supplied) says so too.
        bad += 1
        print("check-installer-screens: FAIL --last-state-matches /%s/ requested but no console state was captured (the capture is empty; truncated?)" % a.last_state_matches, file=sys.stderr)
    else:
        lrx = re.compile(a.last_state_matches)
        keyed = []
        for f in files:
            mt = re.match(r"# t=(\d+)s", rd(os.path.join(a.dir, f), 20))
            keyed.append((int(mt.group(1)) if mt else None, f))
        timed = [k for k in keyed if k[0] is not None]
        if timed:
            # latest capture time wins; ties broken by name order (deterministic)
            last = max(timed, key=lambda k: (k[0], k[1]))[1]
        else:
            last = files[-1]  # no state carries a # t= header: fall back to sorted order
        if not lrx.search(rd(os.path.join(a.dir, last))):
            bad += 1
            print("check-installer-screens: FAIL the last captured state %s does not match /%s/ (the capture ended before the install progress; truncated?)" % (last, a.last_state_matches), file=sys.stderr)
if bad:
    sys.exit(1)
print("check-installer-screens: OK (%d console states)" % len(files))
if titles:
    print(f"check-installer-screens: dialogs in capture order ({len(titles)}): {' > '.join(titles)}")
else:
    print("check-installer-screens: dialogs in capture order (0): NOT EXTRACTED -- this capture has no dialog text (framebuffer-only sampling); the dialog order was NOT verified", file=sys.stderr)
    print("check-installer-screens: dialogs in capture order (0): NOT VERIFIED")
