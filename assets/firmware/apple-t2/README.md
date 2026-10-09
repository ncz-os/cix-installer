# assets/firmware/apple-t2 — Forky-native Apple T2 firmware blobs

The pre-extracted Sonoma 14 firmware tarball staged here is the **only**
WiFi/BT firmware source `post-install/55-t2-firmware.sh` consumes; the hook
treats a missing tarball as a hard error and refuses to fabricate a per-install
Apple CDN fetch (the old quiet fallback is gone).

| field | value |
|---|---|
| file | `apple-t2-firmware-sonoma14.tar.xz` |
| size | 2.6 MiB (compressed) |
| sha256 | `78810308c304eb999555b90de5debba7ad77eebe4614327a7539efe385e1e72a` |
| provenance | extracted once from a genuine Apple macOS Sonoma 14 Recovery Image |
| members | 128 brcmfmac / brcmbt files (~13 chip+board combos) |
| installed by | `post-install/55-t2-firmware.sh` via the staged-tarball path |
| consumed by | Debian-Installer initrd at install time via `build/iso/patch-initrd-firmware.py` |
| license | Apple macOS firmware EULA (Apple-distributed; per-machine, not for general redistribution) |

The sha256 is also pinned in `post-install/55-t2-firmware.sh` as
`NCZ_T2_FW_SHA256` and re-checked at install time, so a swapped/tampered archive
is refused **before** any host mutation.

## Board coverage

The tarball contains the Apple firmware files for the board names below. Each
appears in `/lib/firmware/brcm/` as `brcmfmac<chip>-pcie.apple,<board>.bin`
(WiFi) and / or `brcmbt<chip><stepping>-apple,<board>-{m,u}.{bin,ptb}`
(Bluetooth) after extraction by the hook.

| board name | chip / stepping | kind |
|---|---|---|
| formosa | BCM4377B3 | BT (and a WiFi `brcmfmac4377b3` profile) |
| atlantisb | BCM4378B1 | BT |
| capri | BCM4378B1 | BT |
| honshu | BCM4378B1 | BT |
| santorini | BCM4378B1 | BT |
| shikoku | BCM4378B1 | BT |
| kyushu | BCM4378B3 | BT |
| hokkaido | BCM4387C2 | BT |
| madagascar | BCM4387C2 | BT |
| maldives | BCM4387C2 | BT |
| okinawa | BCM4387C2 | BT |
| snake | BCM4387C2 | BT |
| willamette | BCM4388B0 / BCM4388C0 | BT |
| hawaii | BCM4355C1 | WiFi (older MBP15,1) |
| ekans / hanauma / kauai / lanai / maui / midway / nihau | BCM4364B2 | WiFi |
| bali / borneo / hanauma / kahana / kure / trinidad | BCM4364B3 | WiFi (trinidad ALSO has BT, see below) |
| fiji / formosa / tahiti | BCM4377B3 | WiFi |

## Coverage gap (BCM4364B3 "Trinidad Olympic GEN" Bluetooth)

The `BCM4364B3` chip has **WiFi** firmware in the tarball (`brcmfmac4364b3-
pcie.apple,trinidad.bin/.clm_blob/.txcap_blob/.txt`), but it has **no
Bluetooth** firmware — the Sonoma 14 image never shipped a BT variant for that
chip, so neither does this tarball. (For confirmation: the tarball's BT
files are `brcmbt<chip>-apple,<board>[-<m/u>].ptb`; there is no
`brcmbt4364b3-apple,trinidad*.ptb` of either vendor shape.)

The board is also not in the in-kernel chip-id table of the `hci_uart_bcm`
driver on the current 7.3.0-rc6-t2-ncz branch, so even if the matching .ptb
were present, the driver would fall back to looking for the generic
`brcm/BCM.hcd`. Audit snapshot from a real `MacBookPro16,1` in the kernel
audit at `../ncz-r201-resolution-evidence-20261008/kernel-audit/MEDUSA_192.168.207.38/raw_*.log`:

```
Bluetooth: hci0: BCM: chip id 150
Bluetooth: hci0: BCM4364B3 Trinidad Olympic GEN (MFG)
Bluetooth: hci0: BCM (001.016.050) build 0082
Bluetooth: hci0: BCM: firmware Patch file not found, tried:
Bluetooth: hci0: BCM: 'brcm/BCM.hcd'
Bluetooth: hci0: HCI Read Transmit Power Level command is advertised, but not supported.
```

## The right recovery (operator-led; NO symlink shortcut)

The hook installs the official t2linux wiki helper at `/usr/bin/get-apple-firmware`
(MIT, pinned in `assets/t2/SOURCES.tsv` at commit `986f5a79d43b75d93d84b8d57bc338853b51a0e0`).
For a Mac whose BCM chip the staged set does not cover, the single correct
next step is to run that helper from a Linux session with internet, which
extracts firmware from the user's macOS install (or the Apple CDN recovery
image) and feeds it to `brcm/`:

```bash
sudo /usr/bin/get-apple-firmware get_from_macos   # if dual-booting macOS
sudo /usr/bin/get-apple-firmware get_from_online  # macOS recovery image (larger)
```

The hook's tail (after a successful extract) prints this exact recovery command
on MacBookPro16,1 / 16,2 and iMac20,1 / 20,2 — see the "MacBookPro16,1 hook"
case in `build/test-t2-native.sh`.

## Filename shapes (a parser quirk worth knowing)

The Bluetooth staging inventory in `post-install/55-t2-firmware.sh` accepts
two filename shapes:

1. `brcmbt<chip><stepping>-apple,<board>.{bin,ptb}` — no vendor suffix (e.g.
   the BCM4377B3 "Formosa" BT files: `brcmbt4377b3-apple,formosa.ptb`).
2. `brcmbt<chip><stepping>-apple,<board>-{m,u}.{bin,ptb}` — with vendor
   suffix (MUR/MT or USI).

A literal `,` inside a glob pattern is parsed as list-union by `bash`
(versions as new as 5.3). The hook uses `brcmbt*apple*.ptb` (no literal `,`)
and parameter expansion `${bn#brcmbt*-apple,}` to recognise both shapes;
the bug-for-bug with bash 3.2 on macOS Studio is documented inline.

## Why this hook does NOT install `brcm/BCM.hcd → …` symlinks

The MEDUSA prompt explicitly forbids a blind symlink alias (e.g. `BCM.hcd` →
`brcmbt4377b3-apple,formosa.ptb`). Three independent reasons:

1. **Per-chip rev matching.** `hci_uart_bcm` matches firmware by chip-id +
   board-rev, not by filename. A wrong-board symlink would still print
   "firmware Patch file not found" (with a slightly different tried list) and
   give the appearance of progress without it.
2. **Patchram loader invariants.** The Apple BCM patchram program length and
   init vector differ per chip; loading an incompatible binary can leave the
   UART transport in a half-initialised state that survives a reboot.
3. **Diagnostic hygiene.** The "BCM.hcd tried" line is the kernel's only
   signal that the *real* fault is a missing chip-id entry. Aliasing over it
   breaks the signal and silently regresses to a generic "no firmware"
   message that the operator can no longer disambiguate.

`build/test-t2-native.sh` asserts the no-symlink contract and exercises the
conditional recovery hint.

## Independent kernel-side noise (NOT a fix target)

`Bluetooth: hci0: HCI Read Transmit Power Level command is advertised, but
not supported.` is independent, harmless noise: Apple firmware advertises the
HCI command but the BCM ROM stubs the handler. The kernel logs the warning
because the command bit is set; it does not cause BT bring-up to fail. We do
not suppress it (per scope: never suppress a warning that is not a diagnosed
optional unsupported capability with source evidence; this one is
kernel-internal and not optional).

The `brcmf_p2p_set_firmware` returns -52 (-EBUSY) symptom belongs to the
separate AMD64 kernel followup (`docs branch followup/amd64-kernel-audit-
20261008`) — it is unrelated to this installer source. The MEDUSA log does
not reproduce it on the audited snapshot.
