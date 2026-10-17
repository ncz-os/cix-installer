#!/bin/bash
# test-t2-wifi-no-unload.sh -- no installer file may unload or unbind brcmfmac
# around suspend. Doing so leaves the T2 BCM4364 in D3cold after resume and
# Wi-Fi is gone until reboot (docs/T2-BRCMFMAC-RESUME.md). The driver recovers
# from its own resume-time firmware crash, so no sleep hook is needed at all.
#
# Each shell command (backslash continuations joined, whole-line # comments dropped, split
# on ; && || | &) is a hit when it names brcmfmac and also carries an unload: modprobe with -r in any
# short-option cluster or --remove, in any position; rmmod; kmod remove; or a
# write to the driver's sysfs unbind/remove. Scope is unload/unbind by name: a
# PCI remove by device path (/sys/bus/pci/devices/<bdf>/remove) has no driver
# name in it, and neither is an unload through a variable (modprobe -r "$m"):
# both are out of reach of a static check.
set -u
cd "$(dirname "$0")/.."
fail=0
scan() {   # stdin: a file; prints "N: line" for every hit
    awk '
    function hit(l,   t) {
        if (l !~ /brcmfmac/) return 0
        if (l ~ /(^|[^[:alnum:]_])rmmod([[:space:]]|$)/) return 1
        if (l ~ /(^|[^[:alnum:]_])kmod([[:space:]]+-[^[:space:]]+)*[[:space:]]+remove([[:space:]]|$)/) return 1
        if (l ~ /brcmfmac[^[:space:]]*\/(unbind|remove)([^[:alnum:]_]|$)/) return 1
        if (l ~ /(^|[^[:alnum:]_])modprobe([[:space:]]|$)/) {
            t = l; sub(/.*(^|[^[:alnum:]_])modprobe([[:space:]]|$)/, " ", t)
            if (t ~ /[[:space:]](-[[:alpha:]]*r[[:alpha:]]*|--remove)([[:space:]]|$)/) return 1
        }
        return 0
    }
    {
        line = $0
        if (cont != "") { line = cont " " line; cont = ""; }
        if (line ~ /\\$/) { sub(/\\$/, "", line); cont = line; next }
        if (line ~ /^[[:space:]]*#/) { start = NR + 1; next }   # whole-line comment
        code = line   # inline "#" is not stripped: it may sit inside quotes, and over-matching only fails safe
        n = split(code, cmd, /;|&&|\|\||\||&/); h = 0
        for (i = 1; i <= n; i++) if (hit(cmd[i])) { h = 1; break }
        if (h) print start ": " cmd[i]
        start = NR + 1
    }
    BEGIN { start = 1 }
    '
}
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
         'true; modprobe -r brcmfmac && echo done' 'echo "T2 resume # note"; modprobe -r brcmfmac'; do
    [ -n "$(printf '%s\n' "$s" | scan)" ] || { echo "FAIL control not caught: $s"; fail=1; }
done
for s in 'modprobe brcmfmac' 'modprobe -q brcmfmac' 'modprobe brcmfmac roamoff=1' \
         '# modprobe -r brcmfmac is forbidden here' 'echo brcmfmac >> /etc/modules-load.d/x.conf' \
         'modprobe --show-depends brcmfmac' \
         'echo blacklist brcmfmac > /etc/modprobe.d/x.conf ; modprobe ext4 ; [ -r /x ] && echo y'; do
    [ -z "$(printf '%s\n' "$s" | scan)" ] || { echo "FAIL control wrongly caught: $s"; fail=1; }
done
[ -f docs/T2-BRCMFMAC-RESUME.md ] || { echo "FAIL docs/T2-BRCMFMAC-RESUME.md missing"; fail=1; }
[ $fail = 0 ] && echo "test-t2-wifi-no-unload: OK"
exit $fail
