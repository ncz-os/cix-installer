"""Check newly added lines in a zero-context Git diff."""

import re
import sys

FLEET = re.compile(
    r"(?<![a-z0-9])(?:[a]rgonas|[h]ydra|[t]yphon|[u]ltra|[c]himera|"
    r"[p]egasus|[m]edusa|[p]roteus|[d]ell|[t]ydeus|[c]erberus|"
    r"[a]chilles|[m]inos|[p]ythia)(?:\d+)?(?![a-z0-9])|"
    r"\b[c]ixmini_\d+\b|192[.]168[.]207[.]|/home/[j]asonperlow\b|[.]api_keys[_]master\b|"
    r"\bfleet[_]test_hosts\b|\bssh[p]ass\b|\bkey[ -]master\b|"
    r"\b[a-z0-9][a-z0-9-]*[.](?:lan|local|internal)\b",
    re.IGNORECASE,
)
HARDWARE = re.compile(
    r"\b(?:[d]ell (?:(?:Inc\.?|Technologies|Computer Corporation)\b|"
    r"(?:XPS|Latitude|Precision|OptiPlex|Inspiron|PowerEdge)\b)|"
    r"(?:Core(?:\(TM\))?|Samsung Galaxy) [u]ltra\b)",
    re.IGNORECASE,
)
THIRD_PARTY = (
    "assets/kernel/mali/",
    "assets/kernel/mali-70012/",
    "assets/kernel/aipu/",
)


def added_lines(diff):
    path = ""
    number = None
    for line in diff:
        line = line.rstrip("\n")
        if line.startswith("diff --git "):
            path = ""
            number = None
        elif number is None and line.startswith("+++ "):
            path = line[6:].removesuffix("\t") if line.startswith("+++ b/") else ""
        elif line.startswith("@@ "):
            number = int(re.search(r" \+(\d+)", line).group(1))
        elif number is not None and line.startswith("+"):
            yield path, number, line[1:]
            number += 1
        elif number is not None and line.startswith(" "):
            number += 1


def flagged(line):
    return FLEET.search(HARDWARE.sub("", line)) is not None


def main():
    count = 0
    for path, number, line in added_lines(sys.stdin):
        if path and not path.startswith(THIRD_PARTY) and flagged(line):
            print(f"{path}:{number}: internal reference")
            count += 1
    print(f"Internal-reference check: {count} added lines flagged")
    return int(count > 0)


if __name__ == "__main__":
    sys.exit(main())
