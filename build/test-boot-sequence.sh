#!/bin/bash
# test-boot-sequence.sh -- regression tests for the 2026-10-06 detection / boot-sequence fixes
# (docs/BOOT-SEQUENCE.md). Each section runs the REAL script (or the real generated heredoc) against stubs:
#
#  A. preseed/net-pick.sh: the "Waiting for a wired network link" loop ends at 5 s when a PCI/USB link is up
#     (was 25 s with a cable-less onboard NIC: PEGASUS), at 10 s with no wired adapter at all and says so with a
#     diagnostics hint (was 45 s: O6N in DT PCIe mode saw only lo), and at 20 s with adapters but no carrier
#     (was 45 s; netcfg still waits its own 60 s afterwards). Unchanged: PCI link wins at once, a weak iBridge
#     candidate still gets the PCI settle.
#  B. preseed/clock-sync.sh + preseed.cfg: clock-setup's foreground rdate is off, the helper runs detached from
#     early_command, a silent NTP server is killed after the bound, no route exits at once, and the old
#     year<2020 HTTP-Date refinement still happens when SNTP gives nothing.
#  C. post-install/22-display-fix.sh: the generated detect-primary-display.sh writes the Sky1 card pin
#     (udev master-of-seat rule + Xorg kmsdev) only on aarch64; on x86_64 it only waits for a connected output.
#     The install-time run is arm64-only.
#  D. post-install/33-network.sh: NetworkManager-wait-online is bounded (NM_ONLINE_TIMEOUT 5..20 s) and the
#     greetd drop-in does not order the greeter after network-online.
#  E. preseed/diag-console.sh: alive() is defined before serial_tick first runs.
#
#   bash build/test-boot-sequence.sh            (re-runs itself under busybox sh when busybox is installed)
#   NCZ_BS_ROOT=<tree> bash build/test-boot-sequence.sh   (run against another checkout, e.g. the base commit)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${NCZ_BS_ROOT:-$(cd "$HERE/.." && pwd)}"
PRE="$ROOT/preseed"
SHX="${NCZ_TEST_SH:-sh}"
W="$(mktemp -d "${TMPDIR:-/tmp}/boot-sequence.XXXXXX")"
trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()    { echo "ok   $1"; PASS=$((PASS+1)); }
bad()   { echo "FAIL $1"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: got '$2' want '$3'"; fi; }
echo "-- root: $ROOT  shell: $SHX"

# ---------------------------------------------------------------- A. net-pick ---------------------------------------
echo "== A. net-pick.sh wait bounds"
# mksys DIR SPEC... ; SPEC = name:kind:carrier, kind = pci|usb|ibridge|wifi
mksys() {
    local d=$1; shift; rm -rf "$d"; mkdir -p "$d/net/lo" "$d/pci"
    local spec name kind car n=0
    for spec in "$@"; do
        name=${spec%%:*}; kind=${spec#*:}; car=${kind#*:}; kind=${kind%%:*}; n=$((n+1))
        mkdir -p "$d/net/$name"; echo "$car" > "$d/net/$name/carrier"
        case "$kind" in
            pci) mkdir -p "$d/pci/0000:3c:0$n.0" "$d/devices/pci0000:00/0000:3c:0$n.0"
                 echo 0x020000 > "$d/pci/0000:3c:0$n.0/class"
                 ln -s "$d/devices/pci0000:00/0000:3c:0$n.0" "$d/net/$name/device" ;;
            usb) mkdir -p "$d/devices/pci0000:00/0000:00:14.0/usb1/1-$n/1-$n:1.0"
                 ln -s "$d/devices/pci0000:00/0000:00:14.0/usb1/1-$n/1-$n:1.0" "$d/net/$name/device" ;;
            ibridge) echo "ac:de:48:00:11:22" > "$d/net/$name/address" ;;
            wifi) mkdir -p "$d/net/$name/wireless" ;;
        esac
    done
}
# netpick TAG SYSDIR -> runs the real scan with every wait at its DEFAULT (only the tick is 0)
netpick() { local tag=$1 sys=$2
    NCZ_CONFMODULE=/dev/null NCZ_SYS_NET="$sys/net" NCZ_SYS_PCI="$sys/pci" NCZ_NET_STATE="$W/picked.$tag" \
        NCZ_NET_TICK=0 NCZ_NET_TTY="$W/tty.$tag" NCZ_IP=true timeout 60 $SHX "$PRE/net-pick.sh" scan > "$W/log.$tag" 2>&1
}
after() { sed -n 's/.* after \([0-9][0-9]*\)s.*/\1/p' "$W/log.$1" | tail -1; }

mksys "$W/s1" eno2:pci:0 enx00e05c6701d5:usb:1
netpick a1 "$W/s1"
check "PEGASUS shape: USB link up, cable-less onboard NIC -> picks the USB NIC" "$(cat "$W/picked.a1")" "enx00e05c6701d5"
s=$(after a1); [ -n "$s" ] && [ "$s" -le 10 ] && ok "PEGASUS shape: settles in ${s}s (<= 10 s; was 25 s)" || bad "PEGASUS shape settled after '${s}'s, want <= 10 (log: $(tail -1 "$W/log.a1"))"

mksys "$W/s2" eno2:pci:1 enx00e05c6701d5:usb:1
netpick a2 "$W/s2"
check "PCI link up wins at once" "$(cat "$W/picked.a2"):$(after a2)" "eno2:1"

mksys "$W/s3"
netpick a3 "$W/s3"
s=$(after a3); [ -n "$s" ] && [ "$s" -le 10 ] && ok "no wired adapter (O6N: only lo): stops after ${s}s (<= 10; was 45)" || bad "no adapter: stopped after '${s}'s, want <= 10"
grep -q 'No wired network adapter was detected' "$W/tty.a3" && ok "no wired adapter: the screen says so" || bad "no wired adapter: no 'No wired network adapter' message"
grep -q 'Alt+F4' "$W/tty.a3" && grep -q 'serial console' "$W/tty.a3" && ok "no wired adapter: message carries the Alt+F4 / serial diagnostics hint" || bad "no wired adapter: diagnostics hint missing"
check "no wired adapter: nothing is pinned (netcfg stays auto)" "$(cat "$W/picked.a3")" ""

mksys "$W/s4" wlan0:wifi:1
netpick a4 "$W/s4"
s=$(after a4); [ -n "$s" ] && [ "$s" -le 10 ] && ok "wireless only counts as no wired adapter (${s}s)" || bad "wireless only: stopped after '${s}'s"

mksys "$W/s5" eno2:pci:0 enp49s0:pci:0
netpick a5 "$W/s5"
s=$(after a5); [ -n "$s" ] && [ "$s" -ge 13 ] && [ "$s" -le 20 ] && ok "adapters, no carrier: gives up after ${s}s (13..20; was 45; slowest measured autoneg 13 s)" || bad "no carrier: gave up after '${s}'s, want 13..20"
check "adapters, no carrier: nothing pinned" "$(cat "$W/picked.a5")" ""

mksys "$W/s6" eno2:pci:0 enxacde48001122:ibridge:1
netpick a6 "$W/s6"
s=$(after a6); [ -n "$s" ] && [ "$s" -ge 20 ] && ok "only a weak iBridge link: still waits for the PCI NIC (${s}s, unchanged)" || bad "iBridge-only settled early after '${s}'s"

mksys "$W/s7" enxacde48001122:ibridge:1 enx00e04c684081:usb:1
netpick a7 "$W/s7"
check "T2 shape: the real USB adapter beats the always-up iBridge" "$(cat "$W/picked.a7")" "enx00e04c684081"
s=$(after a7); [ -n "$s" ] && [ "$s" -le 5 ] && ok "T2 shape: settles in ${s}s (<= 5)" || bad "T2 shape settled after '${s}'s"

# ---------------------------------------------------------------- B. clock ------------------------------------------
echo "== B. clock-sync.sh + clock-setup"
CFG="$PRE/preseed.cfg"
grep -qE '^d-i clock-setup/ntp boolean false$' "$CFG" && ok "preseed: clock-setup/ntp=false (no foreground rdate)" || bad "preseed: clock-setup/ntp is not false"
EARLY=$(awk '/^d-i preseed\/early_command string/{f=1} f{print} f && !/\\$/{exit}' "$CFG" | tr -d '\n\\')
case "$EARLY" in *'sh /tmp/clock-sync.sh </dev/null'*'& fi'*) ok "early_command starts clock-sync.sh detached (&)" ;; *) bad "early_command does not start clock-sync.sh in the background" ;; esac
case "$EARLY" in *'wget -S -O /dev/null'*) bad "early_command still carries the inline wget Date subshell" ;; *) ok "inline wget Date subshell moved out of early_command" ;; esac
grep -qE '^[[:space:]]*"clock-sync\.sh",' "$ROOT/build/iso/patch-initrd-t2-kernel.py" && ok "clock-sync.sh is baked into the initrd" || bad "clock-sync.sh missing from BAKED_HELPERS"

if [ -f "$PRE/clock-sync.sh" ]; then
    mkdir -p "$W/cbin"
    printf '#!/bin/sh\n[ "$1" = route ] && cat "%s/route" 2>/dev/null\nexit 0\n' "$W" > "$W/cbin/ip"
    printf '#!/bin/sh\necho $$ > "%s/rdate.pid"\nsleep 30\n' "$W" > "$W/cbin/rdate-hang"
    printf '#!/bin/sh\necho "rdate: adjust local clock by 0.5 seconds"\nexit 0\n' > "$W/cbin/rdate-ok"
    printf '#!/bin/sh\necho "  Date: Tue, 06 Oct 2026 16:32:01 GMT" >&2\nexit 0\n' > "$W/cbin/wget"
    printf '#!/bin/sh\necho "$*" >> "%s/date-set"\nexit 0\n' "$W" > "$W/cbin/date-set"
    chmod +x "$W/cbin/"*
    clk() { local tag=$1; shift
        env NCZ_CLOCK_LOG="$W/clog.$tag" NCZ_CLOCK_TTY=/dev/null NCZ_CLOCK_TICK=0 NCZ_IP="$W/cbin/ip" \
            NCZ_WGET="$W/cbin/wget" NCZ_DATE="$W/cbin/date-set" "$@" timeout 60 $SHX "$PRE/clock-sync.sh"; }

    : > "$W/route"
    t0=$(date +%s); clk b1 NCZ_CLOCK_ROUTE_WAIT=3 NCZ_RDATE="$W/cbin/rdate-ok"; rc=$?; t1=$(date +%s)
    check "no route: exits 0" "$rc" 0
    [ $((t1 - t0)) -le 2 ] && ok "no route: returns at once ($((t1 - t0)) s)" || bad "no route took $((t1 - t0)) s"
    grep -q 'no default route' "$W/clog.b1" && ok "no route: logged as offline" || bad "no route: not logged"

    echo "default via 192.168.207.1 dev enp1s0" > "$W/route"
    t0=$(date +%s); clk b2 NCZ_CLOCK_BOUND=2 NCZ_RDATE="$W/cbin/rdate-hang" NCZ_CLOCK_YEAR=2026; rc=$?; t1=$(date +%s)
    check "silent NTP server: exits 0" "$rc" 0
    # 2 s bound + 1 s TERM grace = 3-4 s by the second clock; a helper that ignored the bound would take the stub's 30 s.
[ $((t1 - t0)) -le 5 ] && ok "silent NTP server: stopped by the bound ($((t1 - t0)) s for a 2 s bound)" || bad "silent NTP server took $((t1 - t0)) s (want <= 5)"
    grep -q 'no answer within 2s' "$W/clog.b2" && ok "silent NTP server: logged" || bad "silent NTP server: not logged"
    p=$(cat "$W/rdate.pid" 2>/dev/null); if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then bad "silent NTP server: rdate $p still running"; kill -9 "$p" 2>/dev/null; else ok "silent NTP server: rdate was killed"; fi

    clk b3 NCZ_RDATE="$W/cbin/rdate-ok" NCZ_CLOCK_YEAR=2026
    grep -q 'set the clock' "$W/clog.b3" && ok "answering NTP server: clock set" || bad "answering NTP server: not logged as set"
    printf '#!/bin/sh\necho "rdate: Unable to get a reasonable time estimate" >&2\nexit 1\n' > "$W/cbin/rdate-fail"; chmod +x "$W/cbin/rdate-fail"
    clk b3f NCZ_RDATE="$W/cbin/rdate-fail" NCZ_CLOCK_YEAR=2026
    grep -q 'failed (rc=1)' "$W/clog.b3f" && ok "refusing NTP server: logged as failed, not as a timeout" || bad "refusing NTP server: not logged as failed (rc=1)"

    rm -f "$W/date-set"
    clk b4 NCZ_CLOCK_RDATE_WAIT=2 NCZ_RDATE="$W/cbin/no-such-rdate" NCZ_CLOCK_YEAR=1970
    check "no rdate + 1970 clock: refined from the mirror Date header" "$(cat "$W/date-set" 2>/dev/null)" "-u -s 2026-10-06 16:32:01"
    rm -f "$W/date-set"
    clk b5 NCZ_CLOCK_RDATE_WAIT=2 NCZ_RDATE="$W/cbin/no-such-rdate" NCZ_CLOCK_YEAR=2026
    [ ! -e "$W/date-set" ] && ok "no rdate + plausible clock: HTTP Date not used (old year<2020 rule kept)" || bad "plausible clock was stepped from HTTP Date"
else
    bad "preseed/clock-sync.sh does not exist"
fi

# ---------------------------------------------------------------- C. display pin ------------------------------------
echo "== C. 22-display-fix.sh Sky1 pin is aarch64-only"
HOOK="$ROOT/post-install/22-display-fix.sh"
awk "/^cat > \/usr\/local\/lib\/cix-installer\/detect-primary-display.sh <<'DET'/{f=1;next} /^DET\$/{f=0} f" "$HOOK" > "$W/det.sh"
[ -s "$W/det.sh" ] && ok "extracted the generated detect-primary-display.sh" || bad "could not extract detect-primary-display.sh"
detrun() { local arch=$1 r="$W/root.$1"
    rm -rf "$r"; mkdir -p "$r/sys/class/drm/card1-eDP-1" "$r/etc/X11" "$r/etc/udev/rules.d" "$r/var/log" "$r/bin"
    echo connected > "$r/sys/class/drm/card1-eDP-1/status"
    printf '#!/bin/sh\necho %s\n' "$arch" > "$r/bin/uname"; printf '#!/bin/sh\nexit 0\n' > "$r/bin/udevadm"; chmod +x "$r/bin/"*
    sed -e "s#/sys/class/drm#$r/sys/class/drm#g" -e "s#/etc/X11#$r/etc/X11#g" -e "s#/etc/udev#$r/etc/udev#g" \
        -e "s#/var/log#$r/var/log#g" "$W/det.sh" > "$r/det.sh"
    PATH="$r/bin:$PATH" timeout 60 sh "$r/det.sh"
}
detrun x86_64
[ ! -e "$W/root.x86_64/etc/udev/rules.d/73-cixmini-primary-display.rules" ] && ok "x86_64: no master-of-seat udev pin written" || bad "x86_64: Sky1 udev master-of-seat pin written (CHIMERA/PEGASUS leak)"
[ ! -e "$W/root.x86_64/etc/X11/xorg.conf.d/10-cixmini-primary-display.conf" ] && ok "x86_64: no Xorg kmsdev pin written" || bad "x86_64: Sky1 Xorg kmsdev pin written"
grep -q 'connected: card1 (eDP-1)' "$W/root.x86_64/var/log/ncz-display-detect.log" 2>/dev/null && ok "x86_64: still waits for and logs the connected output" || bad "x86_64: connected output not detected/logged"
detrun aarch64
grep -q 'KERNEL=="card0", TAG-="master-of-seat"' "$W/root.aarch64/etc/udev/rules.d/73-cixmini-primary-display.rules" 2>/dev/null && ok "aarch64: Sky1 pin unchanged (other cards lose master-of-seat)" || bad "aarch64: Sky1 udev pin missing"
grep -q 'kmsdev" "/dev/dri/card1"' "$W/root.aarch64/etc/X11/xorg.conf.d/10-cixmini-primary-display.conf" 2>/dev/null && ok "aarch64: Xorg kmsdev pin unchanged" || bad "aarch64: Xorg pin missing"
# the install-time run (outside the heredoc) must sit inside the arm64 branch
python3 - "$HOOK" <<'PY' && ok "install-time detect run is arm64-only" || bad "install-time detect run is not arm64-gated"
import re, sys
lines = open(sys.argv[1]).read().split("\n")
out, body = [], False
for l in lines:
    if l.startswith("cat > /usr/local/lib/cix-installer/detect-primary-display.sh <<"): body = True; continue
    if body and l == "DET": body = False; continue
    if not body: out.append(l)
CALL = "/usr/local/lib/cix-installer/detect-primary-display.sh"
calls = [i for i, l in enumerate(out) if re.search(r"(^|\)\s*)" + re.escape(CALL) + r"(\s*;;)?$", l.strip())]
ok = len(calls) == 1
for i in calls:
    s = out[i].strip()
    if re.match(r"(arm64\|aarch64|aarch64\|arm64|arm64)\)\s", s):
        # case arm: the enclosing case must switch on $_ncz_arch
        k = i
        while k > 0 and not out[k].strip().startswith("case "): k -= 1
        ok = ok and '"$_ncz_arch"' in out[k]
    else:
        # plain line: must sit inside if [ "$_ncz_arch" = "arm64" ]; then ... (no else before it)
        k, inside = i, False
        while k > 0:
            k -= 1; t = out[k].strip()
            if t in ("fi", "else"): break
            if re.match(r'if \[ "\$_ncz_arch" = "arm64" \]', t): inside = True; break
        ok = ok and inside
sys.exit(0 if ok else 1)
PY

# ---------------------------------------------------------------- D. wait-online ------------------------------------
echo "== D. NetworkManager-wait-online bound"
NET="$ROOT/post-install/33-network.sh"
awk "/10-ncz-bounded.conf <<'NMWAIT'/{f=1;next} /^NMWAIT\$/{f=0} f" "$NET" > "$W/nmwait.conf"
grep -qx '\[Service\]' "$W/nmwait.conf" && ok "wait-online drop-in has [Service]" || bad "wait-online drop-in missing or has no [Service]"
t=$(sed -n 's/^Environment=NM_ONLINE_TIMEOUT=\([0-9][0-9]*\)$/\1/p' "$W/nmwait.conf")
[ -n "$t" ] && [ "$t" -ge 5 ] && [ "$t" -le 20 ] && ok "NM_ONLINE_TIMEOUT=$t (5..20; stock 60)" || bad "NM_ONLINE_TIMEOUT='$t' not in 5..20"
grep -q 'install -d -m0755 /etc/systemd/system/NetworkManager-wait-online.service.d' "$NET" && ok "drop-in directory is created" || bad "drop-in directory not created"
GREET="$ROOT/post-install/55-greeter.sh"
awk "/10-ncz-drm.conf <<'GREETDDRM'/{f=1;next} /^GREETDDRM\$/{f=0} f" "$GREET" | grep -q 'network-online' \
    && bad "greetd drop-in orders the greeter after network-online" || ok "greetd drop-in is not ordered after network-online"

# ---------------------------------------------------------------- E. diag-console -----------------------------------
echo "== E. diag-console.sh alive() before first use"
DC="$PRE/diag-console.sh"
d=$(grep -n '^alive()' "$DC" | head -1 | cut -d: -f1); u=$(grep -n '^serial_tick$' "$DC" | head -1 | cut -d: -f1)
[ -n "$d" ] && [ -n "$u" ] && [ "$d" -lt "$u" ] && ok "alive() (line $d) is defined before the first serial_tick (line $u)" || bad "alive() defined at line '$d', first serial_tick at line '$u'"

echo "boot-sequence tests ($SHX): $PASS passed, $FAILS failed"
rc=0; [ "$FAILS" = 0 ] || rc=1
# Same convention as test-installer-flow.sh: one run under sh, then again under busybox ash (the installer's shell).
if [ -z "${NCZ_TEST_SH:-}" ] && command -v busybox >/dev/null 2>&1 && busybox sh -c 'exit 0' 2>/dev/null; then
    NCZ_TEST_SH="busybox sh" bash "$0" || rc=1
fi
exit $rc
