#!/bin/bash
# test-lite-profile.sh -- offline regression test for the NCZ-OS lite profile.
#
#   * the auto-select rule table, driven with fake renderer strings and PCI ids
#     (the mission's required table: UHD 630 / Mali / Radeon / RTX / Iris Xe /
#     Apple / Arc stay DEFAULT; llvmpipe, HD 3000, HD 4000, Haswell go LITE);
#   * apply / restore / idempotence against a fake gsettings + fake HOME, so
#     nothing on the running machine is touched;
#   * the first-login auto-apply semantics (decide once, never re-apply after a
#     user change; a strong GPU is left alone);
#   * the install hook (66-ncz-lite-profile.sh): arch gate, installed files, the
#     dev.ncz.profile schema compiles --strict, the unit is enabled, and the
#     hook is reachable (hooks.list.amd64 + run-all.sh MACHINE_HOOKS_RE).
#
# Run: bash build/test-lite-profile.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROF="$ROOT/assets/lite/ncz-profile"
HOOK="$ROOT/post-install/66-ncz-lite-profile.sh"
SCHEMA="$ROOT/assets/lite/dev.ncz.profile.gschema.xml"

export G_MESSAGES_DEBUG=
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# ---------------------------------------------------------------------------
# 1. the rule table (pure; no gsettings involved)
# ---------------------------------------------------------------------------
cls() { "$PROF" class "$@" 2>/dev/null | cut -f1; }
expect() {  # expect CLASS desc args...
    local want="$1" desc="$2"; shift 2
    local got; got=$(cls "$@")
    if [ "$got" = "$want" ]; then ok "class: $desc -> $want"; else bad "class: $desc -> $got (want $want)"; fi
}

expect lite    "Ivy Bridge HD 4000 (IVB)"       --renderer "Mesa Intel(R) HD Graphics 4000 (IVB GT2)"
expect lite    "Sandy Bridge HD 3000 (SNB)"     --renderer "Mesa Intel(R) HD Graphics 3000 (SNB GT2)"
expect lite    "Haswell HD 4600 (HSW)"          --renderer "Mesa Intel(R) HD Graphics 4600 (HSW GT2)"
expect lite    "llvmpipe software GL"           --renderer "llvmpipe (LLVM 21.1.8, 256 bits)"
expect lite    "softpipe software GL"           --renderer "softpipe"
expect lite    "software flag with no renderer"  --software
expect lite    "HD Graphics 4000 marketing name" --renderer "Intel(R) HD Graphics 4000"
expect default "UHD 630 stays default"          --renderer "Mesa Intel(R) UHD Graphics 630 (CFL GT2)"
expect default "Iris Xe stays default"          --renderer "Mesa Intel(R) Iris(R) Xe Graphics (TGL GT2)"
expect default "Mali-G720 stays default"        --renderer "Mali-G720-Immortalis"
expect default "Radeon 5500M stays default"     --renderer "AMD Radeon Pro 5500M (navi14, LLVM 21.1.8)"
expect default "RTX 2060 stays default"         --renderer "NVIDIA GeForce RTX 2060/PCIe/SSE2"
expect default "Intel Arc stays default"        --renderer "Intel(R) Arc(TM) A750 Graphics (DG2)"
expect default "Apple M2 stays default"         --renderer "Apple M2 (G14E, 8 cores)"
# PCI fallback (no renderer string available)
expect lite    "Intel 8086:0166 (Ivy) by PCI"   --pci "8086:0166"
expect lite    "Intel 8086:0126 (Sandy) by PCI" --pci "8086:0126"
expect default "Intel 8086:9a49 (Tiger Lake)"   --pci "8086:9a49"
expect default "Radeon 1002:7340 by PCI"        --pci "1002:7340"
# VRAM never promotes to lite on its own
expect default "2 GB VRAM + strong renderer"    --renderer "NVIDIA GeForce GTX 1650 Ti" --vram-mb 2048

# ---------------------------------------------------------------------------
# 2. fake gsettings + fake HOME: apply / restore / idempotence
# ---------------------------------------------------------------------------
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/gsettings" <<'SHIM'
#!/bin/sh
SD=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KEYS="$SD/keys"; STORE="$SD/store"
cmd="$1"; shift
case "$cmd" in
  list-keys)
    while IFS=' ' read -r s k d; do [ "$s" = "$1" ] && echo "$k"; done < "$KEYS"
    exit 0 ;;
  get)
    s="$1"; k="$2"; v=""
    [ -f "$STORE" ] && v=$(awk -F'\t' -v s="$s" -v k="$k" '$1==s&&$2==k{print $3}' "$STORE" | tail -1)
    [ -n "$v" ] || v=$(awk -v s="$s" -v k="$k" '$1==s&&$2==k{print $3}' "$KEYS" | tail -1)
    echo "$v" ;;
  set)
    s="$1"; k="$2"; v="$3"; touch "$STORE"
    awk -F'\t' -v s="$s" -v k="$k" '!($1==s&&$2==k)' "$STORE" > "$STORE.t" 2>/dev/null
    mv "$STORE.t" "$STORE" 2>/dev/null || true
    printf '%s\t%s\t%s\n' "$s" "$k" "$v" >> "$STORE" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$BIN/gsettings"
cat > "$BIN/keys" <<'KEYS'
dev.sinty.desktop background-effect 'disabled'
dev.sinty.desktop blur-strength 60
dev.sinty.desktop window-transparency 12
dev.sinty.desktop reduce-motion false
dev.sinty.desktop motion-duration-scale 1.0
dev.sinty.desktop window-rounded-corners true
dev.sinty.desktop idle-dim-screen true
dev.sinty.desktop allow-tearing false
dev.sinty.desktop rendering-mode 'auto'
dev.ncz.screensaver pool-gpu-class 'auto'
dev.ncz.screensaver render-scale-mode 'auto'
dev.ncz.screensaver render-scale 1.0
dev.ncz.screensaver max-render-height 0
dev.ncz.screensaver gpu-offload 'auto'
dev.ncz.profile profile 'auto'
dev.ncz.profile lite-applied false
KEYS

export HOME="$T/home"; mkdir -p "$HOME/.config/labwc"
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME/.local/state"
# a stock rc.xml + themerc-override, as the shell writes them
cat > "$HOME/.config/labwc/rc.xml" <<'XML'
<?xml version="1.0"?>
<labwc_config>
  <theme><cornerRadius>12</cornerRadius></theme>
  <core><windowAnimations>yes</windowAnimations><allowTearing>no</allowTearing></core>
  <animations><durationScale>1.00</durationScale></animations>
</labwc_config>
XML
printf 'window.active.shadow.size: 40\nwindow.inactive.shadow.size: 28\n' > "$HOME/.config/labwc/themerc-override"
export PATH="$BIN:$PATH"
export NCZ_LITE_ARCH=amd64
export NCZ_LITE_RENDERER="Mesa Intel(R) HD Graphics 4000 (IVB GT2)"
unset NCZ_LITE_SOFTWARE NCZ_LITE_PCI

gv() { awk -F'\t' -v s="$1" -v k="$2" '$1==s&&$2==k{print $3}' "$BIN/store" | tail -1; }

"$PROF" lite >/dev/null 2>&1
[ "$(gv dev.ncz.profile profile)" = "'lite'" ] && ok "apply: profile=lite" || bad "apply: profile not lite"
[ "$(gv dev.sinty.desktop reduce-motion)" = "true" ] && ok "apply: reduce-motion=true" || bad "apply: reduce-motion not set"
[ "$(gv dev.ncz.screensaver render-scale)" = "0.5" ] && ok "apply: screensaver render-scale=0.5" || bad "apply: render-scale not set"
grep -q "<cornerRadius>0</cornerRadius>" "$HOME/.config/labwc/rc.xml" && ok "apply: rc.xml cornerRadius=0" || bad "apply: rc.xml cornerRadius not set"
grep -q "windowAnimations>no<" "$HOME/.config/labwc/rc.xml" && ok "apply: rc.xml windowAnimations=no" || bad "apply: rc.xml windowAnimations not set"
grep -q "shadow.size: 0" "$HOME/.config/labwc/themerc-override" && ok "apply: themerc shadow=0" || bad "apply: themerc shadow not set"
[ -f "$HOME/.config/labwc/rc.xml.ncz-lite-orig" ] && ok "apply: rc.xml backed up" || bad "apply: no rc.xml backup"
# hardware Intel keeps hardware rendering (no software regression)
if [ "$(gv dev.sinty.desktop rendering-mode)" != "'software'" ]; then ok "apply: rendering-mode not forced to software on hardware GL"; else bad "apply: rendering-mode forced to software on hardware GL"; fi

# idempotence: a second lite must not corrupt the recorded stock prior
"$PROF" lite >/dev/null 2>&1
prior_reduce=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["prior"].get("dev.sinty.desktop:reduce-motion"))' "$XDG_STATE_HOME/ncz/lite-profile/applied.json")
[ "$prior_reduce" = "false" ] && ok "idempotent: stock prior (reduce-motion=false) preserved across re-apply" || bad "idempotent: prior corrupted ($prior_reduce)"

"$PROF" default >/dev/null 2>&1
[ "$(gv dev.sinty.desktop reduce-motion)" = "false" ] && ok "restore: reduce-motion back to false" || bad "restore: reduce-motion not restored"
[ "$(gv dev.ncz.screensaver render-scale)" = "1.0" ] && ok "restore: render-scale back to 1.0" || bad "restore: render-scale not restored"
grep -q "<cornerRadius>12</cornerRadius>" "$HOME/.config/labwc/rc.xml" && ok "restore: rc.xml cornerRadius=12" || bad "restore: rc.xml not restored"
[ "$(gv dev.ncz.profile profile)" = "'default'" ] && ok "restore: profile=default" || bad "restore: profile not default"

# ---------------------------------------------------------------------------
# 3. first-login auto-apply semantics
# ---------------------------------------------------------------------------
"$PROF" auto >/dev/null 2>&1
"$PROF" auto-apply >/dev/null 2>&1     # weak renderer -> lite
[ "$(gv dev.ncz.profile lite-applied)" = "true" ] && ok "auto-apply: decided once (lite-applied=true)" || bad "auto-apply: decision not recorded"
[ "$(gv dev.sinty.desktop reduce-motion)" = "true" ] && ok "auto-apply: weak GPU got lite" || bad "auto-apply: weak GPU did not get lite"
# the user overrides a setting; the selector must never run again
"$BIN/gsettings" set dev.sinty.desktop reduce-motion false
"$PROF" auto-apply >/dev/null 2>&1
[ "$(gv dev.sinty.desktop reduce-motion)" = "false" ] && ok "auto-apply: user change is never overwritten" || bad "auto-apply: user change was overwritten"
# re-arm from stock, strong renderer -> stock is kept, and the decision is
# still recorded once
"$PROF" default >/dev/null 2>&1
"$PROF" auto >/dev/null 2>&1
NCZ_LITE_RENDERER="Mesa Intel(R) UHD Graphics 630 (CFL GT2)" "$PROF" auto-apply >/dev/null 2>&1
[ "$(gv dev.ncz.profile lite-applied)" = "true" ] && ok "auto-apply: default class also decides once" || bad "auto-apply: default class did not record"
[ "$(gv dev.sinty.desktop window-rounded-corners)" = "true" ] && ok "auto-apply: default-class GPU left untouched" || bad "auto-apply: default-class GPU was changed"

# ---------------------------------------------------------------------------
# 4. the install hook + verifier
# ---------------------------------------------------------------------------
if grep -q "NCZ-PLATFORM-GUARD" "$HOOK"; then ok "hook: carries the amd64 platform guard"; else bad "hook: missing NCZ-PLATFORM-GUARD"; fi
grep -q "66-ncz-lite-profile.sh" "$ROOT/post-install/hooks.list.amd64" && ok "hook: listed in hooks.list.amd64" || bad "hook: missing from hooks.list.amd64"
if grep -q "66-ncz-lite-profile" "$ROOT/post-install/hooks.list.sky1-arm64"; then bad "hook: leaked into hooks.list.sky1-arm64"; else ok "hook: absent from hooks.list.sky1-arm64"; fi
grep -q "66-ncz-lite-profile" "$ROOT/post-install/run-all.sh" && ok "hook: in run-all.sh MACHINE_HOOKS_RE" || bad "hook: missing from run-all.sh MACHINE_HOOKS_RE"
# the schema compiles --strict with the fragment override
if command -v glib-compile-schemas >/dev/null 2>&1; then
    mkdir -p "$T/sc"
    cp "$SCHEMA" "$T/sc/"
    if glib-compile-schemas --strict --dry-run "$T/sc" >/dev/null 2>&1; then ok "schema: dev.ncz.profile compiles --strict"; else bad "schema: does not compile --strict"; fi
else
    echo "skip schema compile (glib-compile-schemas absent)"
fi
# arch gate: arm64 target must skip and install nothing
mkdir -p "$T/armroot"
NCZ_TARGET_ARCH=arm64 NCZ_LITE_ROOT="$T/armroot" NCZ_LITE_ASSETS="$ROOT/assets/lite" NCZ_LITE_SCHEMA_DIR="$T/armroot/schemas" NCZ_LITE_SKIP_GLOBAL_ENABLE=1 \
    bash "$HOOK" >/dev/null 2>&1
[ ! -e "$T/armroot/usr/bin/ncz-profile" ] && ok "hook: arm64 target skips" || bad "hook: arm64 target installed files"
# amd64 install into a fake root
mkdir -p "$T/root/usr/share/glib-2.0/schemas" "$T/rootschema"
NCZ_TARGET_ARCH=amd64 NCZ_LITE_ROOT="$T/root" NCZ_LITE_ASSETS="$ROOT/assets/lite" NCZ_LITE_SCHEMA_DIR="$T/root/usr/share/glib-2.0/schemas" NCZ_LITE_SKIP_GLOBAL_ENABLE=1 \
    bash "$HOOK" >/dev/null 2>&1
[ -x "$T/root/usr/bin/ncz-profile" ] && ok "hook: installs /usr/bin/ncz-profile" || bad "hook: ncz-profile not installed"
[ -f "$T/root/usr/share/ncz/lite/rc-lite.fragment.xml" ] && ok "hook: installs the rc.xml fragment" || bad "hook: rc fragment missing"
[ -f "$T/root/usr/share/ncz/lite/themerc-lite.fragment" ] && ok "hook: installs the themerc fragment" || bad "hook: themerc fragment missing"
[ -f "$T/root/usr/lib/systemd/user/ncz-lite-profile.service" ] && ok "hook: installs the first-login user unit" || bad "hook: user unit missing"
[ -f "$T/root/usr/share/glib-2.0/schemas/dev.ncz.profile.gschema.xml" ] && ok "hook: installs the dev.ncz.profile schema" || bad "hook: schema not installed"

echo "lite-profile tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
