# Kernel boot-testing procedure — Sky1 (O6N/cixmini)

Standing procedure. Read before touching a boot-test box with a new kernel
`.deb`. Written after a real near-miss on O6N, 2026-09-21 (detail below) —
follow it exactly, don't improvise the steps it replaces.

## The incident this exists to prevent

Installing `linux-image-cixmini_7.3.0-rc4-sky1-ncz+r273_arm64.deb` on O6N
(currently running 7.2.6-sky1-ncz) did three things nobody asked for, silently,
as a side effect of `dpkg -i`:

1. **`linux-image-cixmini` is a single-slot package name.** There is no
   separate "stable" and "edge" package — installing a new version replaces
   the old one in dpkg's database. dpkg's normal upgrade cleanup then deleted
   the 7.2.6 kernel's own `vmlinuz`/`config` from `/boot`, even though 7.2.6
   was the kernel **currently running in memory** at the time.
2. **`cixmini-boot`'s postinst auto-regenerates `/boot/efi/EFI/BOOT/refind.conf`**
   on every kernel package install (`ncz-refind-refresh`). It rewrote
   **every single menu entry, including `default_selection`**, to point at
   the brand-new, never-booted rc4 kernel. The previously-running 7.2.6 was
   left with no boot entry pointing at it at all.
3. The DKMS accelerator modules (aipu, cix-gpu-kmd/mali, cix-vpu-driver,
   panthor-cix) that the SAME postinst tried to rebuild against
   `/lib/modules/$KVER/build` were built against **locally-regenerated
   headers on O6N itself** (`root@ncz-20e7bc`, gcc 16.2.0), not the real
   staged OE build headers (`oe-user@oe-host`, gcc 15.3.0) — the exact
   r245 DKMS/ABI-mismatch failure class kernel-build-checklist.md §1
   already documents.

**Net effect: had the box rebooted at that point, unattended, there would
have been no way back to the proven-stable 7.2.6 kernel** — only an
untested rc4 or a previously-tested-but-not-original rc3. This is precisely
the class of incident `~/.claude/rules/kernel-build-checklist.md` and O6N's
human-supervised-only reboot rule exist to prevent, and it nearly happened
via a single `dpkg -i` that looked completely routine.

All three problems were caught and fixed live, before any reboot, by
manually restoring 7.2.6's boot files from the shared kernel-staging pool,
manually rebuilding all four accelerators against the real staged headers,
and manually rewriting `refind.conf` back to its pre-install state plus a
new, separate, clearly-labeled test-only entry. That recovery is not
something to redo by hand every time — hence this procedure, and the
packaging fix it recommends.

## The standing procedure (do this, every time, no exceptions)

### 0. Never treat a boot-test box's kernel install as routine `dpkg -i`

`linux-image-cixmini` on a boot-test box is not like installing a normal
Debian package. Before running `dpkg -i` on any `linux-image-cixmini*.deb`:

- [ ] Confirm which kernel is **currently running** (`uname -r`) — this is
      the one at risk, not whatever dpkg thinks is "installed".
- [ ] `dpkg -l | grep cixmini` — confirm there is exactly one
      `linux-image-cixmini` slot, matching the single-package-name model
      above. If a future build changes this (see §3), re-verify.

### 1. Snapshot everything before installing anything

```bash
# On the boot-test box, as root/sudo:
mkdir -p /root/kernel-test-snapshots/$(date -u +%Y%m%dT%H%M%SZ)
cd /root/kernel-test-snapshots/$(date -u +%Y%m%dT%H%M%SZ)
cp /boot/efi/EFI/BOOT/refind.conf ./refind.conf.before
uname -r > ./running-kver.txt
dpkg -l | grep cixmini > ./dpkg-state.before
cp /boot/vmlinuz-$(uname -r) /boot/config-$(uname -r) /boot/initrd.img-$(uname -r) . 2>/dev/null || \
  echo "WARN: could not snapshot running kernel's own /boot files -- note where a copy already exists (staging pool, etc) before proceeding"
```

If the running kernel's own `vmlinuz`/`config`/`initrd` can't be copied
locally (e.g. disk space), confirm they still exist in the shared
ARGONAS kernel-staging pool (`kernel-staging/<rev>-<kver>/`) — build
hosts stage every kernel there, so a copy almost always already exists
off-box. **Do not proceed past this step without knowing exactly where a
recovery copy of the CURRENTLY RUNNING kernel's boot files lives.**

### 2. Install, then immediately verify nothing silently moved

```bash
sudo dpkg -i linux-image-cixmini_*.deb linux-headers-cixmini_*.deb cixmini-boot_*.deb
```

Expect this to possibly report a postinst failure (see §"DKMS forced-rebuild
race" below) — that alone is not fatal, but do NOT reboot yet.

- [ ] `diff refind.conf.before /boot/efi/EFI/BOOT/refind.conf` — read every
      line of the diff. If `default_selection` changed, or any EXISTING
      entry's `loader`/`initrd` path changed to point at the new kernel
      instead of the one that was running before, **this is the bug from
      the incident above, and it means the box would no longer boot the
      previously-running kernel by default.** Fix before proceeding (§4).
- [ ] `ls /boot/vmlinuz-<previously-running-kver>` — confirm it STILL
      EXISTS. If it's gone, restore it from your snapshot or the shared
      staging pool before doing anything else.
- [ ] `dpkg -l | grep cixmini` — if any package shows `iF`/`iU` (broken/
      unconfigured), do not `dpkg --configure -a` blindly yet — first
      resolve the DKMS module provenance (§ next).

### 3. Verify DKMS module provenance BEFORE trusting `dpkg --configure -a`

The generic `dpkg -i` → postinst → `dkms autoinstall` path rebuilds
against `/lib/modules/$KVER/build`, which on a fresh headers install can
get contaminated by a **local** `make modules_prepare`/`make scripts` run
using the box's own native toolchain — producing a module that LOOKS
installed (`dkms status` says `installed`) but was built against the wrong
compiler/headers identity. This is the r245 failure class.

```bash
# Compare the KERNEL's real build identity...
sudo cat /lib/modules/$KVER/build/include/generated/compile.h
# ...against a KNOWN-CLEAN staged headers copy (never the on-disk /build,
# which may already be contaminated):
tar -I zstd -xf headers-$KVER.tar.zst -C /tmp/real-headers
cat /tmp/real-headers/lib/modules/$KVER/build/include/generated/compile.h
```

If `LINUX_COMPILE_BY`/`LINUX_COMPILE_HOST`/`LINUX_COMPILER` differ between
the two, every DKMS-rebuilt accelerator module on this box is suspect.
Rebuild each one explicitly against the clean extracted copy:

```bash
HDRDIR=/tmp/real-headers/lib/modules/$KVER/build
cd "$HDRDIR" && sudo make -j$(nproc) scripts modules_prepare   # builds fixdep/modpost if the staged tree ships source-only
for m in aipu/6.2.0 cix-gpu-kmd/1.0 cix-vpu-driver/1.0.2-ncz1 panthor-cix/7.2.0; do
    sudo dkms build   "$m" -k "$KVER" --kernelsourcedir "$HDRDIR" --force
    sudo dkms install "$m" -k "$KVER" --kernelsourcedir "$HDRDIR" --force
done
```

- [ ] `modinfo -F vermagic <each .ko>` matches `$KVER` exactly for every
      accelerator module before trusting the install.
- [ ] Confirm `CONFIG_MODVERSIONS=y` in the running/new kernel's `.config`
      (it is the backstop: a genuinely mismatched module then REFUSES to
      load with a symbol-CRC error instead of Oopsing — verified present
      tonight, vermagic string included `modversions`).

### 4. Regenerate the initramfs, both copies

Per kernel-build-checklist.md §1c: a rebuilt DKMS module is not what boots
until the initramfs is regenerated, and rEFInd on this project boots the
**ESP copy**, not `/boot`'s.

```bash
sudo depmod "$KVER"     # dkms's own depmod pass does not reliably cover this
sudo dracut --force --kver "$KVER" /boot/initrd.img-"$KVER"
sudo cp /boot/vmlinuz-"$KVER" /boot/config-"$KVER" /boot/initrd.img-"$KVER" /boot/efi/
```

Never `update-initramfs` on this project — it's a silent no-op (dracut owns
the boot image here, see kernel-build-checklist.md §1c).

### 5. Restore/repair `refind.conf` if step 2 found a problem

If `cixmini-boot`'s regeneration retargeted the default or any existing
entry (the incident above): restore from `refind.conf.before` (your
snapshot), or hand-fix so:

- [ ] Every entry that existed before still points at the kernel it
      pointed at before.
- [ ] `default_selection` is unchanged (still the proven-stable kernel).
- [ ] The new kernel gets exactly ONE new, clearly-labeled entry, e.g.:

```
menuentry "TEST -- <kver> (Console, NO accelerators, NOT boot-tested yet)" {
    loader  /vmlinuz-<kver>
    icon    ncz.png
    initrd  /initrd.img-<kver>
    options "root=<same PARTUUID as the running system's normal root>
             rootwait rootfstype=btrfs rw rootflags=subvol=@rootfs
             console=ttyAMA0,115200 console=tty0
             module_blacklist=panthor,panfrost,mali_kbase,memory_group_manager,protected_memory_allocator,amvx,aipu
             pcie_aspm=off sky1_pcie_native=off pcie_pnp_en acpi_scmi_en=off
             loglevel=3 oops=panic panic=6
             sky1.gpu=none systemd.unit=multi-user.target"
}
```

All accelerators blacklisted and `systemd.unit=multi-user.target` (console,
no desktop) for a FIRST boot of any new kernel port — prove the kernel
itself boots before testing any accelerator. Widen the entry (drop
blacklist entries one at a time) only across separate, later, supervised
boots.

### 6. The actual boot test is human-supervised, on the console or serial — not headless SSH

**A network reboot cannot boot-test an alternate rEFInd entry.** rEFInd
waits `timeout` seconds at the menu, and with nobody there to press a key,
it boots `default_selection` — which is exactly what happened tonight
(the box came back up on 7.2.6, not rc4, because nothing selected the test
entry). Options, in order of preference:

- **Physical presence at the console**, or **serial console**
  (`ttyAMA0,115200` per every entry's `options` line above) — reboot, watch
  the menu, arrow down to the TEST entry, confirm the boot proceeds without
  panic/oops, log in, run `build/validate-accelerators.sh` if applicable
  once accelerators are un-blacklisted in a later pass.
- If no one can be physically/serially present: **do not reboot.** Stage
  everything (steps 1-5) and report ready-for-test; wait for the operator.
  This matches the existing O6N rule (`~/.claude/rules/kernel-build-checklist.md`
  §5, and the "human-supervised only, two crash-loop incidents from
  unattended reboots" note in CLAUDE.md's fleet table) — this procedure
  doesn't relax that, it exists because a routine-looking package install
  can turn an otherwise-supervised session into an effectively-unattended
  reboot if nobody catches the silent `refind.conf` rewrite first.

### 7. After a successful test boot

- [ ] Confirm `uname -r` matches the tested `$KVER`.
- [ ] `dmesg | grep -iE 'panic|oops|BUG'` — empty.
- [ ] Only THEN consider promoting the test kernel toward being the new
      default — as its own deliberate step (flip `default_selection`,
      confirmed reboot back to it), never as a side effect of installing
      a later `.deb`.

## Recommended structural fix (not yet implemented — flagging for follow-up)

The root defect is that `linux-image-cixmini` has **one package slot** for
what is conceptually **two channels** (the kernel currently trusted as
default, and whatever is being tested as edge). Every step above is a
manual workaround for that. The real fix, matching how this project already
separates "stable" and "edge" line concepts everywhere else
(`build/stage-amd64-kernel.sh`'s `amd64-stable` channel -- the
amd64-edge channel was removed by the operator directive 2026-09-30
because no validated amd64 7.3 kernel exists, see
`docs/reports/2026-09-30-kernel-default-policy.md` -- and the
Sky1 dual-track O6N/cixmini kernel lines), is to give the Sky1 kernel
the same treatment:

- Package the kernel under test as a **separate package name**
  (`linux-image-cixmini-edge`, distinct from `linux-image-cixmini`), so
  installing it cannot dpkg-replace the trusted default's files.
- `cixmini-boot`'s postinst should **never rewrite an existing entry**,
  only add a new one for whichever channel it was just handed, and should
  **never change `default_selection`** — promotion to default is a
  separate, explicit, human-triggered action (a flag to `cixmini-boot`,
  or a distinct `cixmini-promote-kernel` tool).
- The DKMS forced-rebuild-then-autoinstall race that produced the
  "not located in the DKMS tree" / fallback-to-local-headers failure
  tonight should be fixed at the source: the postinst should point DKMS
  at the package's OWN shipped, unmodified headers tree explicitly
  (`--kernelsourcedir`), the same way `build/release-kernel.sh` step 4b
  already does correctly for the build-host side — never rely on the
  generic `/lib/modules/$KVER/build` symlink, which is exactly the path
  that got locally contaminated tonight.

This is real packaging work (`build/build-kernel-debs.sh`'s package
naming/postinst logic), not a quick patch — scoping it here so it's not
re-discovered from scratch next time this bites, but not rushing it
tonight given the stakes of getting kernel packaging changes wrong.

## Cross-references

- `~/.claude/rules/kernel-build-checklist.md` — the general kernel-build
  checklist (SRCREV verification, DKMS/ABI provenance gate, initramfs
  refresh, boot gates). This procedure is the O6N-specific, incident-driven
  companion to that file's §1, §1c, §6.
- `build/release-kernel.sh` — the correct, full packaging pipeline
  (includes the `--kernelsourcedir` panthor rebuild this procedure's §3
  replicates manually when release-kernel.sh wasn't run end-to-end on the
  same host as the install).
- `build/dkms-abi-gate.sh`, `build/kvm-kernel-gate.sh` — the existing
  automated gates; run both BEFORE this procedure's manual steps, not
  instead of them (they gate the BUILD; this procedure gates the INSTALL).
