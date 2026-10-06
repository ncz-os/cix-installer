#!/bin/bash
# verify-no-debian-kernel.sh -- fail closed if a Debian-archive kernel
# (forky 7.1.x linux-image-arm64 / linux-image-amd64 / versioned
# linux-image-7.1*) has leaked into installer media, the target rootfs,
# the ESP, or an initrd, or if the DEFAULT boot kernel is not the
# expected unified 7.3 string for the architecture.
#
# Policy (operator directive 2026-10-05, unified 7.3; Cygnus 26.10 kernel purity):
#   - The kernel in the installer image AND the installed system is 7.3 on
#     both arches, read from the per-arch sidecar:
#         arm64  expected KVER = assets/kernel/mainline/KVER
#         amd64  expected KVER = assets/kernel/amd64-stable/KVER
#   - NO Debian default kernel (the forky 7.1.x linux-image-arm64 /
#     linux-image-amd64 meta or any versioned linux-image-7.1*) may be
#     included, installed, pulled back by a dependency, or used to boot.
#
# Inputs (at least one of --root / --listing is required):
#   --root DIR          scan a directory tree (unpacked rootfs, mounted image
#                       root, mounted ESP, extracted initrd).
#   --listing FILE      scan a newline-delimited listing of paths (e.g. the
#                       output of `find`) OR a `dpkg-query -W`-style list of
#                       `package version` lines. `./` and absolute path
#                       prefixes are normalized away.
#
# Options:
#   --arch arm64|amd64      required when it cannot be inferred from
#                           release.conf / dpkg.
#   --expect-kver KVER      expected default KVER. Default: read from the
#                           repo's kernel asset sidecar (see --repo).
#   --repo DIR              repo root used to read the expected KVER and to
#                           recognise NCZ-built kernel package names.
#                           Default: the parent of this script.
#   --refind-conf FILE      rEFInd config to parse for the default entry. If
#                           omitted, a refind.conf is auto-discovered under
#                           <root> (boot/efi/EFI/BOOT/refind.conf,
#                           EFI/BOOT/refind.conf, EFI/refind/refind.conf).
#   --debian-prefix P       Debian kernel version prefix to treat as foreign
#                           (default: 7.1).
#   --quiet                 only print failures.
#
# Exit codes:
#   0  no Debian kernel present, default kernel is the expected 7.3
#   1  violation found
#   2  misuse (bad args / no input / could not determine ARCH/expected KVER)
set -uo pipefail
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT=""
LISTING=""
ARCH=""
EXPECT_KVER=""
REPO="${NCZ_REPO_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
REFIND_CONF=""
DEBIAN_PREFIX="7.1"
QUIET=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root)          ROOT="${2:-}"; shift 2 ;;
        --listing)       LISTING="${2:-}"; shift 2 ;;
        --arch)          ARCH="${2:-}"; shift 2 ;;
        --expect-kver)   EXPECT_KVER="${2:-}"; shift 2 ;;
        --repo)          REPO="${2:-}"; shift 2 ;;
        --refind-conf)   REFIND_CONF="${2:-}"; shift 2 ;;
        --debian-prefix) DEBIAN_PREFIX="${2:-}"; shift 2 ;;
        --quiet)         QUIET=1; shift ;;
        -h|--help)       sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "[no-debian-kernel] ERROR: unknown arg '$1'" >&2; exit 2 ;;
    esac
done

log()  { [ "$QUIET" = 1 ] || printf '[no-debian-kernel] %s\n' "$*"; }
err()  { printf '[no-debian-kernel] FAIL: %s\n' "$*" >&2; FAIL=1; }
FAIL=0

[ -n "$ROOT" ] || [ -n "$LISTING" ] || {
    echo "[no-debian-kernel] ERROR: need --root DIR and/or --listing FILE" >&2
    exit 2
}
if [ -n "$ROOT" ] && [ ! -d "$ROOT" ]; then
    echo "[no-debian-kernel] ERROR: --root '$ROOT' is not a directory" >&2
    exit 2
fi
if [ -n "$LISTING" ] && [ ! -f "$LISTING" ]; then
    echo "[no-debian-kernel] ERROR: --listing '$LISTING' is not a file" >&2
    exit 2
fi

# --- ARCH inference ---------------------------------------------------------
if [ -z "$ARCH" ] && [ -n "$REPO" ] && [ -s "$REPO/release.conf" ]; then
    ARCH="$(sed -nE 's/^[[:space:]]*NCZ_TARGET_ARCH[[:space:]]*=[[:space:]]*"?([^"]+)"?.*/\1/p' "$REPO/release.conf" | head -1)"
fi
if [ -z "$ARCH" ] && command -v dpkg >/dev/null 2>&1; then
    ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
fi
case "$ARCH" in
    aarch64) ARCH=arm64 ;;
    x86_64)  ARCH=amd64 ;;
esac
case "$ARCH" in
    arm64|amd64) ;;
    "") echo "[no-debian-kernel] ERROR: could not determine ARCH (set --arch or provide --repo with release.conf)" >&2; exit 2 ;;
    *)  echo "[no-debian-kernel] ERROR: unsupported --arch '$ARCH' (want arm64 or amd64)" >&2; exit 2 ;;
esac

# --- expected default KVER --------------------------------------------------
if [ -z "$EXPECT_KVER" ]; then
    case "$ARCH" in
        arm64) _kfile="$REPO/assets/kernel/mainline/KVER" ;;
        amd64) _kfile="$REPO/assets/kernel/amd64-stable/KVER" ;;
    esac
    if [ -s "$_kfile" ]; then
        EXPECT_KVER="$(tr -d '[:space:]' < "$_kfile")"
    fi
    # Fallback: the committed manifest carries the same mainline KVER, so a
    # dev/build host where the mainline symlink target is not mounted can
    # still resolve the expected default (the symlink is an absolute path
    # into the shared pool, which differs per host).
    if [ -z "$EXPECT_KVER" ] && [ "$ARCH" = arm64 ] && [ -s "$REPO/assets/kernel-manifest.json" ] \
       && command -v python3 >/dev/null 2>&1; then
        EXPECT_KVER="$(python3 -c '
import json,sys
try:
    m=json.load(open(sys.argv[1]))
    print((m.get("variants",{}).get("mainline",{}) or {}).get("kver",""))
except Exception:
    pass
' "$REPO/assets/kernel-manifest.json" 2>/dev/null)"
    fi
fi
if [ -z "$EXPECT_KVER" ]; then
    echo "[no-debian-kernel] ERROR: no expected default KVER (pass --expect-kver, or stage $REPO/assets/kernel/{mainline,amd64-stable}/KVER)" >&2
    exit 2
fi
if [ -z "$DEBIAN_PREFIX" ]; then
    echo "[no-debian-kernel] ERROR: --debian-prefix must not be empty" >&2
    exit 2
fi
log "arch=$ARCH expected-default=$EXPECT_KVER debian-prefix=$DEBIAN_PREFIX"

# --- package-name allowlist (our own kernel packages) -----------------------
# Any linux-image-*/linux-headers-* package NOT in this set is treated as a
# Debian-archive kernel. Derived from the expected KVER plus the NCZ naming
# conventions (arm64: linux-image-cixmini; amd64: linux-image-<kver>).
is_our_kernel_pkg() {
    case "$1" in
        linux-image-cixmini|linux-headers-cixmini|cixmini-boot) return 0 ;;
        "linux-image-$EXPECT_KVER"|"linux-headers-$EXPECT_KVER") return 0 ;;
        *-sky1-ncz|*-sky1-ncz-r[0-9]*) return 0 ;;
        linux-image-*-t2-trixie|linux-headers-*-t2-trixie) return 0 ;;
    esac
    return 1
}

is_debian_meta_pkg() {
    case "$1" in
        linux-image-arm64|linux-image-amd64|linux-headers-arm64|linux-headers-amd64) return 0 ;;
        linux-image-generic|linux-headers-generic) return 0 ;;
    esac
    return 1
}

# check_token TOKEN SOURCE
#   TOKEN is a normalized path or a package/version token.
check_token() {
    local tok="$1" src="$2" base pkg
    [ -n "$tok" ] || return 0
    # Strip a trailing / and any leading ./ or / for display/continuity.
    local norm="${tok#./}"
    base="${norm##*/}"

    # 1. Debian arch-suffixed boot artifacts at the forky prefix.
    case "$norm" in
        */lib/modules/${DEBIAN_PREFIX}*|lib/modules/${DEBIAN_PREFIX}*|\
        */boot/vmlinuz-${DEBIAN_PREFIX}*|boot/vmlinuz-${DEBIAN_PREFIX}*|\
        */boot/initrd.img-${DEBIAN_PREFIX}*|boot/initrd.img-${DEBIAN_PREFIX}*|\
        */boot/config-${DEBIAN_PREFIX}*|boot/config-${DEBIAN_PREFIX}*|\
        */boot/System.map-${DEBIAN_PREFIX}*|boot/System.map-${DEBIAN_PREFIX}*)
            err "$src: Debian ${DEBIAN_PREFIX} boot artifact present: $tok"; return 0 ;;
    esac

    # 2. Debian metapackage names anywhere (path component or package token).
    case "$base" in
        linux-image-arm64|linux-image-amd64|linux-headers-arm64|linux-headers-amd64|\
        linux-image-generic|linux-headers-generic)
            err "$src: Debian default kernel metapackage present: $tok"; return 0 ;;
    esac

    # 3. Any linux-image-/linux-headers- token that is not ours.
    case "$base" in
        linux-image-*.deb) pkg="${base%%_*}" ;;
        linux-headers-*.deb) pkg="${base%%_*}" ;;
        linux-image-*|linux-headers-*) pkg="$base" ;;
        *) return 0 ;;
    esac
    if is_debian_meta_pkg "$pkg"; then
        err "$src: Debian default kernel package present: $pkg"
        return 0
    fi
    if ! is_our_kernel_pkg "$pkg"; then
        err "$src: non-NCZ kernel package present (Debian default kernel): $pkg"
    fi
}

# --- scan a listing ---------------------------------------------------------
scan_listing() {
    local f="$1" line
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        # Trim surrounding whitespace.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] || continue
        # dpkg-query style "pkg version": no slash, starts with a package name.
        case "$line" in
            */*) check_token "$line" "$f" ;;
            *)
                local pkg="${line%%[[:space:]]*}"
                check_token "$pkg" "$f"
                ;;
        esac
    done < "$f"
}

# --- scan a rootfs tree -----------------------------------------------------
scan_root() {
    local r="$1" p
    # boot artifacts + module trees
    while IFS= read -r p; do
        check_token "${p#"$r"/}" "$r"
    done < <(find "$r/boot" -maxdepth 2 \( -name "vmlinuz-*" -o -name "initrd.img-*" \
        -o -name "config-*" -o -name "System.map-*" \) 2>/dev/null)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        check_token "${p#"$r"/}" "$r"
    done < <(find "$r/lib/modules" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
    # staged kernel packages on installer media
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        check_token "${p#"$r"/}" "$r"
    done < <(find "$r" -maxdepth 6 -type f \( -name 'linux-image-*.deb' -o -name 'linux-headers-*.deb' \) 2>/dev/null)
    # dpkg status DB (installed Debian kernel packages)
    if [ -s "$r/var/lib/dpkg/status" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            check_token "$p" "$r/var/lib/dpkg/status"
        done < <(awk '/^Package: /{pkg=$2} /^Status: install ok installed/{print pkg}' \
            "$r/var/lib/dpkg/status" 2>/dev/null)
    fi
}

# --- default-kernel check ---------------------------------------------------
# Parse a rEFInd config and assert the entry named by default_selection loads
# vmlinuz-<expected>. Handles both `default_selection "<token>"` and a bare
# entry-title token.
check_refind_default() {
    local f="$1" token loader entry_title
    [ -s "$f" ] || return 0
    token="$(sed -nE 's/^[[:space:]]*default_selection[[:space:]]+"?([^"[:space:]]+)"?.*/\1/p' "$f" | tail -1)"
    [ -n "$token" ] || { log "$f: no default_selection directive; skipping default check"; return 0; }
    # Find the first menuentry whose title contains the token, then the next
    # loader line. Titles on disk quote the token exactly (e.g. "Mali (Default)").
    loader="$(awk -v tok="$token" '
        BEGIN { in_entry=0 }
        /^[[:space:]]*menuentry[[:space:]]/ {
            in_entry = (index($0, tok) > 0) ? 1 : 0
            next
        }
        in_entry && /^[[:space:]]*loader[[:space:]]/ {
            # strip "loader" keyword and whitespace
            sub(/^[[:space:]]*loader[[:space:]]+/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            print; exit
        }
    ' "$f")"
    if [ -z "$loader" ]; then
        err "$f: default_selection '$token' matches no menuentry with a loader line (no default kernel can boot)"
        return 0
    fi
    entry_title="$(awk -v tok="$token" '
        /^[[:space:]]*menuentry[[:space:]]/ && index($0, tok) > 0 { print; exit }
    ' "$f")"
    case "${loader##*/}" in
        "vmlinuz-$EXPECT_KVER")
            log "$f: default entry loads vmlinuz-$EXPECT_KVER title=${entry_title:-?}" ;;
        "vmlinuz-${DEBIAN_PREFIX}"*)
            err "$f: default entry loads a Debian kernel: $loader" ;;
        *)
            err "$f: default entry loads '$loader', expected vmlinuz-$EXPECT_KVER" ;;
    esac
}

find_refind_conf() {
    local r="$1" c
    for c in "$r/boot/efi/EFI/BOOT/refind.conf" "$r/EFI/BOOT/refind.conf" "$r/EFI/refind/refind.conf"; do
        [ -s "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# --- run --------------------------------------------------------------------
if [ -n "$LISTING" ]; then
    scan_listing "$LISTING"
fi
if [ -n "$ROOT" ]; then
    scan_root "$ROOT"
    if [ -z "$REFIND_CONF" ]; then
        REFIND_CONF="$(find_refind_conf "$ROOT" || true)"
    fi
    # If any vmlinuz exists in the tree but the expected default does not, the
    # default kernel is wrong (a stale/foreign kernel is the only candidate).
    if [ -d "$ROOT/boot" ] || [ -n "$REFIND_CONF" ]; then
        _have_any=$(find "$ROOT" -maxdepth 6 -name 'vmlinuz-*' 2>/dev/null | head -1)
        if [ -n "$_have_any" ] && [ ! -e "$ROOT/boot/vmlinuz-$EXPECT_KVER" ] \
           && [ -z "$REFIND_CONF" ]; then
            err "$ROOT: no vmlinuz-$EXPECT_KVER; bootable kernels are not the expected $ARCH default"
        fi
    fi
fi
if [ -n "$REFIND_CONF" ]; then
    check_refind_default "$REFIND_CONF"
fi

if [ "$FAIL" = 1 ]; then
    echo "[no-debian-kernel] VIOLATION -- a Debian kernel may enter or boot" >&2
    exit 1
fi
echo "[no-debian-kernel] OK -- no Debian kernel; default=$EXPECT_KVER (arch=$ARCH)"
exit 0
