#!/bin/bash
# test-sky1-serial-diag.sh -- Sky1 installer serial diagnostics and the ACPI
# PCIe host-mode experiment (sky1_pcie_native=off pcie_pnp_en on the installer
# entries), arm64 only; amd64 must not change.
#
# Provenance (O6N, r199 installer, 7.3.0-rc6-sky1-ncz, 2026-10-06): d-i saw
# only lo, and with console=tty0 on the on-screen entries nothing reached the
# serial capture on PROTEUS, so the failure could not be read remotely. Serial
# console= on those entries is not an option: both orders moved d-i's UI onto
# the UART on real hardware (0871d09f/65c91e3e, 91060aca, root cause 4f262f4c).
# The serial side therefore lives in preseed/diag-console.sh (kmsg mirror,
# getty, no-interface dump), and the NIC controllers' deferred probe
# ("supplier PRP0001:11 not ready") is side-stepped by booting the installer in
# the installed system's ACPI PCIe mode (sky1_pcie_native=off pcie_pnp_en).
#
# Proves:
#   1. every arm64 installer rEFInd entry (Install, expert, Rescue) carries
#      sky1_pcie_native=off and pcie_pnp_en exactly once and no fw_devlink
#      override (proven not to help); the on-screen arm64 entries still
#      name no serial console (console=tty0 only, so reopen-console keeps d-i
#      on the monitor); the Rescue entry keeps console=ttyAMA0,115200;
#   2. the amd64 installer entries are unchanged by this work (apart from the
#      separate nouveau.runpm=0 workaround)
#      and name none of those tokens nor ttyAMA;
#   3. the installed arm64 cmdline (ncz-refind-refresh.sh) keeps
#      console=ttyAMA0,115200 before console=tty0 and the same ACPI PCIe mode
#      tokens the installer now uses; the amd64 refresh script has neither;
#   4. 36-telemetry.sh enables serial-getty@ttyAMA0 only on arm64;
#   5. diag-console.sh's serial block, run in a sandbox: on arm64 it starts a
#      getty on ttyAMA0 and mirrors /dev/kmsg there; it does neither when d-i
#      owns ttyAMA0 (inittab), when ncz_diag_serial=0, or on amd64; it skips
#      only the mirror when ttyAMA0 is already a kernel console; with only lo it
#      writes one no-interface summary (PCI list + dmesg greps) to the serial
#      port and to the log, and none when a NIC exists;
#   6. diag-console.sh runs the serial block before its first DHCP attempt and
#      in both of its loops.
#
# Run: bash build/test-sky1-serial-diag.sh
# Exit 0 = all cases passed; 1 = a case failed; 2 = a source file missing.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
ESP_PY="$REPO/build/iso/build-refind-esp.py"
REFRESH="$REPO/assets/refind/ncz-refind-refresh.sh"
REFRESH_AMD64="$REPO/assets/refind/ncz-refind-refresh-amd64.sh"
TELEMETRY="$REPO/post-install/36-telemetry.sh"
DIAG="$REPO/preseed/diag-console.sh"
for f in "$ESP_PY" "$REFRESH" "$REFRESH_AMD64" "$TELEMETRY" "$DIAG"; do
    [ -r "$f" ] || { echo "FATAL: cannot read $f" >&2; exit 2; }
done

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; }

# ---- 1 + 2: installer rEFInd entries -----------------------------------------
out=$(python3 - "$ESP_PY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("esp", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
fails = []
def check(cond, msg):
    if not cond:
        fails.append(msg)
TOKENS = ("sky1_pcie_native=off", "pcie_pnp_en")
arm = {"install": m.ARM64_INSTALL_OPTIONS, "expert": m.ARM64_EXPERT_OPTIONS,
       "rescue": m.ARM64_RESCUE_OPTIONS}
for name, opts in arm.items():
    toks = opts.split()
    for tok in TOKENS:
        check(toks.count(tok) == 1, f"arm64 {name}: {tok} count {toks.count(tok)} != 1")
    check(not any(t.startswith("sky1_pcie_native=") and t != TOKENS[0] for t in toks),
          f"arm64 {name}: conflicting sky1_pcie_native token")
    check(not any(t.startswith("fw_devlink=") for t in toks),
          f"arm64 {name}: fw_devlink override (does not release explicit device_link_add links)")
for name in ("install", "expert"):
    cons = [t for t in arm[name].split() if t.startswith("console=")]
    check(cons == ["console=tty0"],
          f"arm64 {name}: consoles {cons} -- a UART console= moves d-i off the monitor (4f262f4c)")
    check("earlycon" not in arm[name], f"arm64 {name}: earlycon is unproven on O6N")
check("console=ttyAMA0,115200" in arm["rescue"].split(), "arm64 rescue lost console=ttyAMA0,115200")
# Rendered refind.conf: all three arm64 menu entries carry the token.
conf = m.REFIND_CONF_TEXT_ARM64_TEMPLATE.format(
    info_line="x", install_options=m.ARM64_INSTALL_OPTIONS,
    expert_options=m.ARM64_EXPERT_OPTIONS, rescue_options=m.ARM64_RESCUE_OPTIONS)
opts_lines = [l for l in conf.splitlines() if l.strip().startswith("options ")]
check(len(opts_lines) == 3, f"arm64 refind.conf has {len(opts_lines)} options lines, want 3")
check(all(all(t in l.split() or t + '"' in l.split() for t in TOKENS) for l in opts_lines),
      "arm64 refind.conf: an entry lacks sky1_pcie_native=off pcie_pnp_en")
# amd64: pinned to the EXACT shipped cmdlines. Two workarounds have landed
# since this test's original baseline and are part of the contract now:
#   * nouveau.runpm=0  (fix/nouveau-runpm-hang-20261006) on every entry;
#   * nomodeset        (fix/di-lcd-display-20261010, AMD64_DI_DISPLAY_OPTIONS)
#     on Install/Expert only -- Rescue deliberately keeps full modeset for
#     diagnosis. The old baseline pinned the shared strings and stripped only
#     nouveau.runpm=0, so it had been RED since 5a21d5cb added nomodeset.
# Any drift on any of the three, or any Sky1 token, is still a failure.
AMD64 = {
    "install": "auto=true priority=critical "
               "ipv6.disable=1 interface=auto netcfg/dhcp_timeout=120 locale=en_US.UTF-8 "
               "keyboard-configuration/layoutcode=us DEBIAN_FRONTEND=newt "
               "quiet loglevel=3 vt.global_cursor_default=0 consoleblank=0 console=tty0 "
               "nouveau.runpm=0 nomodeset",
    "expert": "priority=low ipv6.disable=1 interface=auto netcfg/dhcp_timeout=120 "
              "DEBIAN_FRONTEND=newt loglevel=4 vt.global_cursor_default=0 consoleblank=0 console=tty0 "
              "nouveau.runpm=0 nomodeset",
    "rescue": "rescue/enable=true ipv6.disable=1 interface=auto netcfg/dhcp_timeout=120 "
              "DEBIAN_FRONTEND=newt console=ttyS0,115200n8 console=tty0 nouveau.runpm=0",
}
got = {"install": m.AMD64_INSTALL_OPTIONS, "expert": m.AMD64_EXPERT_OPTIONS,
       "rescue": m.AMD64_RESCUE_OPTIONS}
for k in AMD64:
    check(got[k] == AMD64[k], f"amd64 {k} options changed: {got[k]!r}")
    check(all(t not in got[k] for t in ("fw_devlink", "ttyAMA", "sky1_pcie", "pcie_pnp_en")),
          f"amd64 {k} carries a Sky1 token")
# The rEFInd video-mode fix must NOT leak nomodeset onto the Rescue entry and
# must not have re-added a `textonly` directive to the amd64 installer config.
check("nomodeset" not in got["rescue"], "amd64 rescue must keep full modeset")
check(m.REFIND_CONF_TEXT_AMD64_FULL_TEMPLATE == m.REFIND_CONF_TEXT_TEMPLATE, "amd64 full template diverged")
print("\n".join(fails) if fails else "OK")
PY
)
if [ "$out" = OK ]; then ok "installer rEFInd entries: arm64 ACPI PCIe mode on all three, no UART console on screen entries, amd64 unchanged"
else bad "installer rEFInd entries" "$out"; fi

# ---- 3: installed boot entries ------------------------------------------------
base=$(sed -n 's/^NEXT_CMDLINE_BASE="\(console=[^"]*\)"$/\1/p' "$REFRESH" | head -1)
extra=$(sed -n 's/^NEXT_CMDLINE_EXTRA="\([^"]*\)"$/\1/p' "$REFRESH" | head -1)
cons=$(printf '%s\n' $base | grep '^console=' | paste -sd' ' -)
if [ "$cons" = "console=ttyAMA0,115200 console=tty0" ] \
    && printf '%s\n' $extra | grep -qx 'sky1_pcie_native=off' \
    && printf '%s\n' $extra | grep -qx 'pcie_pnp_en' \
    && grep -q '^NEXT_CMDLINE_BASE="\$NEXT_CMDLINE_BASE \$NEXT_CMDLINE_EXTRA"$' "$REFRESH"; then
    ok "installed arm64 cmdline: serial console with tty0 last, ACPI PCIe mode on every entry"
else
    bad "installed arm64 cmdline" "base=$base extra=$extra"
fi
if grep -qE 'fw_devlink|sky1_pcie_native|pcie_pnp_en' "$REFRESH_AMD64"; then bad "amd64 refresh script carries a Sky1 PCIe token"
else ok "amd64 installed cmdline carries no Sky1 PCIe token"; fi

# ---- 4: installed serial getty --------------------------------------------------
if awk '/^if \[ "\$_ncz_arch" = "arm64" \]; then/{a=1} a&&/systemctl enable serial-getty@ttyAMA0.service/{print "y"; exit} /^else/{a=0}' "$TELEMETRY" | grep -q y; then
    ok "36-telemetry enables serial-getty@ttyAMA0 inside the arm64 branch"
else
    bad "36-telemetry: serial-getty@ttyAMA0 is not enabled in the arm64 branch"
fi

# ---- 5: diag-console serial block in a sandbox ---------------------------------
BLOCK_SRC=$(sed -n '/^# >>> ncz-serial-diag/,/^# <<< ncz-serial-diag/p' "$DIAG")
if [ -z "$BLOCK_SRC" ] || ! printf '%s\n' "$BLOCK_SRC" | grep -q '^serial_tick()'; then
    bad "diag-console.sh has no ncz-serial-diag block with serial_tick()"
    echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
SB_TOP=$(mktemp -d "$REPO/build/.test-serial-diag.XXXXXX") || exit 2
trap 'for p in $(cat "$SB_TOP"/*/run/serial-getty.pid 2>/dev/null); do kill "$p" 2>/dev/null; done; rm -rf "$SB_TOP"' EXIT

# Fake busybox: getty records its argv and stays alive like a real getty.
FAKEBB="$SB_TOP/busybox"
cat > "$FAKEBB" <<'BB'
#!/bin/sh
cmd=$1; shift
case "$cmd" in
    getty) echo "$*" >> "$SB/getty.args"; exec sleep 30 ;;
    stty)  echo "$*" >> "$SB/stty.args" ;;
    dmesg) cat "$SB/dmesg.txt" ;;
    *)     exec "$cmd" "$@" ;;
esac
BB
chmod +x "$FAKEBB"

# run_case NAME ARCH CMDLINE INITTAB_LINE CONSOLES_LINE NETIFS
run_case() {
    local name=$1 arch=$2 cmdline=$3 inittab=$4 consoles=$5 netifs=$6
    local sb="$SB_TOP/$name"
    mkdir -p "$sb/run" "$sb/net" "$sb/pci/0000:90:00.0" "$sb/root"
    printf '%s\n' "$inittab" > "$sb/inittab"
    printf '%s\n' "$consoles" > "$sb/consoles"
    : > "$sb/serial"
    for i in $netifs; do mkdir -p "$sb/net/$i"; done
    echo 0x1e0f > "$sb/pci/0000:90:00.0/vendor"; echo 0x0009 > "$sb/pci/0000:90:00.0/device"
    echo 0x010802 > "$sb/pci/0000:90:00.0/class"
    printf '%s\n' '6,1,238630,-;reg-fixed-voltage PRP0001:11: probe with driver reg-fixed-voltage failed with error -12' \
        ' SUBSYSTEM=platform' \
        '4,2,11742673,-;platform sky1-pcie-cix.2.auto: deferred probe pending: platform: supplier PRP0001:11 not ready' > "$sb/kmsg"
    printf '%s\n' '[    0.238630] reg-fixed-voltage PRP0001:11: probe with driver reg-fixed-voltage failed with error -12' \
        '[   11.742673] platform sky1-pcie-cix.2.auto: deferred probe pending: platform: supplier PRP0001:11 not ready' \
        '[    0.765756] sky1-pcie-cix sky1-pcie-cix.1.auto: Link up' > "$sb/dmesg.txt"
    SB="$sb" BB="$FAKEBB" BB_ARCH="$arch" RUN="$sb/run" BIN="/tmp/diagbin" CMDLINE="$cmdline" \
    NCZ_SERIAL_DEV="$sb/serial" NCZ_SERIAL_NAME=ttyAMA0 NCZ_SERIAL_ALLOW_FILE=1 NCZ_INITTAB="$sb/inittab" \
    NCZ_CONSOLE_PREFERRED="$sb/console-preferred" NCZ_PROC_CONSOLES="$sb/consoles" \
    NCZ_KMSG="$sb/kmsg" NCZ_SYS_NET="$sb/net" NCZ_SYS_PCI="$sb/pci" \
    NCZ_NOIFACE_LOG="$sb/noiface.txt" NCZ_NOIFACE_AFTER=0 NCZ_ROOT_PROFILE="$sb/root/.profile" \
    BLOCK_SRC="$BLOCK_SRC" sh -c '
        export SB
        say() { echo "$*" >> "$SB/say.log"; }
        alive() { p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
        kv() { for t in $CMDLINE; do case "$t" in "$1"=*) echo "${t#*=}"; return;; esac; done; }
        eval "$BLOCK_SRC"
        serial_tick
        p=$(cat "$RUN/serial-kmsg.pid" 2>/dev/null); [ -n "$p" ] && wait "$p" 2>/dev/null
        serial_tick
    ' >/dev/null 2>&1
    sleep 1
}

INITTAB_TTY1='tty1::respawn:/sbin/debian-installer'
INITTAB_UART='ttyAMA0::respawn:/sbin/debian-installer'
CONS_TTY0='tty0                 -WU (EC p  )    4:1'
CONS_UART='ttyAMA0              -W- (E  p a)  204:64'

run_case arm64-screen arm64 "quiet" "$INITTAB_TTY1" "$CONS_TTY0" "lo enP1s0"
sb="$SB_TOP/arm64-screen"
if grep -qx -- "-L -l /tmp/diagbin/login 115200 ttyAMA0 vt100" "$sb/getty.args" 2>/dev/null \
    && [ "$(wc -l < "$sb/getty.args")" -eq 1 ]; then
    ok "arm64, d-i on tty1: one getty on the UART at 115200 (respawn tick does not double it)"
else bad "arm64, d-i on tty1: getty" "$(cat "$sb/getty.args" 2>/dev/null)"; fi
if grep -q '^\[    0.238630\] reg-fixed-voltage PRP0001:11' "$sb/serial" \
    && grep -q '^\[   11.742673\] platform sky1-pcie-cix.2.auto: deferred probe pending' "$sb/serial" \
    && ! grep -q 'SUBSYSTEM=' "$sb/serial"; then
    ok "arm64, d-i on tty1: /dev/kmsg replayed onto the UART with kernel timestamps"
else bad "arm64, d-i on tty1: kmsg mirror" "$(cat "$sb/serial")"; fi
if grep -q '^export PATH=/tmp/diagbin:' "$sb/root/.profile" 2>/dev/null; then ok "arm64: login shell profile puts the diag applet farm on PATH"
else bad "arm64: login shell profile missing"; fi
if grep -q "awk -F: '\$1 == \"root\" { print \$6; exit }' /etc/passwd" "$DIAG"; then ok "profile path follows root's passwd home (d-i root has HOME=/)"
else bad "profile path is not derived from root's passwd home"; fi
if grep -q '115200' "$sb/stty.args" 2>/dev/null; then ok "arm64: UART line set to 115200 before writing"
else bad "arm64: stty 115200 not issued"; fi
if [ ! -e "$sb/noiface.txt" ]; then ok "arm64 with a NIC: no no-interface summary"
else bad "arm64 with a NIC: unexpected no-interface summary"; fi

run_case arm64-uart-owned arm64 "quiet" "$INITTAB_UART" "$CONS_UART" "lo"
sb="$SB_TOP/arm64-uart-owned"
if [ ! -s "$sb/getty.args" ] && [ ! -s "$sb/serial" ]; then
    ok "arm64, d-i owns ttyAMA0: no getty, no mirror, nothing written over the dialogs"
else bad "arm64, d-i owns ttyAMA0" "getty=$(cat "$sb/getty.args" 2>/dev/null) serial=$(head -3 "$sb/serial")"; fi
if grep -q 'NO NETWORK INTERFACE' "$sb/noiface.txt" 2>/dev/null; then
    ok "arm64, d-i owns ttyAMA0, only lo: summary still logged to the file"
else bad "arm64, d-i owns ttyAMA0: no-interface log missing"; fi

run_case arm64-off arm64 "quiet ncz_diag_serial=0" "$INITTAB_TTY1" "$CONS_TTY0" "lo enP1s0"
sb="$SB_TOP/arm64-off"
if [ ! -s "$sb/getty.args" ] && [ ! -s "$sb/serial" ]; then ok "ncz_diag_serial=0: serial block disabled"
else bad "ncz_diag_serial=0 did not disable the serial block"; fi

run_case amd64 amd64 "quiet" "$INITTAB_TTY1" "$CONS_TTY0" "lo"
sb="$SB_TOP/amd64"
if [ ! -s "$sb/getty.args" ] && [ ! -s "$sb/serial" ] && [ ! -e "$sb/noiface.txt" ] && [ ! -e "$sb/root/.profile" ]; then
    ok "amd64: serial block does nothing (no getty, no mirror, no summary, no profile)"
else bad "amd64: serial block had an effect"; fi

run_case arm64-kcons arm64 "quiet" "$INITTAB_TTY1" "$(printf '%s\n%s' "$CONS_TTY0" "$CONS_UART")" "lo enP1s0"
sb="$SB_TOP/arm64-kcons"
if [ -s "$sb/getty.args" ] && [ ! -s "$sb/serial" ]; then
    ok "arm64, ttyAMA0 already a kernel console: getty yes, no duplicate kmsg mirror"
else bad "arm64, ttyAMA0 kernel console" "getty=$(cat "$sb/getty.args" 2>/dev/null)"; fi

run_case arm64-noiface arm64 "quiet" "$INITTAB_TTY1" "$CONS_TTY0" "lo"
sb="$SB_TOP/arm64-noiface"
n=$(grep -c 'NO NETWORK INTERFACE' "$sb/serial" 2>/dev/null || true)
if [ "${n:-0}" -eq 1 ] \
    && grep -q '^\[ncz-noiface\] 0000:90:00.0 0x1e0f:0x0009 0x010802 <no driver>' "$sb/noiface.txt" \
    && grep -q "dmesg | grep -E 'deferred probe|reg-fixed|sky1-pcie|r8169'" "$sb/noiface.txt" \
    && grep -q '^\[ncz-noiface\] \[   11.742673\] platform sky1-pcie-cix.2.auto: deferred probe pending' "$sb/noiface.txt" \
    && grep -q "dmesg | grep -i -E 'pcie|r8169|eth'" "$sb/noiface.txt"; then
    ok "arm64, only lo: one no-interface summary (PCI list + both dmesg greps) on the UART and in the log"
else bad "arm64, only lo: no-interface summary" "count=$n; $(head -20 "$sb/noiface.txt" 2>/dev/null)"; fi

# ---- 6: call sites --------------------------------------------------------------
first_tick=$(grep -n '^serial_tick$' "$DIAG" | head -1 | cut -d: -f1)
first_dhcp=$(grep -n '^diag_net_up || say' "$DIAG" | head -1 | cut -d: -f1)
if [ -n "$first_tick" ] && [ -n "$first_dhcp" ] && [ "$first_tick" -lt "$first_dhcp" ] \
    && grep -q 'do serial_tick; diag_net_up' "$DIAG" \
    && awk '/^while :; do$/{w=1;next} w&&/serial_tick/{print "y";exit} w&&/^done/{exit}' "$DIAG" | grep -q y; then
    ok "diag-console runs the serial block before the first DHCP attempt and in both loops"
else bad "diag-console serial_tick call sites" "tick=$first_tick dhcp=$first_dhcp"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
