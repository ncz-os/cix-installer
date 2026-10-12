#!/bin/bash
# test-kernel-purity-pin.sh -- prove, with a real `apt-get install -s`
# simulation against throwaway local repos, that the apt preferences pin
# written by post-install/lib/kernel-purity.sh keeps Debian's default kernel
# out while leaving NCZ's own kernel installable.
#
# This is a genuine apt resolution, not a text grep: it builds an
# `Origin: Debian` repo (linux-image-<prefix>-...-<arch> + the
# linux-image-<arch> metapackage) and an `Origin: NCZ` repo (our kernel), then
# asks apt to install:
#   * test-drags-kernel   Depends:    linux-image-<arch>  -> MUST fail closed
#   * test-recommends-kernel Recommends: linux-image-<arch> -> MUST install
#                                                            the dep WITHOUT the
#                                                            Debian kernel
#   * our NCZ kernel      -> MUST remain installable
# and, as the negative control, repeats the Depends case with NO pin to prove
# the test fails before the fix.
#
# Self-skips (exit 0) when apt/dpkg are unavailable (non-Debian dev host).
#
# Usage: build/test-kernel-purity-pin.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB="$HERE/../post-install/lib/kernel-purity.sh"
[ -r "$LIB" ] || { echo "EXTRACT FAILED: $LIB missing" >&2; exit 2; }

if ! command -v apt-get >/dev/null 2>&1 || ! command -v apt-cache >/dev/null 2>&1 \
   || ! command -v dpkg >/dev/null 2>&1; then
    echo "SKIP: apt-get/apt-cache/dpkg not available on this host -- apt simulation not run"
    exit 0
fi

ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$ARCH" in
    aarch64) ARCH=arm64 ;;
    x86_64)  ARCH=amd64 ;;
esac
case "$ARCH" in
    arm64) DEB_META="linux-image-arm64"; OUR_PKG="linux-image-cixmini"; OUR_VER="7.3.0-rc7-sky1-ncz+r289" ;;
    amd64) DEB_META="linux-image-amd64"; OUR_PKG="linux-image-7.3.0-rc7-t2-ncz"; OUR_VER="7.3.0-rc7-2" ;;
    *) echo "SKIP: unsupported host arch '$ARCH' for the apt simulation"; exit 0 ;;
esac
DEB_VERSIONED="linux-image-7.1.9-1-${ARCH}"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# shellcheck source=../post-install/lib/kernel-purity.sh
. "$LIB"

# --- throwaway apt universe -------------------------------------------------
mk_repo() {  # dir origin label
    local d="$1" origin="$2" label="$3"
    mkdir -p "$d/pool"
    : > "$d/Packages"
    cat > "$d/Release" <<EOF
Origin: $origin
Label: $label
Suite: forky
Codename: forky
Date: $(date -Ru)
Architectures: $ARCH
Components: main
EOF
}
pkg_entry() {  # dir name ver deps recommends
    local d="$1" name="$2" ver="$3" deps="${4:-}" recs="${5:-}"
    {
        printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$name" "$ver" "$ARCH"
        printf 'Maintainer: Test <test@example.invalid>\n'
        [ -n "$deps" ] && printf 'Depends: %s\n' "$deps"
        [ -n "$recs" ] && printf 'Recommends: %s\n' "$recs"
        printf 'Description: %s\n' "$name"
        printf 'Filename: pool/%s_%s_%s.deb\nSize: 1024\n' "$name" "$ver" "$ARCH"
        printf 'SHA256: %064d\n\n' 0
    } >> "$d/Packages"
}

DEB="$T/debian"; NCZ="$T/ncz"
mk_repo "$DEB" Debian Debian
mk_repo "$NCZ" NCZ NCZ
pkg_entry "$DEB" "$DEB_VERSIONED" "7.1.9-1"
pkg_entry "$DEB" "$DEB_META" "7.1.9-1" "$DEB_VERSIONED"
pkg_entry "$DEB" "linux-headers-7.1.9-1-${ARCH}" "7.1.9-1"
pkg_entry "$DEB" "linux-headers-${ARCH}" "7.1.9-1" "linux-headers-7.1.9-1-${ARCH}"
pkg_entry "$DEB" "test-drags-kernel" "1.0" "$DEB_META"
pkg_entry "$DEB" "test-recommends-kernel" "1.0" "" "$DEB_META"
pkg_entry "$NCZ" "$OUR_PKG" "$OUR_VER"
gzip -kf "$DEB/Packages" "$NCZ/Packages"

# The real pin text, straight from the shipped library.
ncz_kernel_purity_pin_text > "$T/pref"
: > "$T/pref-empty"

mkdir -p "$T/state/lists/partial" "$T/cache/archives/partial" \
         "$T/preferences.d" "$T/apt.conf.d" "$T/trusted.gpg.d"
: > "$T/status"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEB ./
deb [trusted=yes] file://$NCZ ./
EOF
aptopts() {  # [preferences path]
    printf '%s\n' \
        -o "Dir::Etc::sourcelist=$T/sources" \
        -o "Dir::Etc::sourceparts=-" \
        -o "Dir::Etc::main=$T/apt.conf" \
        -o "Dir::Etc::parts=$T/apt.conf.d" \
        -o "Dir::Etc::preferences=${1:-$T/pref}" \
        -o "Dir::Etc::preferencesparts=$T/preferences.d" \
        -o "Dir::Etc::trusted=$T/trusted.gpg" \
        -o "Dir::Etc::trustedparts=$T/trusted.gpg.d" \
        -o "Dir::State=$T/state" \
        -o "Dir::State::status=$T/status" \
        -o "Dir::Cache=$T/cache" \
        -o "Debug::NoLocking=1" \
        -o "APT::Get::AllowUnauthenticated=true" \
        -o "Acquire::AllowInsecureRepositories=true"
}
mapfile -t OPTS < <(aptopts)

if ! apt-get "${OPTS[@]}" update >"$T/update.log" 2>&1; then
    echo "SKIP: apt-get update against the local repos failed (cannot simulate)"; sed 's/^/      /' "$T/update.log"; exit 0
fi

candidate() {  # pkg [prefs]
    local p="$1" prefs="${2:-$T/pref}"
    local -a o; mapfile -t o < <(aptopts "$prefs")
    apt-cache "${o[@]}" policy "$p" 2>/dev/null | awk '/^  Candidate:/{sub(/^  Candidate: /,""); print; exit}'
}
install_plan() {  # pkg prefs -> prints apt-get install -s output
    local p="$1" prefs="${2:-$T/pref}"
    local -a o; mapfile -t o < <(aptopts "$prefs")
    apt-get "${o[@]}" install -s -y "$p" 2>&1
}
installs_pkg() {  # pkg prefs -> prints exit code of apt-get install -s
    local p="$1" prefs="${2:-$T/pref}"
    install_plan "$p" "$prefs" >/dev/null 2>&1
    printf '%s' $?
}

echo "=== apt resolves the Debian kernel as unavailable under the pin ==="
[ "$(candidate "$DEB_META")" = "(none)" ] && ok "Debian meta $DEB_META candidate is (none)" \
    || bad "Debian meta candidate was '$(candidate "$DEB_META")', expected (none)"
[ "$(candidate "$DEB_VERSIONED")" = "(none)" ] && ok "Debian versioned $DEB_VERSIONED candidate is (none)" \
    || bad "Debian versioned candidate was '$(candidate "$DEB_VERSIONED")', expected (none)"

echo "=== NCZ's own kernel stays installable ==="
[ "$(candidate "$OUR_PKG")" = "$OUR_VER" ] && ok "our $OUR_PKG candidate is $OUR_VER" \
    || bad "our $OUR_PKG candidate was '$(candidate "$OUR_PKG")', expected $OUR_VER"
out="$(install_plan "$OUR_PKG")"; rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q '0 to remove'; then
    ok "apt-get install -s $OUR_PKG succeeds with 0 removals under the pin"
else
    bad "apt-get install -s $OUR_PKG failed or removed packages (rc=$rc)"
fi

echo "=== a hard dependency cannot drag the Debian kernel back in ==="
rc="$(installs_pkg test-drags-kernel)"
[ "$rc" != 0 ] && ok "test-drags-kernel (Depends: $DEB_META) fails closed under the pin (rc=$rc)" \
    || bad "test-drags-kernel installed under the pin -- Debian kernel was pulled in"

echo "=== a Recommends is skipped, not satisfied by Debian ==="
rc="$(installs_pkg test-recommends-kernel)"
if [ "$rc" = 0 ]; then
    out="$(install_plan test-recommends-kernel)"
    # "Recommended packages:" may still LIST the Debian meta; what matters is
    # that apt does not schedule it (an `Inst <pkg>` plan line).
    if printf '%s\n' "$out" | grep -qE "^Inst .*$DEB_META"; then
        bad "test-recommends-kernel pulled $DEB_META in"
    elif ! printf '%s\n' "$out" | grep -q '0 to remove'; then
        bad "test-recommends-kernel install removed packages"
    else
        ok "test-recommends-kernel installs with 0 removals and without $DEB_META"
    fi
else
    bad "test-recommends-kernel failed to install (rc=$rc)"
fi

echo "=== negative control: WITHOUT the pin the dependency IS satisfied by Debian ==="
rc="$(installs_pkg test-drags-kernel "$T/pref-empty")"
[ "$rc" = 0 ] && ok "no pin -> test-drags-kernel resolves Debian $DEB_META (proves the sim is meaningful)" \
    || bad "no pin -> test-drags-kernel still failed (rc=$rc); the simulation would not prove anything"
[ "$(candidate "$DEB_META" "$T/pref-empty")" != "(none)" ] \
    && ok "no pin -> Debian meta has a candidate ('$(candidate "$DEB_META" "$T/pref-empty")')" \
    || bad "no pin -> Debian meta candidate is (none); sim misconfigured"

echo
echo "=== summary: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" = 0 ]
