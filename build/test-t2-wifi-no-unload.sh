#!/bin/bash
# test-t2-wifi-no-unload.sh -- no installer hook may unload or unbind brcmfmac
# around suspend. Doing so leaves the T2 BCM4364 in D3cold after resume and
# Wi-Fi is gone until reboot (docs/T2-BRCMFMAC-RESUME.md). The driver recovers
# from its own resume-time firmware crash, so no sleep hook is needed at all.
set -u
cd "$(dirname "$0")/.."
fail=0
pat='(modprobe[[:space:]]+-r|rmmod)[^#]*brcmfmac|brcmfmac[^#]*/(unbind|remove)'
# Per file, so the line prefix is just N: (a file name may contain a colon).
hits=$(grep -rlE "$pat" post-install preseed assets 2>/dev/null | while IFS= read -r f; do
    grep -nE "$pat" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|"
done)
if [ -n "$hits" ]; then
    echo "FAIL brcmfmac is unloaded/unbound by an installer file:"; echo "$hits"; fail=1
fi
# Negative control: the pattern must catch the shape that broke Wi-Fi.
for s in 'modprobe -r brcmfmac' 'rmmod brcmfmac_wcc' 'echo 0000:05:00.0 > /sys/bus/pci/drivers/brcmfmac/unbind'; do
    printf '%s\n' "$s" | grep -qE "$pat" || { echo "FAIL pattern misses: $s"; fail=1; }
done
printf '%s\n' '# modprobe -r brcmfmac is forbidden here' | grep -vE '^[[:space:]]*#' | grep -qE "$pat" \
    && { echo "FAIL comment lines must not count"; fail=1; }
[ -f docs/T2-BRCMFMAC-RESUME.md ] || { echo "FAIL docs/T2-BRCMFMAC-RESUME.md missing"; fail=1; }
[ $fail = 0 ] && echo "test-t2-wifi-no-unload: OK"
exit $fail
