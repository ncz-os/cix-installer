#!/bin/bash
# build/lib/deb-version-gate.sh -- a rebuilt .deb MUST bump its version when its CONTENT changed.
#
# Why (r201, measured on a MacBookPro16,1 test unit 2026-10-07): ncz-wallpapers-{ncz,singularity,
# alex-jay-brady,brandon-perlow} were rebuilt and re-published as 1.0 again.
# apt identifies a version by (version string, package metadata hash), so the
# installed 1.0 and the republished 1.0 are different versions that print the
# same: `apt list --upgradable` shows "1.0 -> 1.0" forever, and two repos
# serving different 1.0 builds make apt flip-flop. A package whose content or
# control data changed needs a new version.
#
# What counts as "changed" (r201 review): NOT the bytes of the .deb. Our
# builders are not all reproducible (the ar/tar mtimes differ per run), so a
# byte comparison refuses an unchanged rebuild. The comparison is a normalised
# CONTENT IDENTITY (ncz_deb_identity): every control field, each maintainer
# script's sha256, the sorted `dpkg-deb -c` listing with modes/owners/sizes/link
# targets but WITHOUT mtimes, and the sha256 of every regular file in the data
# tree. Same identity => allowed (idempotent rebuild). Same version, different
# identity => refused.
#
# ncz_deb_version_gate DEB
#   Looks DEB's (Package, Version, Architecture) up in the published NCZ index:
#     $NCZ_PUBLISHED_INDEX   space-separated Packages files / URLs (tests, offline)
#     else the live Buildkite Packages index for the deb's architecture.
#   Same version published => identical bytes pass at once; otherwise the published
#   .deb is fetched ($NCZ_PUBLISHED_POOL: directory or URL base for the index's
#   Filename; default the Buildkite pool) and the identities are compared.
#   Unreachable index/pool, or an unreadable .deb, FAILS CLOSED (r201: a rebuilt package must not ship
#   unchecked because the network was down). Set NCZ_VERSION_GATE_STRICT=0 explicitly for a deliberately
#   offline build; that downgrades it to a WARNING. TESTS MUST SET NCZ_PUBLISHED_INDEX to a fixture so
#   they never reach the live index.
#
# ncz_policy_deb_lib_check DEB LIB
#   For ncz-apt-policy: the apt-separation.sh packaged in DEB must be byte-identical to LIB
#   (the library whose pin text the deb must carry). Refuses a deb built from a different pin.
#
# Output: one line "version-gate: ..." per decision. Needs dpkg-deb.

# Normalised content identity of a .deb, as text (one fact per line).
ncz_deb_identity() {
    local deb="$1" d
    d="$(mktemp -d)" || return 1
    dpkg-deb -f "$deb" 2>/dev/null | sed 's/^/ctl: /'
    mkdir -p "$d/ctl" "$d/data"
    dpkg-deb -e "$deb" "$d/ctl" 2>/dev/null
    ( cd "$d/ctl" && find . -type f ! -name control -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum | sed 's/^/script: /' )
    dpkg-deb -c "$deb" 2>/dev/null \
        | awk '{ printf "%s %s %s", $1, $2, $3; for (i = 6; i <= NF; i++) printf " %s", $i; print "" }' | LC_ALL=C sort | sed 's/^/list: /'
    dpkg-deb -x "$deb" "$d/data" 2>/dev/null
    ( cd "$d/data" && find . -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r sha256sum | sed 's/^/file: /' )
    rm -rf "$d"
}

ncz_deb_version_gate() {
    local deb="$1" name ver arch sha src rc=0 found_sha="" found_file="" tmp highest="" v a s f
    [ -f "$deb" ] || { echo "version-gate: no such file: $deb" >&2; return 1; }
    name="$(dpkg-deb -f "$deb" Package 2>/dev/null || true)"; ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    arch="$(dpkg-deb -f "$deb" Architecture 2>/dev/null || true)"
    if [ -z "$name" ] || [ -z "$ver" ] || [ -z "$arch" ]; then
        # Not a readable .deb (e.g. a test stubbing dpkg-deb). Never silently pass in strict mode.
        if [ "${NCZ_VERSION_GATE_STRICT:-1}" = 1 ]; then echo "version-gate: FAIL cannot read control fields of $deb" >&2; return 1; fi
        echo "version-gate: WARN cannot read control fields of $deb; not checked" >&2; return 0
    fi
    sha="$(sha256sum "$deb" | awk '{print $1}')"

    local -a srcs
    if [ -n "${NCZ_PUBLISHED_INDEX:-}" ]; then
        read -r -a srcs <<< "$NCZ_PUBLISHED_INDEX"
    else
        local ia="$arch"; [ "$ia" = all ] && ia=amd64
        srcs=("${NCZ_BK_BASE:-https://packages.buildkite.com/ncz-os/ncz/any/dists/any}/main/binary-$ia/Packages")
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
        # stanzas of this package: "version arch sha256 filename"
        while IFS=' ' read -r v a s f; do
            [ "$a" = "$arch" ] || [ "$a" = all ] || [ "$arch" = all ] || continue
            if [ "$v" = "$ver" ]; then found_sha="$s"; found_file="$f"; fi
            if [ -z "$highest" ] || dpkg --compare-versions "$v" gt "$highest"; then highest="$v"; fi
        done < <(awk -v n="$name" '
            /^Package:/{p=$2} /^Version:/{v=$2} /^Architecture:/{a=$2} /^SHA256:/{s=$2} /^Filename:/{f=$2}
            /^$/{ if(p==n) print v, a, s, f; p=""; f="" } END{ if(p==n) print v, a, s, f }' "$tmp")
        break
    done
    rm -f "$tmp"

    if [ "$rc" = 3 ]; then
        if [ "${NCZ_VERSION_GATE_STRICT:-1}" = 1 ]; then
            echo "version-gate: FAIL cannot read the published index and NCZ_VERSION_GATE_STRICT=1" >&2; return 1
        fi
        echo "version-gate: WARN published index unreachable; $name $ver NOT checked for a version bump" >&2
        return 0
    fi
    if [ -n "$found_sha" ] && [ "$found_sha" != "$sha" ]; then
        # Different bytes at the same version. Only a different CONTENT is a violation.
        local pub pubdir base idd ids
        pubdir="$(mktemp -d)"; pub="$pubdir/published.deb"
        base="${NCZ_PUBLISHED_POOL:-${NCZ_BK_BASE:-https://packages.buildkite.com/ncz-os/ncz/any/dists/any}}"
        [ -n "${NCZ_PUBLISHED_POOL:-}" ] || base="${base%/dists/any}"
        case "$base" in
            http://*|https://*) curl -fsSL -m 120 -o "$pub" "${base%/}/$found_file" 2>/dev/null || rm -f "$pub" ;;
            *) cp "${base%/}/$found_file" "$pub" 2>/dev/null || rm -f "$pub" ;;
        esac
        if [ ! -s "$pub" ]; then
            rm -rf "$pubdir"
            if [ "${NCZ_VERSION_GATE_STRICT:-1}" = 1 ]; then
                echo "version-gate: FAIL $name $ver differs in bytes from the published build and the published .deb ($found_file) cannot be fetched to compare content" >&2; return 1
            fi
            echo "version-gate: WARN $name $ver differs in bytes from the published build; the published .deb could not be fetched, content NOT compared" >&2
            return 0
        fi
        ncz_deb_identity "$deb" > "$pubdir/mine"; ncz_deb_identity "$pub" > "$pubdir/theirs"
        if cmp -s "$pubdir/mine" "$pubdir/theirs"; then
            rm -rf "$pubdir"
            echo "version-gate: ok $name $ver has the same content as the published build (only bytes/mtimes differ; idempotent)"
            return 0
        fi
        echo "version-gate: FAIL $name $ver ($arch) is already published with DIFFERENT content." >&2
        echo "version-gate:      rebuilt packages must bump their version (apt would show '$ver -> $ver'). Bump it and rebuild. First differences (published vs this build):" >&2
        diff "$pubdir/theirs" "$pubdir/mine" | head -8 | sed 's/^/version-gate:        /' >&2
        rm -rf "$pubdir"
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

# ncz-apt-policy must carry exactly the library (hence the pin text) it is published from.
ncz_policy_deb_lib_check() {
    local deb="$1" lib="$2" d rc=0
    [ -r "$lib" ] || { echo "version-gate: FAIL policy library $lib unreadable" >&2; return 1; }
    d="$(mktemp -d)"
    dpkg-deb -x "$deb" "$d" 2>/dev/null
    if ! cmp -s "$d/usr/share/ncz-apt-policy/apt-separation.sh" "$lib"; then
        echo "version-gate: FAIL the apt-separation.sh packaged in $(basename "$deb") differs from $lib: the deb was built from a different pin. Build ncz-apt-policy from the exact final head and publish that." >&2
        rc=1
    fi
    rm -rf "$d"
    return "$rc"
}
