#!/usr/bin/env bash
# test-module-dkms-collision.sh -- reproduction for ruling 7 (2026-11-06).
#
# THE DEFECT
# A kver-scoped prebuilt module package owns
#     /lib/modules/<kver>/updates/dkms/<mod>.ko
# and DKMS builds its modules into that same directory (DEST_MODULE_LOCATION
# "/updates/dkms" in assets/kernel/*/dkms.conf). DPKG REFUSES to let two
# packages own one path, so installing a kernel (or a module package) while the
# other is present ends with the archive rejected and the package left
# half-installed -- the "iF" state the operator described. build/audit-dpkg-state.sh
# REPORTS this class after the fact; nothing prevents it.
#
# WHAT THIS TEST DOES
# Builds two real .debs that ship the same path and installs them into a private
# dpkg root. Today dpkg answers:
#     trying to overwrite '/lib/modules/<kver>/updates/dkms/<mod>.ko',
#     which is also in package <module package>
# and the second install fails. That is the reproduction.
#
# EXPECTATION
# While the defect is open this test reports XFAIL (expected failure) and exits
# 0, so CI is not red for a known defect. Set NCZ_EXPECT_COLLISION_FIXED=1 once
# the packaging fix lands and it becomes a hard gate: it then FAILS unless the
# two packages coexist.
#
# WHY NOT A CANDIDATE FIX HERE: the choice between shipping prebuilt modules to
# updates/ (the kernel builder already does that for the GPU modules), adding
# Replaces/Conflicts, or diverting the directory changes boot behaviour and has
# to be proven on a real kernel install (KVM), not in a fixture root. The
# fixture can only prove "two owners collide", which is what it does.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
pass=0; fail=0; xfail=0
ok()   { pass=$((pass + 1)); echo "  PASS  $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
xf()   { xfail=$((xfail + 1)); echo "  XFAIL $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

command -v dpkg-deb >/dev/null || { echo "SKIP: no dpkg-deb"; exit 0; }
command -v dpkg >/dev/null || { echo "SKIP: no dpkg"; exit 0; }

# shellcheck source=lib/deb-fixture.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/deb-fixture.sh"
ncz_deb_fixture_check || { echo "dkms-collision: ENVIRONMENT: this host cannot build deb fixtures; not a code failure" >&2; exit 3; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-dkms-collide.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
KV="9.9.9-test-ncz"

mkdeb() {  # mkdeb <name> <version> <file under updates/dkms>
    local n="$1"; local v="$2"; local f="$3"; local d
    d="$T/src-$n"
    mkdir -p "$d/DEBIAN" "$d/lib/modules/$KV/updates/dkms"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\nMaintainer: t <t@example.invalid>\nDescription: fixture\n' \
        "$n" "$v" > "$d/DEBIAN/control"
    : > "$d/lib/modules/$KV/updates/dkms/$f"
    local msg
    msg="$(dpkg-deb --root-owner-group -b "$d" "$T/${n}_${v}_all.deb" 2>&1)" \
        || msg="$(dpkg-deb -b "$d" "$T/${n}_${v}_all.deb" 2>&1)" \
        || { echo "fixture build failed: $msg" >&2; return 1; }
    [ -s "$T/${n}_${v}_all.deb" ] || { bad "the fixture deb $n was built"; return 1; }
}

ROOT="$T/root"
mkdir -p "$ROOT/var/lib/dpkg/info" "$ROOT/var/log"
: > "$ROOT/var/lib/dpkg/status"
dpi() { dpkg --root="$ROOT" --log="$ROOT/var/log/dpkg.log" --force-not-root \
             --force-script-chrootless -i "$@"; }

mkdeb "t2gmux-modules-$KV" 1 t2gmux.ko && mkdeb "linux-image-$KV" 1 t2gmux.ko \
    && ok "both fixture debs built, each shipping updates/dkms/t2gmux.ko" \
    || { echo "test-module-dkms-collision: fixture could not be built"; exit 1; }

dpi "$T/t2gmux-modules-${KV}_1_all.deb" > "$T/a.log" 2>&1
rc_a=$?
[ "$rc_a" = 0 ] && ok "control: the module package installs on its own" \
    || bad "control: the module package installs on its own" "$(tail -3 "$T/a.log")"

dpi "$T/linux-image-${KV}_1_all.deb" > "$T/b.log" 2>&1
rc_b=$?
msg="$(grep -iE 'trying to overwrite' "$T/b.log" | head -1)"

if [ "$rc_b" = 0 ]; then
    ok "the kernel package installs while the module package owns the same path (defect fixed)"
    if [ "${NCZ_EXPECT_COLLISION_FIXED:-0}" != 1 ]; then
        echo "  NOTE  the reproduction no longer reproduces; flip NCZ_EXPECT_COLLISION_FIXED=1 in CI"
    fi
elif [ -n "$msg" ]; then
    if [ "${NCZ_EXPECT_COLLISION_FIXED:-0}" = 1 ]; then
        bad "the collision must be gone but dpkg still refuses the second package" "$msg"
    else
        xfail=$((xfail + 1))
        echo "  XFAIL dpkg refuses two packages owning updates/dkms/t2gmux.ko (known defect)"
        printf '%s\n' "        $msg" | cut -c1-150
    fi
else
    bad "the kernel install failed for a different reason than the known collision" "$(tail -4 "$T/b.log")"
fi

echo
if [ "${NCZ_EXPECT_COLLISION_FIXED:-0}" = 1 ]; then
    echo "module-dkms-collision (gate mode): $pass passed, $fail failed"
else
    echo "module-dkms-collision (reproduction mode): $pass passed, $fail failed, $xfail expected failure"
fi
[ "$fail" = 0 ]
