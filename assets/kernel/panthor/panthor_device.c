// SPDX-License-Identifier: GPL-2.0 or MIT
/* Copyright 2018 Marty E. Plummer <hanetzer@startmail.com> */
/* Copyright 2019 Linaro, Ltd, Rob Herring <robh@kernel.org> */
/* Copyright 2023 Collabora ltd. */
/* Copyright 2025 ARM Limited. All rights reserved. */

#include <linux/acpi.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/mm.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_domain.h>
#include <linux/pm_runtime.h>
#include <linux/property.h>
#include <linux/regulator/consumer.h>
#include <linux/reset.h>

#include <drm/drm_drv.h>
#include <drm/drm_managed.h>
#include <drm/drm_print.h>

#include "panthor_devfreq.h"
#include "panthor_device.h"
#include "panthor_fw.h"
#include "panthor_fw_regs.h"
#include "panthor_gem.h"
#include "panthor_gpu.h"
#include "panthor_hw.h"
#include "panthor_mmu.h"
#include "panthor_sky1.h"
#include "panthor_pwr.h"
#include "panthor_sched.h"

static int panthor_clk_init(struct panthor_device *ptdev)
{
	ptdev->clks.core = devm_clk_get(ptdev->base.dev, NULL);
	if (IS_ERR(ptdev->clks.core) && has_acpi_companion(ptdev->base.dev) &&
	    acpi_dev_hid_match(ACPI_COMPANION(ptdev->base.dev), "CIXH5000"))
		ptdev->clks.core = devm_clk_get(ptdev->base.dev, "gpu_clk_core");
	if (IS_ERR(ptdev->clks.core))
		return dev_err_probe(ptdev->base.dev,
				     PTR_ERR(ptdev->clks.core),
				     "get 'core' clock failed");

	ptdev->clks.stacks = devm_clk_get_optional(ptdev->base.dev, "stacks");
	if (IS_ERR(ptdev->clks.stacks))
		return dev_err_probe(ptdev->base.dev,
				     PTR_ERR(ptdev->clks.stacks),
				     "get 'stacks' clock failed");

	/* Sky1/ACPI: there is no "stacks" clkdev entry under ACPI, so the
	 * optional lookup above returns NULL and the shader-stack clock is
	 * never enabled. With that clock off, ANY SHADER_PWRON -- host- or
	 * firmware-initiated -- wedges forever in SHADER_PWRTRANS, which
	 * surfaces much later as "CSG update request timedout", a failed CSG
	 * suspend, a soft-reset timeout and a dead address space. L2 and TILER
	 * live on gpu_top and are unaffected, which is exactly why probe,
	 * firmware boot, MMU traffic and vulkaninfo all succeed while the first
	 * real shader job kills the GPU.
	 *
	 * mali_kbase gets this right by asking for the clock by its clkdev
	 * con_id: mali_kbase_core_linux.c clk_names[] = { "gpu_clk_core",
	 * "gpu_clk_stacks" }. Mirror that name here.
	 *
	 * Measured on O6N: SHADER_READY=0x0 SHADER_PWRTRANS=0x550555 (all ten
	 * cores stuck) with gpu_core enable_count=0; with this fix the clock
	 * reports 1 GHz and shader work completes.
	 */
	if (!ptdev->clks.stacks && has_acpi_companion(ptdev->base.dev) &&
	    acpi_dev_hid_match(ACPI_COMPANION(ptdev->base.dev), "CIXH5000"))
		ptdev->clks.stacks = devm_clk_get_optional(ptdev->base.dev,
							   "gpu_clk_stacks");

	/* Sky1 backup clocks. The struct field existed but was never populated.
	 * mali_kbase acquires and enables both at probe:
	 *   backup_clk_names[] = { "gpu_clk_200M", "gpu_clk_400M" }
	 *   devm_clk_get() then clk_prepare_enable(), tolerating absence.
	 * Optional by design: a missing backup clock must not fail the probe.
	 */
	{
		static const char * const backup_names[] = {
			"gpu_clk_200M", "gpu_clk_400M",
		};
		unsigned int i;

		for (i = 0; i < ARRAY_SIZE(ptdev->clks.backup); i++) {
			ptdev->clks.backup[i] =
				devm_clk_get_optional(ptdev->base.dev,
						      backup_names[i]);
			if (IS_ERR(ptdev->clks.backup[i])) {
				drm_warn(&ptdev->base,
					 "optional backup clock %s unavailable (%ld)\n",
					 backup_names[i],
					 PTR_ERR(ptdev->clks.backup[i]));
				ptdev->clks.backup[i] = NULL;
			}
		}
	}

	ptdev->clks.coregroup = devm_clk_get_optional(ptdev->base.dev, "coregroup");
	if (IS_ERR(ptdev->clks.coregroup))
		return dev_err_probe(ptdev->base.dev,
				     PTR_ERR(ptdev->clks.coregroup),
				     "get 'coregroup' clock failed");

	drm_info(&ptdev->base, "clock rate = %lu\n", clk_get_rate(ptdev->clks.core));

	/*
	 * Sky1 (ACPI): if the SCMI gpu_core clock has not been registered
	 * yet, devm_clk_get_optional() above returned NULL and the GPU is
	 * unclocked -- touching its registers raises an SError.  Defer
	 * until the clock provider shows up instead of panicking the boot.
	 */
	if (has_acpi_companion(ptdev->base.dev) &&
	    acpi_dev_hid_match(ACPI_COMPANION(ptdev->base.dev), "CIXH5000") &&
	    (!ptdev->clks.core || !clk_get_rate(ptdev->clks.core)))
		return dev_err_probe(ptdev->base.dev, -EPROBE_DEFER,
				     "Sky1: gpu core clock not ready, deferring probe");

	return 0;
}

static int panthor_init_power(struct device *dev)
{
	struct dev_pm_domain_list  *pd_list = NULL;

	if (dev->pm_domain)
		return 0;

	return devm_pm_domain_attach_list(dev, NULL, &pd_list);
}

/*
 * CIX Sky1 detection. Sky1's Mali-G720 GPU is "arm,mali-valhall" under DT
 * (the BSP DT node uses this older compatible, no -csf suffix) or
 * "CIXH5000" under ACPI.
 */
bool panthor_is_sky1(struct panthor_device *ptdev)
{
	struct device *dev = ptdev->base.dev;

	if (IS_ENABLED(CONFIG_OF) && dev->of_node &&
	    of_device_is_compatible(dev->of_node, "arm,mali-valhall"))
		return true;

	if (IS_ENABLED(CONFIG_ACPI) &&
	    acpi_dev_hid_uid_match(ACPI_COMPANION(dev), "CIXH5000", NULL))
		return true;

	return false;
}

/*
 * CIX Sky1 GPU un-secure / power-on via the ACPI "power-supply" device.
 *
 * The Mali-G720 register block boots SECURED. The very first non-secure
 * (Linux) MMIO access to it faults the secure world and floods the console
 * with "IDM: GPU secure access, error status=0x0" -- an unrecoverable boot
 * hang on Sky1. Something has to power on AND un-secure (grant non-secure
 * access to) the GPU register block before panthor touches it.
 *
 * On Sky1 that is done by a SEPARATE ACPI power device referenced from the
 * GPU's _DSD "power-supply" property (HID CIXH5001, ASL name GPUP). Its ACPI
 * _PR0 power resource (_ON method) writes the GPU RCSU PGCTRL register
 * (0x15000218) and drives a memory-repair / power-group-enable handshake
 * over plain MMIO at 0x15000000. It is pure ACPI AML -- it does NOT use SCMI
 * -- so it works even with acpi_scmi_en=off (required on NCZ-OS for
 * PCIe/NVMe), where the SCMI perf/power genpd referenced by the GPU's own
 * "power-domains" property is absent.
 *
 * The proprietary mali_kbase driver un-secures the GPU exactly this way
 * (drivers/gpu/arm/midgard/platform/sky1/mali_kbase_config_sky1.c:
 * sky1_gpu_attach_pd(): follow the "power-supply" fwnode reference, find the
 * platform device, pm_runtime_enable() + dev_pm_domain_attach(power_on=true),
 * then add an RPM_ACTIVE device_link). Panthor never followed that reference,
 * so under acpi_scmi_en=off nothing ran GPUP's _PR0._ON and the GPU stayed
 * secured -> IDM flood. We mirror kbase here.
 *
 * dev_pm_domain_attach(power_dev, true) attaches the ACPI PM domain to the
 * power device and powers it to D0 immediately (evaluates _PR0._ON), so the
 * GPU is un-secured before panthor issues any GPU MMIO. The RPM_ACTIVE
 * device_link keeps the power device resumed for the GPU's runtime-PM life
 * (so an autosuspend of the GPU does not release the un-secure).
 */
static int panthor_sky1_attach_power_supply(struct panthor_device *ptdev)
{
	struct device *dev = ptdev->base.dev;
	struct fwnode_handle *ps_fwnode;
	struct device *power_dev;
	struct device_link *link;
	int err;

	ps_fwnode = fwnode_find_reference(dev_fwnode(dev), "power-supply", 0);
	if (IS_ERR(ps_fwnode)) {
		/*
		 * No "power-supply" reference: an older firmware or a variant
		 * that un-secures the GPU some other way. Do not fail probe
		 * here; let it proceed (and fault loudly at first MMIO if the
		 * GPU really is still secured) rather than mis-diagnosing.
		 */
		dev_warn(dev,
			 "Sky1: no ACPI 'power-supply' reference; GPU left secured\n");
		return 0;
	}

	power_dev = bus_find_device_by_fwnode(&platform_bus_type, ps_fwnode);
	fwnode_handle_put(ps_fwnode);
	if (!power_dev) {
		dev_err(dev,
			"Sky1: ACPI 'power-supply' device not yet enumerated\n");
		return -EPROBE_DEFER;
	}

	pm_runtime_enable(power_dev);

	/*
	 * power_on=true evaluates the power device's ACPI _PR0._ON now, which
	 * un-secures the GPU register block. Match kbase and tolerate a
	 * non-zero return (the ACPI PM domain may already be attached from
	 * enumeration); the RPM_ACTIVE link below is what holds it powered.
	 */
	err = dev_pm_domain_attach(power_dev, true);
	if (err && err != -EEXIST)
		dev_warn(dev,
			 "Sky1: power-supply PM-domain attach returned %d (continuing)\n",
			 err);

	link = device_link_add(dev, power_dev,
			       DL_FLAG_STATELESS | DL_FLAG_PM_RUNTIME |
			       DL_FLAG_RPM_ACTIVE);
	if (!link) {
		dev_err(dev, "Sky1: failed to link GPU to power-supply device\n");
		dev_pm_domain_detach(power_dev, true);
		pm_runtime_disable(power_dev);
		put_device(power_dev);
		return -EINVAL;
	}

	/*
	 * Record both so a later probe failure (e.g. panthor_sky1_resets_init()
	 * below, or anything else in panthor_device_init()) can unwind this via
	 * panthor_sky1_detach_power_supply() / panthor_pm_domain_fini() instead
	 * of leaking the reference, the device_link and the runtime-PM enable.
	 */
	ptdev->sky1_power_supply_dev = power_dev;
	ptdev->sky1_power_supply_link = link;

	dev_info(dev, "Sky1: GPU un-secured via ACPI power-supply (_PR0)\n");
	return 0;
}

/*
 * Undo panthor_sky1_attach_power_supply(), if it ran. Safe to call
 * unconditionally (including when the "power-supply" reference was never
 * attached, e.g. no ACPI companion or an older firmware variant) since it
 * no-ops when @ptdev->sky1_power_supply_dev is NULL.
 */
static void panthor_sky1_detach_power_supply(struct panthor_device *ptdev)
{
	struct device *power_dev = ptdev->sky1_power_supply_dev;

	if (!power_dev)
		return;

	if (ptdev->sky1_power_supply_link)
		device_link_del(ptdev->sky1_power_supply_link);

	dev_pm_domain_detach(power_dev, true);
	pm_runtime_disable(power_dev);
	put_device(power_dev);

	ptdev->sky1_power_supply_dev = NULL;
	ptdev->sky1_power_supply_link = NULL;
}

/*
 * Sky1 GPU IP reset ("gpu_reset").
 *
 * The ACPI power-supply un-secure (above) is necessary but not sufficient:
 * on real Sky1 hardware the GPU register aperture (panthor's primary iomem,
 * resource[1]) still bus-faults on the very first MMIO access even after
 * "power-supply" is attached -- confirmed via serial trace as a distinct,
 * non-zero "IDM: GPU non-secure access, error status=0xec000014" at the
 * aperture base, i.e. a real bus error (not a security violation) on the
 * first register read in panthor_hw_gpu_id_init().
 *
 * The CIX GPU Development Guide documents a 5-step Sky1 GPU power-on
 * sequence: 1. power domain on, 2. clock enable, 3. IP reset assert,
 * 4. IP reset de-assert, 5. RCSU PGCTRL qchannel-clock-gating enable.
 * Panthor only ever implemented steps 1-2; steps 3-5 (the reset cycle
 * gating access to the register aperture, plus the qchannel-gating
 * follow-up write) were never wired up for the 7.2 ACPI path. This is
 * exactly the same bug class fixed for the Sky1 VPU driver (NCZ patches
 * 0136/0139-0141: an un-deasserted RCSU-side reset leaves the register
 * aperture bus-faulting even though the block is otherwise powered and
 * un-secured), and mirrors mali_kbase's sky1_gpu_attach_pd() +
 * execute_gpu_reset(), which cycles a "gpu_reset" reset_control before
 * its own first GPU register access. panthor_device.h has long carried
 * an unused @gpu_reset field for exactly this; nothing ever acquired or
 * cycled it under the ACPI (7.2) probe path.
 *
 * devm_reset_control_get_optional_exclusive() returns NULL (not an error)
 * when the reset framework has no ACPI-side "gpu_reset" reference to
 * resolve, so this is safe to call unconditionally on Sky1 -- if the
 * firmware genuinely does not describe a "gpu_reset" line, the assert/
 * deassert calls below become no-ops via panthor_sky1_hw_reset_cycle()'s
 * NULL check, same as upstream reset_control_assert/deassert(NULL).
 */
static int panthor_sky1_resets_init(struct panthor_device *ptdev)
{
	struct device *dev = ptdev->base.dev;

	/*
	 * Under ACPI the reset framework has no DT phandle to resolve against,
	 * so use the exclusive lookup (matches the earlier NCZ 7.1.1 panthor
	 * ACPI enablement, which drew this ACPI/OF split from mali_kbase's own
	 * reset-framework usage). Both _optional_ variants return NULL rather
	 * than -ENOENT when firmware has no "gpu_reset" reference at all, so
	 * panthor_sky1_hw_reset_cycle()'s NULL check keeps this a no-op instead
	 * of failing probe on such firmware.
	 */
	if (!dev->of_node)
		ptdev->gpu_reset = devm_reset_control_get_optional_exclusive(dev, "gpu_reset");
	else
		ptdev->gpu_reset = devm_reset_control_get_optional(dev, "gpu_reset");
	if (IS_ERR(ptdev->gpu_reset))
		return dev_err_probe(dev, PTR_ERR(ptdev->gpu_reset),
				     "Sky1: failed to get gpu_reset\n");

	return 0;
}

/*
 * Cycle the Sky1 GPU IP reset and enable RCSU qchannel clock gating.
 *
 * This is steps 3-5 of the CIX GPU Development Guide's Sky1 power-on
 * sequence (see panthor_sky1_resets_init() above) and MUST run after the
 * power-supply un-secure + clocks are up but before any access to
 * ptdev->iomem (the primary GPU register block) -- panthor_hw_init() is
 * the first such access (GPU_ID at offset 0) and is exactly where the
 * hang was observed.
 *
 * Matches mali_kbase's execute_gpu_reset() (assert, 10-20us, deassert)
 * followed by gpu_qchannel_clock_gating_switch(true) against the same
 * RCSU PGCTRL register (offset 0x218, bit 0 =
 * GPU_RCSU_QCHANNEL_CLOCK_GATE_ENABLE in mali_kbase's platform config).
 *
 * Deliberately called ONCE, from probe, not from panthor_device_resume()
 * (ordinary GPU runtime-PM autosuspend/resume). kbase does the same: its
 * pm_callback_power_on() only calls execute_gpu_reset() the first time,
 * gated by a static "need_reset_flag" latch that is never set again, and
 * the GPU's power-supply device_link here is DL_FLAG_RPM_ACTIVE, which
 * keeps that supplier device runtime-resumed for the driver's whole
 * lifetime -- so the ACPI un-secure state it holds is not expected to be
 * revisited by an ordinary autosuspend/resume cycle either. This is
 * INFERRED from kbase's reference behavior, not independently confirmed
 * against Sky1 silicon/firmware docs for panthor specifically, and is
 * unverified by the hardware boot-hang testing this fix targets (that
 * testing never gets past probe). If GPU runtime-PM autosuspend is later
 * found to need this too, add the call to panthor_device_resume().
 *
 * Full SYSTEM suspend/resume (suspend-to-RAM) is a separate, known,
 * explicitly out-of-scope gap: an earlier NCZ patch for the 7.1.1 branch
 * (0037-gpu-panthor-fix-suspend-resume-for-sky1) added an equivalent
 * reset-cycle replay to a dedicated resume_noirq hook for exactly that
 * case. That replay is now ported (NCZ 0188 equivalent):
 * panthor_device_resume_noirq() below re-runs this cycle after STR,
 * before the forced runtime resume re-enables clocks.
 */
static int panthor_sky1_hw_reset_cycle(struct panthor_device *ptdev)
{
	struct device *dev = ptdev->base.dev;
	int ret;

	if (ptdev->gpu_reset) {
		ret = reset_control_assert(ptdev->gpu_reset);
		if (ret) {
			dev_err(dev, "Sky1: GPU reset assert failed: %d\n", ret);
			return ret;
		}

		usleep_range(10, 20);

		ret = reset_control_deassert(ptdev->gpu_reset);
		if (ret) {
			dev_err(dev, "Sky1: GPU reset deassert failed: %d\n", ret);
			return ret;
		}
	}

	if (!IS_ERR_OR_NULL(ptdev->sky1_rcsu_reg)) {
		u32 pgctrl = readl(ptdev->sky1_rcsu_reg + 0x218);

		pgctrl |= BIT(0); /* GPU_RCSU_QCHANNEL_CLOCK_GATE_ENABLE */
		writel(pgctrl, ptdev->sky1_rcsu_reg + 0x218);
		dev_dbg(dev, "Sky1: GPU qchannel clock gating enabled\n");
	}

	return 0;
}

/*
 * Attach every pm-domain explicitly.
 *
 * Mainline panthor_init_power() only attaches the single power-domain
 * that platform_device adds via the "power-domains" property. On the
 * SCMI-perf-domain path we need an explicit attach for each domain in
 * the DT's "power-domain-names" (perf + pd_gpu). Returns 0 on success
 * or no-op when single-domain.
 */
int panthor_pm_domain_init(struct panthor_device *ptdev)
{
	struct device *dev = ptdev->base.dev;
	int num_domains, i, err;

	/*
	 * CIX Sky1 under ACPI: the GPU register block boots secured and must be
	 * un-secured via its ACPI "power-supply" device (GPUP / CIXH5001) before
	 * any GPU MMIO, or the boot hangs flooding "IDM: GPU secure access".
	 * This is ACPI-native (_PR0._ON) and works with acpi_scmi_en=off, where
	 * the GPU's SCMI "power-domains" genpd is absent. Mirror mali_kbase.
	 */
	if (panthor_is_sky1(ptdev)) {
		/*
		 * Best-effort raw SMC SCMI power-on first (CIX 7.1 reference
		 * path, NCZ 0186): asks TFA to power GPU domain 21 and open
		 * IDM non-secure access to the GPU register block. On O6N
		 * firmware the ACPI power-supply (_PR0) attach below is the
		 * proven un-secure mechanism, so a failure here is logged,
		 * not fatal.
		 */
		err = sky1_gpu_power_on(ptdev);
		if (err)
			dev_warn(dev,
				 "Sky1: SMC SCMI GPU power-on failed (%d); relying on ACPI power-supply path\n",
				 err);

		if (has_acpi_companion(dev)) {
			err = panthor_sky1_attach_power_supply(ptdev);
			if (err)
				return err;
		}

		err = panthor_sky1_resets_init(ptdev);
		if (err) {
			/*
			 * panthor_sky1_attach_power_supply() may have already
			 * succeeded above. The caller only invokes
			 * panthor_pm_domain_fini() when THIS function returns
			 * success and a later probe step fails, so an error
			 * return here must unwind the power-supply attach
			 * itself or it leaks (device ref, device_link,
			 * runtime-PM enable).
			 */
			panthor_sky1_detach_power_supply(ptdev);
			return err;
		}
	}

	if (!IS_ENABLED(CONFIG_OF) || !dev->of_node)
		return 0;

	num_domains = of_count_phandle_with_args(dev->of_node,
						 "power-domains",
						 "#power-domain-cells");
	if (num_domains < 2)
		return 0;

	if (WARN_ON(num_domains > ARRAY_SIZE(ptdev->pm_domain_devs)))
		return -EINVAL;

	for (i = 0; i < num_domains; i++) {
		ptdev->pm_domain_devs[i] =
			dev_pm_domain_attach_by_id(dev, i);
		if (IS_ERR_OR_NULL(ptdev->pm_domain_devs[i])) {
			err = PTR_ERR(ptdev->pm_domain_devs[i]) ? : -ENODATA;
			ptdev->pm_domain_devs[i] = NULL;
			dev_err(dev, "failed to attach pm-domain %d: %d\n",
				i, err);
			return err;
		}

		ptdev->pm_domain_links[i] =
			device_link_add(dev, ptdev->pm_domain_devs[i],
					DL_FLAG_PM_RUNTIME | DL_FLAG_STATELESS |
					DL_FLAG_RPM_ACTIVE);
		if (!ptdev->pm_domain_links[i]) {
			dev_err(ptdev->pm_domain_devs[i],
				"adding device link failed\n");
			return -ENODEV;
		}
	}

	return 0;
}

void panthor_pm_domain_fini(struct panthor_device *ptdev)
{
	int i;

	panthor_sky1_detach_power_supply(ptdev);

	for (i = 0; i < ARRAY_SIZE(ptdev->pm_domain_devs); i++) {
		if (!ptdev->pm_domain_devs[i])
			break;

		if (ptdev->pm_domain_links[i])
			device_link_del(ptdev->pm_domain_links[i]);

		dev_pm_domain_detach(ptdev->pm_domain_devs[i], true);
		ptdev->pm_domain_devs[i] = NULL;
		ptdev->pm_domain_links[i] = NULL;
	}
}

void panthor_device_unplug(struct panthor_device *ptdev)
{
	/* This function can be called from two different path: the reset work
	 * and the platform device remove callback. drm_dev_unplug() doesn't
	 * deal with concurrent callers, so we have to protect drm_dev_unplug()
	 * calls with our own lock, and bail out if the device is already
	 * unplugged.
	 */
	mutex_lock(&ptdev->unplug.lock);
	if (drm_dev_is_unplugged(&ptdev->base)) {
		/* Someone beat us, release the lock and wait for the unplug
		 * operation to be reported as done.
		 **/
		mutex_unlock(&ptdev->unplug.lock);
		wait_for_completion(&ptdev->unplug.done);
		return;
	}

	drm_WARN_ON(&ptdev->base, pm_runtime_get_sync(ptdev->base.dev) < 0);

	/* Call drm_dev_unplug() so any access to HW blocks happening after
	 * that point get rejected.
	 */
	drm_dev_unplug(&ptdev->base);

	/* We do the rest of the unplug with the unplug lock released,
	 * future callers will wait on ptdev->unplug.done anyway.
	 */
	mutex_unlock(&ptdev->unplug.lock);

	/* Now, try to cleanly shutdown the GPU before the device resources
	 * get reclaimed.
	 */
	panthor_sched_unplug(ptdev);
	panthor_fw_unplug(ptdev);
	panthor_mmu_unplug(ptdev);
	panthor_gem_shrinker_unplug(ptdev);
	panthor_gpu_unplug(ptdev);
	panthor_pwr_unplug(ptdev);

	pm_runtime_dont_use_autosuspend(ptdev->base.dev);
	pm_runtime_put_sync_suspend(ptdev->base.dev);

	/* If PM is disabled, we need to call the suspend handler manually. */
	if (!IS_ENABLED(CONFIG_PM))
		panthor_device_suspend(ptdev->base.dev);

	/* Report the unplug operation as done to unblock concurrent
	 * panthor_device_unplug() callers.
	 */
	complete_all(&ptdev->unplug.done);
}

static void panthor_device_reset_cleanup(struct drm_device *ddev, void *data)
{
	struct panthor_device *ptdev = container_of(ddev, struct panthor_device, base);

	disable_work_sync(&ptdev->reset.work);
	destroy_workqueue(ptdev->reset.wq);
}

static void panthor_device_reset_work(struct work_struct *work)
{
	struct panthor_device *ptdev = container_of(work, struct panthor_device, reset.work);
	int ret = 0, cookie;

	/* If the device is entering suspend, we don't reset. A slow reset will
	 * be forced at resume time instead.
	 */
	if (atomic_read(&ptdev->pm.state) != PANTHOR_DEVICE_PM_STATE_ACTIVE)
		return;

	if (!drm_dev_enter(&ptdev->base, &cookie))
		return;

	panthor_sched_pre_reset(ptdev);
	panthor_fw_pre_reset(ptdev, true);
	panthor_mmu_pre_reset(ptdev);
	panthor_hw_soft_reset(ptdev);
	panthor_hw_l2_power_on(ptdev);
	panthor_mmu_post_reset(ptdev);
	ret = panthor_fw_post_reset(ptdev);
	atomic_set(&ptdev->reset.pending, 0);
	panthor_sched_post_reset(ptdev, ret != 0);
	drm_dev_exit(cookie);

	if (ret) {
		panthor_device_unplug(ptdev);
		drm_err(&ptdev->base, "Failed to boot MCU after reset, making device unusable.");
	}
}

static bool panthor_device_is_initialized(struct panthor_device *ptdev)
{
	return !!ptdev->scheduler;
}

static void panthor_device_free_page(struct drm_device *ddev, void *data)
{
	__free_page(data);
}

int panthor_device_init(struct panthor_device *ptdev)
{
	u32 *dummy_page_virt;
	struct resource *res;
	struct page *p;
	int ret;

	ptdev->soc_data = of_device_get_match_data(ptdev->base.dev);

	init_completion(&ptdev->unplug.done);
	ret = drmm_mutex_init(&ptdev->base, &ptdev->unplug.lock);
	if (ret)
		return ret;

	ret = drmm_mutex_init(&ptdev->base, &ptdev->pm.mmio_lock);
	if (ret)
		return ret;

#ifdef CONFIG_DEBUG_FS
	ret = drmm_mutex_init(&ptdev->base, &ptdev->gems.lock);
	if (ret)
		return ret;

	INIT_LIST_HEAD(&ptdev->gems.node);
#endif

	atomic_set(&ptdev->pm.state, PANTHOR_DEVICE_PM_STATE_SUSPENDED);
	p = alloc_page(GFP_KERNEL | __GFP_ZERO);
	if (!p)
		return -ENOMEM;

	ptdev->pm.dummy_latest_flush = p;
	dummy_page_virt = page_address(p);
	ret = drmm_add_action_or_reset(&ptdev->base, panthor_device_free_page,
				       ptdev->pm.dummy_latest_flush);
	if (ret)
		return ret;

	/*
	 * Set the dummy page holding the latest flush to 1. This will cause the
	 * flush to avoided as we know it isn't necessary if the submission
	 * happens while the dummy page is mapped. Zero cannot be used because
	 * that means 'always flush'.
	 */
	*dummy_page_virt = 1;

	INIT_WORK(&ptdev->reset.work, panthor_device_reset_work);
	disable_work(&ptdev->reset.work);
	ptdev->reset.wq = alloc_ordered_workqueue("panthor-reset-wq", 0);
	if (!ptdev->reset.wq)
		return -ENOMEM;

	ret = drmm_add_action_or_reset(&ptdev->base, panthor_device_reset_cleanup, NULL);
	if (ret)
		return ret;

	ret = panthor_clk_init(ptdev);
	if (ret)
		return ret;

	/*
	 * NCZ CIX Sky1 fix: explicitly enable the core clock here rather than
	 * relying on pm_runtime_resume_and_get() below to do it via the
	 * runtime_resume callback. On this platform, __pm_runtime_resume() is
	 * gated (NCZ patches 0089/0090) until a late_initcall marks the system
	 * ready, to stop OTHER drivers' premature deferred-probe resumes from
	 * touching not-yet-clocked hardware. But that gate also silently
	 * no-ops THIS device's own first (synchronous, in-probe) resume, so
	 * panthor_hw_init() below was running against an unprepared/disabled
	 * core clock (reported rate=0) and immediately hit an SError touching
	 * GPU MMIO. Confirmed on real Sky1 (.66) hardware. clk_prepare_enable
	 * is refcounted, so this does not conflict with the later resume path
	 * once cix_system_ready flips true and genuinely runs.
	 */
	if (!IS_ERR_OR_NULL(ptdev->clks.core)) {
		ret = clk_prepare_enable(ptdev->clks.core);
		if (ret)
			return ret;
	}

	/* The shader-stack clock must be running before any SHADER_PWRON or the
	 * power transition never completes (see panthor_clk_init()). Mirror the
	 * core-clock early enable above. clk_prepare_enable() is refcounted, so
	 * this does not conflict with the resume path enabling it again.
	 */
	if (!IS_ERR_OR_NULL(ptdev->clks.stacks)) {
		ret = clk_prepare_enable(ptdev->clks.stacks);
		if (ret)
			return ret;
	}

	for (unsigned int i = 0; i < ARRAY_SIZE(ptdev->clks.backup); i++) {
		if (!IS_ERR_OR_NULL(ptdev->clks.backup[i])) {
			ret = clk_prepare_enable(ptdev->clks.backup[i]);
			if (ret)
				return ret;
		}
	}

	ret = panthor_pm_domain_init(ptdev);
	if (ret) {
		drm_err(&ptdev->base, "init pm-domains failed, ret=%d", ret);
		return ret;
	}

	ret = panthor_init_power(ptdev->base.dev);
	if (ret < 0) {
		drm_err(&ptdev->base, "init power domains failed, ret=%d", ret);
		panthor_pm_domain_fini(ptdev);
		return ret;
	}

	ret = panthor_devfreq_init(ptdev);
	if (ret) {
		panthor_pm_domain_fini(ptdev);
		return ret;
	}

	/*
	 * Sky1 has two iomem regions: resource[0] = RCSU control,
	 * resource[1] = GPU primary register block. Other platforms
	 * have one iomem at resource[0].
	 */
	if (panthor_is_sky1(ptdev)) {
		ptdev->sky1_rcsu_reg = devm_platform_ioremap_resource(
				to_platform_device(ptdev->base.dev), 0);
		if (IS_ERR(ptdev->sky1_rcsu_reg)) {
			panthor_pm_domain_fini(ptdev);
			return PTR_ERR(ptdev->sky1_rcsu_reg);
		}

		ptdev->iomem = devm_platform_get_and_ioremap_resource(
				to_platform_device(ptdev->base.dev), 1, &res);
	} else {
		ptdev->iomem = devm_platform_get_and_ioremap_resource(
				to_platform_device(ptdev->base.dev), 0, &res);
	}
	if (IS_ERR(ptdev->iomem)) {
		panthor_pm_domain_fini(ptdev);
		return PTR_ERR(ptdev->iomem);
	}

	ptdev->phys_addr = res->start;

	ret = devm_pm_runtime_enable(ptdev->base.dev);
	if (ret) {
		panthor_pm_domain_fini(ptdev);
		return ret;
	}

	ret = pm_runtime_resume_and_get(ptdev->base.dev);
	if (ret) {
		panthor_pm_domain_fini(ptdev);
		return ret;
	}

	/* If PM is disabled, we need to call panthor_device_resume() manually. */
	if (!IS_ENABLED(CONFIG_PM)) {
		ret = panthor_device_resume(ptdev->base.dev);
		if (ret) {
			panthor_pm_domain_fini(ptdev);
			return ret;
		}
	}

	/*
	 * Sky1: cycle the GPU IP reset + enable RCSU qchannel clock gating
	 * (steps 3-5 of the documented power-on sequence) before the first
	 * GPU register access below (panthor_hw_init() -> GPU_ID read).
	 * See panthor_sky1_hw_reset_cycle()'s comment for why this is
	 * required in addition to the ACPI power-supply un-secure done in
	 * panthor_pm_domain_init().
	 */
	if (panthor_is_sky1(ptdev)) {
		ret = panthor_sky1_hw_reset_cycle(ptdev);
		if (ret)
			goto err_rpm_put;
	}

	ret = panthor_hw_init(ptdev);
	if (ret)
		goto err_rpm_put;

	ret = panthor_pwr_init(ptdev);
	if (ret)
		goto err_rpm_put;

	ret = panthor_gpu_init(ptdev);
	if (ret)
		goto err_unplug_pwr;

	ret = panthor_gpu_coherency_init(ptdev);
	if (ret)
		goto err_unplug_gpu;

	ret = panthor_gem_shrinker_init(ptdev);
	if (ret)
		goto err_unplug_gpu;

	ret = panthor_mmu_init(ptdev);
	if (ret)
		goto err_unplug_shrinker;

	ret = panthor_fw_init(ptdev);
	if (ret)
		goto err_unplug_mmu;

	ret = panthor_sched_init(ptdev);
	if (ret)
		goto err_unplug_fw;

	panthor_gem_init(ptdev);

	/* Now that everything is initialized, we can enable the reset work. */
	enable_work(&ptdev->reset.work);

	/* ~3 frames */
	pm_runtime_set_autosuspend_delay(ptdev->base.dev, 50);
	pm_runtime_use_autosuspend(ptdev->base.dev);

	ret = drm_dev_register(&ptdev->base, 0);
	if (ret)
		goto err_disable_autosuspend;

	pm_runtime_put_autosuspend(ptdev->base.dev);
	return 0;

err_disable_autosuspend:
	pm_runtime_dont_use_autosuspend(ptdev->base.dev);
	panthor_sched_unplug(ptdev);

err_unplug_fw:
	panthor_fw_unplug(ptdev);

err_unplug_mmu:
	panthor_mmu_unplug(ptdev);

err_unplug_shrinker:
	panthor_gem_shrinker_unplug(ptdev);

err_unplug_gpu:
	panthor_gpu_unplug(ptdev);

err_unplug_pwr:
	panthor_pwr_unplug(ptdev);

err_rpm_put:
	pm_runtime_put_sync_suspend(ptdev->base.dev);

	panthor_pm_domain_fini(ptdev);

	return ret;
}

#define PANTHOR_EXCEPTION(id) \
	[DRM_PANTHOR_EXCEPTION_ ## id] = { \
		.name = #id, \
	}

struct panthor_exception_info {
	const char *name;
};

static const struct panthor_exception_info panthor_exception_infos[] = {
	PANTHOR_EXCEPTION(OK),
	PANTHOR_EXCEPTION(TERMINATED),
	PANTHOR_EXCEPTION(KABOOM),
	PANTHOR_EXCEPTION(EUREKA),
	PANTHOR_EXCEPTION(ACTIVE),
	PANTHOR_EXCEPTION(CS_RES_TERM),
	PANTHOR_EXCEPTION(CS_CONFIG_FAULT),
	PANTHOR_EXCEPTION(CS_UNRECOVERABLE),
	PANTHOR_EXCEPTION(CS_ENDPOINT_FAULT),
	PANTHOR_EXCEPTION(CS_BUS_FAULT),
	PANTHOR_EXCEPTION(CS_INSTR_INVALID),
	PANTHOR_EXCEPTION(CS_CALL_STACK_OVERFLOW),
	PANTHOR_EXCEPTION(CS_INHERIT_FAULT),
	PANTHOR_EXCEPTION(INSTR_INVALID_PC),
	PANTHOR_EXCEPTION(INSTR_INVALID_ENC),
	PANTHOR_EXCEPTION(INSTR_BARRIER_FAULT),
	PANTHOR_EXCEPTION(DATA_INVALID_FAULT),
	PANTHOR_EXCEPTION(TILE_RANGE_FAULT),
	PANTHOR_EXCEPTION(ADDR_RANGE_FAULT),
	PANTHOR_EXCEPTION(IMPRECISE_FAULT),
	PANTHOR_EXCEPTION(OOM),
	PANTHOR_EXCEPTION(CSF_FW_INTERNAL_ERROR),
	PANTHOR_EXCEPTION(CSF_RES_EVICTION_TIMEOUT),
	PANTHOR_EXCEPTION(GPU_BUS_FAULT),
	PANTHOR_EXCEPTION(GPU_SHAREABILITY_FAULT),
	PANTHOR_EXCEPTION(SYS_SHAREABILITY_FAULT),
	PANTHOR_EXCEPTION(GPU_CACHEABILITY_FAULT),
	PANTHOR_EXCEPTION(TRANSLATION_FAULT_0),
	PANTHOR_EXCEPTION(TRANSLATION_FAULT_1),
	PANTHOR_EXCEPTION(TRANSLATION_FAULT_2),
	PANTHOR_EXCEPTION(TRANSLATION_FAULT_3),
	PANTHOR_EXCEPTION(TRANSLATION_FAULT_4),
	PANTHOR_EXCEPTION(PERM_FAULT_0),
	PANTHOR_EXCEPTION(PERM_FAULT_1),
	PANTHOR_EXCEPTION(PERM_FAULT_2),
	PANTHOR_EXCEPTION(PERM_FAULT_3),
	PANTHOR_EXCEPTION(ACCESS_FLAG_1),
	PANTHOR_EXCEPTION(ACCESS_FLAG_2),
	PANTHOR_EXCEPTION(ACCESS_FLAG_3),
	PANTHOR_EXCEPTION(ADDR_SIZE_FAULT_IN),
	PANTHOR_EXCEPTION(ADDR_SIZE_FAULT_OUT0),
	PANTHOR_EXCEPTION(ADDR_SIZE_FAULT_OUT1),
	PANTHOR_EXCEPTION(ADDR_SIZE_FAULT_OUT2),
	PANTHOR_EXCEPTION(ADDR_SIZE_FAULT_OUT3),
	PANTHOR_EXCEPTION(MEM_ATTR_FAULT_0),
	PANTHOR_EXCEPTION(MEM_ATTR_FAULT_1),
	PANTHOR_EXCEPTION(MEM_ATTR_FAULT_2),
	PANTHOR_EXCEPTION(MEM_ATTR_FAULT_3),
};

const char *panthor_exception_name(struct panthor_device *ptdev, u32 exception_code)
{
	if (exception_code >= ARRAY_SIZE(panthor_exception_infos) ||
	    !panthor_exception_infos[exception_code].name)
		return "Unknown exception type";

	return panthor_exception_infos[exception_code].name;
}

static vm_fault_t panthor_mmio_vm_fault(struct vm_fault *vmf)
{
	struct vm_area_struct *vma = vmf->vma;
	struct panthor_device *ptdev = vma->vm_private_data;
	u64 offset = (u64)vma->vm_pgoff << PAGE_SHIFT;
	unsigned long pfn;
	pgprot_t pgprot;
	vm_fault_t ret;
	bool active;
	int cookie;

	if (!drm_dev_enter(&ptdev->base, &cookie))
		return VM_FAULT_SIGBUS;

	mutex_lock(&ptdev->pm.mmio_lock);
	active = atomic_read(&ptdev->pm.state) == PANTHOR_DEVICE_PM_STATE_ACTIVE;

	switch (offset) {
	case DRM_PANTHOR_USER_FLUSH_ID_MMIO_OFFSET:
		if (active)
			pfn = __phys_to_pfn(ptdev->phys_addr + CSF_GPU_LATEST_FLUSH_ID);
		else
			pfn = page_to_pfn(ptdev->pm.dummy_latest_flush);
		break;

	default:
		ret = VM_FAULT_SIGBUS;
		goto out_unlock;
	}

	pgprot = vma->vm_page_prot;
	if (active)
		pgprot = pgprot_noncached(pgprot);

	ret = vmf_insert_pfn_prot(vma, vmf->address, pfn, pgprot);

out_unlock:
	mutex_unlock(&ptdev->pm.mmio_lock);
	drm_dev_exit(cookie);
	return ret;
}

static const struct vm_operations_struct panthor_mmio_vm_ops = {
	.fault = panthor_mmio_vm_fault,
};

int panthor_device_mmap_io(struct panthor_device *ptdev, struct vm_area_struct *vma)
{
	u64 offset = (u64)vma->vm_pgoff << PAGE_SHIFT;

	if ((vma->vm_flags & VM_SHARED) == 0)
		return -EINVAL;

	switch (offset) {
	case DRM_PANTHOR_USER_FLUSH_ID_MMIO_OFFSET:
		if (vma->vm_end - vma->vm_start != PAGE_SIZE ||
		    (vma->vm_flags & (VM_WRITE | VM_EXEC)))
			return -EINVAL;
		vm_flags_clear(vma, VM_MAYWRITE);

		break;

	default:
		return -EINVAL;
	}

	/* Defer actual mapping to the fault handler. */
	vma->vm_private_data = ptdev;
	vma->vm_ops = &panthor_mmio_vm_ops;
	vm_flags_set(vma,
		     VM_IO | VM_DONTCOPY | VM_DONTEXPAND |
		     VM_NORESERVE | VM_DONTDUMP | VM_PFNMAP);
	return 0;
}

static int panthor_device_resume_hw_components(struct panthor_device *ptdev)
{
	int ret;

	panthor_pwr_resume(ptdev);
	panthor_gpu_resume(ptdev);
	panthor_mmu_resume(ptdev);

	ret = panthor_fw_resume(ptdev);
	if (!ret)
		return 0;

	panthor_mmu_suspend(ptdev);
	panthor_gpu_suspend(ptdev);
	panthor_pwr_suspend(ptdev);
	return ret;
}

int panthor_device_resume(struct device *dev)
{
	struct panthor_device *ptdev = dev_get_drvdata(dev);
	int ret, cookie;

	if (atomic_read(&ptdev->pm.state) != PANTHOR_DEVICE_PM_STATE_SUSPENDED)
		return -EINVAL;

	atomic_set(&ptdev->pm.state, PANTHOR_DEVICE_PM_STATE_RESUMING);

	ret = clk_prepare_enable(ptdev->clks.core);
	if (ret)
		goto err_set_suspended;

	ret = clk_prepare_enable(ptdev->clks.stacks);
	if (ret)
		goto err_disable_core_clk;

	ret = clk_prepare_enable(ptdev->clks.coregroup);
	if (ret)
		goto err_disable_stacks_clk;

	panthor_devfreq_resume(ptdev);

	if (panthor_device_is_initialized(ptdev) &&
	    drm_dev_enter(&ptdev->base, &cookie)) {
		/* If there was a reset pending at the time we suspended the
		 * device, we force a slow reset.
		 */
		if (atomic_read(&ptdev->reset.pending)) {
			ptdev->reset.fast = false;
			atomic_set(&ptdev->reset.pending, 0);
		}

		ret = panthor_device_resume_hw_components(ptdev);
		if (ret && ptdev->reset.fast) {
			drm_err(&ptdev->base, "Fast reset failed, trying a slow reset");
			ptdev->reset.fast = false;
			ret = panthor_device_resume_hw_components(ptdev);
		}

		if (!ret)
			panthor_sched_resume(ptdev);

		drm_dev_exit(cookie);

		if (ret)
			goto err_suspend_devfreq;
	}

	/* Clear all IOMEM mappings pointing to this device after we've
	 * resumed. This way the fake mappings pointing to the dummy pages
	 * are removed and the real iomem mapping will be restored on next
	 * access.
	 */
	mutex_lock(&ptdev->pm.mmio_lock);
	unmap_mapping_range(ptdev->base.anon_inode->i_mapping,
			    DRM_PANTHOR_USER_MMIO_OFFSET, 0, 1);
	atomic_set(&ptdev->pm.state, PANTHOR_DEVICE_PM_STATE_ACTIVE);
	mutex_unlock(&ptdev->pm.mmio_lock);
	return 0;

err_suspend_devfreq:
	panthor_devfreq_suspend(ptdev);
	clk_disable_unprepare(ptdev->clks.coregroup);

err_disable_stacks_clk:
	clk_disable_unprepare(ptdev->clks.stacks);

err_disable_core_clk:
	clk_disable_unprepare(ptdev->clks.core);

err_set_suspended:
	atomic_set(&ptdev->pm.state, PANTHOR_DEVICE_PM_STATE_SUSPENDED);
	atomic_set(&ptdev->pm.recovery_needed, 1);
	return ret;
}

int panthor_device_suspend(struct device *dev)
{
	struct panthor_device *ptdev = dev_get_drvdata(dev);
	int cookie;

	if (atomic_read(&ptdev->pm.state) != PANTHOR_DEVICE_PM_STATE_ACTIVE)
		return -EINVAL;

	/* Clear all IOMEM mappings pointing to this device before we
	 * shutdown the power-domain and clocks. Failing to do that results
	 * in external aborts when the process accesses the iomem region.
	 * We change the state and call unmap_mapping_range() with the
	 * mmio_lock held to make sure the vm_fault handler won't set up
	 * invalid mappings.
	 */
	mutex_lock(&ptdev->pm.mmio_lock);
	atomic_set(&ptdev->pm.state, PANTHOR_DEVICE_PM_STATE_SUSPENDING);
	unmap_mapping_range(ptdev->base.anon_inode->i_mapping,
			    DRM_PANTHOR_USER_MMIO_OFFSET, 0, 1);
	mutex_unlock(&ptdev->pm.mmio_lock);

	if (panthor_device_is_initialized(ptdev) &&
	    drm_dev_enter(&ptdev->base, &cookie)) {
		cancel_work_sync(&ptdev->reset.work);

		/* We prepare everything as if we were resetting the GPU.
		 * The end of the reset will happen in the resume path though.
		 */
		panthor_sched_suspend(ptdev);
		panthor_fw_suspend(ptdev);
		panthor_mmu_suspend(ptdev);
		panthor_gpu_suspend(ptdev);
		panthor_pwr_suspend(ptdev);
		drm_dev_exit(cookie);
	}

	panthor_devfreq_suspend(ptdev);

	clk_disable_unprepare(ptdev->clks.coregroup);
	clk_disable_unprepare(ptdev->clks.stacks);
	clk_disable_unprepare(ptdev->clks.core);
	atomic_set(&ptdev->pm.state, PANTHOR_DEVICE_PM_STATE_SUSPENDED);
	return 0;
}

int panthor_device_suspend_noirq(struct device *dev)
{
	return pm_runtime_force_suspend(dev);
}

int panthor_device_resume_noirq(struct device *dev)
{
	struct panthor_device *ptdev = dev_get_drvdata(dev);
	int ret;

	/*
	 * Sky1: suspend-to-RAM cuts the GPU power domain, losing the IP-reset
	 * state and the RCSU Q-channel clock-gate enable bit. Re-run power-on
	 * steps 3-5 before the forced runtime resume re-enables clocks and
	 * panthor_device_resume() touches GPU MMIO. (NCZ 0188 equivalent.)
	 */
	if (panthor_is_sky1(ptdev) && panthor_device_is_initialized(ptdev)) {
		ret = panthor_sky1_hw_reset_cycle(ptdev);
		if (ret)
			return ret;
	}

	return pm_runtime_force_resume(dev);
}
