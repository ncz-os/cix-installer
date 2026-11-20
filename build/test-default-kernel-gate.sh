#!/usr/bin/env bash
# Proves build/check-default-kernel.sh FIRES (operator 2026-11-12 01:35Z item 3)
# and that the 7.4 policy line itself fires (operator 2026-11-16, 26.10 Cygnus
# PR4: "release will use 7.4 kernel, no edge and 7.3 will be retired"):
#   1. a good run with matching 7.4 pins passes
#   2. a run that booted the wrong kernel is caught
#   3. a 7.3.4 default (the retired line) is refused EVEN IF every pin agrees
#      with it -- both directions: 7.3.4 default fails, the 7.4 pin passes
#   3b. a 7.4 default whose package revision is not the json pin is refused
#   4. a pin mismatch (json 7.4.0-rc3, pin 7.3.4) is a FAIL, never a note
#      (NG2-NC-004: a pin/registry mismatch fails the build)
#   5. a manifest whose kernel_release disagrees with the json is caught
# Self-contained: every scenario runs against a SYNTHESIZED fixture tree, so
# this test never depends on the staged pins of the real checkout (whose
# kernel may legitimately be mid-transition while the next build is staged).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
G="$ROOT/build/check-default-kernel.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
VSHA="abababababababababababababababababababababababababababababababab"

# mkfixture <name> <json-kver> <pin-kver> <manifest-kver>
mkfixture() {
    local d="$T/$1"
    mkdir -p "$d/root/build" "$d/root/assets/kernel/amd64-stable" "$d/run/kvm-gate"
    cp "$G" "$d/root/build/check-default-kernel.sh"
    python3 - "$d/root/assets/kernel" "$2" "$3" "$4" "$VSHA" <<'PYEOF'
import json, sys
assets, jkver, pin, mkver, vsha = sys.argv[1:6]
json.dump({"schema": 1,
           "amd64": {"kver": jkver, "pkgversion": jkver},
           "arm64": {"kver": jkver, "pkgversion": jkver}},
          open(assets + "/default-kernel.json", "w"))
json.dump({"identity": {"kernel_release": mkver, "vmlinuz_sha256": vsha}},
          open(assets + "/amd64-stable-manifest.json", "w"))
open(assets + "/amd64-stable/KVER", "w").write(pin + "\n")
# The gate also pins the amd64 package revision; the fixture mirrors the json.
open(assets + "/amd64-stable/PKGVERSION", "w").write(jkver + "\n")
PYEOF
}

# runlogs <name> <kver>: boot evidence naming <kver> with the pinned vmlinuz sha
runlogs() {
    local d="$T/$1"
    echo "Linux version $2 (builder@host) (gcc) #1 SMP" > "$d/run/kvm-gate/serial0.log"
    echo "installer kernel /linux is the pinned r2 build ($2, 2010 boot-GPU fix)" > "$d/run/kvm-gate/install.log"
}

# mkarfixture <name> <json-kver> <json-pkg> <release-name> <manifest-kver>
# arm64 fixture: default-kernel.json arm64 pin vs mainline.release vs
# sky1-manifest.json. <json-pkg> is the full pkgversion (<kver>+rNNN); the gate
# derives the expected pkg from the release name, so a drift between the two is
# exactly what the arm64 relrev check must catch.
mkarfixture() {
    local d="$T/$1"
    mkdir -p "$d/root/build" "$d/root/assets/kernel" "$d/run/kvm-gate"
    cp "$G" "$d/root/build/check-default-kernel.sh"
    python3 - "$d/root/assets/kernel" "$2" "$3" "$4" "$5" "$VSHA" <<'PYEOF'
import json, sys
assets, jkver, jpkg, rel, mkver, vsha = sys.argv[1:7]
json.dump({"schema": 1,
           "amd64": {"kver": jkver, "pkgversion": jpkg},
           "arm64": {"kver": jkver, "pkgversion": jpkg}},
          open(assets + "/default-kernel.json", "w"))
json.dump({"identity": {"kernel_release": mkver, "vmlinuz_sha256": vsha}},
          open(assets + "/sky1-manifest.json", "w"))
open(assets + "/mainline.release", "w").write(rel + "\n")
PYEOF
}
# agate <fixture-name>: run the fixture's gate for arm64
agate() { bash "$T/$1/root/build/check-default-kernel.sh" --arch arm64 --run-dir "$T/$1/run" >/dev/null 2>&1; }
# gate <fixture-name>: run the fixture's gate on its fixture run dir (amd64)
gate() { bash "$T/$1/root/build/check-default-kernel.sh" --arch amd64 --run-dir "$T/$1/run" >/dev/null 2>&1; }

r=0
say() { echo "$1"; }

# 1. good run: json == pin == manifest == booted kernel -> accepted
mkfixture good 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz
runlogs good 7.4.0-rc3-t2-ncz
gate good && say "PASS: good run accepted (7.4.0-rc3-t2-ncz)" || { say "FAIL: good 7.4 run rejected"; r=1; }

# 2. wrong kernel booted -> caught
mkfixture wrongboot 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz
runlogs wrongboot 7.4.0-rc2-t2-ncz
gate wrongboot && { say "FAIL: wrong default kernel NOT caught"; r=1; } || say "PASS: wrong default kernel caught (gate fires)"

# 3. 7.3.4 default refused even with perfectly agreeing pins -- the retired
#    7.3.x line can never be the default of a 26.10 Cygnus PR4 image
mkfixture oldpolicy 7.3.4-t2-ncz 7.3.4-t2-ncz 7.3.4-t2-ncz
runlogs oldpolicy 7.3.4-t2-ncz
gate oldpolicy && { say "FAIL: 7.3.4 default NOT refused (7.4 policy line must fire)"; r=1; } || say "PASS: 7.3.4 default refused (7.4 policy line fires)"

# 3b. a 7.4 default is accepted, a 6.12/default-channel kernel is not
mkfixture newline 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz
runlogs newline 7.4.0-rc3-t2-ncz
gate newline && say "PASS: 7.4 pins pass (both directions proven)" || { say "FAIL: 7.4 pins rejected"; r=1; }
mkfixture foreign 6.12.0-t2-ncz 6.12.0-t2-ncz 6.12.0-t2-ncz
runlogs foreign 6.12.0-t2-ncz
gate foreign && { say "FAIL: non-7.4 default NOT refused"; r=1; } || say "PASS: non-7.4 default refused"

# 3c. package revision drift on amd64 (json says -2, pin says -1) -> FAIL
mkfixture pkgdrift 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz
printf '7.4.0-rc3-1\n' > "$T/pkgdrift/root/assets/kernel/amd64-stable/PKGVERSION"
runlogs pkgdrift 7.4.0-rc3-t2-ncz
gate pkgdrift && { say "FAIL: PKGVERSION drift NOT caught"; r=1; } || say "PASS: amd64 PKGVERSION drift caught"

# 3d. arm64 release-revision drift: mainline.release names r999 but the json
#     arm64 pkgversion is <kver>+r303 -> the gate must refuse (relrev mismatch).
mkarfixture armpkgdrift 7.4.0-rc3-sky1-ncz 7.4.0-rc3-sky1-ncz+r303 \
    r999-7.4.0-rc3-sky1-ncz-20261115 7.4.0-rc3-sky1-ncz
agate armpkgdrift && { say "FAIL: arm64 relrev drift NOT caught"; r=1; } || say "PASS: arm64 PKGVERSION/relrev drift caught"
# 3e. arm64 good: release r303 and json pkg <kver>+r303 agree -> accepted
mkarfixture armgood 7.4.0-rc3-sky1-ncz 7.4.0-rc3-sky1-ncz+r303 \
    r303-7.4.0-rc3-sky1-ncz-20261115 7.4.0-rc3-sky1-ncz
runlogs armgood 7.4.0-rc3-sky1-ncz
agate armgood && say "PASS: arm64 good pins accepted" || { say "FAIL: arm64 good pins rejected"; r=1; }
# 4. pin mismatch (json 7.4.0-rc3, pin 7.3.4) -> FAIL, never a note (NG2-NC-004)
mkfixture pinmismatch 7.4.0-rc3-t2-ncz 7.3.4-t2-ncz 7.4.0-rc3-t2-ncz
runlogs pinmismatch 7.4.0-rc3-t2-ncz
gate pinmismatch && { say "FAIL: pin/json mismatch NOT caught (NG2-NC-004)"; r=1; } || say "PASS: pin/json mismatch fails the build (NG2-NC-004)"

# 5. manifest kernel_release disagrees with the json -> caught
mkfixture mandrift 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.3.4-t2-ncz
runlogs mandrift 7.4.0-rc3-t2-ncz
gate mandrift && { say "FAIL: manifest/json drift NOT caught"; r=1; } || say "PASS: manifest kernel_release drift caught"

# 6. boot evidence under kvm-gate/target-logs/ (the installer dmesg the real
#    gate writes as target-logs/cix-install/dmesg-install.log) is FOUND.
#    Regression this guards: the arm64 desktop gate's only boot banner lives
#    there and the gate wrongly reported "no boot evidence" (2026-11-14).
mkfixture targetlogs 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz
mkdir -p "$T/targetlogs/run/kvm-gate/target-logs/cix-install"
echo "[Fri Nov 13 18:25:13 2026] Linux version 7.4.0-rc3-t2-ncz (oe-user@oe-host) (gcc) #1 SMP" \
    > "$T/targetlogs/run/kvm-gate/target-logs/cix-install/dmesg-install.log"
gate targetlogs && say "PASS: target-logs install dmesg accepted as boot evidence" \
    || { say "FAIL: target-logs boot evidence not found (scope gap regressed)"; r=1; }

# 7. server-variant layout: boot evidence under kvm-gate-options/<opt>/ (the
#    per-install-option work dirs the server matrix gate writes instead of
#    kvm-gate/) is FOUND. Regression this guards: the arm64 server run's only
#    boot banners live there and the gate wrongly reported "no boot evidence"
#    (2026-11-14).
mkfixture optlayout 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz 7.4.0-rc3-t2-ncz
mkdir -p "$T/optlayout/run/kvm-gate-options/server-medium"
echo "Linux version 7.4.0-rc3-t2-ncz (builder@host) (gcc) #1 SMP" \
    > "$T/optlayout/run/kvm-gate-options/server-medium/boot.log"
echo "installer kernel /linux is the pinned r2 build (7.4.0-rc3-t2-ncz, 2010 boot-GPU fix)" \
    > "$T/optlayout/run/kvm-gate-options/server-medium/installer-probe.log"
gate optlayout && say "PASS: kvm-gate-options boot evidence accepted" \
    || { say "FAIL: kvm-gate-options boot evidence not found (scope gap regressed)"; r=1; }

exit $r
