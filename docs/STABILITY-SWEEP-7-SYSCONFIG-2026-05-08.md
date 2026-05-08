# Stability Sweep 7 - System Config Hooks - 2026-05-08

## Executive summary

- Verdict: high-severity gaps were present in fstab UUID failure handling, final SSH password posture, NTP enable/config visibility, and Magnetar headless remote-access gating.
- Patched in-place: 4 HIGH fixes across `post-install/31-remote-access.sh`, `post-install/33-ntp-hostname.sh`, `post-install/34-fstab.sh`, and `post-install/35-ssh.sh`; no commit made.
- Counts: HIGH 4, MEDIUM 6, LOW 5.
- Current time sync is `systemd-timesyncd`, not chrony. The hook now writes explicit NTP/FallbackNTP servers and fails if the unit cannot be enabled.
- Current hostname behavior does not preserve the preseeded `mini` default; it treats `mini` as a default/blank value and generates `ncz-<8-hex>` unless the operator set a custom hostname.

## HIGH findings

### H1 - `/etc/fstab` UUID derivation could fail as success

File: `post-install/34-fstab.sh:14`, `post-install/34-fstab.sh:79`, `post-install/34-fstab.sh:80`, `post-install/34-fstab.sh:92`

Root cause: the previous hook ran under `set +e` and returned `exit 0` when root or ESP UUID derivation failed. That matched the sweep 4 M6 complaint: `/etc/fstab` could remain empty or stale while the installer reported success and only printed a warning that `/boot/efi` might not mount.

Why HIGH: first boot can still work because firmware reads the ESP directly, but later kernel or bootloader updates can write into an unmounted `/boot/efi` directory. That creates a target that appears installed but cannot safely receive kernel updates.

Concrete diff applied:

- `34-fstab.sh` now runs under `set -euo pipefail`.
- Missing root or `/boot/efi` device/UUID now exits nonzero through `uuid_for()`.
- The ESP device is derived from the mounted `/boot/efi` first, with same-parent vfat fallback only if needed.
- Separate `/boot` and detected swap partitions are emitted when present; the current preseed recipe has only ESP plus root and no swap at `preseed/preseed.cfg:145` and `preseed/preseed.cfg:165`.
- `/etc/fstab` is written through a temporary file only after mandatory UUIDs are known.

Residual note: `34-fstab.sh` is still a Phase 2 optional hook because `run-all.sh` is out of scope for this component. A nonzero rc is now visible in the hook log, but promoting `34-fstab.sh` to required belongs in the orchestration component.

### H2 - Final installed SSH allowed password logins with a known diagnostic password

File: `post-install/35-ssh.sh:137`, `post-install/35-ssh.sh:138`, `post-install/35-ssh.sh:139`, `post-install/35-ssh.sh:141`

Root cause: the final sshd drop-in previously wrote `PasswordAuthentication yes`. That was materially different from the d-i ramdisk watcher, which temporarily flips root access only during install at `preseed/sshd-watcher.sh:331`. The final installed system also contains the temporary `magnetar` diagnostic account from `post-install/09-diag-account.sh:24` with the testing password documented in that hook.

Why HIGH: a freshly installed target exposed network password authentication for the operator and diagnostic accounts. The final image should be fleet-key reachable, not password reachable, especially because the diagnostic password is intentionally shared for r75/r76 shakedown.

Concrete diff applied:

- Final sshd config now sets `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `ChallengeResponseAuthentication no`, and `PubkeyAuthentication yes`.
- Console passwords remain usable locally; network SSH is key-only.
- This does not change the d-i ramdisk watcher path, which still uses `PermitRootLogin yes` only for installer-time diagnostics.

### H3 - SSH key seeding did not verify all local operator accounts

File: `post-install/35-ssh.sh:75`, `post-install/35-ssh.sh:92`, `post-install/35-ssh.sh:94`, `post-install/35-ssh.sh:121`, `post-install/35-ssh.sh:124`

Root cause: `35-ssh.sh` previously seeded root plus only the first UID >= 1000 user. If both a preseed-created operator and the `magnetar` diagnostic account existed, the diagnostic account relied entirely on `09-diag-account.sh` having completed earlier. Sweep 2 already found one path where that account could be partial.

Why HIGH: after moving SSH to key-only, every expected remote account must have the fleet keys. Missing keys on `magnetar` or the actual preseed operator would turn a headless system into a local-console-only system.

Concrete diff applied:

- Added `install_authorized_keys()` and `seed_user_if_present()`.
- Root is still seeded without clobbering existing rotated keys.
- Every normal local UID in `[1000,65000)` is now considered, and `ncz` plus `magnetar` are explicit fallbacks.
- Existing non-empty `authorized_keys` files are preserved for idempotence.
- The key material remains consistent with the watcher and diag account: `post-install/35-ssh.sh:68`, `post-install/35-ssh.sh:70`, `post-install/09-diag-account.sh:64`, `post-install/09-diag-account.sh:65`, `preseed/preseed-ubuntu.cfg:122`, and `preseed/preseed-ubuntu.cfg:123` all carry the same two fleet keys.

### H4 - Graphical remote-access hook ran on Magnetar headless installs

File: `post-install/31-remote-access.sh:9`, `post-install/31-remote-access.sh:14`, `post-install/31-remote-access.sh:16`

Root cause: `31-remote-access.sh` did not read `/usr/local/lib/cix-installer/BUILD_VARIANT`. In the Phase 2 order, this hook runs before `48-magnetar-variant.sh`, while the sidecar is already written by `preseed/late.sh:111` or defaulted at `preseed/late.sh:118`.

Why HIGH: on Magnetar, `20-desktop.sh` now skips desktop install, but `31-remote-access.sh` still attempted NoMachine and wrote `/etc/xrdp/startwm.sh`. If `/etc/xrdp` was absent, the hook failed; if packages existed, it exposed a graphical remote surface on a headless appliance SKU.

Concrete diff applied:

- `31-remote-access.sh` now reads `BUILD_VARIANT`.
- `server|magnetar|headless` exits 0 before NoMachine download or xrdp mutation.
- Desktop installs keep the existing NoMachine-preferred, xrdp-fallback path.

## MEDIUM findings

### M1 - fstab failure is now nonzero, but still only optional at orchestration level

File: `post-install/run-all.sh:165`, `post-install/run-all.sh:180`, `post-install/run-all.sh:183`

The hook-level hard fail is patched, but Phase 2 optional failures still continue by design. That means the installer can still complete with `34-fstab.sh` logged as failed unless a later release gate consumes optional-hook failures.

Recommended diff: in the orchestration component, either move `34-fstab.sh` to the required set or add a strict mode that treats selected optional hooks such as fstab and ssh as install-fatal.

### M2 - `35-fstrim-fix.sh` does not enable `fstrim.timer`

File: `post-install/35-fstrim-fix.sh:6`, `post-install/35-fstrim-fix.sh:10`, `post-install/35-fstrim-fix.sh:12`

The "fstrim-fix" is clear: systemd's weekly fstrim service was failing because the Cix Sky1 ESP returns I/O error for FITRIM on vfat. The hook installs a drop-in that limits fstrim to ext4, btrfs, xfs, f2fs, and zfs.

Gap: the hook does not run `systemctl enable fstrim.timer`. If the base image or distro preset enables it, the fix applies. If not, the system never trims automatically.

Recommended diff: add `systemctl enable fstrim.timer || true` after the drop-in, then report `systemctl is-enabled fstrim.timer`.

### M3 - Hostname contract is not the preseeded `mini` value

File: `preseed/preseed-ubuntu.cfg:31`, `post-install/33-ntp-hostname.sh:96`, `post-install/33-ntp-hostname.sh:98`, `post-install/33-ntp-hostname.sh:100`

The Ubuntu preseed sets `mini`, but `33-ntp-hostname.sh` treats `mini` as a default/blank value and replaces it with `ncz-<8-hex>`. This is coherent with the hook comment about avoiding duplicate LAN hostnames, but it does not match a literal "installed hostname must be mini" contract.

Recommended decision: make the product contract explicit. Keep MAC-derived names if LAN uniqueness wins, or remove `mini` from the default/blank list if the release must always ship as `mini`.

### M4 - Hostname propagation lacks an explicit Avahi path

File: `post-install/33-ntp-hostname.sh:111`, `post-install/33-ntp-hostname.sh:114`, `post-install/33-ntp-hostname.sh:117`

The hook writes `/etc/hostname` and ensures a single `127.0.1.1` entry in `/etc/hosts`. systemd-hostnamed will read `/etc/hostname` on boot, so no runtime `hostnamectl` call is needed in the chroot.

Gap: no scoped hook installs or enables `avahi-daemon`, and no Avahi config is written. If `.local` discovery is a required operator path, this component does not implement it.

Recommended diff: install/enable Avahi in a network/desktop-owned hook or document that discovery is by DHCP/DNS/SSH inventory, not mDNS.

### M5 - timesyncd is assumed present, not installed by this hook

File: `post-install/33-ntp-hostname.sh:120`, `post-install/33-ntp-hostname.sh:126`, `post-install/33-ntp-hostname.sh:132`

Runtime ownership is now explicit: `systemd-timesyncd` is enabled and the pool list is written under `/etc/systemd/timesyncd.conf.d/`. The hook does not install `systemd-timesyncd`; it assumes the prebaked rootfs or package set already provided it.

Recommended diff: make `systemd-timesyncd` an explicit package in the base image or bootstrap pool. The hook now fails if the unit is missing, but because hook 33 remains optional, the orchestration layer still decides whether that becomes install-fatal.

### M6 - `48-magnetar-variant.sh` still advertises or installs NoMachine for headless

File: `post-install/48-magnetar-variant.sh:46`, `post-install/48-magnetar-variant.sh:61`, `post-install/48-magnetar-variant.sh:186`, `post-install/48-magnetar-variant.sh:227`

`31-remote-access.sh` now skips Magnetar, as requested. However, the later variant hook, outside this component, still describes NoMachine as a headless remote desktop path and installs a staged `.deb` if present.

Recommended decision: align the Magnetar contract. If headless means no GUI remote surface, remove that NoMachine path in component 8 or a variant sweep. If operator preference is "NoMachine X11 over xrdp" for TYPHON/macOS RD client paths, keep NoMachine as an explicit opt-in and do not install xrdp on server.

## LOW findings + recommendations

### L1 - Existing fstab entries are not semantically verified

File: `post-install/34-fstab.sh:18`

If `/etc/fstab` is non-empty and contains root plus `/boot/efi`, the hook leaves it alone. It does not verify that the UUIDs match current block devices. That preserves operator edits, but it can also preserve a stale fstab.

Recommendation: add a non-mutating verification summary that compares the root and ESP fstab UUIDs with `findmnt`/`blkid`, warning when they differ.

### L2 - `31-remote-access.sh` still depends on live internet for NoMachine

File: `post-install/31-remote-access.sh:24`, `post-install/31-remote-access.sh:26`, `post-install/31-remote-access.sh:31`

The hook fetches a hardcoded NoMachine ARM64 `.deb` from the vendor URL. Failure is tolerated and xrdp remains the fallback on desktop installs, but this means NoMachine availability depends on external network state during install.

Recommendation: prefer a staged payload, as `48-magnetar-variant.sh` attempts for server, then use the online URL only as a manual operator action.

### L3 - xrdp config assumes xrdp package ownership

File: `post-install/31-remote-access.sh:35`, `post-install/31-remote-access.sh:61`

On desktop installs this is usually satisfied by `20-desktop.sh`, which installs xrdp before hook 31. If `20-desktop.sh` fails or an operator reruns hook 31 on a minimal target, writing `/etc/xrdp/startwm.sh` can fail.

Recommendation: guard xrdp mutation with `dpkg-query -W xrdp` or `install -d /etc/xrdp` plus a clear warning when the package is absent.

### L4 - Idempotence is mostly good, with one network-heavy exception

File: `post-install/33-ntp-hostname.sh:96`, `post-install/34-fstab.sh:18`, `post-install/35-ssh.sh:82`, `post-install/35-ssh.sh:88`

`33-ntp-hostname.sh` preserves operator hostnames, `34-fstab.sh` preserves an existing root+ESP fstab, and `35-ssh.sh` preserves non-empty authorized_keys. `31-remote-access.sh` is safe to rerun but re-downloads NoMachine each time.

Recommendation: cache or stage the NoMachine package if repeated desktop reruns are common.

### L5 - No VNC or gnome-remote-desktop runtime configuration found

File: `post-install/31-remote-access.sh:21`, `post-install/31-remote-access.sh:34`

The scoped remote-access hook configures NoMachine and xrdp only. There is no VNC/vino/gnome-remote-desktop enablement in this hook. That is good for surface-area control, but the release notes or operator docs should not imply that GNOME remote desktop or VNC is enabled by default.

## Test plan

Static validation already run locally:

```sh
bash -n post-install/31-remote-access.sh post-install/33-ntp-hostname.sh post-install/34-fstab.sh post-install/35-fstrim-fix.sh post-install/35-ssh.sh
shellcheck -S warning post-install/31-remote-access.sh post-install/33-ntp-hostname.sh post-install/34-fstab.sh post-install/35-fstrim-fix.sh post-install/35-ssh.sh
git diff --check -- post-install/31-remote-access.sh post-install/33-ntp-hostname.sh post-install/34-fstab.sh post-install/35-ssh.sh
LC_ALL=C rg -n '[^\\x00-\\x7F]' post-install/31-remote-access.sh post-install/33-ntp-hostname.sh post-install/34-fstab.sh post-install/35-ssh.sh docs/STABILITY-SWEEP-7-SYSCONFIG-2026-05-08.md
```

Installer chroot checks before reboot:

```sh
chroot /target bash /usr/local/lib/cix-installer/post-install/34-fstab.sh
grep -E '[[:space:]]/[[:space:]]' /target/etc/fstab
grep -E '[[:space:]]/boot/efi[[:space:]]+vfat[[:space:]]' /target/etc/fstab
findmnt /target/boot/efi
blkid -s UUID -o value "$(findmnt -no SOURCE /target/boot/efi)"
```

SSH posture checks:

```sh
chroot /target bash /usr/local/lib/cix-installer/post-install/35-ssh.sh
cat /target/etc/ssh/sshd_config.d/10-nclawzero.conf
grep -E '^(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication)' /target/etc/ssh/sshd_config.d/10-nclawzero.conf
chroot /target sshd -t
test -s /target/root/.ssh/authorized_keys
for h in /target/home/*; do test -d "$h" && test -s "$h/.ssh/authorized_keys"; done
diff -u <(rg 'ssh-ed25519' preseed/preseed-ubuntu.cfg | sed -E "s/.*'(ssh-ed25519 [^']+)'.*/\\1/") <(rg '^ssh-ed25519' /target/root/.ssh/authorized_keys)
```

NTP and hostname checks:

```sh
chroot /target bash /usr/local/lib/cix-installer/post-install/33-ntp-hostname.sh
cat /target/etc/hostname
grep -E '^127\\.0\\.1\\.1[[:space:]]+' /target/etc/hosts
cat /target/etc/systemd/timesyncd.conf.d/10-nclawzero.conf
chroot /target systemctl is-enabled systemd-timesyncd
```

Remote-access variant checks:

```sh
printf 'server\n' > /target/usr/local/lib/cix-installer/BUILD_VARIANT
chroot /target bash /usr/local/lib/cix-installer/post-install/31-remote-access.sh
grep -q 'skipping graphical remote access' /target/var/log/cix-install/31-remote-access.log 2>/dev/null || true

printf 'desktop\n' > /target/usr/local/lib/cix-installer/BUILD_VARIANT
chroot /target bash /usr/local/lib/cix-installer/post-install/31-remote-access.sh || true
test -x /target/etc/xrdp/startwm.sh
```

fstrim checks:

```sh
cat /target/etc/systemd/system/fstrim.service.d/no-vfat.conf
grep -- '--types ext4,btrfs,xfs,f2fs,zfs' /target/etc/systemd/system/fstrim.service.d/no-vfat.conf
chroot /target systemctl is-enabled fstrim.timer 2>/dev/null || true
```

First boot smoke:

```sh
findmnt /boot/efi
timedatectl status
systemctl status systemd-timesyncd --no-pager
hostnamectl status
ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no magnetar@<host> true
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no magnetar@<host> true  # must fail
```
