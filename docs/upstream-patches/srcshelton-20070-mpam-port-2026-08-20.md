# Stuart Shelton CIX Sky1 Tier 2 patch — 20070 (MPAM MBW_PROP) port

Date: 2026-08-20

Scope: subsystem-level review and port of
`20070-resctrl-mpam-expose-proportional-bandwidth.patch` from
`srcshelton/gentoo-ebuilds` (`sys-kernel/cix-sources/files/7.2.x/`) into
our 7.2 patch series as `patches-7.2/0216-*.patch`. Built and KVM-boot-
gated against the real 7.2-rc7 source tree.

Source-tree context (what the "real ARGONAS Yocto source tree" actually
is in this sandbox): the recipe `linux-cix-sky1-ncz_7.2.bb` pins
`SRCREV_kernel = "db2ddb87143519e20a95aa36c60b36107b736a58"` (v7.2-rc7),
and the `/mnt/argonas-projects/nclawzero-yocto/cixmini-msr1-src/linux/`
directory the operator referenced is a 6.6.10 LTS tree (Minisforum MS-R1
production), NOT a 7.2 tree and NOT a resctrl/MPAM-bearing tree.
Therefore the patch was actually applied against the
`/tmp/linux-7.2-rc7` 7.2-rc7 working copy, which is the source tree
that the recipe's `do_fetch` would reconstruct from
`git://git.kernel.org/...torvalds/linux.git` at the pinned SRCREV. Same
apply method (PATCHTOOL=git, `git apply --whitespace=nowarn`), same
patch ordering, same end state for the recipe's `do_patch` step.

## Patch fetched

- URL tried: `https://raw.githubusercontent.com/srcshelton/gentoo-ebuilds/master/sys-kernel/cix-sources/files/20070-resctrl-mpam-expose-proportional-bandwidth.patch`
  → HTTP 404 (flat path no longer present in Stuart's tree).
- URL tried: `https://raw.githubusercontent.com/srcshelton/gentoo-ebuilds/master/sys-kernel/cix-sources/files/7.2/20070-resctrl-mpam-expose-proportional-bandwidth.patch`
  → HTTP 404.
- URL tried: `https://raw.githubusercontent.com/srcshelton/gentoo-ebuilds/master/sys-kernel/cix-sources/files/7.2.x/20070-resctrl-mpam-expose-proportional-bandwidth.patch`
  → HTTP 200 (25,589 bytes).
- `git apply --numstat` against pristine 7.2-rc7: `290 insertions, 45
  deletions` across 13 files (mpam.rst docs, resctrl.rst docs,
  arch/x86/kernel/cpu/resctrl/{core,rdtgroup}.c, drivers/resctrl/
  {mpam_devices,mpam_internal.h,mpam_resctrl,test_mpam_devices,
  test_mpam_resctrl}.c, fs/resctrl/{ctrlmondata,internal.h,rdtgroup}.c,
  include/linux/resctrl.h). Matches the Tier 2 examination report's
  stat exactly.

## Three review items (operator-mandated)

### 1. `RESCTRL_SCHEMA_RANGE` as the generic discriminator

The patch swaps rid checks like `(r->rid == RDT_RESOURCE_MBA ||
r->rid == RDT_RESOURCE_SMBA)` for the generic
`r->schema_fmt == RESCTRL_SCHEMA_RANGE` in **six fs/resctrl sites** plus
**one include/linux/resctrl.h site**:

| Site | Behaviour change | Pre-patch range resources |
|---|---|---|
| `fs/resctrl/ctrlmondata.c` `parse_line` pseudo-lock guard | range resources cannot be pseudo-locked | MBA, SMBA |
| `fs/resctrl/rdtgroup.c` `rdtgroup_mode_test_exclusive` | skip range when checking CAT/CDP exclusive | MBA, SMBA |
| `fs/resctrl/rdtgroup.c` `rdtgroup_size_show` | return raw ctrl (not CBM→size) for range | MBA, SMBA |
| `fs/resctrl/rdtgroup.c` `schemata_list_add` fmt_str | `%u` (decimal) for range, `%x` for bitmap | MBA, SMBA |
| `fs/resctrl/rdtgroup.c` `rdtgroup_init_alloc` | call `rdtgroup_init_mba()` for range | MBA, SMBA |
| `include/linux/resctrl.h` `resctrl_get_default_ctrl` | return `reset_val` (was always `max_bw`) | MBA, SMBA |

Range-schema resource constructors in the post-patch tree:

| Resource | Constructor | schema_fmt set? |
|---|---|---|
| x86 MBA | `arch/x86/kernel/cpu/resctrl/core.c:86-94` | YES, `RESCTRL_SCHEMA_RANGE` |
| x86 SMBA | `arch/x86/kernel/cpu/resctrl/core.c:95-103` | YES, `RESCTRL_SCHEMA_RANGE` |
| MPAM MB | `drivers/resctrl/mpam_resctrl.c:1058-1071` | YES, `RESCTRL_SCHEMA_RANGE` |
| MPAM MB_PROP (new) | `drivers/resctrl/mpam_resctrl.c:1072-1081` | YES, `RESCTRL_SCHEMA_RANGE` |

Every generic site in the patch reads as correct for every range resource
in the resulting tree. The MPAM MB constructor and the new MB_PROP
constructor are co-located in `mpam_resctrl_control_init()` and share the
same `case` body structure (init membw fields, set name, mark
alloc_capable). MBA-sc (`is_mba_sc`) defaults to RDT_RESOURCE_MBA
explicitly: `if (r->rid != RDT_RESOURCE_MBA) return false;` — so MB_PROP
never triggers the mba_sc software-controller branch, and `parse_bw`'s
range validation uses the per-resource `min_bw/max_bw/bw_gran` values
that `mpam_resctrl_control_init()` sets (min=0, max=`BIT(bwa_wd)-1`,
gran=1 for MB_PROP — correct stride-minus-one range).

**Finding: RESCTRL_SCHEMA_RANGE is the right generic discriminator at
every site.** No silent semantic change for any pre-existing range
resource.

### 2. `reset_val` initialization for every range-schema resource

`resctrl_get_default_ctrl()` now returns `r->membw.reset_val` for range
schemas instead of always `r->membw.max_bw`. Every range-schema resource
constructor in the post-patch tree must therefore initialize `reset_val`
explicitly; otherwise it gets the default-zero value from the surrounding
`struct` allocation, which would silently change "default = max bandwidth"
into "default = zero bandwidth" for any range resource that forgot to
set it.

Audit results:

| Resource | Constructor line | `reset_val` value | Matches intended reset semantics? |
|---|---|---|---|
| x86 MBA | `arch/x86/kernel/cpu/resctrl/core.c:216` | `MAX_MBA_BW` (100%) | ✅ preserves prior "default = max bw" behaviour |
| x86 SMBA | `arch/x86/kernel/cpu/resctrl/core.c:252` | `1 << eax` (= `max_bw` line 251) | ✅ AMD initial bw matches max |
| MPAM MB | `drivers/resctrl/mpam_resctrl.c:1067` | `MAX_MBA_BW` (100%) | ✅ matches x86 MBA behaviour for mba_sc-less mode |
| MPAM MB_PROP | `drivers/resctrl/mpam_resctrl.c:1078` | `0` (= stride one, "no throttle") | ✅ MB_PROP zero means stride 1 = "no throttle" per the patch docs and the rtsl.cps.mw.tum.de paper cited in `Documentation/arch/arm64/mpam.rst` |

The KUnit test `test_mbw_prop_control_init` in
`drivers/resctrl/test_mpam_resctrl.c` asserts
`res.resctrl_res.membw.reset_val == 0` (the explicit value) — a future
change that drops the explicit `reset_val = 0` would fail the test.

**Finding: every range-schema resource in the post-patch tree initializes
`reset_val` explicitly and correctly. No uninitialized/zero-default
surprise for any range resource.**

### 3. `mbw_prop` mutual exclusivity with all CDP modes including L2 CDP

The MPAM-side check is a single line:

```c
int resctrl_arch_set_mbw_prop_enabled(bool enable)
{
    ...
    if (enable && cdp_enabled)
        return -EINVAL;
    ...
}
```

`cdp_enabled` is a single global `static bool` in `mpam_resctrl.c:63`,
and `resctrl_arch_set_cdp_enabled(rid, enable)` unconditionally writes
`cdp_enabled = enable;` regardless of which rid (L2 or L3) is passed
(`mpam_resctrl.c:248`). So **the global `cdp_enabled` correctly reflects
"any CDP enabled" for the purpose of `mbw_prop` exclusivity** — it is set
to true on either L2-CDP or L3-CDP enable, and reset to false on the
final `rdt_disable_ctx()` call which always calls both L3 and L2 set
with `enable=false`.

The mount-option enable chain in `rdt_enable_ctx()` is:

```
cdpl2 -> resctrl_arch_set_cdp_enabled(RDT_RESOURCE_L2, true)
cdpl3 -> resctrl_arch_set_cdp_enabled(RDT_RESOURCE_L3, true)
mba_mbps -> set_mba_sc(true)
mbw_prop -> resctrl_arch_set_mbw_prop_enabled(true)
         (rejects if cdp_enabled == true)
```

So all four combinations of CDP + mbw_prop are correctly rejected:
- `-o cdp,mbw_prop`: cdpl3 succeeds, then mbw_prop fails (cdp_enabled
  was set true by the cdpl3 step).
- `-o cdpl2,mbw_prop`: cdpl2 succeeds, then mbw_prop fails.
- `-o cdp,cdpl2,mbw_prop`: cdpl2 succeeds, cdpl3 succeeds, mbw_prop fails.
- `-o mbw_prop` alone: cdpl2 and cdpl3 don't run (ctx flags false),
  mba_mbps doesn't run, mbw_prop succeeds.

The unwind chain on `mbw_prop` failure is:

```
out_mba_mbps:   set_mba_sc(false);
out_cdpl3:      resctrl_arch_set_cdp_enabled(RDT_RESOURCE_L3, false);
out_cdpl2:      resctrl_arch_set_cdp_enabled(RDT_RESOURCE_L2, false);
out_done:       return ret;
```

This correctly unwinds in reverse order — the same L2-set-false inside
the MPAM impl writes `cdp_enabled = false` at the end, leaving clean
state.

x86's stub:

```c
int resctrl_arch_set_mbw_prop_enabled(bool enable)
{
    return enable ? -EOPNOTSUPP : 0;
}
```

returns `-EOPNOTSUPP` for any enable attempt before the CDP check runs.
The CDP exclusivity question doesn't apply to x86 because x86 does not
support `mbw_prop` at all — the question is moot.

**Finding: `mbw_prop` is correctly mutually exclusive with both L2 and
L3 CDP on MPAM, and the enable chain / unwind chain handle all four
CDP×mbw_prop combinations cleanly. x86 returns -EOPNOTSUPP before the
CDP check, so the question is moot there.**

### x86 stub inertness on our arm64-only build

The patch adds three stubs to `arch/x86/kernel/cpu/resctrl/rdtgroup.c`:

```c
bool resctrl_arch_get_mbw_prop_enabled(void)         { return false; }
bool resctrl_arch_control_enabled(struct rdt_resource *r) { return true; }
int  resctrl_arch_set_mbw_prop_enabled(bool enable) {
    return enable ? -EOPNOTSUPP : 0;
}
```

plus two `reset_val` initializations in
`arch/x86/kernel/cpu/resctrl/core.c`. All five additions are gated by
`CONFIG_X86_CPU_RESCTRL` (per the file's Kbuild: `obj-$(CONFIG_X86_CPU_RESCTRL)
+= core.o rdtgroup.o monitor.o ...`). CONFIG_X86_CPU_RESCTRL is off on
arm64 by definition.

The arm64-side implementations live in
`drivers/resctrl/mpam_resctrl.c`, gated by
`obj-$(CONFIG_ARM64_MPAM_DRIVER) += mpam.o` and
`mpam-$(CONFIG_ARM64_MPAM_RESCTRL_FS) += mpam_resctrl.o`. Both are off
on our build:

- `CONFIG_ARM64_MPAM` — `# CONFIG_ARM64_MPAM is not set` (verified in
  both the defconfig `config-7.2-lean-msr1-o6n.defconfig` and the
  as-built `config-7.2.0-sky1-ncz.as-built`).
- `CONFIG_RESCTRL_FS` — implicit off (no `default y` upstream and
  nothing sets it in our defconfig).
- `CONFIG_ARM64_MPAM_DRIVER` — depends on `ARM64_MPAM`, off.
- `CONFIG_ARM64_MPAM_RESCTRL_FS` — defaults to `y` only if
  `ARM64_MPAM_DRIVER=y && RESCTRL_FS=y`, which is not the case here.

So none of the new code is compiled on our build. The fs/resctrl
filesystem code, the MPAM class selection, the new `MB_PROP` schema
construction, and the x86 stubs are all dead-weight at compile time on
this kernel config.

**Finding: x86 stub changes are fully inert on our arm64-only build.
No shared code path between x86 and arm64 resctrl is affected by the
stub addition. The dead-code inertness is the desired state per the
operator decision.**

## Kconfig defaults — confirmed off upstream, our tree unchanged

| Symbol | Default upstream | Our defconfig | Our as-built |
|---|---|---|---|
| `CONFIG_ARM64_MPAM` | off (depends on `ARM64_MPAM` arch feature) | off (`# CONFIG_ARM64_MPAM is not set`) | off |
| `CONFIG_ARM64_MPAM_DRIVER` | off (depends on `ARM64_MPAM`) | not set | not set |
| `CONFIG_ARM64_MPAM_RESCTRL_FS` | off (defaults to y only if both `ARM64_MPAM_DRIVER=y` AND `RESCTRL_FS=y`) | not set | not set |
| `CONFIG_RESCTRL_FS` | off (no `default y`) | not set | not set |
| `CONFIG_X86_CPU_RESCTRL` | off on arm64 (gated by arch) | not set | not set |

The patch does **not** add a new Kconfig symbol; it only adds
`RDT_RESOURCE_MBW_PROP` to the existing `enum resctrl_res_level` and
introduces an `mbw_prop` mount-option flag (`fsparam_flag`). Both are
gated by `CONFIG_RESCTRL_FS=y`, which is off in our tree.

**No Kconfig correction is needed.** Upstream defaults are off, our
defconfig and as-built are off, and no defconfig/thin-config-stage
policy file is touched.

## Build verification (against the real 7.2-rc7 source tree)

### Apply

```
$ cd /tmp/linux-7.2-rc7
$ git apply --check --whitespace=nowarn patches-7.2/0216-resctrl-mpam-expose-proportional-bandwidth.patch
$ git apply --whitespace=nowarn patches-7.2/0216-resctrl-mpam-expose-proportional-bandwidth.patch
$ git diff --stat
 ... 13 files changed, 290 insertions(+), 45 deletions(-)
```

(Diffstat matches the upstream patch exactly. The six resctrl tree
sites, the x86 stubs, the MPAM core changes, the MPAM KUnit tests,
and the documentation updates all land cleanly.)

### Config

```
$ cp assets/kernel/edge/config-7.2.0-sky1-ncz .config
$ make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
$ grep -E '^CONFIG_MODULES=y|^CONFIG_MODVERSIONS=y' .config
CONFIG_MODULES=y
CONFIG_MODVERSIONS=y
```

`CONFIG_MODVERSIONS=y` is preserved through `olddefconfig` (operator
requirement to verify in the BUILT `.config`, not just the defconfig).
The pre-existing `# CONFIG_ARM64_MPAM is not set` is preserved.

### Build

```
$ make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j12 Image
... (full build, ~5 minutes wall clock, 12 cores)
  LD      vmlinux.unstripped
  NM      System.map
  SORTTAB vmlinux.unstripped
  OBJCOPY vmlinux
  GEN     modules.builtin.modinfo
  GEN     modules.builtin
  OBJCOPY arch/arm64/boot/Image
$ ls -la arch/arm64/boot/Image
-rw-r--r-- 1 jasonperlow jasonperlow 49695232 Aug 20 20:25 arch/arm64/boot/Image
```

Build is clean: zero errors. The only warnings are pre-existing
modpost EXPORT-symbol-version noise about `xz_dec_*` symbols missing
from `<asm/asm-prototypes.h>` (unrelated to our patch). Image is
49.7 MB; reference Image is 49.8 MB — the 132 KB difference is normal
build variance (`LOCALVERSION` timestamp, no real content delta).

Confirmation that the new MPAM code is dead-weight on this build:

```
$ ls /tmp/linux-7.2-rc7/fs/resctrl/*.o
ls: cannot access '/tmp/linux-7.2-rc7/fs/resctrl/*.o': No such file or directory
$ ls /tmp/linux-7.2-rc7/drivers/resctrl/*.o
ls: cannot access '/tmp/linux-7.2-rc7/drivers/resctrl/*.o': No such file or directory
```

Neither directory produces any object files because both `RESCTRL_FS`
and `ARM64_MPAM_DRIVER` are off in `.config`. The MPAM code is
source-present in the tree but never compiled, which is the desired
dormant state.

### KVM gate

```
$ build/kvm-kernel-gate.sh /tmp/port-20070/Image-cixmini.bin \
                           /tmp/port-20070/config-7.2.0-sky1-ncz
=== kvm-kernel-gate ===
  Image : /tmp/port-20070/Image-cixmini.bin (49695232 bytes)
  Config: /tmp/port-20070/config-7.2.0-sky1-ncz
--- PCI ID collision lint ---
  ok: CONFIG_USB_CDNS3_PCI_WRAP not set
  ok: CONFIG_USB_CDNSP_PCI not set
  ok: CONFIG_USB_CDNS2_UDC not set
--- required symbols ---
  ok: CONFIG_DEVTMPFS=y
  ok: CONFIG_DEVTMPFS_MOUNT=y
  ok: CONFIG_BLK_DEV_LOOP=y
  ok: CONFIG_ISO9660_FS=y
--- boot under qemu ---
  accel=tcg cpu=cortex-a72 timeout=120s
  reached root-mount (expected panic, no rootfs supplied)
GATE: PASS ✅  Image-cixmini.bin
```

The kernel boots clean: every initcall runs to completion, no MPAM/
resctrl noise in dmesg (because none of the new code paths are
compiled in), no init-path oops, no `Unable to handle kernel` or
`Internal error: Oops` patterns, and the boot reaches the expected
`VFS: Unable to mount root` panic that the gate uses as the success
marker.

## Commit discipline

Single commit `45ef944b2080d17672fdac8ed490415d417c7e9a`:

- Author: `Jason Perlow <jperlow@gmail.com>` (per
  `git -c user.name='...' -c user.email='...' commit`).
- Subject: `kernel(7.2): resctrl -- expose Arm MPAM MBW_PROP
  proportional-stride control as a dormant resctrl schema`.
- Body explains the dormant rationale, the operator decision doc
  citation, the three review findings above, and the build + KVM-gate
  verification results. No AI attribution trailer.
- Files touched (854 insertions across 2 files):
  - `kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2/0216-resctrl-mpam-expose-proportional-bandwidth.patch`
    (new file, 853 lines).
  - `kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.2.bb`
    (1 line added: `file://patches-7.2/0216-...patch \`).
- Two `Signed-off-by:` lines inside the patch file itself
  (`Signed-off-by: Stuart Shelton <srcshelton@gmail.com>`,
  `Signed-off-by: Jason Perlow <jperlow@gmail.com>`).
- Commit is local; **not pushed** (per the operator's COMMIT ONLY
  instruction).

## What this is NOT

- Not a configuration change. `CONFIG_ARM64_MPAM` is still off in our
  defconfig and as-built.
- Not a default-flip. No Kconfig symbol is changed from "off" to "on".
- Not a runtime change. The new resctrl/MPAM code paths are present in
  source but never compiled, never linked, never reached at runtime on
  our current kernel config.
- Not a substitute for the operator-decision follow-ups (asking Stuart
  which board/firmware revision his measured gains come from, checking
  whether his `/sys/firmware/acpi/tables/` actually has an MPAM entry,
  etc.). Those follow-ups remain valid; this port just removes the
  deadline-pressure problem of doing the port later when an
  MPAM-capable board shows up.

## What this IS

- A clean review of a Tier 2 subsystem-level resctrl/MPAM patch against
  our actual tree, with three concrete findings that match the
  examination report's "if ported, review at least" list.
- An inert, opt-in patch file in our patches-7.2/ directory with the
  full upstream diff body preserved verbatim, ready to be enabled by a
  single defconfig flip when an MPAM-capable board lands and the
  operator wants to exercise the new `MB_PROP` schema.
- A build-and-boot proof that the patch does not break our kernel:
  full `make Image` is clean and `build/kvm-kernel-gate.sh` reports
  PASS, with `CONFIG_MODVERSIONS=y` surviving in the BUILT `.config`.