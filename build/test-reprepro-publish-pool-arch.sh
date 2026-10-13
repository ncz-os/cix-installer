#!/bin/bash
# test-reprepro-publish-pool-arch.sh -- end-to-end tests of build/ops/publish/ncz-reprepro-publish.sh
# against a mocked reprepro and a mocked Buildkite/R2 (curl stub). Nothing touches the network.
#
# Covers the arm64 pool-path defect: with ncz-usb-recovery 1.1 (Architecture: all) already in the
# repo, publishing 1.2 (arm64) resolved the pool path with `list any NAME | tail -1`, got the OLD
# amd64/all file, posted THAT (Buildkite 409 "verified" for 1.1) and reported "done" while the new
# deb reached neither backend. The publisher must upload exactly the piped deb, and must exit
# non-zero whenever the registry index does not serve that deb (name, version, arch, sha256).
#
# Usage: build/test-reprepro-publish-pool-arch.sh   (NCZ_TEST_PUBLISHER=path tests another copy)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
PUB="${NCZ_TEST_PUBLISHER:-$HERE/ops/publish/ncz-reprepro-publish.sh}"
command -v dpkg-deb >/dev/null || { echo "test-reprepro-publish-pool-arch: needs dpkg-deb" >&2; exit 2; }
# Safety: the publisher must take every location from the environment, or a run here would write
# into a real repository. Refuse a copy that does not, and confine the stubs to the sandbox.
for v in NCZ_APT_REPO_DIR NCZ_R2_PUBLISH_ENV NCZ_PUBLISH_SCRATCH; do
    grep -q "\${$v:-" "$PUB" || { echo "test-reprepro-publish-pool-arch: $PUB does not honour $v; refusing to run it" >&2; exit 2; }
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export NCZ_TEST_SANDBOX="$T"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# --- stubs ---------------------------------------------------------------------------------------
mkdir -p "$T/bin"
# reprepro: a tab-separated db (arch name version file) with the real tool's list order
# (arm64 before amd64, conf/distributions order) and an export of dists/any/main/binary-*/Packages.
cat > "$T/bin/reprepro" <<'EOF'
#!/bin/bash
set -euo pipefail
B=""; A=""; FMT='${package} ${version}\n'
while [ $# -gt 0 ]; do
    case "$1" in
        -b) B="$2"; shift 2 ;; -A) A="$2"; shift 2 ;; --list-format) FMT="$2"; shift 2 ;;
        *) break ;;
    esac
done
case "$(readlink -f "$B")/" in "$(readlink -f "$NCZ_TEST_SANDBOX")"/*) ;; *) echo "reprepro stub: $B is outside the test sandbox" >&2; exit 99 ;; esac
DB="$B/db.tsv"; touch "$DB"
export_indexes() {
    local a
    [ "${MOCK_REPREPRO_NOEXPORT:-0}" = 1 ] && return 0
    for a in arm64 amd64; do
        mkdir -p "$B/dists/any/main/binary-$a"
        awk -F'\t' -v a="$a" '$1 == a' "$DB" | while IFS=$'\t' read -r _ n v f; do
            printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: %s\nSHA256: %s\n\n' \
                "$n" "$v" "$(dpkg-deb -f "$B/$f" Architecture)" "$f" "$(sha256sum "$B/$f" | awk '{print $1}')"
        done > "$B/dists/any/main/binary-$a/Packages"
        gzip -9nc "$B/dists/any/main/binary-$a/Packages" > "$B/dists/any/main/binary-$a/Packages.gz"
    done
    echo "Origin: NCZ-OS" > "$B/dists/any/Release"
}
case "$1" in
    includedeb)
        deb="$3"
        [ "${MOCK_REPREPRO_NOINCLUDE:-0}" = 1 ] && exit 0
        n="$(dpkg-deb -f "$deb" Package)"; v="$(dpkg-deb -f "$deb" Version)"; da="$(dpkg-deb -f "$deb" Architecture)"
        f="pool/main/${n:0:1}/$n/${n}_${v#*:}_${da}.deb"
        mkdir -p "$B/$(dirname "$f")"; cp "$deb" "$B/$f"
        if [ "$da" = all ]; then archs="arm64 amd64"; else archs="$da"; fi
        for a in $archs; do
            awk -F'\t' -v a="$a" -v n="$n" '!($1 == a && $2 == n)' "$DB" > "$DB.new"; mv "$DB.new" "$DB"
            printf '%s\t%s\t%s\t%s\n' "$a" "$n" "$v" "$f" >> "$DB"
        done
        echo "Exporting indices..."; export_indexes ;;
    list)
        n="$3"
        for a in arm64 amd64; do
            [ -z "$A" ] || [ "$A" = "$a" ] || continue
            awk -F'\t' -v a="$a" -v n="$n" '$1 == a && $2 == n' "$DB" | while IFS=$'\t' read -r ar pn v f; do
                o="$FMT"; o="${o//\$\{\$architecture\}/$ar}"; o="${o//\$\{package\}/$pn}"
                o="${o//\$\{version\}/$v}"; o="${o//\$\{Filename\}/$f}"
                o="${o//\\t/$'\t'}"; o="${o//\\n/$'\n'}"; printf '%s' "$o"
            done
        done ;;
    export) export_indexes ;;
    *) echo "reprepro stub: unsupported $*" >&2; exit 2 ;;
esac
EOF
# curl: Buildkite POST / index GET and R2 PUT, logged under $MOCK. MOCK_BK_CODE = POST answer;
# MOCK_BK_INDEXES=1 adds a POSTed deb to the mocked Buildkite index (0 = the index never updates).
cat > "$T/bin/curl" <<'EOF'
#!/bin/bash
out=""; w=""; m=GET; file=""; data=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;; -w) w="$2"; shift 2 ;; -X) m="$2"; shift 2 ;;
        -H|-m) shift 2 ;; -F) file="${2#file=@}"; shift 2 ;; --data-binary) data="${2#@}"; shift 2 ;;
        -*) shift ;; *) url="$1"; shift ;;
    esac
done
code=200
case "$m $url" in
    "POST https://api.buildkite.com/"*)
        code="${MOCK_BK_CODE:-201}"
        echo "POST $(basename "$file") $(sha256sum "$file" | awk '{print $1}')" >> "$MOCK/bk.log"
        if [ "$code" = 201 ] && [ "${MOCK_BK_INDEXES:-1}" = 1 ]; then
            da="$(dpkg-deb -f "$file" Architecture)"; [ "$da" = all ] && archs="amd64 arm64" || archs="$da"
            for a in $archs; do
                printf 'Package: %s\nVersion: %s\nArchitecture: %s\nFilename: pool/any/main/%s\nSHA256: %s\n\n' \
                    "$(dpkg-deb -f "$file" Package)" "$(dpkg-deb -f "$file" Version)" "$da" "$(basename "$file")" \
                    "$(sha256sum "$file" | awk '{print $1}')" >> "$MOCK/bk-$a.Packages"
            done
        fi ;;
    "GET https://packages.buildkite.com/"*"/binary-"*)
        a="${url##*/binary-}"; a="${a%%/*}"; touch "$MOCK/bk-$a.Packages"
        if [ -n "$out" ]; then cp "$MOCK/bk-$a.Packages" "$out"; else cat "$MOCK/bk-$a.Packages"; fi
        exit 0 ;;
    "PUT https://api.cloudflare.com/"*)
        echo "PUT ${url##*/objects/} $(sha256sum "$data" | awk '{print $1}')" >> "$MOCK/r2.log" ;;
    *) echo "curl stub: unexpected $m $url" >&2; exit 22 ;;
esac
[ -n "$w" ] && printf '%s' "$code"
exit 0
EOF
chmod +x "$T/bin/reprepro" "$T/bin/curl"; mkdir -p "$T/home"

mkdeb() {  # out name ver arch marker
    local w="$T/w.$RANDOM$RANDOM"; mkdir -p "$w/DEBIAN" "$w/usr/share/x"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: T <t@example.invalid>\nDescription: t\n' "$2" "$3" "$4" > "$w/DEBIAN/control"
    echo "$5" > "$w/usr/share/x/f"
    dpkg-deb --root-owner-group -Zxz -b "$w" "$1" >/dev/null 2>&1; rm -rf "$w"
}
sha() { sha256sum "$1" | awk '{print $1}'; }

mkdeb "$T/usb11.deb" ncz-usb-recovery 1.1 all old-all
mkdeb "$T/usb12.deb" ncz-usb-recovery 1.2 arm64 new-arm64
mkdeb "$T/usb12-other.deb" ncz-usb-recovery 1.2 arm64 other-bytes
mkdeb "$T/tp10.deb" ncz-testpkg 1.0 all one
mkdeb "$T/tp20.deb" ncz-testpkg 2.0 all two
mkdir -p "$T/poldir"; cp "$ROOT/post-install/lib/apt-separation.sh" "$HERE/lib/deb-version-gate.sh" "$T/poldir/"
printf 'R2_ACCOUNT_ID=a\nR2_BUCKET=b\nR2_TOKEN=t\nBUILDKITE_TOKEN=t\nBUILDKITE_ORG=o\nBUILDKITE_PKG_REGISTRY=r\nR2_PUBLIC_BASE=https://r2.example.invalid\n' > "$T/env"

# fresh <case>: repo holding ncz-usb-recovery 1.1 (all) + ncz-testpkg 1.0 (all), and the matching
# Buildkite index and version-gate index.
fresh() {
    C="$T/case-$1"; rm -rf "$C"; mkdir -p "$C/repo" "$C/mock" "$C/scratch"
    export MOCK="$C/mock"
    PATH="$T/bin:$PATH" reprepro -b "$C/repo" includedeb any "$T/usb11.deb" >/dev/null
    PATH="$T/bin:$PATH" reprepro -b "$C/repo" includedeb any "$T/tp10.deb" >/dev/null
    for a in amd64 arm64; do cp "$C/repo/dists/any/main/binary-$a/Packages" "$MOCK/bk-$a.Packages"; done
    cat "$MOCK/bk-amd64.Packages" "$MOCK/bk-arm64.Packages" > "$MOCK/gate-index"
}
publish() {  # deb [env...] -> RC, OUT
    local deb="$1"; shift
    RC=0
    OUT="$(env HOME="$T/home" PATH="$T/bin:$PATH" NCZ_APT_REPO_DIR="$C/repo" NCZ_R2_PUBLISH_ENV="$T/env" \
        NCZ_PUBLISH_SCRATCH="$C/scratch" NCZ_POLICY_DIR="$T/poldir" NCZ_PUBLISHED_INDEX="$MOCK/gate-index" \
        NCZ_PUBLISH_VERIFY_TRIES=2 NCZ_PUBLISH_VERIFY_SLEEP=0 MOCK="$MOCK" "$@" bash "$PUB" < "$deb" 2>&1)" || RC=$?
}
claims_done() { printf '%s\n' "$OUT" | grep >/dev/null '^== done: '; }

echo "=== 1. arm64 1.2 next to an older Architecture: all 1.1 (the regression) ==="
fresh arm64
publish "$T/usb12.deb"
[ "$RC" = 0 ] && ok "publish exits 0" || bad "publish rc=$RC" "$OUT"
grep -qx "POST ncz-usb-recovery_1.2_arm64.deb $(sha "$T/usb12.deb")" "$MOCK/bk.log" 2>/dev/null \
    && ok "Buildkite received the new arm64 deb" || bad "Buildkite did not receive the new arm64 deb" "$(cat "$MOCK/bk.log" 2>/dev/null)"
grep -q "$(sha "$T/usb11.deb")" "$MOCK/bk.log" 2>/dev/null && bad "the old 1.1 file was posted to Buildkite" || ok "the old 1.1 file was not posted"
grep -qx "PUT pool/main/n/ncz-usb-recovery/ncz-usb-recovery_1.2_arm64.deb $(sha "$T/usb12.deb")" "$MOCK/r2.log" 2>/dev/null \
    && ok "R2 received the new arm64 deb at its pool path" || bad "R2 did not receive the new arm64 deb" "$(cat "$MOCK/r2.log" 2>/dev/null)"
old_pool="$(awk -F'\t' '$2 == "ncz-usb-recovery" && $3 == "1.1" { print $4; exit }' "$C/repo/db.tsv")"
[ -n "$old_pool" ] && ok "the older 1.1 build is still in the repo (amd64): $old_pool" || bad "fixture: no 1.1 row left in the repo"
grep -qF " $old_pool " "$MOCK/r2.log" 2>/dev/null \
    && bad "the old 1.1 file was put to R2" || ok "the old 1.1 file was not put to R2"
printf '%s\n' "$OUT" | grep >/dev/null 'ncz-usb-recovery 1.2 (arm64)' && ok "final line names 1.2 (arm64)" || bad "final line does not name 1.2 (arm64)" "$OUT"

echo "=== 2. Buildkite answers 409 but its index lacks the new deb ==="
fresh bk409
publish "$T/usb12.deb" MOCK_BK_CODE=409
[ "$RC" = 2 ] && ok "publish fails (rc=2)" || bad "rc=$RC, wanted 2 (409 without the deb in the index)" "$OUT"
claims_done && bad "still prints '== done:'" "$OUT" || ok "no '== done:' line"
printf '%s\n' "$OUT" | grep >/dev/null 'FAILED' && ok "the error says FAILED" || bad "no FAILED message" "$OUT"

echo "=== 3. Buildkite answers 201 but the index never serves the deb ==="
fresh bk201
publish "$T/usb12.deb" MOCK_BK_INDEXES=0
[ "$RC" = 2 ] && ok "publish fails (rc=2)" || bad "rc=$RC, wanted 2 (an unverified 201)" "$OUT"
claims_done && bad "still prints '== done:'" "$OUT" || ok "no '== done:' line"

echo "=== 4. 409 and the index serves the same version with DIFFERENT bytes ==="
fresh bksha
printf 'Package: ncz-usb-recovery\nVersion: 1.2\nArchitecture: arm64\nFilename: pool/any/main/x.deb\nSHA256: %s\n\n' "$(sha "$T/usb12-other.deb")" >> "$MOCK/bk-arm64.Packages"
# (the version-gate index stays at 1.1, so the policy passes and only the registry check can refuse)
publish "$T/usb12.deb" MOCK_BK_CODE=409
[ "$RC" = 2 ] && ok "publish fails on a sha mismatch (rc=2)" || bad "rc=$RC, wanted 2 (a different-sha 1.2 must not count as published)" "$OUT"
printf '%s\n' "$OUT" | grep >/dev/null "sha256 $(sha "$T/usb12.deb")" && ok "the error names the expected sha256" || bad "no sha256 in the error" "$OUT"

echo "=== 5. idempotent republish: 409 and the index already serves this exact deb ==="
fresh bkidem
printf 'Package: ncz-usb-recovery\nVersion: 1.2\nArchitecture: arm64\nFilename: pool/any/main/x.deb\nSHA256: %s\n\n' "$(sha "$T/usb12.deb")" | tee -a "$MOCK/bk-arm64.Packages" >> "$MOCK/gate-index"
publish "$T/usb12.deb" MOCK_BK_CODE=409
[ "$RC" = 0 ] && ok "a verified 409 passes" || bad "a verified 409 failed (rc=$RC)" "$OUT"

echo "=== 6. Architecture: all 2.0 over an older all 1.0 ==="
fresh all
publish "$T/tp20.deb"
[ "$RC" = 0 ] && ok "publish exits 0" || bad "publish rc=$RC" "$OUT"
grep -qx "POST ncz-testpkg_2.0_all.deb $(sha "$T/tp20.deb")" "$MOCK/bk.log" 2>/dev/null && ok "Buildkite received 2.0" || bad "Buildkite did not receive 2.0" "$(cat "$MOCK/bk.log" 2>/dev/null)"
[ "$(grep -c '' "$MOCK/bk.log" 2>/dev/null)" = 1 ] && ok "exactly one upload" || bad "more than one upload" "$(cat "$MOCK/bk.log")"

echo "=== 7. reprepro did not include the deb ==="
fresh noinc
publish "$T/usb12.deb" MOCK_REPREPRO_NOINCLUDE=1
[ "$RC" = 5 ] && ok "publish refuses before any upload (rc=5)" || bad "rc=$RC, wanted 5" "$OUT"
[ -s "$MOCK/bk.log" ] || [ -s "$MOCK/r2.log" ] && bad "something was uploaded" || ok "nothing was uploaded"

echo "=== 8. NCZ_PUBLISH_PKG_NAME names another package ==="
fresh name
publish "$T/usb12.deb" NCZ_PUBLISH_PKG_NAME=ncz-testpkg
[ "$RC" = 5 ] && ok "publish refuses a name override that is not the deb's (rc=5)" || bad "rc=$RC, wanted 5" "$OUT"
[ -s "$MOCK/bk.log" ] && bad "something was posted to Buildkite" || ok "nothing was posted"

echo "=== 9. the R2 index export does not carry the deb ==="
fresh noexport
publish "$T/usb12.deb" MOCK_REPREPRO_NOEXPORT=1
[ "$RC" = 6 ] && ok "publish fails (rc=6)" || bad "rc=$RC, wanted 6 (a stale R2 index)" "$OUT"
claims_done && bad "still prints '== done:'" "$OUT" || ok "no '== done:' line"

echo "test-reprepro-publish-pool-arch: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
