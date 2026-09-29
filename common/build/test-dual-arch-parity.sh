#!/bin/bash
# Fixture tests for build/lint-hook-arch-gates.sh and build/verify-dual-arch-parity.sh (both directions).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
expect() { # name want-rc cmd...
    local n="$1" want="$2"; shift 2
    "$@" >"$T/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ $rc = 0 ]; } || { [ "$want" != 0 ] && [ $rc != 0 ]; }; then PASS=$((PASS+1)); echo "ok   $n"
    else FAILS=$((FAILS+1)); echo "FAIL $n (rc=$rc, wanted $want)"; sed 's/^/     /' "$T/out"; fi
}
# ---- hook lint fixtures
H="$T/hooks"; mkdir -p "$H"
sky=$'echo sky1\necho mali\necho panthor\necho npu'
printf '#!/bin/bash\n%s\n' "$sky" > "$H/10-ungated.sh"
printf '#!/bin/bash\n[ "$(uname -m)" = aarch64 ] || exit 0\n%s\n' "$sky" > "$H/11-gated.sh"
printf '#!/bin/bash\n# sky1 mali panthor npu vpu\necho hello\n' > "$H/12-comments-only.sh"
printf '#!/bin/bash\nv=$(cat /sys/class/dmi/id/sys_vendor)\n%s\n' $'echo t2linux\necho apple\necho nvidia\necho intel' > "$H/13-dmi.sh"
printf '#!/bin/bash\necho t2linux\necho apple\necho nvidia\necho intel\n' > "$H/14-x86-ungated.sh"
: > "$T/allow.tsv"
lint() { LINT_HOOK_DIR="$H" LINT_ALLOWLIST="$T/allow.tsv" "$HERE/lint-hook-arch-gates.sh"; }
expect "lint: ungated sky1 + x86 hooks fail" 1 lint
rm "$H/10-ungated.sh" "$H/14-x86-ungated.sh"
expect "lint: gated, comment-only and DMI-gated hooks pass" 0 lint
printf '#!/bin/bash\n%s\n' "$sky" > "$H/10-ungated.sh"
printf '10-ungated.sh\tlegacy, owned by phase B\n' > "$T/allow.tsv"
expect "lint: an allowlisted hook with a reason passes" 0 lint
printf '10-ungated.sh\t\n' > "$T/allow.tsv"
expect "lint: an allowlist row without a reason does not excuse" 1 lint
printf '10-ungated.sh\twhy\n99-gone.sh\twhy\n' > "$T/allow.tsv"
expect "lint: a stale allowlist row fails" 1 lint
expect "lint: the real tree passes" 0 "$HERE/lint-hook-arch-gates.sh"
# ---- facts comparison
good() { printf '[fact] arch=%s\n[fact] hostname_format_ok=1\n[fact] sudo_ok=1\n[fact] screensavers_version=%s\n[fact] bing_plugin_patched=1\n[fact] sensors_plugin_patched=1\n[fact] gpu_policy_ok=1\n[fact] ssh_password_ok=1\n[fact] release_version=26.7\n[fact] release_codename=Maximilian\n' "$1" "${2:-0.3.4}"; }
good arm64 > "$T/a.txt"; good amd64 > "$T/b.txt"
expect "facts: matching targets pass" 0 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a.txt" "$T/b.txt"
good amd64 0.3.3 > "$T/b2.txt"
expect "facts: screensavers version drift fails" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a.txt" "$T/b2.txt"
sed 's/sensors_plugin_patched=1/sensors_plugin_patched=0/' "$T/b.txt" > "$T/b3.txt"
expect "facts: unpatched sensors plugin on one arch fails" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a.txt" "$T/b3.txt"
sed 's/hostname_format_ok=1/hostname_format_ok=0/' "$T/a.txt" > "$T/a4.txt"
sed 's/ssh_password_ok=1/ssh_password_ok=0/' "$T/b.txt" > "$T/b6.txt"
expect "facts: password login off on one arch fails" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a.txt" "$T/b6.txt"
sed 's/gpu_policy_ok=1/gpu_policy_ok=0/' "$T/a.txt" > "$T/a7.txt"
expect "facts: gpu policy not enforced on one arch fails" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a7.txt" "$T/b.txt"
expect "facts: bad hostname fails" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a4.txt" "$T/b.txt"
expect "facts: swapped arch files fail" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/b.txt" "$T/a.txt"
sed 's/release_codename=Maximilian/release_codename=Other/' "$T/b.txt" > "$T/b5.txt"
expect "facts: release codename drift fails" 1 "$HERE/verify-dual-arch-parity.sh" --facts "$T/a.txt" "$T/b5.txt"
# ---- manifest parity fixtures
R="$T/root"; mkdir -p "$R/manifests" "$R/build" "$R/post-install"
for m in desktop installer-base rescue; do printf 'a\nb\n' > "$R/manifests/$m.pkgs"; printf 'a\nb\n' > "$R/manifests/$m-amd64.pkgs"; done
cp "$HERE/lint-hook-arch-gates.sh" "$R/build/"; cp "$HERE/verify-dual-arch-parity.sh" "$R/build/"; : > "$R/build/arch-parity-allowlist.tsv"
mp() { NCZ_SCREENSAVERS_DEBS=/nonexistent PARITY_ROOT="$R" "$R/build/verify-dual-arch-parity.sh"; }
expect "manifests: identical pairs pass" 0 mp
echo "arm-only-pkg" >> "$R/manifests/desktop.pkgs"
expect "manifests: an unlisted arm64-only package fails" 1 mp
printf 'desktop\tarm-only-pkg\tarm64-only\treason\n' > "$R/build/arch-parity-allowlist.tsv"
expect "manifests: the allowlisted package passes" 0 mp
echo "x86-only-pkg" >> "$R/manifests/rescue-amd64.pkgs"
expect "manifests: an unlisted amd64-only package fails" 1 mp
printf 'desktop\tarm-only-pkg\tarm64-only\treason\nrescue\tx86-only-pkg\tarm64-only\twrong side\n' > "$R/build/arch-parity-allowlist.tsv"
expect "manifests: allowlist side must match" 1 mp
echo "parity tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
