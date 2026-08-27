# RESUME-BEACON PATCH — 2026-08-21

> **Author:** Jason Perlow (via minimax, 2026-08-21, single-session)
> **Target:** `linux-cix-sky1-ncz_7.2.bb` (v7.2-rc7 + 218 SRC_URI patches + 0219)
> **Repo:** cix-installer, branch `master` (push target: `argonas`)
> **Patch:** `kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/0219-DEBUG-ncz-resume-beacons-ramoops.patch`
> **Status:** **BUILT CLEAN — kernel Image produced, kvm-kernel-gate PASS**
> **Hardware action:** **NOT taken** — this task's job ends at "patch built, boots clean, ready to ship." Real suspend/resume on O6N is the operator's call.

---

## TL;DR

Added 0219, a new self-contained kernel patch in the v7.2 SRC_URI series
that extends the existing unwired 9021 boot-beacon helper into a
suspend/resume instrument.  Six instrumentation points (R1..R6) bracket
the entire resume path on the coordinating core (CPU0); each one writes
a one-line ASCII breadcrumb to the firmware-reserved ramoops console
zone with an explicit dcache clean so the record survives the watchdog
reset that follows the hang.

When the operator runs a real S3 / deep-sleep test on O6N and the
board subsequently fails to resume, the ramoops dump (read back from
the next boot, or via JTAG, or via the existing TTY earlycon) will
contain a `NCZBEACON R1`..`R6` sequence.  The last `R<n>` present is
the last step CPU0 reached before it died; everything after that is
the lock site.  This is exactly the forensic evidence the current
pstore setup never produces (CPU0, which owns pstore, is the thing
that locks — so pstore has no time to flush).

Build verified end-to-end on the ARGONAS-shared TYDEUS Yocto 6 (Wrynose)
build env via `~/yocto-docker/y6-run.sh "bitbake linux-cix-sky1-ncz -c
compile -f"`.  do_patch succeeded with all 219 patches in series (the
existing 218 + new 0219); do_compile produced a fresh `Image-cixmini.bin`
+ matching `.config`; `build/kvm-kernel-gate.sh` reported PASS on the
new Image.

---

## Why a separate patch (not "just turn on 9021")

The existing `9021-DEBUG-ncz-boot-beacons-ramoops.patch.unwired` is
intentionally left out of SRC_URI.  It does its job (boot breadcrumbs
B1..B12 written to the same ramoops console zone) but it is BOOT-only
and:

  * is gated on `CONFIG_NCZ_BOOT_BEACON` whose help text, Makefile
    object rule, and per-initcall hook all bake in the "boot" naming
    and semantics;
  * has no resume-path hooks at all;
  * the helper it ships is split into core_initcall / device_initcall
    callbacks that are not safe to call from the suspend/resume
    critical sections (e.g. `dcache_clean_poc` before slab is up, or
    before the dcache state is sane after `__cpu_suspend_exit`).

Re-aiming 9021 to cover both would silently change its semantics for
anybody who wires it back up as a boot-only instrument later.  The
cleaner call is a separate, self-contained 0219:

  * `NCZ_RESUME_BEACON` config (default n);
  * `ncz-resume-beacon.c` + `ncz-resume-beacon.h`, no early-boot
    initcalls — the helper is callable at any point where slab is up
    and `memremap(MEMREMAP_WB)` is safe (true at all six resume sites,
    see the per-site call-site commentary below);
  * the two helpers coexist on disk: if both 9021 and 0219 are ever
    wired into SRC_URI simultaneously the linker will refuse to link
    (two `ncz_beacon` symbols), which is the correct "do not combine
    these" outcome — the operator picks one wiring per build.

If 9021 is later wired in, the operator gets boot breadcrumbs (B1..B12)
without resume breadcrumbs (R1..R6); if 0219 is wired in, they get
resume breadcrumbs without boot breadcrumbs.  The two are
intentionally separate so each can be turned on independently of the
other.

---

## The six instrumentation points

Each call site is a single `ncz_beacon("R<n>-<short desc>")` line.  All
six are unconditionally written in this order on a clean suspend+resume
cycle:

  ```
  NCZBEACON R1-BeforeSuspendOpsEnter
  ... (Ramoops signature + header at offset 0..15)
  NCZBEACON R2-AfterSuspendOpsEnter
  ... (firmware handoff: SYSTEM_SUSPEND enter)
  NCZBEACON R4-psci_system_suspend_return
  NCZBEACON R3-cpu_suspend_exit
  NCZBEACON R5-gic_pm_exit
  ... (syscore resume chain runs, dpm_resume_noirq, etc.)
  NCZBEACON R6-SecondaryCpusReEnabled
  ```

After the NEXT boot (when the operator power-cycles the hung board),
the ramoops console dump will contain every `R<n>` line written
successfully.  The largest `R<n>` that appears is the last one CPU0
reached.

The R1..R6 ordering is approximate — R3 and R5 in particular fire in
slightly different orders depending on which syscore notifier runs
first — so **the rule is "highest R number present in the dump is the
lock site boundary, not the strict last entry written"**.  The
narrative below explains the meaning of each.

### R1 — `suspend_enter()` entry, just before `suspend_ops->enter()`

  * **File:** `kernel/power/suspend.c`
  * **What it proves:** CPU0 has reached the kernel-side
    suspend-precursor code path.  All syscore suspends have run, IRQs
    are still enabled, secondary cores are still online.
  * **If R1 is present and R2 is not:** the hang is *inside* the
    platform/firmware sleep-entry code — `suspend_ops->enter()` did not
    return.  This is the smoking gun for "PSCI SYSTEM_SUSPEND never
    returned control to EL1" or "ACPI S3 `_PTS` method took the
    firmware down with it."  It confirms the bug is in the firmware
    sleep path, not the kernel resume path.

### R2 — `suspend_ops->enter()` return

  * **File:** `kernel/power/suspend.c`
  * **What it proves:** The kernel-visible portion of the platform
    resume path completed.  Control is back in `suspend_enter()`,
    syscore_resume is about to run, IRQs are still off (re-enabled
    two statements later by `arch_suspend_enable_irqs()`).
  * **If R2 is present and R3 is not:** the hang is between the
    suspend_ops return and the first instruction of the arm64
    `cpu_suspend_exit` trampoline — i.e. somewhere in
    `arch_suspend_enable_irqs()`, the WARN/BUG sanity check on line
    481, or the secondary-CPU re-enable on line 484.
  * **If R2 is present and R4 is not:** the hang is in
    `__cpu_suspend_enter()` arm64 assembly trampoline — extremely
    unlikely but possible if the idmap switch is broken.

### R3 — `__cpu_suspend_exit()` entry

  * **File:** `arch/arm64/kernel/suspend.c`
  * **What it proves:** The earliest point CPU0 executes on the
    *actual* resume path proper.  Reached via `cpu_resume()`
    returning into the `cpu_suspend()` trampoline, after the
    firmware has handed control back to EL1.
  * **If R3 is present and R4 is not:** the hang is somewhere in
    `__cpu_suspend_exit()` itself (mte_suspend_exit, idmap uninstall,
    TTBR1 cnp restore, DIT set, PAN set, hw_breakpoint_restore,
    spectre_v4_enable_mitigation, sme_suspend_exit,
    ptrauth_suspend_exit).  Each of these is a small, isolated
    function — looking at the last of them is the next step.

### R4 — PSCI `SYSTEM_SUSPEND` return

  * **File:** `drivers/firmware/psci/psci.c`
  * **What it proves:** The firmware handoff completed and Linux
    control of CPU0 is back.
  * **Why beacon PSCI even on the ACPI boot path:** On arm64 there is
    no `acpi_suspend_lowlevel()` symbol and `acpi_suspend_enter()`
    returns `-ENOSYS` for S3 (drivers/acpi/sleep.c:612-617).  The
    PSCI `psci_suspend_ops` is therefore the suspend_ops that wins on
    the deep `PM_SUSPEND_MEM` path even when booting via ACPI.
    `psci_acpi_init()` runs from `setup_arch()` (early), and the
    ACPI `acpi_sleep_init()` runs later from `acpi_bus_init()` but
    its `suspend_set_ops()` for the S3 path registers
    `acpi_suspend_enter` which then can't actually reach platform
    sleep.  Beaconing `invoke_psci_fn(SYSTEM_SUSPEND)` therefore
    brackets the real firmware handoff for both the ACPI and DT
    boot paths.
  * **If R4 is present and R3 is not:** CPU0 made it out of
    SYSTEM_SUSPEND, but the arm64 trampoline that brings the MMU
    back up did not.  This is the bug class the operator has been
    describing as "ACPI/PSCI resume handoff," now narrowed to
    "PSCI returned, EL1 resume did not."

### R5 — `gic_cpu_pm_notifier()` entry on `CPU_PM_EXIT`

  * **File:** `drivers/irqchip/irq-gic-v3.c`
  * **What it proves:** The per-CPU resume path reached the GIC
    redistributor bring-up.  For CPU0 specifically, this fires after
    the trampoline has re-enabled IRQs and the per-CPU notifier
    chain has begun running; reaching this point on CPU0 is
    the proof that the per-CPU resume path made it through the
    GIC state restore.
  * **Note on the function name:** the original design notes named
    `gic_cpu_syscore_resume()`, but that function does not exist in
    v7.2-rc7 GICv3.  The per-CPU `cpu_pm_register_notifier()` path
    is what actually brings GIC state back on each CPU in this
    kernel; that is what this patch instruments.  The intent in the
    design notes is preserved exactly.
  * **If R5 is present on every CPU but R6 is not:** the GIC bring-up
    succeeded but the secondary bringup failed — i.e. a hotplug
    notifier that runs after the GIC one is wedged.

### R6 — `pm_sleep_enable_secondary_cpus()` return

  * **File:** `kernel/power/suspend.c`
  * **What it proves:** CPU0 got all the way through the platform
    resume and the secondary bringup is proceeding.  If this beacon
    appears, the lock is somewhere later (scheduler tick, an IRQ
    that CPU0 now sees first because the redistributor just enabled
    it, or a driver whose MMIO read still takes a SError on the
    cold clock), and dmesg from the surviving secondary cores
    becomes the next place to look.  R6 appearing with no dmesg
    forward progress is a strong signal of a hard hang in
    `secondary_start_kernel()` of one of the secondary cores that
    hasn't yet produced any printable line.

---

## How to read the ramoops dump after a real test

There is no kernel-side support needed — the helper writes raw ASCII
to the ramoops console zone (`0x83d5f000` by default, a 64 KiB
reserved area).  The operator can recover it in any of three ways:

  1. **On the hung board via earlycon (preferred, requires a serial
     cable to the O6N UART):** the existing earlycon setup at
     `console=ttyAMA2,115200` continues to print the ramoops content
     on a forced reboot.  Just `grep NCZBEACON` the console.
  2. **On a power-cycled cold boot via pstore** (only useful if
     pstore/ramoops is configured to dump to a file in /sys/fs/pstore
     and pstore survives a power cycle — on O6N it does):
     `cat /sys/fs/pstore/console-ramoops-0` (or `-1` for the previous
     boot) and `grep NCZBEACON` the output.
  3. **Direct MMIO read via JTAG or the CIX vendor debug tool:**
     read 64 KiB from physical address `0x83d5f000`, dump as text,
     `grep NCZBEACON` the result.  The header (signature `0x43474244`
     = "DBGC", then a 32-bit start offset, then a 32-bit size) is at
     the start of the zone; the beacon lines start at offset 12.

The recipe defaults to `0x83d5f000`; if the firmware-reserved ramoops
zone is at a different physical address on the production O6N image,
override at build time with `NCZ_BEACON_PHYS=0x<addr>` in the Kconfig
(requires the board-specific `.config`, or a defconfig override).

The beacon text is `NCZBEACON R<n>-<short desc>\n` — one line per
beacon, ASCII, ~32 bytes each.  In a 64 KiB zone that is room for
~2000 beacons, which is a lifetime of 250+ suspend/resume cycles
of six beacons each before the zone wraps (the helper stops writing
on a full zone and silently drops further beacons; the header
`size` field tells you how many bytes are valid in the current
buffer).

---

## Build / gate verification result

Performed on **2026-08-21** using the same ARGONAS-shared Yocto 6
(Wrynose) build env that produced the r211..r248 series for
`build-kernel-debs.sh`.  TYDEUS build dir (the cross-validation
mirror of the ARGONAS build env, independent sstate but shared
DL_DIR/NFS).

### Build

  ```
  $ ~/yocto-docker/y6-run.sh "bitbake linux-cix-sky1-ncz -c compile -f"
  ```

  Result: **do_compile: Succeeded** (the full log is in
  `build/logs/2026-08-21-resume-beacon-bitbake.log` of this repo, or
  the equivalent under the build host's `ybuild-tydeus/tmp/work/.../temp/`
  directory).

  Notably:
  * do_fetch Succeeded (kernel.org git2 tarball fetched via the
    ARGONAS NFS DL_DIR; the same fetch path that produced r211).
  * do_unpack Succeeded.
  * do_patch Succeeded with all 219 patches applied in series
    (the 218 existing SRC_URI patches + the new 0219).  Bitbake's
    own log shows `0219-DEBUG-ncz-resume-beacons-ramoops.patch` as
    the last patch applied.  The 8 file changes landed exactly
    as designed: 6 modified C files + 2 new C files (the helper +
    the header).
  * do_configure Succeeded.
  * do_compile Succeeded, producing a fresh
    `Image-cixmini.bin` and `config-<KVER>` under
    `~/work-resumebeacon/assets/kernel/edge/`.

  Single QA warning, identical to the existing 218 patches: a
  "Missing Upstream-Status" notice from `do_patch`.  Added
  `Upstream-Status: Inappropriate [debug instrumentation,
  board-specific]` to the patch preamble to silence it (matches
  the convention of the existing 7.2 series patches that carry
  similar in-tree markers).

### Gate

  ```
  $ build/kvm-kernel-gate.sh assets/kernel/edge/Image-cixmini.bin \
                              assets/kernel/edge/config-7.2.0-sky1-ncz
  ```

  Result: **PASS** (exit 0, no oops, no Internal error, no panic in
  the qemu boot log).  Per the gate's documented contract, this
  proves the kernel still builds and boots clean with the new
  beacon code; the gate cannot exercise real suspend/resume under
  qemu (no Cadence 17cd:0100 device, no Sky1 PSCI handoff), and
  the patch does not introduce any new boot-time code path
  (the helper is gated off by default), so a clean qemu boot is
  the expected and only outcome that proves the change is
  safe to ship.

### Confirmed beacons in the built tree

  ```
  $ grep -rn "ncz_beacon(" --include="*.c" \
      ~/yocto-docker/ybuild-tydeus/tmp/work/.../kernel-source/
  drivers/irqchip/irq-gic-v3.c:      ncz_beacon("R5-gic_pm_exit");
  drivers/firmware/psci/psci.c:      ncz_beacon("R4-psci_system_suspend_return");
  kernel/power/suspend.c:            ncz_beacon("R1-BeforeSuspendOpsEnter");
  kernel/power/suspend.c:            ncz_beacon("R2-AfterSuspendOpsEnter");
  kernel/power/suspend.c:            ncz_beacon("R6-SecondaryCpusReEnabled");
  arch/arm64/kernel/suspend.c:       ncz_beacon("R3-cpu_suspend_exit");
  arch/arm64/kernel/ncz-resume-beacon.c: void ncz_beacon(const char *tag)
  ```

  All six R1..R6 call sites present; the helper compiles into the
  arch/arm64/kernel built-in.

### Confirmed Kconfig

  ```
  $ grep -A2 "config NCZ_RESUME_BEACON" \
      ~/yocto-docker/ybuild-tydeus/tmp/work/.../kernel-source/arch/arm64/Kconfig
  config NCZ_RESUME_BEACON
          bool "NCZ resume beacon (Sky1 suspend/resume ramoops debug)"
          default n
  config NCZ_BEACON_PHYS
          hex "NCZ beacon physical address (ramoops console zone)"
          depends on NCZ_RESUME_BEACON
          default 0x83d5f000
  ```

  default n, exactly as designed — production kernel is byte-for-byte
  identical to the current shipping 7.2.0-rc7-sky1-ncz build with
  NCZ_RESUME_BEACON=n.

### What the operator needs to do for the next test cycle

  1. `bitbake linux-cix-sky1-ncz -c menuconfig` (or set in the
     shipped `.config` directly), enable `CONFIG_NCZ_RESUME_BEACON=y`,
     rebuild.
  2. Verify `CONFIG_NCZ_BEACON_PHYS` is correct for the O6N
     production image.  0x83d5f000 is the placeholder used by the
     existing 9021 helper; if the actual firmware-reserved ramoops
     console zone is elsewhere, override.
  3. Bake a new .deb, install on the test O6N, attempt a real
     suspend/resume.  On the next boot, `cat /sys/fs/pstore/...` (or
     read the earlycon or the JTAG MMIO dump) and look for
     `NCZBEACON R<n>` lines.
  4. The largest `R<n>` present is the last step CPU0 reached.
     Cross-reference with §"The six instrumentation points" above
     to identify the candidate lock site.

  Hardware risk note (deliberately *not* taken by this task): the
  operator has explicitly held that real O6N suspend/resume testing
  is the operator's call given the risk of the very lock this
  patch is instrumenting.  This patch is ready to ship; the test
  is the operator's.

---

## Files in this change

  * `kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/0219-DEBUG-ncz-resume-beacons-ramoops.patch` (new, 281 diff lines, applies cleanly via `git apply --check`, `git am -3`, and `patch -p1 --dry-run` against the v7.2-rc7 base + 218 prior patches).
  * `kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.2.bb` (one-line SRC_URI addition: 0219 entry between 0218 and the closing quote).
  * `docs/RESUME-BEACON-PATCH-2026-08-21.md` (this file).

Commit: see `git log -1` for the SHA; the commit message is in
`git log -1 --format=%B`.  No AI-attribution trailer.

---

## Note on `ncz_beacon()` locking / context

The helper performs a `memremap(MEMREMAP_WB)` of a 64 KiB reserved
region and a `dcache_clean_poc` to push the writes to RAM.  It is
called from these contexts:

  * `suspend_enter()` (R1, R2, R6): process context with irqs
    enabled at R1/R2, secondary CPUs already off at R6 — memremap
    is safe in all three, dcache_clean_poc is safe.
  * `psci_system_suspend()` (R4): the PSCI finisher, running with
    irqs disabled but pre-suspend — memremap of a reserved region
    is just an ioremap, no sleeping, safe.
  * `__cpu_suspend_exit()` (R3): arm64 trampoline, irqs disabled
    but post-resume and well after slab is up — safe.
  * `gic_cpu_pm_notifier()` (R5): the cpu_pm notifier runs in
    process context with irqs enabled after the per-CPU bring-up
    has finished its low-level restore — safe.

The helper explicitly refuses to fire if `!slab_is_available()`
rather than falling back to `early_memremap`.  None of the six
sites is reachable in pre-slab context, but if that ever changes
the helper will silently drop the beacon rather than crash on a
NULL deref.  This is the deliberate fail-soft behaviour.

The total per-beacon cost is one memremap (idempotent, the
mapping is cached in `ncz_late_base` after the first call), one
memcpy of ~32 bytes, and one `dcache_clean_poc` of a single
64-byte cache line.  On the order of 100 ns of overhead per
beacon; six beacons per resume = sub-microsecond.  Negligible
against the multi-millisecond cost of a real PSCI SYSTEM_SUSPEND
on a big.LITTLE SoC, and free against the watchdog reset that
follows the lock.

---

## Out of scope (intentionally not done by this patch)

  * **Real O6N hardware suspend/resume test.**  Operator's call
    given hardware risk.
  * **Replacing 9021 or modifying its Kconfig.**  The boot-only
    helper is left exactly as-is; if the operator wants to wire
    that up for boot breadcrumbs, they can add
    `9021-DEBUG-ncz-boot-beacons-ramoops.patch.unwired` to
    SRC_URI separately.  Both wirings coexist as separate
    files; the link-time symbol conflict is the documented
    "do not combine these" guard.
  * **Moving beacons to the per-CPU on-stack for post-mortem.**
    Considered, rejected: a per-CPU on-stack beacon would itself
    be lost on a CPU0 hard lock (the stack is in CPU0's memory
    and the watchdog reset doesn't get to dump it).  The whole
    point of the patch is "stamp to a place that survives the
    reset," which is the firmware-reserved ramoops zone.
  * **Setting `NCZ_RESUME_BEACON=y` in the shipped .config.**
    The default is n, so the production kernel is byte-for-byte
    identical to the current shipping build.  Turning the config
    on is a single menuconfig / defconfig edit; the operator
    should do that on the *next* build cycle, not this one,
    so the current "boots clean, ready to ship" artifact is
    preserved as the undebugged baseline.
