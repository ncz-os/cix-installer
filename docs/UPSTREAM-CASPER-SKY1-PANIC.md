# Upstream issue draft — Ubuntu casper kernel-panics on Cix Sky1 USB boot

**Status:** DRAFT 2026-05-06. Needs panic-signature capture on next .66 test boot before publish.
**Targets:** Launchpad bug at `bugs.launchpad.net/ubuntu/+source/casper`; mirror to `Sky1-Linux/linux-sky1` issues; cross-link to `cixtech/cix-linux-main` for vendor visibility.
**Why this matters:** This bug is the only thing preventing a unified Subiquity-based arm64/x86 installer for Cix Sky1 hardware. Solving it upstream eliminates the need for downstream-d-i forks (NCZ Reinhardt, others) and lets the Sky1 community track Ubuntu mainline directly.

---

## Title

> casper / live-build initrd kernel-panics on USB boot on Cix Sky1 (CD8180) — bookworm-d-i busybox initrd boots fine on the same kernel

## Body

### Summary

Booting any Ubuntu casper-based ISO from USB on Cix Sky1 / CD8180 silicon (Minisforum MS-R1, Radxa Orion O6, Orange Pi 6 Plus) results in a kernel panic during initrd execution. The panic is reproducible across:

- multiple bootloaders (rEFInd, GRUB, systemd-boot)
- Ubuntu 26.04 resolute and Ubuntu 24.04 noble installer ISOs
- Cix Sky1 LTS kernel `linux-cix-sky1 6.18.x` and NEXT `7.0.x`
- the Sky1-Linux community kernel patch series

Substituting a Debian `bookworm-d-i` busybox initrd (with the *same* Cix Sky1 vmlinuz) boots and installs successfully on the same hardware. We have shipped that workaround as the [NCZ Reinhardt](https://gitlab.com/nclawzero/cix-installer) installer for ~6 months, but it requires us to fork the d-i base substrate. We'd much rather drop the fork and use Subiquity directly.

### What we know

- The panic happens *after* kernel handoff (vmlinuz boots, kernel prints early console messages, modules load), *before* the Subiquity TUI / casper init script reaches a usable state.
- The panic signature has been observed on UART/serial console but **has not been captured cleanly** (TODO: capture from .66 on next boot test — pending).
- The casper init script does several things bookworm-d-i busybox-init doesn't:
  - Mounts an overlay filesystem (squashfs + tmpfs + overlayfs)
  - Loads `casper.conf` / `casper.preseed` parameters from kernel cmdline
  - Runs `casper-bottom/` scripts in sequence
- We have not narrowed down which step trips the panic.

### What we've ruled out

- **Bootloader:** rEFInd, GRUB, systemd-boot all panic at the same point. Rules out bootloader-specific behavior.
- **Storage stack:** the bookworm-d-i initrd reads from the same USB stick on the same EHCI/XHCI controller without panicking. Rules out storage driver / probe issues.
- **Kernel version:** both the LTS 6.18.x and NEXT 7.0.x branches panic with casper. Rules out a single-version regression.
- **EFI runtime services:** we run with `efi=noruntime` for MS-R1 BIOS quirks; tested with and without — no change to the panic. Rules out EFI runtime.
- **ACPI:** boot params with `acpi=force` (our default) and `acpi=noirq` both panic. Rules out trivial ACPI mismatch.

### Reproducer

Currently anyone with Sky1 hardware + a recent Ubuntu desktop or server ISO sees this. Specifically:

1. Download `ubuntu-26.04-desktop-arm64.iso` (or `live-server-arm64.iso`)
2. Flash to USB with `dd` or balenaEtcher
3. Boot a Cix CD8180 / Sky1 system from the USB
4. Observe panic shortly after kernel handoff

Baseline that works for comparison: NCZ Reinhardt installer (`gitlab.com/nclawzero/cix-installer/-/releases`) — same hardware, same Cix Sky1 kernel, bookworm-d-i busybox initrd substituted in.

### Panic signature (placeholder)

```
TODO: capture from /dev/ttyAMA2 serial console on next test boot.
Estimated structure:
  - Kernel: linux-cix-sky1 X.Y.Z
  - Last printk before panic: ?
  - Panic line + register dump
  - Backtrace (top 10-15 frames)
  - Tainted state (likely "G" from Cix vendor modules)
```

We'll attach the captured panic to this bug as soon as we get a clean serial trace. Will edit this section in place.

### What would help

1. **Tell us if you've seen this on other ARM SoCs.** The pattern (busybox-init works, casper panics, same kernel) suggests something casper does that Sky1's runtime doesn't tolerate — could be SoC-specific or could be a class of issue affecting multiple ARM64 platforms with similar firmware quirks.
2. **Which casper script / step is the most likely suspect?** From a maintainer's read of `casper/scripts/casper-bottom/`, what stands out as fragile against unusual ARM64 platforms?
3. **Subiquity team:** would you accept patches to make casper init more resilient (graceful fallback, more diagnostics) even before we have a root cause?

### Why we care

The downstream cost is real:

- We maintain a forked debian-installer pipeline (`cix-installer`) just to substitute the initrd.
- The fork carries hand-grafted trixie udebs (`debootstrap-udeb 1.0.141 + libzstd1-udeb + liblzma5-udeb`) onto a bookworm-d-i base, which is fragile.
- Two parallel install paths (Sky1 fork vs. Ubuntu mainline) for what should be one Sky1 user community.
- New Sky1 hardware vendors (Radxa, Orange Pi, MetaComputing's Framework 13 mainboard) each rediscover this bug independently when trying to use Ubuntu live ISOs.

If casper just worked on Sky1, all of that retires. We want to use Subiquity. That's the destination.

### Cross-links

- NCZ Reinhardt (the downstream workaround we maintain): [gitlab.com/nclawzero/cix-installer](https://gitlab.com/nclawzero/cix-installer)
- Sky1-Linux community kernel: [github.com/Sky1-Linux/linux-sky1](https://github.com/Sky1-Linux/linux-sky1)
- Cix vendor kernel: [github.com/cixtech/cix_opensource__linux](https://github.com/cixtech/cix_opensource__linux)
- visorcraft NPU bring-up (related Sky1 mainline work): [github.com/visorcraft/orange-pi-6-plus-npu](https://github.com/visorcraft/orange-pi-6-plus-npu)
- This bug doc: `gitlab.com/nclawzero/cix-installer/-/blob/main/docs/UPSTREAM-CASPER-SKY1-PANIC.md`

### Author / contact

Jason Perlow (`@perlowja`) — NCZ project maintainer.

Happy to:
- Provide reproducible steps + UART captures + ISO/USB images on demand
- Test patches on real Sky1 hardware (Minisforum MS-R1)
- Do a screen-share / live-debug session with whoever is best-positioned to look at this

---

## Distribution plan

| Channel | Audience | When |
|---|---|---|
| Launchpad bug `bugs.launchpad.net/ubuntu/+source/casper` | Canonical casper maintainers | Day 0 (after panic capture) |
| `Sky1-Linux/linux-sky1` issue (link to Launchpad) | Community kernel maintainers | Day 0 |
| `cixtech/cix-linux-main` issue (link to Launchpad) | Cix vendor visibility | Day 0 |
| `discourse.ubuntu.com` post (cross-ref Launchpad) | Broader Ubuntu community | Day 1 if first-day traction warrants |
| `canonical/subiquity` issue (link to Launchpad) | Subiquity maintainers | Day 1 |
| `r/Ubuntu` + `r/LocalLLaMA` | SBC enthusiasts | If Day 1-3 doesn't get a Canonical-side response, escalate |

Frame: collaborative, not adversarial. We are not blocking anyone; we're maintaining a workaround they could take off our hands.

## Pre-publish checklist

- [ ] Capture clean UART panic signature on next .66 test boot
- [ ] Reproduce on a second Sky1 board (Radxa O6 if available; otherwise leave as MS-R1-only and note that)
- [ ] Codex review against the personal-OSS comms rules (no NVIDIA/Jetson framing in non-NVIDIA-vendor comms — this is fine, no comparisons)
- [ ] Confirm the bookworm-d-i workaround attribution is correct in the body (we proved it in cix-installer r6; reference that)

## Why this is on the r75-review branch

Strategic decision (PRIMARY DIRECTIVE #10 triple persistence): we want this in `cix-installer/docs/` so it ships with the project and is discoverable by anyone reading the repo. The actual bug filing on Launchpad happens later when the panic capture lands; this file is the canonical drafting surface.
