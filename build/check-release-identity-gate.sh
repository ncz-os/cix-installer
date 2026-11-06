#!/bin/bash
# check-release-identity-gate.sh -- build-time gate: no retired codename, no
# empty product label, no variant-label mismatch, anywhere in the GENERATED
# identity strings of a staged installer medium or a baked rootfs (MINOR-001).
#
# Bug being proven impossible to recur (MINOR-001): an operator saw the
# console banner "NCZ Maximilian Server" on an arm64 Preview2 install medium.
# Every producer of the installer-medium identity must therefore carry the
# CURRENT identity from release.conf:
#
#   * preseed/ncz-ui.sh ncz_ui_brand() -- the dialog frame titles. Reads the
#     initrd-baked /ncz/RELEASE (release.conf verbatim, baked by
#     build/iso/patch-initrd-t2-kernel.py, already gated) FIRST and the
#     medium's /ncz-payload/RELEASE as fallback.
#   * post-install/50-brand.sh -- writes /etc/os-release, /etc/lsb-release,
#     /etc/issue and /etc/issue.net and the login banner. Reads
#     /usr/local/lib/cix-installer/RELEASE or /etc/cix-installer/RELEASE,
#     both of which late.sh copies off the medium's /ncz-payload/RELEASE.
#     It runs BOTH at install time (d-i chroot) and at bake time (the
#     build-baked-rootfs.sh BAKE_HOOKS list), so a stale codename in either
#     copy reaches the console banner.
#   * build/iso/write-usb-image.py -- stages release.conf verbatim as
#     ncz-payload/RELEASE on every medium it builds.
#   * build/build-baked-rootfs.sh -- stamps BUILD_VARIANT into the baked
#     chroot and runs 50-brand.sh there, generating the baked rootfs'
#     /etc/os-release + /etc/issue + /etc/issue.net.
#
# The gate checks what those producers ACTUALLY generated in a tree on disk:
#   1. every RELEASE / os-release / issue / issue.net file present in the
#      tree is parseable and carries the full identity from release.conf
#      (product name, version, codename -- none empty, none a retired
#      codename);
#   2. no GENERATED string in the tree contains a retired codename
#      (Maximilian / Reinhardt);
#   3. the product label is non-empty;
#   4. the variant label on the os-release PRETTY_NAME matches the tree's
#      BUILD_VARIANT (desktop -> "Desktop", server -> "Server").
#
# The `staged` subcommand checks a staged medium tree (the ncz-payload/
# staging directory of build/iso/write-usb-image.py -- or the equivalent
# payload dir of any medium writer); the `baked` subcommand checks a baked
# rootfs tree (the build-baked-rootfs.sh chroot, or an extracted
# rootfs-<base>-arm64-baked.tar.zst). The image build runs `staged` for the
# medium and `baked` for the rootfs, for BOTH variants.
#
# Usage:
#   check-release-identity-gate.sh conf   <release.conf>
#   check-release-identity-gate.sh staged <staged-medium-tree> [ncz-payload-dir]
#   check-release-identity-gate.sh baked  <rootfs-tree>
#
# Exit 0 = identity sound; 1 = a violation (the build must stop);
# 2 = usage error or unreadable input.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# Retired release codenames. History prose may still name them (docs/, test
# fixtures that use them as DELIBERATELY-WRONG negative input) -- only live
# strings in a GENERATED tree are violations, so the list is matched against
# tree contents, never against the repo sources.
RETIRED=("Maximilian" "Reinhardt")
# Retired names are matched case-insensitively (VERSION_CODENAME is lower case).
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

FAILS=0
ok()  { echo "ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "FAIL $1"; }

die_usage() { echo "$1" >&2; exit 2; }

# Parse KEY="value" (quotes optional) out of a release-identity file.
# Tolerates a final line without a trailing newline (a truncated file must
# not silently drop the last field).
field() { # $1 file, $2 key
    [ -r "$1" ] || return 0
    while IFS= read -r _l || [ -n "$_l" ]; do
        case "$_l" in
            "$2="*) _v=${_l#*=}; _v=${_v#\"}; _v=${_v%\"}; echo "$_v"; return 0 ;;
        esac
    done < "$1"
}

# check_release_file FILE WHERE -- the full identity, none empty, none retired.
check_release_file() {
    local f="$1" where="$2" k v want
    [ -s "$f" ] || { bad "$where: identity file is missing or empty"; return; }
    for k in NCZ_PRODUCT_NAME NCZ_RELEASE_VERSION NCZ_RELEASE_CODENAME; do
        v="$(field "$f" "$k")"
        if [ -z "$v" ]; then
            bad "$where: $k is empty"
        else
            ok "$where: $k=$v"
            for r in "${RETIRED[@]}"; do
                case "$(lc "$v")" in *"$(lc "$r")"*) bad "$where: $k names the retired codename '$r'" ;; esac
            done
            # Not just "not retired": the generated copy must BE the current
            # identity, so an older non-retired codename cannot slip through.
            case "$k" in
                NCZ_PRODUCT_NAME)     want="$NCZ_EXPECT_PRODUCT" ;;
                NCZ_RELEASE_VERSION)  want="$NCZ_EXPECT_VERSION" ;;
                NCZ_RELEASE_CODENAME) want="$NCZ_EXPECT_CODENAME" ;;
            esac
            [ "$v" = "$want" ] || bad "$where: $k='$v' does not match release.conf ('$want')"
        fi
    done
}

# check_os_release_file FILE WHERE VARIANT -- os-release identity + variant.
# The expected identity fields are globals loaded by load_expected_identity().
check_os_release_file() {
    local f="$1" where="$2" variant="$3"
    [ -s "$f" ] || { bad "$where: os-release file is missing or empty"; return; }
    local name_val version_id_val
    name_val="$(field "$f" NAME)"
    version_id_val="$(field "$f" VERSION_ID)"
    [ -n "$name_val" ] || bad "$where: NAME is empty"
    [ -n "$version_id_val" ] || bad "$where: VERSION_ID is empty"
    [ -z "$name_val" ] || [ "$name_val" = "$NCZ_EXPECT_PRODUCT" ] \
        || bad "$where: NAME='$name_val' does not match release.conf ('$NCZ_EXPECT_PRODUCT')"
    [ -z "$version_id_val" ] || [ "$version_id_val" = "$NCZ_EXPECT_VERSION" ] \
        || bad "$where: VERSION_ID='$version_id_val' does not match release.conf ('$NCZ_EXPECT_VERSION')"

    local pn vcod
    pn="$(field "$f" PRETTY_NAME)"
    vcod="$(field "$f" VERSION_CODENAME)"
    if [ -z "$pn" ]; then
        bad "$where: PRETTY_NAME is empty"
    else
        ok "$where: PRETTY_NAME=$pn"
        for r in "${RETIRED[@]}"; do
            case "$(lc "$pn")" in *"$(lc "$r")"*) bad "$where: PRETTY_NAME names the retired codename '$r'" ;; esac
        done
    fi
    for r in "${RETIRED[@]}"; do
        case "$(lc "$vcod")" in *"$(lc "$r")"*) bad "$where: VERSION_CODENAME names the retired codename '$r'" ;; esac
    done
    # 50-brand.sh writes VERSION_CODENAME as the lower-cased release codename.
    local want_cod
    want_cod="$(printf '%s' "$NCZ_EXPECT_CODENAME" | tr '[:upper:]' '[:lower:]')"
    [ "$(printf '%s' "$vcod" | tr '[:upper:]' '[:lower:]')" = "$want_cod" ] \
        || bad "$where: VERSION_CODENAME='$vcod' does not match release.conf ('$want_cod')"

    # The product label must be non-empty AND must carry the version.
    if [ -n "$pn" ] && [ -n "$NCZ_EXPECT_VERSION" ]; then
        case "$pn" in
            *"$NCZ_EXPECT_PRODUCT"*"$NCZ_EXPECT_VERSION"*)
                ok "$where: PRETTY_NAME carries the current product and version" ;;
            *)
                bad "$where: PRETTY_NAME does not carry '$NCZ_EXPECT_PRODUCT $NCZ_EXPECT_VERSION'" ;;
        esac
    fi

    if [ -n "$variant" ]; then
        local want_label
        case "$variant" in
            server) want_label="Server" ;;
            desktop) want_label="Desktop" ;;
            *) bad "$where: unknown BUILD_VARIANT '$variant' (expected desktop or server)"; return ;;
        esac
        if [ -n "$pn" ]; then
            case "$pn" in
                *" $want_label,"*|*" $want_label "*)
                    ok "$where: variant label '$want_label' matches BUILD_VARIANT=$variant" ;;
                *)
                    bad "$where: variant label mismatch: BUILD_VARIANT=$variant but PRETTY_NAME lacks '$want_label' (got: $pn)" ;;
            esac
        fi
    fi
}

# check_generated_strings DIR WHERE -- every identity-shaped file in the tree
# must be clean, and no generated string in the tree may name a retired
# codename. History prose in comments is fine; live generated content is not.
check_generated_strings() {
    local dir="$1" where="$2"
    N_RELEASE=0; N_OSREL=0; N_ISSUE=0; N_ISSUENET=0
    [ -d "$dir" ] || { bad "$where: tree not found: $dir"; return; }
    # Identity-shaped files: RELEASE (medium payload / chroot install copies),
    # os-release, lsb-release, issue, issue.net. Match anywhere in the tree,
    # except systemd's factory copies (usr/share/factory/etc/*): those are the
    # stock Debian defaults tmpfiles restores only when /etc lacks the file,
    # never the banner 50-brand.sh generated.
    local label="$NCZ_EXPECT_PRODUCT $NCZ_EXPECT_VERSION $NCZ_EXPECT_CODENAME"
    local want_banner="$label"
    case "${NCZ_EXPECT_VARIANT:-}" in
        server)  want_banner="$label Server" ;;
        desktop) want_banner="$label Desktop" ;;
    esac
    local f content r rel
    while IFS= read -r f; do
        case "$f" in */usr/share/factory/*) continue ;; esac
        case "$f" in
            */RELEASE|RELEASE)
                N_RELEASE=$((N_RELEASE + 1))
                check_release_file "$f" "$where: $(basename "$f")" ;;
            */os-release)
                N_OSREL=$((N_OSREL + 1))
                check_os_release_file "$f" "$where: $(basename "$f")" "${NCZ_EXPECT_VARIANT:-}" ;;
            */lsb-release|*issue|*issue.net)
                content="$(cat "$f" 2>/dev/null || true)"
                for r in "${RETIRED[@]}"; do
                    case "$(lc "$content")" in *"$(lc "$r")"*) bad "$where: $(basename "$f") names the retired codename '$r'" ;; esac
                done
                case "$f" in
                    */lsb-release)
                        rel="$(field "$f" DISTRIB_RELEASE)"
                        [ "$rel" = "$NCZ_EXPECT_VERSION" ] \
                            || bad "$where: lsb-release DISTRIB_RELEASE='$rel' does not match release.conf ('$NCZ_EXPECT_VERSION')"
                        rel="$(field "$f" DISTRIB_CODENAME | tr '[:upper:]' '[:lower:]')"
                        [ "$rel" = "$(printf '%s' "$NCZ_EXPECT_CODENAME" | tr '[:upper:]' '[:lower:]')" ] \
                            || bad "$where: lsb-release DISTRIB_CODENAME='$rel' does not match release.conf" ;;
                    *)
                        case "$f" in *issue.net) N_ISSUENET=$((N_ISSUENET + 1)) ;; *) N_ISSUE=$((N_ISSUE + 1)) ;; esac
                        case "$content" in
                            *"$want_banner"*) ok "$where: $(basename "$f") carries '$want_banner'" ;;
                            *) bad "$where: $(basename "$f") does not carry the banner '$want_banner'" ;;
                        esac ;;
                esac
                ;;
        esac
    done < <(find "$dir" -type f \( -name RELEASE -o -name os-release -o -name lsb-release \
        -o -name issue -o -name issue.net \) 2>/dev/null)
}

# Load the expected identity from release.conf (the single source of truth).
# FATAL on an unreadable/incomplete release.conf: a gate that cannot name the
# expected identity must not pass a build.
load_expected_identity() {
    local rc="${1:-$ROOT/release.conf}"
    [ -r "$rc" ] || { echo "FATAL: cannot read $rc" >&2; exit 2; }
    # shellcheck disable=SC1090
    . "$rc"
    : "${NCZ_PRODUCT_NAME:?release.conf did not define NCZ_PRODUCT_NAME}"
    : "${NCZ_RELEASE_VERSION:?release.conf did not define NCZ_RELEASE_VERSION}"
    : "${NCZ_RELEASE_CODENAME:?release.conf did not define NCZ_RELEASE_CODENAME}"
    NCZ_EXPECT_PRODUCT="$NCZ_PRODUCT_NAME"
    NCZ_EXPECT_VERSION="$NCZ_RELEASE_VERSION"
    NCZ_EXPECT_CODENAME="$NCZ_RELEASE_CODENAME"
    for r in "${RETIRED[@]}"; do
        case "$(lc "$NCZ_EXPECT_CODENAME")" in
            *"$(lc "$r")"*) echo "FATAL: release.conf codename '$NCZ_EXPECT_CODENAME' is a retired codename" >&2; exit 2 ;;
        esac
    done
    # The expected identity is exported into the checks above.
    export NCZ_EXPECT_PRODUCT NCZ_EXPECT_VERSION NCZ_EXPECT_CODENAME
}

# read_variant FILE -- print the BUILD_VARIANT value (empty when absent).
read_variant() {
    local f="${1:-}"
    [ -n "$f" ] && [ -r "$f" ] || return 0
    tr -d ' \t\r\n' < "$f"
}

cmd_conf() {
    local rc="${1:-}"
    [ -n "$rc" ] || die_usage "usage: $0 conf <release.conf>"
    load_expected_identity "$rc"
    ok "release.conf identity: $NCZ_EXPECT_PRODUCT $NCZ_EXPECT_VERSION $NCZ_EXPECT_CODENAME (no retired codename)"
    for r in "${RETIRED[@]}"; do
        case "$(lc "$NCZ_EXPECT_CODENAME")" in *"$(lc "$r")"*) bad "release.conf codename is retired: $r" ;; esac
    done
    [ -z "$NCZ_EXPECT_PRODUCT" ] && bad "release.conf product name is empty"
}

cmd_staged() {
    local tree="${1:-}" payload_dir="${2:-}"
    [ -n "$tree" ] || die_usage "usage: $0 staged <staged-medium-tree> [ncz-payload-dir]"
    load_expected_identity "${NCZ_EXPECT_RELEASE_CONF:-$ROOT/release.conf}"
    [ -d "$tree" ] || die_usage "staged tree not found: $tree"

    # Scan the staged tree ONCE: the payload RELEASE (staged by
    # write-usb-image.py from release.conf), the ESP rEFInd, the post-install
    # tree -- everything that goes onto the medium. The medium itself carries
    # no variant: 50-brand.sh resolves BUILD_VARIANT at install time
    # (preseed/late.sh) from the operator's component selection, so a
    # variant-label check would be wrong here.
    NCZ_EXPECT_VARIANT=""
    check_generated_strings "$tree" "medium"
    # A medium without its RELEASE is not an identity that passed: it is no
    # identity at all.
    [ "$N_RELEASE" -gt 0 ] || bad "medium: no RELEASE found in the staged tree"
    # payload_dir is accepted for interface stability with the medium
    # writer's staging layout; it is a subdir of the tree, already covered.
    [ -n "$payload_dir" ] && [ -d "$payload_dir" ] || true
}

cmd_baked() {
    local tree="${1:-}"
    [ -n "$tree" ] || die_usage "usage: $0 baked <rootfs-tree>"
    load_expected_identity "${NCZ_EXPECT_RELEASE_CONF:-$ROOT/release.conf}"
    [ -d "$tree" ] || die_usage "rootfs tree not found: $tree"

    # BUILD_VARIANT decides which label the variant check expects.
    local variant
    variant="$(read_variant "$tree/usr/local/lib/cix-installer/BUILD_VARIANT")"
    [ -n "$variant" ] || variant="$(read_variant "$tree/etc/cix-installer/BUILD_VARIANT")"
    # build-baked-rootfs.sh stamps BUILD_VARIANT before the gate runs; a
    # missing stamp is itself a broken bake, never an implicit desktop.
    if [ -z "$variant" ]; then
        bad "baked rootfs: BUILD_VARIANT stamp is missing (usr/local/lib/cix-installer or etc/cix-installer)"
        variant=desktop
    fi
    NCZ_EXPECT_VARIANT="$variant"
    ok "baked rootfs: BUILD_VARIANT=${NCZ_EXPECT_VARIANT}"

    # Generated identity files: /etc/os-release (+symlink), lsb-release,
    # issue, issue.net, and the RELEASE copies 50-brand reads.
    check_generated_strings "$tree" "baked"
    # 50-brand.sh generates all three; a bake missing any of them did not brand.
    [ "$N_OSREL" -gt 0 ]    || bad "baked: no os-release in the rootfs"
    [ "$N_ISSUE" -gt 0 ]    || bad "baked: no issue in the rootfs"
    [ "$N_ISSUENET" -gt 0 ] || bad "baked: no issue.net in the rootfs"
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        conf)   cmd_conf "$@" ;;
        staged) cmd_staged "$@" ;;
        baked)  cmd_baked "$@" ;;
        *)      die_usage "usage: $0 {conf <release.conf>|staged <tree> [payload-dir]|baked <rootfs-tree>}" ;;
    esac
    if [ "$FAILS" -gt 0 ]; then
        echo "release-identity-gate: $FAILS violation(s) -- a stale or empty identity would ship" >&2
        exit 1
    fi
    echo "release-identity-gate: PASS (no retired codename, non-empty product label, variant label consistent)"
}

main "$@"
