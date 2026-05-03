# Sky1-Linux issue #12 — comment draft

**Target:** https://github.com/Sky1-Linux/linux-sky1/issues/12
**Author identity:** Jason Perlow / `perlowja` on GitHub
**To post:** AFTER r7 boots cleanly on cixmini.66 with the blacklist applied

---

## Draft

Adding another data point + a workaround.

I'm running [`meta-cix`](https://github.com/perlowja/cix-installer) — a
small Yocto layer that bakes `linux-cix-sky1` (140 patches: 139 from the
LTS series + Stuart Shelton's PR #18 kconfig fix) into a Debian-installer
preseeded ISO for unattended install on a Minisforum MS-R1.

I tested @MartJohnson's reported configuration on `7.0.1-sky1-next.r1000`
first, and (since that has known SCMI bugs) also tried `6.18.26 LTS` with
his hand-corrected `0065-treewide` ACPI patch + his MS-R1 config
(`config.sky1-minisforum-6.18.26-1000.txt`). Same MartJohnson cmdline:

```
loglevel=4 console=tty0 console=ttyAMA2,115200 efi=noruntime acpi=force \
arm-smmu-v3.disable_bypass=0 audit_backlog_limit=8192 clk_ignore_unused \
keep_bootcon panic=30
```

**Both wedge during driver probe at:**

```
[    0.566710] rts5453h i2c-CIXH200D:00: USB role switch handle is error.
[    0.575174] rts5453h i2c-CIXH200D:00: No switch control for port
[    0.583472] rts5453h i2c-CIXH200D:01: USB role switch handle is error.
[    0.592014] rts5453h i2c-CIXH200D:01: No switch control for port
[    0.759600] genirq: Flags mismatch irq 151. 00002008 (i2c-CIXH200D:00) vs. 00002008 (i2c-CIXH200D:01)
```

Both `rts5453h` instances request IRQ 151 with `0x2008`
(`IRQF_ONESHOT | IRQF_TRIGGER_LOW`) but **neither has `IRQF_SHARED` set**,
so genirq refuses the second registration and the kernel hangs before
reaching userland.

**Workaround that gets boot:**

```
module_blacklist=typec_rts5453,rts5453
```

USB-A ports, HDMI, ethernet, NVMe, GPU all work. USB-C ports degrade
to default-voltage host-only (no PD nego, no DisplayPort alt-mode).

**Hardware:** Minisforum MS-R1, BIOS rev `01.30.2026` (whatever ships
factory; happy to capture exact build number from boot console once I
can get a screen capture).

**Question:** Is your working `7.0.1-sky1-next.r1000` setup possibly on
a newer BIOS rev where this conflict is gone? Or is `IRQF_SHARED`
patched in somewhere I've missed in `patches/` or `patches-next/`?

The fix is small if anyone wants it: register both `rts5453h` instances
as `IRQF_SHARED`, OR have only one bind (board-specific quirk for MS-R1
that drops the second device). Happy to write either if there's
guidance on which is preferred upstream.

For reference, our integration is at https://github.com/perlowja/cix-installer
— `meta-cix/recipes-kernel/linux-cix-sky1*/` for the Yocto recipes,
`build/build-iso.sh` for the d-i preseed pipeline. We ship dual-kernel
(both LTS and next) as a hard policy specifically because of cases like
this — when one wedges, the user has the other in the systemd-boot menu.

CC @MartJohnson @HeyMeco @Entrpi @polprog
