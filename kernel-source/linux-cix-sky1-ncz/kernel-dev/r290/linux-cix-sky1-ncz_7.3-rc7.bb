# SPDX-FileCopyrightText: Copyright (c) 2026 Jason Perlow
# SPDX-License-Identifier: Apache-2.0
#
# r290 (2026-10-13, PR r3, kernel-dev track): r289 plus
# - CONFIG_VIDEO_LINLON not set, and 0022 so that the in-tree VPU driver is
#   really not built (cix/Kbuild otherwise falls back to obj-m): the VPU
#   driver (amvx) ships only as the cix-vpu-driver DKMS module; an in-tree
#   amvx.ko with the same name could load in its place without any error
#   (see config-7.3-rc7.defconfig);
# - 0023-0026 display fixes (linlondp): clocks running across the firmware
#   takeover with every firmware pipeline stopped, flip-timeout recovery that
#   leaves the other output alone and remodesets the affected CRTC, engine
#   clock set while the unit is inactive and raised for a second output,
#   overlay planes spread over all outputs above the DRM plane limit;
# - 0027-0028 PCIe: no 0000:0000 root port ID, and the vendor driver reports
#   the CIX root port ID 1f6c:0001 in native mode (as mainline pci-sky1 does).
# The same series is the commit history of linux-cix branch
# kernel-dev/sky1-7.3.0-rc7-r290 on top of release/sky1-7.3.0-rc7-r289.
#
# r289 (2026-10-12): the COMPLETE Sky1 rc7 kernel. This recipe is the r287
# recipe (fully guarded; RT_GROUP_SCHED=n; 0001-0011 + 0013-0021 CIX q3 sync)
# ported to the 7.3-rc7 line. It supersedes r288 (fix/sky1-rc7-20261011),
# which was branched from the pre-r284 lineage and applied ONLY the
# consolidated port patch (missing 0001-0011, 0013-0021 and every r283/r285
# defconfig fix; RT_GROUP_SCHED=y). The DP AUX-wedge recovery v2 is folded
# INTO sky1-ncz-v7.3-rc7-port.patch (it is NOT a separate patch here).
#
# Linux kernel for Cix Sky1 / CP8180 -- NCZ 7.3 track (NEXT/test, not yet
# the shipping/stable release -- that is 7.2.x, see linux-cix-sky1-ncz_7.2.bb).
#
# Base: torvalds mainline v7.3-rc7, peeled commit ec8bf8280261294a9b9b4520414b42704c7f9f6b.
# (v7.3-rc7 is NOT in linux-stable -- rc tags live in Linus's tree. Stable's
# refs/tags/v7.3-rc7^{} is absent; torvalds's refs/tags/v7.3-rc7^{} resolves
# to 24a19b953e2a3d0ea5a8c4951a0ab8f32720c907.)
#
# The recipe pins the peeled upstream v7.3-rc7 commit in SRCREV_kernel and
# applies the complete, rebased CIX port as sky1-ncz-v7.3-rc7-port.patch
# (which also carries the DP AUX-wedge recovery v2).
# The equivalent 207-commit review branch is kernel-73rc7-port-20261011.
#
# Patch decisions vs. the dry-run 205-patch replay (accepted the
# review advisory 2026-09-29; each item re-verified against source, see
# the 2026-09-29 Sky1 rc5 advisory implementation report).
# The raw 7.2 patches below are superseded by the consolidated diff of the
# kernel-73rc7-port-20261011 branch; this recipe ALSO applies the numbered
# review/q3 patches 0001-0011 and 0013-0021 (see SRC_URI). "drop" below means
# "the raw patch is not re-applied", NOT "its content is absent from the tree".
#   0027 (Cadence Sky1 vendor PCIe) and 0029 (Cadence ACPI clock release):
#        mainline b5672f9463f2 / ea34744eb094 / d70e964dc099 add the HPA flag
#        and LTSSM debugfs only; they do NOT cover 0027. The port carried
#        cdns_pcie_hpa_host_restore() (65108d59b2be), register_syscore() and
#        the LMR base block (23d4657ab234). The rest (HPA ECAM region,
#        sky1_cdns_pcie_find_capability(), HPA root-port base, the
#        "sky1-pcie-cix" rename, ACPI vendor-id/device-id/no-inbound-bar)
#        and 0029's CLKT-keyed clocks are re-ported for native mode in
#        0002-PCI-cadence-sky1-cix-restore-ACPI-native-mode-on-v7.3.patch
#        (decision 2026-09-29: native PCIe wanted on 7.3), plus the
#        review fixes in 0004 (clock error paths, AER re-enable, pdev name,
#        ECAM size). Default
#        cmdline sky1_pcie_native=off is unchanged.
#   0058 (fwnode_drm_find_panel export): dropped. Its forward-port
#        3d3bd1842516 is reverted and the only caller (0008 trilin_dp_probe)
#        is re-aimed at the counted of_drm_find_panel() by
#        0001-drm-cix-trilin-dp-drop-fwnode_drm_find_panel-use-cou.patch below;
#        drm_panel.[ch] are byte-identical to v7.3-rc6 again.
#   0074 (6.6->7.2 API drift): not re-applied. H1-H14 are present in the port
#        tree; H15-H17 are superseded by the 0172-shaped cix_scmi_em.[ch] from
#        9fa83019a3ea (not by 0066/0068/0069, whose 0069 copy still called
#        perf_ops->device_domain_id()).
#   0004/0005/0065/0105: not re-applied (there is no per-patch SRC_URI to
#        delete them from). 0105 is covered (no .prepare op, no put_noidle).
#        0004/0005/0065 are only PARTLY covered by mainline 3730fe6032d9 /
#        7cd3ca90d921 / b5fa9d3beec4 (DT AUDSS clock + reset). Their ACPI
#        halves are load-bearing and stay: CIXHA010 provider a4de88c36585,
#        reset ACPI lookup db1fd834dae3 + cad63faa518b, AUDSS CIXH6061 match
#        77b1624778cc.
#   NPU in-tree chain 0119 0120 0121 0123 0125 0159 0220: DROPPED BY POLICY.
#        The NPU ships as the DKMS cix-npu-driver (aipu), never in-tree
#        (port commit 3da51e546c4b records the verdict).
#   CLKT chain 0096 0138 0147 0148 0157 0168: drivers/clk/cix is identical
#        to the r277 (v7.2.8) tree except clk-sky1-audss.c (mainline driver
#        + port fixes), so the chain is at r277 parity; nothing to port.
#   0172: carried by 9fa83019a3ea. cix_scmi_register_em() is called by the
#        out-of-tree mali_kbase DKMS (mali_kbase_devfreq.c), not in-tree.
#   0089: acpi_clk.c half present; the runtime-PM early-boot gate is
#        re-ported in 0003-PM-runtime-restore-the-CIX-Sky1-early-boot-runtime-P.patch.
#   0001 and 0091: already carried (0001: 3d7823f9c2b2 + 535db5995054;
#        0091: 6d3cab5b0154 + 9291c638f97a).
#   0212 (cacheinfo PPTT global IDs): NOT ported; no 7.3 failure has been
#        observed; the r279 boot sheet compares cache topology with 7.2.8.
#   0216 (resctrl MB_PROP): NOT ported; inert (CONFIG_ARM64_MPAM is off).
#   r279 config: CONFIG_MODULE_COMPRESS off (project rule: never xz a .ko).
#
# Expected replay result: ~178 applied of 205, matching rc3/rc4 exactly.
# rc4 and rc5 have an identical failure set, so a result close to that is
# CORRECT, not a regression. rc3 and rc4 both already shipped as Sky1 test
# kernels on this same footing.
#
# Provenance (2026-09-09): dry-run replay of the full 205-patch series
# (build/port-series.sh v7.3-rc2, from the linux-port-v7.3-rc2 working tree)
# applied 168/203 cleanly; the 35 failures (mailbox/clk-cix ACPI+SCMI bridge
# cluster, armchina/Zhouyi NPU driver cluster, usb-cdns3 Sky1 wrapper,
# cacheinfo, resctrl-mpam) were then individually re-derived against the
# real v7.3-rc2 diff and landed as 11 real forward-port commits on top of
# the dry-run base, ending at kernel-73rc2-port HEAD 03ba72644afe.
#
# 2026-09-11: First real bitbake compile found additional forward-port
# gaps that were not reachable by dry-run patch replay:
# - PCI: cadence: add Sky1 IP Local Management Registers base block
#   (commit 4f84181bfab4) -- CIX-added offset macros used by Sky1 I_*
#   helpers in pci-sky1-cix.c, simply missing from this branch.
# Bumped SRCREV_kernel to current HEAD 4f84181bfab4.
#
# NOT YET DONE as of this recipe's authoring: a real bitbake compile of this
# tree. Patches applying/replaying cleanly is not proof the kernel builds or
# boots (see the project's kernel build checklist) -- that is exactly
# what pulling this recipe into a real Yocto build is for. Full
# kernel-build-checklist.md gates (dkms-abi-gate, kvm-kernel-gate,
# CONFIG_MODVERSIONS=y, boot on O6N only/human-supervised) all still apply
# before this track is ever considered for shipping.

# r283 (2026-10-06, PR r2): config-only respin of r282. Same SRCREV_kernel and
# the same sky1-ncz-v7.3-rc6-port.patch (sha256 9be6f5f3...c6594); the only
# changes are in config-7.3-rc6.defconfig (see its "r283" block):
#   DMABUF_DEBUG=n, DEBUG_INFO_BTF=y (+ DWARF, BTF_MODULES),
#   DRM_PANIC_SCREEN="kmsg", SQUASHFS_ZSTD=y, MT7921U/MT7925U/RTW89_8922DE=m.
# BTF build requirements:
#   - pahole >= 1.22 (Kconfig PAHOLE_VERSION >= 122). Provided by meta-oe
#     pahole-native (1.31 in wrynose). Kconfig probes pahole at configure time,
#     so without it olddefconfig silently drops DEBUG_INFO_BTF; the
#     do_configure:append check below turns that into a hard failure.
#   - resolve_btfids is a host tool built from the kernel tree; it needs host
#     libelf (elfutils-native).
#   - Out-of-tree modules built against a full build tree (vmlinux present)
#     need pahole on PATH too; DKMS builds against the headers package (no
#     vmlinux) print "Skipping BTF generation" and still succeed.
# DEBUG_INFO also puts DWARF into every module, so modules_install strips
# with --strip-debug (INSTALL_MOD_STRIP=1). That keeps .BTF and the GNU
# build-id note and leaves the shipped modules the same size class as r282.

# r284 (2026-10-06, PR r3): r283 plus the four r279 patches that r282/r283
# lost. The rc6 recipe (d8e7da34) was branched from d3176d61 before the r279
# commits 3014e78f / c6203a8b, so its decision comment above described
# 0001-0004 while SRC_URI applied none of them. They are restored verbatim
# (diff bodies byte-identical to r279; headers keep the original author and
# Signed-off-by) and apply in order on v7.3-rc6 + sky1-ncz-v7.3-rc6-port.patch
# with no offset or fuzz:
#   0001 trilin-dp: counted OF panel lookup, fwnode_drm_find_panel() dropped
#   0002 sky1-cix: ACPI native PCIe on v7.3, vendor driver "sky1-pcie-cix"
#        (fixes "Driver 'sky1-pcie' is already registered" at boot)
#   0003 PM: runtime: CIX early-boot runtime-PM gate ("cix_pm: system ready")
#   0004 sky1-cix: native-mode review fixes (clocks, AER, pdev name, ECAM)
# The source delta against the base tag is content-identical to r279's
# (v7.3-rc5 + rc5 port + 0001-0004). The defconfig is unchanged from r283;
# the r279 defconfig carried nothing r283 lacks. Default cmdline
# sky1_pcie_native=off is unchanged. r284_patch_check (a do_patch postfunc)
# fails the build if any of the four is missing from the patched tree.

# r285 (2026-10-06, PR r4): r284 plus 0005, the CIX 0028 ACPI regulator
# support that the v7.3 port dropped (deferred in linux-cix 65fa8cfadb02).
# Without it every ACPI PRP0001 "regulator-fixed" node fails with
# "probe with driver reg-fixed-voltage failed with error -12": mainline
# fixed.c reads config only from OF or platform data, and finds neither, so
# config is NULL. The firmware DLKL tables link those rails to the RTL8127
# root ports with device_link_add(..., 0), a managed link. So since r284
# brought native PCIe back, sky1-pcie-cix.2 and .3 stayed at "supplier
# PRP0001:11/10 not ready" and the O6N had no Ethernet. fw_devlink=permissive
# does not release these links (they are explicit, not inferred). 0005 is
# the r277 (v7.2.7) regulator code. fwnode_regulator.c, fixed.c, internal.h,
# fwnode_regulator.h and driver.h are byte-identical to it, plus one brace
# fix in regulator_init_coupling(). It changes the struct regulator_desc and
# regulator_config layout, so do a full rebuild with DKMS overlays rebuilt.
# r285_patch_check fails the build if 0005 is missing.
#
# r285 also carries the dmesg-noise fixes from the O6N r284 validation
# (2026-10-06). Each is a cause fix, not a loglevel change:
#   0006 pinctrl: acpi: defer consumers until the named pin controller
#        registers ("sbsa-uart ARMH0011:02: pctldev with ACPI name
#        '\_SB.MUX0' not found": COM2 enumerates before MUX0 and ran
#        without its pin state; the deferral leaked maps, now freed)
#   0007 usb: cdns3: cdnsp-sky1: hold the ACPI wrapper active until its
#        children bind (10x "runtime PM trying to activate child device
#        CIXH2031:0N but parent (CIXH2030:0N) is not active"; the 0003
#        gate let the wrapper suspend before the DLKL-linked child probed)
#   0008 clk: cix: sky1-audss: resolve ACPI parent clocks by connection ID
#        ("clock x8k/x11k/sys/48m not ready (-2)": the DSDT CLKT names them
#        audio_clk0/2/4/5; the composite parents were global-name-only, so
#        every I2S mux was orphaned and MS-R1 playback failed with
#        "cdns-i2s-mc ...: clk freq 0 is too low")
#   0009 backlight: pwm: restore CIX Sky1 ACPI backlight support (v7.2.7
#        0169924d1898, never on kernel-73rc6-port; "CIXH5040: deferred
#        probe pending: supplier CIXH5041 not ready")
#   0010 drm/cix: linlondp: don't warn about DPUs the firmware disabled
#        (O6N DPU2/DPU3 have _STA 0; "no physical node (trimmed?)")
#   0011 arm64: cpufeature: treat ID_AA64MMFR1_EL1.SpecSEI as non-strict
#        (A720 0 vs A520 1: "SANITY CHECK: Unexpected variation" x4 and
#        TAINT_CPU_OUT_OF_SPEC)
# Config (config-7.3-rc6.defconfig "r285" block): CRYPTO_ZSTD=m (zram-
# generator's modprobe crypto-zstd failed every boot) and I2C_CHARDEV=m
# (KNOWN-ISSUES item 6, fwupd /dev/i2c-*). The PCIe default is unchanged:
# installed and installer entries keep sky1_pcie_native=off pcie_pnp_en.
# Not kernel bugs and handled in cix-installer: the ramoops "already
# initialized" -22 (cmdline ramoops.* duplicates the ACPI RAOP node and
# oversizes it into rdr_ap_adapter), rtl8125b-2.fw missing in the d-i
# initrd, mali "Unbalanced pm_runtime_enable" (DKMS detach path).

LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://COPYING;md5=6bc538ed5bd9a7fc9398086aedcd7e46"

inherit kernel
FILESEXTRAPATHS:prepend := "${THISDIR}/linux-cix-sky1-ncz-7.3-rc7:"

LINUX_VERSION = "7.3-rc7"
KERNEL_LOCALVERSION = "-sky1-ncz"
PV = "7.3-rc7+ncz"
PR = "r3"
KBRANCH = "kernel-73rc7-port-20261011"
KERNEL_PACKAGE_NAME = "kernel-${PN}"

do_shared_workdir:append() {
    shared_kernel_dir="${TMPDIR}/work-shared/${MACHINE}"
    install -d "$shared_kernel_dir"
    ln -sfn "${S}" "$shared_kernel_dir/kernel-source"
    ln -sfn "${WORKDIR}/kernel-build-artifacts" "$shared_kernel_dir/kernel-build-artifacts"
    ln -sfn "${KERNEL_PACKAGE_NAME}-abiversion" "${WORKDIR}/kernel-build-artifacts/kernel-abiversion"
    ln -sfn "${KERNEL_PACKAGE_NAME}-localversion" "${WORKDIR}/kernel-build-artifacts/kernel-localversion"
}

# kernel-73rc2-port HEAD. Brief prior to this commit claimed the PCI commit
# had SHA 4f84181bfab456e9b8dbabb47fbb02f6c7f48d6c, but that hash does NOT
# exist in the repo -- the actual stored object has SHA
# 4f84181bfab41cd1253d09f444d0544f2eb5022f (verified via zlib decompress
# of the loose object on disk: real SHA1 of the stored commit content is
# the 1cd1253d... one, not 56e9b8...). Bitbake's git fetcher happily reports
# the bare 40-char string back on rev-parse even when the object is absent,
# so the bogus hash made the recipe LOOK valid while the actual fetch
# failed with 'Unable to find revision ... even from upstream'.
#
# After PCI was fixed, two more real bugs landed on top of it:
#   f924ac6d2942 cix: acpi: dsdt_override: switch asm/unaligned.h to
#                    linux/unaligned.h
#   0c37f837d3a7 cix: ddr-lp: fix platform_driver .remove signature
#                   (int -> void)
# 2026-09-11 (2nd bitbake attempt): compile failed on a 4th platform_driver
# .remove() int->void mismatch, cix_aec_remove() in cix-acpi-ec.c (same class
# as cix_ddrlp_remove -- see kernel-build-checklist.md). Audited all 5
# CIX .remove= assignments in the port tree against the 7.2.5 reference;
# only this one and cix_ddrlp_remove needed the fix. Fixed in commit
# 1aa3075a23ea.
#
# SRCREV_kernel is now the tip of kernel-73rc2-port (1aa3075a23ea) so the
# build picks up all four forward-port fixes together.
# 2026-09-11 (3rd bitbake attempt): compile failed on 2 more bugs:
# 1) cix_aec_gpio_set() in cix-acpi-ec-gpio.c was void, but this gpiolib
#    still has gpio_chip.set as int-returning (matches 7.2.5 reference,
#    which is int) -- reverted to int, return 0.
# 2) cix-plat.cs whole CONFIG_CIX_SMMU_ATTACH_NOTIFIER block was missing
#    its ifdef guards -- a dropped hunk of 7.2 series patch 0074 (the
#    same patch that supplied the cix_ddrlp_remove fix; only that sibling
#    hunk landed). Restored the guards verbatim from patch 0074; the
#    option is unset in the built .config so the block now compiles out,
#    matching 7.2.5s working behavior byte-for-byte.
#
# SRCREV_kernel is now the tip of kernel-73rc2-port (ef818e8dc33d) so
# the build picks up all six forward-port fixes together.
# 2026-09-11 (4th bitbake attempt): compile failed on a missing header
# linux/cix/cix_scmi_em.h. The cix_scmi_em.c file in the port was the
# pre-0074 single-arg cix_scmi_register_em(struct device *dev) version
# from patch 0069 (last commit touching it: 63f4b57c286f), and the header
# file itself was never carried into this tree at all -- both 0074
# (which CREATED include/linux/cix/cix_scmi_em.h) and 0172 (which evolved
# both to the 2-arg cix_scmi_register_em(dev, perf_dev) signature using
# scmi_perf_domain_power_scale()/est_power()) never landed on this
# forward-port. This is the same missing-patch-never-carried-into-7.3
# sub-pattern the loop instructions explicitly call out for missing-header
# failures (see ef818e8dc33d commit message). Copied both files
# byte-for-byte from the 7.2.5 reference tree (.../7.2.5+ncz/kernel-
# source/) -- the post-copy diff against the reference is zero. No API
# drift detected: include/linux/scmi_perf_domain.h exists in 7.3-rc2
# with the required helper signatures, and CONFIG_CIX_SCMI_ENERGY_MODEL
# is defined in drivers/thermal/cix/Kconfig.
# SRCREV_kernel is now the tip of kernel-73rc2-port (ebb3f4e1874e) so
# the build picks up all seven forward-port fixes together.
# 2026-09-11 (5th bitbake attempt): compile passed do_compile but FAILED
# at the final vmlinux link stage -- cdns_pcie_host_restore undefined.
# Root cause: pci-sky1-cix.c's sky1_pcie_resume_noirq() calls
# cdns_pcie_host_restore(rc) (extern + 2 call sites), but no such
# function exists anywhere in this tree (grep confirms: zero
# definitions, only the extern decl + the call sites in pci-sky1-cix.c).
# The 7.2.5 reference uses cdns_pcie_hpa_host_restore() (note the _hpa
# infix), defined in pcie-cadence-host-hpa.c:471 and prototyped in
# pcie-cadence.h:486. The 7.3-rc2 port renamed it to the wrong shorter
# name during the forward-port without adding a corresponding
# definition -- same missing-patch-carried-forward sub-pattern as the
# cix_scmi_em fix (ebb3f4e1874e) and the cix-plat SMMU guards
# (ef818e8dc33d). 7.2 series patch
# 0027-pci-cadence-sky1-cix-fix-sky1-cix-vendor-pcie-driver.patch
# contains the cdns_pcie_hpa_host_restore() definition but the
# corresponding hunk was never ported.
# Fix: restored the _hpa infix at the 2 call sites in pci-sky1-cix.c,
# added the missing function definition to pcie-cadence-host-hpa.c
# (copied from 7.2.5 line 471, with one trivial substitution:
# cdns_pcie_link_up -> cdns_pcie_hpa_link_up to match the HPA link-up
# callback name in this tree), added the prototype + static inline
# fallback to pcie-cadence.h (mirroring 7.2.5 lines 486 and 507-510),
# removed the now-redundant local extern decl from pci-sky1-cix.c.
# See commit 78a45c61229d for the full commit message.
# SRCREV_kernel is now the tip of kernel-73rc2-port (78a45c61229d) so
# the build picks up all eight forward-port fixes together.
# 2026-09-11 (6th bitbake attempt): vmlinux compiled clean (no more
# cdns_pcie_hpa_host_restore link error), do_compile_kernelmodules
# then failed on a single cix_edp_panel.c call to
# of_drm_get_panel_orientation() -- the symbol was renamed upstream
# to drm_of_get_panel_orientation() in 7.3 (declaration moved from
# include/drm/drm_panel.h to include/drm/drm_of.h:52, signature
# unchanged). Both 7.2.5 reference and 7.3-rc2 cix_edp_panel.c still
# use the old name, but only the 7.3-rc2 build fails because the old
# symbol no longer exists in this tree. Grep of all 7.2 patches shows
# no patch touches the symbol name -- this is a NEW upstream API
# rename the 7.3-rc2 forward-port didn't pick up, not a dropped hunk
# of an existing patch. Renamed the call site + added <drm/drm_of.h>
# include. vmlinux now builds clean and modules have begun compiling.
# See commit aec39fe3c662.
# SRCREV_kernel is now the tip of kernel-73rc2-port (aec39fe3c662) so
# the build picks up all nine forward-port fixes together.
# 2026-09-12 (7th bitbake attempt): real-metal boot-test on O6N
# (a lab board) of the aec39fe3c662 kernel exposed a 10th bug this
# session, in a new sub-class: a forward-port that re-ported ONE
# hunk of a multi-hunk 7.2 patch but forgot its sibling. SCMI
# channel setup failed at protocol 0x10 BASE with
# "arm-scmi arm-scmi.1.auto: failed to setup channel for
# protocol:0x10", cascading into NPU devfreq init failure
# (aipu), linlondp-cluster DPU probe failure (no /dev/dri), and
# no mali_kbase probe for CIXH5000 GPU -- ALL three regress at
# once because every firmware-driven subsystem on this SoC goes
# through SCMI, and SCMI's mailbox transport can't talk to the
# SCP without a working cix-mailbox controller registered under
# ACPI. Root cause: the v7.3-rc2 forward-port of patches-7.2/0001
# (commit a0ea259f3d27) re-ported the ACPI branch in
# cix_mbox_probe() correctly but forgot to add the matching
# struct acpi_device_id cix_mbox_acpi_match[] = { { "CIXHA001",
# 0 }, ... } table + MODULE_DEVICE_TABLE(acpi, ...) +
# .acpi_match_table = ACPI_PTR(...) on the platform_driver.
# Without those, the driver never binds to CIXHA001 ACPI devices
# (the CIX sky1 mailbox controllers), and SCMI's
# mbox_request_channel(cl, 0) during scmi_chan_setup() loops on
# -EPROBE_DEFER until it gives up. Fix: ported the missing hunks
# verbatim from patches-7.2/0001.
# See commit 32e112b6d7aa for the full commit message.
# SRCREV_kernel is now the tip of kernel-73rc2-port (32e112b6d7aa) so
# the build picks up all ten forward-port fixes together.
# Bumped to a49de0beac8c: 11th (final) forward-port fix, the CIX clock
# driver rewrite that adds the CIXHA010 ACPI clock provider driver
# (clk-sky1-acpi.c, acpi_clk.c, acpi_scmi_clk.c, cix-clk-debug.c,
# clk.c, acpi_clk.h, clk.h, sky1-clk.h, acpi_clk-scmi.h -- the
# post-0065 state of patches-7.2/0065). Without this, CIXHA010 stays
# unbound and every device with _DEP on it (CIXH5010 DPU, CIXH502F,
# CIXH2030..9, CIXH1002, CIXH1003, CIXH200B, CIXH2011, CIXH3010,
# CIXH6070) stays in permanent -EPROBE_DEFER. linlondp-cluster
# (CIXH50C0) finds no slave mdev, "ACPI cluster: no DPUs", no /dev/dri.
# See commit a49de0beac8c for the full commit message.
SRCREV_kernel = "ec8bf8280261294a9b9b4520414b42704c7f9f6b"

# NOTE: fetches from a LOCAL bare mirror under this build container's workdir mount
# (the Yocto build container has no SSH keys, so it cannot reach the
# project's ssh:// remote directly). The canonical public copy is
# gitlab.com/ncz-os/linux-cix.git (the internal bare mirror is a copy of it),
# branch kernel-73rc7-port-20261011.
# The local mirror (kernel-mirrors/linux-cix-kernel-73rc7-port.git in the build workdir)
# was created from a v7.3-rc7 working tree by cherry-picking all 207
# kernel-73rc6-port commits onto peeled v7.3-rc7^{} = 24a19b953e2a.
# Rebuild it with `git clone --bare` of that branch if it goes stale again.
SRC_URI = " \
    git:///workdir/kernel-mirrors/linux-cix-kernel-73rc7-port.git;protocol=file;branch=${KBRANCH};name=kernel \
    file://config-7.3-rc7.defconfig \
    file://sky1-ncz-v7.3-rc7-port.patch \
    file://0001-drm-cix-trilin-dp-drop-fwnode_drm_find_panel-use-cou.patch \
    file://0002-PCI-cadence-sky1-cix-restore-ACPI-native-mode-on-v7.3.patch \
    file://0003-PM-runtime-restore-the-CIX-Sky1-early-boot-runtime-P.patch \
    file://0004-PCI-cadence-sky1-cix-native-mode-review-fixes-clocks.patch \
    file://0005-regulator-restore-CIX-Sky1-ACPI-fixed-regulator-supp.patch \
    file://0006-pinctrl-acpi-defer-consumers-until-the-named-pin-con.patch \
    file://0007-usb-cdns3-cdnsp-sky1-hold-the-ACPI-wrapper-active-un.patch \
    file://0008-clk-cix-sky1-audss-resolve-ACPI-parent-clocks-by-con.patch \
    file://0009-backlight-pwm-restore-CIX-Sky1-ACPI-backlight-suppor.patch \
    file://0010-drm-cix-linlondp-don-t-warn-about-DPUs-the-firmware-.patch \
    file://0011-arm64-cpufeature-treat-ID_AA64MMFR1_EL1.SpecSEI-as-n.patch \
    file://0013-ASoC-cix-i2s_mc-mask-all-interrupts-CIX.patch \
    file://0014-usb-usb-cdns3-Fix-RCU-stall-in-cdnsp_thread_irq_hand.patch \
    file://0015-usb-cdnsp-skip-DISABLE_SLOT-command-if-slot-is-alrea.patch \
    file://0016-dptx-cix-Add-support-for-out-of-bound-hotplug-events.patch \
    file://0017-DRM-cix-dptx-physical-dp-status-and-MST-HPD-handling.patch \
    file://0018-restrict-psr-caps-update-conditions-CIX.patch \
    file://0019-DRM-cix-dptx-notify-GOP-plug-after-HDCP-init-CIX.patch \
    file://0020-usb-cdns3-Fix-NULL-pointer-dereference-when-comp_des.patch \
    file://0021-typec-rts5453-expose-portX-orientation-node-CIX.patch \
    file://0022-media-cix-build-the-in-tree-VPU-driver-only-with-CON.patch \
    file://0023-drm-cix-linlondp-keep-clocks-running-across-the-firm.patch \
    file://0024-drm-cix-linlondp-recover-from-a-flip-timeout-without.patch \
    file://0025-drm-cix-linlondp-set-the-engine-clock-while-the-disp.patch \
    file://0026-drm-cix-linlondp-spread-overlay-planes-when-layers-e.patch \
    file://0027-PCI-cadence-hpa-never-program-a-zero-root-port-ID.patch \
    file://0028-PCI-sky1-cix-report-the-CIX-root-port-ID-in-native-m.patch \
"

# ---------------------------------------------------------------------------
# r289 (2026-10-12): CIX vendor-tree q3 sync + the RT-group-scheduling root fix.
# - config-7.3-rc6.defconfig: CONFIG_RT_GROUP_SCHED is now "not set" (see the
#   r287 block in that file). This is the kernel-level fix for the O6N audio
#   cutouts (rtkit/pipewire could never get SCHED_RR under cgroup v2).
# - patches 0013-0021 port the relevant cixtech/cix_opensource__linux
#   cix_k6.6.89_2026q2..cix_k6.6.89_2026q3 commits that were still missing
#   from the 7.3-rc6 series: ASoC i2s_mc global-interrupt mask; cdns3/cdnsp
#   RCU-stall + DISABLE_SLOT + comp_desc-NULL fixes; dptx out-of-bound HPD,
#   physical dp->status/MST HPD, eDP-only PSR caps and GOP-plug-after-HDCP;
#   typec rts5453 portX/orientation. Each carries its upstream commit id.
# - the DP-AUX-wedge recovery (r286/0012/v2) is folded into sky1-ncz-v7.3-rc7-port.patch.
# ---------------------------------------------------------------------------
COMPATIBLE_MACHINE = "(cixmini)"
S = "${UNPACKDIR}/${BB_GIT_DEFAULT_DESTSUFFIX}"

PROVIDES = "${PN} virtual/kernel"

do_configure:prepend() {
    cd ${S}
    cp ${UNPACKDIR}/config-7.3-rc7.defconfig ${B}/.config
    oe_runmake ARCH=arm64 O=${B} olddefconfig
}

# Fail the build if any r284 patch (0001-0004) is absent from the patched tree.
r284_patch_check() {
    if grep -q fwnode_drm_find_panel ${S}/include/drm/drm_panel.h; then
        bbfatal "r284 patch check: 0001 missing (fwnode_drm_find_panel still exported)"
    fi
    grep -q '"sky1-pcie-cix"' ${S}/drivers/pci/controller/cadence/pci-sky1-cix.c || \
        bbfatal "r284 patch check: 0002 missing (vendor driver not renamed sky1-pcie-cix)"
    grep -q 'cix_pm: system ready' ${S}/drivers/base/power/runtime.c || \
        bbfatal "r284 patch check: 0003 missing (no CIX early-boot runtime-PM gate)"
    grep -q 'pdevinfo.name = "sky1-pcie-cix"' ${S}/drivers/pci/controller/cadence/pci-sky1-acpi.c || \
        bbfatal "r284 patch check: 0004 missing (ACPI pdev not renamed sky1-pcie-cix)"
}
do_patch[postfuncs] += "r284_patch_check"

# Fail the build if 0005 (ACPI fixed-regulator support) is absent.
r285_patch_check() {
    [ -f ${S}/drivers/regulator/fwnode_regulator.c ] || \
        bbfatal "r285 patch check: 0005 missing (no drivers/regulator/fwnode_regulator.c)"
    grep -q fwnode_get_fixed_voltage_config ${S}/drivers/regulator/fixed.c || \
        bbfatal "r285 patch check: 0005 missing (fixed.c has no ACPI config path)"
    grep -q "config->enabled_at_boot = true" ${S}/drivers/regulator/fixed.c || \
        bbfatal "r285 patch check: 0005 incomplete (RTL8127 rail preserve missing)"
    grep -q "driver_deferred_probe_check_state(dev)" ${S}/drivers/pinctrl/pinctrl-acpi.c || \
        bbfatal "r285 patch check: 0006 missing (ACPI pinctrl lookup does not defer)"
    grep -q "cdnsp_sky1_sync_state" ${S}/drivers/usb/cdns3/cdnsp-sky1.c || \
        bbfatal "r285 patch check: 0007 missing (no cdnsp-sky1 sync_state)"
    grep -q "sky1_audss_acpi_clk_names" ${S}/drivers/clk/cix/clk-sky1-audss.c || \
        bbfatal "r285 patch check: 0008 missing (audss has no ACPI clock names)"
    grep -q "sky1_audss_register_fixed_div" ${S}/drivers/clk/cix/clk-sky1-audss.c || \
        bbfatal "r285 patch check: 0008 incomplete (audss ACPI parents not resolved by connection ID)"
    grep -q '"CIXH5041"' ${S}/drivers/video/backlight/pwm_bl.c || \
        bbfatal "r285 patch check: 0009 missing (pwm_bl has no CIXH5041 match)"
    grep -q "disabled by firmware" ${S}/drivers/gpu/drm/cix/linlon-dp/linlondp_cluster.c || \
        bbfatal "r285 patch check: 0010 missing (linlondp still warns on _STA 0 DPUs)"
    grep -q "FTR_NONSTRICT, FTR_HIGHER_SAFE, ID_AA64MMFR1_EL1_SpecSEI_SHIFT" ${S}/arch/arm64/kernel/cpufeature.c || \
        bbfatal "r285 patch check: 0011 missing (SpecSEI still strict)"
    grep -q "trilin_dp_aux_engine_reinit" ${S}/drivers/gpu/drm/cix/dptx/trilin_dptx.c || \
        bbfatal "r289 patch check: 0012 content missing (DP AUX-wedge recovery not in the port patch)"
    # --- r287 CIX vendor q3 sync (patches 0013-0021) ------------------------
    grep -q "it cannot be cleared" ${S}/sound/soc/cix/cdns_i2s_mc.c || \
        bbfatal "r289 patch check: 0013 missing (i2s_mc global interrupt still enabled)"
    grep -q "max_events" ${S}/drivers/usb/cdns3/cdnsp-ring.c || \
        bbfatal "r289 patch check: 0014 missing (cdnsp-ring event loop unbounded)"
    grep -q "Slot already disabled, skip" ${S}/drivers/usb/cdns3/cdnsp-gadget.c || \
        bbfatal "r289 patch check: 0015 missing (cdnsp disable_slot does not skip)"
    grep -q "trilin_dp_oob_hotplug_event" ${S}/drivers/gpu/drm/cix/dptx/trilin_drm.c || \
        bbfatal "r289 patch check: 0016 missing (no dptx out-of-bound hotplug)"
    grep -q "reflects physical sink presence" ${S}/drivers/gpu/drm/cix/dptx/trilin_dptx.c || \
        bbfatal "r289 patch check: 0017 missing (dptx physical dp->status not applied)"
    grep -q "dpcd\[DP_EDP_CONFIGURATION_CAP\]" ${S}/drivers/gpu/drm/cix/dptx/trilin_dptx.c || \
        bbfatal "r289 patch check: 0018 missing (psr caps not gated on eDP)"
    grep -q "GOP boot: plug notify after HDCP init" ${S}/drivers/gpu/drm/cix/dptx/trilin_dptx.c || \
        bbfatal "r289 patch check: 0019 missing (dptx GOP plug notify not applied)"
    grep -q "!pep->endpoint.comp_desc" ${S}/drivers/usb/cdns3/cdnsp-mem.c || \
        bbfatal "r289 patch check: 0020 missing (cdnsp comp_desc NULL guards)"
    grep -q "orientation_aware" ${S}/drivers/usb/typec/rts5453.c || \
        bbfatal "r289 patch check: 0021 missing (rts5453 orientation node not wired)"
    # --- r290 (patches 0022-) ----------------------------------------------
    grep -qx 'obj-$(CONFIG_VIDEO_LINLON) += cix/' ${S}/drivers/media/platform/Makefile || \
        bbfatal "r290 patch check: 0022 missing (cix/ VPU driver still built without CONFIG_VIDEO_LINLON)"
    grep -q "linlondp_crtc_takeover_from_gop" ${S}/drivers/gpu/drm/cix/linlon-dp/linlondp_crtc.c || \
        bbfatal "r290 patch check: 0023 missing (firmware takeover still resets with clocks off)"
    grep -q "linlondp_crtc_recover_work" ${S}/drivers/gpu/drm/cix/linlon-dp/linlondp_crtc.c || \
        bbfatal "r290 patch check: 0024 missing (no flip-timeout recovery)"
    grep -q "second output needs more" ${S}/drivers/gpu/drm/cix/linlon-dp/linlondp_crtc.c || \
        bbfatal "r290 patch check: 0025 missing (engine clock not raised for a second output)"
    grep -q "linlondp_kms_add_overlays_spread" ${S}/drivers/gpu/drm/cix/linlon-dp/linlondp_plane.c || \
        bbfatal "r290 patch check: 0026 missing (overlay planes not spread)"
    grep -q "Nothing provided an ID" ${S}/drivers/pci/controller/cadence/pcie-cadence-host-hpa.c || \
        bbfatal "r290 patch check: 0027 missing (hpa can still write a zero root port ID)"
    grep -q "rc->device_id = PCI_DEVICE_ID_CIX_SKY1" ${S}/drivers/pci/controller/cadence/pci-sky1-cix.c || \
        bbfatal "r290 patch check: 0028 missing (vendor driver keeps the 17cd:0100 root port ID)"
    # Count what quilt actually applied, not what SRC_URI intends: the port
    # patch plus 0001-0011, plus aux (0012) and the r287 CIX set (0013-0021).
    applied="${S}/.pc/applied-patches"
    [ -f "$applied" ] || bbfatal "r285 patch check: $applied missing, cannot count applied patches"
    n=$(grep -c . "$applied")
    [ "$n" -eq "${R290_EXPECTED_PATCHES}" ] || \
        bbfatal "r290 patch check: quilt applied $n patches, expected ${R290_EXPECTED_PATCHES}"
    for i in 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011 0013 0014 0015 0016 0017 0018 0019 0020 0021 0022 0023 0024 0025 0026 0027 0028; do
        grep -q "^$i-" "$applied" || bbfatal "r290 patch check: $i not in $applied"
    done
    bbnote "r290 patch check: $n patches applied (rc7 port incl. r5 aux + 0001-0011 + r289 CIX q3 set + r290 0022-0028)"
}
R290_EXPECTED_PATCHES = "28"
do_patch[postfuncs] += "r285_patch_check"

DEPENDS += "pahole-native elfutils-native"
EXTRA_OEMAKE += "INSTALL_MOD_STRIP=1"

# Fail the build if olddefconfig dropped or changed any r283 config fix.
R283_REQUIRED_CONFIG = " \
    CONFIG_DEBUG_INFO_BTF=y \
    CONFIG_DEBUG_INFO_BTF_MODULES=y \
    CONFIG_SQUASHFS_ZSTD=y \
    CONFIG_MT7921U=m \
    CONFIG_MT7925U=m \
    CONFIG_RTW89_8922DE=m \
    CONFIG_MODVERSIONS=y \
"
# r285: zram-generator modprobes crypto-zstd; fwupd wants /dev/i2c-*.
R285_REQUIRED_CONFIG = " \
    CONFIG_CRYPTO_ZSTD=m \
    CONFIG_I2C_CHARDEV=m \
"
# r287: the Sky1 kernel must NOT be built with RT_GROUP_SCHED=y. Together with
# the cgroup v2 cpu controller (enabled by systemd on every boot) it makes
# every non-root cgroup carry zero RT runtime, so sched_setscheduler(SCHED_RR)
# returns EPERM even for CAP_SYS_NICE -- rtkit/pipewire silently stay
# SCHED_OTHER and O6N audio XRUNs. With RT_GROUP_SCHED=n the RT bandwidth
# accounting is global (root cgroup) and RTKit grants succeed; FAIR_GROUP_SCHED
# / CFS_BANDWIDTH / cpu.weight/cpu.max are untouched.
R289_REQUIRED_NOT_CONFIG = " \
    CONFIG_RT_GROUP_SCHED \
"
# r290: CIX accelerators ship out-of-tree only. An in-tree module with the
# name of a DKMS module (amvx for the VPU, armchina_npu for the NPU) can load
# in place of the validated one without any error. Any value but "not set"
# fails the build ("not set" and absent are both fine).
R290_REQUIRED_UNSET = " \
    CONFIG_VIDEO_LINLON \
    CONFIG_ARMCHINA_NPU \
"
do_configure:append() {
    for sym in ${R290_REQUIRED_UNSET}; do
        if grep -q "^${sym}=" ${B}/.config; then
            bbfatal "r290 config check: $(grep "^${sym}=" ${B}/.config) (accelerator drivers ship out-of-tree only)"
        fi
    done
    # the DKMS amvx imports the videobuf2 DMA-SG helpers; VIDEO_LINLON_OOT selects them
    grep -qE '^CONFIG_VIDEOBUF2_DMA_SG=(m|y)$' ${B}/.config ||         bbfatal "r290 config check: CONFIG_VIDEOBUF2_DMA_SG missing (set CONFIG_VIDEO_LINLON_OOT; the DKMS VPU module cannot load without it)"
    for want in ${R283_REQUIRED_CONFIG}; do
        grep -qxF "$want" ${B}/.config || bbfatal "r283 config check: $want missing from ${B}/.config"
    done
    grep -qx 'CONFIG_DRM_PANIC_SCREEN="kmsg"' ${B}/.config || \
        bbfatal "r283 config check: CONFIG_DRM_PANIC_SCREEN is not kmsg"
    for want in ${R285_REQUIRED_CONFIG}; do
        grep -qxF "$want" ${B}/.config || bbfatal "r285 config check: $want missing from ${B}/.config"
    done
    for bad in ${R289_REQUIRED_NOT_CONFIG}; do
        if grep -qxF "${bad}=y" ${B}/.config; then
            bbfatal "r289 config check: ${bad}=y (rtkit cannot grant RT under cgroup v2)"
        fi
    done
    if grep -q '^CONFIG_DMABUF_DEBUG=y' ${B}/.config; then
        bbfatal "r283 config check: CONFIG_DMABUF_DEBUG=y (amvx dma-buf import maps zero pages)"
    fi
    if grep -q '^CONFIG_MODULE_COMPRESS=y' ${B}/.config; then
        bbfatal "r283 config check: CONFIG_MODULE_COMPRESS=y (modules must ship as plain .ko)"
    fi
}

KERNEL_IMAGETYPE = "Image"
KERNEL_DEVICETREE = " \
    cix/sky1-orion-o6.dtb \
"
# SRCREV_kernel is now the tip of kernel-73rc2-port (b58f477c30f6) so the audss ACPI match-table fix (CIXH6061 audio bind) is included -- 12th forward-port bug.
# SRCREV_kernel is now the tip of kernel-73rc2-port (f1a2007e424f) -- the REAL audio fix (syscon regmap, not just ACPI match table), 13th forward-port bug. All diagnostic dev_err instrumentation reverted.
# 2026-09-13: rebased all 207 kernel-73rc2-port commits from v7.3-rc2
# onto v7.3-rc4 as kernel-73rc4-port. All commits applied cleanly; none
# needed conflict resolution or were dropped as already upstream.

# 2026-09-20: replayed all 207 kernel-73rc3-port commits onto peeled
# v7.3-rc4 commit 93f51579e7df248780214094418f205253383cc5. The replay
# completed without conflicts or dropped commits; range-diff reports all
# 207 commits patch-equivalent. Raw 205-patch audit: 178 applied, 27 failed;
# all 27 are represented by the corrected forward-port commits in the
# rebased series and consolidated recipe patch.

