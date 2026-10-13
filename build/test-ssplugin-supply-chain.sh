#!/bin/bash
# test-ssplugin-supply-chain.sh -- the Singularity screensaver settings plugin
# (ncz-screensavers-plugin) reaches BOTH images: pin, staging, stage-2 ABI gate,
# medium staging, offline install, registry, baked-mode allowlist. Every guard
# is driven in both directions with synthetic debs (dpkg-deb -b); no network,
# no root, no chroot. SSP_TEST_ROOT=<tree> runs the checks against another
# checkout (a tree without this change fails; that is the fail-before proof).
#
# Optional real-data case: SSP_REAL_PAYLOAD=<ncz-singularity-desktop_*.deb>
# SSP_REAL_ARCH=<arch> runs the stage-2 ABI rule against a real payload with
# the real pin (the staged plugin is replaced by a pin-matching stand-in, the
# payload is real).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SSP_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
command -v dpkg-deb >/dev/null || { echo "SKIP: dpkg-deb not available"; exit 0; }
T="$(mktemp -d "${TMPDIR:-/var/tmp}/ssp-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
ok()  { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAILS=$((FAILS + 1)); echo "FAIL $1"; [ -s "$T/out" ] && sed 's/^/     /' "$T/out" | tail -12; }
expect() { # name want-rc grep-or-empty cmd...
    local n="$1" want="$2" pat="$3"; shift 3
    "$@" >"$T/out" 2>&1; local rc=$?
    if { [ "$want" = 0 ] && [ "$rc" = 0 ]; } || { [ "$want" != 0 ] && [ "$rc" != 0 ]; }; then
        if [ -n "$pat" ] && ! grep -q -- "$pat" "$T/out"; then bad "$n (rc=$rc but no '$pat')"; else ok "$n"; fi
    else bad "$n (rc=$rc, wanted $want)"; fi
}
sha() { sha256sum "$1" | awk '{print $1}'; }
LOCK="$ROOT/post-install/lib/ncz-screensavers-plugin.lock"
LIB="$ROOT/post-install/lib/ncz-ssplugin-install.sh"

# --- fixtures ---------------------------------------------------------------------
# mkplugin OUT ARCH VERSION [PKGNAME] [META_VERSION] [ICON|none] [CATEGORY]: a plugin-shaped
# deb whose screensaver.plugin carries the keys the Plugins page reads (Version, Icon with
# its scalable svg, X-Singularity-Category); the optional arguments break one of them.
mkplugin() {
    local out="$1" arch="$2" ver="$3" pkg="${4:-ncz-screensavers-plugin}" mver="${5:-$3}" icon="${6:-dev.ncz.screensaver}" cat="${7:-lock}" d
    d="$(mktemp -d "$T/pkg.XXXXXX")"
    mkdir -p "$d/DEBIAN" "$d/opt/singularity/lib/singularity/plugins/screensaver"
    echo "so $arch $ver" > "$d/opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so"
    printf '[Plugin]\nModule=screensaver\nVersion=%s\nIcon=%s\nX-Singularity-Category=%s\n' "$mver" "$icon" "$cat" \
        > "$d/opt/singularity/lib/singularity/plugins/screensaver/screensaver.plugin"
    if [ "$icon" != none ]; then
        mkdir -p "$d/opt/singularity/share/icons/hicolor/scalable/apps"
        echo "<svg/>" > "$d/opt/singularity/share/icons/hicolor/scalable/apps/$icon.svg"
    fi
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: Jason Perlow <jperlow@gmail.com>\nDescription: test\n' "$pkg" "$ver" "$arch" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$d" "$out" >/dev/null 2>&1 || dpkg-deb -b "$d" "$out" >/dev/null
}
# mkpayload OUT ARCH VERSION LIBBYTES [SHELLTEXT]: a Singularity-payload-shaped deb; the shell
# binary carries the Plugins category row titles (SHELLTEXT replaces them).
mkpayload() {
    local out="$1" arch="$2" ver="$3" bytes="$4" shell="${5:-Plugins without a category Screensaver and Lock}" d
    d="$(mktemp -d "$T/pay.XXXXXX")"
    mkdir -p "$d/DEBIAN" "$d/opt/singularity/lib" "$d/opt/singularity/bin"
    printf '%s\n' "$shell" > "$d/opt/singularity/bin/singularity-desktop"
    printf '%s' "$bytes" > "$d/opt/singularity/lib/libsingularity.so.0.1.0"
    ln -s libsingularity.so.0.1.0 "$d/opt/singularity/lib/libsingularity.so.0"
    printf 'Package: ncz-singularity-desktop\nVersion: %s\nArchitecture: %s\nMaintainer: x <x@x>\nDescription: test\n' "$ver" "$arch" > "$d/DEBIAN/control"
    dpkg-deb --root-owner-group -b "$d" "$out" >/dev/null 2>&1 || dpkg-deb -b "$d" "$out" >/dev/null
}
# mklock OUT: a pin naming the fixture debs below.
mklock() {
    cat > "$1" <<EOF
NCZ_SSPLUGIN_PKG=ncz-screensavers-plugin
NCZ_SSPLUGIN_VERSION=0.3.16
NCZ_SSPLUGIN_MAINTAINER="Jason Perlow <jperlow@gmail.com>"
NCZ_SSPLUGIN_ARGONAS_DIR=ncz-screensavers-debs/plugin-test
NCZ_SSPLUGIN_SOURCE="ncz-screensavers test 0000000"
NCZ_SSPLUGIN_SHA256_amd64=$(sha "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_amd64.deb")
NCZ_SSPLUGIN_SHA256_arm64=$(sha "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_arm64.deb")
NCZ_SSPLUGIN_PAYLOAD_amd64=20261006+bk0+tgzaaaaaaaa
NCZ_SSPLUGIN_PAYLOAD_arm64=20261006+bk0+tgzbbbbbbbb
NCZ_SSPLUGIN_ABI_LIB=/opt/singularity/lib/libsingularity.so.0
NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_amd64=$(printf 'LIB-A' | sha256sum | awk '{print $1}')
NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_arm64=$(printf 'LIB-B' | sha256sum | awk '{print $1}')
EOF
}
A="$T/store"; mkdir -p "$A/ncz-screensavers-debs/plugin-test"
for a in amd64 arm64; do mkplugin "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_$a.deb" "$a" 0.3.16; done
FL="$T/lock"; mklock "$FL"

# --- 1. the real pin -----------------------------------------------------------------
if [ -r "$LOCK" ] && [ -r "$LIB" ]; then
    for a in amd64 arm64; do
        expect "pin: the real pin loads for $a" 0 "" bash -c ". '$LIB'; ssplugin_load_lock '$LOCK' $a && [ \"\$SSP_VERSION\" ] && [ \"\${#SSP_SHA256}\" = 64 ]"
    done
    sed '/^NCZ_SSPLUGIN_PAYLOAD_arm64=/d' "$LOCK" > "$T/lock.nopayload"
    expect "pin: a pin missing a field is refused" 1 "no value for SSP_PAYLOAD" bash -c ". '$LIB'; ssplugin_load_lock '$T/lock.nopayload' arm64"
    sed 's/^\(NCZ_SSPLUGIN_SHA256_amd64=\).*/\1ZZZ/' "$LOCK" > "$T/lock.badhex"
    expect "pin: a non-hex sha256 is refused" 1 "not lowercase hex" bash -c ". '$LIB'; ssplugin_load_lock '$T/lock.badhex' amd64"
else
    FAILS=$((FAILS + 1)); echo "FAIL pin: $LOCK or $LIB missing (the plugin is not wired)"
fi

# --- 2. staging from the store ------------------------------------------------------------
ST="$ROOT/build/stage-screensaver-plugin.sh"
if [ -r "$ST" ]; then
    O="$T/out-stage"; mkdir -p "$O"
    echo engine > "$O/ncz-screensavers_0.8.10_arm64.deb"
    mkplugin "$O/ncz-screensavers-plugin_0.3.15_arm64.deb" arm64 0.3.15
    mkplugin "$O/ncz-screensavers-plugin_0.3.15_amd64.deb" amd64 0.3.15
    stage() { NCZ_SSPLUGIN_LOCK="$FL" NCZ_SSPLUGIN_SRC_ROOT="$A" NCZ_SSPLUGIN_OUT="$O" bash "$ST" "$@"; }
    expect "stage: the pinned arm64 deb is staged" 0 "staged " stage arm64
    [ "$(sha "$O/ncz-screensavers-plugin_0.3.16_arm64.deb")" = "$(sed -n 's/^NCZ_SSPLUGIN_SHA256_arm64=//p' "$FL")" ] && ok "stage: staged bytes equal the pin" || bad "stage: staged bytes differ from the pin"
    [ ! -e "$O/ncz-screensavers-plugin_0.3.15_arm64.deb" ] && ok "stage: a superseded arm64 plugin deb is removed" || bad "stage: superseded arm64 plugin deb left behind"
    [ -e "$O/ncz-screensavers-plugin_0.3.15_amd64.deb" ] && [ -e "$O/ncz-screensavers_0.8.10_arm64.deb" ] && ok "stage: the other arch and the engine deb are untouched" || bad "stage: removed something it does not own"
    expect "stage: a re-run is a no-op" 0 "identical" stage arm64
    cp -a "$A" "$T/store-bad"; echo tampered >> "$T/store-bad/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_amd64.deb"
    O2="$T/out-bad"; mkdir -p "$O2"
    expect "stage: a source that does not match the pin is refused" 1 "refusing to stage" env NCZ_SSPLUGIN_LOCK="$FL" NCZ_SSPLUGIN_SRC_ROOT="$T/store-bad" NCZ_SSPLUGIN_OUT="$O2" bash "$ST" amd64
    [ -z "$(ls "$O2")" ] && ok "stage: nothing staged after a refused source" || bad "stage: refused source left a file"
    # a deb whose sha matches a pin but whose control says another arch
    cp "$FL" "$T/lock.swap"
    sed -i "s/^NCZ_SSPLUGIN_SHA256_amd64=.*/NCZ_SSPLUGIN_SHA256_amd64=$(sed -n 's/^NCZ_SSPLUGIN_SHA256_arm64=//p' "$FL")/" "$T/lock.swap"
    cp -a "$A" "$T/store-swap"; cp "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_arm64.deb" "$T/store-swap/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_amd64.deb"
    expect "stage: a pin-matching deb with the wrong Architecture is refused" 1 "Architecture is 'arm64'" env NCZ_SSPLUGIN_LOCK="$T/lock.swap" NCZ_SSPLUGIN_SRC_ROOT="$T/store-swap" NCZ_SSPLUGIN_OUT="$O2" bash "$ST" amd64
    expect "stage: a missing source is refused" 1 "missing" env NCZ_SSPLUGIN_LOCK="$FL" NCZ_SSPLUGIN_SRC_ROOT="$T" NCZ_SSPLUGIN_OUT="$O2" bash "$ST" amd64
else
    FAILS=$((FAILS + 1)); echo "FAIL stage: $ST missing"
fi

# --- 3. stage-2 ABI gate -------------------------------------------------------------------
CK="$ROOT/build/check-ssplugin-abi.sh"
if [ -r "$CK" ]; then
    O="$T/out-abi"; C="$T/cix-debs"; mkdir -p "$O" "$C"
    cp "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_amd64.deb" "$O/"
    abi() { NCZ_SSPLUGIN_LOCK="$FL" NCZ_SSPLUGIN_OUT="$O" NCZ_SSPLUGIN_CIX_DEBS="$C" bash "$CK" --arch amd64 "$@"; }
    # the plugin file inside the deb: Version, Icon and category (each broken in turn)
    mkpayload "$C/ncz-singularity-desktop_20261006+bk0+tgzaaaaaaaa_amd64.deb" amd64 20261006+bk0+tgzaaaaaaaa LIB-A
    expect "abi: the good fixture reports its plugin metadata" 0 "plugin metadata OK: Version 0.3.16, Icon dev.ncz.screensaver" abi
    rm -f "$C"/*
    for variant in "stale-version:0.3.16:0.3.15:dev.ncz.screensaver:tools:says Version='0.3.15'" \
                   "no-icon-file:0.3.16:0.3.16:none:tools:installs no scalable" \
                   "bad-category:0.3.16:0.3.16:dev.ncz.screensaver:screensavers:no valid X-Singularity-Category"; do
        IFS=: read -r vname vver vmeta vicon vcat vmsg <<< "$variant"
        V="$T/variant-$vname"; mkdir -p "$V"
        mkplugin "$V/ncz-screensavers-plugin_${vver}_amd64.deb" amd64 "$vver" ncz-screensavers-plugin "$vmeta" "$vicon" "$vcat"
        sed "s/^NCZ_SSPLUGIN_SHA256_amd64=.*/NCZ_SSPLUGIN_SHA256_amd64=$(sha "$V/ncz-screensavers-plugin_${vver}_amd64.deb")/" "$FL" > "$V/lock"
        expect "abi: metadata $vname is refused" 1 "$vmsg" env NCZ_SSPLUGIN_LOCK="$V/lock" NCZ_SSPLUGIN_OUT="$V" NCZ_SSPLUGIN_CIX_DEBS="$C" bash "$CK" --arch amd64
    done
    expect "abi: no payload deb fails" 1 "no Singularity payload deb" abi
    mkpayload "$C/ncz-singularity-desktop_20261006+bk0+tgzaaaaaaaa_amd64.deb" amd64 20261006+bk0+tgzaaaaaaaa LIB-A "Plugins without a category"
    expect "abi: a lock-category plugin over a shell without the row is refused" 1 "no Screensaver and Lock row" abi
    rm -f "$C"/*
    mkpayload "$C/ncz-singularity-desktop_20261006+bk0+tgzaaaaaaaa_amd64.deb" amd64 20261006+bk0+tgzaaaaaaaa LIB-A
    expect "abi: the payload the plugin was built against passes" 0 "ABI OK (version-match)" abi
    rm -f "$C"/*; mkpayload "$C/ncz-singularity-desktop_20261007+bk0+tgzcccccccc_amd64.deb" amd64 20261007+bk0+tgzcccccccc LIB-A
    expect "abi: a rebuilt payload with a byte-identical libsingularity passes" 0 "ABI OK (lib-identical)" abi
    mkpayload "$C/ncz-singularity-desktop_20261008+bk0+tgzdddddddd_amd64.deb" amd64 20261008+bk0+tgzdddddddd LIB-CHANGED
    expect "abi: the newest payload with a changed libsingularity fails" 1 "ABI MISMATCH" abi
    grep -q "amd64: .*container debian:forky" "$T/out" && grep -q "arm64: .*container debian:testing" "$T/out" && grep -q "tools/make-plugin-deb.sh" "$T/out" \
        && ok "abi: the failure prints the rebuild hosts and commands" || bad "abi: the failure lacks rebuild instructions"
    expect "abi: --payload-deb selects an explicit payload" 0 "lib-identical" abi --payload-deb "$C/ncz-singularity-desktop_20261007+bk0+tgzcccccccc_amd64.deb"
    rm -f "$C/ncz-singularity-desktop_20261008"*
    mv "$O/ncz-screensavers-plugin_0.3.16_amd64.deb" "$T/held.deb"
    expect "abi: no staged plugin fails" 1 "stage-screensaver-plugin.sh amd64" abi
    echo bogus > "$O/ncz-screensavers-plugin_0.3.16_amd64.deb"
    expect "abi: a staged plugin that does not match the pin fails" 1 "!= pinned" abi
    cp "$T/held.deb" "$O/ncz-screensavers-plugin_0.3.16_amd64.deb"; cp "$T/held.deb" "$O/ncz-screensavers-plugin_0.3.17_amd64.deb"
    expect "abi: two staged plugin debs fail" 1 "found 2" abi
    rm -f "$O/ncz-screensavers-plugin_0.3.17_amd64.deb"
    expect "abi: an arm64 build ignores the amd64 staging" 1 "found 0" env NCZ_SSPLUGIN_LOCK="$FL" NCZ_SSPLUGIN_OUT="$O" NCZ_SSPLUGIN_CIX_DEBS="$C" bash "$CK" --arch arm64
    if [ -n "${SSP_REAL_PAYLOAD:-}" ] && [ -s "$SSP_REAL_PAYLOAD" ]; then
        ra="${SSP_REAL_ARCH:?SSP_REAL_ARCH}"
        expect "abi (REAL payload $(basename "$SSP_REAL_PAYLOAD")): real pin rule passes" 0 "ABI OK" \
            env NCZ_SSPLUGIN_LOCK="$LOCK" bash -c ". '$LIB'; ssplugin_load_lock '$LOCK' $ra; w=\$(mktemp -d '$T/real.XXXX'); dpkg-deb -x '$SSP_REAL_PAYLOAD' \$w; v=\$(dpkg-deb -f '$SSP_REAL_PAYLOAD' Version); l=\$(sha256sum \$(readlink -f \$w\$SSP_ABI_LIB) | cut -d' ' -f1); r=\$(ssplugin_abi_verdict \"\$v\" \"\$l\") && echo \"ABI OK (\$r) \$v \$l\""
        cat "$T/out"
    fi
else
    FAILS=$((FAILS + 1)); echo "FAIL abi: $CK missing"
fi

# --- 4. the offline install (hook 59's plugin step) ------------------------------------
if [ -r "$LIB" ]; then
    # Stubs: dpkg-query reads $R/status; apt-get -s prints Inst (or Remv when
    # SIM_REMOVE=1); apt-get install unpacks the deb into $R and records it.
    S="$T/stubs"; mkdir -p "$S"
    cat > "$S/dpkg-query" <<'EOF'
#!/bin/bash
fmt=""; while [ $# -gt 1 ]; do case "$1" in -W) shift ;; -f=*) fmt="${1#-f=}"; shift ;; -f) fmt="$2"; shift 2 ;; *) shift ;; esac; done
pkg="$1"; f="$NCZ_SSPLUGIN_ROOT/status"
line="$(awk -v p="$pkg" 'BEGIN{RS="";FS="\n"} {pk="";st="";v=""; for(i=1;i<=NF;i++){ if($i~/^Package: /)pk=substr($i,10); if($i~/^Status: /)st=substr($i,9); if($i~/^Version: /)v=substr($i,10)} if(pk==p) print st "|" v}' "$f" | tail -1)"
[ -n "$line" ] || exit 1
o="${fmt//'${Status}'/${line%%|*}}"; o="${o//'${Version}'/${line#*|}}"; o="${o//'\n'/$'\n'}"
printf '%s' "$o"
EOF
    cat > "$S/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> "$NCZ_SSPLUGIN_ROOT/apt.log"
deb="${@: -1}"
case " $* " in *" -s "*) [ "${SIM_REMOVE:-0}" = 1 ] && echo "Remv something"; echo "Inst ncz-screensavers-plugin"; exit 0 ;; esac
dpkg-deb -x "$deb" "$NCZ_SSPLUGIN_ROOT" || exit 1
printf 'Package: ncz-screensavers-plugin\nStatus: install ok installed\nVersion: %s\n\n' "$(dpkg-deb -f "$deb" Version)" >> "$NCZ_SSPLUGIN_ROOT/status"
if [ "${NO_OVERRIDE:-0}" != 1 ]; then
    mkdir -p "$NCZ_SSPLUGIN_ROOT/opt/singularity/share/glib-2.0/schemas"
    printf "[dev.sinty.desktop]\nenabled-plugins=['sensors', 'screensaver']\n" > "$NCZ_SSPLUGIN_ROOT/opt/singularity/share/glib-2.0/schemas/99-zz-ncz-screensaver-plugin.gschema.override"
fi
EOF
    chmod +x "$S/dpkg-query" "$S/apt-get"
    # mkroot DIR PAYLOADVER LIBBYTES [deb-placement: cdrom|union|none|tampered]
    mkroot() {
        local r="$1" pv="$2" lb="$3" where="${4:-cdrom}" dd
        mkdir -p "$r/opt/singularity/lib" "$r/opt/singularity/bin"
        printf 'Plugins without a category Screensaver and Lock\n' > "$r/opt/singularity/bin/singularity-desktop"
        printf 'Package: ncz-singularity-desktop\nStatus: install ok installed\nVersion: %s\n\n' "$pv" > "$r/status"
        printf '%s' "$lb" > "$r/opt/singularity/lib/libsingularity.so.0.1.0"
        ln -sf libsingularity.so.0.1.0 "$r/opt/singularity/lib/libsingularity.so.0"
        case "$where" in
            cdrom) dd="$r/cdrom/ncz-payload/assets/ncz-screensavers-plugin" ;;
            union|tampered) dd="$r/usr/local/lib/cix-installer/assets/ncz-screensavers-plugin" ;;
            none) return 0 ;;
        esac
        mkdir -p "$dd"; cp "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_arm64.deb" "$dd/"
        [ "$where" = tampered ] && echo x >> "$dd/ncz-screensavers-plugin_0.3.16_arm64.deb"
        return 0
    }
    inst() { PATH="$S:$PATH" NCZ_SSPLUGIN_ROOT="$1" NCZ_SSPLUGIN_LOCK="${LOCKOVR:-$FL}" bash -c ". '$LIB'; ncz_ssplugin_install arm64"; }
    R="$T/r1"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B cdrom
    expect "install: the pinned deb over its own payload installs and asserts" 0 "OK: ncz-screensavers-plugin 0.3.16 installed" inst "$R"
    expect "install: a re-run only re-asserts" 0 "already installed" inst "$R"
    R="$T/r2"; mkroot "$R" 20261009+bk0+tgzeeeeeeee LIB-B union
    expect "install: a rebuilt payload with identical libsingularity installs (union-synced copy)" 0 "ABI ok (lib-identical)" inst "$R"
    R="$T/r9"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B cdrom; printf 'Plugins without a category\n' > "$R/opt/singularity/bin/singularity-desktop"
    expect "install: the lock category over a shell without the row is refused" 1 "no Screensaver and Lock row" inst "$R"
    R="$T/r3"; mkroot "$R" 20261009+bk0+tgzeeeeeeee LIB-OTHER cdrom
    expect "install: an ABI mismatch refuses the plugin" 1 "ABI MISMATCH" inst "$R"
    [ ! -e "$R/apt.log" ] && ok "install: apt never ran on an ABI mismatch" || bad "install: apt ran despite the ABI mismatch"
    R="$T/r4"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B tampered
    expect "install: a medium deb that does not match the pin is refused" 1 "does not match the pinned sha256" inst "$R"
    R="$T/r5"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B none
    expect "install: no deb on the medium is a FATAL, not a silent skip" 1 "FATAL: no ncz-screensavers-plugin_0.3.16_arm64.deb" inst "$R"
    R="$T/r6"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B cdrom
    expect "install: a simulated removal is refused" 1 "would REMOVE" env SIM_REMOVE=1 bash -c "$(declare -f inst); S='$S'; LIB='$LIB'; FL='$FL'; inst '$R'"
    R="$T/r7"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B cdrom
    expect "install: no default-enabled override after install fails" 1 "new users would not see the plugin" env NO_OVERRIDE=1 bash -c "$(declare -f inst); S='$S'; LIB='$LIB'; FL='$FL'; inst '$R'"
    R="$T/r8"; mkroot "$R" 20261006+bk0+tgzbbbbbbbb LIB-B cdrom
    expect "install: a missing pin file is a FATAL" 1 "pin file" env LOCKOVR="$T/nope" bash -c "$(declare -f inst); S='$S'; LIB='$LIB'; FL='$FL'; inst '$R'"
fi

# --- 5. hook 59 + baked allowlist + inventory ----------------------------------------------
H59="$ROOT/post-install/59-ncz-screensavers-pkg.sh"
[ "$(grep -c '^[[:space:]]*ncz_ssplugin_install; exit \$?$' "$H59" 2>/dev/null)" = 2 ] && ok "hook 59: the plugin step runs on both exit paths" || bad "hook 59: plugin step not on both exit paths"
grep -q 'MACHINE_HOOKS_RE=.*|59-ncz-screensavers-pkg|' "$ROOT/post-install/run-all.sh" && ok "run-all: 59-ncz-screensavers-pkg is in the baked-mode allowlist" || bad "run-all: 59 missing from MACHINE_HOOKS_RE (silently skipped on baked installs)"
for plat in amd64 sky1-arm64; do
    grep -qx '59-ncz-screensavers-pkg.sh' "$ROOT/post-install/hooks.list.$plat" 2>/dev/null && ok "hooks.list.$plat runs hook 59" || bad "hooks.list.$plat lacks hook 59"
done
for f in post-install/lib/ncz-screensavers-plugin.lock post-install/lib/ncz-ssplugin-install.sh build/stage-screensaver-plugin.sh build/check-ssplugin-abi.sh build/test-ssplugin-supply-chain.sh; do
    grep -q "^$f	" "$ROOT/docs/platform-inventory.tsv" && ok "inventory lists $f" || bad "inventory lacks $f"
done
grep -q 'check-ssplugin-abi.sh --arch $(ARCH)' "$ROOT/Makefile" && ok "make image runs the stage-2 plugin gate" || bad "make image does not run build/check-ssplugin-abi.sh"

# --- 6. the medium (write-usb-image.py) -----------------------------------------------------
WUI="$ROOT/build/iso/write-usb-image.py"
if grep -q 'def stage_ssplugin_deb' "$WUI" 2>/dev/null; then
    cat > "$T/wui.py" <<EOF
import importlib.util, sys, shutil
from pathlib import Path
spec = importlib.util.spec_from_file_location("wui", "$WUI"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
case, lock, staged, out = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
try:
    r = m.stage_ssplugin_deb(out, "amd64", lock=lock, staged_dir=staged)
except RuntimeError as e:
    print(e); sys.exit(1)
print("staged", r); sys.exit(0 if r is None or (out / "ncz-screensavers-plugin" / r).is_file() else 1)
EOF
    W="$T/wui"; mkdir -p "$W/staged" "$W/assets"
    cp "$A/ncz-screensavers-debs/plugin-test/ncz-screensavers-plugin_0.3.16_amd64.deb" "$W/staged/"
    expect "medium: the pinned deb is copied to ncz-payload/assets/ncz-screensavers-plugin" 0 "staged ncz-screensavers-plugin_0.3.16_amd64.deb" python3 "$T/wui.py" ok "$FL" "$W/staged" "$W/assets"
    echo x >> "$W/staged/ncz-screensavers-plugin_0.3.16_amd64.deb"
    expect "medium: a staged deb that does not match the pin stops the image" 1 "!= pinned" python3 "$T/wui.py" bad "$FL" "$W/staged" "$W/assets"
    rm -f "$W/staged/"*
    expect "medium: a missing staged deb stops the image" 1 "stage-screensaver-plugin.sh amd64" python3 "$T/wui.py" missing "$FL" "$W/staged" "$W/assets"
    expect "medium: a tree without a pin stages nothing" 0 "staged None" python3 "$T/wui.py" nopin "$T/no-such-lock" "$W/staged" "$W/assets"
else
    FAILS=$((FAILS + 1)); echo "FAIL medium: write-usb-image.py does not stage the plugin"
fi

# --- 7. registry -------------------------------------------------------------------------------
if q="$(python3 "$ROOT/build/components.py" --root "$ROOT" query --name ncz-screensavers-plugin --kind staged-deb --field required 2>/dev/null)" && [ "$q" = yes ]; then
    ok "registry: ncz-screensavers-plugin is a required staged-deb row"
else bad "registry: no required staged-deb row for ncz-screensavers-plugin"; fi
grep -q 'KNOWN_UNPUBLISHED_SEEDS' "$ROOT/build/gen-components-registry.py" && bad "registry: the generator still treats the plugin as an unpublished seed" || ok "registry: the plugin is no longer an unpublished-seed exception"
if python3 "$ROOT/build/gen-components-registry.py" --root "$ROOT" --out "$T/gen.tsv" >/dev/null 2>&1; then
    grep -qP '^ncz-screensavers-plugin\t' "$T/gen.tsv" && \
    diff <(grep -P '^ncz-screensavers-plugin\t' "$T/gen.tsv") <(grep -P '^ncz-screensavers-plugin\t' "$ROOT/manifests/components.tsv") >/dev/null \
        && ok "registry: the committed plugin row is what the generator derives from the pin" || bad "registry: committed plugin row drifted from the pin"
else bad "registry: generator failed"; fi

echo "ssplugin supply-chain tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
