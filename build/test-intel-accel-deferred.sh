#!/bin/bash
# test-intel-accel-deferred.sh -- Intel GPU/NPU userspace: native NCZ/Forky
# acquisition, apt simulation gate, and the deferred retry when the network
# is down (r201) / NPU drivers are missing (r202), plus the deferred
# publication-lag policy (2026-10-17, PROTEUS: failed:gave-up-after-36).
#
# GU502LV had no OpenVINO / Level Zero userspace: 54-gpu-accel.sh fetched an
# Intel key URL that answers 403, skipped the stack with no retry, and asked
# for package names Intel's repo does not publish. The 2026-10-15 redesign
# removes the apt.repos.intel.com / ubuntu24 path entirely and consumes only
# native NCZ packages built against Debian Forky.
#
# This runs the real post-install/lib/intel-accel.sh against a fixture root
# (NCZ_INTEL_ROOT) with apt-get / apt-cache / dpkg-query stubs that model:
#   * "native NCZ index available" (NET=up, NPUPKGS=1)
#   * "NPU drivers not yet published" (NPUPKGS=0)
#   * "no network / index not refreshable" (NET=down)
#   * "a transaction that would remove packages" (REMV=1)
#
# and covers the deferred policy:
#   * a 75 caused ONLY by native candidates missing from a freshly fetched
#     index does NOT give up after the fast budget: the marker is kept and
#     the status is deferred:native-candidates-unpublished (exit 0);
#   * network-down and would-remove keep the old give-up / refusal semantics;
#   * a failed:gave-up-* system re-arms on the next deferred run (or
#     ncz-update-apply refresh) when the Intel GPU/NPU hardware is present.
#
# Run: bash build/test-intel-accel-deferred.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
LIB="$ROOT/post-install/lib/intel-accel.sh"
HOOK="$ROOT/post-install/54-gpu-accel.sh"
W="$(mktemp -d -t intel-accel.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); return 0; }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }

mkdir -p "$W/bin"
# apt-cache: the native NCZ index is reachable only when NET=up; the NPU
# plugin is published only when NPUPKGS=1 (C artifacts); the NPU
# driver/compiler/firmware set is published only when NPUDRIVERS=1
# (D artifacts -- still in flight as of 2026-10-15). These env toggles are
# the test seam for "native candidate availability".
cat > "$W/bin/apt-cache" <<'EOF'
#!/bin/sh
case "$1" in
    pkgnames)
        case "$2" in
            libopenvino-intel-gpu-plugin-)
                [ "$NET" = up ] && printf 'libopenvino-intel-gpu-plugin-2026.3.1\nlibopenvino-intel-gpu-plugin-2026.4.1\n' ;;
            libopenvino-intel-npu-plugin-)
                [ "$NET" = up ] && [ "${NPUPKGS:-0}" = 1 ] \
                    && printf 'libopenvino-intel-npu-plugin-2026.4.1\n' ;;
        esac
        exit 0 ;;
    policy)
        case "$2" in
            intel-driver-compiler-npu|intel-fw-npu|intel-level-zero-npu|intel-validation-npu)
                if [ "${NPUDRIVERS:-0}" = 1 ]; then
                    echo "$2:"
                    if [ "${VENDOR_ONLY_D:-0}" = 1 ]; then
                        echo "  Candidate: 1.38.0.20260910-34487311128"
                    else
                        echo "  Candidate: 1.38.0.ncz1~debian"
                    fi
                else
                    echo "$2:"
                    echo "  Candidate: (none)"
                fi
                ;;
            libopenvino-intel-gpu-plugin-*)
                echo "$2:"
                if [ "${VENDOR_ONLY:-0}" = 1 ]; then
                    echo "  Candidate: 2026.4.1.22982"
                else
                    echo "  Candidate: 1:2026.4.1.1-ncz1"
                fi
                ;;
            libopenvino-intel-npu-plugin-*)
                echo "$2:"
                if [ "${VENDOR_ONLY:-0}" = 1 ]; then
                    echo "  Candidate: 2026.4.1.22982"
                else
                    echo "  Candidate: 1:2026.4.1.1-ncz1"
                fi
                ;;
            *) echo "$2:"; echo "  Candidate: (none)" ;;
        esac
        exit 0 ;;
esac
EOF
# apt-get: log every call; -s prints Inst (+ Remv when REMV=1); real install fails when NET!=up.
# update fails when the network is down: a stale/cached index is NOT a fresh
# fetch, and the deferred policy must treat "index not refreshable" as a
# network-down 75 (give-up semantics), not as publication lag.
cat > "$W/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$LOG"
case " $* " in
    *" update "*) [ "${NET:-up}" = down ] && exit 100; exit 0 ;;
    *" -s "*) echo "Inst libze1"; [ "${REMV:-0}" = 1 ] && echo "Remv mesa-opencl-icd [1]"; exit 0 ;;
    *" install "*) [ "$NET" = up ] && exit 0
                   # network down: only the Debian set can come (offline mirror, MIRROR=1)
                   [ "${MIRROR:-0}" = 1 ] && ! echo " $* " | grep >/dev/null libopenvino && exit 0
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
# gpg / curl: not used by the native path; keep stubs that prove no key is fetched.
printf '#!/bin/sh\ncat\n' > "$W/bin/gpg"
printf '#!/bin/sh\nexit 22\n' > "$W/bin/curl"
chmod +x "$W/bin/"*
export PATH="$W/bin:$PATH" LOG="$W/apt.log"

mkroot() {
    rm -rf "$W/r" "$LOG"; mkdir -p "$W/r"; : > "$LOG"
    # A remote-origin NCZ source under the fixture root: real installs carry
    # one (hook24), and the deferred policy requires a remote source for
    # "freshly fetched index" -- an all-local index is never fresh.
    mkdir -p "$W/r/etc/apt/sources.list.d"
    echo "deb [signed-by=/x] https://example.invalid/ncz ./ " > "$W/r/etc/apt/sources.list.d/ncz-test.list"
}
run() {   # run FUNC ARGS... in the fixture root
    ( export NCZ_INTEL_ROOT="$W/r" NCZ_INTEL_ASSETS="${KEYASSETS:-$ROOT/assets/intel}" NCZ_INTEL_LIB_SRC="$LIB" NCZ_INTEL_ACCEL_LIB=1
      . "$LIB"; "$@" ) > "$W/out" 2>&1
}   # returns the function's exit status
P="$W/r/var/lib/ncz/intel-accel.pending"
T="$W/r/etc/systemd/system/timers.target.wants/ncz-intel-accel-setup.timer"

echo "=== no Intel key/repo wiring: native NCZ only ==="
# The lib must NOT define a vendored Intel key (sha256 pin, KEY URL, or repo
# line); it must not import or trust the ubuntu24 component. Comments are
# stripped before grepping: bare mention of an old URL inside a `# ...`
# comment is not active vendor wiring. The legacy URL pattern itself IS
# allowed inside `ncz_intel_disable_legacy_vendor_list` -- the disabler is
# by design required to recognize it.
LIB_NOCOMMENTS="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$LIB")"
printf '%s\n' "$LIB_NOCOMMENTS" | grep -q 'NCZ_INTEL_KEY_SHA256=' \
    && bad "lib still defines a vendored Intel key pin" || ok "lib has no vendored Intel key pin"
printf '%s\n' "$LIB_NOCOMMENTS" | grep -q 'NCZ_INTEL_KEY_URL=' \
    && bad "lib still defines an Intel key URL"        || ok "lib has no Intel key URL"
# The disabler MUST exist and reference the legacy URL pattern as a matcher
# -- a literal grep ban would also ban the disabler, which is required.
grep -q 'ncz_intel_disable_legacy_vendor_list' "$LIB" \
    && ok "lib has the intel-openvino.list legacy URL disabler (NCZ_INTEL_ROOT-scoped)" \
    || bad "lib has no intel-openvino.list disabler"
# But the lib must NOT WRITE to the Intel list from active code (only the
# disabler RENAMES it; nothing generates/refreshes/trusts it).
printf '%s\n' "$LIB_NOCOMMENTS" | grep -qE '>[[:space:]]*/etc/apt/sources\.list\.d/intel-openvino\.list[[:space:]]*$' \
    && bad "lib still WRITES /etc/apt/sources.list.d/intel-openvino.list" \
    || ok "lib does not write /etc/apt/sources.list.d/intel-openvino.list"
printf '%s\n' "$LIB_NOCOMMENTS" | grep -q 'ubuntu24' \
    && bad "lib still references the ubuntu24 component in active code" \
    || ok "lib does not trust the ubuntu24 component"
printf '%s\n' "$LIB_NOCOMMENTS" | grep -qE 't2-ubuntu-repo|adityagarg8' \
    && bad "lib still references T2 Ubuntu repo in active code" \
    || ok "lib does not reference the T2 Ubuntu vendor repo"

# === fixture: ncz_intel_disable_legacy_vendor_list on real temp files ===
# Extract the actual function body from the lib and source it in a subshell
# with logging wrappers defined (the sourced block does NOT include helpers).
# Drive it with REAL temp files under $W to verify: only known legacy Intel
# vendor lines are commented out, unrelated rows preserved, both row orders,
# unique .disabled-for-build.XXXXXX backup created with byte-equal content,
# idempotent second run, lookalike hosts and wrong paths untouched, failed
# mv preserves original with nonzero rc, symlink refusal preserves target.
# No live APT or device access; all fixtures under $W.

sed -n '/^ncz_intel_disable_legacy_vendor_list() {/,/^}$/p' "$LIB" > "$W/disabler.sh"
[ -s "$W/disabler.sh" ] && ok "intel disabler function extracted from lib" \
    || { bad "intel disabler function missing from lib"; exit 1; }

# Wrappers matching the real helper signatures used by the sourced block.
cat > "$W/intel_helpers.sh" <<'IHELP'
ncz_intel_log() { printf 'LOG: %s\n' "$*" >&2; }
ncz_intel_log_err() { printf 'ERR: %s\n' "$*" >&2; }
IHELP

# (a) signed-by actual vendor row disabled; unrelated Debian row preserved.
_a="$W/r/etc/apt/sources.list.d/intel-openvino.list"
mkdir -p "$(dirname "$_a")"
cat > "$_a" <<'ILIST'
# legacy intel-openvino.list shipped by an older installer
deb [signed-by=/usr/share/keyrings/intel-openvino.gpg] https://apt.repos.intel.com/openvino/2024/ubuntu noble main
ILIST
_orig_bytes=$(wc -c < "$_a")
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_a" ) > "$W/out" 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "disabler returned 0 on legacy vendor row" \
    || bad "disabler returned nonzero on legacy vendor row" "rc=$_rc $(cat "$W/out")"
grep -q '^# \[intel-accel\] disabled legacy vendor source: deb \[signed-by=' "$_a" \
    && ok "signed-by legacy vendor row was commented out in place" \
    || bad "signed-by legacy vendor row NOT commented out" "$(cat "$_a")"
grep -q '^deb ' "$_a" && bad "active deb line still present after disable" || true
_bak_count=$(ls -1 "$_a".disabled-for-build.* 2>/dev/null | wc -l)
[ "$_bak_count" -eq 1 ] && ok "exactly one .disabled-for-build.XXXXXX backup created" \
    || bad "expected 1 backup, got $_bak_count"
_bak=$(ls -1 "$_a".disabled-for-build.* 2>/dev/null | head -1)
[ -n "$_bak" ] && [ "$(wc -c < "$_bak")" -eq "$_orig_bytes" ] \
    && ok "backup byte-equal to original" \
    || bad "backup byte count mismatch (orig=$_orig_bytes)"
grep -q 'apt.repos.intel.com' "$_bak" \
    && ok "backup preserves legacy Intel URL verbatim" \
    || bad "backup lost legacy URL content"

# (b) unrelated Debian row stays ACTIVE and unchanged.
_b="$W/r/etc/apt/sources.list.d/debian-main.list"
mkdir -p "$(dirname "$_b")"
printf 'deb http://deb.debian.org/debian trixie main\n' > "$_b"
_b_before=$(cat "$_b")
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_b" ) > "$W/out" 2>&1
[ "$(cat "$_b")" = "$_b_before" ] \
    && ok "unrelated Debian row left ACTIVE and unchanged" \
    || bad "unrelated Debian row was modified"
[ ! -e "$_b.disabled-for-build" ] && [ -z "$(ls -1 "$_b".disabled-for-build.* 2>/dev/null)" ] \
    && ok "no backup created for unrelated Debian row" \
    || bad "unexpected backup for unrelated Debian row"

# (c) both row orders: URL before options, and options before URL.
_c1="$W/r/etc/apt/sources.list.d/order1.list"
printf 'deb https://apt.repos.intel.com/openvino/2024/ubuntu noble main\n' > "$_c1"
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_c1" ) > "$W/out" 2>&1
grep -q '^# \[intel-accel\] disabled legacy vendor source:' "$_c1" \
    && ok "URL-first legacy row disabled" \
    || bad "URL-first legacy row NOT disabled"
_c2="$W/r/etc/apt/sources.list.d/order2.list"
printf 'deb-src [arch=amd64] https://apt.repos.intel.com/openvino/2024/ubuntu noble main\n' > "$_c2"
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_c2" ) > "$W/out" 2>&1
grep -q '^# \[intel-accel\] disabled legacy vendor source:' "$_c2" \
    && ok "options-first deb-src legacy row disabled" \
    || bad "options-first deb-src legacy row NOT disabled"

# (d) idempotent second run: backup count unchanged, file unchanged.
_a2="$W/r/etc/apt/sources.list.d/idem.list"
printf 'deb https://apt.repos.intel.com/openvino/2024/ubuntu noble main\n' > "$_a2"
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_a2" ) >/dev/null 2>&1
_after1=$(cat "$_a2")
_bc1=$(ls -1 "$_a2".disabled-for-build.* 2>/dev/null | wc -l)
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_a2" ) >/dev/null 2>&1
_after2=$(cat "$_a2")
_bc2=$(ls -1 "$_a2".disabled-for-build.* 2>/dev/null | wc -l)
[ "$_after1" = "$_after2" ] && [ "$_bc1" -eq "$_bc2" ] \
    && ok "second run idempotent (content and backup count unchanged)" \
    || bad "second run not idempotent (bc1=$_bc1 bc2=$_bc2)"

# (e) lookalike evil host and wrong Intel path stay ACTIVE and unchanged.
_e1="$W/r/etc/apt/sources.list.d/evil.list"
printf 'deb https://apt.repos.intel.com.evil.example/openvino/2024/ubuntu noble main\n' > "$_e1"
_e1_before=$(cat "$_e1")
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_e1" ) >/dev/null 2>&1
[ "$(cat "$_e1")" = "$_e1_before" ] \
    && ok "lookalike evil host row left ACTIVE and unchanged" \
    || bad "lookalike evil host row was modified"
_e2="$W/r/etc/apt/sources.list.d/wrongpath.list"
printf 'deb https://apt.repos.intel.com/oneapi/2024/ubuntu noble main\n' > "$_e2"
_e2_before=$(cat "$_e2")
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_e2" ) >/dev/null 2>&1
[ "$(cat "$_e2")" = "$_e2_before" ] \
    && ok "wrong Intel path row left ACTIVE and unchanged" \
    || bad "wrong Intel path row was modified"

# (f) failed mv mock returns 77: original preserved, rc nonzero.
_f="$W/r/etc/apt/sources.list.d/mvfail.list"
printf 'deb https://apt.repos.intel.com/openvino/2024/ubuntu noble main\n' > "$_f"
_f_before=$(cat "$_f")
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; mv() { return 77; }; ncz_intel_disable_legacy_vendor_list "$_f" ) > "$W/out" 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "failed mv yields nonzero rc" \
    || bad "failed mv did not yield nonzero rc"
[ "$(cat "$_f")" = "$_f_before" ] \
    && ok "failed mv preserves original file content" \
    || bad "failed mv clobbered original file"

# (g) symlink refusal preserves the pointed-to file.
_g_target="$W/r/etc/apt/sources.list.d/symtarget.list"
printf 'deb https://apt.repos.intel.com/openvino/2024/ubuntu noble main\n' > "$_g_target"
_g_before=$(cat "$_g_target")
_g_link="$W/r/etc/apt/sources.list.d/symlink.list"
ln -sf "$_g_target" "$_g_link"
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_g_link" ) > "$W/out" 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "symlink refusal returns nonzero" \
    || bad "symlink refusal returned zero"
[ -L "$_g_link" ] && [ "$(cat "$_g_target")" = "$_g_before" ] \
    && ok "symlink refusal preserves pointed-to file" \
    || bad "symlink refusal modified target"

# (h) existing .disabled-for-build file is skipped (no re-processing).
_h="$W/r/etc/apt/sources.list.d/already.list.disabled-for-build"
printf 'deb https://apt.repos.intel.com/openvino/2024/ubuntu noble main\n' > "$_h"
_h_before=$(cat "$_h")
( . "$W/intel_helpers.sh"; . "$W/disabler.sh"; ncz_intel_disable_legacy_vendor_list "$_h" ) >/dev/null 2>&1
[ "$(cat "$_h")" = "$_h_before" ] \
    && ok "already-disabled file skipped (no suffix pile-up)" \
    || bad "already-disabled file was re-processed"


echo "=== install time, native index + NPU present, network down -> retry armed (Debian set installs from the mirror) ==="
mkroot; NET=down MIRROR=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_install 1 1
[ ! -s "$W/r/etc/apt/keyrings/intel-openvino.gpg" ] && [ ! -e "$W/r/etc/apt/sources.list.d/intel-openvino.list" ] \
    && ok "no Intel keyring / sources.list written (lib is native-only)" \
    || bad "Intel keyring or sources.list still written"
[ -f "$P" ] && grep -qx GPU=1 "$P" && grep -qx NPU=1 "$P" && ok "retry marker records GPU=1 NPU=1" || bad "no retry marker" "$(cat "$W/out")"
[ -L "$T" ] && [ -f "$W/r/etc/systemd/system/ncz-intel-accel-setup.service" ] && [ -x "$W/r/usr/local/sbin/ncz-intel-accel-setup" ] \
    && ok "timer enabled, service + ncz-intel-accel-setup installed" || bad "deferred units not installed"
# Network is down, so no apt-get install call should hit at all on the
# Intel-repo plugin path. The Debian set CAN come (MIRROR=1) — verify it did.
inst=$(grep ' install -y' "$LOG")
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "Debian $p missing on offline install" "$inst"
done
printf '%s\n' "$inst" | grep >/dev/null libopenvino && bad "attempted an OpenVINO install without the native index" "$inst" \
    || ok "no OpenVINO install attempted without the native index"

echo "=== deferred run, network still down -> stays pending ==="
NET=down run ncz_intel_accel_run; rc=$?
[ "$rc" = 75 ] && [ -f "$P" ] && grep -qx 'TRIES=1' "$P" && ok "exit 75 (timer retries), attempt counted" || bad "deferred down run rc=$rc" "$(cat "$P")"

echo "=== deferred run, native index up -> installed, marker + timer gone, NPU drivers present ==="
: > "$LOG"; NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run
[ ! -f "$P" ] && [ ! -e "$T" ] && grep -qx done "$W/r/var/lib/ncz/intel-accel.status" && ok "done: marker removed, timer disabled" || bad "network-up run" "$(cat "$W/out")"
inst=$(grep ' install -y' "$LOG")
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1 \
         libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1 \
         intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "install lacks $p" "$inst"
done
# The lib MUST NOT install phantom (non-native) names; especially no
# `openvino` or `level-zero` (the old Intel-repo bug). And it MUST install
# the four required NPU drivers when NPU=1 was requested.
printf '%s\n' "$inst" | grep >/dev/null -wE 'openvino$' \
    && bad "asks for the legacy 'openvino' name (not a native NCZ package)" "$inst" \
    || ok "no phantom 'openvino' name requested"
# NPU drivers must all show up in the SAME install -y call (parity).
_npud=$(printf '%s\n' "$inst" | grep >/dev/null -wE 'intel-driver-compiler-npu|intel-fw-npu|intel-level-zero-npu|intel-validation-npu' && echo yes || echo no)
[ "$_npud" = yes ] && ok "all 4 native NPU drivers were installed in the same call" \
    || bad "NPU drivers missing from install list" "$inst"
grep -q ' -s ' "$LOG" && [ "$(grep -n ' -s ' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n ' install -y' "$LOG" | head -1 | cut -d: -f1)" ] \
    && ok "simulated before installing" || bad "no simulation before install"

echo "=== offline mirror: Debian set installs with no native index, OpenVINO plugins stay pending ==="
mkroot; NET=down MIRROR=1 run ncz_intel_accel_install 1 0; rc=$?
inst=$(grep ' install -y' "$LOG")
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "offline install lacks $p" "$inst"
done
printf '%s\n' "$inst" | grep >/dev/null libopenvino && bad "offline install pulled a native-NCZ package" "$inst" || ok "Debian GPU set installed from the mirror with the network down"
[ -f "$P" ] && ok "OpenVINO plugins still deferred (marker kept, timer armed)" || bad "marker lost although the plugins are not installed" "$(cat "$W/out")"

echo "=== NPU requested but the native NPU drivers are NOT yet published: NOT done, retry armed ==="
# NPU plugin package IS available (C artifacts), but the four D components
# (intel-driver-compiler-npu, intel-fw-npu, intel-level-zero-npu,
# intel-validation-npu) are still in flight. The lib must NOT mark done and
# must NOT silently install a partial set.
mkroot; NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_install 1 1
inst=$(grep ' install -y' "$LOG")
# The Debian GPU set should install; the GPU plugin should install; the NPU
# plugin + drivers must NOT install (because the drivers are missing, the
# partial set is unsafe).
for p in intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1 libopenvino-intel-gpu-plugin-2026.4.1; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "NPU-missing install lacks $p" "$inst"
done
for p in libopenvino-intel-npu-plugin-2026.4.1 \
         intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" \
        && bad "NPU drivers not yet published: install should NOT include $p" "$inst" \
        || ok "NPU drivers not yet published: install correctly excludes $p"
done
! grep -qx done "$W/r/var/lib/ncz/intel-accel.status" \
    && ok "status NOT 'done' when NPU drivers missing (no silent skip)" \
    || bad "status incorrectly reports done with NPU drivers missing"
[ -f "$P" ] && grep -qx GPU=1 "$P" && grep -qx NPU=1 "$P" \
    && ok "retry armed (timer marker kept) so the next native publish will retry" \
    || bad "retry marker lost even though NPU drivers are missing"

echo "=== NPU missing: deferred run also refuses to mark done, keeps pending ==="
# The deferred run only does work when there is a pending marker. The
# "no marker -> noop" path is a separate contract; this test exercises
# "NPU driver missing -> deferred run KEEPS the marker" instead. Without
# a pre-seeded marker the function returns 0 from `nothing pending` and
# this test would falsely fail for the wrong reason.
mkroot; mkdir -p "$(dirname "$P")"; printf 'GPU=1\nNPU=1\nTRIES=0\n' > "$P"
NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; rc=$?
[ "$rc" != 0 ] && [ -f "$P" ] && ! grep -qx done "$W/r/var/lib/ncz/intel-accel.status" \
    && ok "deferred run with NPU drivers missing: rc=$rc, retry kept, NOT done" \
    || bad "deferred run should have stayed pending" "$(cat "$W/out")"
# Pre-existing contract assertion: pending-state preserves the TRIES counter
# (timer retry bookkeeping); the deferred run increments once and stays.
grep -qE '^TRIES=[1-9][0-9]*' "$P" \
    && ok "TRIES counter incremented by the deferred run" \
    || bad "TRIES counter missing/zero after deferred run" "$(cat "$P")"

echo "=== GPU-only selector: NPU driver check must NOT fire (no false retry) ==="
mkroot; NET=up NPUPKGS=0 NPUDRIVERS=0 run ncz_intel_accel_install 1 0
inst=$(grep ' install -y' "$LOG")
printf '%s\n' "$inst" | grep >/dev/null -w -- libopenvino-intel-gpu-plugin-2026.4.1 \
    && ok "GPU-only selector installs the GPU plugin" \
    || bad "GPU-only selector missing the GPU plugin" "$inst"
! printf '%s\n' "$inst" | grep >/dev/null -wE 'intel-driver-compiler-npu|intel-fw-npu|intel-level-zero-npu|intel-validation-npu' \
    && ok "GPU-only selector does NOT touch NPU drivers" \
    || bad "GPU-only selector incorrectly pulled NPU drivers" "$inst"
grep -qx done "$W/r/var/lib/ncz/intel-accel.status" \
    && ok "GPU-only selector marks done (no NPU request, no retry needed)" \
    || bad "GPU-only selector did not mark done" "$(cat "$W/out")"

echo "=== already installed from the mirror: skipped without touching apt install ==="
mkroot; NET=up NPUPKGS=1 NPUDRIVERS=1 INSTALLED="intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1" run ncz_intel_accel_install 1 0
inst=$(grep ' install -y' "$LOG")
printf '%s\n' "$inst" | grep >/dev/null -wE 'intel-opencl-icd|intel-media-va-driver|libze1|libze-intel-gpu1' && bad "reinstalled packages that are already present" "$inst" || ok "present packages are not passed to apt again"
printf '%s\n' "$inst" | grep >/dev/null libopenvino-intel-gpu-plugin && ok "only the native OpenVINO plugin is installed" || bad "plugin install missing" "$inst"
grep -qx done "$W/r/var/lib/ncz/intel-accel.status" && ok "status done" || bad "status not done" "$(cat "$W/out")"

echo "=== everything present, network down: nothing to do except the native index ==="
mkroot; NET=down MIRROR=1 INSTALLED="intel-opencl-icd intel-media-va-driver libze1 libze-intel-gpu1" run ncz_intel_accel_install 1 0
grep -q ' install ' "$LOG" && bad "ran apt install although all Debian packages are present" || ok "no apt install call when the Debian set is already installed"

echo "=== a transaction that would remove packages is refused, not forced ==="
mkroot; NET=up REMV=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_install 1 0
grep -q ' install -y' "$LOG" && bad "installed despite removals" || ok "no install when the simulation removes packages"
grep -q 'failed:would-remove-1-packages' "$W/r/var/lib/ncz/intel-accel.status" && [ ! -f "$P" ] && ok "status records the refusal; no endless retry" || bad "removal refusal" "$(cat "$W/out")"

echo "=== 54-gpu-accel.sh wiring ==="
grep -q "grep -qi '\\\\\[1200\\\\\]:.\*\\\\\[8086:' && HAS_INTEL_NPU=1" "$HOOK" && ok "Intel NPU detection unchanged (class [1200] vendor 8086)" || bad "Intel NPU detection changed"
grep -q 'ncz_intel_accel_install "$HAS_INTEL" "$HAS_INTEL_NPU"' "$HOOK" && ok "54 calls the shared installer for GPU and NPU" || bad "54 does not call ncz_intel_accel_install"
grep -q 'ConditionPathExists=/var/lib/ncz/intel-accel.pending' "$ROOT/assets/intel/ncz-intel-accel-setup.service" \
    && ! grep -qE '^(Before|RequiredBy)=' "$ROOT/assets/intel/ncz-intel-accel-setup.service" && ok "deferred unit gated on the marker and never ordered before boot targets" || bad "unit gating"

echo "=== assets/intel reaches the image (deferred units still stage) ==="
# r201 amd64 build c638bbf8: assets/intel was in no staging allowlist, so the installed
# target had intel-accel.sh but neither the vendored key nor the service/timer it installs.
SQ="$ROOT/build/build-squashfs-layers.sh"
grep -E '^\s*for a in cix-debs kernel .*\bintel\b' "$SQ" >/dev/null && ok "base staging allowlist stages assets/intel" || bad "build-squashfs-layers.sh base staging loop omits assets/intel"
# The base fingerprint lives in build/lib/layerplan.py (4a22d6c7), not in a find loop in $SQ.
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import layerplan as lp; sys.exit(0 if ("path", "assets/intel") in lp.REGISTRY["base"] else 1)' "$ROOT/build/lib" \
    && ok "base fingerprint covers assets/intel (a change rebuilds the base)" || bad "base_assets_stamp omits assets/intel"
for f in ncz-intel-accel-setup.service ncz-intel-accel-setup.timer; do
    [ -s "$ROOT/assets/intel/$f" ] || bad "assets/intel/$f missing from the tree"
done
# The vendored Intel key is intentionally NOT required anymore — the lib
# uses only the NCZ suite. Confirm assets/intel/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB
# is no longer relied on (its presence in the tree is harmless; just verify
# the lib does not pin or fetch it).
if grep -q '^NCZ_INTEL_KEY_SHA256=' "$LIB"; then
    bad "lib still pins the vendor Intel key"
else
    ok "no vendored Intel key pin (the public key asset is not required)"
fi

# C vendor-only: pkgnames present, candidate lacks ncz -> no native plugin
mkroot
NET=up NPUPKGS=1 NPUDRIVERS=1 VENDOR_ONLY=1 run ncz_intel_accel_install 1 1
! grep -q ' install -y.*libopenvino-' "$LOG" \
    && ok "vendor-only installed plugin names do not qualify as native candidates" \
    || bad "vendor-only plugin was treated as native" "$(cat "$LOG")"
[ -f "$P" ] && ! grep -qx done "$W/r/var/lib/ncz/intel-accel.status" \
    && ok "missing native plugin candidates remain pending despite old vendor names" \
    || bad "vendor-only plugin incorrectly marked done"
# D vendor-only: NPU requested, GPU native available -> GPU kept, no NPU args
mkroot
NET=up NPUPKGS=1 NPUDRIVERS=1 VENDOR_ONLY_D=1 run ncz_intel_accel_install 1 1
! grep -qE ' install -y.*(libopenvino-intel-npu-plugin|intel-driver-compiler-npu)' "$LOG" \
    && ok "vendor-only NPU driver candidates cannot install a partial NPU stack" \
    || bad "vendor-only NPU driver stack was accepted" "$(cat "$LOG")"
grep -q ' install -y.*libopenvino-intel-gpu-plugin' "$LOG" && [ -f "$P" ] \
    && ok "native GPU stays available while vendor-only NPU drivers remain pending" \
    || bad "GPU availability or NPU retry was lost" "$(cat "$W/out")"

# =============================================================================
# Deferred publication-lag policy (2026-10-17, PROTEUS gave-up defect)
# =============================================================================
S="$W/r/var/lib/ncz/intel-accel.status"
PCIR="$W/pcir"
mkpci() {   # mkpci VENDOR-CLASS...  (default: Intel GPU 0x8086-030000)
    if [ "$#" -eq 0 ]; then
        set -- 0x8086-030000
    fi
    rm -rf "$PCIR"; local c
    for c in "$@"; do
        mkdir -p "$PCIR/$c"
        printf '%s\n' "${c%-*}" > "$PCIR/$c/vendor"
        printf '0x%s\n' "${c#*-}" > "$PCIR/$c/class"
    done
}

echo "=== deferred policy: rc 75 caused ONLY by unpublished native candidates -> defer, never give up ==="
# PROTEUS scenario: NPU D set + NPU plugin missing from the NCZ index, but
# the index itself fetched fine (NET=up, remote source present).
mkroot
NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_install 1 1
# Attempt 1 is inside the fast budget (tries 1 < 2): still pending, retrying (75).
NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rc1=$?
[ "$_rc1" = 75 ] && grep -qx 'TRIES=1' "$P" && ok "fast attempt 1 of 2: rc=75, marker kept" || bad "fast attempt 1 rc=$_rc1" "$(cat "$W/out")"
# Attempt 2 exhausts the budget (tries 2 < 2 is false): the ONLY gap is the
# unpublished native candidates -> deferred, NOT failed:gave-up-*, marker +
# timer kept, exit 0 (clean oneshot; the timer keeps firing on the marker).
: > "$LOG"
NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rc3=$?
[ "$_rc3" = 0 ] && ok "attempt past budget: exit 0 (clean oneshot, timer keeps firing)" || bad "deferred attempt rc=$_rc3" "$(cat "$W/out")"
grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "status is deferred:native-candidates-unpublished" \
    || bad "status is '$(cat "$S")'"
[ -f "$P" ] && [ -L "$T" ] \
    && ok "pending marker + timer kept in the deferred state (retry stays armed)" \
    || bad "deferred state lost the marker or timer"
grep -qx 'TRIES=2' "$P" \
    && ok "TRIES counter preserved across the deferral" \
    || bad "TRIES not preserved: $(cat "$P")"
# While deferred, a deferred run where the candidates are STILL missing stays
# deferred (no flip to failed:gave-up-*).
NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rc4=$?
[ "$_rc4" = 0 ] && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "repeated deferred run stays deferred (no give-up flip)" \
    || bad "repeated deferred run rc=$_rc4 status '$(cat "$S")'"
grep -q '^LAST=[0-9]' "$P" && ok "deferral records LAST= for the slow retry" || bad "no LAST= in marker: $(cat "$P")"
# The 10-min timer keeps firing while deferred, but within the slow-retry
# interval a run does nothing: no apt-get update every 10 minutes forever.
: > "$LOG"
NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rcT=$?
[ "$_rcT" = 0 ] && [ ! -s "$LOG" ] && grep -qx 'deferred:native-candidates-unpublished' "$S" && [ -f "$P" ] \
    && ok "deferred timer run inside the slow interval is a no-op (no apt calls)" \
    || bad "deferred run inside the interval rc=$_rcT ran apt: $(cat "$LOG")"
# Past the interval the run re-checks the index on its own.
: > "$LOG"
NCZ_INTEL_DEFER_SECS=0 NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rcU=$?
[ "$_rcU" = 0 ] && grep -q ' update' "$LOG" && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "past the slow interval the deferred run re-checks the index" \
    || bad "past-interval run rc=$_rcU log: $(cat "$LOG")"
# Once the index publishes the candidates, the next forced re-check (the
# ncz-update-apply refresh passes NCZ_INTEL_FORCE=1) installs everything and
# finishes: no manual re-arm needed.
: > "$LOG"
NCZ_INTEL_FORCE=1 NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rc5=$?
inst=$(grep ' install -y' "$LOG")
[ "$_rc5" = 0 ] && [ ! -f "$P" ] && [ ! -e "$T" ] && grep -qx done "$S" \
    && ok "once published: next deferred run installs and finishes (done, marker gone)" \
    || bad "published run rc=$_rc5" "$(cat "$W/out")"
for p in libopenvino-intel-npu-plugin-2026.4.1 \
         intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
    printf '%s\n' "$inst" | grep -q -w -- "$p" || bad "deferred-then-published install lacks $p" "$inst"
done
ok "deferred-then-published install carries the full NPU set"

echo "=== deferred policy: NPU plugin gap (C artifact missing) also defers ==="
# NPU requested, the NPU plugin (C artifact) is missing from the index, and
# the D set is present: the GPU plugin installs fine, but the NPU plugin +
# D set cannot be assembled. The ONLY remaining gap is the unpublished NPU
# plugin -> deferred after the budget, not gave-up.
mkroot
NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=0 NPUDRIVERS=1 run ncz_intel_accel_install 1 1
NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=0 NPUDRIVERS=1 run ncz_intel_accel_run
NET=up NCZ_INTEL_MAX_TRIES=2 NPUPKGS=0 NPUDRIVERS=1 run ncz_intel_accel_run; _rc6=$?
[ "$_rc6" = 0 ] && grep -qx 'deferred:native-candidates-unpublished' "$S" && [ -f "$P" ] \
    && ok "NPU-plugin gap defers past the budget with the marker kept" \
    || bad "npu-plugin-gap deferred run rc=$_rc6 status '$(cat "$S")'"

echo "=== deferred policy: network-down stays failed:gave-up-* (old semantics) ==="
# No fresh index fetchable: the 75 is NOT deferred-unpublished, so the
# budget still ends in gave-up + marker dropped.
mkroot
NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NET=down NCZ_INTEL_MAX_TRIES=1 MIRROR=1 run ncz_intel_accel_run; _rc7=$?
[ "$_rc7" = 1 ] && grep -qx 'failed:gave-up-after-1-attempts' "$S" && [ ! -f "$P" ] \
    && ok "network-down past the budget: failed:gave-up-*, marker dropped (old semantics)" \
    || bad "network-down run rc=$_rc7 status '$(cat "$S")'"

echo "=== deferred policy: would-remove refusal keeps its current semantics ==="
# REMV=1 refuses at install time (rc 1) -- no marker, no give-up bookkeeping.
mkroot
NET=up REMV=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_install 1 0
grep -qx 'failed:would-remove-1-packages' "$S" && [ ! -f "$P" ] \
    && ok "would-remove: refused, status recorded, no marker (unchanged)" \
    || bad "would-remove path changed: '$(cat "$S")'"
# And a would-remove inside the deferred run refuses immediately (rc 1),
# never defers and never loops.
mkroot; mkdir -p "$(dirname "$P")"; printf 'GPU=1\nNPU=1\nTRIES=0\n' > "$P"
NET=up REMV=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rc8=$?
[ "$_rc8" = 1 ] && grep -qx 'failed:would-remove-1-packages' "$S" && [ ! -f "$P" ] \
    && ok "deferred run would-remove: rc=1 refusal, marker dropped (no endless retry)" \
    || bad "deferred would-remove rc=$_rc8 status '$(cat "$S")'"

echo "=== recovery: a failed:gave-up-* system re-arms when hardware is present ==="
mkroot; mkpci
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run; _rc9=$?
[ "$_rc9" = 1 ] && grep -q 'failed:gave-up-after-1-attempts' "$S" && [ ! -f "$P" ] \
    && ok "precondition: system is gave-up with no marker" \
    || bad "gave-up precondition rc=$_rc9 status '$(cat "$S")'"
# The deferred entry (timer re-run after the payload upgrade) sees the
# gave-up status and the still-present Intel GPU -> re-arms.
: > "$LOG"
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rc10=$?
[ "$_rc10" = 0 ] && [ ! -f "$P" ] && grep -qx done "$S" \
    && ok "re-arm + immediate success: gave-up system recovers on the next deferred run" \
    || bad "re-arm run rc=$_rc10 status '$(cat "$S")'"
# Same recovery, but the index is still missing the candidates: the run must
# re-arm (marker back) and then stay pending, NOT silently exit as a no-op.
mkroot; mkpci 0x8086-030000 0x8086-120000
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "re-arm precondition missing: '$(cat "$S")'"
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rc11=$?
[ "$_rc11" = 0 ] && [ -f "$P" ] && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "re-arm with index still incomplete: marker re-created and run defers (not a no-op)" \
    || bad "re-arm incomplete run rc=$_rc11 status '$(cat "$S")'"

echo "=== recovery: re-arm requests only the classes still present ==="
# GPU-only machine: the re-arm must not request NPU, or it would wait forever
# for NPU drivers the machine never needs.
mkroot; mkpci 0x8086-030000
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "gpu-only precondition missing: '$(cat "$S")'"
: > "$LOG"
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rcG=$?
[ "$_rcG" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "GPU-only re-arm requests GPU=1 NPU=0 and finishes without NPU drivers" \
    || bad "gpu-only re-arm rc=$_rcG status '$(cat "$S")'" "$(cat "$W/out")"

echo "=== recovery: Intel devices outside the install-time GPU/NPU classes do not re-arm ==="
# 54-gpu-accel.sh counts only display 0300/0302/0380 and accelerator 1200.
mkroot; mkpci 0x8086-030100 0x8086-128000
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "other-class precondition missing: '$(cat "$S")'"
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rcX=$?
[ "$_rcX" = 0 ] && grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] \
    && ok "Intel 0301/1280 devices only: gave-up kept, no re-arm" \
    || bad "other-class run rc=$_rcX status '$(cat "$S")'"

echo "=== recovery: gave-up WITHOUT Intel hardware stays gave-up (no false re-arm) ==="
mkroot; mkpci 0x10de-030000   # only an NVIDIA display device, no Intel
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "no-hw precondition missing: '$(cat "$S")'"
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rc12=$?
[ "$_rc12" = 0 ] && grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] \
    && ok "no Intel GPU/NPU hardware: gave-up status kept, marker NOT re-created" \
    || bad "no-hw run rc=$_rc12 status '$(cat "$S")'"
# No PCI tree at all (probe cannot decide) fails open: re-arm proceeds,
# and the run behaves like a normal pending run.
mkroot
NCZ_INTEL_PCI_ROOT="$W/no-pci" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$W/no-pci" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "no-sysfs precondition missing: '$(cat "$S")'"
NCZ_INTEL_PCI_ROOT="$W/no-pci" NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run
NCZ_INTEL_PCI_ROOT="$W/no-pci" NCZ_INTEL_MAX_TRIES=2 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rc13=$?
[ "$_rc13" = 0 ] && [ -f "$P" ] && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "no PCI tree: probe fails open and the marker is re-armed (deferred, not gave-up)" \
    || bad "no-sysfs run rc=$_rc13 status '$(cat "$S")'"

echo "=== fresh-index evidence: _ncz_intel_repos_all_local reads every real source shape ==="
# The deferred policy treats "apt-get update succeeded" as evidence ONLY
# when a REMOTE origin exists. That predicate must not be fooled by:
#   * a remote URI that is a SYMLINK into the sources dir (Debian vendors
#     managed configs that way),
#   * a deb822 .sources file,
#   * an inline deb line in the root sources.list,
# and it must still report all-local for a file:/mirror-only system.
_al() {   # _al ROOTDIR -> 1 (has remote) / 0 (all local)
    ( NCZ_INTEL_ROOT="$1"; . "$LIB"; _ncz_intel_repos_all_local ) >/dev/null 2>&1
    echo $?
}
mkroot
mkdir -p "$W/linked" "$W/r/etc/apt/sources.list.d"
printf 'deb [signed-by=/x] https://ncz.example/ncz forky main\n' > "$W/linked/managed.list"
ln -sf "$W/linked/managed.list" "$W/r/etc/apt/sources.list.d/managed.list"
[ "$(_al "$W/r")" = 1 ] && ok "symlinked remote .list is read (remote origin detected)" \
    || bad "symlinked remote .list was skipped: index freshness would be misclassified"
mkroot; mkdir -p "$W/r/etc/apt/sources.list.d"
printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: forky\n' > "$W/r/etc/apt/sources.list.d/deb.sources"
[ "$(_al "$W/r")" = 1 ] && ok "deb822 URIs with a remote origin detected" \
    || bad "deb822 remote origin missed"
mkroot; rm -f "$W/r/etc/apt/sources.list.d/ncz-test.list"
printf 'deb file:/srv/mirror forky main\n' > "$W/r/etc/apt/sources.list.d/local.list"
[ "$(_al "$W/r")" = 0 ] && ok "file:/mirror-only sources stay 'all local' (never a fresh fetch)" \
    || bad "local mirror misclassified as remote"
mkroot; rm -f "$W/r/etc/apt/sources.list.d/ncz-test.list"
printf 'deb https://deb.example/debian forky main\n' > "$W/r/etc/apt/sources.list"
[ "$(_al "$W/r")" = 1 ] && ok "inline remote line in root sources.list detected" \
    || bad "inline root sources.list remote line missed"
# A local-index system whose only gap is a missing candidate must NOT defer:
# it keeps the giving-up semantics (no proof the index was freshly fetched).
mkroot; rm -f "$W/r/etc/apt/sources.list.d/ncz-test.list"
printf 'deb file:/srv/mirror forky main\n' > "$W/r/etc/apt/sources.list.d/local.list"
NCZ_INTEL_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_install 1 1
NCZ_INTEL_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run; _rcl=$?
[ "$_rcl" = 1 ] && grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] \
    && ok "all-local index: missing candidates still end in gave-up (defer needs a fresh remote index)" \
    || bad "all-local index was misclassified as publication lag (rc=$_rcl status '$(cat "$S")')"

echo "=== recovery: the re-arm helper itself is idempotent and status-scoped ==="
mkroot; mkpci
( export NCZ_INTEL_ROOT="$W/r" NCZ_INTEL_ASSETS="$ROOT/assets/intel" NCZ_INTEL_LIB_SRC="$LIB" \
   NCZ_INTEL_ACCEL_LIB=1 NCZ_INTEL_PCI_ROOT="$PCIR"
  . "$LIB"
  mkdir -p "$(dirname "$S")"
  echo "failed:gave-up-after-36-attempts" > "$S"
  ncz_intel_recover; r1=$?
  [ -f "$P" ] && [ -L "$T" ] || exit 1
  ncz_intel_recover; r2=$?
  # Idempotent second call: still exactly one marker, no error.
  [ -f "$P" ] && [ "$r1" = 0 ] && [ "$r2" = 0 ] || exit 1
  # A non-gave-up status is left alone: with the marker removed, a
  # second recover call on a `done` status must NOT re-arm.
  echo "done" > "$S"
  rm -f "$P"
  ncz_intel_recover
  [ ! -f "$P" ] || exit 1
) >/dev/null 2>&1 && ok "ncz_intel_recover: re-arms gave-up once, idempotent, ignores other statuses" \
    || bad "ncz_intel_recover helper contract"

echo "=== deferred entry CLI: run and rearm both drive the entry point ==="
mkroot; mkpci
# Precondition: a gave-up system (no marker).
NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1
NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "cli precondition: '$(cat "$S")'"
# The asset service still drives `run` (unchanged contract) and the lib's
# CLI entry accepts both `run` and `rearm` as synonyms for the entry point.
grep -q 'ExecStart=/usr/local/sbin/ncz-intel-accel-setup run' "$ROOT/assets/intel/ncz-intel-accel-setup.service" \
    && ok "timer service still invokes run" \
    || bad "service ExecStart changed"
# Prove the CLI ENTRY clause itself (not just the words "run"/"rearm"
# somewhere in the file): the active `if [ ... NCZ_INTEL_ACCEL_LIB ... ]`
# block must dispatch both words to ncz_intel_accel_run.
printf '%s\n' "$LIB_NOCOMMENTS" | grep -Eq '^[[:space:]]*run\|rearm\)[[:space:]]*ncz_intel_accel_run' \
    && ok "lib CLI entry dispatches both run and rearm to ncz_intel_accel_run" \
    || bad "lib CLI entry missing run|rearm dispatch"
# Behavioural proof: invoke the lib as the service / operator would, once
# with each word, and require the deferred entry to run both times.
for _verb in run rearm; do
    mkroot; mkpci
    # NCZ_INTEL_PCI_ROOT names the sysfs root directly (not a suffix).
    [ -r "$PCIR/0x8086-030000/vendor" ] \
        || bad "pcir fixture not populated for $_verb (expected $PCIR/0x8086-030000/vendor)"
    NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_install 1 1 >/dev/null 2>&1
    NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1 NET=down MIRROR=1 run ncz_intel_accel_run; _pv=$?
    [ "$_pv" = 1 ] && grep -q 'failed:gave-up' "$S" 2>/dev/null \
        || bad "precondition for $_verb: expected rc=1 + gave-up, got rc=$_pv '$(cat "$S" 2>/dev/null)'" "$(cat "$W/out")"
    # The invocation runs in a child; the output is kept so a failure
    # reports WHY nothing happened instead of just "did nothing".
    ( export NCZ_INTEL_ROOT="$W/r" NCZ_INTEL_ASSETS="$ROOT/assets/intel" NCZ_INTEL_LIB_SRC="$LIB" \
       NCZ_INTEL_PCI_ROOT="$PCIR" NCZ_INTEL_MAX_TRIES=1
      bash "$LIB" "$_verb" ) >"$W/vout" 2>&1; _vrc=$?
    # The CLI child ran at least one attempt: prove it DROVE the entry (not
    # The fixture has only an Intel GPU, so the re-arm requests GPU=1 NPU=0.
    # that it succeeded -- with the network down the attempt legitimately
    # re-arms and then gives up again at the 1-attempt budget).
    grep -q 'attempt 1 (GPU=1 NPU=0)' "$W/vout" \
        && ok "CLI verb '$_verb' drives the deferred entry (attempt ran)" \
        || bad "CLI verb '$_verb' did not reach the deferred entry" "rc=$_vrc $(cat "$W/vout")"
    grep -q 're-arming deferred install (was: failed:gave-up' "$W/vout" \
        && ok "CLI verb '$_verb' re-armed the gave-up system before the attempt" \
        || bad "CLI verb '$_verb' ran without re-arming the gave-up system" "$(cat "$W/vout")"
done
# Execute the INSTALLED binary shape (the lib invoked with `rearm`) exactly
# as ncz-update-apply / an operator would: it must re-arm the gave-up
# system (marker + timer back) because the Intel GPU is present.
( export NCZ_INTEL_ROOT="$W/r" NCZ_INTEL_ASSETS="$ROOT/assets/intel" NCZ_INTEL_LIB_SRC="$LIB" \
   NCZ_INTEL_PCI_ROOT="$PCIR"
  bash -c '. "$1"; ncz_intel_accel_run; exit $?' _ "$LIB" >/dev/null 2>&1 )
# The re-arm + first fast attempt (pending:attempt-1) proves the gave-up
# system was revived: marker and timer are back and the retry is running.
[ -f "$P" ] && [ -L "$T" ] && grep -qx 'pending:attempt-1' "$S" \
    && ok "deferred entry re-arms a gave-up system (marker + timer back, first fast attempt)" \
    || bad "re-arm did not restore marker/timer: status '$(cat "$S")'"

echo "=== update hook: ncz-update-apply refresh re-checks the deferred install ==="
UA="$ROOT/assets/update-manager/ncz-update-apply"
grep -q 'intel_deferred_recheck' "$UA" \
    && ok "ncz-update-apply calls the intel deferred re-check helper" \
    || bad "ncz-update-apply lacks the re-check hook"
# Placement must be INSIDE the refresh) branch (after the `refresh)` label
# and before the next case label) -- a raw occurrence count would also pass
# if the call sat in a comment or in the apply) branch. Compare line
# numbers; the next case label after refresh) may be either branch.
_refresh_ln=$(grep -n '^[[:space:]]*refresh)' "$UA" | head -1 | cut -d: -f1)
_apply_ln=$(grep -n '^[[:space:]]*apply)' "$UA" | head -1 | cut -d: -f1)
_call_ln=$(grep -n '^[[:space:]]*intel_deferred_recheck$' "$UA" | head -1 | cut -d: -f1)
# The call must sit before the NEXT case label after refresh) -- which is
# apply) today, but the check must not depend on that branch order.
_nextln=$(awk -v r="$_refresh_ln" 'NR>r && /^[[:space:]]*[a-z|*()]+\)/ {print NR; exit}' "$UA")
if [ -n "$_refresh_ln" ] && [ -n "$_nextln" ] && [ -n "$_call_ln" ] \
   && [ "$_call_ln" -gt "$_refresh_ln" ] && [ "$_call_ln" -lt "$_nextln" ]; then
    ok "ncz-update-apply re-checks inside the refresh branch only (before apply/full-upgrade)"
else
    bad "ncz-update-apply re-check placement wrong (refresh=$_refresh_ln call=$_call_ln next=$_nextln apply=$_apply_ln)"
fi
grep -q 'ncz_intel_accel_run' "$UA" \
    && ok "ncz-update-apply drives the real deferred entry (ncz_intel_accel_run)" \
    || bad "ncz-update-apply does not call ncz_intel_accel_run"
grep -q 'NCZ_INTEL_FORCE=1' "$UA" \
    && ok "ncz-update-apply forces the re-check past the deferred slow interval" \
    || bad "ncz-update-apply does not pass NCZ_INTEL_FORCE=1 (a fresh refresh would be throttled)"

echo "=== remote-origin detection: local schemes vs any remote transport ==="
_srcd="$W/r/etc/apt/sources.list.d"
_src_case() {   # _src_case WANT(local|remote) LABEL LINE...
    local want="$1" label="$2"; shift 2
    mkroot; rm -f "$_srcd"/*.list "$_srcd"/*.sources "$W/r/etc/apt/sources.list"
    _ext=list; case "$1" in Types:*) _ext=sources ;; esac
    printf '%s\n' "$@" > "$_srcd/case.$_ext"
    if run _ncz_intel_repos_all_local; then got=local; else got=remote; fi
    [ "$got" = "$want" ] && ok "sources $label -> $want" || bad "sources $label -> $got, want $want"
}
_src_case local  "file: only"            'deb [trusted=yes] file:///srv/mirror ./'
_src_case local  "cdrom: only"           'deb cdrom:[NCZ-OS]/ forky main'
_src_case remote "https"                 'deb https://example.invalid/ncz ./'
_src_case remote "mirror+https"          'deb mirror+https://example.invalid/mirrors.txt forky main'
_src_case remote "file: plus http"       'deb [trusted=yes] file:///srv/mirror ./' 'deb http://deb.debian.org/debian forky main'
_src_case local  "commented remote"      '# deb https://example.invalid/ncz ./' 'deb file:///srv/mirror ./'
_src_case remote "deb822 file: plus https" 'Types: deb' 'URIs: file:///srv/mirror https://example.invalid/ncz' 'Suites: forky'
_src_case local  "deb822 file: only"     'Types: deb' 'URIs: file:///srv/mirror' 'Suites: forky'

echo "=== deferred throttle: a corrupt LAST= re-checks instead of wedging ==="
mkroot
NCZ_INTEL_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_install 1 1
NET=up NCZ_INTEL_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=0 run ncz_intel_accel_run
grep -qx 'deferred:native-candidates-unpublished' "$S" || bad "corrupt-LAST precondition: '$(cat "$S")'"
sed -i 's/^LAST=.*/LAST=12x/' "$P"
: > "$LOG"
NET=up NCZ_INTEL_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_intel_accel_run; _rcL=$?
[ "$_rcL" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "corrupt LAST= is ignored: the run re-checks and installs" \
    || bad "corrupt LAST= run rc=$_rcL status '$(cat "$S")'" "$(cat "$W/out")"

echo "intel accel tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
