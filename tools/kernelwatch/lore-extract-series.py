"""Extract the ACPI CPPC v3 series from a lore atom feed.

The atom <content> element carries the entire message including the diff, so
the feed is a complete source for the patches - no /raw or mbox needed, both of
which Anubis blocks.

Writes each patch as a git-am-able file. Reports which of the 15 are present:
the feed only holds the 25 most recent messages, so a series can be partially
rolled off and that has to be visible rather than silently producing a short
series.
"""
import html
import os
import re
import sys

FEED = sys.argv[1]
OUT = sys.argv[2]
os.makedirs(OUT, exist_ok=True)

text = open(FEED, encoding="utf-8", errors="replace").read()
entries = re.findall(r"<entry>(.*?)</entry>", text, re.S)

found = {}
for e in entries:
    tm = re.search(r"<title[^>]*>(.*?)</title>", e, re.S)
    cm = re.search(r"<content[^>]*>(.*?)</content>", e, re.S)
    if not tm or not cm:
        continue
    title = html.unescape(tm.group(1)).strip()

    # Only the v3 patches themselves; skip replies, which begin with "Re:".
    m = re.match(r"\[PATCH v3 (\d+)/15\]\s*(.+)", title)
    if not m:
        continue
    num = int(m.group(1))
    if num == 0 or num in found:
        continue

    body = html.unescape(re.sub(r"<[^>]+>", "", cm.group(1)))
    found[num] = (title, body)

print(f"  entries in feed: {len(entries)}")
print(f"  v3 patches found: {len(found)} of 15")

missing = [n for n in range(1, 16) if n not in found]
if missing:
    print(f"  MISSING from feed: {missing}")

for num, (title, body) in sorted(found.items()):
    slug = re.sub(r"[^a-z0-9]+", "-", m2.lower()).strip("-")[:60] \
        if (m2 := re.sub(r"^ACPI: CPPC: ", "", title.split("] ", 1)[-1])) else f"patch{num}"
    path = os.path.join(OUT, f"{num:04d}-acpi-cppc-{slug}.patch")
    with open(path, "w") as fh:
        fh.write(body if body.endswith("\n") else body + "\n")
    has_diff = "diff --git" in body or "@@" in body
    print(f"    {num:02d}  {'diff' if has_diff else 'NO-DIFF'}  {len(body):>6}B  {slug[:52]}")
