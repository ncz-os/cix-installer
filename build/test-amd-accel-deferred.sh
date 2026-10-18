#!/bin/bash
# test-amd-accel-deferred.sh -- AMD GPU/NPU userspace: GPU half is
# Debian-only (Mesa RADV Vulkan ICD; no native NCZ GPU package), NPU half
# is native NCZ-only acquisition (amdxdna driver / XRT runtime), apt
# simulation gate, and the deferred retry when the network is down / the
# native NPU candidates are not yet published. Mirrors
# build/test-intel-accel-deferred.sh's seams and state-machine cases,
# adapted for the AMD facts (see post-install/lib/amd-accel.sh header):
#   * vendor PCI ID 0x1002 (AMD/ATI GPU) / 0x1022 (AMD NPU, XDNA device
#     1502/17f0/17f2/17f3/1b0b/1b0c),
#   * NPU PCI class 0x1180 ("Signal processing controller"), NOT 0x1200,
#   * GPU compute works via Debian mesa-vulkan-drivers + libvulkan1 alone
#     (verified live on ACHILLES/HYDRA 2026-10-17), so the GPU half has NO
#     native-candidate gate.
#
# This runs the real post-install/lib/amd-accel.sh against a fixture root
# (NCZ_AMD_ROOT) with apt-get / apt-cache / dpkg-query stubs that model:
#   * "native NCZ index available" (NET=up, NPUPKGS=1)
#   * "NPU drivers not yet published" (NPUPKGS=0)
#   * "no network / index not refreshable" (NET=down)
#   * "a transaction that would remove packages" (REMV=1)
#
# and covers the deferred policy:
#   * a 75 caused ONLY by native NPU candidates missing from a freshly
#     fetched index does NOT give up after the fast budget: the marker is
#     kept and the status is deferred:native-candidates-unpublished
#     (exit 0);
#   * network-down and would-remove keep the old give-up / refusal
#     semantics;
#   * a failed:gave-up-* system re-arms on the next deferred run (or
#     ncz-update-apply refresh) when the AMD GPU/NPU hardware is present;
#   * the NPU-driver-incomplete-but-GPU-available partial install: the
#     Debian GPU set installs and is done-eligible on its own, while the
#     NPU half defers.
#
# Run: bash build/test-amd-accel-deferred.sh     Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
LIB="$ROOT/post-install/lib/amd-accel.sh"
HOOK="$ROOT/post-install/54-gpu-accel.sh"
W="$(mktemp -d -t amd-accel.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); return 0; }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }

mkdir -p "$W/bin"
# apt-cache: the native NCZ index is reachable only when NET=up; the NPU
# runtime (amd-npu-xrt-<ver>) is published only when NPUPKGS=1 (C
# artifacts); the NPU driver/runtime/firmware set is published only when
# NPUDRIVERS=1 (D artifacts -- not yet published as of 2026-10-17). These
# env toggles are the test seam for "native candidate availability".
cat > "$W/bin/apt-cache" <<'EOF'
#!/bin/sh
case "$1" in
    pkgnames)
        case "$2" in
            amd-npu-xrt-)
                [ "$NET" = up ] && [ "${NPUPKGS:-0}" = 1 ] \
                    && printf 'amd-npu-xrt-1.0\namd-npu-xrt-2.0\n' ;;
        esac
        exit 0 ;;
    policy)
        case "$2" in
            amd-xdna-driver|amd-xdna-firmware|amd-xdna-runtime|amd-xdna-validation)
                if [ "${NPUDRIVERS:-0}" = 1 ]; then
                    echo "$2:"
                    if [ "${VENDOR_ONLY_D:-0}" = 1 ]; then
                        echo "  Candidate: 2.26.0.20260826"
                    else
                        echo "  Candidate: 2.26.0.ncz1~debian"
                    fi
                else
                    echo "$2:"
                    echo "  Candidate: (none)"
                fi
                ;;
            amd-npu-xrt-*)
                echo "$2:"
                if [ "${NPUPKGS:-0}" != 1 ]; then
                    echo "  Candidate: (none)"
                elif [ "${VENDOR_ONLY:-0}" = 1 ]; then
                    echo "  Candidate: 2.26.0"
                else
                    echo "  Candidate: 2.0.ncz1"
                fi
                ;;
            *) echo "$2:"; echo "  Candidate: (none)" ;;
        esac
        exit 0 ;;
esac
EOF
# apt-get: log every call; -s prints Inst (+ Remv when REMV=1); real
# install fails when NET!=up.
# update fails when the network is down: a stale/cached index is NOT a
# fresh fetch, and the deferred policy must treat "index not refreshable"
# as a network-down 75 (give-up semantics), not as publication lag.
cat > "$W/bin/apt-get" <<'EOF'
#!/bin/sh
echo "apt-get $*" >> "$LOG"
case " $* " in
    *" update "*) [ "${NET:-up}" = down ] && exit 100; exit 0 ;;
    *" -s "*) echo "Inst mesa-vulkan-drivers"; [ "${REMV:-0}" = 1 ] && echo "Remv mesa-opencl-icd [1]"; exit 0 ;;
    *" install "*) [ "$NET" = up ] && exit 0
                   # network down: only the Debian set can come (offline mirror, MIRROR=1)
                   [ "${MIRROR:-0}" = 1 ] && ! echo " $* " | grep >/dev/null amd-npu && exit 0
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
    ( export NCZ_AMD_ROOT="$W/r" NCZ_AMD_ASSETS="${KEYASSETS:-$ROOT/assets/amd}" NCZ_AMD_LIB_SRC="$LIB" NCZ_AMD_ACCEL_LIB=1
      [ -n "${NCZ_AMD_PCI_ROOT:-}" ] && export NCZ_AMD_PCI_ROOT
      . "$LIB"; "$@" ) > "$W/out" 2>&1
}   # returns the function's exit status
P="$W/r/var/lib/ncz/amd-accel.pending"
T="$W/r/etc/systemd/system/timers.target.wants/ncz-amd-accel-setup.timer"
S="$W/r/var/lib/ncz/amd-accel.status"
PCIR="$W/pcir"

echo "=== no AMD key/repo wiring: native NCZ only ==="
# The lib must NOT define a vendored AMD key (sha256 pin, KEY URL, or repo
# line); it must not import or trust a vendor origin. Comments are stripped
# before grepping: bare mention of an old URL inside a `# ...` comment is
# not active vendor wiring. The legacy URL pattern itself IS allowed inside
# `ncz_amd_disable_legacy_vendor_list` -- the disabler is by design
# required to recognize it.
LIB_NOCOMMENTS="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$LIB")"
printf '%s\n' "$LIB_NOCOMMENTS" | grep -q 'NCZ_AMD_KEY_SHA256=' \
    && bad "lib still defines a vendored AMD key pin" || ok "lib has no vendored AMD key pin"
printf '%s\n' "$LIB_NOCOMMENTS" | grep -q 'NCZ_AMD_KEY_URL=' \
    && bad "lib still defines an AMD key URL"        || ok "lib has no AMD key URL"
# The disabler MUST exist and reference the legacy URL pattern as a matcher
# -- a literal grep ban would also ban the disabler, which is required.
grep -q 'ncz_amd_disable_legacy_vendor_list' "$LIB" \
    && ok "lib has the rocm.list legacy URL disabler (NCZ_AMD_ROOT-scoped)" \
    || bad "lib has no rocm.list disabler"
# But the lib must NOT WRITE to the rocm list from active code (only the
# disabler RENAMES it; nothing generates/refreshes/trusts it).
printf '%s\n' "$LIB_NOCOMMENTS" | grep -qE '>[[:space:]]*/etc/apt/sources\.list\.d/rocm\.list[[:space:]]*$' \
    && bad "lib still WRITES /etc/apt/sources.list.d/rocm.list" \
    || ok "lib does not write /etc/apt/sources.list.d/rocm.list"
# And it must NOT install the repo.radeon.com ROCm set (that is 54's job,
# not this lib's; this lib is native-NCZ + Debian-only).
printf '%s\n' "$LIB_NOCOMMENTS" | grep -q 'repo.radeon.com' \
    && bad "lib still references repo.radeon.com in active code (the disabler only)" \
    || ok "lib does not reference repo.radeon.com outside the disabler"

# === fixture: ncz_amd_disable_legacy_vendor_list on real temp files ===
# Extract the actual function body from the lib and source it in a subshell
# with logging wrappers defined (the sourced block does NOT include
# helpers). Drive it with REAL temp files under $W to verify: only known
# legacy AMD vendor lines are commented out, unrelated rows preserved, both
# row orders, unique .disabled-for-build.XXXXXX backup created with
# byte-equal content, idempotent second run, lookalike hosts and wrong
# paths untouched, failed mv preserves original with nonzero rc, symlink
# refusal preserves target. No live APT or device access; all fixtures
# under $W.
sed -n '/^ncz_amd_disable_legacy_vendor_list() {/,/^}$/p' "$LIB" > "$W/disabler.sh"
[ -s "$W/disabler.sh" ] && ok "amd disabler function extracted from lib" \
    || { bad "amd disabler function missing from lib"; exit 1; }

# Wrappers matching the real helper signatures used by the sourced block.
cat > "$W/amd_helpers.sh" <<'AHELP'
ncz_amd_log() { printf 'LOG: %s\n' "$*" >&2; }
ncz_amd_log_err() { printf 'ERR: %s\n' "$*" >&2; }
AHELP

# (a) signed-by actual vendor row disabled; unrelated Debian row preserved.
_a="$W/r/etc/apt/sources.list.d/rocm.list"
mkdir -p "$(dirname "$_a")"
cat > "$_a" <<'RLIST'
# legacy rocm.list shipped by an older installer
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/6.4.1 noble main
RLIST
_orig_bytes=$(wc -c < "$_a")
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_a" ) > "$W/out" 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && ok "disabler returned 0 on legacy vendor row" \
    || bad "disabler returned nonzero on legacy vendor row" "rc=$_rc $(cat "$W/out")"
grep -q '^# \[amd-accel\] disabled legacy vendor source: deb ' "$_a" \
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
grep -q 'repo.radeon.com' "$_bak" \
    && ok "backup preserves legacy AMD URL verbatim" \
    || bad "backup lost legacy URL content"

# (b) unrelated Debian row stays ACTIVE and unchanged.
_b="$W/r/etc/apt/sources.list.d/debian-main.list"
mkdir -p "$(dirname "$_b")"
printf 'deb http://deb.debian.org/debian forky main\n' > "$_b"
_b_before=$(cat "$_b")
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_b" ) > "$W/out" 2>&1
[ "$(cat "$_b")" = "$_b_before" ] \
    && ok "unrelated Debian row left ACTIVE and unchanged" \
    || bad "unrelated Debian row was modified"
[ ! -e "$_b.disabled-for-build" ] && [ -z "$(ls -1 "$_b".disabled-for-build.* 2>/dev/null)" ] \
    && ok "no backup created for unrelated Debian row" \
    || bad "unexpected backup for unrelated Debian row"

# (c) both row orders: URL before options, and options before URL.
_c1="$W/r/etc/apt/sources.list.d/order1.list"
printf 'deb https://repo.radeon.com/rocm/apt/6.4.1 noble main\n' > "$_c1"
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_c1" ) > "$W/out" 2>&1
grep -q '^# \[amd-accel\] disabled legacy vendor source:' "$_c1" \
    && ok "URL-first legacy row disabled" \
    || bad "URL-first legacy row NOT disabled"
_c2="$W/r/etc/apt/sources.list.d/order2.list"
printf 'deb-src [arch=amd64] https://repo.radeon.com/amdgpu/6.4.1/ubuntu noble main\n' > "$_c2"
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_c2" ) > "$W/out" 2>&1
grep -q '^# \[amd-accel\] disabled legacy vendor source:' "$_c2" \
    && ok "options-first deb-src legacy row disabled" \
    || bad "options-first deb-src legacy row NOT disabled"

# (d) idempotent second run: backup count unchanged, file unchanged.
# (d1) first run against a file with NO legacy row: no backup is created.
_a1="$W/r/etc/apt/sources.list.d/nolegacy.list"
printf 'deb https://example.invalid/ncz ./\n' > "$_a1"
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_a1" ) >/dev/null 2>&1
[ "$(ls -1 "$_a1".disabled-for-build.* 2>/dev/null | wc -l)" -eq 0 ] \
    && ok "no backup when the file has no legacy vendor row" \
    || bad "unexpected backup for a file without a legacy row"
_a2="$W/r/etc/apt/sources.list.d/idem.list"
printf 'deb https://repo.radeon.com/rocm/apt/6.4.1 noble main\n' > "$_a2"
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_a2" ) >/dev/null 2>&1
_after1=$(cat "$_a2")
_bc1=$(ls -1 "$_a2".disabled-for-build.* 2>/dev/null | wc -l)
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_a2" ) >/dev/null 2>&1
_after2=$(cat "$_a2")
_bc2=$(ls -1 "$_a2".disabled-for-build.* 2>/dev/null | wc -l)
[ "$_after1" = "$_after2" ] && [ "$_bc1" -eq "$_bc2" ] \
    && ok "second run idempotent (content and backup count unchanged)" \
    || bad "second run not idempotent (bc1=$_bc1 bc2=$_bc2)"

# (e) lookalike evil host and wrong AMD path stay ACTIVE and unchanged.
_e1="$W/r/etc/apt/sources.list.d/evil.list"
printf 'deb https://repo.radeon.com.evil.example/rocm/apt/6.4.1 noble main\n' > "$_e1"
_e1_before=$(cat "$_e1")
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_e1" ) >/dev/null 2>&1
[ "$(cat "$_e1")" = "$_e1_before" ] \
    && ok "lookalike evil host row left ACTIVE and unchanged" \
    || bad "lookalike evil host row was modified"
_e2="$W/r/etc/apt/sources.list.d/wrongpath.list"
printf 'deb https://repo.radeon.com/other/2026 noble main\n' > "$_e2"
_e2_before=$(cat "$_e2")
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_e2" ) >/dev/null 2>&1
[ "$(cat "$_e2")" = "$_e2_before" ] \
    && ok "wrong AMD path row left ACTIVE and unchanged" \
    || bad "wrong AMD path row was modified"

# (f) failed mv mock returns 77: original preserved, rc nonzero.
_f="$W/r/etc/apt/sources.list.d/mvfail.list"
printf 'deb https://repo.radeon.com/rocm/apt/6.4.1 noble main\n' > "$_f"
_f_before=$(cat "$_f")
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; mv() { return 77; }; ncz_amd_disable_legacy_vendor_list "$_f" ) > "$W/out" 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "failed mv yields nonzero rc" \
    || bad "failed mv did not yield nonzero rc"
[ "$(cat "$_f")" = "$_f_before" ] \
    && ok "failed mv preserves original file content" \
    || bad "failed mv clobbered original file"

# (g) symlink refusal preserves the pointed-to file.
_g_target="$W/r/etc/apt/sources.list.d/symtarget.list"
printf 'deb https://repo.radeon.com/rocm/apt/6.4.1 noble main\n' > "$_g_target"
_g_before=$(cat "$_g_target")
_g_link="$W/r/etc/apt/sources.list.d/symlink.list"
ln -sf "$_g_target" "$_g_link"
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_g_link" ) > "$W/out" 2>&1
_rc=$?
[ "$_rc" -ne 0 ] && ok "symlink refusal returns nonzero" \
    || bad "symlink refusal returned zero"
[ -L "$_g_link" ] && [ "$(cat "$_g_target")" = "$_g_before" ] \
    && ok "symlink refusal preserves pointed-to file" \
    || bad "symlink refusal modified target"

# (h) existing .disabled-for-build file is skipped (no re-processing).
_h="$W/r/etc/apt/sources.list.d/already.list.disabled-for-build"
printf 'deb https://repo.radeon.com/rocm/apt/6.4.1 noble main\n' > "$_h"
_h_before=$(cat "$_h")
( . "$W/amd_helpers.sh"; . "$W/disabler.sh"; ncz_amd_disable_legacy_vendor_list "$_h" ) >/dev/null 2>&1
[ "$(cat "$_h")" = "$_h_before" ] \
    && ok "already-disabled file skipped (no suffix pile-up)" \
    || bad "already-disabled file was re-processed"


echo "=== GPU-only selector (Debian-only Vulkan set): no native-candidate gate ==="
# The AMD GPU half is Debian-only: with the network up and no NPU
# requested, the Debian Vulkan set installs and the status is done. No
# native candidate probe, no 75, no marker.
mkroot; NET=up NPUPKGS=0 NPUDRIVERS=0 run ncz_amd_accel_install 1 0
inst=$(grep ' install -y' "$LOG")
for p in mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "GPU-only Debian install lacks $p" "$inst"
done
printf '%s\n' "$inst" | grep >/dev/null -w amd-npu \
    && bad "GPU-only selector pulled a native NPU package" "$inst" \
    || ok "GPU-only selector does NOT touch the native NPU namespace"
grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "GPU-only selector marks done (Debian-only, no native gate)" \
    || bad "GPU-only selector did not mark done: '$(cat "$S")' marker='$([ -f "$P" ] && cat "$P" || echo none)'"

echo "=== NPU requested but the native NPU drivers are NOT yet published: NOT done, retry armed ==="
# NPU runtime IS available (C artifacts), but the four D components
# (amd-xdna-driver, amd-xdna-firmware, amd-xdna-runtime,
# amd-xdna-validation) are still in flight. The lib must NOT mark done and
# must NOT silently install a partial set. The GPU half (Debian) still
# installs.
mkroot; NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_install 1 1
inst=$(grep ' install -y' "$LOG")
for p in mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "NPU-missing install lacks GPU Debian $p" "$inst"
done
printf '%s\n' "$inst" | grep -w amd-npu-xrt-2.0 \
    && bad "NPU runtime installed without its driver stack (partial NPU)" "$inst" \
    || ok "NPU runtime NOT installed while its driver set is missing"
for p in amd-xdna-driver amd-xdna-firmware amd-xdna-runtime amd-xdna-validation; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" \
        && bad "NPU drivers not yet published: install should NOT include $p" "$inst" \
        || ok "NPU drivers not yet published: install correctly excludes $p"
done
! grep -qx done "$S" \
    && ok "status NOT 'done' when NPU drivers missing (no silent skip)" \
    || bad "status incorrectly reports done with NPU drivers missing"
[ -f "$P" ] && grep -qx GPU=1 "$P" && grep -qx NPU=1 "$P" \
    && ok "retry armed (timer marker kept) so the next native publish will retry" \
    || bad "retry marker lost even though NPU drivers are missing"
[ -L "$T" ] && [ -f "$W/r/etc/systemd/system/ncz-amd-accel-setup.service" ] && [ -x "$W/r/usr/local/sbin/ncz-amd-accel-setup" ] \
    && ok "timer enabled, service + ncz-amd-accel-setup installed" || bad "deferred units not installed"

echo "=== NPU missing: deferred run also refuses to mark done, keeps pending ==="
# The deferred run only does work when there is a pending marker. Without
# a pre-seeded marker the function returns 0 from `nothing pending` and
# this test would falsely fail for the wrong reason.
mkroot; mkdir -p "$(dirname "$P")"; printf 'GPU=1\nNPU=1\nTRIES=0\n' > "$P"
NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run; rc=$?
[ "$rc" != 0 ] && [ -f "$P" ] && ! grep -qx done "$S" \
    && ok "deferred run with NPU drivers missing: rc=$rc, retry kept, NOT done" \
    || bad "deferred run should have stayed pending" "$(cat "$W/out")"
# Pre-existing contract assertion: pending-state preserves the TRIES counter
# (timer retry bookkeeping); the deferred run increments once and stays.
grep -qE '^TRIES=[1-9][0-9]*' "$P" \
    && ok "TRIES counter incremented by the deferred run" \
    || bad "TRIES counter missing/zero after deferred run" "$(cat "$P")"

echo "=== NPU-only selector, both published: installed, marker + timer gone ==="
: > "$LOG"; NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run
[ ! -f "$P" ] && [ ! -e "$T" ] && grep -qx done "$S" && ok "done: marker removed, timer disabled" || bad "network-up run" "$(cat "$W/out")"
inst=$(grep ' install -y' "$LOG")
for p in mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri \
         amd-npu-xrt-2.0 \
         amd-xdna-driver amd-xdna-firmware amd-xdna-runtime amd-xdna-validation; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "install lacks $p" "$inst"
done
# The lib MUST NOT install phantom (non-native) names; especially no bare
# `amd-npu` (the old repo.radeon.com bug). Match the bare token only:
# `amd-npu-xrt-2.0` carries a suffix and IS a legitimate native name.
printf '%s\n' "$inst" | grep -qwE 'amd-npu( |-| |$)' \
    && bad "asks for the legacy bare 'amd-npu' name (not a native NCZ package)" "$inst" \
    || ok "no phantom bare 'amd-npu' name requested"
# NPU runtime + drivers must all show up in the SAME install -y call
# (parity with the Intel path, where the plugin + its 4 D components are
# one transaction): a split install would strand the runtime without its
# driver stack.
_npucall=$(printf '%s\n' "$inst" | grep -w amd-npu-xrt-2.0 | head -1)
for p in amd-xdna-driver amd-xdna-firmware amd-xdna-runtime amd-xdna-validation; do
    printf '%s\n' "$_npucall" | grep -qw -- "$p" || bad "NPU runtime and $p are not in the same install call" "$_npucall"
done
[ -n "$_npucall" ] && [ "$(printf '%s\n' "$_npucall" | grep -cwE 'amd-npu-xrt-2.0 amd-xdna-driver amd-xdna-firmware amd-xdna-runtime amd-xdna-validation')" -ge 1 ] \
    && ok "all 4 native NPU drivers + runtime were installed in the same call" \
    || bad "NPU set split across install calls: $inst"
grep -q ' -s ' "$LOG" && [ "$(grep -n ' -s ' "$LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n ' install -y' "$LOG" | head -1 | cut -d: -f1)" ] \
    && ok "simulated before installing" || bad "no simulation before install"

echo "=== offline mirror: Debian GPU set installs with no native index, NPU stays pending ==="
mkroot; NET=down MIRROR=1 run ncz_amd_accel_install 1 1
inst=$(grep ' install -y' "$LOG")
for p in mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "offline install lacks GPU Debian $p" "$inst"
done
printf '%s\n' "$inst" | grep -w amd-npu && bad "offline install pulled a native-NCZ package" "$inst" || ok "Debian GPU set installed from the mirror with the network down"
[ -f "$P" ] && ok "NPU still deferred (marker kept, timer armed)" || bad "marker lost although the NPU set is not installed" "$(cat "$W/out")"

echo "=== install time, native index + NPU present, network down -> retry armed (Debian set installs from the mirror) ==="
mkroot; NET=down MIRROR=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_install 1 1
[ ! -s "$W/r/etc/apt/keyrings/rocm.gpg" ] && [ ! -e "$W/r/etc/apt/sources.list.d/rocm.list" ] \
    && ok "no AMD keyring / rocm.list written (lib is native-only + Debian)" \
    || bad "AMD keyring or rocm.list still written"
[ -f "$P" ] && grep -qx GPU=1 "$P" && grep -qx NPU=1 "$P" && ok "retry marker records GPU=1 NPU=1" || bad "no retry marker" "$(cat "$W/out")"
# Network is down, so no native NPU install call should hit at all. The
# Debian GPU set CAN come (MIRROR=1) -- verify it did.
inst=$(grep ' install -y' "$LOG")
for p in mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri; do
    printf '%s\n' "$inst" | grep >/dev/null -w -- "$p" || bad "Debian GPU $p missing on offline install" "$inst"
done
printf '%s\n' "$inst" | grep -w amd-npu && bad "attempted a native NPU install without the native index" "$inst" \
    || ok "no native NPU install attempted without the native index"

echo "=== deferred run, network still down -> stays pending ==="
NET=down run ncz_amd_accel_run; rc=$?
[ "$rc" = 75 ] && [ -f "$P" ] && grep -qx 'TRIES=1' "$P" && ok "exit 75 (timer retries), attempt counted" || bad "deferred down run rc=$rc" "$(cat "$P")"

echo "=== already installed from the mirror: skipped without touching apt install ==="
mkroot; NET=up NPUPKGS=1 NPUDRIVERS=1 INSTALLED="mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri" run ncz_amd_accel_install 1 0
inst=$(grep ' install -y' "$LOG")
printf '%s\n' "$inst" | grep -wE 'mesa-vulkan-drivers|libvulkan1|libgl1-mesa-dri' && bad "reinstalled packages that are already present" "$inst" || ok "present packages are not passed to apt again"
grep -qx done "$S" && ok "status done" || bad "status not done" "$(cat "$W/out")"

echo "=== everything present, network down: nothing to do except the native index ==="
mkroot; NET=down MIRROR=1 INSTALLED="mesa-vulkan-drivers libvulkan1 libgl1-mesa-dri" run ncz_amd_accel_install 1 0
grep -q ' install ' "$LOG" && bad "ran apt install although all Debian packages are present" || ok "no apt install call when the Debian GPU set is already installed"

echo "=== a transaction that would remove packages is refused, not forced ==="
mkroot; NET=up REMV=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_install 1 0
grep -q ' install -y' "$LOG" && bad "installed despite removals" || ok "no install when the simulation removes packages"
grep -q 'failed:would-remove-1-packages' "$S" && [ ! -f "$P" ] && ok "status records the refusal; no endless retry" || bad "removal refusal" "$(cat "$W/out")"

echo "=== 54-gpu-accel.sh wiring ==="
grep -q "grep -qiE '\\\\\[1180\\\\\]:.*\\\\\[1022:(1502|17f0|17f2|17f3|1b0b|1b0c)\\\\\]' && HAS_AMD_NPU=1" "$HOOK" && ok "AMD NPU detection (class [1180] vendor 1022 + XDNA device ID)" || bad "AMD NPU detection changed"
grep -q 'ncz_amd_accel_install "$HAS_AMD" "$HAS_AMD_NPU"' "$HOOK" && ok "54 calls the AMD installer for GPU and NPU" || bad "54 does not call ncz_amd_accel_install"
grep -q 'ConditionPathExists=/var/lib/ncz/amd-accel.pending' "$ROOT/assets/amd/ncz-amd-accel-setup.service" \
    && ! grep -qE '^(Before|RequiredBy)=' "$ROOT/assets/amd/ncz-amd-accel-setup.service" && ok "deferred unit gated on the marker and never ordered before boot targets" || bad "unit gating"

echo "=== assets/amd reaches the image (deferred units still stage) ==="
# Same silent-drop bug the Intel test pins (r201 amd64 build c638bbf8):
# the base staging allowlist + the base fingerprint must both cover
# assets/amd, or the service/timer never reach the image.
SQ="$ROOT/build/build-squashfs-layers.sh"
grep -E '^\s*for a in cix-debs kernel .*\bamd\b' "$SQ" >/dev/null && ok "base staging allowlist stages assets/amd" || bad "build-squashfs-layers.sh base staging loop omits assets/amd"
python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import layerplan as lp; sys.exit(0 if ("path", "assets/amd") in lp.REGISTRY["base"] else 1)' "$ROOT/build/lib" \
    && ok "base fingerprint covers assets/amd (a change rebuilds the base)" || bad "base fingerprint omits assets/amd"
for f in ncz-amd-accel-setup.service ncz-amd-accel-setup.timer; do
    [ -s "$ROOT/assets/amd/$f" ] || bad "assets/amd/$f missing from the tree"
done

# C vendor-only: pkgnames present, candidate lacks ncz -> no native runtime
mkroot
NET=up NPUPKGS=1 NPUDRIVERS=1 VENDOR_ONLY=1 run ncz_amd_accel_install 1 1
! grep -q ' install -y.*amd-npu-' "$LOG" \
    && ok "vendor-only runtime names do not qualify as native candidates" \
    || bad "vendor-only runtime was treated as native" "$(cat "$LOG")"
[ -f "$P" ] && ! grep -qx done "$S" \
    && ok "missing native runtime candidates remain pending despite old vendor names" \
    || bad "vendor-only runtime incorrectly marked done"
# D vendor-only: NPU requested, GPU Debian available -> GPU kept, no NPU args
mkroot
NET=up NPUPKGS=1 NPUDRIVERS=1 VENDOR_ONLY_D=1 run ncz_amd_accel_install 1 1
! grep -qE ' install -y.*(amd-npu-xrt|amd-xdna-driver)' "$LOG" \
    && ok "vendor-only NPU driver candidates cannot install a partial NPU stack" \
    || bad "vendor-only NPU driver stack was accepted" "$(cat "$LOG")"
grep -q ' install -y.*mesa-vulkan-drivers' "$LOG" && [ -f "$P" ] \
    && ok "Debian GPU stays available while vendor-only NPU drivers remain pending" \
    || bad "GPU availability or NPU retry was lost" "$(cat "$W/out")"

# =============================================================================
# Deferred publication-lag policy (mirrors intel-accel.sh 2026-10-17)
# =============================================================================
mkpci() {   # mkpci [VENDOR-DEVICE-CLASS...]  (default: AMD GPU 0x1002-0x15bf-030000)
    if [ "$#" -eq 0 ]; then
        set -- 0x1002-0x15bf-030000
    fi
    rm -rf "$PCIR"; local v d c
    for v in "$@"; do
        IFS='-' read -ra parts <<< "$v"
        v="${parts[0]}"
        d="${parts[1]}"
        c="${parts[2]}"
        mkdir -p "$PCIR/${v}-${d}-${c}"
        printf '%s\n' "$v" > "$PCIR/${v}-${d}-${c}/vendor"
        printf '%s\n' "$d" > "$PCIR/${v}-${d}-${c}/device"
        printf '0x%s\n' "$c" > "$PCIR/${v}-${d}-${c}/class"
    done
}

# An armed marker is what ncz_amd_arm_retry leaves behind for the deferred
# unit. Only `rearm` / ncz_amd_recover (an explicit re-arming actor) may
# reset its attempt counter; a machine armed before the payload upgrade has
# no such actor, so the timer's own `run` must carry the count forward.
arm() {   # arm GPU NPU TRIES
    mkdir -p "$(dirname "$P")"
    printf 'GPU=%s\nNPU=%s\nTRIES=%s\n' "$1" "$2" "$3" > "$P"
}

# _src_case EXPECTED_DESC...: check that _ncz_amd_repos_all_local classifies
# the given sources correctly (0=all local, 1=at least one remote).
_src_case() {
    local _expected="$1"; shift
    local _srcd
    _srcd="$(mktemp -d)"
    for _s in "$@"; do
        echo "$_s" >> "$_srcd/test.list"
    done
    ( export NCZ_AMD_ROOT="$_srcd/root"
      mkdir -p "$_srcd/root/etc/apt/sources.list.d"
      cp "$_srcd/test.list" "$_srcd/root/etc/apt/sources.list.d/test.list"
      . "$LIB"
      if _ncz_amd_repos_all_local; then
          [ "$_expected" = local ] && ok "$_srcd: all-local" || bad "$_srcd: expected remote, got local"
      else
          [ "$_expected" = remote ] && ok "$_srcd: has remote" || bad "$_srcd: expected local, got remote"
      fi
    )
    rm -rf "$_srcd"
}

_src_case local  "file: only"            'deb [trusted=yes] file:///srv/mirror ./'
_src_case local  "cdrom: only"           'deb cdrom:[NCZ-OS]/ forky main'
_src_case remote "https"                 'deb https://example.invalid/ncz ./'
_src_case remote "mirror+https"          'deb mirror+https://example.invalid/mirrors.txt forky main'
_src_case remote "file: plus http"       'deb [trusted=yes] file:///srv/mirror ./' 'deb http://deb.debian.org/debian forky main'
_src_case local  "commented remote"      '# deb https://example.invalid/ncz ./' 'deb file:///srv/mirror ./'
_src_case remote "deb822 file: plus https" 'Types: deb' 'URIs: file:///srv/mirror https://example.invalid/ncz' 'Suites: forky'
_src_case local  "deb822 file: only"     'Types: deb' 'URIs: file:///srv/mirror' 'Suites: forky'
_src_case local  "disabled https line"   'deb [enabled=no] https://deb.debian.org/debian forky main' 'deb file:///srv/mirror ./'
_src_case local  "deb822 Enabled: no"    'Types: deb' 'URIs: https://deb.debian.org/debian' 'Suites: forky' 'Enabled: no' '' 'Types: deb' 'URIs: file:///srv/mirror' 'Suites: forky'
_src_case remote "deb822 enabled stanza" 'Types: deb' 'URIs: https://deb.debian.org/debian' 'Suites: forky' 'Enabled: yes'
_src_case remote "enabled=yes https"     'deb [enabled=yes] https://deb.debian.org/debian forky main'
_src_case local  "https in a trailing comment" 'deb file:///srv/mirror forky main # mirror of https://deb.debian.org/debian'
_src_case local  "enabled=false https"   'deb [enabled=false] https://deb.debian.org/debian forky main' 'deb file:///srv/mirror ./'
_src_case local  "enabled=0 + arch opt"  'deb [arch=amd64 enabled=0] https://deb.debian.org/debian forky main' 'deb file:///srv/mirror ./'
_src_case local  "deb822 Enabled: false" 'Types: deb' 'URIs: https://deb.debian.org/debian' 'Suites: forky' 'Enabled: false'
_src_case remote "enabled=yes kept"      'deb [enabled=yes] https://deb.debian.org/debian forky main'
mkroot; rm -f "$W/r/etc/apt/sources.list.d"/*.list "$W/r/etc/apt/sources.list.d"/*.sources
printf 'deb file:///srv/mirror ./\n' > "$W/r/etc/apt/sources.list"
printf 'deb https://example.invalid/ncz ./\n' > "$W/r/etc/apt/vendor.list"
run _ncz_amd_repos_all_local && ok "a stray etc/apt/vendor.list (not read by apt) is ignored" \
    || bad "etc/apt/vendor.list counted as a configured source"
rm -f "$W/r/etc/apt/vendor.list" "$W/r/etc/apt/sources.list"
mkroot; rm -f "$W/r/etc/apt/sources.list.d"/*.list "$W/r/etc/apt/sources.list.d"/*.sources "$W/r/etc/apt/sources.list"
printf 'deb https://example.invalid/ncz ./\n' > "$W/r/etc/apt/sources.list.d/ncz.disabled-for-build.list"
run _ncz_amd_repos_all_local && bad "ncz.disabled-for-build.list (read by apt) was skipped" \
    || ok "a .list named *.disabled-for-build.list is read, as apt reads it"
rm -f "$W/r/etc/apt/sources.list.d/ncz.disabled-for-build.list"
printf 'deb https://example.invalid/ncz ./\n' > "$W/r/etc/apt/sources.list.d/ncz.list.disabled-for-build.Ab12Cd"
run _ncz_amd_repos_all_local && ok "a 55-t2-firmware backup (not *.list) is ignored, as apt ignores it" \
    || bad "a .disabled-for-build backup counted as a source"
rm -f "$W/r/etc/apt/sources.list.d/ncz.list.disabled-for-build.Ab12Cd"
_src_case remote "deb822 folded URIs"    'Types: deb' 'URIs: file:///srv/mirror' ' https://deb.debian.org/debian' 'Suites: forky'
UA="$ROOT/assets/update-manager/ncz-update-apply"
grep -q "ncz_amd_accel_run' _ \"\$lib\" >/dev/null 2>&1 || true" "$UA" \
    && ok "ncz-update-apply: a still-deferred re-check (rc 75) cannot fail the refresh under set -e" \
    || bad "ncz-update-apply re-check is not guarded against set -e"
# one run at a time: with the lock held elsewhere a run leaves the marker alone
mkroot
NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_install 1 1
_pm=$(cat "$P")
mkdir -p "$W/r/run"; ( flock 8; sleep 5 ) 8>"$W/r/run/ncz-amd-accel.lock" &
_lkpid=$!; sleep 1
NCZ_AMD_LOCK_WAIT=1 NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rcK=$?
wait "$_lkpid" 2>/dev/null
[ "$_rcK" = 0 ] && [ "$(cat "$P")" = "$_pm" ] && grep -q "another run holds" "$W/out" \
    && ok "a run waits for the lock and leaves the marker to the run holding it" \
    || bad "lock not honoured (rc=$_rcK)" "$(cat "$W/out")"
# The install-time entry writes/removes the marker too, and it runs while
# the deferred timer may already be active on an upgrade install. It must
# take the same lock: otherwise it can delete the marker after a deferred
# run re-armed it, or a deferred run can append LAST= to a marker install
# just removed.
mkroot
NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_install 1 1
_pm=$(cat "$P")
mkdir -p "$W/r/run"; ( flock 8; sleep 5 ) 8>"$W/r/run/ncz-amd-accel.lock" &
_lkpid=$!; sleep 1
: > "$LOG"
NCZ_AMD_LOCK_WAIT=1 NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_install 1 1
wait "$_lkpid" 2>/dev/null
[ "$(cat "$P")" = "$_pm" ] && grep -q "another run holds" "$W/out" \
    && ok "install waits for the lock and does not rewrite a marker another run owns" \
    || bad "install-time entry ignores the run lock (marker '$(cat "$P")')" "$(cat "$W/out")"
# And it must not leave the marker holding only LAST= when the file
# vanished between the existence check and the append (the reason the
# append is guarded).
grep -A2 'elif \[ -f "\$_pf" \]' "$LIB" | grep -q 'echo "LAST=' \
    && ok "the LAST= append stays guarded on the marker still existing" \
    || bad "the LAST= append is no longer existence-guarded"

grep -A8 '^ncz_amd_recover()' "$LIB" | grep -q . \
    && awk '/^ncz_amd_recover\(\)/,/^}/' "$LIB" | grep -q 'systemctl start ncz-amd-accel-setup.timer' \
    && awk '/^ncz_amd_recover\(\)/,/^}/' "$LIB" | grep -q '\[ -z "$(_na_r)" \] && \[ -d /run/systemd/system \]' \
    && ok "recover starts the timer on a running system only (not for a target root)" \
    || bad "recover does not start the timer on a running system"

echo "=== fresh-index evidence: a deb822 file is judged field by field ==="
# A deb822 stanza is a set of fields in arbitrary order; the remote-origin
# probe must find the URIs: field wherever it sits, honour Enabled: no, and
# join folded continuation lines. Each case writes a file of its own (NOT
# under sources.list.d, so no earlier case can satisfy the detector) and is
# driven through the same detector the deferred policy uses.
d822() {   # d822 LABEL REMOTE(1)/LOCAL(0) FIELD...
    f="$W/deb822-case.sources"
    printf '%s\n' "${@:3}" > "$f"
    if ( export NCZ_AMD_ROOT="$W/r" NCZ_AMD_ACCEL_LIB=1; . "$LIB"; _ncz_amd_has_remote_uri "$f" ) >/dev/null 2>&1; then got=1; else got=0; fi
    # ok()/bad() both return 0, so `test && ok || bad` runs BOTH branches
    # (a PASS is followed by a FAIL). Guard the call, not the return value.
    case "$got" in
        "$2") ok "deb822: $1" ;;
        *) bad "deb822 field order: $1 (detected remote=$got, want $2)" ;;
    esac
}
mkroot
d822 "URIs after Types/Suites (remote)" 1 'Types: deb' 'Suites: forky' 'URIs: https://example.invalid/ncz'
d822 "URIs after Components (remote)"   1 'Types: deb' 'Suites: forky' 'Components: main' 'URIs: https://example.invalid/ncz'
d822 "URIs after Types/Suites (local)"  0 'Types: deb' 'Suites: forky' 'URIs: file:///srv/mirror'
d822 "URIs first (remote)"              1 'URIs: https://example.invalid/ncz' 'Types: deb' 'Suites: forky'
d822 "folded URIs, field not first"     1 'Types: deb' 'URIs: file:///srv/mirror' ' https://example.invalid/ncz' 'Suites: forky'
d822 "disabled stanza with late URIs"   0 'Types: deb' 'Suites: forky' 'URIs: https://example.invalid/ncz' 'Enabled: no'

echo "=== deferred throttle: a corrupt LAST= re-checks instead of wedging ==="
mkroot
NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_install 1 1
NET=up NCZ_AMD_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run
grep -qx 'deferred:native-candidates-unpublished' "$S" || bad "corrupt-LAST precondition: '$(cat "$S")'"
sed -i 's/^LAST=.*/LAST=12x/' "$P"
: > "$LOG"
NET=up NCZ_AMD_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rcL=$?
[ "$_rcL" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "corrupt LAST= is ignored: the run re-checks and installs" \
    || bad "corrupt LAST= run rc=$_rcL status '$(cat "$S")'" "$(cat "$W/out")"

mkroot
NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_install 1 1
NET=up NCZ_AMD_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run
grep -qx 'deferred:native-candidates-unpublished' "$S" || bad "future-LAST precondition: '$(cat "$S")'"
sed -i "s/^LAST=.*/LAST=$(( $(date +%s) + 30 * 86400 ))/" "$P"
NET=up NCZ_AMD_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rcF=$?
[ "$_rcF" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "future LAST= is ignored: the run re-checks and installs" \
    || bad "future LAST= run rc=$_rcF status '$(cat "$S")'" "$(cat "$W/out")"

# The slow-retry decision must be driven by an explicit "the stamp is
# usable" test, never by arithmetic on a variable the case above may have
# emptied. The status guard makes the arithmetic short-circuit return 0
# here, which is also the permissive (re-check) answer: nothing is
# throttled.
mkroot
mkdir -p "$(dirname "$P")"; printf 'GPU=0\nNPU=1\nTRIES=1\nLAST=\n' > "$P"
echo "deferred:native-candidates-unpublished" > "$S"
: > "$LOG"
NET=up NPUDRIVERS=0 NCZ_AMD_FORCE=0 run ncz_amd_accel_run; _rcE=$?
# rc 0 or 75 both mean the run went on to check the index; a throttled run
# returns 0 WITHOUT any apt call, which is what this case forbids.
grep -q ' update' "$LOG" \
    && ok "an empty LAST= re-checks instead of wedging on arithmetic with no stamp" \
    || bad "empty LAST= run rc=$_rcE was throttled or failed early: $(cat "$LOG")"

mkroot
NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_install 1 1
NET=up NCZ_AMD_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run
sed -i "s/^LAST=.*/LAST=09/" "$P"
NET=up NCZ_AMD_MAX_TRIES=1 NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rcO=$?
[ "$_rcO" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "an octal-looking LAST=09 is ignored instead of aborting the run" \
    || bad "LAST=09 run rc=$_rcO status '$(cat "$S")'" "$(cat "$W/out")"

echo "=== recovery: a failed:gave-up-* system re-arms when hardware is present ==="
mkroot; mkpci
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_install 1 1
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_run; _rc9=$?
[ "$_rc9" = 1 ] && grep -q 'failed:gave-up-after-1-attempts' "$S" && [ ! -f "$P" ] \
    && ok "precondition: system is gave-up with no marker" \
    || bad "gave-up precondition rc=$_rc9 status '$(cat "$S")'"
# The deferred entry (timer re-run after the payload upgrade) sees the
# gave-up status and the still-present AMD GPU -> re-arms.
: > "$LOG"
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rc10=$?
[ "$_rc10" = 0 ] && [ ! -f "$P" ] && grep -qx done "$S" \
    && ok "re-arm + immediate success: gave-up system recovers on the next deferred run" \
    || bad "re-arm run rc=$_rc10 status '$(cat "$S")'"
# Same recovery, but the index is still missing the candidates: the run
# must re-arm (marker back) and then stay pending, NOT silently exit as a
# no-op. NPU=1 so the mirror seam cannot satisfy the NPU half; the 75 is
# the native index not being refreshable (NET=down) -- but the recovery
# run is NET=up with NPUPKGS=1 NPUDRIVERS=0 (runtime published, driver
# set missing) which is the publication-lag class -> defers.
mkroot; mkpci 0x1002-0x15bf-030000 0x1022-0x1502-118000
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_install 1 1
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "re-arm precondition missing: '$(cat "$S")'"
# The re-arm requests GPU=1 NPU=1 (both classes present); attempt 1 is a
# fast pending (tries 1 < 2), attempt 2 exhausts the budget and defers
# (the NPU set is still missing from the freshly fetched index).
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run; _rc11=$?
[ "$_rc11" = 0 ] && [ -f "$P" ] && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "re-arm with index still incomplete: marker re-created and run defers (not a no-op)" \
    || bad "re-arm incomplete run rc=$_rc11 status '$(cat "$S")'"

echo "=== recovery: re-arm requests only the classes still present ==="
# GPU-only machine: the re-arm must not request NPU, or it would wait
# forever for NPU drivers the machine never needs.
mkroot; mkpci 0x1002-0x15bf-030000
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_install 1 1
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "gpu-only precondition missing: '$(cat "$S")'"
: > "$LOG"
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run; _rcG=$?
[ "$_rcG" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "GPU-only re-arm requests GPU=1 NPU=0 and finishes without NPU drivers" \
    || bad "gpu-only re-arm rc=$_rcG status '$(cat "$S")'" "$(cat "$W/out")"

echo "=== recovery: an AMD NPU (1022:1502, class 1180) re-arms the NPU class ==="
# NPU-only machine: the re-arm must request NPU=1 (and only NPU=1).
# GPU=0 NPU=1 with the driver set missing defers (never done: the NPU set
# is missing). The gave-up precondition is armed with NPU=1 (so the NPU
# half is requested and can give up); the recovery run is NET=up with the
# runtime published but the driver set missing (publication lag -> defer).
mkroot; mkpci 0x1022-0x1502-118000
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_install 1 1
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_run >/dev/null 2>&1
grep -q 'failed:gave-up' "$S" && [ ! -f "$P" ] || bad "npu-only precondition missing: '$(cat "$S")'"
# The re-arm requests GPU=0 NPU=1 (NPU class only present); with the
# budget exhausted (1 >= 1) and the index still missing the driver set,
# the run DEFERS (not gave-up, not done).
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run; _rcN=$?
[ "$_rcN" = 0 ] && [ -f "$P" ] && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && grep -qx 'GPU=0' "$P" && grep -qx 'NPU=1' "$P" \
    && ok "NPU-only re-arm requests GPU=0 NPU=1 and defers (never done with the NPU set missing)" \
    || bad "npu-only re-arm rc=$_rcN status '$(cat "$S")' marker '$([ -f "$P" ] && cat "$P" || echo none)'" "$(cat "$W/out")"

echo "=== retry budget: an explicit re-arm starts a new budget ==="
mkroot; mkpci
arm 1 1 35
NCZ_AMD_PCI_ROOT="$PCIR" NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rcB=$?
[ "$_rcB" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "re-arm with all published: done immediately" \
    || bad "re-arm all-published rc=$_rcB status '$(cat "$S")'"
mkroot; mkpci
arm 1 1 35
NCZ_AMD_PCI_ROOT="$PCIR" NET=down MIRROR=1 run ncz_amd_accel_run; _rcB2=$?
[ "$_rcB2" = 1 ] && grep -q 'failed:gave-up-after-36-attempts' "$S" && [ ! -f "$P" ] \
    && ok "budget exhausted at 36: gave-up" \
    || bad "budget-36 rc=$_rcB2 status '$(cat "$S")'"
# Now re-arm explicitly: the new budget starts at 0.
mkroot; mkpci
arm 1 1 0
NCZ_AMD_PCI_ROOT="$PCIR" NET=up NPUPKGS=1 NPUDRIVERS=1 run ncz_amd_accel_run; _rcB3=$?
[ "$_rcB3" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \
    && ok "re-arm with TRIES=0 and all published: done" \
    || bad "re-arm TRIES=0 rc=$_rcB3 status '$(cat "$S")'"
# Re-arm with the index incomplete: the new budget is bounded.
mkroot; mkpci
arm 1 1 0
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=up NPUPKGS=1 NPUDRIVERS=0 run ncz_amd_accel_run; _rcB4=$?
[ "$_rcB4" = 0 ] && grep -qx 'deferred:native-candidates-unpublished' "$S" \
    && ok "re-armed budget defers at TRIES=2" \
    || bad "recover re-arm budget rc=$_rcB4 status '$(cat "$S")' tries '$(sed -n 's/^TRIES=//p' "$P" 2>/dev/null)'"
arm 1 1 2
NCZ_AMD_PCI_ROOT="$PCIR" NCZ_AMD_MAX_TRIES=1 NET=down MIRROR=1 run ncz_amd_accel_run; _rcB4b=$?
[ "$_rcB4b" = 1 ] && grep -q 'failed:gave-up-after-3-attempts' "$S" \
    && ok "the re-armed budget is bounded: the next failure gives up after 2" \
    || bad "re-armed budget not bounded rc=$_rcB4b status '$(cat "$S")'"

[ "$_rcO" = 0 ] && grep -qx done "$S" && [ ! -f "$P" ] \

echo "amd accel tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
