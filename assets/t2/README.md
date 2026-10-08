# assets/t2 — Forky-native Apple T2 firmware/audio inputs

This directory holds the pinned, licensed, **official-t2linux** inputs that
replace the formerly-wired third-party apt repo
(`adityagarg8.github.io/t2-ubuntu-repo`, a `pending` row in
`manifests/vendor-repos.tsv`). `post-install/55-t2-firmware.sh` installs them
into the target with no apt transaction and no network access.

Rationale: NCZ-OS must not depend on an unapproved Ubuntu-built vendor repo,
and must not invent a vendor approval. Every artifact here traces to a real
upstream commit with a real license and a real file hash (see `SOURCES.tsv`).

## Contents

| path | what | upstream | license |
|---|---|---|---|
| `t2-better-audio/files/` | T2 audio config (ALSA card profile-sets + paths + udev rule) | `github.com/kekrby/t2-better-audio` @ `e46839a28963e2f7d364020518b9dac98236bcae` (mirror: `github.com/t2linux/t2-better-audio`) | MIT (`t2-better-audio/LICENSE`) |
| `firmware-helper/get-apple-firmware` | official t2linux firmware helper tool | `github.com/t2linux/wiki` `docs/tools/firmware.sh` @ `986f5a79d43b75d93d84b8d57bc338853b51a0e0` (served at `wiki.t2linux.org/tools/firmware.sh`) | MIT (license text embedded in the script) |

The WiFi/BT firmware **blobs** are not here: they are the already-staged
`assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz` (128 Apple
brcmfmac board files, extracted once from the macOS Sonoma 14 Recovery Image;
provenance recorded there). `55-t2-firmware.sh` extracts that tarball and
treats a missing tarball as a hard error.

## Why `t2-better-audio`, not `apple-t2-audio-config` 0.5.x

The old hook apt-installed `apple-t2-audio-config` from the third-party repo
(newest = `0.5.1`, ALSA UCM2 `AppleT2/HiFi-x{2,4,6}.conf`). Investigation
(2026-10-08) found those exact UCM2 bytes have **no upstream repository and no
declared license** — they exist only inside that repo's deb. The officially
documented T2 audio-config source (t2linux wiki → `kekrby/t2-better-audio`,
MIT) instead ships `alsa-card-profile` profile-sets, and the *earlier*
`apple-t2-audio-config 0.4.2` deb was byte-for-byte that MIT content. This
directory carries the MIT content, which is the license-clean, reproducible
replacement.

**Review note:** this is a config-style change (UCM2 → card-profile
profile-sets). The t2linux wiki documents that profile vs. UCM: if hardware
validation shows the `AppleT2xN` card needs the UCM2 layout specifically, the
options are (a) author an in-tree NCZ UCM2 config (not a re-licensing of the
unlicensed blob), or (b) have the operator approve the third-party repo as an
explicit exception. Do not silently restore the unlicensed bytes.

## Hardware gates — NOT ready to ship

Functional equivalence of every T2 input below is **unproven**; the sandbox
tests exercise the install contract only (file layout, sha256 refusal,
hardlink preservation, loud failure), never a real AppleT2xN sound card or a
real brcmfmac radio. Before any image is accepted, each of the four paths needs
a real-T2-Mac (MEDUSA) run:

| # | path | what must be observed on hardware |
|---|---|---|
| 1 | WiFi firmware (Apple `brcmfmac*.apple,*.bin` blobs) | `wlan0` enumerates, associates, passes traffic |
| 2 | Bluetooth firmware (`*apple,*.ptb` blobs) | `bluetoothctl` sees the controller and pairs |
| 3 | audio config (`t2-better-audio` card-profile profile-sets + udev rule) | speakers, headphones, headset-mic and built-in mic all work (the UCM2→profile-sets style change is the specific risk) |
| 4 | `get-apple-firmware` helper | the installed `/usr/bin/get-apple-firmware` runs on a model whose chip variant the staged set does not cover |

This worktree makes **no** MEDUSA live-audio change and infers **no** reboot
permission; the hardware run is a separate, operator-scheduled gate.

The older MIT `kekrby/t2-better-audio` profile-sets are the **only candidate**
carried here; the former 0.5.1 UCM2 bytes are unlicensed and are not restored.

## Reproducing

```
# t2-better-audio @ e46839a2
git clone https://github.com/kekrby/t2-better-audio && (cd t2-better-audio && git checkout e46839a28963e2f7d364020518b9dac98236bcae)
cp -a t2-better-audio/files assets/t2/t2-better-audio/files
cp    t2-better-audio/LICENSE assets/t2/t2-better-audio/LICENSE

# get-apple-firmware @ 986f5a79
git clone https://github.com/t2linux/wiki && (cd wiki && git checkout 986f5a79d43b75d93d84b8d57bc338853b51a0e0)
cp wiki/docs/tools/firmware.sh assets/t2/firmware-helper/get-apple-firmware
```

`build/test-t2-native.sh` re-checks every hash in `SOURCES.tsv` and that the
hook no longer references the third-party repo or apt.
