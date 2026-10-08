#!/bin/sh
# net-pick.sh -- pick the wired NIC that has carrier and make netcfg use it. Run from preseed/early_command
# (baked at /ncz/net-pick.sh, copied to /tmp/net-pick.sh):
#
#   net-pick.sh scan   the scan pass: raise every NIC, poll carrier, remember the best wired interface
#                      that has carrier in $STATE, then apply it (below).
#   net-pick.sh        an apply pass: apply the remembered pick (used after the scan, and defensively if
#                      early_command is ever evaluated a second time).
#
# WHY "apply" IS SEPARATE FROM "scan": until 2026-10-08 the Install entry passed preseed/file=, so
# file-preseed loaded preseed.cfg a second time and re-ran preseed/early_command. That reload set
# netcfg/choose_interface back to "auto" (preseed.cfg "d-i netcfg/choose_interface select auto", and the
# kernel command line carries interface=auto) and netcfg/link_wait_timeout back to 60, and the re-apply put
# the scan's pick back. The 2026-10-08 fix loads preseed.cfg once (d-i S30initrd-preseed from the baked
# /preseed.cfg), so no reload happens; the scan/apply split and $STATE are kept so the helper stays correct
# if the command is ever evaluated twice, and they document the PEGASUS failure: 2026-10-06 logged
# "ALREADY RAN -- skipping duplicate invocation (no stored pick to re-apply)" with /tmp/.ncz-picked-if =
# enx00e05c6701d5 present, then netcfg ran in auto mode, activated the cable-less onboard eno2 first and
# waited the full 60 s link timeout before trying the USB NIC that had carrier all along.
#
# What "apply" sets:
#   carrier found  -> netcfg/choose_interface=<that NIC> (seen), and netcfg/link_wait_timeout=$FAST_WAIT so any
#                     carrier-less interface netcfg still touches costs seconds, not a minute.
#   no carrier     -> leave choose_interface=auto and the preseeded 60 s wait: a cable plugged in late, or a slow
#                     PHY, still gets its full chance, and with no NIC at all (O6N seeing only lo) netcfg shows its
#                     own "no network interfaces" error instead of anything here hanging.
#
# Ranking (unchanged from the inline scan it replaces): PCI wired 1 < USB wired 2 < other 3 < QEMU-style
# ac:de:48:00:11:22 4; wireless 9 is never picked. A PCI NIC with carrier ends the scan at once. Otherwise:
#   * a real wired candidate (PCI or USB, rank <= 2) already has carrier -> settle after $CARRIER_SETTLE s
#     (5 s). Before 2026-10-06 this waited the full PCI settle (25 s) for a cable-less onboard NIC that never
#     came up: PEGASUS (USB NIC with carrier at 6.6 s kernel time, cable-less eno2) sat in early_command from
#     14:17:59 to 14:18:26. Picking the USB NIC when the onboard NIC ALSO had a cable that was still
#     negotiating costs nothing: both reach the same network.
#   * only a weak candidate (rank 3/4, e.g. the T2 iBridge NCM link that always reports carrier) -> keep
#     polling for $SETTLE s (25 s when a PCI Ethernet controller exists, its autoneg can take 9-13 s; 3 s when
#     there is none) before settling for it.
#   * no wired network adapter exists at all after $NOIF_WAIT s (10 s; O6N in DT PCIe mode saw only lo and the
#     old loop printed "Waiting for a wired network link... (45s)") -> stop and say so, with the diagnostics
#     hint, instead of counting to $MAXWAIT.
#   * adapters exist but none has carrier -> give up after $MAXWAIT s (20 s, above the slowest measured
#     autoneg). netcfg keeps its preseeded 60 s link wait afterwards, so a cable plugged in late still works.
#
# Test seams: NCZ_CONFMODULE, NCZ_SYS_NET, NCZ_SYS_PCI, NCZ_NET_STATE, NCZ_NET_TICK, NCZ_NET_MAXWAIT,
# NCZ_NET_SETTLE, NCZ_NET_CARRIER_SETTLE, NCZ_NET_NOIF_WAIT, NCZ_NET_TTY, NCZ_IP, NCZ_IS_MAC.
. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true

SYSNET="${NCZ_SYS_NET:-/sys/class/net}"
SYSPCI="${NCZ_SYS_PCI:-/sys/bus/pci/devices}"
STATE="${NCZ_NET_STATE:-/tmp/.ncz-picked-if}"
TICK="${NCZ_NET_TICK:-1}"
MAXWAIT="${NCZ_NET_MAXWAIT:-20}"
CARRIER_SETTLE="${NCZ_NET_CARRIER_SETTLE:-5}"
NOIF_WAIT="${NCZ_NET_NOIF_WAIT:-10}"
TTY="${NCZ_NET_TTY:-/dev/tty3}"
IP="${NCZ_IP:-ip}"
FAST_WAIT=10

_rank() {
    _k="$SYSNET/$1"
    { [ -d "$_k/wireless" ] || [ -e "$_k/phy80211" ] ; } && { echo 9 ; return ; }
    case "$(cat "$_k/address" 2>/dev/null)" in ac:de:4?:00:11:22) echo 4 ; return ;; esac
    _kd=$(readlink -f "$_k/device" 2>/dev/null)
    case "$_kd" in *"/usb"*) echo 2 ; return ;; esac
    case "$_kd" in /sys/devices/pci*|*/pci[0-9]*:*) echo 1 ; return ;; esac
    echo 3
}

if [ "${1:-}" = scan ] ; then
    _pci_eth=0
    for _c in "$SYSPCI"/*/class ; do case "$(cat "$_c" 2>/dev/null)" in 0x0200*) _pci_eth=1 ; break ;; esac ; done
    SETTLE=25 ; [ "$_pci_eth" = 0 ] && SETTLE=3
    [ -n "${NCZ_NET_SETTLE:-}" ] && SETTLE=$NCZ_NET_SETTLE
    echo "early_command: PCI ethernet present=$_pci_eth -> USB-candidate settle ${SETTLE}s"
    PICKED_IF="" ; PICKED_RANK=9 ; _i=0 ; NOIF=0
    while [ "$_i" -lt "$MAXWAIT" ] ; do
        _i=$((_i + 1))
        _wired=0
        for _if in "$SYSNET"/* ; do
            _ifn=${_if##*/} ; [ "$_ifn" = lo ] && continue ; [ -e "$_if" ] || continue
            "$IP" link set dev "$_ifn" up 2>/dev/null || true
            [ "$(_rank "$_ifn")" -lt 9 ] && _wired=$((_wired + 1))
        done
        if [ "$_wired" = 0 ] && [ "$_i" -ge "$NOIF_WAIT" ] ; then
            NOIF=1 ; break
        fi
        for _if in "$SYSNET"/* ; do
            _ifn=${_if##*/} ; [ "$_ifn" = lo ] && continue
            [ -f "$_if/carrier" ] || continue
            [ "$(cat "$_if/carrier" 2>/dev/null)" = 1 ] || continue
            _r=$(_rank "$_ifn") ; [ "$_r" -ge 9 ] && continue
            if [ "$_r" -lt "$PICKED_RANK" ] ; then
                PICKED_RANK=$_r ; PICKED_IF=$_ifn
                echo "early_command: wired candidate $_ifn rank=$_r at ${_i}s"
            fi
        done
        [ "$PICKED_RANK" -le 1 ] && break
        [ "$PICKED_RANK" -le 2 ] && [ "$_i" -ge "$CARRIER_SETTLE" ] && break
        [ -n "$PICKED_IF" ] && [ "$_i" -ge "$SETTLE" ] && break
        echo "[ncz] Waiting for a wired network link... (${_i}s of at most ${MAXWAIT}s)" > "$TTY" 2>/dev/null || true
        sleep "$TICK"
    done
    if [ -n "$PICKED_IF" ] ; then
        echo "early_command: selected $PICKED_IF (rank $PICKED_RANK) after ${_i}s"
        printf '%s\n' "$PICKED_IF" > "$STATE"
    elif [ "$NOIF" = 1 ] ; then
        echo "early_command: no wired network adapter after ${_i}s (only lo/wireless in $SYSNET), leaving netcfg/choose_interface=auto"
        : > "$STATE"
        for V in /dev/tty1 "$TTY" ; do
            echo "[ncz] No wired network adapter was detected (${_i}s). The installer downloads its components over a wired link: connect a supported Ethernet adapter and reboot. Diagnostics: Alt+F2 opens a shell, Alt+F4 shows the log; on Sky1 boards the serial console (ttyAMA0, 115200) has a root shell." > "$V" 2>/dev/null || true
        done
    else
        echo "early_command: no wired carrier after ${_i}s, leaving netcfg/choose_interface=auto"
        : > "$STATE"
        if [ "${NCZ_IS_MAC:-0}" = 1 ] ; then
            for V in /dev/tty1 "$TTY" ; do echo "[ncz] No wired link found. On Apple hardware this installer requires a wired adapter." > "$V" 2>/dev/null || true ; done
        fi
    fi
fi

command -v db_set >/dev/null 2>&1 || { echo "early_command: net-pick: no confmodule, netcfg left as preseeded" ; exit 0 ; }
PICK=$(cat "$STATE" 2>/dev/null)
if [ -n "$PICK" ] && [ -e "$SYSNET/$PICK" ] ; then
    db_set netcfg/choose_interface "$PICK"
    db_fset netcfg/choose_interface seen true
    db_set netcfg/link_wait_timeout "$FAST_WAIT"
    db_fset netcfg/link_wait_timeout seen true
    echo "early_command: netcfg/choose_interface=$PICK (carrier up), netcfg/link_wait_timeout=$FAST_WAIT"
else
    echo "early_command: no interface with carrier${PICK:+ ($PICK is gone)}: netcfg/choose_interface stays auto, link wait as preseeded"
fi
exit 0
