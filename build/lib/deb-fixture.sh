#!/bin/bash
# deb-fixture.sh -- can this host build the .deb fixtures a test needs?
#
# WHY. On 2026-11-06 cycle 463 HYDRA's /tmp hit its per-user quota and
# `dpkg-deb -b` produced empty archives. Tests that suppress dpkg-deb's stderr
# then reported 33 assertion failures ("unreadable deb", "compress subprocess
# failed") which read as code regressions. One check up front turns that into a
# single sentence naming the host problem.
#
# Exit codes for callers: the check itself returns 0 when fixtures work, 1 when
# they do not (reason on stderr). Tests should exit 3 in that case: "the host
# cannot build fixtures" is not a code failure and must not look like one.
#
# Usage:
#   . "$(dirname "$0")/lib/deb-fixture.sh"
#   ncz_deb_fixture_check || { echo "SKIP/ENV: ..." >&2; exit 3; }

ncz_deb_fixture_check() {
    local base d out msg
    base="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-fixture-check.XXXXXX" 2>/dev/null)" || {
        echo "cannot create a temp dir under ${TMPDIR:-/var/tmp}: /tmp quota or permissions" >&2
        return 1
    }
    d="$base/pkg"; mkdir -p "$d/DEBIAN" "$d/usr/share/ncz-fixture" || {
        echo "cannot create fixture tree under ${TMPDIR:-/var/tmp}: quota or permissions" >&2
        rm -rf "$base"; return 1
    }
    printf 'Package: ncz-fixture-check\nVersion: 1\nArchitecture: all\nMaintainer: ncz <ncz@example.invalid>\nDescription: fixture check\n' \
        > "$d/DEBIAN/control" 2>/dev/null || {
        echo "cannot write a control file under ${TMPDIR:-/var/tmp}: quota or permissions" >&2
        rm -rf "$base"; return 1
    }
    echo ok > "$d/usr/share/ncz-fixture/payload" 2>/dev/null
    out="$base/fixture.deb"
    if ! msg="$(dpkg-deb --root-owner-group -b "$d" "$out" 2>&1)"; then
        echo "dpkg-deb cannot build a fixture: $(printf '%s' "$msg" | tail -1)" >&2
        echo "  Usually TMPDIR has hit a quota (df -h ${TMPDIR:-/var/tmp}; check the tmpfs per-user limit) or is not writable." >&2
        rm -rf "$base"; return 1
    fi
    if [ ! -s "$out" ] || ! dpkg-deb -f "$out" Package >/dev/null 2>&1; then
        echo "dpkg-deb wrote an unusable fixture ($out is empty or unparseable): TMPDIR quota is the usual cause" >&2
        rm -rf "$base"; return 1
    fi
    rm -rf "$base"
    return 0
}
