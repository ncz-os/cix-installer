# T2 Wi-Fi (BCM4364, brcmfmac) across suspend/resume

**Status: no workaround shipped, on purpose.** Do not unload or unbind brcmfmac
around suspend on T2 Macs.

## What happens

On some S3 resumes the BCM4364 firmware traps:

    brcmf_fw_crashed: Firmware has halted or crashed
    brcmf_msgbuf_query_dcmd: Timeout on response for query command
    brcmf_cfg80211_get_channel: chanspec failed (-5)

The driver handles this itself. Within about a second it re-requests the
firmware and brings the chip back up:

    brcmf_fw_alloc_request: using brcm/brcmfmac4364b3-pcie for chip BCM4364/4
    brcmf_c_preinit_dcmds: Firmware: BCM4364/4 wl0: ... version 9.30.503.0.32.5.92

NetworkManager then reconnects. Nothing in userspace has to act.

Measured on MEDUSA (MacBookPro16,1, kernel 7.3.0-rc7-t2-ncz), 2026-10-17: six
`systemctl suspend` cycles (rtcwake 60 s), Wi-Fi associated before each. The
firmware crashed on resume in 4 of 6; in all 6 wlan0 was connected again and
`ping -I wlan0` to the gateway lost 0 of 3 packets. The earlier field log
(2026-10-16) shows the same crash followed by the same automatic firmware
reload before `PM: suspend exit`; it never showed Wi-Fi staying down.

## Why not unload the driver around suspend

That was tried (unload in a system-sleep `pre` hook, reload in `post`) and it
breaks Wi-Fi until reboot: with no driver bound, the PCI core let the card go to
D3cold during S3, and on resume

    brcmfmac 0000:05:00.0: Unable to change power state from D3cold to D0, device inaccessible
    brcmf_pcie_probe: failed 14e4:4464

and wlan0 is gone. Removing and rescanning the port does not bring it back.
`modprobe -r brcmfmac_wcc` also takes brcmfmac with it as an unused dependency.

`build/test-t2-wifi-no-unload.sh` fails the build if any hook unloads or unbinds
brcmfmac in a sleep path.

## Upstream

t2linux carries a kernel fix for the crash itself, "wifi: brcmfmac: Improve D3
substate entering timeout handling" (t2linux 781fea140620, 2026-10-13, patch
9003-PATCH-wireless-next-v2-...). It belongs in the T2 kernel series, not here;
until it lands the driver's own recovery covers the crash.
