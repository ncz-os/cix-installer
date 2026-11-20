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
# 2026-10-15 (native Forky policy) universe additions: the NCZ suite also carries the native
# Forky-only allowlist -- apple-t2-audio-config 0.5.1+ncz1 and apple-firmware-script
# 20261015+ncz1 (both Architecture: all), libopenvino-2026.4.1 + its three intel
# plugin shlibs and the four intel-*-npu CPack components -- while the whole Ubuntu
# T2 host and the whole Intel apt host are pinned -1. The T2 repo therefore also
# carries HIGHER Ubuntu builds of the two apples and a higher apfs-dkms, the Intel
# repo carries higher builds of the selected names plus two names only it ships, and
# two UNLISTED Debian-named artefacts exist in both repos with NCZ's copy HIGHER.
# The per-architecture half of an override row ('all,amd64' / 'amd64') cannot be
# expressed in a pin at all; it is asserted over real Packages metadata by
# build/test-native-apt-overrides.sh, which drives build/check-ncz-repo-policy.sh.
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
export NCZ_APT_INTEL_HOST="127.0.0.2"   # loopback alias: a third distinct apt origin host
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
entry "$DEB" libgtk4-layer-shell0 1.3.0-1+b1 "$ARCH"
# Debian fallback names (2026-10-15 Forky snapshot 20261012T023456Z): no special pin,
# default priority 500; the policy does NOT block them.
entry "$DEB" apfs-dkms 0.3.21-1 "$ARCH"
# Debian-named artefacts that are NOT in the NCZ override list (Debian 500 wins):
entry "$DEB" libopenvino-forky-extra 4.2.0-1 "$ARCH"
entry "$DEB" intel-forky-extra 2.1.0-1 "$ARCH"
# NCZ
entry "$NCZ" fonts-liberation 1:2.1.5-3build1
entry "$NCZ" libdrm-common 2.4.134-3+ncz1
entry "$NCZ" ncz-wallpapers-ncz 1.1
entry "$NCZ" ncz-evil 1.0
entry "$NCZ" zoder 0.2.1 "$ARCH"
entry "$NCZ" linux-image-7.3.0-t2-ncz 7.3.0-1 "$ARCH"
entry "$NCZ" libfoo 2.0
entry "$NCZ" libgtk4-layer-shell0 1.3.0-1+ncz20261013 "$ARCH"
# NCZ Forky-native builds of the narrow allowlist (2026-10-15).
# A/B -- apples (allowlisted 'all,amd64'). The REAL artifacts are Architecture: all
# (apple-t2-audio-config 0.5.1+ncz1 = 6 UCM configs + 2 docs, no ELF;
# apple-firmware-script 20261015+ncz1 = scripts + docs), and 'all' is how
# Buildkite's managed registry spells them. One stanza per artifact: there is
# NO $ARCH duplicate row in the index (a second row for the same name/version
# would only re-describe the same all-arch deb).
entry "$NCZ" apple-t2-audio-config 0.5.1+ncz1
entry "$NCZ" apple-firmware-script 20261015+ncz1
# C -- libopenvino-2026.4.1 + the three intel-plugin shlibs (amd64 only).
entry "$NCZ" libopenvino-2026.4.1 2026.4.1-1+ncz1 "$ARCH"
entry "$NCZ" libopenvino-intel-cpu-plugin-2026.4.1 2026.4.1-1+ncz1 "$ARCH"
entry "$NCZ" libopenvino-intel-gpu-plugin-2026.4.1 2026.4.1-1+ncz1 "$ARCH"
entry "$NCZ" libopenvino-intel-npu-plugin-2026.4.1 2026.4.1-1+ncz1 "$ARCH"
# D -- the four Intel NPU CPack components (amd64 only).
for _n in intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu; do
    entry "$NCZ" "$_n" 2026.4.1-1+ncz1 "$ARCH"
done
# Two Debian-named artefacts that are NOT allowlisted, where NCZ carries the
# HIGHER build. Without a pin a version contest alone hands the name to NCZ; with
# the pin the NCZ row is 100 and Debian's 500 wins. (A lower NCZ version would
# make the assertion vacuous, so the fixture is deliberately the "wrong" way up.)
entry "$NCZ" libopenvino-forky-extra 9.9.9-1+ncz1 "$ARCH"
entry "$NCZ" intel-forky-extra 9.9.9-1+ncz1 "$ARCH"
# Foreign HIGHER versions of the new allowlist (prove whole-host -1 works):
# the T2 repo's Ubuntu build and the Intel apt repo's Ubuntu build would win
# any contest if their host priority were positive.
entry "$T2" apple-t2-audio-config 99999999-1ubuntu1 "$ARCH"
entry "$T2" apple-firmware-script 99999999-1ubuntu1 "$ARCH"
# T2
entry "$T2" t2fanrd 0.1.0-4 "$ARCH"
entry "$T2" libfoo 3.0 "$ARCH"
entry "$T2" linux-image-t2-fake 1.0 "$ARCH"
# T2 repo carries apfs-dkms too; the policy does NOT prefer it because
# the whole host is -1, so Debian's 0.3.21-1 is the candidate.
entry "$T2" apfs-dkms 1.0 "$ARCH"
for d in "$DEB" "$NCZ" "$T2"; do gzip -kf "$d/Packages"; done

: > "$T/status"
inst() { printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nSection: misc\nInstalled-Size: 1\nMaintainer: T <t@example.invalid>\nArchitecture: all\nVersion: %s\nDescription: %s\n\n' "$1" "$2" "$1" >> "$T/status"; }
inst fonts-liberation 1:2.1.5-3
inst libdrm-common 2.4.134-3+ncz1
inst terser 5.1.0
inst ncz-wallpapers-ncz 1.0
inst libfoo 1.0
# Preview 1 (2026-10-12) shipped the patched layer-shell build that lacks patch 0002
printf 'Package: libgtk4-layer-shell0\nStatus: install ok installed\nPriority: optional\nSection: libs\nInstalled-Size: 1\nMaintainer: T <t@example.invalid>\nArchitecture: %s\nVersion: 1.3.0-1+ncz20260925\nDescription: l\n\n' "$ARCH" >> "$T/status"

# loopback http server for the two host-matched repos
PORT=$((20000 + RANDOM % 20000))
( cd "$T/www" && exec python3 -m http.server "$PORT" --bind 0.0.0.0 >"$T/http.log" 2>&1 ) &
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
# The 1.0.2 policy: the same pin without the libgtk4-layer-shell0 override row.
mkdir -p "$T/prefs-102"
ncz_kernel_purity_pin_text > "$T/prefs-102/00-ncz-kernel-purity.pref"
( eval "_ov_$(declare -f ncz_apt_debian_overrides)"
  ncz_apt_debian_overrides() { _ov_ncz_apt_debian_overrides | awk -F'\t' '$1!="libgtk4-layer-shell0"'; }
  ncz_apt_separation_pin_text ) > "$T/prefs-102/$NCZ_APT_PIN_NAME"

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
polprio() {  # prefsdir pkg -> "<pin-priority> <source-url>" per version-table row
    local -a o; mapfile -t o < <(aptopts "$1")
    apt-cache "${o[@]}" policy "$2" 2>/dev/null | awk '/^ +-?[0-9]+ /{print $1, $2}'
}

candidate_priority() {  # version priority differs from repository index priority
    local -a o; mapfile -t o < <(aptopts "$1")
    apt-cache "${o[@]}" policy "$2" 2>/dev/null | awk -v c="$(cand "$1" "$2")" '
        $1==c {print $2; exit} $1=="***" && $2==c {print $3; exit}'
}

OLD="$T/prefs-old"; NEW="$T/prefs-new"

echo "=== NEGATIVE CONTROL: r200 configuration (no separation pin) reproduces the flagged update ==="
eq "old fonts-liberation candidate (Ubuntu build leaks)" "$(cand "$OLD" fonts-liberation)" "1:2.1.5-3build1"
eq "old libfoo candidate (T2 Ubuntu build wins on version)" "$(cand "$OLD" libfoo)" "3.0"
eq "old ncz-evil candidate (Debian hijacks an NCZ name)" "$(cand "$OLD" ncz-evil)" "9.0"
case "$(upgrade_plan "$OLD")" in *fonts-liberation*) ok "old dist-upgrade plan includes fonts-liberation" ;; *) bad "old plan lacks fonts-liberation: $(upgrade_plan "$OLD")" ;; esac
# The pre-policy shape of every 2026-10-15 row: the Ubuntu T2 host wins its own
# contests at apt's default 500, and an unlisted NCZ name is hijacked on version
# alone. These are the behaviours the NEW rows below have to invert.
eq "old apple-t2-audio-config candidate (Ubuntu T2 build wins)" "$(cand "$OLD" apple-t2-audio-config)" "99999999-1ubuntu1"
eq "old apple-firmware-script candidate (Ubuntu T2 build wins)" "$(cand "$OLD" apple-firmware-script)" "99999999-1ubuntu1"
eq "old apfs-dkms candidate (T2 repo's 1.0 beats Debian 0.3.21-1)" "$(cand "$OLD" apfs-dkms)" "1.0"
eq "old libopenvino-forky-extra candidate (unlisted name: NCZ hijacks it)" "$(cand "$OLD" libopenvino-forky-extra)" "9.9.9-1+ncz1"
eq "old intel-forky-extra candidate (unlisted name: NCZ hijacks it)" "$(cand "$OLD" intel-forky-extra)" "9.9.9-1+ncz1"

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
eq "linux-image-7.3.0-t2-ncz (NCZ kernel) installable" "$(cand "$NEW" linux-image-7.3.0-t2-ncz)" "7.3.0-1"

echo "=== NEW: allowlisted intentional Debian-name override wins ==="
eq "libdrm-common stays on the NCZ +ncz1 patch build" "$(cand "$NEW" libdrm-common)" "2.4.134-3+ncz1"

echo "=== NEW: the patched libgtk4-layer-shell0 reaches a Preview 1 install through apt upgrade ==="
# Preview 1 installed 1.3.0-1+ncz20260925, which already sorts above Debian's 1.3.0-1+b1, so the
# fixed NCZ build is the candidate under the 1.0.2 pin (100) as well as the new one (990): what
# delivers the fix is the package being in the NCZ index. The 990 row matters once Debian ships a
# HIGHER unpatched build (scenario F).
grep -q 'libgtk4-layer-shell0' "$T/prefs-102/$NCZ_APT_PIN_NAME" && bad "1.0.2-shape pin fixture still names libgtk4-layer-shell0" || ok "1.0.2-shape pin fixture has no libgtk4-layer-shell0 row"
eq "1.0.2 pin, Debian 1.3.0-1+b1: candidate is the fixed NCZ build" "$(cand "$T/prefs-102" libgtk4-layer-shell0)" "1.3.0-1+ncz20261013"
eq "new pin, Debian 1.3.0-1+b1: candidate is the fixed NCZ build" "$(cand "$NEW" libgtk4-layer-shell0)" "1.3.0-1+ncz20261013"
case "$(upgrade_plan "$NEW")" in *libgtk4-layer-shell0*) ok "new pin: dist-upgrade delivers the fixed build" ;; *) bad "new pin: libgtk4-layer-shell0 missing from plan: $(upgrade_plan "$NEW")" ;; esac
case "$(src_of "$NEW" libgtk4-layer-shell0)" in "http://localhost:$PORT/ncz"*) ok "libgtk4-layer-shell0 is served by the NCZ host" ;; *) bad "libgtk4-layer-shell0 source: $(src_of "$NEW" libgtk4-layer-shell0)" ;; esac

# --- 2026-10-15 (native Forky policy): the native Forky-only allowlist -------------------
echo "=== NEW: the native T2 apples (A/B) come from NCZ; the Ubuntu T2 host is -1 ==="
eq "apple-t2-audio-config candidate (NCZ-native build, not the T2 99999999-1ubuntu1)" "$(cand "$NEW" apple-t2-audio-config)" "0.5.1+ncz1"
case "$(src_of "$NEW" apple-t2-audio-config)" in "http://localhost:$PORT/ncz"*) ok "  ... served by the NCZ host" ;; *) bad "  apple-t2-audio-config source: $(src_of "$NEW" apple-t2-audio-config)" ;; esac
eq "apple-firmware-script candidate (NCZ-native build, not the T2 99999999-1ubuntu1)" "$(cand "$NEW" apple-firmware-script)" "20261015+ncz1"
case "$(src_of "$NEW" apple-firmware-script)" in "http://localhost:$PORT/ncz"*) ok "  ... served by the NCZ host" ;; *) bad "  apple-firmware-script source: $(src_of "$NEW" apple-firmware-script)" ;; esac
POLPRI="$(polprio "$NEW" apple-t2-audio-config)"
case "$POLPRI" in *"-1 http://127.0.0.1:$PORT/t2"*) ok "  the Ubuntu T2 host is pinned -1 for the whole apple-t2-audio-config table" ;; *) bad "  T2 priority rows: $POLPRI" ;; esac
eq "NCZ audio candidate priority" "$(candidate_priority "$NEW" apple-t2-audio-config)" "990"
POLPRI="$(polprio "$NEW" apple-firmware-script)"
case "$POLPRI" in *"-1 http://127.0.0.1:$PORT/t2"*) ok "  the Ubuntu T2 host is pinned -1 for apple-firmware-script too" ;; *) bad "  T2 priority rows: $POLPRI" ;; esac
eq "NCZ firmware candidate priority" "$(candidate_priority "$NEW" apple-firmware-script)" "990"

echo "=== NEW: Debian's own T2 name (apfs-dkms) is untouched: Debian 500, T2 blocked ==="
eq "apfs-dkms candidate (Debian 0.3.21-1, NOT the T2 repo's higher 1.0)" "$(cand "$NEW" apfs-dkms)" "0.3.21-1"
case "$(src_of "$NEW" apfs-dkms)" in "file:$DEB"*) ok "  apfs-dkms is served by the Debian source" ;; *) bad "  apfs-dkms source: $(src_of "$NEW" apfs-dkms)" ;; esac
POLPRI="$(polprio "$NEW" apfs-dkms)"
case "$POLPRI" in *"500 file:$DEB"*) ok "  Debian keeps apt's default priority 500 for apfs-dkms" ;; *) bad "  apfs-dkms priority rows: $POLPRI" ;; esac

echo "=== NEW: the selected native Intel NPU set (C/D) resolves to NCZ's own build ==="
# The C/D override rows are amd64-ONLY rows, but the generated pin stanza is
# name-based (Package: <name> / Pin: origin <ncz host> / 990) exactly like every
# other override row: this policy retains name-based client pins; the PUBLICATION
# gate enforces architecture metadata, exercised over real
# Packages metadata by build/test-native-apt-overrides.sh. This block exercises
# the other half -- the name really resolves, from the NCZ host, at 990.
NATIVE_CD="libopenvino-2026.4.1 libopenvino-intel-cpu-plugin-2026.4.1 libopenvino-intel-gpu-plugin-2026.4.1 libopenvino-intel-npu-plugin-2026.4.1"
NATIVE_D4="intel-driver-compiler-npu intel-fw-npu intel-level-zero-npu intel-validation-npu"
for _p in $NATIVE_CD $NATIVE_D4; do
    eq "native $_p candidate" "$(cand "$NEW" "$_p")" "2026.4.1-1+ncz1"
    eq "native $_p candidate priority" "$(candidate_priority "$NEW" "$_p")" "990"
    case "$(src_of "$NEW" "$_p")" in "http://localhost:$PORT/ncz"*) ok "  $_p is served by the NCZ host" ;; *) bad "  $_p source: $(src_of "$NEW" "$_p")" ;; esac
done

echo "=== NEW: names outside the allowlist stay Debian's, even when NCZ's build is HIGHER ==="
eq "libopenvino-forky-extra candidate (NCZ 9.9.9-1+ncz1 is only 100)" "$(cand "$NEW" libopenvino-forky-extra)" "4.2.0-1"
case "$(src_of "$NEW" libopenvino-forky-extra)" in "file:$DEB"*) ok "  libopenvino-forky-extra is served by the Debian source" ;; *) bad "  libopenvino-forky-extra source: $(src_of "$NEW" libopenvino-forky-extra)" ;; esac
eq "intel-forky-extra candidate (NCZ 9.9.9-1+ncz1 is only 100)" "$(cand "$NEW" intel-forky-extra)" "2.1.0-1"
case "$(src_of "$NEW" intel-forky-extra)" in "file:$DEB"*) ok "  intel-forky-extra is served by the Debian source" ;; *) bad "  intel-forky-extra source: $(src_of "$NEW" intel-forky-extra)" ;; esac

echo "=== NEW: a host that already installed the OLD foreign apples upgrades to the native set ==="
# The shape hook 55 / ncz-intel-accel-setup creates on an existing install:
# apple-t2-audio-config 0.5.1 and apple-firmware-script 0.6 installed from the
# Ubuntu T2 repo. A plain `apt-get install` of the two names (no -t, no pinning,
# no live hook, isolated apt root) must upgrade both to the NCZ-native builds
# with "0 to remove" -- the r200 pin text offered neither build at all.
cp "$T/status" "$T/status.native-backup"
inst apple-t2-audio-config 0.5.1
inst apple-firmware-script 0.6
mapfile -t _nat < <(aptopts "$NEW")
NATPLAN="$(apt-get "${_nat[@]}" -s --no-remove install apple-t2-audio-config apple-firmware-script 2>&1)"; natrc=$?
eq "unpinned 'apt-get install' of the two apples resolves (rc=0)" "$natrc" "0"
if printf '%s\n' "$NATPLAN" | grep -F >/dev/null 'Inst apple-t2-audio-config [0.5.1] (0.5.1+ncz1'; then
    ok "  it upgrades apple-t2-audio-config to the NCZ-native 0.5.1+ncz1"
else bad "  apple-t2-audio-config is not upgraded to the native build" "$NATPLAN"; fi
if printf '%s\n' "$NATPLAN" | grep -F >/dev/null 'Inst apple-firmware-script [0.6] (20261015+ncz1'; then
    ok "  it upgrades apple-firmware-script to the NCZ-native 20261015+ncz1"
else bad "  apple-firmware-script is not upgraded to the native build" "$NATPLAN"; fi
if printf '%s\n' "$NATPLAN" | grep >/dev/null '^Remv'; then
    bad "  the plan removes a package (apt would not print '0 to remove')" "$NATPLAN"
else ok "  no ^Remv action: an existing install keeps both names ('0 to remove')"; fi
if printf '%s\n' "$NATPLAN" | grep >/dev/null '99999999-1ubuntu1'; then
    bad "  the plan still carries the Ubuntu T2 build" "$NATPLAN"
else ok "  no 99999999-1ubuntu1 (T2) version anywhere in the plan"; fi
cp "$T/status.native-backup" "$T/status"

echo "=== NEW: third-party T2 repo -- the WHOLE host is -1, known names included ==="
# 2026-10-15 (native Forky policy): the old per-name 990 allowlist for adityagarg8.github.io is
# gone; the host is pinned -1 wholesale, so even a name NCZ has never rebuilt
# (t2fanrd) is not installable. Nothing from that host wins a contest.
eq "t2fanrd (Ubuntu T2 repo only, whole host -1) is not installable" "$(cand "$NEW" t2fanrd)" "(none)"
eq "OLD: t2fanrd is installable from the T2 repo without the pin" "$(cand "$OLD" t2fanrd)" "0.1.0-4"
eq "linux-image-t2-fake from the T2 repo is blocked" "$(cand "$NEW" linux-image-t2-fake)" "(none)"
case "$(polprio "$NEW" t2fanrd)" in *"-1 http://127.0.0.1:$PORT/t2"*) ok "the T2 row for t2fanrd sits at -1 (and only at -1)" ;; *) bad "T2 priority rows: $(polprio "$NEW" t2fanrd)" ;; esac

echo "=== NEW: Debian kernel purity pin still composes ==="
eq "Debian linux-image-$ARCH unavailable" "$(cand "$NEW" "linux-image-$ARCH")" "(none)"

echo "=== NEW: what an upgrade would touch ==="
PLAN="$(upgrade_plan "$NEW")"
case "$PLAN" in *fonts-liberation*) bad "new plan still upgrades fonts-liberation: $PLAN" ;; *) ok "fonts-liberation is no longer upgraded" ;; esac
case "$PLAN" in *terser*) ok "terser (Debian update) still offered" ;; *) bad "terser missing from plan: $PLAN" ;; esac
case "$PLAN" in *ncz-wallpapers-ncz*) ok "ncz-wallpapers-ncz (NCZ update) still offered" ;; *) bad "ncz-wallpapers-ncz missing from plan: $PLAN" ;; esac

echo "=== scenario B: image-style install -- offline mirror (Release Origin: NCZ-OS, like build-forky-mirror.sh) + network ==="
# The offline install mirror is labelled NCZ-OS and carries Debian-named packages. The pin must NOT
# demote them (it matches NCZ by host only), so the offline path keeps apt's default priority.
NCZB="$T/nczb"; mk_repo "$NCZB" NCZ-OS forky
entry "$NCZB" fonts-liberation 1:2.1.5-3
entry "$NCZB" libfoo 1.5
entry "$NCZB" offline-only 1.0
gzip -kf "$NCZB/Packages"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEB ./
deb [trusted=yes] file://$NCZB ./
deb [trusted=yes] http://localhost:$PORT/ncz ./
deb [trusted=yes] http://127.0.0.1:$PORT/t2 ./
EOF
apt-get "${UPD[@]}" update >"$T/update2.log" 2>&1
eq "offline-mirror Debian-named package keeps priority (libfoo 1.5 beats NCZ-host 2.0 / T2 3.0)" "$(cand "$NEW" libfoo)" "1.5"
eq "offline-mirror-only package is installable" "$(cand "$NEW" offline-only)" "1.0"
case "$(src_of "$NEW" libfoo)" in "file:$NCZB"*) ok "libfoo is served by the offline mirror" ;; *) bad "libfoo source: $(src_of "$NEW" libfoo)" ;; esac
eq "network leak still loses with the offline mirror present (fonts-liberation)" "$(cand "$NEW" fonts-liberation)" "1:2.1.5-3"
eq "NCZ-host ncz-* package still wins" "$(cand "$NEW" ncz-wallpapers-ncz)" "1.1"
# Capture first: with pipefail, `apt-cache | grep -q` can fail on SIGPIPE when grep exits early.
POL="$(apt-cache "${UPD[@]/prefs-old/prefs-new}" policy libfoo 2>/dev/null)"
grep -q ' 500 .*nczb' <<<"$POL" && ok "offline mirror stays at priority 500" || bad "offline mirror lost its priority 500" "$POL"

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

echo "=== scenario D: Intel deferred install (ncz-intel-accel-setup: UNPINNED apt-get install, Ubuntu-named suite ubuntu24) ==="
# 2026-10-15 (native Forky policy) contract: apt.repos.intel.com is pinned -1 as a WHOLE HOST.
# So Intel can supply NOTHING: not intel-opencl-icd / libze1 / libze-intel-gpu1,
# and not libopenvino-intel-npu-plugin either -- that name falls back to Debian
# forky's own 3000.0-1. The Intel NPU stack NCZ now builds itself arrives under
# the SELECTED names (libopenvino-2026.4.1 + its intel-* plugins, intel-*-npu),
# which the NCZ host serves at 990 even against Intel's HIGHER foreign build.
INTEL="$T/www/intel"; DEBI="$T/debintel"
mk_repo "$INTEL" Intel ubuntu24; mk_repo "$DEBI" Debian testing
for p in intel-opencl-icd libze1 libze-intel-gpu1; do entry "$INTEL" "$p" 99.0-ubuntu24 "$ARCH"; entry "$DEBI" "$p" 25.1-1 "$ARCH"; done
entry "$INTEL" libopenvino-intel-npu-plugin 2026.1.0-intel "$ARCH"; entry "$DEBI" libopenvino-intel-npu-plugin 3000.0-1 "$ARCH"
# Foreign-only names: the Intel repo also carries a HIGHER Ubuntu build of every
# name NCZ now builds natively, plus two names nobody else ships at all.
for p in $NATIVE_CD $NATIVE_D4; do entry "$INTEL" "$p" 2026.4.1-99intel "$ARCH"; done
entry "$INTEL" libopenvino-extra 99.0-ubuntu24 "$ARCH"
entry "$INTEL" intel-other 99.0-ubuntu24 "$ARCH"
gzip -kf "$INTEL/Packages" "$DEBI/Packages"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEBI ./
deb [trusted=yes] http://127.0.0.2:$PORT/intel ./
deb [trusted=yes] http://localhost:$PORT/ncz ./
EOF
apt-get "${UPD[@]}" update >"$T/update4.log" 2>&1
eq "OLD: Intel's Ubuntu intel-opencl-icd wins (the bug the pin prevents)" "$(cand "$OLD" intel-opencl-icd)" "99.0-ubuntu24"
eq "OLD: Debian's libopenvino-intel-npu-plugin already wins without the pin (3000.0-1 > 2026.1.0-intel)" "$(cand "$OLD" libopenvino-intel-npu-plugin)" "3000.0-1"
eq "OLD: Intel's higher foreign build of a selected name wins" "$(cand "$OLD" libopenvino-intel-npu-plugin-2026.4.1)" "2026.4.1-99intel"
eq "OLD: a foreign-only Intel name is installable" "$(cand "$OLD" libopenvino-extra)" "99.0-ubuntu24"
# --- NEW: the whole Intel host is -1 --------------------------------------
eq "NEW: libopenvino-intel-npu-plugin falls back to Debian forky, not Intel" "$(cand "$NEW" libopenvino-intel-npu-plugin)" "3000.0-1"
case "$(src_of "$NEW" libopenvino-intel-npu-plugin)" in "file:$DEBI"*) ok "  ... and it is served by the Debian snapshot source" ;; *) bad "  source: $(src_of "$NEW" libopenvino-intel-npu-plugin)" ;; esac
for p in intel-opencl-icd libze1 libze-intel-gpu1; do eq "NEW: $p comes from Debian forky" "$(cand "$NEW" "$p")" "25.1-1"; done
POLPRI="$(polprio "$NEW" libopenvino-intel-npu-plugin)"
case "$POLPRI" in *"-1 http://127.0.0.2:$PORT/intel"*) ok "the Intel origin carries -1 in the version table" ;; *) bad "Intel priority rows: $POLPRI" ;; esac
case "$POLPRI" in *"500 file:$DEBI"*) ok "the Debian source keeps apt's default 500 for the same name" ;; *) bad "Debian priority rows: $POLPRI" ;; esac
POLPRI="$(polprio "$NEW" intel-opencl-icd)"
case "$POLPRI" in *"-1 http://127.0.0.2:$PORT/intel"*) ok "intel-opencl-icd: Intel's 99.0-ubuntu24 is pinned -1 too" ;; *) bad "Intel priority rows: $POLPRI" ;; esac
# --- NEW: the selected native names win their contest against the foreign build ---
for p in $NATIVE_CD $NATIVE_D4; do
    eq "NEW: $p candidate is NCZ's native build, not Intel's 2026.4.1-99intel" "$(cand "$NEW" "$p")" "2026.4.1-1+ncz1"
    case "$(src_of "$NEW" "$p")" in "http://localhost:$PORT/ncz"*) ok "  $p is served by the NCZ host" ;; *) bad "  $p source: $(src_of "$NEW" "$p")" ;; esac
    case "$(polprio "$NEW" "$p")" in *"-1 http://127.0.0.2:$PORT/intel"*) ok "  the foreign 2026.4.1-99intel build of $p sits at -1" ;; *) bad "  $p Intel priority rows: $(polprio "$NEW" "$p")" ;; esac
done
# --- NEW: a foreign-only name has no candidate at all and apt refuses it ---
for p in libopenvino-extra intel-other; do
    eq "NEW: foreign-only $p (no Debian/NCZ copy) has no candidate" "$(cand "$NEW" "$p")" "(none)"
    mapfile -t _f < <(aptopts "$NEW")
    FPLAN="$(apt-get "${_f[@]}" -s install "$p" 2>&1)"; frc=$?
    if [ "$frc" -ne 0 ]; then ok "NEW: apt-get -s install $p is refused (rc=$frc)"; else bad "NEW: apt-get -s install $p resolved against the blocked Intel host" "$FPLAN"; fi
done
mapfile -t _o < <(aptopts "$NEW")
PLAN="$(apt-get "${_o[@]}" -s install libopenvino-intel-npu-plugin intel-opencl-icd libze1 libze-intel-gpu1 2>&1)"; prc=$?
[ "$prc" = 0 ] && ok "an unpinned apt-get install of the Intel set resolves (rc=0)" || bad "unpinned install plan failed rc=$prc" "$PLAN"
printf '%s\n' "$PLAN" | grep >/dev/null '^Inst libopenvino-intel-npu-plugin (3000.0-1' && printf '%s\n' "$PLAN" | grep >/dev/null '^Inst intel-opencl-icd (25.1-1' \
    && ok "the plan installs Debian's plugin and Debian's runtime (no Intel build)" || bad "wrong sources in the install plan" "$PLAN"
if printf '%s\n' "$PLAN" | grep >/dev/null -E 'ubuntu24|2026\.1\.0-intel|99intel'; then
    bad "the install plan still carries an Intel-origin version" "$PLAN"
else ok "no Intel-origin version (ubuntu24 / *-intel / *99intel) in the install plan"; fi
PLANU="$(apt-get "${_o[@]}" -s --print-uris install libopenvino-intel-npu-plugin intel-opencl-icd libze1 libze-intel-gpu1 2>&1)"
if printf '%s\n' "$PLANU" | grep >/dev/null '127\.0\.0\.2'; then
    bad "the install plan still names an Intel-host artefact URI" "$PLANU"
else ok "the install plan's artefact URIs name no Intel host (whole-host -1)"; fi
ncz_apt_separation_pin_text | grep >/dev/null -i 'cdrom' && bad "the pin text mentions /cdrom" || ok "the pin text does not depend on /cdrom"

echo "=== scenario E: hook 24's ncz-screensavers canary reads the same policy shape with the pin installed ==="
# Extract the canary block from the real hook, run it against REAL apt-cache output (paths/hosts rewritten to what
# the hook greps for: file:/cdrom and packages.buildkite.com/ncz-os/ncz).
python3 - "$PI/24-apt-sources.sh" > "$T/canary.sh" <<'PYC'
import sys
s = open(sys.argv[1]).read()
a = s.index('echo "[24] verifying NCZ-OS apt sources carry ncz-screensavers')
b = s.index("\nfi\n", s.index("apt-cache not on PATH", a)) + 4
print(s[a:b])
PYC
CD="$T/cdrom"; mk_repo "$CD" nclawzero forky; entry "$CD" ncz-screensavers 0.8.9; gzip -kf "$CD/Packages"
entry "$NCZ" ncz-screensavers 0.8.10; gzip -kf -f "$NCZ/Packages"
# Discard only this fixture cache: HTTP Last-Modified has second precision.
find "$T/state/lists" -maxdepth 1 -type f -delete
mkshim() {  # prefsdir dest
    local -a o; mapfile -t o < <(aptopts "$1")
    { echo '#!/bin/bash'; printf '/usr/bin/apt-cache'; printf ' %q' "${o[@]}"
      printf ' "$@" | sed -e %q -e %q\n' "s#http://localhost:$PORT/ncz#https://packages.buildkite.com/ncz-os/ncz/any#" "s#file:$CD#file:/cdrom#"; } > "$2"
    chmod +x "$2"
}
canary() {  # prefsdir tag
    mkdir -p "$T/shim-$2"; mkshim "$1" "$T/shim-$2/apt-cache"
    PATH="$T/shim-$2:$PATH" bash "$T/canary.sh" > "$T/canary-$2.log" 2>&1; echo $?
}
shape() {  # prefsdir -> the source URLs apt lists for ncz-screensavers, priorities dropped
    mkdir -p "$T/shim-s"; mkshim "$1" "$T/shim-s/apt-cache"
    "$T/shim-s/apt-cache" policy ncz-screensavers | awk '/^ +[0-9]+ /{print $2}' | sort -u | tr '\n' ' '
}
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$CD ./
deb [trusted=yes] http://localhost:$PORT/ncz ./
EOF
apt-get "${UPD[@]}" update >"$T/update5.log" 2>&1
eq "canary with the pin: NCZ network source + /cdrom pool -> rc 0" "$(canary "$NEW" netpin)" "0"
grep -q 'OK: NCZ-OS apt sources carry ncz-screensavers (Candidate: 0.8.10)' "$T/canary-netpin.log" && ok "  verdict: OK, candidate from the NCZ network source" || bad "  canary verdict" "$(cat "$T/canary-netpin.log")"
eq "  same source URLs listed with and without the pin" "$(shape "$NEW")" "$(shape "$OLD")"
case "$(shape "$NEW")" in *file:/cdrom*packages.buildkite.com*|*packages.buildkite.com*file:/cdrom*) ok "  policy output still shows both file:/cdrom and the NCZ host" ;; *) bad "  policy shape: $(shape "$NEW")" ;; esac
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$CD ./
EOF
apt-get "${UPD[@]}" update >"$T/update6.log" 2>&1
eq "canary with the pin, offline pool only -> rc 0 (warn, not fatal)" "$(canary "$NEW" offpin)" "0"
grep -q 'resolves only from the offline /cdrom pool' "$T/canary-offpin.log" && ok "  verdict: WARN offline-only" || bad "  canary verdict" "$(cat "$T/canary-offpin.log")"
eq "  same source URLs with and without the pin (offline only)" "$(shape "$NEW")" "$(shape "$OLD")"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEB ./
EOF
apt-get "${UPD[@]}" update >"$T/update7.log" 2>&1
eq "canary with the pin, no ncz-screensavers anywhere -> rc 1 (still FATAL)" "$(canary "$NEW" nonepin)" "1"

echo "=== scenario F: Debian ships a HIGHER unpatched libgtk4-layer-shell0 ==="
DEBF="$T/debf"; mk_repo "$DEBF" Debian testing; entry "$DEBF" libgtk4-layer-shell0 1.3.1-1 "$ARCH"; gzip -kf "$DEBF/Packages"
cat > "$T/sources" <<EOF
deb [trusted=yes] file://$DEBF ./
deb [trusted=yes] http://localhost:$PORT/ncz ./
EOF
apt-get "${UPD[@]}" update >"$T/updateF.log" 2>&1
eq "1.0.2 pin: Debian's unpatched 1.3.1-1 replaces the fix (what the 990 row prevents)" "$(cand "$T/prefs-102" libgtk4-layer-shell0)" "1.3.1-1"
eq "new pin: the patched NCZ build stays the candidate" "$(cand "$NEW" libgtk4-layer-shell0)" "1.3.0-1+ncz20261013"
cp "$T/sources.A" "$T/sources"

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

echo "=== source writer: re-runs never truncate a keyring or leave two repos ==="
echo key > "$T/keys/buildkite-ncz-apt-keyring.asc"; echo key > "$T/keys/ncz-os-apt-keyring.asc"
R4="$T/root4"; PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R4" >/dev/null
GOODSHA="$(sha256sum "$R4/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg" | cut -d' ' -f1)"
mkdir -p "$T/failbin"; printf '#!/bin/sh\nexit 1\n' > "$T/failbin/gpg"; chmod +x "$T/failbin/gpg"
W="$(PATH="$T/failbin:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R4")"
eq "gpg failing on a re-run keeps the working repo" "$W" "buildkite"
eq "gpg failing on a re-run leaves the keyring byte-identical" "$(sha256sum "$R4/etc/apt/keyrings/buildkite-ncz-apt-keyring.gpg" | cut -d' ' -f1)" "$GOODSHA"
eq "re-run: exactly one enabled NCZ list" "$(ls "$R4"/etc/apt/sources.list.d/ncz-os-apt-*.list | wc -l | tr -d ' ')" "1"
R5="$T/root5"; mkdir -p "$R5/etc/apt/sources.list.d"
echo 'deb stale https://packages.buildkite.com/ncz-os/ncz/any/ any main' > "$R5/etc/apt/sources.list.d/ncz-os-apt-buildkite.list"
rm -f "$T/keys/buildkite-ncz-apt-keyring.asc"
W="$(PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R5")"
eq "stale Buildkite list without a keyring: R2 becomes the only repo" "$W" "r2"
eq "  enabled NCZ lists after the re-run" "$(ls "$R5"/etc/apt/sources.list.d/ncz-os-apt-*.list | wc -l | tr -d ' ')" "1"
echo key > "$T/keys/buildkite-ncz-apt-keyring.asc"

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

echo "=== source writer + helper: leave foreign, build-time and Intel/CUDA/ROCm lists alone (build-squashfs-layers, hook 54, intel-accel) ==="
R6="$T/root6"; mkdir -p "$R6/etc/apt/sources.list.d" "$R6/etc/apt/keyrings"
SL="$R6/etc/apt/sources.list.d"
echo 'deb [signed-by=/etc/apt/keyrings/intel-openvino.gpg] https://apt.repos.intel.com/openvino ubuntu24 main' > "$SL/intel-openvino.list"
echo 'deb https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/ /' > "$SL/ncz-cuda-debian12.list"
echo 'deb https://repo.radeon.com/rocm/apt/latest noble main' > "$SL/rocm.list"
echo 'deb [signed-by=/x] https://packages.buildkite.com/ncz-os/ncz/any/ any main' > "$SL/ncz-os-apt-buildkite-live.list"
echo 'deb [signed-by=/x] https://example.invalid/old any main' > "$SL/ncz-os-apt-buildkite.list.disabled-for-build"
echo 'deb [signed-by=/x] https://example.invalid/r2 any main' > "$SL/ncz-os-apt-r2.list.disabled-for-build"
printf 'Types: deb\nURIs: https://deb.debian.org/debian\n' > "$SL/ncz-base.sources.disabled-for-build"
echo ring > "$R6/etc/apt/keyrings/intel-openvino.gpg"
echo t2 > "$SL/t2.list"
echo key > "$T/keys/buildkite-ncz-apt-keyring.asc"; echo key > "$T/keys/ncz-os-apt-keyring.asc"
snap6() {
    ( cd "$R6/etc/apt" && for f in sources.list.d/intel-openvino.list sources.list.d/ncz-cuda-debian12.list sources.list.d/rocm.list \
        sources.list.d/ncz-os-apt-buildkite-live.list sources.list.d/ncz-os-apt-buildkite.list.disabled-for-build \
        sources.list.d/ncz-os-apt-r2.list.disabled-for-build sources.list.d/ncz-base.sources.disabled-for-build sources.list.d/t2.list \
        keyrings/intel-openvino.gpg; do sha256sum "$f" 2>&1; done )
}
snap6 > "$T/before6"
PATH="$FAKEBIN:$PATH" ncz_apt_write_ncz_sources "$T/keys" "$R6" >/dev/null
mkdir -p "$T/h6/usr/sbin"; ncz_apt_install_source_helper "$T/h6"
NCZ_APT_ROOT="$R6" sh "$T/h6/usr/sbin/ncz-apt-source" r2 >/dev/null; NCZ_APT_ROOT="$R6" sh "$T/h6/usr/sbin/ncz-apt-source" buildkite >/dev/null
snap6 > "$T/after6"
grep -q 'No such file' "$T/before6" && bad "fixture file missing" "$(cat "$T/before6")"
diff -q "$T/before6" "$T/after6" >/dev/null && ok "writer + helper (r2 then buildkite) left 9 foreign/build-time files byte-identical" || bad "a foreign or build-time file changed or vanished" "$(diff "$T/before6" "$T/after6")"
eq "exactly one enabled ncz-os-apt-{buildkite,r2}.list (the -live and .disabled-for-build copies are not ours)" "$(ls "$SL"/ncz-os-apt-buildkite.list "$SL"/ncz-os-apt-r2.list 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "=== hook 24 wires the pin + single source (static) ==="
H24="$PI/24-apt-sources.sh"
grep -q 'lib/apt-separation.sh' "$H24" && grep -q 'ncz_apt_write_separation_pin' "$H24" && ok "24-apt-sources.sh writes the separation pin" || bad "24-apt-sources.sh does not write the separation pin"
grep -q 'ncz_apt_write_ncz_sources' "$H24" && ok "24-apt-sources.sh uses the single-repo writer" || bad "24-apt-sources.sh still writes two repos by hand"
n=$(grep -c 'ncz-os-apt-r2.list' "$H24"); [ "$n" -le 2 ] && ok "no hand-written R2 source in 24" || bad "R2 list still hand-written ($n mentions)"

echo "test-apt-separation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
