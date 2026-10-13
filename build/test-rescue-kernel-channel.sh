#!/bin/bash
# test-rescue-kernel-channel.sh -- prove post-install/72-rescue-partition.sh
# stages the arm64 rescue kernel from the shipping channel, not the retired
# edge channel.
#
# The unified 7.3 policy (2026-10-05) retired assets/kernel/edge.
# build-squashfs-layers.sh deletes that directory from the installed payload
# and writes KVER_NEXT from assets/kernel/mainline. A rescue hook that still
# requires Image-cixmini.bin and modules-cixmini.tgz under assets/kernel/edge
# fails every arm64 install before it can write RESCUE_READY, which then
# makes 70-bootloader.sh refuse to ship.
#
# This test does not mount a rescue partition. It drives the hook's arm64
# precondition against a fixture that contains only mainline (the post-policy
# payload) and asserts the hook looks there, not under edge.
#
# Exit 0 = all PASS, 1 = one or more FAIL, 2 = harness error.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../post-install/72-rescue-partition.sh"
[ -f "$HOOK" ] || { echo "EXTRACT FAILED: $HOOK missing"; exit 2; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# The arm64 branch must name the shipping channel in executable code, not
# only in a comment. A comment that says "mainline" while the install still
# reads edge is exactly the defect this test exists to catch.
exec_lines() {
    awk '
        /^[[:space:]]*#/ { next }
        { print }
    ' "$HOOK"
}

EDGE_READS="$(exec_lines | grep -c 'ASSETS_KERNEL/edge/' || true)"
MAINLINE_READS="$(exec_lines | grep -c 'ASSETS_KERNEL/mainline/' || true)"

if [ "$EDGE_READS" -eq 0 ]; then
    ok "arm64 rescue does not read assets/kernel/edge"
else
    bad "arm64 rescue still reads assets/kernel/edge ($EDGE_READS executable reference(s))"
fi
if [ "$MAINLINE_READS" -ge 2 ]; then
    ok "arm64 rescue reads Image and modules from assets/kernel/mainline ($MAINLINE_READS)"
else
    bad "arm64 rescue does not stage both Image and modules from assets/kernel/mainline (found $MAINLINE_READS)"
fi

# Fail-before shape: a payload with only mainline (no edge dir) must get
# past the asset check. We stop the hook at the rescue-rootfs precondition,
# which is the next check after the kernel-asset check, so a wrong channel
# exits 1 with the edge error and a correct channel exits 1 with the
# tarball error. Both exits are 1; the message distinguishes them.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

install_meta() {
    local root="$1" channel="$2"
    mkdir -p "$root/usr/local/lib/cix-installer/assets/kernel/$channel"
    printf '7.3.0-rc6-sky1-ncz\n' > "$root/usr/local/lib/cix-installer/KVER_NEXT"
    printf 'arm64\n' > "$root/usr/local/lib/cix-installer/BUILD_ARCH"
    : > "$root/usr/local/lib/cix-installer/assets/kernel/$channel/Image-cixmini.bin"
    : > "$root/usr/local/lib/cix-installer/assets/kernel/$channel/modules-cixmini.tgz"
}

# Positive: mainline only, no edge directory.
install_meta "$WORK/mainline-only" mainline
python3 - "$HOOK" "$WORK/mainline-only/usr/local/lib/cix-installer" <<'PY'
import pathlib, re, sys
hook = pathlib.Path(sys.argv[1]).read_text()
meta = pathlib.Path(sys.argv[2])
exec_lines = []
for line in hook.splitlines():
    if line.lstrip().startswith("#"):
        continue
    exec_lines.append(line)
body = "\n".join(exec_lines)
# Every executable assets/kernel/<channel>/ read in the arm64 branch.
reads = re.findall(r'ASSETS_KERNEL/([A-Za-z0-9_-]+)/([A-Za-z0-9_.-]+)', body)
missing = []
for channel, name in reads:
    path = meta / "assets" / "kernel" / channel / name
    if not path.is_file():
        missing.append(f"{channel}/{name}")
if missing:
    print("FAIL fixture resolution: " + ", ".join(missing))
    sys.exit(1)
if not reads:
    print("FAIL no ASSETS_KERNEL/<channel>/<file> reads in executable code")
    sys.exit(1)
channels = sorted({c for c, _ in reads})
if channels != ["mainline"]:
    print("FAIL rescue kernel channel is %s, want mainline" % channels)
    sys.exit(1)
print("PASS fixture: mainline-only payload satisfies every rescue kernel read")
PY
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "mainline-only fixture satisfies every executable rescue kernel read"
else
    bad "mainline-only fixture does not satisfy the rescue hook"
fi

# Negative: edge-only payload must NOT satisfy the hook. If it does, the
# hook is still on the retired channel.
install_meta "$WORK/edge-only" edge
python3 - "$HOOK" "$WORK/edge-only/usr/local/lib/cix-installer" <<'PY'
import pathlib, re, sys
hook = pathlib.Path(sys.argv[1]).read_text()
meta = pathlib.Path(sys.argv[2])
reads = []
for line in hook.splitlines():
    if line.lstrip().startswith("#"):
        continue
    reads.extend(re.findall(r'ASSETS_KERNEL/([A-Za-z0-9_-]+)/([A-Za-z0-9_.-]+)', line))
satisfied = []
for channel, name in reads:
    if (meta / "assets" / "kernel" / channel / name).is_file():
        satisfied.append(f"{channel}/{name}")
if satisfied:
    print("FAIL edge-only payload still satisfies: " + ", ".join(satisfied))
    sys.exit(1)
print("PASS edge-only payload does not satisfy the rescue kernel reads")
PY
rc=$?
if [ "$rc" -eq 0 ]; then
    ok "edge-only payload does not satisfy the rescue hook"
else
    bad "edge-only payload still satisfies the rescue hook (still on the retired channel)"
fi

echo "---- $PASS passed, $FAIL failed ----"
[ "$FAIL" -eq 0 ]
