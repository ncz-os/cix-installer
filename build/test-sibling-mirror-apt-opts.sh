#!/bin/bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2329
# Hermetic check that the sibling rootfs scripts put NCZ_BASE_MIRROR_APT_OPTS
# on every chroot sources.list line, and emit a plain deb line when it is empty.
# No debootstrap, no apt, no image build.
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/build/lib/mirror-apt-opts.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
PASS=0
FAILS=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }

if [ -f "$LIB" ]; then ok "mirror-apt-opts.sh present"; else no "mirror-apt-opts.sh missing"; fi

cat > "$T/release-pinned.conf" <<'EOF'
NCZ_BASE_NAME="Debian"
NCZ_BASE_CODENAME="forky"
NCZ_BASE_COMPONENTS="main contrib"
NCZ_BASE_MIRROR="https://snapshot.debian.org/archive/debian/20260927T203404Z"
NCZ_BASE_MIRROR_APT_OPTS="check-valid-until=no"
NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="26.10"
NCZ_RELEASE_CODENAME="fixture"
EOF
cat > "$T/release-live.conf" <<'EOF'
NCZ_BASE_NAME="Debian"
NCZ_BASE_CODENAME="forky"
NCZ_BASE_COMPONENTS="main contrib"
NCZ_BASE_MIRROR="https://deb.debian.org/debian"
NCZ_BASE_MIRROR_APT_OPTS=""
NCZ_PRODUCT_NAME="NCZ-OS"
NCZ_RELEASE_VERSION="26.10"
NCZ_RELEASE_CODENAME="fixture"
EOF

# Extract the sources.list call from the real script and run only that.
gen_sources() {
    local script="$1" release="$2" out="$3" rel_root
    rel_root="$T/rel-$script-$(basename "$release")"
    mkdir -p "$rel_root/build/lib" "$rel_root/manifests"
    cp "$LIB" "$rel_root/build/lib/mirror-apt-opts.sh"
    cp "$release" "$rel_root/release.conf"
    printf '%s\n' '# fixture' 'bash' > "$rel_root/manifests/mgmt.pkgs"
    printf '%s\n' '# fixture' 'bash' > "$rel_root/manifests/rescue.pkgs"
    awk '
        /ncz_mirror_sources_list / { capture=1 }
        capture { print; if ($0 !~ /\\$/) { exit } }
    ' "$ROOT/build/$script" > "$T/call.sh"
    [ -s "$T/call.sh" ] || { echo "no sources call in $script" >&2; return 1; }
    (
        # shellcheck disable=SC1090
        ROOT="$rel_root"
        # shellcheck disable=SC1091
        . "$rel_root/release.conf"
        # shellcheck disable=SC1091
        . "$rel_root/build/lib/mirror-apt-opts.sh"
        case "$script" in
            build-mgmt-rootfs.sh)
                MIRROR="$NCZ_BASE_MIRROR"
                SUITE="$NCZ_BASE_CODENAME"
                COMPONENTS="$NCZ_BASE_COMPONENTS"
                ;;
            build-rescue-rootfs.sh)
                MIRROR="$NCZ_BASE_MIRROR"
                SUITE="$NCZ_BASE_CODENAME"
                COMPONENTS="$NCZ_BASE_COMPONENTS"
                ;;
            build-baked-rootfs.sh)
                ;;
        esac
        sudo() {
            if [ "$1" = "tee" ]; then
                shift
                cat > "$1"
                return 0
            fi
            echo "unexpected sudo: $*" >&2
            return 1
        }
        CHROOT="$T/chroot-$script"
        mkdir -p "$CHROOT/etc/apt"
        # shellcheck disable=SC1091
        . "$T/call.sh"
    )
    cp "$T/chroot-$script/etc/apt/sources.list" "$out"
}

check_pinned() {
    local script="$1" out="$2" expect_lines="$3" n
    n="$(grep -c 'check-valid-until=no' "$out" || true)"
    if [ "$n" = "$expect_lines" ]; then
        ok "$script pinned: $expect_lines line(s) carry check-valid-until=no"
    else
        no "$script pinned: expected $expect_lines opted lines, got $n"
        cat "$out" >&2
    fi
    if grep -q '^deb [^[]' "$out"; then
        no "$script pinned: a deb line has no options"
        cat "$out" >&2
    else
        ok "$script pinned: every deb line has options"
    fi
}

check_live() {
    local script="$1" out="$2"
    if grep -q 'check-valid-until' "$out"; then
        no "$script live: option leaked onto an unpinned line"
        cat "$out" >&2
    else
        ok "$script live: no check-valid-until on an unpinned build"
    fi
    if grep -q '^deb \[' "$out"; then
        no "$script live: empty option still emitted brackets"
        cat "$out" >&2
    else
        ok "$script live: plain deb lines (historical shape)"
    fi
}

for script in build-mgmt-rootfs.sh build-rescue-rootfs.sh build-baked-rootfs.sh; do
    if gen_sources "$script" "$T/release-pinned.conf" "$T/$script.pinned"; then
        ok "$script generates a pinned sources.list"
    else
        no "$script failed to generate a pinned sources.list"
    fi
    if gen_sources "$script" "$T/release-live.conf" "$T/$script.live"; then
        ok "$script generates a live sources.list"
    else
        no "$script failed to generate a live sources.list"
    fi
done

check_pinned build-mgmt-rootfs.sh "$T/build-mgmt-rootfs.sh.pinned" 1
check_pinned build-rescue-rootfs.sh "$T/build-rescue-rootfs.sh.pinned" 1
check_pinned build-baked-rootfs.sh "$T/build-baked-rootfs.sh.pinned" 1
check_live build-mgmt-rootfs.sh "$T/build-mgmt-rootfs.sh.live"
check_live build-rescue-rootfs.sh "$T/build-rescue-rootfs.sh.live"
check_live build-baked-rootfs.sh "$T/build-baked-rootfs.sh.live"

# operator 2026-10-08 ("only Debian versions from forky"): mgmt is the single base suite too --
# no forky-updates, no forky-security, no security.debian.org.
if grep -Eq 'updates|security' "$T/build-mgmt-rootfs.sh.pinned"; then
    no "mgmt pinned sources grew a suite beyond forky"
    cat "$T/build-mgmt-rootfs.sh.pinned" >&2
else
    ok "mgmt pinned sources is the single forky base suite"
fi
if grep -Eq 'updates|security' "$T/build-rescue-rootfs.sh.pinned"; then
    no "rescue pinned sources grew a suite it did not have"
    cat "$T/build-rescue-rootfs.sh.pinned" >&2
else
    ok "rescue pinned sources is the single base suite"
fi

echo "sibling mirror apt opts: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
