#!/bin/bash
# test-apt-separation.sh -- prove, with real apt resolution against throwaway
# repos, that post-install/lib/apt-separation.sh keeps NCZ-OS updates and Debian
# updates apart on an installed system, and that the source/helper writers
# leave exactly ONE NCZ repo enabled.
#
# Universe (three origins, like a real NCZ-OS machine):
#   debian  file:  Release Origin: Debian         fonts-liberation 1:2.1.5-3, terser 5.2.0, ...
#   ncz     http://localhost  Release Origin: packagecloud.io/<uuid> (what Buildkite
#           really publishes -- NOT "NCZ-OS"), so the pin must match by HOST
#   t2      http://127.0.0.1  no Origin at all (like adityagarg8's flat repo)
# Installed: fonts-liberation 1:2.1.5-3, libdrm-common 2.4.134-3+ncz1, terser 5.1.0,
#            ncz-wallpapers-ncz 1.0, libfoo 1.0
#
# Every assertion is made twice: WITHOUT the separation pin (the r200 behaviour,
# the negative control that must reproduce the flagged update) and WITH it.
#
# Self-skips (exit 0) when apt, dpkg, python3 or a loopback listener are missing.
# Usage: build/test-apt-separation.sh
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PI="$HERE/../post-install"
for c in apt-get apt-cache dpkg python3; do
    command -v "$c" >/dev/null 2>&1 || { echo "SKIP: $c not available"; exit 0; }
done
ARCH="$(dpkg --print-architecture 2>/dev/null)"
[ -n "$ARCH" ] || { echo "SKIP: no dpkg architecture"; exit 0; }

# apt-get cannot be driven by ~/Projects tmp on a tmpfs-free host only if TMPDIR is sane.
T="$(mktemp -d)"
SRVPID=""
cleanup() { [ -n "$SRVPID" ] && kill "$SRVPID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
eq()  { [ "$2" = "$3" ] && ok "$1 = $3" || bad "$1: got '$2', want '$3'"; }

export NCZ_APT_NCZ_HOSTS="localhost"
export NCZ_APT_T2_HOST="127.0.0.1"
# shellcheck source=../post-install/lib/apt-separation.sh
. "$PI/lib/apt-separation.sh"
# shellcheck source=../post-install/lib/kernel-purity.sh
. "$PI/lib/kernel-purity.sh"

# --- build the universe ------------------------------------------------------
mk_repo() {  # dir origin(or -) suite
    mkdir -p "$1"; : > "$1/Packages"
    {
        [ "$2" != - ] && printf 'Origin: %s\nLabel: %s\n' "$2" "$2"
        printf 'Suite: %s\nCodename: %s\nDate: %s\nArchitectures: %s all\nComponents: main\n' "$3" "$3" "$(date -Ru)" "$ARCH"
    } > "$1/Release"
}
entry() {  # dir name ver [arch]
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nPriority: optional\nSection: misc\nInstalled-Size: 1\nMaintainer: Test <t@example.invalid>\nDescription: %s\nFilename: ./%s_%s.deb\nSize: 1024\nSHA256: %064d\n\n' \
        "$2" "$3" "${4:-all}" "$2" "$2" "$3" 0 >> "$1/Packages"
}
mkdir -p "$T/www"
DEB="$T/debian"; NCZ="$T/www/ncz"; T2="$T/www/t2"
mk_repo "$DEB" Debian testing
mk_repo "$NCZ" 'packagecloud.io/019f10bc-0000-0000-0000-000000000000/019f10be-0000' any
mk_repo "$T2" - ./
# Debian
entry "$DEB" fonts-liberation 1:2.1.5-3
entry "$DEB" libdrm-common 2.4.134-3
entry "$DEB" terser 5.2.0
entry "$DEB" libfoo 1.0
entry "$DEB" ncz-evil 9.0
entry "$DEB" "linux-image-$ARCH" 7.1.9-1
# NCZ
entry "$NCZ" fonts-liberation 1:2.1.5-3build1
entry "$NCZ" libdrm-common 2.4.134-3+ncz1
entry "$NCZ" ncz-wallpapers-ncz 1.1
entry "$NCZ" ncz-evil 1.0
entry "$NCZ" zoder 0.2.1 "$ARCH"
entry "$NCZ" linux-image-7.3.0-t2-trixie 7.3.0-1 "$ARCH"
entry "$NCZ" libfoo 2.0
# T2
entry "$T2" t2fanrd 0.1.0-4 "$ARCH"
entry "$T2" libfoo 3.0 "$ARCH"
entry "$T2" linux-image-t2-fake 1.0 "$ARCH"
for d in "$DEB" "$NCZ" "$T2"; do gzip -kf "$d/Packages"; done

: > "$T/status"
inst() { printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: misc\nInstalled-Size: 1\nMaintainer: T <t@example.invalid>\nArchitecture: all\nVersion: %s\nDescription: %s\n\n' "$1" "$2" "$1" >> "$T/status"; }
inst fonts-liberation 1:2.1.5-3
inst libdrm-common 2.4.134-3+ncz1
inst terser 5.1.0
inst ncz-wallpapers-ncz 1.0
inst libfoo 1.0

# loopback http server for the two host-matched repos
PORT=$((20000 + RANDOM % 20000))
( cd "$T/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$T/http.log" 2>&1 ) &
SRVPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    python3 -c "import socket;s=socket.create_connection(('127.0.0.1',$PORT),1)" 2>/dev/null && break; sleep 0.3
done
python3 -c "import socket;s=socket.create_connection(('127.0.0.1',$PORT),1)" 2>/dev/null \
    || { echo "SKIP: cannot start a loopback http server"; exit 0; }

mkdir -p "$T/state/lists/partial" "$T/cache/archives/partial" "$T/none.d" "$T/apt.conf.d" "$T/trusted.gpg.d"
mkdir -p "$T/prefs-old" "$T/prefs-new"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEB ./
deb [trusted=yes] http://localhost:$PORT/ncz ./
deb [trusted=yes] http://127.0.0.1:$PORT/t2 ./
EOF
cp "$T/sources" "$T/sources.A"
# r200 configuration: only the kernel-purity pin. New: purity + separation.
ncz_kernel_purity_pin_text > "$T/prefs-old/00-ncz-kernel-purity.pref"
ncz_kernel_purity_pin_text > "$T/prefs-new/00-ncz-kernel-purity.pref"
ncz_apt_separation_pin_text > "$T/prefs-new/$NCZ_APT_PIN_NAME"

aptopts() {  # prefs-dir
    printf '%s\n' -o "Dir::Etc::sourcelist=$T/sources" -o "Dir::Etc::sourceparts=-" \
        -o "Dir::Etc::main=$T/apt.conf" -o "Dir::Etc::parts=$T/apt.conf.d" \
        -o "Dir::Etc::preferences=$T/none" -o "Dir::Etc::preferencesparts=$1" \
        -o "Dir::Etc::trusted=$T/trusted.gpg" -o "Dir::Etc::trustedparts=$T/trusted.gpg.d" \
        -o "Dir::State=$T/state" -o "Dir::State::status=$T/status" -o "Dir::Cache=$T/cache" \
        -o Debug::NoLocking=1 -o Acquire::AllowInsecureRepositories=true \
        -o APT::Get::AllowUnauthenticated=true -o Acquire::Languages=none
}
mapfile -t UPD < <(aptopts "$T/prefs-old")
if ! apt-get "${UPD[@]}" update >"$T/update.log" 2>&1; then
    echo "SKIP: apt-get update against the local repos failed"; sed 's/^/      /' "$T/update.log"; exit 0
fi
cand() {  # prefsdir pkg
    local -a o; mapfile -t o < <(aptopts "$1")
    apt-cache "${o[@]}" policy "$2" 2>/dev/null | awk '/^  Candidate:/{sub(/^  Candidate: /,""); print; exit}'
}
upgrade_plan() {  # prefsdir -> names that would be upgraded
    local -a o; mapfile -t o < <(aptopts "$1")
    apt-get "${o[@]}" -s dist-upgrade 2>&1 | awk '/^Inst /{print $2}' | sort | tr '\n' ' '
}
src_of() {  # prefsdir pkg -> the source line (url) serving the candidate
    local -a o; mapfile -t o < <(aptopts "$1")
    apt-cache "${o[@]}" policy "$2" 2>/dev/null | awk -v c="$(cand "$1" "$2")" '
        /Version table:/{t=1; next} t && ($1==c || $2==c) {f=1; next} f && /^ +[0-9]+ /{print $2; exit}'
}

OLD="$T/prefs-old"; NEW="$T/prefs-new"

echo "=== NEGATIVE CONTROL: r200 configuration (no separation pin) reproduces the flagged update ==="
eq "old fonts-liberation candidate (Ubuntu build leaks)" "$(cand "$OLD" fonts-liberation)" "1:2.1.5-3build1"
eq "old libfoo candidate (T2 Ubuntu build wins on version)" "$(cand "$OLD" libfoo)" "3.0"
eq "old ncz-evil candidate (Debian hijacks an NCZ name)" "$(cand "$OLD" ncz-evil)" "9.0"
case "$(upgrade_plan "$OLD")" in *fonts-liberation*) ok "old dist-upgrade plan includes fonts-liberation" ;; *) bad "old plan lacks fonts-liberation: $(upgrade_plan "$OLD")" ;; esac

echo "=== NEW: Debian names come from Debian ==="
eq "fonts-liberation candidate" "$(cand "$NEW" fonts-liberation)" "1:2.1.5-3"
case "$(src_of "$NEW" fonts-liberation)" in "file:$DEB"*) ok "fonts-liberation is served by the Debian source" ;; *) bad "fonts-liberation source: $(src_of "$NEW" fonts-liberation)" ;; esac
eq "libfoo candidate (Debian, not NCZ 2.0 / T2 3.0)" "$(cand "$NEW" libfoo)" "1.0"
eq "terser candidate (genuine Debian update)" "$(cand "$NEW" terser)" "5.2.0"
case "$(src_of "$NEW" terser)" in "file:$DEB"*) ok "terser is served by the Debian source" ;; *) bad "terser source: $(src_of "$NEW" terser)" ;; esac

echo "=== NEW: NCZ names come from NCZ ==="
eq "ncz-wallpapers-ncz candidate" "$(cand "$NEW" ncz-wallpapers-ncz)" "1.1"
eq "zoder candidate" "$(cand "$NEW" zoder)" "0.2.1"
eq "ncz-evil candidate (Debian cannot hijack)" "$(cand "$NEW" ncz-evil)" "1.0"
eq "linux-image-7.3.0-t2-trixie (NCZ kernel) installable" "$(cand "$NEW" linux-image-7.3.0-t2-trixie)" "7.3.0-1"

echo "=== NEW: allowlisted intentional Debian-name override wins ==="
eq "libdrm-common stays on the NCZ +ncz1 patch build" "$(cand "$NEW" libdrm-common)" "2.4.134-3+ncz1"

echo "=== NEW: third-party T2 repo ==="
eq "t2fanrd (known T2 package) candidate" "$(cand "$NEW" t2fanrd)" "0.1.0-4"
eq "linux-image-t2-fake from the T2 repo is blocked" "$(cand "$NEW" linux-image-t2-fake)" "(none)"

echo "=== NEW: Debian kernel purity pin still composes ==="
eq "Debian linux-image-$ARCH unavailable" "$(cand "$NEW" "linux-image-$ARCH")" "(none)"

echo "=== NEW: what an upgrade would touch ==="
PLAN="$(upgrade_plan "$NEW")"
case "$PLAN" in *fonts-liberation*) bad "new plan still upgrades fonts-liberation: $PLAN" ;; *) ok "fonts-liberation is no longer upgraded" ;; esac
case "$PLAN" in *terser*) ok "terser (Debian update) still offered" ;; *) bad "terser missing from plan: $PLAN" ;; esac
case "$PLAN" in *ncz-wallpapers-ncz*) ok "ncz-wallpapers-ncz (NCZ update) still offered" ;; *) bad "ncz-wallpapers-ncz missing from plan: $PLAN" ;; esac

echo "=== scenario B: a self-labelled NCZ repo (Release Origin: NCZ-OS, like R2) is matched by origin name ==="
NCZB="$T/nczb"; mk_repo "$NCZB" NCZ-OS any
entry "$NCZB" fonts-liberation 1:2.1.5-3build1
entry "$NCZB" ncz-wallpapers-ncz 1.1
gzip -kf "$NCZB/Packages"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEB ./
deb [trusted=yes] file://$NCZB ./
EOF
apt-get "${UPD[@]}" update >"$T/update2.log" 2>&1
eq "label-matched: fonts-liberation candidate" "$(cand "$NEW" fonts-liberation)" "1:2.1.5-3"
eq "label-matched: ncz-wallpapers-ncz candidate" "$(cand "$NEW" ncz-wallpapers-ncz)" "1.1"

echo "=== scenario C: a machine that ALREADY installed the leaked build (the arm64 O6N case) ==="
cp "$T/sources.A" "$T/sources"
cp "$T/status" "$T/status.A"
awk 'BEGIN{RS="";ORS="\n\n"} /^Package: fonts-liberation\n/{sub(/Version: [^\n]*/,"Version: 1:2.1.5-3build1")} {print}' "$T/status.A" > "$T/status"
apt-get "${UPD[@]}" update >"$T/update3.log" 2>&1
eq "leaked build is never offered as a candidate" "$(cand "$NEW" fonts-liberation)" "(none)"
PLAN="$(upgrade_plan "$NEW")"
case "$PLAN" in *fonts-liberation*) bad "plan touches the leaked fonts-liberation: $PLAN" ;; *) ok "no spurious upgrade or downgrade of fonts-liberation" ;; esac
mapfile -t _o < <(aptopts "$NEW")
case "$(apt-get "${_o[@]}" -s dist-upgrade 2>&1)" in *"Remv fonts-liberation"*) bad "dist-upgrade would remove fonts-liberation" ;; *) ok "dist-upgrade does not remove fonts-liberation" ;; esac
cp "$T/status.A" "$T/status"

echo "=== source writer leaves exactly ONE enabled NCZ repo ==="
FAKEBIN="$T/fakebin"; mkdir -p "$FAKEBIN" "$T/keys"
printf '#!/bin/sh\ncat\n' > "$FAKEBIN/gpg"; chmod +x "$FAKEBIN/gpg"
echo key > "$T/keys/buildkite-ncz-apt-keyring.asc"; echo key > "$T/keys/ncz-os-apt-keyring.asc"
R="$T/root1"; mkdir -p "$R/etc/apt/sources.list.d"
# pre-existing r200 dual configuration must be migrated
echo 'deb x' > "$R/etc/apt/sources.list.d/ncz-os-apt-r2.list"
echo 'deb y' > "$R/etc/apt/sources.list.d/ncz-os-apt-buildkite.list"
W="$(PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R")"
eq "enabled repo" "$W" "buildkite"
eq "enabled NCZ list files" "$(ls "$R"/etc/apt/sources.list.d/ncz-os-apt-*.list | wc -l | tr -d ' ')" "1"
[ -f "$R/etc/apt/sources.list.d/ncz-os-apt-r2.list.disabled" ] && ok "R2 kept as .list.disabled fallback" || bad "R2 fallback file missing"
[ -s "$R/etc/apt/keyrings/ncz-os-apt-keyring.gpg" ] && ok "R2 keyring staged for the fallback" || bad "R2 keyring not staged"
R2="$T/root2"; rm -f "$T/keys/buildkite-ncz-apt-keyring.asc"
W="$(PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R2")"
eq "Buildkite keyring missing -> R2 is the single enabled repo" "$W" "r2"
eq "  enabled list files" "$(ls "$R2"/etc/apt/sources.list.d/ncz-os-apt-*.list | wc -l | tr -d ' ')" "1"
R3="$T/root3"; rm -f "$T/keys/ncz-os-apt-keyring.asc"
if PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R3" >/dev/null; then bad "no keyrings should fail"; else ok "no keyring -> failure (hook turns it into FATAL)"; fi

echo "=== ncz-apt-source helper switches exactly one ==="
mkdir -p "$T/hroot/usr/sbin"; ncz_apt_install_source_helper "$T/hroot"
H="$T/hroot/usr/sbin/ncz-apt-source"
export NCZ_APT_ROOT="$R"
sh "$H" r2 >/dev/null
eq "after 'r2': enabled lists" "$(ls "$R"/etc/apt/sources.list.d/ncz-os-apt-*.list | wc -l | tr -d ' ')" "1"
[ -f "$R/etc/apt/sources.list.d/ncz-os-apt-r2.list" ] && ok "r2 is the enabled one" || bad "r2 not enabled"
sh "$H" buildkite >/dev/null
[ -f "$R/etc/apt/sources.list.d/ncz-os-apt-buildkite.list" ] && [ ! -f "$R/etc/apt/sources.list.d/ncz-os-apt-r2.list" ] \
    && ok "switching back leaves only Buildkite enabled" || bad "switch back failed"
unset NCZ_APT_ROOT

echo "=== hook 24 wires the pin + single source (static) ==="
H24="$PI/24-apt-sources.sh"
grep -q 'lib/apt-separation.sh' "$H24" && grep -q 'ncz_apt_write_separation_pin' "$H24" && ok "24-apt-sources.sh writes the separation pin" || bad "24-apt-sources.sh does not write the separation pin"
grep -q 'ncz_apt_write_ncz_sources' "$H24" && ok "24-apt-sources.sh uses the single-repo writer" || bad "24-apt-sources.sh still writes two repos by hand"
n=$(grep -c 'ncz-os-apt-r2.list' "$H24"); [ "$n" -le 2 ] && ok "no hand-written R2 source in 24" || bad "R2 list still hand-written ($n mentions)"

echo "test-apt-separation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
