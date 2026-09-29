/* SPDX-License-Identifier: GPL-2.0 or MIT */
/* Copyright 2024 Cix Technology Group Co., Ltd. */

#ifndef __PANTHOR_SKY1_H__
#define __PANTHOR_SKY1_H__

struct panthor_device;

#if IS_ENABLED(CONFIG_ACPI)

int sky1_gpu_power_on(struct panthor_device *ptdev);

#else

static inline int sky1_gpu_power_on(struct panthor_device *ptdev)
{
	return 0;
}

#endif

#endif /* __PANTHOR_SKY1_H__ */
