#!/bin/sh
# ncz-hostname-gen.sh -- THE NCZ-OS hostname algorithm (one implementation for arm64 and amd64).
#
#   name = ncz-<IAU star name, <= 8 letters>-<4 digit seed>          e.g. ncz-acrab-1717
#   regex ^ncz-[a-z]{1,8}-[0-9]{4}$   (at most 14 characters, a valid DNS label)
#
# The star and the seed both come from sha256("ncz-hostname-v2:" + IDENTITY), where IDENTITY is the
# first usable of, in order:
#   1. DMI product_uuid                 unique per machine (x86, T2 Macs)
#   2. DMI product/board/chassis serial  (T2 serial etc.); placeholder values are rejected
#   3. /etc/machine-id                   present on an installed system, absent in the installer
#   4. the onboard (non-USB) wireless MAC
#   5. the lowest-numbered non-USB, non-virtual NIC MAC
#   6. random                            last resort; callers persist the first answer
# It never reads a USB or dock NIC, so swapping an adapter cannot rename a machine (T2 Mac A and
# T2 Mac B both became ncz-9b4fe9 when one dock moved between them). The identity is hashed, never
# used raw: a hostname is broadcast over DHCP and mDNS.
#
# Usage: ncz-hostname-gen.sh            -> prints the hostname
#        ncz-hostname-gen.sh --source   -> prints "<hostname> <source>"
# Test seams: NCZ_DMI_DIR, NCZ_NET_DIR, NCZ_MACHINE_ID.
DMI="${NCZ_DMI_DIR:-/sys/class/dmi/id}"
NET="${NCZ_NET_DIR:-/sys/class/net}"
MID="${NCZ_MACHINE_ID:-/etc/machine-id}"

# a DMI value is usable if it is non-empty, not a well-known placeholder, and not one repeated
# character (all-zero / all-f UUIDs).
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

_ncz_id=""; _ncz_src=""
for _f in product_uuid product_serial board_serial chassis_serial ; do
    [ -r "$DMI/$_f" ] || continue
    _val=$(cat "$DMI/$_f" 2>/dev/null)
    if _ncz_dmi_ok "$_val" ; then
        _ncz_id="dmi:$_f:$(printf '%s' "$_val" | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')"
        _ncz_src="dmi:$_f"
        break
    fi
done
if [ -z "$_ncz_id" ] && [ -r "$MID" ] ; then
    _v=$(tr -cd '0-9a-f' < "$MID" 2>/dev/null)
    if [ "${#_v}" -ge 16 ] ; then _ncz_id="machine-id:$_v"; _ncz_src="machine-id"; fi
fi
if [ -z "$_ncz_id" ] ; then
    for _d in "$NET"/* ; do
        [ -e "$_d/address" ] || continue
        [ -d "$_d/wireless" ] || [ -e "$_d/phy80211" ] || continue
        _ncz_is_usb "$_d" && continue
        _m=$(_ncz_mac_of "$_d") || continue
        _ncz_id="wifi:$_m"; _ncz_src="onboard-wireless"; break
    done
fi
if [ -z "$_ncz_id" ] ; then
    for _d in "$NET"/* ; do
        [ -e "$_d/address" ] || continue
        _n=${_d##*/}
        case "$_n" in lo|docker*|veth*|virbr*|br-*|tun*|tap*|wg*) continue ;; esac
        _ncz_is_usb "$_d" && continue
        case "$(readlink -f "$_d" 2>/dev/null)" in */devices/virtual/*) continue ;; esac
        _m=$(_ncz_mac_of "$_d") || continue
        _ncz_id="nic:$_m"; _ncz_src="pci-nic"; break
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
_ncz_hn=$(printf 'ncz-%s-%04d' "$_ncz_nm" "$_ncz_sd")
if [ "$1" = "--source" ] ; then
    printf '%s %s\n' "$_ncz_hn" "$_ncz_src"
else
    printf '%s\n' "$_ncz_hn"
fi
