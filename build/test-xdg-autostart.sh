#!/bin/bash
# test-xdg-autostart.sh -- every system XDG autostart entry the hooks install
# must behave as intended under the Singularity session.
#
# The shipped shell starts autostart entries through libsingularity's
# AutostartManager (src/system/autostart_manager.vala, since 2026-10-06): an
# entry in a system XDG_CONFIG_DIRS autostart directory (/etc/xdg/autostart)
# is launched only when it is a Type=Application entry that is not Hidden, not
# X-GNOME-Autostart-enabled=false, has an Exec, passes TryExec, and whose
# OnlyShowIn names Singularity (the session exports
# XDG_CURRENT_DESKTOP=Singularity). An entry without OnlyShowIn=Singularity, or
# with another desktop's name only, is never started.
#
# Two kinds of entry are installed:
#   session   started by the shell at login (notifiers, the first-login tour);
#             MUST pass the rule.
#   fallback  a systemd --user unit is the real mechanism; the .desktop file is
#             kept for desktops that honour XDG autostart. MUST NOT pass the
#             rule, or the program would start twice.
# Any autostart entry a hook writes that is not classified below fails the
# test, so a new entry has to be classified when it is added.
#
# Negative control: the rule is also applied to an OnlyShowIn=XFCE entry and,
# when the git object is available, to the 57-qotd.sh entry of the control
# revision (NCZ_AUTOSTART_CONTROL_REF), which must NOT launch.
#
# Usage: bash build/test-xdg-autostart.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CONTROL_REF="${NCZ_AUTOSTART_CONTROL_REF:-9b7b060c991c33a0aa6f8df38935c0ca6cb20988}"

python3 -I - "$ROOT" "$CONTROL_REF" <<'PY'
import configparser
import os
import re
import subprocess
import sys

root, control_ref = sys.argv[1], sys.argv[2]
passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"ok   {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"FAIL {msg}", file=sys.stderr)


SESSION = {
    "ncz-qotd.desktop": "post-install/57-qotd.sh",
    "ncz-firewall-notice.desktop": "post-install/34-firewall.sh",
    "ncz-update-notifier.desktop": "post-install/50-update-manager.sh",
    "ncz-first-login-tour.desktop": "post-install/51-ncz-tour-slides.sh",
}
FALLBACK = {
    "ncz-wallpaper-rotator.desktop": "post-install/45-wallpaper-rotator.sh",
    "fcitx5-ncz.desktop": "post-install/22-locale-gen.sh",
}
# Entries copied from a tracked file instead of a heredoc.
STATIC = {
    "ncz-update-notifier.desktop": "assets/update-manager/ncz-update-notifier.desktop",
    "ncz-first-login-tour.desktop": "assets/branding/first-login-tour/ncz-first-login-tour.desktop",
}
HEREDOC = re.compile(
    r"cat\s+>\s*\S*/etc/xdg/autostart/([A-Za-z0-9._-]+\.desktop)\s*<<-?\s*'?([A-Za-z0-9_]+)'?\n(.*?)\n\2\n",
    re.S)
REF = re.compile(r"/etc/xdg/autostart/([A-Za-z0-9._*-]+\.desktop)")


def parse(text):
    cp = configparser.RawConfigParser(strict=False, interpolation=None)
    cp.optionxform = str
    cp.read_string(text)
    return dict(cp["Desktop Entry"]) if cp.has_section("Desktop Entry") else {}


def str_list(v):
    return [x for x in v.split(";") if x]


def launches(entry, desktops=("Singularity",)):
    """libsingularity system_entry_should_launch(path, require_only_show_in=true)."""
    def boolean(v):
        return v.strip().lower() == "true"
    if entry.get("Type", "Application") != "Application":
        return False, "Type is not Application"
    if boolean(entry.get("Hidden", "false")):
        return False, "Hidden=true"
    if "X-GNOME-Autostart-enabled" in entry and not boolean(entry["X-GNOME-Autostart-enabled"]):
        return False, "X-GNOME-Autostart-enabled=false"
    if not entry.get("Exec", "").strip():
        return False, "no Exec"
    if "OnlyShowIn" not in entry:
        return False, "no OnlyShowIn (system entries need OnlyShowIn=Singularity)"
    only = str_list(entry["OnlyShowIn"])
    if not any(d in only for d in desktops):
        return False, f"OnlyShowIn={entry['OnlyShowIn']} does not name the current desktop"
    if "Singularity" not in only:
        return False, "OnlyShowIn does not name Singularity"
    if any(d in str_list(entry.get("NotShowIn", "")) for d in desktops):
        return False, "NotShowIn names the current desktop"
    return True, "launched"


# --- collect every autostart entry the hooks write --------------------------
entries, writers, referenced = {}, {}, set()
hooks_dir = os.path.join(root, "post-install")
for name in sorted(os.listdir(hooks_dir)):
    if not name.endswith(".sh"):
        continue
    rel = f"post-install/{name}"
    text = open(os.path.join(hooks_dir, name), encoding="utf-8", errors="replace").read()
    for m in HEREDOC.finditer(text):
        entries[m.group(1)] = m.group(3)
        writers[m.group(1)] = rel
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#") or re.match(r"rm\s", s):
            continue
        for m in REF.finditer(s):
            if "*" not in m.group(1):
                referenced.add(m.group(1))
                writers.setdefault(m.group(1), rel)
for name, path in STATIC.items():
    full = os.path.join(root, path)
    if os.path.isfile(full):
        entries[name] = open(full, encoding="utf-8", errors="replace").read()
    else:
        bad(f"{name}: source file {path} missing")

classified = set(SESSION) | set(FALLBACK)
for name in sorted(referenced | set(entries)):
    if name not in classified:
        bad(f"{name} (written by {writers.get(name, '?')}) is not classified as session or fallback in this test")
for name in sorted(classified):
    if name not in referenced and name not in entries:
        bad(f"{name}: classified here but no hook installs it any more (update the test)")

# --- the rule, per entry ----------------------------------------------------
for name, hook in sorted(SESSION.items()):
    if name not in entries:
        bad(f"{name}: entry content not found")
        continue
    if writers.get(name) != hook:
        bad(f"{name}: expected writer {hook}, found {writers.get(name)}")
    entry = parse(entries[name])
    go, why = launches(entry)
    if go:
        ok(f"{name}: started by the Singularity shell ({hook})")
    else:
        bad(f"{name}: never started by the Singularity shell: {why}")
    exe = entry.get("Exec", "").split()[0] if entry.get("Exec") else ""
    hook_text = open(os.path.join(root, hook), encoding="utf-8", errors="replace").read()
    if exe and exe in hook_text:
        ok(f"{name}: Exec {exe} is installed by {hook}")
    else:
        bad(f"{name}: Exec {exe!r} is not installed by {hook}")

for name, hook in sorted(FALLBACK.items()):
    if name not in entries:
        bad(f"{name}: entry content not found")
        continue
    go, why = launches(parse(entries[name]))
    if go:
        bad(f"{name}: would be started by the shell AND by its systemd user unit ({hook})")
    else:
        ok(f"{name}: fallback entry is not started by the shell ({why})")

# --- negative controls ------------------------------------------------------
go, _ = launches(parse("[Desktop Entry]\nType=Application\nExec=/bin/true\nOnlyShowIn=XFCE;\n"))
if go:
    bad("control: an OnlyShowIn=XFCE entry was treated as launched")
else:
    ok("control: an OnlyShowIn=XFCE entry is not launched")
go, _ = launches(parse("[Desktop Entry]\nType=Application\nExec=/bin/true\nOnlyShowIn=Singularity;\nHidden=true\n"))
if go:
    bad("control: a Hidden=true entry was treated as launched")
else:
    ok("control: a Hidden=true entry is not launched")
try:
    old = subprocess.run(["git", "-C", root, "show", f"{control_ref}:post-install/57-qotd.sh"],
                         capture_output=True, text=True, check=True).stdout
except (OSError, subprocess.CalledProcessError):
    old = None
if old is None:
    print(f"skip control revision {control_ref[:12]} not available in this clone")
else:
    m = {mm.group(1): mm.group(3) for mm in HEREDOC.finditer(old)}
    if "ncz-qotd.desktop" not in m:
        bad("control: 57-qotd.sh at the control revision has no autostart entry")
    elif launches(parse(m["ncz-qotd.desktop"]))[0]:
        bad("control: the control revision's qotd entry was treated as launched (test cannot see the defect)")
    else:
        ok(f"control: the qotd entry at {control_ref[:12]} is not launched (defect detected)")

print(f"# test-xdg-autostart: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
