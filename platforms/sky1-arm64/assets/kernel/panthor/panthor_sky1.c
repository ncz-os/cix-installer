// SPDX-License-Identifier: GPL-2.0 or MIT
/* Copyright 2024 Cix Technology Group Co., Ltd. */

#include <linux/acpi.h>
#include <linux/arm-smccc.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/io.h>

#include "panthor_device.h"
#include "panthor_sky1.h"

/*
 * Sky1 raw SMC SCMI GPU power-on (CIX 7.1 reference path, NCZ 0186).
 *
 * Under DT, smc_devpd (arm,scmi-smc) sends SCMI POWER_STATE_SET to TFA
 * via SMC function 0xc2000001 with shared memory at 0x84380000. Under
 * ACPI there is no smc_devpd, so we make the raw SMC call directly.
 * Per the CIX 7.1 bring-up, TFA's handler powers the GPU domain AND
 * configures the IDM (Interconnect Domain Manager) to allow non-secure
 * (Linux) access to GPU registers.
 *
 * NOTE (O6N): the hardware-validated un-secure mechanism on O6N firmware
 * is the ACPI "power-supply" (_PR0._ON) attach in panthor_device.c, which
 * works with acpi_scmi_en=off. This SMC call is kept as a best-effort
 * complementary step (its caller treats failure as non-fatal).
 */

#if IS_ENABLED(CONFIG_ACPI)

#define SKY1_SMC_SCMI_FUNC_ID		0xc2000001
#define SKY1_SMC_SCMI_SHMEM_PHYS	0x84380000UL
#define SKY1_SMC_SCMI_SHMEM_SIZE	0x80
#define SKY1_PD_GPU			21

/* SCMI shared memory offsets */
#define SCMI_SHMEM_CHAN_STATUS		0x04
#define SCMI_SHMEM_FLAGS		0x10
#define SCMI_SHMEM_LENGTH		0x14
#define SCMI_SHMEM_MSG_HEADER		0x18
#define SCMI_SHMEM_MSG_PAYLOAD		0x1c

static int sky1_smc_scmi_power_set(struct device *dev, u32 domain, u32 state)
{
	void __iomem *shmem;
	struct arm_smccc_res res;
	u32 msg_header, resp_status;
	int timeout = 1000;

	shmem = ioremap(SKY1_SMC_SCMI_SHMEM_PHYS, SKY1_SMC_SCMI_SHMEM_SIZE);
	if (!shmem)
		return -ENOMEM;

	/* Wait for channel free */
	while (!(ioread32(shmem + SCMI_SHMEM_CHAN_STATUS) & BIT(0))) {
		if (--timeout <= 0) {
			dev_err(dev, "SCMI SMC channel busy timeout\n");
			iounmap(shmem);
			return -ETIMEDOUT;
		}
		udelay(10);
	}

	/* Clear channel status */
	iowrite32(0, shmem + SCMI_SHMEM_CHAN_STATUS);

	/* Polling mode (no interrupt) */
	iowrite32(0, shmem + SCMI_SHMEM_FLAGS);

	/*
	 * Message header:
	 *   Bits  0-7:  MSG_ID = 0x04 (POWER_STATE_SET)
	 *   Bits  8-9:  MSG_TYPE = 0 (command)
	 *   Bits 10-17: PROTOCOL_ID = 0x11 (POWER)
	 *   Bits 18-27: TOKEN = 0
	 */
	msg_header = 0x04 | (0x11 << 10);
	iowrite32(msg_header, shmem + SCMI_SHMEM_MSG_HEADER);

	/* Payload: flags(4) + domain(4) + state(4) = 12 bytes */
	iowrite32(0, shmem + SCMI_SHMEM_MSG_PAYLOAD);		/* flags: sync */
	iowrite32(domain, shmem + SCMI_SHMEM_MSG_PAYLOAD + 4);	/* domain_id */
	iowrite32(state, shmem + SCMI_SHMEM_MSG_PAYLOAD + 8);	/* power_state */

	/* Length = msg_header(4) + payload(12) = 16 */
	iowrite32(16, shmem + SCMI_SHMEM_LENGTH);

	/* SMC call: param_page = phys >> 12, param_offset = phys & 0xFFF */
	arm_smccc_smc(SKY1_SMC_SCMI_FUNC_ID,
		      SKY1_SMC_SCMI_SHMEM_PHYS >> 12,
		      SKY1_SMC_SCMI_SHMEM_PHYS & 0xFFF,
		      0, 0, 0, 0, 0, &res);

	if (res.a0) {
		dev_err(dev, "SCMI SMC returned error: 0x%lx\n", res.a0);
		iounmap(shmem);
		return -EIO;
	}

	/* Response: first word of payload is SCMI status */
	resp_status = ioread32(shmem + SCMI_SHMEM_MSG_PAYLOAD);
	iounmap(shmem);

	if (resp_status != 0) {
		dev_err(dev, "SCMI POWER_STATE_SET domain %u failed: %d\n",
			domain, resp_status);
		return -EIO;
	}

	dev_info(dev, "GPU power domain %u powered on via SMC SCMI\n", domain);
	return 0;
}

int sky1_gpu_power_on(struct panthor_device *ptdev)
{
	if (!panthor_is_sky1(ptdev))
		return 0;

	return sky1_smc_scmi_power_set(ptdev->base.dev, SKY1_PD_GPU, 0);
}

#endif /* IS_ENABLED(CONFIG_ACPI) */
