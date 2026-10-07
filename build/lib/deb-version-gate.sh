#!/bin/bash
# build/lib/deb-version-gate.sh -- a rebuilt .deb MUST bump its version.
#
# Why (r201, measured on MEDUSA 2026-10-07): ncz-wallpapers-{ncz,singularity,
# alex-jay-brady,brandon-perlow} were rebuilt and re-published as 1.0 again.
# apt identifies a version by (version string, package metadata hash), so the
# installed 1.0 and the republished 1.0 are different versions that print the
# same: `apt list --upgradable` shows "1.0 -> 1.0" forever, and two repos
# serving different 1.0 builds make apt flip-flop. A package whose content or
# control data changed needs a new version. Same bytes republished is fine
# (idempotent); same version + different bytes is refused.
#
# ncz_deb_version_gate DEB
#   Looks DEB's (Package, Version, Architecture) up in the published NCZ index
#   and returns 1 when the same version is already published with different
#   content. Sources of truth, first that works:
#     $NCZ_PUBLISHED_INDEX   space-separated Packages files / URLs (tests, offline)
#     the live Buildkite Packages index for the deb's architecture
#   An unreachable index is a WARNING (an offline build must still work) unless
#   NCZ_VERSION_GATE_STRICT=1, which makes it an error.
#
# Output: one line "version-gate: ..." per decision. Needs dpkg-deb.

ncz_deb_version_gate() {
    local deb="$1" name ver arch sha idx src rc=0 found_sha="" tmp highest="" v a s
    [ -f "$deb" ] || { echo "version-gate: no such file: $deb" >&2; return 1; }
    name="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"; ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
    if [ -z "$name" ] || [ -z "$ver" ] || [ -z "$arch" ]; then
        # Not a readable .deb (e.g. a test stubbing dpkg-deb). Never silently pass in strict mode.
        if [ "${NCZ_VERSION_GATE_STRICT:-0}" = 1 ]; then echo "version-gate: FAIL cannot read control fields of $deb" >&2; return 1; fi
        echo "version-gate: WARN cannot read control fields of $deb; not checked" >&2; return 0
    fi
    sha="$(sha256sum "$deb" | awk '{print $1}')"

    local -a srcs
    if [ -n "${NCZ_PUBLISHED_INDEX:-}" ]; then
        read -r -a srcs <<< "$NCZ_PUBLISHED_INDEX"
    else
        local a="$arch"; [ "$a" = all ] && a=amd64
        srcs=("${NCZ_BK_BASE:-https://packages.buildkite.com/ncz-os/ncz/any/dists/any}/main/binary-$a/Packages")
    fi

    tmp="$(mktemp)"
    for src in "${srcs[@]}"; do
        : > "$tmp"
        case "$src" in
            http://*|https://*) curl -fsSL -m 60 -o "$tmp" "$src" 2>/dev/null || { echo "version-gate: WARN cannot fetch $src" >&2; rc=3; continue; } ;;
            *.gz) gzip -dc "$src" > "$tmp" 2>/dev/null || { rc=3; continue; } ;;
            *)    cat "$src" > "$tmp" 2>/dev/null || { rc=3; continue; } ;;
        esac
        rc=0
        # stanzas of this package: "version arch sha256"
        while IFS=' ' read -r v a s; do
            [ "$a" = "$arch" ] || [ "$a" = all ] || [ "$arch" = all ] || continue
            if [ "$v" = "$ver" ]; then found_sha="$s"; fi
            if [ -z "$highest" ] || dpkg --compare-versions "$v" gt "$highest"; then highest="$v"; fi
        done < <(awk -v n="$name" '
            /^Package:/{p=$2} /^Version:/{v=$2} /^Architecture:/{a=$2} /^SHA256:/{s=$2}
            /^$/{ if(p==n) print v, a, s; p="" } END{ if(p==n) print v, a, s }' "$tmp")
        break
    done
    rm -f "$tmp"

    if [ "$rc" = 3 ]; then
        if [ "${NCZ_VERSION_GATE_STRICT:-0}" = 1 ]; then
            echo "version-gate: FAIL cannot read the published index and NCZ_VERSION_GATE_STRICT=1" >&2; return 1
        fi
        echo "version-gate: WARN published index unreachable; $name $ver NOT checked for a version bump" >&2
        return 0
    fi
    if [ -n "$found_sha" ] && [ "$found_sha" != "$sha" ]; then
        echo "version-gate: FAIL $name $ver ($arch) is already published with DIFFERENT content." >&2
        echo "version-gate:      rebuilt packages must bump their version (apt would show '$ver -> $ver'). Bump it and rebuild." >&2
        return 1
    fi
    if [ -n "$found_sha" ]; then
        echo "version-gate: ok $name $ver identical to the published build (idempotent)"
    elif [ -n "$highest" ] && dpkg --compare-versions "$ver" lt "$highest"; then
        echo "version-gate: WARN $name $ver is OLDER than the published $highest; apt will not offer it as an update" >&2
    else
        echo "version-gate: ok $name $ver is new (published highest: ${highest:-none})"
    fi
    return 0
}
