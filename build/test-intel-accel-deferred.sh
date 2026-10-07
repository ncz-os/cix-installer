#!/bin/bash
# test-intel-accel-deferred.sh -- Intel GPU/NPU userspace: vendored key, apt
# simulation gate, and the deferred retry when the network is down (r201).
#
# PEGASUS had no OpenVINO / Level Zero userspace: 54-gpu-accel.sh fetched an
# Intel key URL that answers 403, skipped the stack with no retry, and asked for
# package names Intel's repo does not publish. This runs the real
# post-install/lib/intel-accel.sh against a fixture root (NCZ_INTEL_ROOT) with
# apt-get / apt-cache / gpg stubs that model "network down", "network up" and
# "a transaction that would remove packages".
#
# Run: bash build/test-intel-accel-deferred.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
LIB="$ROOT/post-install/lib/intel-accel.sh"
HOOK="$ROOT/post-install/54-gpu-accel.sh"
W="$(mktemp -d -t intel-accel.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

mkdir -p "$W/bin"
# apt-cache: the Intel index exists only when NET=up
cat > "$W/bin/apt-cache" <<'EOF'
#!/bin/sh
case "$1" in
    pkgnames) [ "$NET" = up ] && printf 'libopenvino-intel-gpu-plugin-2026.3.1\nlibopenvino-intel-gpu-plugin-2026.4.1\n'; exit 0 ;;
    policy)   echo "$2:"; echo "  Candidate: (none)"; exit 0 ;;
esac
EOF
# apt-get: log every call; -s prints Inst (+ Remv when REMV=1); real install fails when NET!=up
cat > "$W/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$LOG"
case " $* " in
    *" update "*) exit 0 ;;
    *" -s "*) echo "Inst libze1"; [ "${REMV:-0}" = 1 ] && echo "Remv mesa-opencl-icd [1]"; exit 0 ;;
    *" install "*) [ "$NET" = up ] && exit 0
                   # network down: only the Debian set can come (offline mirror, MIRROR=1)
                   [ "${MIRROR:-0}" = 1 ] && ! echo " $* " | grep -q libopenvino && exit 0
                   exit 100 ;;
esac
EOF
# dpkg-query: packages listed in $INSTALLED report as installed
cat > "$W/bin/dpkg-query" <<'EOF'
#!/bin/sh
for a in "$@"; do p="$a"; done
case " ${INSTALLED:-} " in *" $p "*) printf 'install ok installed'; exit 0 ;; esac
exit 1
EOF
printf '#!/bin/sh\ncat\n' > "$W/bin/gpg"
# hermetic: the key download (fallback) must never reach the network
printf '#!/bin/sh\nexit 22\n' > "$W/bin/curl"
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" LOG="$W/apt.log"

mkroot() { rm -rf "$W/r" "$LOG"; mkdir -p "$W/r"; : > "$LOG"; }
run() {   # run FUNC ARGS... in the fixture root
    ( export NCZ_INTEL_ROOT="$W/r" NCZ_INTEL_ASSETS="${KEYASSETS:-$ROOT/assets/intel}" NCZ_INTEL_LIB_SRC="$LIB" NCZ_INTEL_ACCEL_LIB=1
      . "$LIB"; "$@" ) > "$W/out" 2>&1
}   # returns the function's exit status
P="$W/r/var/lib/ncz/intel-accel.pending"
T="$W/r/etc/systemd/system/timers.target.wants/ncz-intel-accel-setup.timer"

echo "=== vendored key ==="
[ "$(sha256sum "$ROOT/assets/intel/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB" | cut -d' ' -f1)" = "$(sed -n 's/^NCZ_INTEL_KEY_SHA256=//p' "$LIB")" ] \
    && ok "assets/intel key matches the pinned sha256" || bad "vendored key does not match the pin"
grep -q 'GPG-PUB-KEY-INTEL-OPENVINO-2026' "$HOOK" && bad "54 still fetches the 403 OpenVINO-2026 key URL" || ok "54 no longer fetches the dead key URL"

echo "=== install time, network down -> retry armed ==="
mkroot; NET=down run ncz_intel_accel_install 1 1
[ -s "$W/r/etc/apt/keyrings/intel-openvino.gpg" ] && ok "keyring written from the vendored key (no network needed)" || bad "no keyring" "$(cat "$W/out")"
[ -f "$P" ] && grep -qx GPU=1 "$P" && grep -qx NPU=1 "$P" && ok "retry marker records GPU=1 NPU=1" || bad "no retry marker" "$(cat "$W/out")"
[ -L "$T" ] && [ -f "$W/r/etc/systemd/system/ncz-intel-accel-setup.service" ] && [ -x "$W/r/usr/local/sbin/ncz-intel-accel-setup" ] \
    && ok "timer enabled, service + ncz-intel-accel-setup installed" || bad "deferred units not installed"
grep ' install -y' "$LOG" | grep -q libopenvino && bad "attempted an OpenVINO install without the repo index" || ok "no OpenVINO install attempted without the index"

echo "=== deferred run, still down -> stays pending ==="
NET=down run ncz_intel_accel_run; rc=$?
[ "$rc" = 75 ] && [ -f "$P" ] && grep -qx 'TRIES=1' "$P" && ok "exit 75 (timer retries), attempt counted" || bad "deferred down run rc=$rc" "$(cat "$P")"

echo "=== deferred run, network up -> installed, marker + timer gone ==="
: > "$LOG"; NET=up run ncz_intel_accel_run
[ ! -f "$P" ] && [ ! -e "$T" ] && grep -qx done "$W/r/var/lib/ncz/intel-accel.status" && ok "done: marker removed, timer disabled" || bad "network-up run" "$(cat "$W/out")"
inst=$(grep ' install -y' "$LOG")
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1 libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1; do
    printf '%s\n' "$inst" | grep -qw -- "$p" || bad "install lacks $p" "$inst"
done
printf '%s\n' "$inst" | grep -qwE 'openvino|level-zero|intel-driver-compiler-npu' && bad "asks for packages no repo publishes" "$inst" || ok "installs the newest OpenVINO plugins + Debian Level Zero/OpenCL/VA; no phantom package names"
grep -q ' -s ' "$LOG" && [ "$(grep -n ' -s ' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n ' install -y' "$LOG" | head -1 | cut -d: -f1)" ] \
    && ok "simulated before installing" || bad "no simulation before install"

echo "=== offline mirror: Debian set installs with no Intel index, OpenVINO stays pending ==="
mkroot; NET=down MIRROR=1 run ncz_intel_accel_install 1 0; rc=$?
inst=$(grep ' install -y' "$LOG")
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1; do
    printf '%s\n' "$inst" | grep -qw -- "$p" || bad "offline install lacks $p" "$inst"
done
printf '%s\n' "$inst" | grep -q libopenvino && bad "offline install pulled an Intel-repo package" "$inst" || ok "Debian GPU set installed from the mirror with the network down"
[ -f "$P" ] && ok "OpenVINO plugins still deferred (marker kept, timer armed)" || bad "marker lost although the plugins are not installed" "$(cat "$W/out")"

echo "=== no Intel signing key at all: the Debian set still installs, the plugins wait (r201 re-review) ==="
mkroot; mkdir -p "$W/nokey"; NET=down MIRROR=1 KEYASSETS="$W/nokey" NCZ_INTEL_KEY_URL=file:///nonexistent run ncz_intel_accel_install 1 0
inst=$(grep ' install -y' "$LOG")
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1; do
    printf '%s\n' "$inst" | grep -qw -- "$p" || bad "no key: Debian package $p was not installed" "$inst$(cat "$W/out")"
done
[ ! -s "$W/r/etc/apt/keyrings/intel-openvino.gpg" ] && [ ! -e "$W/r/etc/apt/sources.list.d/intel-openvino.list" ] && ok "no key: no Intel keyring and no Intel repo list written" || bad "no key: Intel repo wired without a key"
[ -f "$P" ] && ok "no key: retry armed for the OpenVINO plugins" || bad "no key: retry not armed" "$(cat "$W/out")"

echo "=== already installed from the mirror: skipped without touching apt install ==="
mkroot; NET=up INSTALLED="intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1" run ncz_intel_accel_install 1 0
inst=$(grep ' install -y' "$LOG")
printf '%s\n' "$inst" | grep -qwE 'intel-opencl-icd|intel-media-va-driver|libze1|libze-intel-gpu1' && bad "reinstalled packages that are already present" "$inst" || ok "present packages are not passed to apt again"
printf '%s\n' "$inst" | grep -q libopenvino-intel-gpu-plugin && ok "only the Intel-repo plugin is installed" || bad "plugin install missing" "$inst"
grep -qx done "$W/r/var/lib/ncz/intel-accel.status" && ok "status done" || bad "status not done" "$(cat "$W/out")"

echo "=== everything present, network down: nothing to do except the plugin index ==="
mkroot; NET=down MIRROR=1 INSTALLED="intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1" run ncz_intel_accel_install 1 0
grep -q ' install ' "$LOG" && bad "ran apt install although all Debian packages are present" || ok "no apt install call when the Debian set is already installed"

echo "=== a transaction that would remove packages is refused, not forced ==="
mkroot; NET=up REMV=1 run ncz_intel_accel_install 1 0
grep -q ' install -y' "$LOG" && bad "installed despite removals" || ok "no install when the simulation removes packages"
grep -q 'failed:would-remove-1-packages' "$W/r/var/lib/ncz/intel-accel.status" && [ ! -f "$P" ] && ok "status records the refusal; no endless retry" || bad "removal refusal" "$(cat "$W/out")"

echo "=== 54-gpu-accel.sh wiring ==="
grep -q "grep -qi '\\\\\[1200\\\\\]:.\*\\\\\[8086:' && HAS_INTEL_NPU=1" "$HOOK" && ok "Intel NPU detection unchanged (class [1200] vendor 8086)" || bad "Intel NPU detection changed"
grep -q 'ncz_intel_accel_install "$HAS_INTEL" "$HAS_INTEL_NPU"' "$HOOK" && ok "54 calls the shared installer for GPU and NPU" || bad "54 does not call ncz_intel_accel_install"
grep -q 'ConditionPathExists=/var/lib/ncz/intel-accel.pending' "$ROOT/assets/intel/ncz-intel-accel-setup.service" \
    && ! grep -qE '^(Before|RequiredBy)=' "$ROOT/assets/intel/ncz-intel-accel-setup.service" && ok "deferred unit gated on the marker and never ordered before boot targets" || bad "unit gating"

echo "=== assets/intel reaches the image (key + deferred units) ==="
# r201 amd64 build c638bbf8: assets/intel was in no staging allowlist, so the installed
# target had intel-accel.sh but neither the vendored key nor the service/timer it installs.
SQ="$ROOT/build/build-squashfs-layers.sh"
grep -E '^\s*for a in cix-debs kernel .*\bintel\b' "$SQ" >/dev/null && ok "base staging allowlist stages assets/intel" || bad "build-squashfs-layers.sh base staging loop omits assets/intel"
grep -E '^\s*for a in gpu audio .*\bintel\b' "$SQ" >/dev/null && ok "base fingerprint covers assets/intel (a change rebuilds the base)" || bad "base_assets_stamp omits assets/intel"
for f in GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB ncz-intel-accel-setup.service ncz-intel-accel-setup.timer; do
    [ -s "$ROOT/assets/intel/$f" ] || bad "assets/intel/$f missing from the tree"
done

echo "intel accel tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
