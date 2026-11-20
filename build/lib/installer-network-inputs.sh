#!/bin/bash
# build/lib/installer-network-inputs.sh -- pinned fetch of the installer
# image's network inputs (M9 step 2, docs/BUILD-STABILITY.md "Pin and cache
# the network inputs", NG-NC-02).
#
# build/build-installer-image.sh used to curl the d-i Packages.xz index and
# the debootstrap-udeb from LIVE forky (deb.debian.org), so stage 70 could
# pull a different udeb than the snapshot pin (release.conf
# NCZ_BASE_MIRROR_SNAPSHOT) that the provenance gate describes. This library
# stages both inputs from the pinned snapshot and sha256-checks every byte
# through ncz_fetch_pinned_file (build/lib/fetch-pinned-file.sh, NG-NC-01).
#
# ncz_installer_fetch_inputs ARCH WORK_DIR CACHE_DIR [MANIFEST]
#   ARCH      amd64 | arm64  (selects the arch Packages.xz row; 'all' rows
#             always apply)
#   WORK_DIR  inputs are staged here as <dest> (manifest column 4)
#   CACHE_DIR passed through to ncz_fetch_pinned_file
#   MANIFEST  default $ROOT/manifests/network-inputs.tsv (resolved from this
#             file's location, so tests may pass a fixture instead)
#   0  every applicable row fetched, verified and staged
#   1  refused: bad arch, unreadable manifest, an unpinned row, a fetch or
#      hash failure. The error names the row and says what to do (re-pin the
#      manifest / check the snapshot mirror).
#
# Manifest columns (TAB separated, header line skipped):
#   arch url-template sha256 dest note
# url-template may contain {SNAPSHOT} (the NCZ_BASE_MIRROR_SNAPSHOT value),
# {ARCH} and {BASE} (the snapshot base URL). Rows whose template starts with
# http(s):// are still verified by sha256 before they are staged, but the
# BASE they resolve from MUST be the snapshot base -- a template pointing at
# a live mirror (deb.debian.org) is refused outright, not fetched.
#
# The d-i Packages.xz index itself is pinned byte-for-byte (its row carries
# the index sha256), and the debootstrap-udeb Filename + SHA256 are read
# from THAT verified index whenever the manifest udeb row's dest is '*':
# the index names which udeb the snapshot holds, the udeb row pins what it
# must hash to. A mismatch between index and pin fails the fetch.

ncz_installer_fetch_inputs() {
    local arch="$1" work_dir="$2" cache_dir="$3"
    local lib_here manifest
    lib_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    manifest="${4:-$(cd "$lib_here/../../manifests" && pwd)/network-inputs.tsv}"

    case "$arch" in
        amd64|arm64) ;;
        *) echo "ERROR: installer network inputs: unsupported ARCH '$arch' (want amd64|arm64)" >&2; return 1 ;;
    esac
    [ -n "$work_dir" ] || { echo "ERROR: installer network inputs: no work dir given" >&2; return 1; }
    [ -f "$manifest" ] || { echo "ERROR: installer network inputs: manifest $manifest is missing; re-pin with the udeb sha256 from the snapshot Packages.xz" >&2; return 1; }

    # release.conf is the single source of truth for the snapshot pin.
    local root snap base
    root="$(cd "$lib_here/../.." && pwd)"
    snap=""
    if [ -f "$root/release.conf" ]; then
        snap="$(sed -n 's/^NCZ_BASE_MIRROR_SNAPSHOT=//p' "$root/release.conf" | tr -d "\"' " | head -1)"
    fi
    [ -n "${NCZ_BASE_MIRROR_SNAPSHOT:-}" ] && snap="$NCZ_BASE_MIRROR_SNAPSHOT"
    case "$snap" in
        '') echo "ERROR: installer network inputs: NCZ_BASE_MIRROR_SNAPSHOT is unset -- refusing to fetch from an unpinned mirror" >&2; return 1 ;;
    esac
    base="${NCZ_SNAPSHOT_BASE:-https://snapshot.debian.org/archive/debian/$snap}"

    # shellcheck source=lib/fetch-pinned-file.sh
    . "$lib_here/fetch-pinned-file.sh"

    mkdir -p -- "$work_dir" "$cache_dir" \
        || { echo "ERROR: installer network inputs: cannot create $work_dir / $cache_dir" >&2; return 1; }

    local line=0 row_arch template pin dest note url index_file index_sha
    while IFS=$'\t' read -r row_arch template pin dest note; do
        line=$((line + 1))
        [ "$line" = 1 ] && continue  # header
        case "$row_arch" in ''|'#'*) continue ;; esac
        case "$row_arch" in "$arch"|all) ;; *) continue ;; esac
        case "$template" in
            '') echo "ERROR: installer network inputs: $manifest line $line ($row_arch/$dest): no url-template -- refusing an untemplated fetch" >&2; return 1 ;;
        esac
        case "$dest" in
            '') echo "ERROR: installer network inputs: $manifest line $line: no dest -- refusing to stage a file with no name" >&2; return 1 ;;
        esac
        case "$pin" in
            ''|*[!0-9a-fA-F]*)
                echo "ERROR: installer network inputs: unpinned input $row_arch/$dest ($manifest line $line): add its sha256 from the snapshot Packages.xz and re-run" >&2
                return 1 ;;
        esac
        [ "${#pin}" = 64 ] || { echo "ERROR: installer network inputs: unpinned input $row_arch/$dest ($manifest line $line): sha256 is ${#pin} chars, not 64 -- add the pinned sha256 and re-run" >&2; return 1; }
        url="$template"
        url="${url//\{SNAPSHOT\}/$snap}"
        url="${url//\{ARCH\}/$arch}"
        url="${url//\{BASE\}/$base}"
        case "$url" in
            *deb.debian.org*)
                echo "ERROR: installer network inputs: $row_arch/$dest resolves to a live mirror ($url) -- re-point the url-template at {BASE} (the snapshot base) and re-pin" >&2
                return 1 ;;
        esac
        if ! ncz_fetch_pinned_file "$url" "$pin" "$work_dir/$dest" "$cache_dir"; then
            echo "ERROR: installer network inputs: stage 70 cannot fetch $row_arch/$dest ($url): the pinned file failed to verify -- re-pin manifests/network-inputs.tsv from the snapshot Packages.xz" >&2
            return 1
        fi
    done < "$manifest"

    # Cross-check: the staged index must describe the staged udeb. The index
    # is the snapshot's own word for "which udeb is current"; the manifest
    # pin is ours. When they disagree (stale manifest row under a moved
    # snapshot) the build must stop here, not install whatever differs.
    index_file="$work_dir/Packages-$arch.xz"
    if [ -f "$index_file" ]; then
        local udeb_dest
        udeb_dest="$(awk -F'\t' -v a="$arch" 'NR>1 && ($1==a || $1=="all") && $2 ~ /debootstrap-udeb_/ {print $4; exit}' "$manifest")"
        if [ -n "$udeb_dest" ] && [ -f "$work_dir/$udeb_dest" ]; then
            index_sha="$(xz -dc "$index_file" 2>/dev/null | awk '
                $1 == "Package:" { pkg=$2 }
                pkg == "debootstrap-udeb" && $1 == "SHA256:" { print $2; exit }')"
            if [ -n "$index_sha" ]; then
                local staged_sha
                staged_sha="$(sha256sum "$work_dir/$udeb_dest" | awk '{print $1}')"
                if [ "$staged_sha" != "$index_sha" ]; then
                    echo "ERROR: installer network inputs: staged $udeb_dest (sha256 $staged_sha) != snapshot index SHA256 $index_sha -- the manifest pin is stale; re-pin manifests/network-inputs.tsv from the snapshot Packages.xz" >&2
                    return 1
                fi
            fi
        fi
    fi
    return 0
}
