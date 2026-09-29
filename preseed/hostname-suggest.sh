#!/bin/sh
# hostname-suggest.sh -- NCZ installer hostname SUGGESTION, run from
# preseed/early_command via _ncz_helper (baked at /ncz/hostname-suggest.sh).
#
# WHY A HELPER: this logic used to be inlined in preseed.cfg's early_command,
# which pushed the joined command to 15,634 bytes. /bin/preseed_command then
# died in confmodule (`return: line 88: Illegal number`, db_get lost the reply),
# early_command never ran, the ext4 medium was never mounted at /cdrom and d-i
# stopped at "Incorrect installation media detected" (arm64 KVM gate,
# 2026-09-29). build/check-early-command-size.sh enforces the budget.
#
# WHAT IT SEEDS: netcfg/get_hostname and netcfg/hostname = ncz-<star>-<nnnn>.
# Unattended installs (an ncz_components= token on the kernel command line) mark
# the questions seen so nothing prompts; interactive installs show the suggestion
# for the operator to override.
#
# STABLE IDENTITY, NOT A SWAPPABLE NIC. The name used to hash the MAC of the wired
# adapter early_command picked, so it FOLLOWED THE DOCK: CHIMERA and MEDUSA both
# became ncz-9b4fe9 when one Thunderbolt dock moved between them. The identity is
# now taken from the machine itself, first usable source wins:
#   1. DMI product_uuid            (unique per machine, present on x86 and T2 Macs)
#   2. DMI product/board/chassis serial
#   3. the onboard wireless MAC    (soldered on; T2 Macs and laptops have one)
#   4. the lowest-numbered PCI (non-USB) NIC MAC
#   5. random                      (last resort: a fresh name each install)
# Placeholder DMI values ("Default string", "Radxa System Serial Number",
# all-zero or all-f UUIDs, ...) are rejected, because a board that reports one
# constant would give every unit the same hostname. The identity is hashed, never
# used raw: a hostname is broadcast over DHCP and mDNS.
#
# Test seams (used only by build/test-hostname-suggest.sh): NCZ_DMI_DIR,
# NCZ_NET_DIR, NCZ_CONFMODULE.
. "${NCZ_CONFMODULE:-/usr/share/debconf/confmodule}" 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
command -v db_set >/dev/null 2>&1 || exit 0

DMI="${NCZ_DMI_DIR:-/sys/class/dmi/id}"
NET="${NCZ_NET_DIR:-/sys/class/net}"

# a DMI value is usable if it is non-empty, not a well-known placeholder, and has
# some entropy (not one repeated character).
_ncz_dmi_ok() {
    _v=$(printf '%s' "$1" | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')
    [ -n "$_v" ] || return 1
    case "$_v" in
        *defaultstring*|*tobefilled*|*notspecified*|*notapplicable*|*serialnumber*|*systemserial*|*unknown*|*none|n/a|na|*oem*|*0123456789*|*123456789*|*xxxxxxxx*) return 1 ;;
    esac
    _first=$(printf '%s' "$_v" | cut -c1)
    _rest=$(printf '%s' "$_v" | tr -d "$_first-")
    [ -n "$_rest" ] || return 1
    return 0
}

_ncz_id=""
_ncz_src=""
for _f in product_uuid product_serial board_serial chassis_serial ; do
    [ -r "$DMI/$_f" ] || continue
    _val=$(cat "$DMI/$_f" 2>/dev/null)
    if _ncz_dmi_ok "$_val" ; then
        _ncz_id="dmi:$_f:$(printf '%s' "$_val" | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')"
        _ncz_src="dmi:$_f"
        break
    fi
done

_ncz_mac_of() {   # print the MAC of interface dir $1 if it is usable
    _m=$(tr 'A-Z' 'a-z' < "$1/address" 2>/dev/null | tr -d ':\r\n ')
    case "$_m" in ''|000000000000|ffffffffffff) return 1 ;; esac
    printf '%s' "$_m"
}
_ncz_is_usb() {   # true if the interface hangs off a USB bus (dock, dongle, iBridge)
    _p=$(readlink -f "$1/device" 2>/dev/null)
    case "$_p" in */usb[0-9]*|*/usb/*) return 0 ;; esac
    return 1
}

if [ -z "$_ncz_id" ] ; then
    # 3. onboard wireless (has a wireless/ or phy80211 entry), non-USB
    for _d in "$NET"/* ; do
        [ -e "$_d/address" ] || continue
        [ -d "$_d/wireless" ] || [ -e "$_d/phy80211" ] || continue
        _ncz_is_usb "$_d" && continue
        _m=$(_ncz_mac_of "$_d") || continue
        _ncz_id="wifi:$_m" ; _ncz_src="onboard-wireless" ; break
    done
fi
if [ -z "$_ncz_id" ] ; then
    # 4. lowest-numbered non-USB, non-virtual NIC
    for _d in "$NET"/* ; do
        [ -e "$_d/address" ] || continue
        _n=${_d##*/}
        case "$_n" in lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*) continue ;; esac
        _ncz_is_usb "$_d" && continue
        case "$(readlink -f "$_d" 2>/dev/null)" in */devices/virtual/*) continue ;; esac
        _m=$(_ncz_mac_of "$_d") || continue
        _ncz_id="nic:$_m" ; _ncz_src="pci-nic" ; break
    done
fi
if [ -z "$_ncz_id" ] ; then
    _ncz_id="random:$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n')$$"
    _ncz_src="random"
fi

_ncz_names="acamar achird acrab acrux acubens adhafera adhara ain alalba albali albireo alchiba alcor alcyone aldhibah alfirk algedi algenib algieba algol algorab alhena alioth aljanah alkaid alkes almaaz alnair alnasl alnilam alnitak alniyat alphard alpherg alrakis alrescha alsafi alshain altair altais aludra alula alya alzirr ancha ankaa anser antares arcturus arkab arneb ascella asellus ashlesha asterope atik atlas atria avior azha azmidi barnard baten beemim beid biham botein brachium canopus capella caph castor castula cebalrai celaeno chalawan chara chertan cor cujam cursa dabih dalim deneb denebola diadem diphda dschubba dubhe dziban edasich electra elgafar elkurud elnath eltanin enif errai fafnir fang fawaris felis fulu furud gacrux giausar gienah ginan gomeisa gorgonea graffias grumium hadar haedus hamal hassaleh hatysa heze homam iklil imai izar jabbah jishui kang kaus keid kitalpha kochab kraz kurhah lesath libertas lich lilii maasym mahasim maia marfik markab markeb marsic matar mebsuta megrez meissa mekbuda menkar menkent menkib merak merga merope mimosa minchir mintaka mira mirach miram mirfak mirzam misam mizar muphrid musica muscida nahn naos nashira nekkar nembus nihal nunki nusakan okab peacock phact phecda pherkad pipirima pleione polaris polis pollux porrima prima procyon propus rana rasalas rastaban regulus revati rigel rotanev ruchbah rukbat sabik sadr saiph salm sargas sarin sceptrum scheat schedar secunda segin seginus sham shaula sheliak sheratan sirius situla skat spica sterope sualocin subra suhail sulafat syrma tabit taiyi talitha tania tarazed tarf taygeta tegmine tejat theemin thuban tiaki titawin tonatiuh torcular tureis vega veritate wasat wazn wezen wurren yed yildun zaniah zaurak zavijava zibal zosma"
_ncz_h=$(printf 'ncz-hostname-v2:%s' "$_ncz_id" | sha256sum | cut -c1-12)
_ncz_cnt=$(printf '%s\n' $_ncz_names | grep -c .)
_ncz_i=$(( 0x$(printf '%s' "$_ncz_h" | cut -c1-6) % _ncz_cnt + 1 ))
_ncz_sd=$(( 0x$(printf '%s' "$_ncz_h" | cut -c7-12) % 10000 ))
_ncz_nm=$(printf '%s\n' $_ncz_names | sed -n "${_ncz_i}p")
_ncz_hn=""
[ -n "$_ncz_nm" ] && _ncz_hn=$(printf 'ncz-%s-%04d' "$_ncz_nm" "$_ncz_sd")
[ -n "$_ncz_hn" ] || _ncz_hn="ncz-$(printf '%s' "$_ncz_h" | cut -c1-6)"

_ncz_unattended=0
for _t in $(cat /proc/cmdline 2>/dev/null) ; do
    case $_t in ncz_components=*) _ncz_unattended=1 ;; esac
done

LOG="${NCZ_EARLY_LOG:-/var/log/early_command.log}"
db_set netcfg/get_hostname "$_ncz_hn"
db_set netcfg/hostname "$_ncz_hn"
if [ "$_ncz_unattended" = 1 ] ; then
    db_fset netcfg/get_hostname seen true
    db_fset netcfg/hostname seen true
    echo "early_command: hostname suggestion $_ncz_hn from $_ncz_src (unattended: ncz_components= on cmdline, not prompting)" >> "$LOG" 2>/dev/null
else
    db_fset netcfg/get_hostname seen false
    db_fset netcfg/hostname seen false
    echo "early_command: hostname suggestion $_ncz_hn from $_ncz_src (prompting; operator may override)" >> "$LOG" 2>/dev/null
fi
exit 0
