# Stability Sweep 4 - Bootloader and Kernel Staging - 2026-05-08

## Executive summary

- Verdict: high-severity boot staging gaps were present around initrd ownership and kernel asset mismatch handling.
- Patched in-place: 3 HIGH fixes in `post-install/10-our-kernel.sh`, `post-install/70-bootloader.sh`, and `post-install/80-npu.sh`; no commit made.
- Counts: HIGH 3, MEDIUM 6, LOW 5.
- Current code does not match the brief's `ncz-*.conf` / LTS-default names; it writes `cixmini-*` entries and defaults to NEXT when present.
- Asset verification is incomplete in this checkout: `assets/kernel/` contains only `.gitkeep`; kernel, firmware, and NPU blobs are gitignored build-time payloads.

## HIGH findings

### H1 - Initrd generation was owned by an optional hook, while bootloader entries could omit initrd

File: `post-install/10-our-kernel.sh:47`, `post-install/10-our-kernel.sh:108`, `post-install/70-bootloader.sh:177`, `post-install/70-bootloader.sh:196`

Root cause: `10-our-kernel.sh` installed kernel images and modules, ran `depmod`, and stopped. The only `update-initramfs -c -k ...` path lived in `80-npu.sh`, which is a Phase 2 optional hook and runs under `set +e`. If `80-npu.sh` was skipped, failed, hardcoded the wrong kernel version, or lacked assets, `70-bootloader.sh` previously wrote kernel entries without initrd lines.

Why HIGH: first-boot storage/display/recovery behavior depended on an optional NPU hook. Even if the current Sky1 kernel can sometimes boot without initrd, this is an unsafe installer contract and violates the requested kernel staging invariant.

Concrete diff applied:

- `10-our-kernel.sh` now installs `initramfs-tools` with `kmod`.
- `10-our-kernel.sh` now runs `update-initramfs -c/-u -k "$kver"` for each installed NCZ kernel and fails if `/boot/initrd.img-$kver` is missing or empty.
- `70-bootloader.sh` now refuses to stage a loader entry for any present kernel without a non-empty matching initrd.

### H2 - NEXT sidecar could silently degrade to LTS-only

File: `post-install/10-our-kernel.sh:135`

Root cause: when `KVER_NEXT` existed but `assets/kernel/next/Image-cixmini.bin` or `modules-cixmini.tgz` was missing, the prior hook fell into the generic "BETA kernel not present" branch and continued. That masks corrupt or incomplete dual-kernel payloads.

Why HIGH: the system can appear to ship a dual-kernel LTS+NEXT payload while actually installing only one side. That removes the expected test/dev slot and makes bootloader defaults/fallbacks depend on accidental asset presence.

Concrete diff applied:

- If `KVER_NEXT` is set, `10-our-kernel.sh` now requires both NEXT image and modules assets and exits non-zero if either is missing.
- Missing NEXT is still allowed only when the `KVER_NEXT` sidecar itself is absent, which matches the explicit netinstall/full-thin payload distinction.

### H3 - NPU hook hardcoded kernel versions and `/cdrom` asset path

File: `post-install/80-npu.sh:30`, `post-install/80-npu.sh:37`, `post-install/80-npu.sh:64`, `post-install/80-npu.sh:85`, `post-install/80-npu.sh:102`

Root cause: `80-npu.sh` used fixed `6.18.26-cix-sky1-lts` and `7.0.3-cix-sky1-next` strings and read assets only from `/cdrom/cixmini/assets/npu`. That path is not the canonical copied payload path used by the other hooks, and it is especially fragile in netinstall mode.

Why HIGH: before H1, this version drift could also suppress initrd generation. Even after H1, it could install no NPU module or SSDT for a valid staged kernel because the actual KVER sidecars changed.

Concrete diff applied:

- `80-npu.sh` now reads `KVER_LTS` and `KVER_NEXT` from `/usr/local/lib/cix-installer`.
- It now prefers `/usr/local/lib/cix-installer/assets/npu` and only falls back to `/cdrom/cixmini/assets/npu`.
- It loops over the staged sidecar versions instead of hardcoded LTS/NEXT strings.

## MEDIUM findings

### M1 - Actual loader entry names and default do not match this sweep brief

File: `post-install/70-bootloader.sh:6`, `post-install/70-bootloader.sh:270`, `post-install/70-bootloader.sh:334`, `post-install/70-bootloader.sh:367`

Root cause: the brief says to verify `ncz-lts.conf`, `ncz-next.conf`, and `ncz-safe.conf`, with LTS default. Current code writes `cixmini-lts.conf`, `cixmini-next+3-0.conf`, and `cixmini-rescue.conf`, and sets `default cixmini-next*` whenever NEXT exists.

Concrete diff: no code change applied because current r75/r78 comments and netinstall mode say NEXT default is intentional. Either update the release/test brief to the `cixmini-*` NEXT-default contract, or explicitly flip `DEFAULT_ENTRY` to `cixmini-lts` for full/thin and update the netinstall exception.

### M2 - Fallback is boot-counting, not a `default-fallback` config

File: `post-install/70-bootloader.sh:264`, `post-install/70-bootloader.sh:356`

Root cause: systemd-boot does not have a separate `default-fallback` key in `loader.conf`. The implemented fallback is a boot-counted NEXT entry (`cixmini-next+3-0.conf`) plus an uncounted LTS entry. After failed NEXT attempts, systemd-boot should prefer non-bad entries, but this is not a full A/B slot system.

Concrete diff: add a comment and diagnostic test that explicitly names this as "boot-counted NEXT with LTS fallback", not "A/B". Do not redesign into full slots unless a future component already introduces stateful slot metadata.

### M3 - ESP free-space failure is still late and destructive

File: `post-install/70-bootloader.sh:101`, `post-install/70-bootloader.sh:183`, `post-install/70-bootloader.sh:202`

Root cause: the hook wipes existing loader entries and kernel copies before staging the new images and initrds. If the ESP is too small or full, `install` fails under `set -e`, but the ESP may already have had its previous entries removed.

Concrete diff: before the wipe, calculate required bytes for all `/boot/vmlinuz-$KVER*` and `/boot/initrd.img-$KVER*`, compare against `df -Pk /boot/efi`, and fail before deleting entries unless there is enough free space or enough reclaimable NCZ-owned space. Keep the current hard failure; add the preflight to make it graceful.

### M4 - Firmware hook treats missing Sky1 firmware as success

File: `post-install/12-sky1-firmware.sh:19`

Root cause: `12-sky1-firmware.sh` is a required Phase 1 hook, but missing or empty firmware assets only emit a warning and exit 0. That makes GPU/DSP/VPU/WiFi firmware absence invisible to the installer result.

Concrete diff: if the build mode expects firmware assets, exit non-zero when `/usr/local/lib/cix-installer/assets/sky1-firmware` is absent or empty. If a no-firmware mode is intentional, add a sidecar such as `ALLOW_MISSING_SKY1_FIRMWARE=1` and log it.

### M5 - `cix-noe-umd` Python 3.13 recovery is outside `80-npu.sh`

File: `post-install/80-npu.sh:160`, `post-install/25-cix-ppa.sh:43`, `post-install/25-cix-ppa.sh:73`

Root cause: the sweep brief asks for `80-npu.sh` verification of `cix-noe-umd` 2.0.2 and the Python 3.13 postinst patch. Current ownership is split: `25-cix-ppa.sh` installs `cix-noe-umd` and patches the failing pip/libnoe stanza, while `80-npu.sh` installs kernel-side NPU pieces and writes a doc that still tells the operator to install userspace manually.

Concrete diff: keep the package install in `25-cix-ppa.sh`, but update `80-npu.sh` status text to reflect actual ownership and add a post-hook check for `libnoe.so`/`dpkg-query cix-noe-umd` only if the package was expected to be present.

### M6 - `/etc/fstab` generation can leave ESP unmounted on first boot without failing install

File: `post-install/34-fstab.sh:18`, `post-install/34-fstab.sh:39`

Root cause: `34-fstab.sh` exits 0 when UUID derivation fails, leaving `/etc/fstab` unchanged and warning that `/boot/efi` may not mount. First boot can still work because firmware reads the ESP directly, but future kernel/bootloader updates can write into an unmounted `/boot/efi` directory.

Concrete diff: once `70-bootloader.sh` has validated `/boot/efi` as vfat, make missing fstab UUIDs fatal or have `70-bootloader.sh` verify that `/etc/fstab` contains the ESP UUID before it exits.

## LOW findings + recommendations

### L1 - Local asset inventory cannot verify the requested payload

File: `assets/kernel/.gitkeep:1`, `.gitignore:30`

Root cause: the repo intentionally gitignores `assets/kernel/lts/` and `assets/kernel/next/`. This checkout contains no `KVER`, `Image-cixmini.bin`, `modules-cixmini.tgz`, or headers tarballs under `assets/kernel/`.

Recommendation: add a generated manifest artifact to each bake, for example `assets/kernel/MANIFEST.sha256` in the ISO payload and a matching copy in build logs. The hook logic is now stricter, but this audit cannot confirm blob presence from the repo alone.

### L2 - Firmware copy is idempotent but not update-idempotent

File: `post-install/12-sky1-firmware.sh:26`

Root cause: `cp -rn` preserves existing files on rerun. That avoids clobbering local changes, but it also means a repaired firmware payload will not replace stale or bad blobs already on the target.

Recommendation: for appliance installs, use an NCZ-owned manifest and replace files listed in that manifest on rerun. Keep local-preservation only for unknown files.

### L3 - Firmware zstd decompression counter is ineffective

File: `post-install/12-sky1-firmware.sh:57`

Root cause: `DECOMPRESSED=0` is incremented inside a pipeline-fed `while` loop, so the parent shell never sees the increment. The current log prints a generic message, not the count.

Recommendation: use process substitution (`while ...; done < <(find ...)`) or remove the unused counter entirely.

### L4 - Re-running bootloader resets NEXT boot-count state

File: `post-install/70-bootloader.sh:101`, `post-install/70-bootloader.sh:270`

Root cause: rerun wipes all entry files and rewrites `cixmini-next+3-0.conf`. If a target had already marked NEXT bad, a manual rerun gives NEXT another three attempts.

Recommendation: acceptable for install-time reruns, but document it. If field recovery reruns are common, detect existing `cixmini-next+0-*.conf` or `*.bad` state and default to LTS for that rerun.

### L5 - Bootloader comments still contain stale "LTS default" text

File: `post-install/70-bootloader.sh:218`, `post-install/80-npu.sh:141`

Root cause: comments/status docs still describe LTS as default or NEXT as opt-in in places, while `loader.conf` defaults to `cixmini-next*` when NEXT exists.

Recommendation: update comments and `/usr/share/doc/ncz/NPU-STATUS.md` text to match the actual NEXT-default-with-LTS-fallback behavior, or flip the default if the brief is authoritative.

## Test plan

Run these from the installer shell before reboot, adjusting `/target` only where the command is outside `in-target`.

1. Verify payload sidecars and installed kernels:

```bash
cat /target/usr/local/lib/cix-installer/KVER_LTS 2>/dev/null || true
cat /target/usr/local/lib/cix-installer/KVER_NEXT 2>/dev/null || true
ls -lh /target/boot/vmlinuz-* /target/boot/initrd.img-*
find /target/usr/lib/modules -maxdepth 2 -name modules.dep -o -name modules.alias
```

2. Verify initrd generation and ESP staging:

```bash
ls -lh /target/boot/initrd.img-*
findmnt /target/boot/efi
df -h /target/boot/efi
ls -lh /target/boot/efi/vmlinuz-* /target/boot/efi/initrd.img-*
```

3. Verify loader entries and defaults:

```bash
cat /target/boot/efi/loader/loader.conf
ls -la /target/boot/efi/loader/entries/
grep -R --line-number -E '^(title|sort-key|version|linux|initrd|options)' /target/boot/efi/loader/entries/
test -f /target/boot/efi/loader/entries/cixmini-lts.conf
ls /target/boot/efi/loader/entries/cixmini-next*.conf
test -f /target/boot/efi/loader/entries/cixmini-rescue.conf
```

4. Verify systemd-boot install and fallback path:

```bash
test -f /target/boot/efi/EFI/systemd/systemd-bootaa64.efi
test -f /target/boot/efi/EFI/BOOT/BOOTAA64.EFI
grep -q '^default cixmini-next\*' /target/boot/efi/loader/loader.conf || grep -q '^default cixmini-lts' /target/boot/efi/loader/loader.conf
```

5. Verify fstab will mount ESP after first boot:

```bash
grep -E '[[:space:]]/boot/efi[[:space:]]+vfat[[:space:]]' /target/etc/fstab
blkid -s UUID -o value "$(findmnt -no SOURCE /target/boot/efi)"
```

6. Verify firmware and NPU state:

```bash
ls -l /target/lib/firmware/mali_csffw.bin /target/lib/firmware/arm/mali_csffw.bin /target/lib/firmware/arm/mali/mali_csffw.bin
find /target/lib/firmware -name '*.zst' -type f | head
find /target/usr/lib/modules -path '*/extra/armchina_npu.ko' -print
cat /target/etc/modules-load.d/ncz-npu.conf
chroot /target dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' cix-noe-umd 2>/dev/null || true
find /target/usr -name 'libnoe.so*' -o -name 'libaipudrv.so*' -o -name 'libaipu_driver.so*'
```

7. First-boot checks after reboot:

```bash
findmnt /boot/efi
bootctl status
bootctl list
uname -r
lsinitramfs /boot/initrd.img-$(uname -r) | head
journalctl -b -u systemd-bless-boot.service -u systemd-boot-check-no-failures.service --no-pager
```
