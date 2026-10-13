#!/bin/bash
# check-no-ubuntu.sh -- hard gate: no Ubuntu deb, archive or userland
# (2026-10-08: "We shouldn't be using Ubuntu debs ever").
#
# Offline, fast, no snapshot index (run by `make lint-platform`). It fails on:
#   SRC   a non-comment line in the build/install sources that names an Ubuntu
#         archive, PPA, ubuntu:* container image or an Ubuntu default
#   BIN   a tracked ELF under assets/ whose BusyBox banner, GCC .comment or
#         package note names an Ubuntu build
#   DEB   any .deb/.udeb under the scanned trees whose control data is
#         Ubuntu-built (Maintainer "Ubuntu Developers" / lists.ubuntu.com, or a
#         version containing "ubuntu"), and any rootfs/status/Packages given
#         with ID=ubuntu / ID_LIKE=ubuntu / UBUNTU_CODENAME / ubuntu apt sources
# The stricter "every package is NCZ, a reviewed vendor deb, or byte-identical
# to the pinned Debian forky snapshot" check is build/check-forky-provenance.sh.
#
# Usage: build/check-no-ubuntu.sh [forky-provenance.py scan args...]
#   (default scan: the git-tracked deb payloads under assets/)
#   e.g. --debs build/libdrm-debs --rootfs /path/to/rootfs --packages Packages.xz
# NCZ_NO_UBUNTU_ROOT overrides the repository root (unit tests).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${NCZ_NO_UBUNTU_ROOT:-$(cd "$HERE/.." && pwd)}"
BAD=0

# --- SRC: banned archive/default patterns in non-comment lines -----------------
PAT='(ports|archive|security|old-releases|us\.archive|[a-z]{2}\.archive)\.ubuntu\.com|ubuntu-ports|launchpad(content)?\.net|ppa\.launchpad|(^|[ "=:/])ubuntu:[0-9]|^FROM[[:space:]]+(docker\.io/library/)?ubuntu|NCZ_BASE_NAME:-Ubuntu|\bresolute\b'
# Reviewed exclusions: tests/fixtures (they must name Ubuntu to test the gate),
# this gate, and docs/history. Vendor repos are listed in manifests/vendor-repos.tsv.
list_files() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && [ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$ROOT" && pwd -P)" ]; then
        git -C "$ROOT" ls-files -- build post-install preseed docker scripts tools packaging release.conf Makefile manifests
    else
        (cd "$ROOT" && find build post-install preseed docker scripts tools packaging manifests release.conf Makefile -type f 2>/dev/null)
    fi
}
while IFS= read -r f; do
    case "$f" in
        build/test-*|build/testdata/*|build/fixtures/*|build/check-no-ubuntu.sh|build/forky-provenance.py|build/check-forky-provenance.sh) continue ;;
        manifests/vendor-repos.tsv|manifests/vendor-debs.tsv|manifests/keys/*) continue ;;
        *.deb|*.udeb|*.png|*.svg|*.xz|*.zst|*.gz|*.bin) continue ;;
    esac
    [ -f "$ROOT/$f" ] || continue
    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        echo "FAIL  [SRC] $f:$hit"
        BAD=$((BAD + 1))
    done < <(grep -nIEH --binary-files=without-match "$PAT" "$ROOT/$f" 2>/dev/null \
                | sed "s|^$ROOT/$f:||" \
                | awk -F: '{ line=$0; sub(/^[0-9]+:/, "", line); if (line !~ /^[[:space:]]*#/) print $0 }' \
                | cut -c1-200)
done < <(list_files)

# --- BIN: committed ELF binaries (static tools, kernel modules) built by Ubuntu --
# A committed binary records where it was built: a distro BusyBox banner
# ("BusyBox v1.36.1 (Ubuntu 1:1.36.1-6ubuntu3.1)"), the GCC .comment of a
# module or program ("GCC: (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0"), or an
# ELF package note ({"type":"deb","os":"ubuntu",...}). Any of these in a
# tracked ELF under assets/ is Ubuntu evidence. Debian builds read "(Debian ...)".
list_assets() {
    if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && [ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$ROOT" && pwd -P)" ]; then
        git -C "$ROOT" ls-files -z -- assets
    else
        (cd "$ROOT" && find assets -type f -print0 2>/dev/null)
    fi
}
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    echo "FAIL  [BIN] $hit"
    BAD=$((BAD + 1))
done < <(list_assets | python3 -I -c '
import os, re, sys
root = sys.argv[1]
pat = re.compile(rb"\"os\":\"ubuntu\"|\(Ubuntu [0-9][^)\n]{0,80}ubuntu[^)\n]{0,40}\)")
for rel in sys.stdin.buffer.read().split(b"\0"):
    if not rel:
        continue
    path = os.path.join(root.encode(), rel)
    try:
        with open(path, "rb") as f:
            if f.read(4) != b"\x7fELF":
                continue
            f.seek(0)
            m = pat.search(f.read())
    except OSError:
        continue
    if m:
        print(rel.decode(errors="replace") + ": Ubuntu-built ELF (" + m.group(0).decode(errors="replace") + ")")
' "$ROOT")

# --- DEB / rootfs: delegate to the provenance tool in Ubuntu-only mode ---------
ARGS=("$@")
[ ${#ARGS[@]} -gt 0 ] || ARGS=(--debs "$ROOT/assets")
python3 -I "$HERE/forky-provenance.py" --ubuntu-only "${ARGS[@]}" || BAD=$((BAD + 1))

if [ "$BAD" -gt 0 ]; then
    echo "check-no-ubuntu: FAIL ($BAD finding group(s))" >&2
    exit 1
fi
echo "check-no-ubuntu: OK"
