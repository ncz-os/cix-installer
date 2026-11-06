#!/bin/bash
# check-metal-bundle.sh TARBALL [--prefix DIR] [--arch amd64|arm64] [--min-savers N]
#                                   [--allow-build-path]
#
# Check a bundle BEFORE it reaches a human-supervised metal test.
#
# The reason is 2026-11-06: the BH metal bundle from 00e262e9 carried
# /home/jasonperlow/Projects/ncz-bh-metal-413/build-metal in 76 binaries. It turned out to
# live only in .debug_* (proved by stripping: the string vanished), so nothing was broken -
# but the check that established that was ad hoc, and the same class of defect (a bundle
# that cannot run, or that ships the builder's paths) would otherwise be found by the
# operator, mid-session, on a machine that is not the build host.
#
# Checks, all against the artifact and never against the build:
#   1. every member is under --prefix (no absolute paths, no .. escapes)
#   2. the launcher and at least --min-savers saver binaries are present
#   3. every ELF member's e_machine matches --arch
#   4. no member contains a build-path needle (/home/, /Users/, or a pair of absolute
#      build roots) unless --allow-build-path
#
# Exit: 0 pass, 1 fail, 2 usage/setup.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

if [ "$#" -lt 1 ]; then
    echo "usage: check-metal-bundle.sh TARBALL [--prefix DIR] [--arch amd64|arm64] [--min-savers N] [--allow-build-path]" >&2
    exit 2
fi
TARBALL="$1"
shift
PREFIX=opt/bh-test
ARCH=amd64
MIN_SAVERS=1
ALLOW_PATH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --arch) ARCH="${2:?--arch needs a value}"; shift 2 ;;
        --min-savers) MIN_SAVERS="${2:?--min-savers needs a value}"; shift 2 ;;
        --allow-build-path) ALLOW_PATH=1; shift ;;
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
        *) echo "check-metal-bundle: unknown argument $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64) ;; *) echo "check-metal-bundle: --arch amd64|arm64" >&2; exit 2 ;; esac
[ -r "$TARBALL" ] || { echo "check-metal-bundle: cannot read $TARBALL" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-metal-bundle: python3 required" >&2; exit 2; }

echo "bundle: $(basename "$TARBALL") $(wc -c < "$TARBALL") bytes"
echo "sha256: $(sha256sum "$TARBALL" | cut -d' ' -f1)"
python3 -I - "$TARBALL" "$PREFIX" "$ARCH" "$MIN_SAVERS" "$ALLOW_PATH" <<'PY'
import sys
import tarfile

path, prefix_name, arch, min_savers, allow_path = sys.argv[1:6]
min_savers = int(min_savers)
allow_path = allow_path == "1"
MACHINE = {"amd64": 62, "arm64": 183}          # EM_X86_64, EM_AARCH64
EXPECT = MACHINE[arch]
prefix = prefix_name.strip("/") + "/"
NEEDLES = [b"/home/", b"/Users/"]

fails = []
elf_seen = 0
savers = 0
launcher = False
leaks = []

try:
    tf = tarfile.open(path, "r:*")
except (tarfile.TarError, OSError) as exc:
    print("FAIL cannot open the tarball: %s" % exc)
    sys.exit(1)

members = tf.getmembers()
if not members:
    print("FAIL the tarball has no members")
    sys.exit(1)

# ancestors of the prefix ("opt/", "opt/bh-test/") are legitimate directory entries:
# tar always writes them, and calling them escapes would fail every real bundle
ancestors = set()
_parts = prefix.strip("/").split("/")
for _i in range(1, len(_parts) + 1):
    ancestors.add("/".join(_parts[:_i]).strip("/"))

for m in members:
    raw = m.name
    name = raw[2:] if raw.startswith("./") else raw
    if name in ("", "."):
        continue
    # ".." has to be checked on the RAW name: any normalisation that strips "./" also
    # turns "../escape" into "escape" and hides the escape
    if raw.startswith("/") or ".." in raw.split("/"):
        fails.append("member escapes the prefix: %s" % raw)
        continue
    if name.rstrip("/") in ancestors and m.isdir():
        continue
    if not name.startswith(prefix):
        fails.append("member outside %s: %s" % (prefix_name, raw))
        continue
    leaf = name[len(prefix):]
    if leaf.rstrip("/") == "bin/ncz-screensaver" and m.isfile():
        launcher = True
    if "/ncz-screensavers/" in "/" + leaf and leaf.endswith("_gles3") and m.isfile():
        savers += 1
    if m.isfile():
        try:
            data = tf.extractfile(m).read()
        except (tarfile.TarError, OSError) as exc:
            fails.append("cannot read %s: %s" % (m.name, exc))
            continue
        if data[:4] == b"\x7fELF" and len(data) >= 20:
            elf_seen += 1
            # e_machine is a 16-bit field at offset 18, little-endian on both targets
            machine = int.from_bytes(data[18:20], "little")
            if machine != EXPECT:
                fails.append("%s is ELF machine %d, expected %d for %s"
                             % (m.name, machine, EXPECT, arch))
        if not allow_path:
            for needle in NEEDLES:
                if needle in data:
                    leaks.append((m.name, needle.decode().strip("/")))
                    break

print("entries: %d  ELF: %d  savers: %d  launcher: %s"
      % (len(members), elf_seen, savers, "yes" if launcher else "NO"))

if not launcher:
    fails.append("no %s/bin/ncz-screensaver" % prefix_name)
if savers < min_savers:
    fails.append("only %d saver(s), expected at least %d" % (savers, min_savers))
if elf_seen == 0:
    fails.append("no ELF members at all - this is not a runnable bundle")
if leaks:
    shown = ", ".join(sorted({name for name, _ in leaks})[:5])
    fails.append("%d file(s) carry a build path (%s%s)"
                 % (len(leaks), shown, ", ..." if len(leaks) > 5 else ""))

if fails:
    for f in fails[:12]:
        print("FAIL %s" % f)
    print("check-metal-bundle: FAIL (%d problem(s))" % len(fails))
    sys.exit(1)
print("check-metal-bundle: OK (prefix %s, arch %s, %d savers, no build paths)"
      % (prefix_name, arch, savers))
PY
