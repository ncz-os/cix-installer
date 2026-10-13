#!/bin/bash
# test-ncz-apt-policy-deb.sh -- build the ncz-apt-policy package and run its REAL maintainer
# scripts.
#
# Why (r201 review, blocker): 1.0.0 shipped a #!/bin/sh postinst that sourced the bash-only
# library; dash died on it (rc=2), dpkg left the package half-configured and the pin was never
# written. Nothing in the tree ever built the deb or ran its scripts, so no test could notice.
#
#   1. every packaged script parses under the interpreter its shebang names (dash -n for
#      /bin/sh, bash -n for bash), and no /bin/sh script sources the bash library
#   2. in a debian:forky container (docker or podman, no network): `dpkg -i` leaves the package
#      `install ok installed`, writes the pin, migrates a dual-repo config, is idempotent on
#      reinstall, and purge removes the pin
#   3. negative control: the 1.0.0 shape (sh postinst) is rebuilt from the same tree and FAILS
#      the same container run
# The container part self-skips (exit 0) when neither docker nor podman can run debian:forky.
# Usage: build/test-ncz-apt-policy-deb.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
command -v dpkg-deb >/dev/null 2>&1 || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

: > "$T/empty-index"
echo "=== build ==="
if ! NCZ_PUBLISHED_INDEX="$T/empty-index" NCZ_APT_POLICY_OUT="$T/out" bash "$HERE/build-ncz-apt-policy-deb.sh" >"$T/build.log" 2>&1; then
    bad "build-ncz-apt-policy-deb.sh failed" "$(cat "$T/build.log")"; echo "test-ncz-apt-policy-deb: $PASS passed, $FAIL failed"; exit 1
fi
DEB="$(ls "$T"/out/ncz-apt-policy_*_all.deb)"
VER="$(dpkg-deb -f "$DEB" Version)"
[ "$VER" != 1.0.0 ] && ok "version is $VER (1.0.0 carried the broken postinst and must never ship)" || bad "version is the broken 1.0.0"
dpkg-deb -f "$DEB" Depends | grep -qw bash && ok "Depends includes bash" || bad "Depends lacks bash"

echo "=== 0. bytes match the reviewed ledger row and do not follow commit history ==="
SHA="$(sha256sum "$DEB" | cut -d' ' -f1)"
PIN="$(awk -F'\t' -v v="$VER" '$1=="ncz-apt-policy" && $2==v && $3=="all" {print $4; exit}' "$ROOT/manifests/ncz-packages.tsv")"
if [ -z "$PIN" ]; then bad "manifests/ncz-packages.tsv has no ncz-apt-policy $VER all row"
elif [ "$SHA" = "$PIN" ]; then ok "built sha256 $SHA == ledger row"
else bad "built sha256 $SHA != ledger row $PIN (bump the version or update the row)"; fi
# the same tree outside git, with a comment-only edit to the builder, must give the same bytes
mkdir -p "$T/copy/build/lib" "$T/copy/post-install/lib"
cp "$HERE/build-ncz-apt-policy-deb.sh" "$T/copy/build/"
cp "$HERE/lib/deb-version-gate.sh" "$T/copy/build/lib/"
cp "$ROOT/post-install/lib/apt-separation.sh" "$T/copy/post-install/lib/"
echo '# comment-only edit' >> "$T/copy/build/build-ncz-apt-policy-deb.sh"
if NCZ_PUBLISHED_INDEX="$T/empty-index" NCZ_APT_POLICY_OUT="$T/out-copy" bash "$T/copy/build/build-ncz-apt-policy-deb.sh" >"$T/build-copy.log" 2>&1; then
    SHA2="$(sha256sum "$T"/out-copy/ncz-apt-policy_*_all.deb | cut -d' ' -f1)"
    [ "$SHA2" = "$SHA" ] && ok "comment-only builder edit outside git: same bytes" \
        || bad "comment-only builder edit outside git changed the bytes ($SHA2 != $SHA)"
else
    bad "builder failed from a copied tree" "$(cat "$T/build-copy.log")"
fi

echo "=== 1. every packaged script parses under its own interpreter ==="
dpkg-deb -R "$DEB" "$T/x"
SHDASH="$(command -v dash || true)"
n=0
while IFS= read -r f; do
    first="$(head -c 200 "$f" | head -1)"
    case "$first" in
        '#!/bin/bash'*|'#!/usr/bin/env bash'*) interp=bash ;;
        '#!/bin/sh'*) interp=sh ;;
        *) continue ;;
    esac
    n=$((n+1))
    if [ "$interp" = sh ]; then
        if [ -n "$SHDASH" ]; then out="$("$SHDASH" -n "$f" 2>&1)" && ok "dash -n ${f#"$T/x/"}" || bad "dash -n ${f#"$T/x/"}" "$out"
        else out="$(sh -n "$f" 2>&1)" && ok "sh -n ${f#"$T/x/"} (dash not installed)" || bad "sh -n ${f#"$T/x/"}" "$out"; fi
        if grep -Eq '(^|[[:space:]])(\.|source)[[:space:]]+[^#]*apt-separation\.sh' "$f"; then
            bad "${f#"$T/x/"} is a /bin/sh script that sources the bash-only library"
        fi
    else
        out="$(bash -n "$f" 2>&1)" && ok "bash -n ${f#"$T/x/"}" || bad "bash -n ${f#"$T/x/"}" "$out"
    fi
done < <(find "$T/x" -type f \( -path '*/DEBIAN/*' -o -path '*/usr/sbin/*' \) | sort)
bash -n "$T/x/usr/share/ncz-apt-policy/apt-separation.sh" 2>"$T/lib.err" && ok "bash -n the packaged library" || bad "bash -n the packaged library" "$(cat "$T/lib.err")"
if [ -n "$SHDASH" ]; then
    "$SHDASH" -n "$T/x/usr/share/ncz-apt-policy/apt-separation.sh" >/dev/null 2>&1 \
        && bad "the library parses under dash: the bash-only contract (and this test's premise) changed" \
        || ok "the library is bash-only under dash, so the postinst must be bash"
fi
[ "$n" -ge 3 ] && ok "$n maintainer/helper scripts examined" || bad "only $n scripts examined"
# ownership: the deb must not own the Intel deferred-install units/state, nor any foreign apt list or keyring
owned="$(dpkg-deb -c "$DEB" | awk '{print $6}')"
printf '%s\n' "$owned" | grep -Eq 'ncz-intel-accel|/var/lib/ncz/|intel-openvino|ncz-cuda|rocm|sources\.list\.d|/etc/apt/keyrings' \
    && bad "the package owns a path it must not (Intel units/state, foreign apt lists or keyrings)" "$owned" \
    || ok "the package owns no ncz-intel-accel-setup.*, /var/lib/ncz/intel-accel.*, foreign apt list or keyring"
head -1 "$T/x/DEBIAN/postinst" | grep -q 'bash' && ok "postinst shebang is bash" || bad "postinst shebang is not bash: $(head -1 "$T/x/DEBIAN/postinst")"

echo "=== 2. real maintainer scripts in debian:forky ==="
RT=""
for c in docker podman; do
    command -v "$c" >/dev/null 2>&1 && "$c" image inspect debian:forky >/dev/null 2>&1 && { RT="$c"; break; }
done
if [ -z "$RT" ]; then
    echo "SKIP: no docker/podman with a local debian:forky image; container checks not run"
    echo "test-ncz-apt-policy-deb: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
cat > "$T/inside.sh" <<'INSIDE'
set -u
mkdir -p /etc/apt/sources.list.d
# the r200 shape: BOTH NCZ repos enabled
echo 'deb [trusted=yes] https://packages.buildkite.com/ncz-os/ncz/any/ any main' > /etc/apt/sources.list.d/ncz-os-apt-buildkite.list
echo 'deb [trusted=yes] https://pub-d7b784e01679403d9c70fcd23fff5b96.r2.dev any main' > /etc/apt/sources.list.d/ncz-os-apt-r2.list
# files other components own (hook 54, ncz-intel-accel-setup): must survive install, reinstall and purge untouched
mkdir -p /etc/systemd/system /var/lib/ncz /etc/apt/keyrings
echo 'deb [signed-by=/etc/apt/keyrings/intel-openvino.gpg] https://apt.repos.intel.com/openvino ubuntu24 main' > /etc/apt/sources.list.d/intel-openvino.list
echo 'deb https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /' > /etc/apt/sources.list.d/ncz-cuda-debian12.list
echo ring > /etc/apt/keyrings/intel-openvino.gpg
echo '[Unit]' > /etc/systemd/system/ncz-intel-accel-setup.service; echo '[Timer]' > /etc/systemd/system/ncz-intel-accel-setup.timer
echo pending > /var/lib/ncz/intel-accel.pending
sums() { sha256sum /etc/apt/sources.list.d/intel-openvino.list /etc/apt/sources.list.d/ncz-cuda-debian12.list /etc/apt/keyrings/intel-openvino.gpg /etc/systemd/system/ncz-intel-accel-setup.* /var/lib/ncz/intel-accel.pending 2>&1 | sha256sum | cut -c1-16; }
FOREIGN_BEFORE="$(sums)"
dpkg -i /w/policy.deb > /tmp/dpkg1.log 2>&1; echo "RC_INSTALL=$?"
echo "STATUS=$(dpkg-query -W -f='${db:Status-Abbrev}' ncz-apt-policy 2>/dev/null | tr -d ' ')"
[ -s /etc/apt/preferences.d/10-ncz-origin-separation.pref ] && echo PIN=yes || echo PIN=no
grep -q 'Pin: origin packages.buildkite.com' /etc/apt/preferences.d/10-ncz-origin-separation.pref 2>/dev/null && echo PINCONTENT=yes || echo PINCONTENT=no
[ -f /etc/apt/sources.list.d/ncz-os-apt-r2.list.disabled ] && [ ! -f /etc/apt/sources.list.d/ncz-os-apt-r2.list ] && echo MIGRATED=yes || echo MIGRATED=no
[ -f /etc/apt/sources.list.d/ncz-os-apt-buildkite.list ] && echo BKKEPT=yes || echo BKKEPT=no
[ -x /usr/sbin/ncz-apt-source ] && echo HELPER=yes || echo HELPER=no
echo "AUDIT=$(dpkg --audit 2>&1 | wc -l)"
dpkg -i /w/policy.deb > /tmp/dpkg2.log 2>&1; echo "RC_REINSTALL=$?"
dpkg -P ncz-apt-policy > /tmp/dpkg3.log 2>&1; echo "RC_PURGE=$?"
[ ! -e /etc/apt/preferences.d/10-ncz-origin-separation.pref ] && echo PURGED=yes || echo PURGED=no
[ "$(sums)" = "$FOREIGN_BEFORE" ] && echo FOREIGN_UNTOUCHED=yes || echo FOREIGN_UNTOUCHED=no
tail -5 /tmp/dpkg1.log | sed 's/^/LOG: /'
INSIDE
run_in() {  # deb -> output
    mkdir -p "$T/w"; cp "$1" "$T/w/policy.deb"; cp "$T/inside.sh" "$T/w/inside.sh"
    "$RT" run --rm --network none -v "$T/w:/w:ro" debian:forky bash /w/inside.sh 2>&1
}
OUT="$(run_in "$DEB")"
want() { printf '%s\n' "$OUT" | grep -qx "$1" && ok "container: $1" || bad "container: expected $1" "$OUT"; }
want RC_INSTALL=0; want STATUS=ii; want PIN=yes; want PINCONTENT=yes; want MIGRATED=yes; want BKKEPT=yes
want HELPER=yes; want AUDIT=0; want RC_REINSTALL=0; want RC_PURGE=0; want PURGED=yes; want FOREIGN_UNTOUCHED=yes

echo "=== 3. negative control: the 1.0.0 shape (sh postinst) must fail the same run ==="
mkdir -p "$T/old"; dpkg-deb -R "$DEB" "$T/old/tree"
sed -i '1s|.*|#!/bin/sh|' "$T/old/tree/DEBIAN/postinst"
dpkg-deb --root-owner-group -b "$T/old/tree" "$T/old/old.deb" >/dev/null 2>&1
OUT="$(run_in "$T/old/old.deb")"
printf '%s\n' "$OUT" | grep -qx 'PIN=yes' && bad "sh postinst unexpectedly wrote the pin" "$OUT" || ok "sh postinst: pin never written"
printf '%s\n' "$OUT" | grep -q '^RC_INSTALL=0$' && bad "sh postinst unexpectedly installed cleanly" "$OUT" || ok "sh postinst: dpkg -i fails"
printf '%s\n' "$OUT" | grep -qx 'STATUS=ii' && bad "sh postinst: package reached ii" || ok "sh postinst: package left half-configured, not ii"

echo "test-ncz-apt-policy-deb: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
