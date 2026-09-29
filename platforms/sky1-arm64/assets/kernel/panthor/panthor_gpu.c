// SPDX-License-Identifier: GPL-2.0 or MIT
/* Copyright 2018 Marty E. Plummer <hanetzer@startmail.com> */
/* Copyright 2019 Linaro, Ltd., Rob Herring <robh@kernel.org> */
/* Copyright 2019 Collabora ltd. */

#include <linux/acpi.h>
#include <linux/bitfield.h>
#include <linux/bitmap.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/pm_runtime.h>

#include <drm/drm_drv.h>
#include <drm/drm_managed.h>
#include <drm/drm_print.h>

#include "panthor_device.h"
#include "panthor_gpu.h"
#include "panthor_sky1.h"
#include "panthor_gpu_regs.h"
#include "panthor_hw.h"

#define CREATE_TRACE_POINTS
#include "panthor_trace.h"

/**
 * struct panthor_gpu - GPU block management data.
 */
struct panthor_gpu {
	/** @iomem: CPU mapping of GPU_CONTROL iomem region */
	void __iomem *iomem;

	/** @irq: GPU irq. */
	struct panthor_irq irq;

	/** @reqs_lock: Lock protecting access to pending_reqs. */
	spinlock_t reqs_lock;

	/** @pending_reqs: Pending GPU requests. */
	u32 pending_reqs;

	/** @reqs_acked: GPU request wait queue. */
	wait_queue_head_t reqs_acked;

	/** @cache_flush_lock: Lock to serialize cache flushes */
	struct mutex cache_flush_lock;
};

#define GPU_INTERRUPTS_MASK	\
	(GPU_IRQ_FAULT | \
	 GPU_IRQ_PROTM_FAULT | \
	 GPU_IRQ_RESET_COMPLETED | \
	 GPU_IRQ_CLEAN_CACHES_COMPLETED)

#define GPU_POWER_INTERRUPTS_MASK	\
	(GPU_IRQ_POWER_CHANGED | GPU_IRQ_POWER_CHANGED_ALL)

static void panthor_gpu_coherency_set(struct panthor_device *ptdev)
{
	u32 val = ptdev->coherency_mode;

	if (val != PANTHOR_COHERENCY_NONE) {
		u32 features = gpu_read(ptdev->gpu->iomem, GPU_COHERENCY_FEATURES);

		if (features & GPU_COHERENCY_SHAREABLE_CACHE)
			val |= GPU_COHERENCY_SHAREABLE_CACHE;
	}

	gpu_write(ptdev->gpu->iomem, GPU_COHERENCY_PROTOCOL, val);
}

static void panthor_gpu_l2_config_set(struct panthor_device *ptdev)
{
	struct panthor_gpu *gpu = ptdev->gpu;
	const struct panthor_soc_data *data = ptdev->soc_data;
	u32 l2_config;
	u32 i;

	if (!data || !data->asn_hash_enable)
		return;

	if (GPU_ARCH_MAJOR(ptdev->gpu_info.gpu_id) < 11) {
		drm_err(&ptdev->base, "Custom ASN hash not supported by the device");
		return;
	}

	for (i = 0; i < ARRAY_SIZE(data->asn_hash); i++)
		gpu_write(gpu->iomem, GPU_ASN_HASH(i), data->asn_hash[i]);

	l2_config = gpu_read(gpu->iomem, GPU_L2_CONFIG);
	l2_config |= GPU_L2_CONFIG_ASN_HASH_ENABLE;
	gpu_write(gpu->iomem, GPU_L2_CONFIG, l2_config);
}

static void panthor_gpu_irq_handler(struct panthor_device *ptdev, u32 status)
{
	struct panthor_gpu *gpu = ptdev->gpu;

	gpu_write(gpu->irq.iomem, INT_CLEAR, status);

	if (tracepoint_enabled(gpu_power_status) && (status & GPU_POWER_INTERRUPTS_MASK))
		trace_gpu_power_status(ptdev->base.dev,
				       gpu_read64(gpu->iomem, SHADER_READY),
				       gpu_read64(gpu->iomem, TILER_READY),
				       gpu_read64(gpu->iomem, L2_READY));

	if (status & GPU_IRQ_FAULT) {
		u32 fault_status = gpu_read(gpu->iomem, GPU_FAULT_STATUS);
		u64 address = gpu_read64(gpu->iomem, GPU_FAULT_ADDR);

		drm_warn(&ptdev->base, "GPU Fault 0x%08x (%s) at 0x%016llx\n",
			 fault_status, panthor_exception_name(ptdev, fault_status & 0xFF),
			 address);
	}
	if (status & GPU_IRQ_PROTM_FAULT)
		drm_warn(&ptdev->base, "GPU Fault in protected mode\n");

	spin_lock(&ptdev->gpu->reqs_lock);
	if (status & ptdev->gpu->pending_reqs) {
		ptdev->gpu->pending_reqs &= ~status;
		wake_up_all(&ptdev->gpu->reqs_acked);
	}
	spin_unlock(&ptdev->gpu->reqs_lock);
}
PANTHOR_IRQ_HANDLER(gpu, panthor_gpu_irq_handler);

/**
 * panthor_gpu_unplug() - Called when the GPU is unplugged.
 * @ptdev: Device to unplug.
 */
void panthor_gpu_unplug(struct panthor_device *ptdev)
{
	unsigned long flags;

	/* Make sure the IRQ handler is not running after that point. */
	if (!IS_ENABLED(CONFIG_PM) || pm_runtime_active(ptdev->base.dev))
		panthor_gpu_irq_suspend(&ptdev->gpu->irq);

	/* Wake-up all waiters. */
	spin_lock_irqsave(&ptdev->gpu->reqs_lock, flags);
	ptdev->gpu->pending_reqs = 0;
	wake_up_all(&ptdev->gpu->reqs_acked);
	spin_unlock_irqrestore(&ptdev->gpu->reqs_lock, flags);
}

/**
 * panthor_gpu_init() - Initialize the GPU block
 * @ptdev: Device.
 *
 * Return: 0 on success, a negative error code otherwise.
 */
int panthor_gpu_init(struct panthor_device *ptdev)
{
	struct panthor_gpu *gpu;
	u32 pa_bits;
	int ret, irq;

	gpu = drmm_kzalloc(&ptdev->base, sizeof(*gpu), GFP_KERNEL);
	if (!gpu)
		return -ENOMEM;

	gpu->iomem = ptdev->iomem + GPU_CONTROL_BASE;
	spin_lock_init(&gpu->reqs_lock);
	init_waitqueue_head(&gpu->reqs_acked);
	mutex_init(&gpu->cache_flush_lock);
	ptdev->gpu = gpu;

	dma_set_max_seg_size(ptdev->base.dev, UINT_MAX);
	pa_bits = GPU_MMU_FEATURES_PA_BITS(ptdev->gpu_info.mmu_features);
	ret = dma_set_mask_and_coherent(ptdev->base.dev, DMA_BIT_MASK(pa_bits));
	if (ret)
		return ret;

	/*
	 * Under ACPI, go straight to the positional lookup (index 2 = GPU,
	 * matching mali_kbase's own get_irqs(): "JOB","MMU","GPU" at indices
	 * 0,1,2 via platform_get_irq(pdev, i) when has_acpi_companion()) --
	 * plain ACPI _CRS has no resource names, so a byname() attempt here
	 * is guaranteed to fail and only produces a spurious "IRQ gpu not
	 * found" dev_err from inside platform_get_irq_byname() itself. This
	 * does not change which IRQ is used under ACPI, only removes the
	 * noise (the prior code called byname() unconditionally, then always
	 * overwrote the result on ACPI anyway).
	 */
	if (IS_ENABLED(CONFIG_ACPI) && has_acpi_companion(ptdev->base.dev)) {
		irq = platform_get_irq(to_platform_device(ptdev->base.dev), 2);
	} else {
		irq = platform_get_irq_byname(to_platform_device(ptdev->base.dev), "gpu");
		if (irq < 0)
			irq = platform_get_irq_byname(to_platform_device(ptdev->base.dev), "GPU");
	}
	if (irq < 0)
		return irq;

	ret = panthor_request_gpu_irq(ptdev, &ptdev->gpu->irq, irq,
				      ptdev->iomem + GPU_INT_BASE);
	if (ret)
		return ret;

	panthor_gpu_irq_enable_events(&ptdev->gpu->irq, GPU_INTERRUPTS_MASK);
	panthor_gpu_irq_resume(&ptdev->gpu->irq);
	return 0;
}

int panthor_gpu_power_changed_on(struct panthor_device *ptdev)
{
	guard(pm_runtime_active)(ptdev->base.dev);

	panthor_gpu_irq_enable_events(&ptdev->gpu->irq, GPU_POWER_INTERRUPTS_MASK);

	return 0;
}

void panthor_gpu_power_changed_off(struct panthor_device *ptdev)
{
	guard(pm_runtime_active)(ptdev->base.dev);

	panthor_gpu_irq_disable_events(&ptdev->gpu->irq, GPU_POWER_INTERRUPTS_MASK);
}

/**
 * panthor_gpu_block_power_off() - Power-off a specific block of the GPU
 * @ptdev: Device.
 * @blk_name: Block name.
 * @pwroff_reg: Power-off register for this block.
 * @pwrtrans_reg: Power transition register for this block.
 * @mask: Sub-elements to power-off.
 * @timeout_us: Timeout in microseconds.
 *
 * Return: 0 on success, a negative error code otherwise.
 */
int panthor_gpu_block_power_off(struct panthor_device *ptdev,
				const char *blk_name,
				u32 pwroff_reg, u32 pwrtrans_reg,
				u64 mask, u32 timeout_us)
{
	struct panthor_gpu *gpu = ptdev->gpu;
	u64 val;
	int ret;

	ret = gpu_read64_relaxed_poll_timeout(gpu->iomem, pwrtrans_reg, val,
					      !(mask & val), 100, timeout_us);
	if (ret) {
		drm_err(&ptdev->base,
			"timeout waiting on %s:%llx power transition", blk_name,
			mask);
		return ret;
	}

	gpu_write64(gpu->iomem, pwroff_reg, mask);

	ret = gpu_read64_relaxed_poll_timeout(gpu->iomem, pwrtrans_reg, val,
					      !(mask & val), 100, timeout_us);
	if (ret) {
		drm_err(&ptdev->base,
			"timeout waiting on %s:%llx power transition", blk_name,
			mask);
		return ret;
	}

	return 0;
}

/**
 * panthor_gpu_block_power_on() - Power-on a specific block of the GPU
 * @ptdev: Device.
 * @blk_name: Block name.
 * @pwron_reg: Power-on register for this block.
 * @pwrtrans_reg: Power transition register for this block.
 * @rdy_reg: Power transition ready register.
 * @mask: Sub-elements to power-on.
 * @timeout_us: Timeout in microseconds.
 *
 * Return: 0 on success, a negative error code otherwise.
 */
int panthor_gpu_block_power_on(struct panthor_device *ptdev,
			       const char *blk_name,
			       u32 pwron_reg, u32 pwrtrans_reg,
			       u32 rdy_reg, u64 mask, u32 timeout_us)
{
	struct panthor_gpu *gpu = ptdev->gpu;
	u64 val;
	int ret;

	ret = gpu_read64_relaxed_poll_timeout(gpu->iomem, pwrtrans_reg, val,
					      !(mask & val), 100, timeout_us);
	if (ret) {
		drm_err(&ptdev->base,
			"timeout waiting on %s:%llx power transition", blk_name,
			mask);
		return ret;
	}

	gpu_write64(gpu->iomem, pwron_reg, mask);

	ret = gpu_read64_relaxed_poll_timeout(gpu->iomem, rdy_reg, val,
					      (mask & val) == mask,
					      100, timeout_us);
	if (ret) {
		drm_err(&ptdev->base, "timeout waiting on %s:%llx readiness",
			blk_name, mask);
		return ret;
	}

	return 0;
}

void panthor_gpu_l2_power_off(struct panthor_device *ptdev)
{
	panthor_gpu_power_off(ptdev, L2, ptdev->gpu_info.l2_present, 20000);
}

/**
 * panthor_gpu_l2_power_on() - Power-on the L2-cache
 * @ptdev: Device.
 *
 * Return: 0 on success, a negative error code otherwise.
 */
int panthor_gpu_l2_power_on(struct panthor_device *ptdev)
{
	if (ptdev->gpu_info.l2_present != 1) {
		/*
		 * Only support one core group now.
		 * ~(l2_present - 1) unsets all bits in l2_present except
		 * the bottom bit. (l2_present - 2) has all the bits in
		 * the first core group set. AND them together to generate
		 * a mask of cores in the first core group.
		 */
		u64 core_mask = ~(ptdev->gpu_info.l2_present - 1) &
				(ptdev->gpu_info.l2_present - 2);
		drm_info_once(&ptdev->base, "using only 1st core group (%lu cores from %lu)\n",
			      hweight64(core_mask),
			      hweight64(ptdev->gpu_info.shader_present));
	}

	/* Set the desired coherency mode and L2 config before the power up of L2 */
	panthor_gpu_coherency_set(ptdev);
	panthor_gpu_l2_config_set(ptdev);

	/* CIX Sky1 needs special PHBA setup before L2 activation */
	if (panthor_is_sky1(ptdev)) {
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_PBHA_OVERRIDE(3), 0x22000000);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(0), 0x00230000);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(1), 0x00000023);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(2), 0x00000000);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(3), 0x00000000);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(4), 0x00523222);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(5), 0x00523200);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(6), 0x00000022);
		gpu_write(ptdev->gpu->iomem, GPU_SYSC_ALLOC(7), 0x00000032);

		/* Required for LS_MEM_* related counters */
		gpu_write(ptdev->gpu->iomem, 0x306C, 0xFFFFFFFF);
		gpu_write(ptdev->gpu->iomem, 0x3070, 0xFFFFFFFF);
		gpu_write(ptdev->gpu->iomem, 0x307C, 0xFFFFFFFF);
		gpu_write(ptdev->gpu->iomem, 0x3074, 0xFFFFFFFF);
		gpu_write(ptdev->gpu->iomem, 0x3068, 0x1);
	}

	return panthor_gpu_power_on(ptdev, L2, 1, 20000);
}

/**
 * panthor_gpu_flush_caches() - Flush caches
 * @ptdev: Device.
 * @l2: L2 flush type.
 * @lsc: LSC flush type.
 * @other: Other flush type.
 *
 * Return: 0 on success, a negative error code otherwise.
 */
int panthor_gpu_flush_caches(struct panthor_device *ptdev,
			     u32 l2, u32 lsc, u32 other)
{
	struct panthor_gpu *gpu = ptdev->gpu;
	unsigned long flags;
	int ret = 0;

	/* Serialize cache flush operations. */
	guard(mutex)(&ptdev->gpu->cache_flush_lock);

	spin_lock_irqsave(&ptdev->gpu->reqs_lock, flags);
	if (!(ptdev->gpu->pending_reqs & GPU_IRQ_CLEAN_CACHES_COMPLETED)) {
		ptdev->gpu->pending_reqs |= GPU_IRQ_CLEAN_CACHES_COMPLETED;
		gpu_write(gpu->iomem, GPU_CMD, GPU_FLUSH_CACHES(l2, lsc, other));
	} else {
		ret = -EIO;
	}
	spin_unlock_irqrestore(&ptdev->gpu->reqs_lock, flags);

	if (ret)
		return ret;

	if (!wait_event_timeout(ptdev->gpu->reqs_acked,
				!(ptdev->gpu->pending_reqs & GPU_IRQ_CLEAN_CACHES_COMPLETED),
				msecs_to_jiffies(100))) {
		spin_lock_irqsave(&ptdev->gpu->reqs_lock, flags);
		if ((ptdev->gpu->pending_reqs & GPU_IRQ_CLEAN_CACHES_COMPLETED) != 0 &&
		    !(gpu_read(gpu->irq.iomem, INT_RAWSTAT) & GPU_IRQ_CLEAN_CACHES_COMPLETED))
			ret = -ETIMEDOUT;
		else
			ptdev->gpu->pending_reqs &= ~GPU_IRQ_CLEAN_CACHES_COMPLETED;
		spin_unlock_irqrestore(&ptdev->gpu->reqs_lock, flags);
	}

	if (ret) {
		panthor_device_schedule_reset(ptdev);
		drm_err(&ptdev->base, "Flush caches timeout");
	}

	return ret;
}

/**
 * panthor_gpu_soft_reset() - Issue a soft-reset
 * @ptdev: Device.
 *
 * Return: 0 on success, a negative error code otherwise.
 */
int panthor_gpu_soft_reset(struct panthor_device *ptdev)
{
	struct panthor_gpu *gpu = ptdev->gpu;
	bool timedout = false;
	unsigned long flags;

	spin_lock_irqsave(&ptdev->gpu->reqs_lock, flags);
	if (!drm_WARN_ON(&ptdev->base,
			 ptdev->gpu->pending_reqs & GPU_IRQ_RESET_COMPLETED)) {
		ptdev->gpu->pending_reqs |= GPU_IRQ_RESET_COMPLETED;
		gpu_write(gpu->irq.iomem, INT_CLEAR, GPU_IRQ_RESET_COMPLETED);
		gpu_write(gpu->iomem, GPU_CMD, GPU_SOFT_RESET);
	}
	spin_unlock_irqrestore(&ptdev->gpu->reqs_lock, flags);

	if (!wait_event_timeout(ptdev->gpu->reqs_acked,
				!(ptdev->gpu->pending_reqs & GPU_IRQ_RESET_COMPLETED),
				msecs_to_jiffies(100))) {
		spin_lock_irqsave(&ptdev->gpu->reqs_lock, flags);
		if ((ptdev->gpu->pending_reqs & GPU_IRQ_RESET_COMPLETED) != 0 &&
		    !(gpu_read(gpu->irq.iomem, INT_RAWSTAT) & GPU_IRQ_RESET_COMPLETED))
			timedout = true;
		else
			ptdev->gpu->pending_reqs &= ~GPU_IRQ_RESET_COMPLETED;
		spin_unlock_irqrestore(&ptdev->gpu->reqs_lock, flags);
	}

	if (timedout) {
		drm_err(&ptdev->base, "Soft reset timeout");
		return -ETIMEDOUT;
	}

	ptdev->gpu->pending_reqs = 0;
	return 0;
}

/**
 * panthor_gpu_suspend() - Suspend the GPU block.
 * @ptdev: Device.
 *
 * Suspend the GPU irq. This should be called last in the suspend procedure,
 * after all other blocks have been suspented.
 */
void panthor_gpu_suspend(struct panthor_device *ptdev)
{
	/* On a fast reset, simply power down the L2. */
	if (!ptdev->reset.fast)
		panthor_hw_soft_reset(ptdev);
	else
		panthor_hw_l2_power_off(ptdev);

	panthor_gpu_irq_suspend(&ptdev->gpu->irq);
}

/**
 * panthor_gpu_resume() - Resume the GPU block.
 * @ptdev: Device.
 *
 * Resume the IRQ handler and power-on the L2-cache.
 * The FW takes care of powering the other blocks.
 */
void panthor_gpu_resume(struct panthor_device *ptdev)
{
	panthor_gpu_irq_resume(&ptdev->gpu->irq);
	panthor_hw_l2_power_on(ptdev);
}

u64 panthor_gpu_get_timestamp(struct panthor_device *ptdev)
{
	return gpu_read64_counter(ptdev->gpu->iomem, GPU_TIMESTAMP);
}

u64 panthor_gpu_get_timestamp_offset(struct panthor_device *ptdev)
{
	return gpu_read64(ptdev->gpu->iomem, GPU_TIMESTAMP_OFFSET);
}

u64 panthor_gpu_get_cycle_count(struct panthor_device *ptdev)
{
	return gpu_read64_counter(ptdev->gpu->iomem, GPU_CYCLE_COUNT);
}

int panthor_gpu_coherency_init(struct panthor_device *ptdev)
{
	bool dma_coherent = device_get_dma_attr(ptdev->base.dev) == DEV_DMA_COHERENT;

	BUILD_BUG_ON(GPU_COHERENCY_NONE != DRM_PANTHOR_GPU_COHERENCY_NONE);
	BUILD_BUG_ON(GPU_COHERENCY_ACE_LITE != DRM_PANTHOR_GPU_COHERENCY_ACE_LITE);
	BUILD_BUG_ON(GPU_COHERENCY_ACE != DRM_PANTHOR_GPU_COHERENCY_ACE);

	/*
	 * Sky1 SoC: the GPU hardware supports full ACE (128/256-bit AMBA 4 ACE
	 * master) but the platform is wired ACE-Lite. The DPU is non-snooping and
	 * reads from SLC/DRAM, so ACE-Lite is correct: GPU L2 evictions route
	 * through HN-F and are absorbed into the SLC, making WB data visible to
	 * the DPU without an NC memattr. (cix-linux-main patches-7.1/00114)
	 */
	if (panthor_is_sky1(ptdev)) {
		ptdev->coherency_mode = PANTHOR_COHERENCY_ACE_LITE;
		drm_info(&ptdev->base, "Using ACE-Lite bus coherency (Sky1)\n");
	} else if (!dma_coherent) {
		ptdev->coherency_mode = PANTHOR_COHERENCY_NONE;
	} else {
		ptdev->coherency_mode = PANTHOR_COHERENCY_ACE_LITE;
	}

	/*
	 * NCZ deviation from 00114: keep the UAPI field in sync. CIX's patch drops
	 * gpu_info.selected_coherency entirely, but it is ABI --
	 * drm_panthor_gpu_info::selected_coherency is read by userspace (Mesa), so
	 * silently leaving it at 0 would change what every client sees.
	 */
	ptdev->gpu_info.selected_coherency =
		ptdev->coherency_mode == PANTHOR_COHERENCY_NONE ?
			GPU_COHERENCY_NONE : GPU_COHERENCY_ACE_LITE;

	if (ptdev->coherency_mode == PANTHOR_COHERENCY_NONE)
		return 0;

	/* Verify the hardware actually implements the selected protocol. */
	if (gpu_read(ptdev->gpu->iomem, GPU_COHERENCY_FEATURES) &
	    GPU_COHERENCY_PROT_BIT(ACE_LITE))
		return 0;

	drm_err(&ptdev->base, "ACE-Lite not supported by hardware");
	return -ENOTSUPP;
}
