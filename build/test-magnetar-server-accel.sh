#!/bin/bash
# test-magnetar-server-accel.sh -- SCOPE-002: the Magnetar server variant
# (NCZ_VARIANT=server / BUILD_VARIANT=server) treats a missing or omitting
# COMPONENTS record as an opt-in for every accelerator whose hardware is
# actually present, while the desktop variant keeps its pre-SCOPE-002
# behaviour byte-for-byte.
#
# The dangerous half of this change is the desktop half. Before SCOPE-002,
# ncz_cuda_component_wanted returned 1 as soon as a COMPONENTS record existed
# and did not list `cuda`; only a total absence of any record fell through to
# install. An earlier attempt inverted that for desktop by ending with
# `[ "$variant" = server ] || return 0`, so a desktop with no record started
# opting in where the shipped code returned 1. This suite pins the exact
# truth table for both variants, including the three record sources and the
# COMPONENTS_cuda per-component bit.
#
# It runs the REAL function bodies out of post-install/54-gpu-accel.sh, with
# only the absolute paths redirected into a sandbox, so a drift between this
# test and the shipped hook shows up as a failure.
#
# Run: bash build/test-magnetar-server-accel.sh   Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
HOOK="$ROOT/post-install/54-gpu-accel.sh"
REFIND="$ROOT/assets/refind/ncz-refind-refresh.sh"
# Run from the repo's own scratch area, never /tmp or tmpfs: the installer
# record paths get rewritten into this tree and a tmpfs would not exercise
# the same mount semantics.
: "${NCZ_TEST_TMPDIR:=$ROOT/.test-tmp}"
mkdir -p "$NCZ_TEST_TMPDIR"
W="$(mktemp -d "$NCZ_TEST_TMPDIR/magnetar-accel.XXXXXX")"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }

[ -r "$HOOK" ]   || { echo "FATAL: $HOOK missing" >&2; exit 2; }
[ -r "$REFIND" ] || { echo "FATAL: $REFIND missing" >&2; exit 2; }

# ---------------------------------------------------------------- extractors ------------------------------------------
# Copy the function verbatim (its closing line is a lone "}" in column 1).
extract() { awk -v s="$2" 'f==0 && $0 ~ s {f=1} f==1 {print; if ($0 ~ /^}$/) exit}' "$1"; }
# Redirect the hook's absolute record paths into the per-case sandbox.
redirect() {
    sed -e "s#/usr/local/lib/cix-installer/#$TGT/usr/local/lib/cix-installer/#g" \
        -e "s#/etc/cix-installer/#$TGT/etc/cix-installer/#g" \
        -e "s#/var/lib/cix-components/#$TGT/var/lib/cix-components/#g" "$1"
}

# ---------------------------------------------------------------- sandbox ---------------------------------------------
# newcase <variant> [COMPONENTS] [COMPONENTS_cuda]
#   variant "desktop"/"server" selects the BUILD_VARIANT record path (the
#   environment variable NCZ_VARIANT is left unset so the record is what is
#   exercised, exactly as on a real install where the hook is run by
#   run-all.sh with no inherited variant).
#   $2 = NOREC means "no COMPONENTS record at all". An empty string means a
#   record that exists and names nothing -- a different input, see below.
NOREC=$'\001'
newcase() {
    TGT="$W/tgt.$$.$RANDOM"; rm -rf "$TGT"; mkdir -p "$TGT/usr/local/lib/cix-installer"
    printf '%s\n' "$1" > "$TGT/usr/local/lib/cix-installer/BUILD_VARIANT"
    # $2 absent or NOREC -> no COMPONENTS record at all
    # $2 is the empty str -> a COMPONENTS record that exists but names nothing
    # $2 has content      -> a record that names components
    # The first two are NOT the same input to ncz_cuda_component_wanted (a
    # record declines; its absence falls through), so the caller says which
    # one it means -- ${2:-x} would erase the difference.
    if [ "$#" -ge 2 ] && [ "$2" != "$NOREC" ]; then
        printf '%s' "$2" > "$TGT/usr/local/lib/cix-installer/COMPONENTS"
    fi
    if [ "$#" -ge 3 ]; then printf '%s\n' "$3" > "$TGT/usr/local/lib/cix-installer/COMPONENTS_cuda"; fi
    { extract "$HOOK" '^ncz_variant[(][)] [{]'
      extract "$HOOK" '^ncz_cuda_component_wanted[(][)] [{]'
      echo 'ncz_cuda_component_wanted && echo yes || echo no'; } | redirect /dev/stdin > "$W/case.sh"
    env -u NCZ_VARIANT bash "$W/case.sh" 2>/dev/null | tail -1
}

echo "=== 1. the extracted function bodies are the shipped ones ==="
extract "$HOOK" '^ncz_variant[(][)] [{]' | grep -q 'BUILD_VARIANT' \
    && ok "ncz_variant: resolves the BUILD_VARIANT record" || bad "ncz_variant does not read BUILD_VARIANT"
extract "$HOOK" '^ncz_cuda_component_wanted[(][)] [{]' | grep -q 'ncz_variant' \
    && ok "ncz_cuda_component_wanted: asks ncz_variant for the variant" || bad "variant resolution missing"

echo "=== 2. desktop keeps the pre-SCOPE-002 behaviour byte-for-byte ==="
# Truth table of the shipped pre-SCOPE-002 function.
check "desktop, no COMPONENTS record, no bit -> install (legacy fall-through)" \
    "$(newcase desktop)" yes
check "desktop, record omits cuda -> NOT installed" \
    "$(newcase desktop 'mgmt-container,rescue-partition')" no
check "desktop, record lists cuda -> installed" \
    "$(newcase desktop 'cuda,desktop')" yes
check "desktop, empty COMPONENTS file -> NOT installed" \
    "$(newcase desktop '')" no
check "desktop, COMPONENTS_cuda=0 -> NOT installed" \
    "$(newcase desktop "$NOREC" 0)" no
check "desktop, COMPONENTS_cuda=1 -> installed" \
    "$(newcase desktop "$NOREC" 1)" yes
# An *existing* record that names nothing is still a record: it declines, and
# the per-component bit is never consulted. Pinned because it is the one case
# that looks like "no record" but is not.
check "desktop, empty record + COMPONENTS_cuda=1 -> still declined (record wins)" \
    "$(newcase desktop "" 1)" no
# The regression this suite exists for: a bare desktop box must not start
# pulling a CUDA stack because SCOPE-002 touched the function.
newcase desktop 'mgmt-container' >/dev/null
d_out=$(env -u NCZ_VARIANT bash "$W/case.sh" 2>&1)
case "$d_out" in
    *"BUILD_VARIANT=server"*) bad "desktop printed the server opt-in message" "$d_out" ;;
    no) ok "desktop never emits the server opt-in message" ;;
    *) bad "desktop case printed unexpected output" "$d_out" ;;
esac

echo "=== 3. server optimises in on omitted records, hardware permitting ==="
check "server + record omitting cuda -> installed (the SCOPE-002 fix)" \
    "$(newcase server 'mgmt-container,rescue-partition')" yes
check "server + no record at all -> installed" \
    "$(newcase server)" yes
check "server + record listing cuda -> installed" \
    "$(newcase server 'cuda,mgmt-container')" yes
check "server + explicit COMPONENTS_cuda=0 -> declined" \
    "$(newcase server 'mgmt-container' 0)" no

echo "=== 4. server: an accelerator is only installed where the hardware is ==="
# Every vendor block in 54-gpu-accel.sh is gated on its own detected PCI
# device, so the server opt-in above only reaches hardware that exists. Pin
# the NVIDIA gate: a box whose sysfs shows no NVIDIA display controller must
# not reach the CUDA installer even on server.
nv_calls=$(grep -n '^[[:space:]]*ncz_nvidia_dynamic_setup[[:space:]]*$' "$HOOK" | cut -d: -f1)
nv_ok=1
[ -n "$nv_calls" ] || nv_ok=0
for n in $nv_calls; do
    sed -n "$((n - 1))p" "$HOOK" | grep -qx 'if \[ "\$HAS_NVIDIA" = 1 \]; then' || nv_ok=0
done
[ "$nv_ok" = 1 ] && ok "CUDA setup is gated on detected NVIDIA hardware" \
    || bad "ncz_nvidia_dynamic_setup is called outside the HAS_NVIDIA gate"
grep -q 'no NVIDIA/AMD/Intel display controller detected' "$HOOK" \
    && ok "server + no accelerator: the hook is a silent no-op" || bad "no-accelerator early-out missing"
# The server branch must not install anything before the hardware gate: it
# may only change the *record* interpretation. Every echo in it must be the
# one explanatory message; anything else would be an action taken on a record
# alone, i.e. before we know the box has an NVIDIA GPU.
server_echoes=$(extract "$HOOK" '^ncz_cuda_component_wanted[(][)] [{]' | awk '/ncz_variant/ && /server/{f=1} f && /^    fi$/{exit} f && /^[[:space:]]*echo /' | grep -vc 'installing it for the detected NVIDIA GPU')
[ "$server_echoes" = 0 ] && ok "the NVIDIA server branch only reinterprets the record" \
    || bad "server branch performs $server_echoes action(s) beyond record interpretation"

echo "=== 5. variant resolution is not global state ==="
grep -qE '^[[:space:]]*(export|NCZ_VARIANT=.*;export)[[:space:]]*NCZ_VARIANT' "$HOOK" \
    && bad "the hook still exports NCZ_VARIANT into the helpers it sources" \
    || ok "no NCZ_VARIANT export (variant stays a plain local/variable read)"
n_def=$(grep -c ':-desktop}' "$HOOK")
n_fn=$(extract "$HOOK" '^ncz_variant[(][)] [{]' | grep -c ':-desktop}')
[ "$n_def" = 1 ] && [ "$n_fn" = 1 ] && ok "VARIANT defaulted exactly once (in ncz_variant)" \
    || bad "the desktop default appears $n_def time(s) in the hook, $n_fn in ncz_variant"
# An explicit environment variant still wins, for callers that resolved it.
mkdir -p "$W/tgt.env/usr/local/lib/cix-installer"
printf '%s\n' desktop > "$W/tgt.env/usr/local/lib/cix-installer/BUILD_VARIANT"
printf '%s\n' 'mgmt-container' > "$W/tgt.env/usr/local/lib/cix-installer/COMPONENTS"
TGT="$W/tgt.env"
{ extract "$HOOK" '^ncz_variant[(][)] [{]'
  extract "$HOOK" '^ncz_cuda_component_wanted[(][)] [{]'
  echo 'ncz_cuda_component_wanted && echo yes || echo no'; } | redirect /dev/stdin > "$W/envcase.sh"
check "NCZ_VARIANT=server in the environment overrides the desktop record" \
    "$(NCZ_VARIANT=server bash "$W/envcase.sh" 2>/dev/null | tail -1)" yes
check "  ...and with it unset the desktop record still declines" \
    "$(env -u NCZ_VARIANT bash "$W/envcase.sh" 2>/dev/null | tail -1)" no

echo "=== 6. rEFInd: the server menu is Console + Rescue Partition only ==="
# Drive the real menu emission with each variant and count the entries. The
# script does far more than build the menu (preflight, ESP validation, the ESP
# wipe), so extract just the emission block: it opens at the `{` that starts
# the refind.conf body and closes at `} > "$REFIND_CONF"`. REFIND_CONF is
# redirected into the sandbox -- that is the only write the block performs.
MENU_START=$(grep -n '^    echo "timeout \$REFIND_TIMEOUT"$' "$REFIND" | cut -d: -f1)
MENU_END=$(awk -v s="${MENU_START:-0}" 'NR>s && /^} > "\$REFIND_CONF"$/{print NR; exit}' "$REFIND")
# The echo lines above live inside the `{ ... } > "$REFIND_CONF"` group; the
# opening `{` is a bare line a few lines above. Start there or the extracted
# snippet is a syntax error and writes nothing.
MENU_OPEN=$(awk -v m="${MENU_START:-0}" 'NR<m && /^\{$/{o=NR} END{print o}' "$REFIND")
extract_menu() { sed -n "${MENU_OPEN},${MENU_END}p" "$REFIND"; }
[ -n "$MENU_OPEN" ] && [ -n "$MENU_END" ] && ok "located the refind.conf emission block (lines $MENU_OPEN-$MENU_END)" \
    || bad "could not locate the refind.conf emission block"
emit_menu() {   # emit_menu <variant> -> the menuentry titles
    local out="$W/refind.$1.conf"
    NCZ_VARIANT="$1" REFIND_CONF="$out" NEXT_AVAILABLE=1 KVER_NEXT=7.3.0-sky1-ncz NEXT_INITRD_AVAILABLE=1 \
      NCZ_RELEASE_SHORT=NCZ PANTHOR_ENTRY=1 REFIND_ICON= REFIND_BANNER= REFIND_THEME= REFIND_TIMEOUT=5 \
      DEFAULT_TOKEN=next MALI_OPTIONS=x PANTHOR_OPTIONS=y NEXT_CONSOLE_OPTIONS=c \
      NEXT_RESCUE_OPTIONS=r RESCUEPART_OPTIONS=p \
      bash -c "$(extract_menu)" >/dev/null 2>&1
    grep -o 'menuentry "[^"]*"' "$out" 2>/dev/null | sed 's/^menuentry "//;s/"$//'
}
d_menu=$(emit_menu desktop); s_menu=$(emit_menu server)
printf '%s\n' "$d_menu" | grep -q 'Mali' && ok "desktop: Mali entry present" || bad "desktop lost its Mali entry"
printf '%s\n' "$d_menu" | grep -q 'Panthor' && ok "desktop: Panthor entry present" || bad "desktop lost its Panthor entry"
printf '%s\n' "$d_menu" | grep -q 'Console (All Accelerators' && ok "desktop: Console entry present" || bad "desktop lost its Console entry"
printf '%s\n' "$d_menu" | grep -q 'Rescue / No Accelerators' && ok "desktop: Rescue entry present" || bad "desktop lost its Rescue entry"
# Four accelerator/console entries plus the optional Rescue Partition entry
# (that one is the rescue-partition component, offered on both variants).
[ "$(printf '%s\n' "$d_menu" | wc -l)" = 5 ] && ok "desktop: four entries + Rescue Partition, unchanged" \
    || bad "desktop menu changed: $(printf '%s\n' "$d_menu" | wc -l) entries"
[ "$(printf '%s\n' "$s_menu" | wc -l)" = 2 ] && ok "server: exactly two entries" \
    || bad "server menu has $(printf '%s\n' "$s_menu" | wc -l) entries: $s_menu"
printf '%s\n' "$s_menu" | grep -q 'Console (All Accelerators' && ok "server: Console entry present" || bad "server: Console entry missing"
printf '%s\n' "$s_menu" | grep -q 'Rescue Partition' && ok "server: Rescue Partition entry present" || bad "server: Rescue Partition entry missing"
# Case-SENSITIVE and anchored on the entry names: "Console (All Accelerators,
# Mali)" legitimately contains the word Mali, so a case-insensitive match on
# 'mali' would flag the Console entry as a leak.
printf '%s\n' "$s_menu" | grep -qE '7\.3 (Mali|Panthor|Rescue / No Accelerators)' \
    && bad "server: a desktop-only entry leaked into the server menu" \
    || ok "server: no Mali/Panthor/desktop-Rescue entries"
# ...and the same emission with no rescue partition selected still yields
# Console only, so the second entry really is the optional rescue component.
s_np=$(NCZ_VARIANT=server REFIND_CONF="$W/refind.np.conf" NEXT_AVAILABLE=1 KVER_NEXT=7.3.0-sky1-ncz \
       NEXT_INITRD_AVAILABLE=1 NCZ_RELEASE_SHORT=NCZ PANTHOR_ENTRY=1 REFIND_ICON= REFIND_BANNER= \
       REFIND_THEME= REFIND_TIMEOUT=5 DEFAULT_TOKEN=next MALI_OPTIONS=x PANTHOR_OPTIONS=y \
       NEXT_CONSOLE_OPTIONS=c NEXT_RESCUE_OPTIONS=r RESCUEPART_OPTIONS= \
       bash -c "$(extract_menu)" >/dev/null 2>&1; grep -c '^menuentry ' "$W/refind.np.conf")
[ "$s_np" = 1 ] && ok "server, no rescue partition selected: Console entry only" \
    || bad "server with no rescue partition wrote $s_np entries"
unset -f emit_menu
# The gating must be by variant, not by accident of the entry order.
grep -q 'NCZ_VARIANT:-desktop' "$REFIND" && ok "rEFInd gates on the variant record" \
    || bad "rEFInd no longer gates the desktop entries on the variant"


echo "=== 7. server reaches every vendor block its detected hardware has ==="
# The variant gate itself, run for real: server must fall through to the
# vendor blocks, headless must still exit before them.
gate_run() {   # gate_run <variant> -> fallthrough|exited
    TGT="$W/gate.$1"; rm -rf "$TGT"; mkdir -p "$TGT/usr/local/lib/cix-installer"
    printf '%s\n' "$1" > "$TGT/usr/local/lib/cix-installer/BUILD_VARIANT"
    { echo 'ncz_cuda_status() { :; }'
      extract "$HOOK" '^ncz_variant[(][)] [{]' '^[}]$'
      awk '/^VARIANT=\$\(ncz_variant\)$/{f=1} f{print} f && /^esac$/{exit}' "$HOOK"
      echo 'echo fallthrough'; } | redirect /dev/stdin > "$W/gate.$1.sh"
    grep -q '^case "$VARIANT" in' "$W/gate.$1.sh" || { echo missing-gate; return; }
    ( unset NCZ_VARIANT; bash "$W/gate.$1.sh" 2>/dev/null ) | tail -1 | grep -qx fallthrough && echo fallthrough || echo exited
}
check "server falls through to the vendor blocks" "$(gate_run server)" fallthrough
check "headless still skips accelerator wiring" "$(gate_run headless)" exited
check "desktop falls through as before" "$(gate_run desktop)" fallthrough

# The hook's own PCI detection lines over sysfs fixture trees (vendor/device/
# class files, the shape lib/pci-sysfs.sh reads).
pci_dev() {    # pci_dev <root> <bdf> <class> <vendor> <device>
    mkdir -p "$1/$2"; echo "0x$3" > "$1/$2/class"; echo "0x$4" > "$1/$2/vendor"; echo "0x$5" > "$1/$2/device"
}
detect() {     # detect <root> -> "NVIDIA AMD INTEL INTEL_NPU"
    { cat "$ROOT/post-install/lib/pci-sysfs.sh"
      grep -E '^(ALL_PCI=|DISPLAY_PCI=|HAS_NVIDIA=0|NPU_PCI=|HAS_INTEL_NPU=0)|^echo "\$(DISPLAY|NPU)_PCI" \| grep' "$HOOK"
      echo 'echo "$HAS_NVIDIA $HAS_AMD $HAS_INTEL $HAS_INTEL_NPU"'; } > "$W/detect.sh"
    NCZ_PCI_DEVICES_ROOT="$1" bash "$W/detect.sh" 2>/dev/null
}
P="$W/pci"
pci_dev "$P/amd" 0000:03:00.0 030000 1002 73bf
pci_dev "$P/amd" 0000:00:00.0 060000 1022 14d8
pci_dev "$P/arl" 0000:00:02.0 030000 8086 7d67
pci_dev "$P/arl" 0000:00:0b.0 120000 8086 ad1d
pci_dev "$P/nv"  0000:01:00.0 030000 10de 2684
pci_dev "$P/none" 0000:00:00.0 060000 1022 14d8
check "server + AMD GPU: ROCm block selected" "$(detect "$P/amd")" "0 1 0 0"
check "server + Intel Arrow Lake GPU + NPU: Intel/OpenVINO block selected" "$(detect "$P/arl")" "0 0 1 1"
check "server + NVIDIA GPU: CUDA block selected" "$(detect "$P/nv")" "1 0 0 0"
check "server + no accelerator: nothing selected" "$(detect "$P/none")" "0 0 0 0"
# The AMD and Intel blocks consult neither the variant nor the COMPONENTS
# record, so detection alone decides on server too.
for blk in '^if \[ "\$HAS_AMD" = 1 \]; then$' '^if \[ "\$HAS_INTEL" = 1 \] \|\| \[ "\$HAS_INTEL_NPU" = 1 \]; then$'; do
    body=$(awk -v s="$blk" '$0 ~ s {f=1} f {print} f && /^fi$/ {exit}' "$HOOK")
    if [ -z "$body" ]; then bad "vendor block not found: $blk"
    elif printf '%s\n' "$body" | grep -qE 'VARIANT|COMPONENTS'; then bad "vendor block is variant/record gated: $blk"
    else ok "vendor block is hardware-gated only: $(printf '%s\n' "$body" | head -1)"; fi
done
# CIX Sky1: the NPU and Mali hooks are arch-gated only; nothing in them
# skips a server install.
for h in 80-npu.sh 82-mali-gpu.sh; do
    if grep -qE 'BUILD_VARIANT|headless|NCZ_VARIANT' "$ROOT/post-install/$h"; then
        bad "post-install/$h gates on the variant (server would lose the Sky1 accelerator)"
    else
        ok "server + CIX Sky1: post-install/$h runs (arch-gated, not variant-gated)"
    fi
done

echo "magnetar server accelerator tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
