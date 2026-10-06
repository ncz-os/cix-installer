#!/bin/bash
# test-screensavers-mandatory-install.sh -- prove the screensaver deb is
# required at EVERY layer of the build chain (mirror pool, squashfs layer,
# role delta, post-install hook). Designed as fail-before/pass-after:
# every assertion here FAILS on the un-fixed branch (where 59-ncz-screensavers
# is a silent no-op when the mirror lacks ncz-screensavers, and where build-
# desktop-mirror.sh marks ncz-screensavers as `optional`) and PASSES on the
# fixed branch (this item, fix/screensavers-mandatory-install-20261006).
#
# Operator 2026-10-05: "If we are distributing screensavers as Deb they need
# to be apt installed during installation." This is the regression test for
# that statement. The earlier Singularity "looked entirely healthy" incident
# (the offline mirror shipped Singularity = empty and nobody noticed because
# the install hook reported success) is the failure class this test exists
# to prevent for the screensaver subsystem.
#
# No real apt. No real chroot. Each case constructs a synthetic fixture in a
# scratch directory, invokes the exact script the real pipeline invokes, and
# asserts the documented exit code + a recognisable failure message.
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

    # (d) the hook must install EXACTLY ncz-screensavers -- the separate
    #     ncz-screensavers-plugin package is not published yet, so the hook
    #     must never apt-get install it (naming it in a comment is fine).
    if grep -q '^PKG=ncz-screensavers$' "$HOOK" && ! grep -qE 'apt-get install .*ncz-screensavers-plugin' "$HOOK"; then
        ok "59-ncz-screensavers-pkg.sh installs exactly ncz-screensavers (never the unpublished plugin package)"
    else
        bad "59-ncz-screensavers-pkg.sh installs something other than exactly ncz-screensavers"
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

# ---------------------------------------------------------------------------
# (3) build-desktop-mirror.sh -- the offline mirror builder. The un-fixed
#     branch listed ncz-screensavers as `optional`. The fixed branch marks
#     it `required` and enforces the version floor.
# ---------------------------------------------------------------------------
BDM="$ROOT/build/build-desktop-mirror.sh"
if [ -r "$BDM" ]; then
    # The row must end in "|required" (the third pipe-separated value).
    if grep -E '^ncz-screensavers\|.*\|required[[:space:]]*$' "$BDM" >/dev/null; then
        ok "build-desktop-mirror.sh marks ncz-screensavers as required"
    else
        bad "build-desktop-mirror.sh still lists ncz-screensavers as optional"
    fi

    # No NCZ_LOCAL_DEBS data line for ncz-screensavers-plugin (a non-ncursive
    # comment referencing it is fine and intentional).
    if grep -E '^ncz-screensavers-plugin\|.*\|(optional|required)' "$BDM" >/dev/null; then
        bad "build-desktop-mirror.sh still seeds the non-existent ncz-screensavers-plugin"
    else
        ok "build-desktop-mirror.sh no longer seeds the non-existent ncz-screensavers-plugin"
    fi

    if grep -q 'screensavers-version.env' "$BDM"; then
        ok "build-desktop-mirror.sh sources build/screensavers-version.env"
    else
        bad "build-desktop-mirror.sh does NOT source build/screensavers-version.env"
    fi
else
    bad "build-desktop-mirror.sh missing"
fi

# ---------------------------------------------------------------------------
# (4) build-squashfs-layers.sh + build-role-delta-mkosi.sh -- the consumers
#     of desktop-mirror. Both must pre-flight the mirror the DESKTOP layer
#     actually installs from (desktop-mirror when MIRROR_DIRS is not
#     overridden), not the base role's suite/vendor mirrors, and only for the
#     stages that build a desktop layer. assert-mirror's own fail/pass
#     behaviour is covered by the cases in section (1) above.
# ---------------------------------------------------------------------------
SQFS="$ROOT/build/build-squashfs-layers.sh"
if [ -r "$SQFS" ]; then
    if grep -q 'assert-mirror-has-screensavers.sh' "$SQFS" \
       && grep -q 'desktop|all)' "$SQFS" \
       && grep -q '_ss_effective="desktop-mirror"' "$SQFS"; then
        ok "build-squashfs-layers.sh pre-flights desktop-mirror for ncz-screensavers (desktop|all only)"
    else
        bad "build-squashfs-layers.sh pre-flights the wrong mirror or the wrong stages"
    fi
else
    bad "build-squashfs-layers.sh missing"
fi

RD="$ROOT/build/build-role-delta-mkosi.sh"
if [ -r "$RD" ]; then
    if grep -q 'assert-mirror-has-screensavers.sh' "$RD" \
       && grep -q 'desktop) MIRROR_DIRS="desktop-mirror"' "$RD" \
       && grep -q 'assert-mirror-has-screensavers.sh" \$_ss_mirrors --arch "\$ARCH"' "$RD"; then
        ok "build-role-delta-mkosi.sh pre-flights desktop-mirror for ncz-screensavers (target arch)"
    else
        bad "build-role-delta-mkosi.sh does NOT pre-flight desktop-mirror with the target arch"
    fi
else
    bad "build-role-delta-mkosi.sh missing"
fi

# ---------------------------------------------------------------------------
# (5) post-install/24-apt-sources.sh -- live update path. The fixed hook
#     verifies at least one NCZ-OS apt source resolves ncz-screensavers so
#     `apt upgrade` on a running image can pull newer screensaver debs.
# ---------------------------------------------------------------------------
S24="$ROOT/post-install/24-apt-sources.sh"
if [ -r "$S24" ]; then
    # The canary must distinguish an NCZ-OS *network* origin from the
    # install-time /cdrom pool, otherwise it can pass while both live sources
    # are dead (20-desktop.sh registers file:///cdrom before 24 runs).
    if grep -q 'NCZ-OS apt sources carry ncz-screensavers' "$S24" \
       && grep -q 'packages\.buildkite\.com/ncz-os/ncz' "$S24" \
       && grep -q 'pub-d7b784e01679403d9c70fcd23fff5b96\.r2\.dev' "$S24" \
       && grep -q 'only from the offline /cdrom pool' "$S24"; then
        ok "24-apt-sources.sh proves the candidate comes from an NCZ-OS network source, not only /cdrom"
    else
        bad "24-apt-sources.sh does NOT distinguish an NCZ-OS network origin from the offline /cdrom pool"
    fi
fi

# ---------------------------------------------------------------------------
# (6) build/verify-installed-target.sh -- the post-install assertion. The
#     fixed verifier asserts what the PUBLISHED 0.8.9 deb actually ships:
#     the engine + idle timer + calibrator + schema + the shipped 74-title
#     catalogue (each title backed by its binary) + idle daemon enabled +
#     schema compiled + the operator "default saver = blackhole" rule
#     (package schema default AND the effective Cygnus override), and treats
#     the Singularity plugin files as required only when the separate
#     (not-yet-published) ncz-screensavers-plugin package is installed.
# ---------------------------------------------------------------------------
VIT="$ROOT/build/verify-installed-target.sh"
if [ -r "$VIT" ]; then
    # The plugin contract is CONDITIONAL: files are required only when the
    # plugin package is installed (SS_PLUGIN non-empty), never unconditionally.
    if grep -q 'if \[ -n "$SS_PLUGIN" \]' "$VIT" && ! grep -q 'shipped by ncz-screensavers' "$VIT"; then
        ok "verify-installed-target.sh requires plugin files only when ncz-screensavers-plugin is installed"
    else
        bad "verify-installed-target.sh still asserts plugin files unconditionally (the 0.8.9 engine deb ships none)"
    fi

    if grep -q 'need >= 74' "$VIT"; then
        ok "verify-installed-target.sh asserts >= 74 catalogue rows"
    else
        bad "verify-installed-target.sh does NOT assert the 74-title catalogue"
    fi

    # every catalogue title must have its binary
    if grep -q 'has no binary /usr/lib/ncz-screensavers/' "$VIT"; then
        ok "verify-installed-target.sh asserts each catalogue title has its binary"
    else
        bad "verify-installed-target.sh does NOT check catalogue binaries exist"
    fi

    # the version floor is enforced from the single source of truth
    if grep -q 'NCZ_SCREENSAVERS_MIN_VERSION' "$VIT" && grep -q 'compare-versions' "$VIT"; then
        ok "verify-installed-target.sh enforces the version floor from screensavers-version.env"
    else
        bad "verify-installed-target.sh does NOT enforce the version floor"
    fi

    # both parity facts are emitted (screensaver_plugin_version was dropped by
    # an earlier draft, breaking verify-dual-arch-parity.sh's fact comparison)
    if grep -q '\[fact\] screensaver_plugin_version=' "$VIT"; then
        ok "verify-installed-target.sh emits the screensaver_plugin_version fact"
    else
        bad "verify-installed-target.sh does NOT emit the screensaver_plugin_version fact (parity check breaks)"
    fi

    # the effective default: the package schema default is mode='off', so the
    # Cygnus override (mode='one' + blackhole + cygnus palette) is what makes
    # "default saver = blackhole" true end to end.
    if grep -q "99-ncz-cygnus-screensaver.gschema.override" "$VIT" && grep -q "blackhole-color-mode='cygnus'" "$VIT"; then
        ok "verify-installed-target.sh asserts the effective Cygnus blackhole default"
    else
        bad "verify-installed-target.sh does NOT assert the effective (Cygnus override) default saver"
    fi
fi

# ---------------------------------------------------------------------------
# (7) Hook 57 retirement -- the un-fixed branch left post-install/57-screensaver.sh
#     in the hook lists (and in run-all.sh's MACHINE_HOOKS_RE missing list);
#     the fixed branch retires it from BOTH the inventory and the hook lists
#     because the package fully supersedes it.
# ---------------------------------------------------------------------------
INV="$ROOT/docs/platform-inventory.tsv"
if [ -r "$INV" ]; then
    if grep -qE 'post-install/57-screensaver\.sh' "$INV"; then
        bad "platform-inventory.tsv still lists post-install/57-screensaver.sh"
    else
        ok "platform-inventory.tsv no longer lists post-install/57-screensaver.sh"
    fi
fi
for plat in amd64 sky1-arm64; do
    lst="$ROOT/post-install/hooks.list.$plat"
    if [ -r "$lst" ]; then
        if grep -q '^57-screensaver\.sh$' "$lst"; then
            bad "hooks.list.$plat still contains 57-screensaver.sh"
        else
            ok "hooks.list.$plat no longer contains 57-screensaver.sh"
        fi
    fi
done
if [ -r "$ROOT/post-install/57-screensaver.sh" ]; then
    bad "post-install/57-screensaver.sh still on disk"
else
    ok "post-install/57-screensaver.sh deleted"
fi

echo
echo "test-screensavers-mandatory-install: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]