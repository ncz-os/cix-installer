#!/bin/bash
# test-t2-wifi-no-unload.sh -- no installer file may unload or unbind brcmfmac
# around suspend. Doing so leaves the T2 BCM4364 in D3cold after resume and
# Wi-Fi is gone until reboot (docs/T2-BRCMFMAC-RESUME.md). The driver recovers
# from its own resume-time firmware crash, so no sleep hook is needed at all.
#
# A shell command (backslash continuations joined, whole-line # comments
# dropped, "#" and ; && || | & ending a command) is a hit when it names
# brcmfmac and carries an unload -- modprobe with -r in any short-option
# cluster or --remove, in any position; rmmod; kmod remove/--remove -- or when
# it writes the driver's sysfs unbind/remove: the absolute
# /sys/bus/.../drivers/brcmfmac{,_wcc}/ path, or a "<dev>/driver/unbind" write
# in an instruction that reads a wireless interface (readlink .../device).
# That second shape is how preseed.cfg used to unbind it while this check said
# OK; the files scanned are every file naming brcmfmac, not just *.sh.
# What a static, name-based check still cannot see, stated rather than implied:
#   * a PCI *device* unload (echo 1 > /sys/bus/pci/devices/<bdf>/remove) --
#     no driver name and no driver-relative path on the line;
#   * an unload through a variable/alias the scanner cannot resolve
#     (modprobe -r "$m", kmod -r), and --remove=<mod>.
set -u
cd "$(dirname "$0")/.."
fail=0
scan() {   # stdin: a file; prints "N: line" for every hit
    awk '
    function hit(l) {
        if (l ~ /brcmfmac/) {
            if (l ~ /(^|[^[:alnum:]_])rmmod([[:space:]]|$)/) return 1
            if (l ~ /(^|[^[:alnum:]_])kmod([[:space:]]+-[^[:space:]]+)*[[:space:]]+(remove|--remove)([[:space:]]|$)/) return 1
            if (l ~ /(^|[^[:alnum:]_])modprobe([[:space:]]|$)/) {
                t = l; sub(/.*(^|[^[:alnum:]_])modprobe([[:space:]]|$)/, " ", t)
                if (t ~ /[[:space:]](-[[:alpha:]]*r[[:alpha:]]*|--remove)([[:space:]]|$)/) return 1
            }
        }
        # An absolute path names the driver itself.
        if (l ~ /\/drivers\/brcmfmac(_wcc)?\/(unbind|remove)([^[:alnum:]_]|$)/) return 1
        return 0
    }
    # A write to <dev>/driver/unbind unbinds whichever driver is bound to that
    # device: the path names no driver, and the line that reads the device
    # (readlink .../device) is usually a different command of the same
    # instruction. Judged per instruction, so an xhci-hcd/hub rebind in a
    # command that never touches a wireless interface stays clean.
    function wl_unbind(t) {
        if (t !~ /\/driver\/(unbind|remove)([^[:alnum:]_]|$)/) return 0
        return t ~ /wireless|wlan|phy80211|readlink/
    }
    # One shell command may run over several physical lines (joined "\"
    # continuations): match the joined text, report the raw lines.
    function flush(   i) {
        if (joined == "") return
        n = split(joined, cmd, /;|&&|\|\||\||&|#/)
        if (wl_unbind(joined)) { print raw; return }
        for (i = 1; i <= n; i++) if (hit(cmd[i])) { print raw; return }
    }
    {
        line = $0
        if (cont == "" && line ~ /^[[:space:]]*#/) { flush(); next }
        if (cont != "") { raw = raw "\n" line } else { raw = NR ": " line }
        if (joined == "") joined = line; else joined = joined " " line
        if (line ~ /\\$/) {
            sub(/\\$/, "", line)
            sub(/\\$/, "", joined)
            cont = line; next
        }
        flush()
        cont = ""; joined = ""
    }
    END { flush() }
    '
}
# Every installer file that names brcmfmac, whatever its extension: the
# unbind that actually shipped was in preseed/preseed.cfg, not a .sh.
hits=$(grep -rlE 'brcmfmac' post-install preseed assets 2>/dev/null | while IFS= read -r f; do
    scan < "$f" | sed "s|^|$f:|"
done)
if [ -n "$hits" ]; then
    echo "FAIL brcmfmac is unloaded/unbound by an installer file:"; echo "$hits"; fail=1
fi
# Controls: every unload shape must be caught, every load must not be.
for s in 'modprobe -r brcmfmac' 'modprobe --remove brcmfmac' 'modprobe -q -r brcmfmac_wcc brcmfmac' \
         'modprobe -rv brcmfmac' 'modprobe brcmfmac -r' '/sbin/modprobe -r brcmfmac' 'rmmod brcmfmac_wcc' \
         'kmod remove brcmfmac' 'kmod -q remove brcmfmac' 'kmod --quiet remove brcmfmac' 'modprobe -r brcmfmac # trailing comment' \
         'echo 0000:05:00.0 > /sys/bus/pci/drivers/brcmfmac/unbind' $'modprobe -r \\\n    brcmfmac' \
         'true; modprobe -r brcmfmac && echo done' 'echo "T2 resume # note"; modprobe -r brcmfmac' $'# note \\\nmodprobe -r brcmfmac' \
         'kmod --remove brcmfmac' 'echo 1 > /sys/bus/pci/drivers/brcmfmac/remove' \
         '_wdev=$(readlink -f /sys/class/net/wlan0/device); echo 1 > "$_wdev/driver/unbind"' \
         'for _if in /sys/class/net/*; do _w=$(readlink -f "$_if/device"); echo 1 > "$_w/driver/unbind"; done'; do
    [ -n "$(printf '%s\n' "$s" | scan)" ] || { echo "FAIL control not caught: $s"; fail=1; }
done
for s in 'modprobe brcmfmac' 'modprobe -q brcmfmac' 'modprobe brcmfmac roamoff=1' \
         '# modprobe -r brcmfmac is forbidden here' 'echo brcmfmac >> /etc/modules-load.d/x.conf' \
         'modprobe --show-depends brcmfmac' 'echo hello > /tmp/brcmfmac_something/unbind' \
         'echo 0000:05:00.0 > "$DRV/unbind"  # DRV=/sys/bus/platform/drivers/xhci-hcd' \
         'echo "$(basename "$i")" > "$HUBDRV/unbind"  # hub' \
         'kmod list brcmfmac' 'echo blacklist brcmfmac > /etc/modprobe.d/x.conf ; modprobe ext4 ; [ -r /x ] && echo y'; do
    [ -z "$(printf '%s\n' "$s" | scan)" ] || { echo "FAIL control wrongly caught: $s"; fail=1; }
done
[ -f docs/T2-BRCMFMAC-RESUME.md ] || { echo "FAIL docs/T2-BRCMFMAC-RESUME.md missing"; fail=1; }
[ $fail = 0 ] && echo "test-t2-wifi-no-unload: OK"
exit $fail
