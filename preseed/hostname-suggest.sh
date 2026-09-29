#!/bin/sh
# hostname-suggest.sh -- NCZ installer hostname SUGGESTION, run from
# preseed/early_command via _ncz_helper (baked at /ncz/hostname-suggest.sh).
#
# This logic used to be inlined in preseed.cfg's early_command. That pushed the
# joined command past what cdebconf can hand back through `db_get`: with the
# inline block early_command was 15,634 bytes and /bin/preseed_command died in
# confmodule (`return: line 88: Illegal number`, the same "return \"\" after EOF"
# class component-selector.sh documents), early_command never ran, the ext4
# medium was never mounted at /cdrom, and d-i stopped at "Incorrect installation
# media detected" -- on arm64 (2026-09-29). With the block removed (12.4 KB) the
# same image installs. Keep early_command small: put logic in helpers.
# build/check-early-command-size.sh enforces the budget.
#
# Input: $PICKED_IF (the wired NIC early_command selected), falling back to
# /tmp/.ncz-picked-if. Output: netcfg/get_hostname and netcfg/hostname seeded to
# ncz-<star>-<nnnn>, derived from that NIC's MAC. Unattended installs (an
# ncz_components= token on the kernel command line) mark the questions seen so
# nothing prompts; interactive installs show the suggestion for the operator to
# override.
. /usr/share/debconf/confmodule 2>/dev/null || . /usr/lib/cdebconf/confmodule 2>/dev/null || true
command -v db_set >/dev/null 2>&1 || exit 0
PICKED_IF="${PICKED_IF:-}"
[ -n "$PICKED_IF" ] || { [ -s /tmp/.ncz-picked-if ] && PICKED_IF=$(cat /tmp/.ncz-picked-if) ; }
_ncz_unattended=0 ; for _t in $(cat /proc/cmdline) ; do case $_t in ncz_components=*) _ncz_unattended=1 ;; esac ; done ;
_ncz_hn="" ;
if [ -n "$PICKED_IF" ] && [ -r "/sys/class/net/$PICKED_IF/address" ] ; then
    _ncz_mac=$(tr -d ':' < "/sys/class/net/$PICKED_IF/address" | tr 'A-F' 'a-f') ;
    _ncz_names="acamar achird acrab acrux acubens adhafera adhara ain alalba albali albireo alchiba alcor alcyone aldhibah alfirk algedi algenib algieba algol algorab alhena alioth aljanah alkaid alkes almaaz alnair alnasl alnilam alnitak alniyat alphard alpherg alrakis alrescha alsafi alshain altair altais aludra alula alya alzirr ancha ankaa anser antares arcturus arkab arneb ascella asellus ashlesha asterope atik atlas atria avior azha azmidi barnard baten beemim beid biham botein brachium canopus capella caph castor castula cebalrai celaeno chalawan chara chertan cor cujam cursa dabih dalim deneb denebola diadem diphda dschubba dubhe dziban edasich electra elgafar elkurud elnath eltanin enif errai fafnir fang fawaris felis fulu furud gacrux giausar gienah ginan gomeisa gorgonea graffias grumium hadar haedus hamal hassaleh hatysa heze homam iklil imai izar jabbah jishui kang kaus keid kitalpha kochab kraz kurhah lesath libertas lich lilii maasym mahasim maia marfik markab markeb marsic matar mebsuta megrez meissa mekbuda menkar menkent menkib merak merga merope mimosa minchir mintaka mira mirach miram mirfak mirzam misam mizar muphrid musica muscida nahn naos nashira nekkar nembus nihal nunki nusakan okab peacock phact phecda pherkad pipirima pleione polaris polis pollux porrima prima procyon propus rana rasalas rastaban regulus revati rigel rotanev ruchbah rukbat sabik sadr saiph salm sargas sarin sceptrum scheat schedar secunda segin seginus sham shaula sheliak sheratan sirius situla skat spica sterope sualocin subra suhail sulafat syrma tabit taiyi talitha tania tarazed tarf taygeta tegmine tejat theemin thuban tiaki titawin tonatiuh torcular tureis vega veritate wasat wazn wezen wurren yed yildun zaniah zaurak zavijava zibal zosma" ;
    _ncz_h=$(printf '%s' "$_ncz_mac" | sha256sum | cut -c1-12) ;
    _ncz_cnt=$(printf '%s\n' $_ncz_names | grep -c .) ;
    _ncz_i=$(( 0x$(printf '%s' "$_ncz_h" | cut -c1-6) % _ncz_cnt + 1 )) ;
    _ncz_sd=$(( 0x$(printf '%s' "$_ncz_h" | cut -c7-12) % 10000 )) ;
    _ncz_nm=$(printf '%s\n' $_ncz_names | sed -n "${_ncz_i}p") ;
    [ -n "$_ncz_nm" ] && _ncz_hn=$(printf 'ncz-%s-%04d' "$_ncz_nm" "$_ncz_sd") ;
    [ -n "$_ncz_hn" ] || _ncz_hn="ncz-$(printf '%s' "$_ncz_mac" | tail -c 6)" ;
fi ;
if [ -n "$_ncz_hn" ] && command -v db_set >/dev/null 2>&1 ; then
    db_set netcfg/get_hostname "$_ncz_hn" ; db_set netcfg/hostname "$_ncz_hn" ;
    if [ "$_ncz_unattended" = 1 ] ; then
        db_fset netcfg/get_hostname seen true ; db_fset netcfg/hostname seen true ;
        echo "early_command: hostname suggestion $_ncz_hn (unattended: ncz_components= on cmdline, not prompting)" >> /var/log/early_command.log ;
    else
        db_fset netcfg/get_hostname seen false ; db_fset netcfg/hostname seen false ;
        echo "early_command: hostname suggestion $_ncz_hn (prompting; operator may override)" >> /var/log/early_command.log ;
    fi ;
fi ;
