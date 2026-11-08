# O6N boot test: Sky1 kernel 7.3.3-sky1-ncz (r298)

Operator-supervised. Nothing in this plan has been run yet. O6N (`192.168.207.3`)
and cixmini (`.66`) were not contacted while the kernel was built.

This test gates the promotion of `7.3.3-sky1-ncz` to `CURRENT_KVER_arm64`
(docs/RC-DEFINITION.md, "Kernel promotion"). Until it passes, the pin patch
`docs/patches/arm64-kernel-733-pin.patch.in` (docs/ARM64-KERNEL-733-PIN.md) stays
unapplied and every arm64 image build stops at the lifecycle gate.

## What gets installed

The O6N side-by-side packages. They are packed from the same bitbake build as
the staged image inputs (same Image, same 376 module build ids, same three GPU
modules), by meta-cix `scripts/sky1-debpack/build-sky1-sidebyside-debs.sh`,
the packer O6N used for 7.3.1 on 2026-11-02.

| package | version | sha256 |
|---|---|---|
| `linux-image-7.3.3-sky1-ncz` | `7.3.3-sky1-ncz+r298` | `975f3facd3fad42c2138643adc712ca3b6261102b45542f32bd158c9fd486442` |
| `linux-headers-7.3.3-sky1-ncz` | `7.3.3-sky1-ncz+r298` | `a17e1974d6f526fdbafdd7499ef6c22f69c198f63e236c1f55d8018a17923f45` |
| `cixmini-boot` | `1.7+r298` | `2d0d12d3e31501c004cb8824ec50780a51aaf3d3b8d0a59f9ddaa50b4886b786` |

Source: `kernel-staging/r298-7.3.3-sky1-ncz-20261107/o6n-sidebyside/` in the
yocto-shared pool on ARGONAS (`/mnt/argonas/datapool/yocto-shared/` on ULTRA),
with its own `SHA256SUMS`. `/boot/vmlinuz-7.3.3-sky1-ncz` in the image package
is `Image-cixmini.bin`, sha256
`f47b74e20cb336a3adb2c5d0566d110528ec53c77fe947ae42ead15d38c3bf99`, vmlinux
build id `19c5ddd7880e24c63af78a8df57414268a52d5d5`.

The package names are per release, with no Provides, Conflicts or Replaces on
`linux-image-cixmini` / `linux-headers-cixmini`. apt therefore neither upgrades
nor removes the installed 7.3.0 kernel, and its files stay on disk.

Do not install the image-build package `linux-image-cixmini_7.3.3-sky1-ncz+r298`
(in `debs/`) on O6N. It has the same name as the installed 7.3.0 package, so apt
would replace the known-good kernel's files.

## Boot entry: add-only, one-shot, fallback

- The image postinst runs `ncz-refind-refresh --kver 7.3.3-sky1-ncz`. That
  appends one `menuentry "NCZ-OS 26.10 Cygnus - 7.3.3-sky1-ncz (Side-by-side)"`
  with the Default entry's options and stages its own ESP copies. It leaves
  `default_selection` unchanged, and it never edits or deletes an existing
  entry, the rescue entries or NVRAM.
- One-shot: at the rEFInd menu (10 s timeout) the operator selects the 7.3.3
  entry once. Nothing is promoted. The next boot without a selection is Default.
- Fallback: on a hang, oops, panic or black screen, power-cycle (the entry also
  carries `panic=6`, so a panic reboots by itself). rEFInd then boots the
  unchanged `7.3 Mali (Default)` (7.3.0-sky1-ncz r293). The rescue entries stay
  as they are.

## Commands

Run from STUDIO (or tell an agent to run them), one block at a time. Set the
login first. It is in the key master under `fleet_test_hosts` (O6N).

```bash
O6N=<user>@192.168.207.3
POOL=/mnt/argonas/datapool/yocto-shared/kernel-staging/r298-7.3.3-sky1-ncz-20261107
```

### 0. Lease and baseline (changes nothing on O6N except the suspend mask)

```bash
ssh $O6N 'uname -r; cat /proc/cmdline; dpkg -l "linux-image-*" "linux-headers-*" cixmini-boot | grep ^ii;
  sudo grep -nE "^default_selection|^menuentry" /boot/efi/EFI/BOOT/refind.conf; df -h / /boot/efi; dkms status;
  journalctl -b -p err --no-pager | sed "s/^.*\]: //" | sort -u > ~/err-7.3.0.txt; wc -l ~/err-7.3.0.txt'
# expected: running 7.3.0-sky1-ncz, default_selection "7.3 Mali (Default)"
ssh $O6N 'sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target'
```

### 1. Copy and verify the packages

```bash
ssh jasonperlow@192.168.207.88 "cd $POOL/o6n-sidebyside && tar -cf - *.deb SHA256SUMS" | ssh $O6N 'mkdir -p ~/k733 && tar -xf - -C ~/k733'
ssh jasonperlow@192.168.207.88 'git --git-dir=/mnt/argonas/datapool/git/cix-installer.git show hv/rc4-arm64-kernel-733-20261107:build/validate-accelerators.sh' \
  | ssh $O6N 'cat > ~/k733/validate-accelerators.sh'
ssh $O6N 'cd ~/k733 && sha256sum -c SHA256SUMS'
```

### 2. Simulate (zero removals, only these three packages)

```bash
ssh $O6N 'cd ~/k733 && sudo apt-get install -s ./cixmini-boot_1.7+r298_arm64.deb \
  ./linux-headers-7.3.3-sky1-ncz_7.3.3-sky1-ncz+r298_arm64.deb ./linux-image-7.3.3-sky1-ncz_7.3.3-sky1-ncz+r298_arm64.deb \
  | tee apt-sim.txt | grep -E "^(Inst|Remv|Conf)|upgraded"'
```
Stop if there is any `Remv` line, or if anything other than these three
packages would be installed.

### 3. Install (add-only)

```bash
ssh $O6N 'cd ~/k733 && sudo apt-get install -y ./cixmini-boot_1.7+r298_arm64.deb \
  ./linux-headers-7.3.3-sky1-ncz_7.3.3-sky1-ncz+r298_arm64.deb ./linux-image-7.3.3-sky1-ncz_7.3.3-sky1-ncz+r298_arm64.deb 2>&1 | tee install.log | tail -30'
ssh $O6N 'dkms status | grep 7.3.3; ls -la /boot/*7.3.3* /usr/lib/modules/7.3.3-sky1-ncz/updates;
  sudo grep -nE "^default_selection|^menuentry" /boot/efi/EFI/BOOT/refind.conf; sha256sum /boot/vmlinuz-7.3.3-sky1-ncz'
```
Expected: DKMS shows mali (cix-gpu-kmd), aipu, amvx and panthor for
`7.3.3-sky1-ncz`. `updates/` holds the three prebuilt Mali modules.
`default_selection` is unchanged and there is exactly one new 7.3.3 menuentry.
The vmlinuz sha256 is `f47b74e2...`.

### 4. One-shot boot (operator at the console)

This reboot is authorized for this test only.
```bash
ssh $O6N 'sudo systemctl reboot'
```
At the rEFInd menu, select `NCZ-OS 26.10 Cygnus - 7.3.3-sky1-ncz (Side-by-side)`.
If the greeter does not come up within 3 minutes, power-cycle, let Default boot
and go to step 7.

### 5. Checklist on 7.3.3 (Mali entry)

```bash
ssh $O6N 'bash -s' <<'CHECK'
set -x
uname -r                                   # 7.3.3-sky1-ncz
cat /proc/cmdline                          # sky1.gpu=vendor, panthor blacklisted
# dmesg / journal errors, compared with the 7.3.0 baseline from step 0
dmesg --level=err,crit,alert,emerg | head -40
journalctl -b -p err --no-pager | sed "s/^.*\]: //" | sort -u > ~/err-7.3.3.txt; comm -13 ~/err-7.3.0.txt ~/err-7.3.3.txt
systemctl --failed --no-pager
# GPU (Mali)
ls -l /dev/mali0; lsmod | grep -E "mali_kbase|memory_group_manager|protected_memory_allocator"
ncz-gpu-health 2>&1 | tail -5
# NPU and VPU
ls -l /dev/aipu; lsmod | grep aipu
ls -l /dev/video*; lsmod | grep amvx
# all three, bound and exercised (exit 0 = pass)
sudo bash ~/k733/validate-accelerators.sh; echo "validate-accelerators rc=$?"
# USB4 / NVMe / PCIe
lspci -nn; lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINT; ls /sys/bus/thunderbolt/devices/ 2>/dev/null; lsusb -t
# Ethernet / Wi-Fi
ip -br link; ip -br addr; nmcli -t device status; ping -c3 192.168.207.1
# display + session
pgrep -a greetd; pgrep -a labwc; loginctl list-sessions
CHECK
```

| check | pass criterion |
|---|---|
| boot | `uname -r` = `7.3.3-sky1-ncz`, greeter up |
| Mali GPU | `/dev/mali0`, all three modules loaded, `ncz-gpu-health` PASS |
| NPU | `/dev/aipu`, `aipu` loaded |
| VPU | `/dev/video0`-`3`, `amvx` loaded |
| accelerators | `validate-accelerators.sh` exits 0 |
| USB4 / NVMe | NVMe root mounted; USB devices and any USB4 device enumerate as on 7.3.0 |
| Ethernet / Wi-Fi | wired link up with an address, gateway ping OK; Wi-Fi device listed |
| dmesg | no new error lines compared with `err-7.3.0.txt` (the `comm` output), no oops or WARN |
| soak | 30 minutes up, then run the error comparison again |

### 6. Panthor (second GPU stack), same kernel, one-shot edit

Reboot. Highlight the 7.3.3 entry and press `F2` (or `Insert`) to edit its
options for this boot only:
- remove `panthor,` from `module_blacklist=`
- change `sky1.gpu=vendor` to `sky1.gpu=mesa`

Boot, then:
```bash
ssh $O6N 'uname -r; cat /proc/cmdline; lsmod | grep -E "panthor|mali_kbase"; ls -l /dev/dri;
  journalctl -b -k --no-pager | grep -iE "panthor|mali" | tail -20;
  glmark2-es2-wayland --off-screen -b build 2>&1 | tail -3'
```
Pass: `panthor` bound (it can drive `/dev/dri/renderD*`), no GPU faults,
glmark2 completes. The edit is not saved; the next boot is Default.

### 7. Rollback (always ends the test)

Reboot without a selection, so Default (7.3.0) boots. Then run:
```bash
ssh $O6N 'uname -r'   # must be 7.3.0-sky1-ncz
ssh $O6N 'sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target'
```
Removing 7.3.3 is optional (only if the operator wants it gone):
```bash
ssh $O6N 'sudo apt-get remove -s linux-image-7.3.3-sky1-ncz linux-headers-7.3.3-sky1-ncz | grep -E "^Remv"'
# exactly those two lines; then run it again without -s.
```
Remove 7.3.3 only while 7.3.0 is running (the `uname -r` check above). The
package's prerm refuses to remove the kernel that is currently running, so it
cannot take out the kernel the board booted.
The 7.3.3 ESP files and rEFInd entry stay (add-only policy) and are harmless.
Never delete the Default or rescue entries.

## Evidence and promotion

Keep `~/k733/{apt-sim.txt,install.log}`, the step 0 and step 5 outputs, the
error comparison, the soak result and `journalctl -b` of the 7.3.3 boot. Copy
them to `projects/kernel-ci/` on the artifact store next to the registry entry,
and record PASS or FAIL in `projects/kernel-ci/registry.json`.

On PASS, apply the pin as docs/ARM64-KERNEL-733-PIN.md describes. On FAIL, the
pin stays unapplied and arm64 stays refused. File the failure against r298 with
the evidence above.
