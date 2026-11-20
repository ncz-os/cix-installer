#!/bin/bash
# test-release-kernel-manifest-order.sh -- SKY1 ARM64 7.3.3 KERNEL order, item 3.
#
# release-kernel.sh regenerates the kernel manifest only at its last step (7/7),
# but the accelerator-overlay gate (stage-accel-overlays.sh, step 4b) runs earlier
# and checks that manifest. A KVER bump therefore stops at the overlay step with
# a stale manifest that still names the previous kernel.
#
# Two checks:
#   A. structural: `kernel-manifest.py gen` must sit on a live (non-comment,
#      non-echo) line BEFORE the stage-accel-overlays.sh call.
#   B. behavioral: a version-bump fixture (kernel.release = NEW_KVER, committed
#      manifest = OLD_KVER) run through the pre-overlay refresh block extracted
#      from release-kernel.sh must leave a manifest whose kver == NEW_KVER, so
#      the overlay gate sees the regenerated form and not the stale one.
set -u
S="$(cd "$(dirname "$0")/.." && pwd)/build/release-kernel.sh"
[ -f "$S" ] || { echo "FAIL: no release-kernel.sh"; exit 1; }

# --- A. structural -----------------------------------------------------------
gen=$(grep -n '^[[:space:]]*[^#]*kernel-manifest\.py gen' "$S" | head -1 | cut -d: -f1)
ov=$(grep -n '\$REPO/build/stage-accel-overlays\.sh' "$S" | head -1 | cut -d: -f1)
if [ -z "$gen" ] || [ -z "$ov" ]; then echo "FAIL: manifest gen or overlay call missing"; exit 1; fi
if [ "$gen" -lt "$ov" ]; then
    echo "PASS(A): live manifest gen (line $gen) precedes the overlay gate (line $ov)"
else
    echo "FAIL(A): manifest gen (line $gen) is after the overlay gate (line $ov)"
    exit 1
fi

# --- B. behavioral fixture ---------------------------------------------------
# Reproduce the defect: the kernel is built at NEW_KVER, the committed manifest
# still says OLD_KVER. Extract every live (non-comment) line between the KVER
# derivation and the overlay gate call, run it against a scratch repo with a
# stub kernel-manifest.py, and prove the manifest is refreshed before the gate.
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/build" "$TMP/repo/assets"
OLD_KVER="7.3.2-sky1-ncz"
NEW_KVER="7.3.3-sky1-ncz"
mkdir -p "$TMP/repo/assets/kernel/$NEW_KVER"
echo "$NEW_KVER" > "$TMP/repo/assets/kernel/$NEW_KVER/KVER"
cat > "$TMP/repo/assets/kernel-manifest.json" <<JSON
{"variants":{"mainline":{"kver":"$OLD_KVER"}}}
JSON
# Stub generator: write the kver read from assets/kernel/<KVER>/KVER.
cat > "$TMP/repo/build/kernel-manifest.py" <<'PY'
#!/usr/bin/env python3
import json, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
m = os.path.join(root, "assets", "kernel-manifest.json")
if cmd == "gen":
    kver = None
    if os.path.isdir(os.path.join(root, "assets", "kernel")):
        for d in sorted(os.listdir(os.path.join(root, "assets", "kernel"))):
            kf = os.path.join(root, "assets", "kernel", d, "KVER")
            if os.path.isfile(kf):
                kver = open(kf).read().strip()
    if kver is None:
        print("gen: cannot derive KVER", file=sys.stderr)
        sys.exit(1)
    with open(m, "w") as f:
        json.dump({"variants": {"mainline": {"kver": kver}}}, f)
    print(f"wrote {os.path.relpath(m, root)} (kver={kver})")
    sys.exit(0)
if cmd == "check":
    want = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        have = json.load(open(m))["variants"]["mainline"]["kver"]
    except (OSError, ValueError, KeyError, TypeError):
        print(f"check: manifest missing or malformed")
        sys.exit(1)
    if want is not None and have != want:
        print(f"check: FAIL: manifest kver {have} != expected {want} (stale)")
        sys.exit(1)
    print(f"check: OK (kver={have})")
    sys.exit(0)
print("unknown command")
sys.exit(2)
PY

# Extract the live refresh block: the lines from the first "pre-overlay"
# comment through the line that invokes kernel-manifest.py gen (both inclusive),
# dropping comment lines. This is the region that must run before the gate.
awk '
    /pre-overlay/ { keep = 1 }
    keep && !/^[[:space:]]*#/ { print }
    keep && /manifest still stale/ { keep = 0 }
' "$S" > "$TMP/region.sh"
grep -q 'kernel-manifest\.py gen' "$TMP/region.sh" \
    || { echo "FAIL(B): no live manifest-gen line in the pre-overlay region"; exit 1; }
grep -q 'kernel-manifest\.py check' "$TMP/region.sh" \
    || { echo "FAIL(B): no live manifest-check line in the pre-overlay region"; exit 1; }

# Run the region with the scratch repo; KVER is the just-built (new) release.
# step/die are defined by release-kernel.sh itself; provide equivalents so the
# extracted block runs standalone.
(
    cd "$TMP/repo"
    export REPO="$TMP/repo"
    export KVER="$NEW_KVER"
    step() { printf '\n=== %s\n' "$*"; }
    die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
    source "$TMP/region.sh"
) > "$TMP/run.log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
    echo "FAIL(B): pre-overlay refresh block exited $rc with OLD_KVER=$OLD_KVER manifest:"
    cat "$TMP/run.log"
    exit 1
fi
have=$(python3 -c "import json;print(json.load(open('$TMP/repo/assets/kernel-manifest.json'))['variants']['mainline']['kver'])" 2>/dev/null)
if [ "$have" != "$NEW_KVER" ]; then
    echo "FAIL(B): fixture reached the overlay gate with stale manifest (kver=${have:-missing}, expected $NEW_KVER)"
    cat "$TMP/run.log"
    exit 1
fi
echo "PASS(B): version-bump fixture refreshed the manifest to $NEW_KVER before the overlay gate"
