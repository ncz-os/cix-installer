#!/bin/bash
# test-layer-gates.sh -- both-direction tests for the layer build-host-state and
# content gates:
#   1. build/build-squashfs-layers.sh strip_build_host_state: every item on its
#      list (resolver config, hostname, hosts, machine ids, mtab, random seed,
#      ssh host keys, leases, apt caches/lists, logs, journal, histories, tmp,
#      LVM backup, NVMe ids, build-user owners and write bits) is removed or
#      reset, and a layer it cannot clean is refused
#   2. build/check-layers.sh no-build-leftovers + layer-ownership: each item FAILs
#      when present and PASSes when absent
#   3. content assertions name files the layers really ship: the ncz-apt-policy
#      assertion (installed package / install-time delivery / kernel-purity pin)
#      and the greeter session; removing a shipped file FAILs. The paths the old
#      assertions wanted are produced by nothing in the tree, so they could never
#      have passed on a correct layer
#   4. no-ubuntu catches Ubuntu builds (Origin, Ubuntu Developers maintainer,
#      NubuntuN/NbuildN versions) and passes Debian packages whose Debian
#      maintainer has an ubuntu.com address or whose name says "canonical"
#   5. layer-perms-allowlist.tsv regexes compile cleanly and the vte rows match
#      the versioned directory (vte-2.91)
#   6. no tracked symlink has an absolute target; assets/kernel/mainline is a
#      generated, ignored link (build/link-kernel-mainline.sh) and never enters a
#      layer
# Ownership needs root semantics: the test re-runs itself under fakeroot.
# Usage: build/test-layer-gates.sh
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
if [ "$(id -u)" != 0 ]; then
    if command -v fakeroot >/dev/null 2>&1 && [ -z "${NCZ_TLG_FAKEROOT:-}" ]; then
        NCZ_TLG_FAKEROOT=1 exec fakeroot bash "$0" "$@"
    fi
    echo "SKIP: test-layer-gates needs root or fakeroot (file ownership)"; exit 0
fi
CL="$HERE/check-layers.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$*"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-tlg.XXXXXX")"; trap 'rm -rf "$T"' EXIT

lc() { local layer="$1"; shift; bash "$CL" "$layer" --arch amd64 --stage t --root "$ROOT" "$@" 2>/dev/null; }
res() { printf '%s\n' "$1" | awk -F'\t' -v i="$2" '$3==i{print $4; exit}'; }
ev()  { printf '%s\n' "$1" | awk -F'\t' -v i="$2" '$3==i{print $5; exit}'; }
want() { # tsv id result what
    local got; got="$(res "$1" "$2")"
    [ "$got" = "$3" ] && ok "$4" || bad "$4 (want $3 got ${got:-none}: $(ev "$1" "$2"))"; }

# ===========================================================================
echo "== 1. strip_build_host_state =="
FN="$T/strip.sh"
{
    echo 'sudo() { "$@"; }'; echo 'log() { echo "[log] $*"; }'
    sed -n '/^NCZ_HOSTS_DEFAULT=/,/^}$/p' "$ROOT/build/build-squashfs-layers.sh"   # hosts default + names + helper
    sed -n '/^strip_build_host_state(){/,/^}$/p' "$ROOT/build/build-squashfs-layers.sh"
} > "$FN"
grep -q '^strip_build_host_state(){' "$FN" && grep -q '^ncz_hosts_foreign_names(){' "$FN" \
    && ok "strip_build_host_state and its hosts helper extracted" || bad "could not extract strip_build_host_state"
mkdirty() {  # root -> a layer carrying every host-state item
    local r="$1"
    mkdir -p "$r"/{etc/ssh,etc/lvm/backup,etc/nvme,var/lib/dbus,var/lib/systemd,var/lib/dhcp,var/cache/apt/archives/partial,var/lib/apt/lists/partial,var/log/journal/abc,root,home/u,tmp/.X11-unix,var/tmp,usr/local/lib/cix-installer/post-install}
    echo builder > "$r/etc/hostname"
    printf '127.0.0.1\tlocalhost\n127.0.1.1\tbuilder.example builder\n' > "$r/etc/hosts"
    printf 'nameserver 10.9.8.7\nsearch example.lan\n' > "$r/etc/resolv.conf"
    echo 0123456789abcdef0123456789abcdef > "$r/etc/machine-id"
    echo 0123456789abcdef0123456789abcdef > "$r/var/lib/dbus/machine-id"
    echo 'proc /proc proc rw 0 0' > "$r/etc/mtab"
    echo seed > "$r/var/lib/systemd/random-seed"; echo s > "$r/var/lib/systemd/credential.secret"
    echo k > "$r/etc/ssh/ssh_host_ed25519_key"; echo k > "$r/etc/ssh/ssh_host_ed25519_key.pub"
    echo lease > "$r/var/lib/dhcp/dhclient.eth0.leases"
    echo bin > "$r/var/cache/apt/pkgcache.bin"; echo deb > "$r/var/cache/apt/archives/x_1_all.deb"
    echo idx > "$r/var/lib/apt/lists/deb.example_dists_forky_InRelease"; : > "$r/var/lib/apt/lists/lock"
    echo m > "$r/var/lib/apt/lists/.ncz-installer-refreshed"
    echo log > "$r/var/log/dpkg.log"; echo j > "$r/var/log/journal/abc/system.journal"
    echo h > "$r/root/.bash_history"; echo h > "$r/home/u/.bash_history"; echo h > "$r/root/.lesshst"
    echo t > "$r/tmp/scratch"; echo t > "$r/var/tmp/scratch"
    echo vg > "$r/etc/lvm/backup/vg0"; echo nqn > "$r/etc/nvme/hostnqn"
    printf '#!/bin/sh\n' > "$r/usr/local/lib/cix-installer/post-install/10-x.sh"
    chmod 0775 "$r/usr/local/lib/cix-installer/post-install/10-x.sh"
    chmod 0664 "$r/etc/hostname"
    chown -R 1000:1000 "$r/usr/local/lib/cix-installer" "$r/home/u"
}
D="$T/dirty"; mkdirty "$D"
out="$(bash -c ". '$FN'; strip_build_host_state '$D' base" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "strip: a dirty layer is cleaned (rc 0)" || bad "strip rc=$rc: $out"
[ "$(cat "$D/etc/hostname")" = localhost ] && ok "strip: hostname -> localhost" || bad "strip: hostname $(cat "$D/etc/hostname")"
grep -q builder "$D/etc/hosts" && bad "strip: hosts still names the builder" || ok "strip: hosts reset to the local names"
[ -f "$D/etc/resolv.conf" ] && [ ! -s "$D/etc/resolv.conf" ] && ok "strip: resolv.conf truncated (file kept)" || bad "strip: resolv.conf not empty"
[ -f "$D/etc/machine-id" ] && [ ! -s "$D/etc/machine-id" ] && ok "strip: machine-id empty" || bad "strip: machine-id"
[ ! -e "$D/var/lib/dbus/machine-id" ] && ok "strip: dbus machine-id removed" || bad "strip: dbus machine-id left"
[ -L "$D/etc/mtab" ] && [ "$(readlink "$D/etc/mtab")" = ../proc/self/mounts ] && ok "strip: mtab is the proc link" || bad "strip: mtab"
for f in var/lib/systemd/random-seed var/lib/systemd/credential.secret etc/ssh/ssh_host_ed25519_key etc/ssh/ssh_host_ed25519_key.pub \
         var/lib/dhcp/dhclient.eth0.leases var/cache/apt/pkgcache.bin var/cache/apt/archives/x_1_all.deb \
         var/lib/apt/lists/deb.example_dists_forky_InRelease var/log/dpkg.log var/log/journal/abc/system.journal \
         root/.bash_history home/u/.bash_history root/.lesshst tmp/scratch var/tmp/scratch etc/lvm/backup/vg0 etc/nvme/hostnqn; do
    [ ! -e "$D/$f" ] && ok "strip: $f removed" || bad "strip: $f left"
done
[ -e "$D/var/lib/apt/lists/lock" ] && [ -e "$D/var/lib/apt/lists/.ncz-installer-refreshed" ] && [ -d "$D/tmp/.X11-unix" ] \
    && ok "strip: apt lock, installer marker and tmp socket dir kept" || bad "strip: removed a kept entry"
n1000="$(find "$D" \( -uid +999 ! -uid 65534 \) -o \( -gid +999 ! -gid 65534 \) | wc -l)"
[ "$n1000" = 0 ] && ok "strip: no build-user owners left" || bad "strip: $n1000 build-user owned entries left"
m="$(stat -c %a "$D/usr/local/lib/cix-installer/post-install/10-x.sh")"
[ "$m" = 755 ] && ok "strip: project file loses the group write bit (0775 -> $m)" || bad "strip: project file mode $m"
# a symlinked resolv.conf / an overlay delta without hostname stay as they are
S2="$T/sym"; mkdir -p "$S2/etc"; ln -s ../run/systemd/resolve/stub-resolv.conf "$S2/etc/resolv.conf"
bash -c ". '$FN'; strip_build_host_state '$S2' desktop" >/dev/null 2>&1 \
    && [ -L "$S2/etc/resolv.conf" ] && [ ! -e "$S2/etc/hostname" ] && ok "strip: resolv.conf symlink kept; delta gets no hostname" || bad "strip: symlink/delta handling"
# refusal: an item strip cannot reset makes it return non-zero
R="$T/refuse"; mkdirty "$R"
mkdir -p "$T/nochown"; printf '#!/bin/sh\nexit 1\n' > "$T/nochown/chown"; chmod 0755 "$T/nochown/chown"
out="$(PATH="$T/nochown:$PATH" bash -c ". '$FN'; strip_build_host_state '$R' base" 2>&1)"; rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep >/dev/null 'would carry build-host state' \
    && ok "strip: a layer it cannot clean (owners stay) is refused" || bad "strip: refusal path rc=$rc"

# ===========================================================================
echo "== 2. check-layers: leftovers + ownership =="
G="$T/g"; mkdir -p "$G/var/lib/dpkg" "$G/etc"; printf 'Package: foo\nStatus: install ok installed\nVersion: 1\n' > "$G/var/lib/dpkg/status"
printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' > "$G/etc/hosts"; echo localhost > "$G/etc/hostname"; : > "$G/etc/resolv.conf"
tsv="$(lc "$G")"; want "$tsv" no-build-leftovers PASS "clean layer: no-build-leftovers PASS"; want "$tsv" layer-ownership PASS "root-owned layer: layer-ownership PASS"
leak() { # name setup-cmd
    local d="$T/l-$1"; rm -rf "$d"; cp -a "$G" "$d"; ( cd "$d" && eval "$2" ); local t; t="$(lc "$d")"
    want "$t" no-build-leftovers FAIL "leftover $1: no-build-leftovers FAIL"; }
leak resolv   'printf "nameserver 10.9.8.7\n" > etc/resolv.conf'
leak hostname 'echo builder > etc/hostname'
leak hosts    'printf "127.0.1.1\tbuilder\n" >> etc/hosts'
leak dbusid   'mkdir -p var/lib/dbus && echo abc > var/lib/dbus/machine-id'
leak seed     'mkdir -p var/lib/systemd && echo s > var/lib/systemd/random-seed'
leak lease    'mkdir -p var/lib/dhcp && echo l > var/lib/dhcp/dhclient.leases'
leak journal  'mkdir -p var/log/journal/abc && echo j > var/log/journal/abc/system.journal'
leak aptbin   'mkdir -p var/cache/apt && echo b > var/cache/apt/pkgcache.bin'
leak aptlist  'mkdir -p var/lib/apt/lists && echo i > var/lib/apt/lists/deb.example_InRelease'
leak history  'mkdir -p home/u && echo h > home/u/.bash_history'
leak vartmp   'mkdir -p var/tmp && echo t > var/tmp/x'
d="$T/l-keep"; cp -a "$G" "$d"; mkdir -p "$d/var/lib/apt/lists/partial" "$d/var/lib/apt/lists/auxfiles"; : > "$d/var/lib/apt/lists/lock"; : > "$d/var/lib/apt/lists/.ncz-installer-refreshed"
tsv="$(lc "$d")"; want "$tsv" no-build-leftovers PASS "apt lock/partial/auxfiles and the installer marker are not leftovers"
d="$T/o-1000"; cp -a "$G" "$d"; mkdir -p "$d/usr/local/lib/cix-installer"; echo x > "$d/usr/local/lib/cix-installer/f"; chown -R 1000:1000 "$d/usr/local/lib/cix-installer"
tsv="$(lc "$d")"; want "$tsv" layer-ownership FAIL "build-user owned project files: layer-ownership FAIL"
d="$T/o-gid"; cp -a "$G" "$d"; echo x > "$d/etc/x"; chown 0:1000 "$d/etc/x"
tsv="$(lc "$d")"; want "$tsv" layer-ownership FAIL "group 1000 alone: layer-ownership FAIL"
d="$T/o-nobody"; cp -a "$G" "$d"; mkdir -p "$d/var/lib/x"; chown 65534:65534 "$d/var/lib/x"; chown 0:998 "$d/etc/hosts"
tsv="$(lc "$d")"; want "$tsv" layer-ownership PASS "nobody/nogroup and system groups are fine"

# a reviewed 'owner' allow-list row exempts exactly its paths
AR="$T/alroot"; mkdir -p "$AR/build"; cp -a "$ROOT/build/lib" "$AR/build/"
{ cat "$ROOT/build/layer-perms-allowlist.tsv"; printf 'owner\t^opt/game(/|$)\ttest fixture\n'; } > "$AR/build/layer-perms-allowlist.tsv"
d="$T/o-allow"; cp -a "$G" "$d"; mkdir -p "$d/opt/game"; echo x > "$d/opt/game/f"; chown -R 1000:1000 "$d/opt/game"
tsv="$(bash "$CL" "$d" --arch amd64 --stage t --root "$AR" 2>/dev/null)"; want "$tsv" layer-ownership PASS "owner allow-list row exempts its path"
echo x > "$d/etc/y"; chown 1000:1000 "$d/etc/y"
tsv="$(bash "$CL" "$d" --arch amd64 --stage t --root "$AR" 2>/dev/null)"; want "$tsv" layer-ownership FAIL "owner allow-list row does not exempt other paths"

# ===========================================================================
echo "== 3. content assertions name shipped files =="
IP=usr/local/lib/cix-installer
mkbase() { # dir: a base layer as the installer delivers ncz-apt-policy (install time)
    local b="$1"; rm -rf "$b"; mkdir -p "$b/usr/bin" "$b/etc/apt/apt.conf.d" "$b/etc/apt/preferences.d" "$b/var/lib/dpkg" "$b/$IP/post-install/lib" "$b/$IP/manifests"
    printf 'Package: apt\nStatus: install ok installed\nVersion: 3\n' > "$b/var/lib/dpkg/status"
    echo pin > "$b/etc/apt/preferences.d/00-ncz-kernel-purity.pref"
    cp "$ROOT/post-install/lib/apt-separation.sh" "$b/$IP/post-install/lib/"; cp "$ROOT/post-install/24-apt-sources.sh" "$b/$IP/post-install/"
    cp "$ROOT/manifests/install-extra.pkgs" "$b/$IP/manifests/"
}
B="$T/base"; mkbase "$B"
tsv="$(lc "$B" --layer base)"; want "$tsv" content-assertions PASS "base as shipped (install-time policy + kernel-purity pin): PASS"
for rmf in etc/apt/preferences.d/00-ncz-kernel-purity.pref $IP/post-install/lib/apt-separation.sh $IP/post-install/24-apt-sources.sh; do
    mkbase "$B"; rm -f "$B/$rmf"; tsv="$(lc "$B" --layer base)"; want "$tsv" content-assertions FAIL "base without $rmf: FAIL"
done
mkbase "$B"; sed -i '/^ncz-apt-policy/d' "$B/$IP/manifests/install-extra.pkgs"; tsv="$(lc "$B" --layer base)"
want "$tsv" content-assertions FAIL "install-extra.pkgs without ncz-apt-policy: FAIL"
mkbase "$B"; rm -rf "$B/$IP"; tsv="$(lc "$B" --layer base)"; want "$tsv" content-assertions FAIL "no apt policy delivery at all: FAIL"
# a layer where the package is installed carries the package files
P="$T/pkg"; mkbase "$P"; rm -rf "$P/$IP"; printf '\nPackage: ncz-apt-policy\nStatus: install ok installed\nVersion: 1.0.4\n' >> "$P/var/lib/dpkg/status"
mkdir -p "$P/usr/sbin" "$P/usr/share/ncz-apt-policy"; : > "$P/usr/sbin/ncz-apt-source"; : > "$P/usr/share/ncz-apt-policy/apt-separation.sh"; : > "$P/etc/apt/preferences.d/10-ncz-origin-separation.pref"
tsv="$(lc "$P" --layer desktop)"; want "$tsv" content-assertions PASS "installed ncz-apt-policy with helper, library and pin: PASS"
rm -f "$P/usr/sbin/ncz-apt-source"; tsv="$(lc "$P" --layer desktop)"; want "$tsv" content-assertions FAIL "installed ncz-apt-policy without ncz-apt-source: FAIL"
# the old assertion: a layer carrying only what it wanted does not satisfy the new one ...
O="$T/old"; mkbase "$O"; rm -rf "$O/$IP" "$O/etc/apt/preferences.d"; : > "$O/usr/bin/ncz-apt-policy"; : > "$O/etc/apt/apt.conf.d/99ncz-policy"
tsv="$(lc "$O" --layer base)"; want "$tsv" content-assertions FAIL "only the old assertion's paths present: FAIL"
# ... and nothing in the tree produces those paths, so on a correct layer it could never pass
prod="$(cd "$ROOT" && git grep -n -E 'usr/bin/ncz-apt-policy|apt\.conf\.d/99ncz-policy' -- . ':!build/check-layers.sh' ':!build/test-layer-gates.sh' 2>/dev/null | head -3)"
[ -z "$prod" ] && ok "no file in the tree writes usr/bin/ncz-apt-policy or apt.conf.d/99ncz-policy" || bad "a producer of the old paths exists: $prod"
if command -v dpkg-deb >/dev/null 2>&1; then
    : > "$T/empty-index"
    if NCZ_PUBLISHED_INDEX="$T/empty-index" NCZ_APT_POLICY_OUT="$T/apdeb" bash "$ROOT/build/build-ncz-apt-policy-deb.sh" >"$T/apdeb.log" 2>&1; then
        c="$(dpkg-deb -c "$T"/apdeb/ncz-apt-policy_*_all.deb | awk '{print $NF}' | sed 's#^\./##')"
        printf '%s\n' "$c" | grep >/dev/null -x 'usr/sbin/ncz-apt-source' && printf '%s\n' "$c" | grep >/dev/null -x 'usr/share/ncz-apt-policy/apt-separation.sh' \
            && ok "the ncz-apt-policy deb ships usr/sbin/ncz-apt-source and its library" || bad "ncz-apt-policy deb contents: $c"
        printf '%s\n' "$c" | grep >/dev/null -E '^usr/bin/ncz-apt-policy$|99ncz-policy' && bad "the deb ships an old-assertion path" || ok "the ncz-apt-policy deb ships neither old-assertion path"
    else bad "build-ncz-apt-policy-deb.sh failed: $(tail -3 "$T/apdeb.log")"; fi
fi
# greeter session
S="$T/sess"; mkdir -p "$S/usr/share/wayland-sessions" "$S/usr/local/bin" "$S/opt/singularity/bin"; : > "$S/opt/singularity/bin/singularity-desktop"
: > "$S/usr/share/wayland-sessions/singularity.desktop"; : > "$S/usr/local/bin/ncz-singularity"
tsv="$(lc "$S" --layer desktop)"; want "$tsv" content-assertions PASS "greeter session as 20-desktop.sh writes it: PASS"
rm -f "$S/usr/share/wayland-sessions/singularity.desktop"; : > "$S/usr/share/wayland-sessions/singularity-labwc-session.desktop"
tsv="$(lc "$S" --layer desktop)"; want "$tsv" content-assertions FAIL "only the never-written singularity-labwc-session.desktop: FAIL"
w="$(grep -n 'singularity.desktop' "$ROOT/post-install/20-desktop.sh" | head -1)"; [ -n "$w" ] && ok "post-install/20-desktop.sh writes singularity.desktop" || bad "20-desktop.sh no longer writes singularity.desktop"

# ===========================================================================
echo "== 4. no-ubuntu =="
U="$T/u"; mkdir -p "$U/var/lib/dpkg"
ubu() { # what want status-stanza
    printf 'Package: base-files\nStatus: install ok installed\nVersion: 14\n\n%b\n' "$3" > "$U/var/lib/dpkg/status"
    local t; t="$(lc "$U")"; want "$t" no-ubuntu "$2" "$1"; }
ubu "fonts-liberation 1:2.1.5-3build1 (Ubuntu rebuild): FAIL" FAIL 'Package: fonts-liberation\nStatus: install ok installed\nMaintainer: Debian Fonts Task Force <debian-fonts@lists.debian.org>\nVersion: 1:2.1.5-3build1'
ubu "0ubuntu1 version: FAIL" FAIL 'Package: foo\nStatus: install ok installed\nVersion: 1.0-0ubuntu1'
ubu "Ubuntu Developers maintainer: FAIL" FAIL 'Package: foo\nStatus: install ok installed\nMaintainer: Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>\nVersion: 1.0-1'
ubu "Origin: Ubuntu: FAIL" FAIL 'Package: snapd\nStatus: install ok installed\nOrigin: Ubuntu\nVersion: 1'
ubu "libeditorconfig0 (Debian maintainer at ubuntu.com): PASS" PASS 'Package: libeditorconfig0\nStatus: install ok installed\nMaintainer: Jeremy Bicha <jbicha@ubuntu.com>\nVersion: 0.12.10-1'
ubu "node-unicode-canonical-property-names-ecmascript: PASS" PASS 'Package: node-unicode-canonical-property-names-ecmascript\nStatus: install ok installed\nMaintainer: Debian Javascript Maintainers <pkg-javascript-devel@lists.alioth.debian.org>\nHomepage: https://github.com/mathiasbynens/unicode-canonical-property-names-ecmascript\nVersion: 2.0.1-1'
ubu "Debian +b1 binNMU: PASS" PASS 'Package: foo\nStatus: install ok installed\nVersion: 1.0-2+b1'

# ===========================================================================
echo "== 5. layer-perms-allowlist.tsv =="
AL="$ROOT/build/layer-perms-allowlist.tsv"
err="$(awk -F'\t' '$1 ~ /^(suid|ww|owner)$/ {print $2}' "$AL" | while IFS= read -r re; do printf 'x' | grep -E "$re" 2>&1 >/dev/null; done)"
[ -z "$err" ] && ok "every allow-list regex compiles without grep warnings" || bad "allow-list regex warnings: $err"
vm() { awk -F'\t' '$1=="suid"{print $2}' "$AL" | while IFS= read -r re; do printf '%s' "$1" | { grep >/dev/null -E "$re" && echo y; } || true; done | grep >/dev/null y; }
vm usr/lib/x86_64-linux-gnu/vte-2.91/vte-spawn-helper && ok "vte-2.91 spawn helper (amd64) is allow-listed" || bad "vte-2.91 amd64 not matched"
vm usr/lib/aarch64-linux-gnu/vte-2.91/vte-spawn-helper && ok "vte-2.91 spawn helper (arm64) is allow-listed" || bad "vte-2.91 arm64 not matched"
vm usr/lib/x86_64-linux-gnu/vte-2.91/other && bad "allow-list matches an unrelated vte file" || ok "allow-list does not match an unrelated file"

# ===========================================================================
echo "== 6. tracked symlinks + the mainline link =="
abs="$(cd "$ROOT" && git ls-files -s 2>/dev/null | awk '$1=="120000"{print $2" "$4}' | while read -r blob p; do
          t="$(git cat-file blob "$blob")"; case "$t" in /*) echo "$p -> $t";; esac; done)"
[ -z "$abs" ] && ok "no tracked symlink has an absolute target" || bad "tracked absolute symlinks: $abs"
( cd "$ROOT" && git ls-files --error-unmatch assets/kernel/mainline >/dev/null 2>&1 ) && bad "assets/kernel/mainline is tracked" || ok "assets/kernel/mainline is not tracked"
( cd "$ROOT" && git check-ignore -q assets/kernel/mainline ) && ok "assets/kernel/mainline is ignored" || bad "assets/kernel/mainline is not ignored"
rel="$(tr -d '[:space:]' < "$ROOT/assets/kernel/mainline.release" 2>/dev/null)"
case "$rel" in r[0-9]*-*-sky1-ncz-[0-9]*) ok "mainline.release names a staged release ($rel)" ;; *) bad "mainline.release: '$rel'" ;; esac
F="$T/tree"; mkdir -p "$F/assets/kernel" "$T/ys/kernel-staging/$rel"; echo "$rel" > "$F/assets/kernel/mainline.release"
out="$(env -u NCZ_KERNEL_STAGING_DIR NCZ_YOCTO_SHARED_DIR="$T/ys" bash "$ROOT/build/link-kernel-mainline.sh" --root "$F" 2>&1)"
[ "$(readlink "$F/assets/kernel/mainline")" = "$T/ys/kernel-staging/$rel" ] && ok "link-kernel-mainline: link from the site pool ($out)" || bad "link-kernel-mainline: $out"
rm -f "$F/assets/kernel/mainline"
env -u NCZ_KERNEL_STAGING_DIR NCZ_YOCTO_SHARED_DIR="$T/nopool" bash "$ROOT/build/link-kernel-mainline.sh" --root "$F" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ ! -e "$F/assets/kernel/mainline" ] && [ ! -L "$F/assets/kernel/mainline" ] && ok "link-kernel-mainline: missing release dir -> rc 1, no dangling link" || bad "link-kernel-mainline missing dir rc=$rc"
env -u NCZ_KERNEL_STAGING_DIR -u NCZ_YOCTO_SHARED_DIR XDG_CONFIG_HOME="$T/noconf" bash "$ROOT/build/link-kernel-mainline.sh" --root "$F" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "link-kernel-mainline: no pool configured -> rc 1" || bad "link-kernel-mainline no pool rc=$rc"
mkdir -p "$F/assets/kernel/mainline"; : > "$F/assets/kernel/mainline/KVER"
env -u NCZ_KERNEL_STAGING_DIR NCZ_YOCTO_SHARED_DIR="$T/ys" bash "$ROOT/build/link-kernel-mainline.sh" --root "$F" >/dev/null 2>&1
[ -d "$F/assets/kernel/mainline" ] && [ ! -L "$F/assets/kernel/mainline" ] && [ -e "$F/assets/kernel/mainline/KVER" ] && ok "link-kernel-mainline: a real directory is left as is" || bad "link-kernel-mainline replaced a real directory"
grep -q 'if \[ -L "$_ka/mainline" \]; then sudo rm -f "$_ka/mainline"; fi' "$ROOT/build/build-squashfs-layers.sh" \
    && ok "the base layer copy leaves the mainline link out" || bad "build-squashfs-layers.sh no longer removes the mainline link"

echo "test-layer-gates: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
