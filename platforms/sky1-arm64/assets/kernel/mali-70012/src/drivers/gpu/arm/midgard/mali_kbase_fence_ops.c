// SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note
/*
 *
 * (C) COPYRIGHT 2020-2023 ARM Limited. All rights reserved.
 *
 * This program is free software and is provided to you under the terms of the
 * GNU General Public License version 2 as published by the Free Software
 * Foundation, and any use by you of this program is subject to the terms
 * of such GNU license.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, you can access it online at
 * http://www.gnu.org/licenses/gpl-2.0.html.
 *
 */

#include <linux/atomic.h>
#include <linux/list.h>
#include <mali_kbase_fence.h>
#include <mali_kbase.h>

static const char *kbase_fence_get_driver_name(struct dma_fence *fence)
{
	CSTD_UNUSED(fence);

	return KBASE_DRV_NAME;
}

#if MALI_USE_CSF
static const char *kbase_fence_get_timeline_name(struct dma_fence *fence)
{
	struct kbase_kcpu_dma_fence *kcpu_fence = (struct kbase_kcpu_dma_fence *)fence;

	return kcpu_fence->metadata->timeline_name;
}
#else
static const char *kbase_fence_get_timeline_name(struct dma_fence *fence)
{
	CSTD_UNUSED(fence);

	return KBASE_TIMELINE_NAME;
}
#endif /* MALI_USE_CSF */

static bool kbase_fence_enable_signaling(struct dma_fence *fence)
{
	CSTD_UNUSED(fence);

	return true;
}

/* See the MALI_KBASE_TARGETS_7_0_12_CIX_SKY1_NEXT_BACKPORT comment in
 * version_compat_defs.h: the 7.0.12-cix-sky1-next kernel backported
 * kernel 7.2's dma_fence_ops shape (no fence_value_str) despite its
 * own LINUX_VERSION_CODE reporting 7.0.12, so this guard must also
 * exclude that exact kernel, not just >= 7.2.0. Reuse the single
 * central definition (rather than re-deriving the same condition here)
 * so tightening it in one place can't drift out of sync between files.
 */
#if (KERNEL_VERSION(7, 2, 0) > LINUX_VERSION_CODE) && \
	!MALI_KBASE_TARGETS_7_0_12_CIX_SKY1_NEXT_BACKPORT
/* Kernel 7.2 dropped dma_fence_ops.fence_value_str (see the two
 * kbase_fence_ops initializers below) -- this helper is only referenced,
 * and therefore only compiled, on older kernels that still have it.
 */
static void kbase_fence_fence_value_str(struct dma_fence *fence, char *str, int size)
{
	char *format;

	if (KERNEL_VERSION(5, 1, 0) > LINUX_VERSION_CODE)
		format = "%u";
	else
		format = "%llu";

	if (unlikely(!scnprintf(str, (size_t)size, format, fence->seqno)))
		pr_err("Fail to encode fence seqno to string");
}
#endif /* (KERNEL_VERSION(7, 2, 0) > LINUX_VERSION_CODE) */

#if MALI_USE_CSF
static void kbase_fence_release(struct dma_fence *fence)
{
	struct kbase_kcpu_dma_fence *kcpu_fence = (struct kbase_kcpu_dma_fence *)fence;

	kbase_kcpu_dma_fence_meta_put(kcpu_fence->metadata);
	kfree(kcpu_fence);
}

extern const struct dma_fence_ops kbase_fence_ops; /* silence checker warning */
const struct dma_fence_ops kbase_fence_ops = { .wait = dma_fence_default_wait,
					       .get_driver_name = kbase_fence_get_driver_name,
					       .get_timeline_name = kbase_fence_get_timeline_name,
					       .enable_signaling = kbase_fence_enable_signaling,
/* See the MALI_KBASE_TARGETS_7_0_12_CIX_SKY1_NEXT_BACKPORT comment in
 * version_compat_defs.h: the 7.0.12-cix-sky1-next kernel backported
 * kernel 7.2's dma_fence_ops shape (no fence_value_str) despite its
 * own LINUX_VERSION_CODE reporting 7.0.12, so this guard must also
 * exclude that exact kernel, not just >= 7.2.0. Reuse the single
 * central definition (rather than re-deriving the same condition here)
 * so tightening it in one place can't drift out of sync between files.
 */
#if (KERNEL_VERSION(7, 2, 0) > LINUX_VERSION_CODE) && \
	!MALI_KBASE_TARGETS_7_0_12_CIX_SKY1_NEXT_BACKPORT
					       .fence_value_str = kbase_fence_fence_value_str,
#endif
					       .release = kbase_fence_release };
#else
extern const struct dma_fence_ops kbase_fence_ops; /* silence checker warning */
const struct dma_fence_ops kbase_fence_ops = { .wait = dma_fence_default_wait,
					       .get_driver_name = kbase_fence_get_driver_name,
					       .get_timeline_name = kbase_fence_get_timeline_name,
					       .enable_signaling = kbase_fence_enable_signaling,
/* See the MALI_KBASE_TARGETS_7_0_12_CIX_SKY1_NEXT_BACKPORT comment in
 * version_compat_defs.h: the 7.0.12-cix-sky1-next kernel backported
 * kernel 7.2's dma_fence_ops shape (no fence_value_str) despite its
 * own LINUX_VERSION_CODE reporting 7.0.12, so this guard must also
 * exclude that exact kernel, not just >= 7.2.0. Reuse the single
 * central definition (rather than re-deriving the same condition here)
 * so tightening it in one place can't drift out of sync between files.
 */
#if (KERNEL_VERSION(7, 2, 0) > LINUX_VERSION_CODE) && \
	!MALI_KBASE_TARGETS_7_0_12_CIX_SKY1_NEXT_BACKPORT
					       .fence_value_str = kbase_fence_fence_value_str,
#endif
					       };
#endif /* MALI_USE_CSF */

KBASE_EXPORT_TEST_API(kbase_fence_ops);
