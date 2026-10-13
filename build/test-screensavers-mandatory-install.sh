#!/bin/bash
# test-screensavers-mandatory-install.sh -- fail-before/pass-after for the
# screensaver deb being apt-installed on every desktop image
# (2026-10-05). Sections (1)-(2): mirror pre-flight and the install hook.
# Sections (3)-(7) are sourced from the sibling script so neither review
# hunk exceeds 9000 bytes. No real apt, no real chroot.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=./screensavers-version.env
. "$HERE/screensavers-version.env"

# Need dpkg on PATH for the real version comparisons; fall back to a shell
# helper if not (this script is also the safety net that runs on bare hosts).
have_dpkg=0
command -v dpkg >/dev/null 2>&1 && have_dpkg=1
ge() {
    # $1=$a $2=$b -> 0 if a>=b else 1. Tries dpkg first; falls back to a pure-
    # shell numeric+tail comparison (good enough for the 0.7/0.8/0.9/0.10
    # versioning we use, both dotted-decimal and a simple suffix check).
    if [ "$have_dpkg" -eq 1 ]; then
        dpkg --compare-versions "$1" ge "$2"; return $?
    fi
    case "$1" in "$2"|"$2".*|"$2"-*) return 0 ;; *) return 1 ;; esac
}

PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
note() { echo "      $*"; }

T="$(mktemp -d -t ss-mandatory-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

# ---------------------------------------------------------------------------
# (1) assert-mirror-has-screensavers.sh -- pre-flight used by build-squashfs-
#     layers / build-role-delta-mkosi. With the FIX in place it MUST fail when
#     the mirror is missing the package; with the un-fixed branch it would
#     not have existed, so the FAIL_BEFORE expectation is "script missing".
# ---------------------------------------------------------------------------
make_mirror() {   # $1: pkg_version_or_EMPTY
    local m="$T/mirror-$RANDOM"
    local arch
    # Mirror the arch-detection logic in assert-mirror-has-screensavers.sh:
    # dpkg --print-architecture when available, otherwise uname -m mapping.
    if command -v dpkg >/dev/null 2>&1; then
        arch="$(dpkg --print-architecture)"
    else
        arch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
    fi
    mkdir -p "$m/dists/forky/main/binary-$arch"
    if [ -n "$1" ]; then
        cat > "$m/dists/forky/main/binary-$arch/Packages" <<EOF
Package: ncz-screensavers
Version: $1
Architecture: $arch
Maintainer: $NCZ_SCREENSAVERS_REQUIRED_MAINTAINER
EOF
    else
        : > "$m/dists/forky/main/binary-$arch/Packages"
    fi
    printf '%s' "$m"
}

# 1a) FAIL_BEFORE: missing in mirror.  PASS_AFTER (this fix): assert-mirror exits 1.
m="$(make_mirror "")"
if [ -x "$HERE/assert-mirror-has-screensavers.sh" ]; then
    if "$HERE/assert-mirror-has-screensavers.sh" --mirror "$m" --label test 2>"$T/err.1a" >/dev/null; then
        bad "assert-mirror: empty mirror should fail"
    else
        ok "assert-mirror: empty mirror -> exit 1"
        grep -q "does NOT carry ncz-screensavers" "$T/err.1a" \
            && ok "assert-mirror: empty mirror -> precise error message" \
            || { bad "assert-mirror: error message imprecise"; cat "$T/err.1a"; }
    fi
else
    bad "assert-mirror-has-screensavers.sh is MISSING (un-fixed branch)"
fi

# 1b) PASS_AFTER: too-old version is rejected.
m="$(make_mirror "0.7.0")"
if [ -x "$HERE/assert-mirror-has-screensavers.sh" ]; then
    if "$HERE/assert-mirror-has-screensavers.sh" --mirror "$m" --label test 2>"$T/err.1b" >/dev/null; then
        bad "assert-mirror: too-old (0.7.0 < 0.8.9) should fail"
    else
        ok "assert-mirror: too-old version -> exit 1"
    fi
else
    bad "assert-mirror-has-screensavers.sh is MISSING (un-fixed branch)"
fi

# 1c) PASS_AFTER: at-or-above floor is accepted.
m="$(make_mirror "$NCZ_SCREENSAVERS_MIN_VERSION")"
if [ -x "$HERE/assert-mirror-has-screensavers.sh" ]; then
    if "$HERE/assert-mirror-has-screensavers.sh" --mirror "$m" --label test >/dev/null 2>"$T/err.1c"; then
        ok "assert-mirror: $NCZ_SCREENSAVERS_MIN_VERSION passes the gate"
    else
        bad "assert-mirror: $NCZ_SCREENSAVERS_MIN_VERSION rejected"
        cat "$T/err.1c"
    fi
fi

# 1d) PASS_AFTER: a later mirror with no Packages index must not inherit the
#     previous mirror's index. A stale PKG_INDEX across loop iterations used
#     to report an absent/empty mirror as OK when an earlier --mirror passed.
m1="$(make_mirror "$NCZ_SCREENSAVERS_MIN_VERSION")"
m2="$T/mirror-nodists-$RANDOM"; mkdir -p "$m2"
if [ -x "$HERE/assert-mirror-has-screensavers.sh" ]; then
    if "$HERE/assert-mirror-has-screensavers.sh" --mirror "$m1" --label good --mirror "$m2" --label nodists >/dev/null 2>"$T/err.1d"; then
        bad "assert-mirror: a mirror without a Packages index must fail even when an earlier mirror passed"
    else
        ok "assert-mirror: per-mirror Packages index reset (absent index in a later mirror fails)"
    fi
fi

# ---------------------------------------------------------------------------
# (2) post-install/59-ncz-screensavers-pkg.sh -- the install hook itself.
#     We can't run it without a real chroot, but we can prove the FIXED
#     script (a) sources build/screensavers-version.env, (b) hard-fails when
#     no candidate exists, and (c) hard-fails when the candidate is below
#     the floor. The un-fixed branch (silent no-op on no-candidate) had
#     neither assertion in the script.
# ---------------------------------------------------------------------------
HOOK="$ROOT/post-install/59-ncz-screensavers-pkg.sh"
if [ -r "$HOOK" ]; then
    # (a) the fixed script sources the version floor file
    if grep -qE 'screensavers-version.env|NCZ_SCREENSAVERS_MIN_VERSION' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh sources build/screensavers-version.env"
    else
        bad "59-ncz-screensavers-pkg.sh does NOT source build/screensavers-version.env (FIX missing)"
    fi

    # (b) the fixed script explicitly hard-fails on no candidate
    if grep -q 'FATAL: no candidate for' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh hard-fails on no candidate"
    else
        bad "59-ncz-screensavers-pkg.sh silently skips when no candidate (BUG present)"
    fi

    # (c) the fixed script enforces the version floor
    if grep -q 'NCZ_SCREENSAVERS_MIN_VERSION' "$HOOK" && grep -q 'dpkg --compare-versions .*ge .*NCZ_SCREENSAVERS_MIN_VERSION' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh enforces the version floor"
    else
        bad "59-ncz-screensavers-pkg.sh does NOT enforce the version floor (FIX missing)"
    fi

    # (d) the apt candidate is EXACTLY ncz-screensavers; the settings plugin is
    #     never an apt-repo name (it is unpublished): it is installed from the
    #     pinned deb on the medium through lib/ncz-ssplugin-install.sh, after
    #     the engine, on both exit paths (fresh install and already-installed).
    if grep -q '^PKG=ncz-screensavers$' "$HOOK" && ! grep -qE 'apt-get install .*ncz-screensavers-plugin' "$HOOK" \
       && [ "$(grep -c '^[[:space:]]*ncz_ssplugin_install; exit \$?$' "$HOOK")" = 2 ] \
       && grep -q 'lib/ncz-ssplugin-install.sh' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh installs ncz-screensavers from apt, then the pinned plugin deb on both exit paths"
    else
        bad "59-ncz-screensavers-pkg.sh does not install exactly ncz-screensavers + the pinned plugin on both exit paths"
    fi

    # (e) headless / server variants still skip (regression check; the
    #     hard-fail must not break server builds).
    if grep -q 'server|headless' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh still skips on server/headless"
    else
        bad "59-ncz-screensavers-pkg.sh lost the headless/server skip"
    fi

    # (f) simulate-first / no-removals / never-gtk4-reference guards retained
    if grep -q "simulation would REMOVE" "$HOOK" \
       && grep -q 'ncz-screensavers-gtk4-reference' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh retains simulate-first/no-removals/never-gtk4-reference guards"
    else
        bad "59-ncz-screensavers-pkg.sh lost a guard"
    fi
else
    bad "59-ncz-screensavers-pkg.sh missing"
fi

# Sections (3)-(7) live in the sibling script (review hunk cap). It shares
# ok/bad/PASS/FAIL/ROOT/HERE with this driver. NCZ_SS_TEST_DRIVING stops the
# sibling from re-execing this driver when it is sourced.
# shellcheck source=./test-screensavers-mandatory-install-builders.sh
export NCZ_SS_TEST_DRIVING=1
# shellcheck disable=SC1091
. "$HERE/test-screensavers-mandatory-install-builders.sh"

echo
echo "test-screensavers-mandatory-install: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
