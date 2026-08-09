"""Scan lore atom feeds for patches that collide with the NCZ Sky1 stack.

Scope is honest about its limits: each feed carries only the 25 most recent
messages, lore's search feeds are Anubis-blocked, and public-inbox git is 403.
There is no way to query 60 days of history from here. What this does instead
is take the current window and flag anything touching a file our 170-patch
series also touches - which is the actual predictor of a painful rebase.

Run it repeatedly to accumulate coverage; that is what kernelwatch should be
doing with the <content> element rather than storing subject lines.
"""
import html
import os
import re
import subprocess
import sys

FEEDS = [
    "linux-acpi",
    "linux-pm",
    "linux-arm-kernel",
    "linux-media",
    "dri-devel",        # panthor / mali / komeda-linlondp live here
    "linux-clk",
    "linux-usb",
]

# Subsystems we carry downstream drivers for. A patch mentioning these is
# interesting even when it touches no file we currently patch, because it may
# be the upstream version of something we fork.
KEYWORDS = ("panthor", "mali", "linlondp", "komeda", "cix", "sky1",
            "amvx", "zhouyi", "cdns3", "cadence")
UA = ("Mozilla/5.0 (X11; Linux x86_64; rv:153.0) "
      "Gecko/20100101 Firefox/153.0")
PDIR = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
    "~/Projects/cix-installer/kernel-source/linux-cix-sky1-ncz/"
    "linux-cix-sky1-ncz-7.2/patches-7.2")

# Every file our series touches.
ours = set()
for fn in os.listdir(PDIR):
    if not fn.endswith(".patch"):
        continue
    for line in open(os.path.join(PDIR, fn), errors="replace"):
        m = re.match(r"^\+\+\+ b/(\S+)", line)
        if m:
            ours.add(m.group(1))
print(f"  our stack touches {len(ours)} distinct files")

hits, scanned = [], 0
for lst in FEEDS:
    url = f"https://lore.kernel.org/{lst}/new.atom"
    raw = subprocess.run(["curl", "-sL", "--max-time", "40", "-A", UA, url],
                         capture_output=True, text=True).stdout
    if "not a bot" in raw or "<entry>" not in raw:
        print(f"  {lst}: blocked or empty")
        continue
    entries = re.findall(r"<entry>(.*?)</entry>", raw, re.S)
    scanned += len(entries)
    for e in entries:
        tm = re.search(r"<title[^>]*>(.*?)</title>", e, re.S)
        cm = re.search(r"<content[^>]*>(.*?)</content>", e, re.S)
        if not tm or not cm:
            continue
        title = html.unescape(tm.group(1)).strip()
        if not title.startswith("[PATCH"):
            continue
        body = html.unescape(re.sub(r"<[^>]+>", "", cm.group(1)))
        touched = set(re.findall(r"^\+\+\+ b/(\S+)", body, re.M))
        overlap = touched & ours
        blob = (title + " " + " ".join(touched)).lower()
        kw = sorted({k for k in KEYWORDS if k in blob})
        if overlap or kw:
            hits.append((lst, title, sorted(overlap), kw))
    print(f"  {lst}: {len(entries)} entries")

print(f"\n  scanned {scanned} messages across {len(FEEDS)} feeds")
print(f"  relevant (file overlap or keyword): {len(hits)}\n")
for lst, title, files, kw in hits:
    tag = ",".join(kw) if kw else "file-overlap"
    print(f"  [{lst}] ({tag}) {title[:78]}")
    for f in files[:3]:
        print(f"        collides: {f}")
