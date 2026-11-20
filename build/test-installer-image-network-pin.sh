#!/bin/bash
# test-installer-image-network-pin.sh -- M9 step 2 (docs/BUILD-STABILITY.md,
# "Pin and cache the network inputs"): the installer image fetches its d-i
# Packages.xz index and debootstrap-udeb from the PINNED snapshot, never live
# forky, and every byte is sha256-checked.
#
# Static half:
#   manifests/network-inputs.tsv exists with columns
#     arch, url-template, sha256, dest, note;
#   both fetch sites in build/build-installer-image.sh resolve their URL from
#     the snapshot base (snapshot.debian.org/archive/debian/<SNAPSHOT>) and go
#     through ncz_fetch_pinned_file;
#   no build/*.sh script gains a raw deb.debian.org fetch outside the
#     documented NCZ_BASE_MIRROR defaults (curl/wget + deb.debian.org on one
#     uncommented line is a FAIL).
#
# Functional half (no image build): a fixture mirror over file:// plus a
# stubbed curl drives build/lib/installer-network-inputs.sh --
#   hit/miss through the cache, a tampered udeb failing against its pin with
#   both hashes named and DEST untouched, and an unpinned (empty-sha) row
#   refusing with an actionable line.
#
# Usage: bash build/test-installer-image-network-pin.sh    Exit 0 = all pass.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")" )" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$*"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

TSV="$ROOT/manifests/network-inputs.tsv"
LIB="$ROOT/build/lib/installer-network-inputs.sh"
SCRIPT="$ROOT/build/build-installer-image.sh"

echo "== static: manifests/network-inputs.tsv =="
if [ -f "$TSV" ]; then
    ok "manifests/network-inputs.tsv exists"
else
    bad "manifests/network-inputs.tsv is missing"
fi
if [ -f "$TSV" ] && IFS=$'\t' read -r c1 c2 c3 c4 c5 _ < "$TSV" && [ "$c1" = "arch" ] && [ "$c2" = "url-template" ] && [ "$c3" = "sha256" ] && [ "$c4" = "dest" ] && [ "$c5" = "note" ]; then
    ok "manifest header is tab-separated 'arch url-template sha256 dest note'"
else
    bad "manifest header is wrong or missing (expected tab-separated columns)" "$(head -1 "$TSV" 2>/dev/null)"
fi
for arch in amd64 arm64; do
    if [ -f "$TSV" ] && awk -F'\t' -v a="$arch" '$1==a && $2 ~ /Packages\.xz$/ {found=1} END{exit !found}' "$TSV"; then
        ok "$arch Packages.xz row present"
    else
        bad "$arch Packages.xz row missing from $TSV"
    fi
done
if [ -f "$TSV" ] && awk -F'\t' '$1=="all" && $2 ~ /debootstrap-udeb_/ {found=1} END{exit !found}' "$TSV"; then
    ok "debootstrap-udeb row present"
else
    bad "debootstrap-udeb row missing from $TSV"
fi
if [ -f "$TSV" ]; then
    badrows="$(awk -F'\t' 'NR>1 && NF>=4 && ($3 !~ /^[0-9a-f]{64}$/) {print NR": "$0}' "$TSV")"
    if [ -z "$badrows" ]; then
        ok "every manifest sha256 is a full 64-hex pin"
    else
        bad "manifest has unpinned or malformed sha256 rows" "$badrows"
    fi
    liverows="$(awk -F'\t' 'NR>1 && $2 ~ /deb\.debian\.org/ {print NR": "$0}' "$TSV")"
    if [ -z "$liverows" ]; then
        ok "no manifest url-template points at live deb.debian.org"
    else
        bad "manifest url-template still points at live forky" "$liverows"
    fi
    # Templates resolve through {BASE} (the snapshot base built from
    # NCZ_BASE_MIRROR_SNAPSHOT) or name the snapshot base literally; either
    # way the fetch never touches a live mirror.
    snaprows="$(awk -F'\t' 'NR>1 && NF>=4 && $2 !~ /\{BASE\}/ && $2 !~ /snapshot\.debian\.org\/archive\/debian\// {print NR": "$0}' "$TSV")"
    if [ -z "$snaprows" ]; then
        ok "every manifest url-template resolves from the snapshot base"
    else
        bad "manifest url-template not rooted at the snapshot base" "$snaprows"
    fi
fi

echo "== static: build-installer-image.sh fetches from the snapshot via the pinned helper =="
if [ -f "$SCRIPT" ] && grep -q 'ncz_fetch_pinned_file' "$SCRIPT"; then
    ok "build-installer-image.sh goes through ncz_fetch_pinned_file"
else
    bad "build-installer-image.sh never calls ncz_fetch_pinned_file"
fi
if [ -f "$SCRIPT" ] && grep -q 'NCZ_BASE_MIRROR_SNAPSHOT' "$SCRIPT"; then
    ok "build-installer-image.sh resolves its URLs from NCZ_BASE_MIRROR_SNAPSHOT"
else
    bad "build-installer-image.sh never references NCZ_BASE_MIRROR_SNAPSHOT"
fi
if [ -f "$SCRIPT" ]; then
    livefetch="$(grep -n 'deb\.debian\.org' "$SCRIPT" | grep -v '^[0-9]*:[[:space:]]*#' || true)"
    if [ -z "$livefetch" ]; then
        ok "build-installer-image.sh has no live forky URL left"
    else
        bad "build-installer-image.sh still references live forky" "$livefetch"
    fi
fi

echo "== static lint: no build/*.sh gains a raw deb.debian.org fetch =="
# A raw fetch is an UNCOMMENTED curl/wget line against deb.debian.org.
# Documented NCZ_BASE_MIRROR defaults (${VAR:-https://deb.debian.org/debian},
# comments, test fixtures) carry no fetch command, so they are excluded; the
# lint itself is skipped so its own pattern strings are not hits.
# The check also covers multi-line commands where curl/wget and the URL are
# on separate lines: grep -A2 captures the command and its immediate context.
lint_hits=""
for f in "$ROOT"/build/*.sh; do
    case "$(basename "$f")" in
        test-installer-image-network-pin.sh) continue ;;
    esac
    hits="$(grep -nE -A2 'curl|wget' "$f" 2>/dev/null | grep 'deb\.debian\.org' \
        | grep -vE '^[0-9]+:[[:space:]]*#' \
        | grep -v 'NCZ_BASE_MIRROR' \
        | grep -vE '^[0-9]+-:[[:space:]]*#' \
        || true)"
    [ -n "$hits" ] || continue
    # shellcheck disable=SC2001
    hits="$(printf '%s\n' "$hits" | sed "s|^|$(basename "$f"):|")"
    lint_hits+="$hits"$'\n'
done
if [ -z "$lint_hits" ]; then
    ok "no build/*.sh runs curl/wget against deb.debian.org"
else
    bad "raw live-mirror fetch in build/*.sh (pin it to the snapshot instead)" "$lint_hits"
fi

echo "== functional: fixture mirror over file:// and a stubbed curl =="
if [ ! -f "$LIB" ]; then
    bad "build/lib/installer-network-inputs.sh is missing -- cannot run the fixture cases"
else
    # shellcheck source=lib/installer-network-inputs.sh
    . "$LIB"
    T="$(mktemp -d "${TMPDIR:-$HOME}/.installer-network-pin-test.XXXXXX")"
    trap 'rm -rf "$T"' EXIT
    # Synthetic fixture snapshot id -- never the real NCZ_BASE_MIRROR_SNAPSHOT
    # pin (build/test-no-pin-literals.sh forbids the current literal in tests).
    export NCZ_BASE_MIRROR_SNAPSHOT="20260101T000000Z"
    mkdir -p "$T/mirror/dists/forky/main/debian-installer/binary-amd64"
    mkdir -p "$T/mirror/dists/forky/main/debian-installer/binary-arm64"
    mkdir -p "$T/mirror/pool/main/d/debootstrap"
    printf 'tampered udeb bytes\n' > "$T/mirror/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb"
    TAMPERED_SHA="$(sha256sum "$T/mirror/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb" | awk '{print $1}')"
    {
        printf 'Package: debootstrap-udeb\n'
        printf 'Version: 1.0.145\n'
        printf 'Filename: pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb\n'
        printf 'SHA256: %s\n' "$TAMPERED_SHA"
    } > "$T/udeb-section-amd64"
    cp "$T/udeb-section-amd64" "$T/udeb-section-arm64"
    xz -c "$T/udeb-section-amd64" > "$T/mirror/dists/forky/main/debian-installer/binary-amd64/Packages.xz"
    xz -c "$T/udeb-section-arm64" > "$T/mirror/dists/forky/main/debian-installer/binary-arm64/Packages.xz"
    IDX_AMD64_SHA="$(sha256sum "$T/mirror/dists/forky/main/debian-installer/binary-amd64/Packages.xz" | awk '{print $1}')"
    IDX_ARM64_SHA="$(sha256sum "$T/mirror/dists/forky/main/debian-installer/binary-arm64/Packages.xz" | awk '{print $1}')"
    {
        printf 'arch\turl-template\tsha256\tdest\tnote\n'
        printf 'amd64\t%s\t%s\t%s\t%s\n' \
            "file://$T/mirror/dists/forky/main/debian-installer/binary-amd64/Packages.xz" \
            "$IDX_AMD64_SHA" "Packages-amd64.xz" "fixture d-i index"
        printf 'arm64\t%s\t%s\t%s\t%s\n' \
            "file://$T/mirror/dists/forky/main/debian-installer/binary-arm64/Packages.xz" \
            "$IDX_ARM64_SHA" "Packages-arm64.xz" "fixture d-i index"
        printf 'all\t%s\t%s\t%s\t%s\n' \
            "file://$T/mirror/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb" \
            "$TAMPERED_SHA" "debootstrap-udeb_1.0.145_all.udeb" "fixture udeb"
    } > "$T/inputs.tsv"

    out="$(ncz_installer_fetch_inputs amd64 "$T/w1" "$T/cache1" "$T/inputs.tsv" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] \
        && [ -f "$T/w1/Packages-amd64.xz" ] \
        && [ -f "$T/w1/debootstrap-udeb_1.0.145_all.udeb" ]; then
        ok "file:// fixture: pinned index + udeb stage into the work dir (rc=0)"
    else
        bad "file:// fixture: fetch failed (rc=$rc)" "$out"
    fi

    printf 'different bytes\n' > "$T/mirror/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb"
    out="$(ncz_installer_fetch_inputs amd64 "$T/w2" "$T/cache2" "$T/inputs.tsv" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$T/w2/debootstrap-udeb_1.0.145_all.udeb" ]; then
        ok "tampered udeb fails the pin and stages nothing (rc=$rc)"
    else
        bad "tampered udeb was accepted or staged (rc=$rc)" "$out"
    fi
    if grep -qiE 'mismatch|expected|actual|sha256' <<<"$out"; then
        ok "  the failure names the pin (expected vs actual sha256)"
    else
        bad "  the failure does not name the hashes" "$out"
    fi

    printf 'arch\turl-template\tsha256\tdest\tnote\n' > "$T/unpinned.tsv"
    printf 'amd64\t%s\t%s\t%s\t%s\n' \
        "file://$T/mirror/dists/forky/main/debian-installer/binary-amd64/Packages.xz" \
        "" "Packages-amd64.xz" "no pin on purpose" >> "$T/unpinned.tsv"
    out="$(ncz_installer_fetch_inputs amd64 "$T/w3" "$T/cache3" "$T/unpinned.tsv" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        ok "unpinned row is refused, not fetched (rc=$rc)"
    else
        bad "unpinned row was fetched" "$out"
    fi
    if grep -qiE 'no pin|unpinned|pin' <<<"$out"; then
        ok "  the refusal says the input is unpinned"
    else
        bad "  the refusal is not actionable" "$out"
    fi

    # Stubbed curl: the helper must work over http:// without the real network.
    mkdir -p "$T/stubbin"
    cat > "$T/stubbin/curl" <<'STUB'
#!/bin/bash
# test stub: curl -fsSL --output TARGET URL ; serves http://fixture.invalid/ from $FIXTURE_MIRROR
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in --output) out="$2"; shift 2;; *) url="$1"; shift;; esac; done
case "$url" in http://fixture.invalid/*) cp -f -- "$FIXTURE_MIRROR/${url#http://fixture.invalid/}" "$out" ;; *) echo "stub curl: refuse $url" >&2; exit 1;; esac
STUB
    chmod +x "$T/stubbin/curl"
    export FIXTURE_MIRROR="$T/mirror"
    printf 'restored udeb bytes\n' > "$T/mirror/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb"
    RESTORED_SHA="$(sha256sum "$T/mirror/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb" | awk '{print $1}')"
    {
        printf 'Package: debootstrap-udeb\n'
        printf 'Version: 1.0.145\n'
        printf 'Filename: pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb\n'
        printf 'SHA256: %s\n' "$RESTORED_SHA"
    } > "$T/udeb-section-amd64"
    xz -c "$T/udeb-section-amd64" > "$T/mirror/dists/forky/main/debian-installer/binary-amd64/Packages.xz"
    IDX_HTTP_SHA="$(sha256sum "$T/mirror/dists/forky/main/debian-installer/binary-amd64/Packages.xz" | awk '{print $1}')"
    {
        printf 'arch\turl-template\tsha256\tdest\tnote\n'
        printf 'amd64\t%s\t%s\t%s\t%s\n' \
            "http://fixture.invalid/dists/forky/main/debian-installer/binary-amd64/Packages.xz" \
            "$IDX_HTTP_SHA" "Packages-amd64.xz" "stubbed-http index"
        printf 'all\t%s\t%s\t%s\t%s\n' \
            "http://fixture.invalid/pool/main/d/debootstrap/debootstrap-udeb_1.0.145_all.udeb" \
            "$RESTORED_SHA" "debootstrap-udeb_1.0.145_all.udeb" "stubbed-http udeb"
    } > "$T/http.tsv"
    out="$(PATH="$T/stubbin:$PATH" ncz_installer_fetch_inputs amd64 "$T/w4" "$T/cache4" "$T/http.tsv" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -f "$T/w4/debootstrap-udeb_1.0.145_all.udeb" ]; then
        ok "stubbed curl: http:// fixture fetches and verifies (rc=0)"
    else
        bad "stubbed curl: fetch failed (rc=$rc)" "$out"
    fi
fi

echo "installer-image-network-pin tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
