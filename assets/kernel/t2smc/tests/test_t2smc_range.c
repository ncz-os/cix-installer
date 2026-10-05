/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * test_t2smc_range.c - userspace boundary tests for the t2smc range
 * validators.
 *
 * The validators live in src/t2smc_range.h, which the DKMS hardening patch
 * adds to the module. They are pure (no kernel state), so they can be built
 * and exercised here against stub fan readers - no SMC hardware, no module
 * load. build/test-t2smc-range.sh extracts the header from the patch and
 * compiles this file against it.
 *
 * Build/run: bash build/test-t2smc-range.sh
 */
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>

#include "t2smc_range.h"

static int failures;

#define CHECK(cond, ...)                                                       \
	do {                                                                   \
		if (!(cond)) {                                                  \
			fprintf(stderr, "FAIL: ");                             \
			fprintf(stderr, __VA_ARGS__);                          \
			fprintf(stderr, "\n");                                 \
			failures++;                                            \
		}                                                              \
	} while (0)

/* Table-backed stub standing in for t2smc_read_fan(). */
struct stub {
	bool present[8][5];
	unsigned int v[8][5];
};

static int stub_read(void *ctx, int fan_idx, int option, unsigned int *speed)
{
	struct stub *s = ctx;

	if (fan_idx < 0 || fan_idx >= 8 || option < 0 || option >= 5)
		return -EINVAL;
	if (!s->present[fan_idx][option])
		return -EIO;
	*speed = s->v[fan_idx][option];
	return 0;
}

static void test_fan_speed_valid(void)
{
	/* min=1000 max=6000 cur=3000 */
	CHECK(t2smc_fan_speed_valid(1000, 6000, 3000, 1000, false), "target at min");
	CHECK(t2smc_fan_speed_valid(1000, 6000, 3000, 6000, false), "target at max");
	CHECK(!t2smc_fan_speed_valid(1000, 6000, 3000, 999, false), "target below min");
	CHECK(!t2smc_fan_speed_valid(1000, 6000, 3000, 6001, false), "target above max");
	CHECK(!t2smc_fan_speed_valid(6000, 1000, 3000, 3000, false), "inverted envelope");

	/* fan_min also may not exceed the current target */
	CHECK(t2smc_fan_speed_valid(1000, 6000, 3000, 3000, true), "min == target");
	CHECK(t2smc_fan_speed_valid(1000, 6000, 3000, 2000, true), "min below target");
	CHECK(!t2smc_fan_speed_valid(1000, 6000, 3000, 3001, true), "min above target");
	CHECK(!t2smc_fan_speed_valid(1000, 6000, 3000, 1000 - 1, true), "min below floor");
}

static void test_charge_limit_valid(void)
{
	CHECK(!t2smc_charge_limit_valid(false, false, 101), ">100 rejected");
	CHECK(t2smc_charge_limit_valid(false, false, 0), "bclm-only 0");
	CHECK(t2smc_charge_limit_valid(false, false, 100), "bclm-only 100");

	CHECK(t2smc_charge_limit_valid(true, false, 0), "chls 0 (off)");
	CHECK(t2smc_charge_limit_valid(true, false, 50), "chls 50");
	CHECK(t2smc_charge_limit_valid(true, false, 99), "chls 99");
	CHECK(t2smc_charge_limit_valid(true, false, 100), "chls 100");

	CHECK(t2smc_charge_limit_valid(false, true, 80), "chwa fixed 80");
	CHECK(t2smc_charge_limit_valid(false, true, 100), "chwa off");
	CHECK(!t2smc_charge_limit_valid(false, true, 50), "chwa 50 rejected");
	CHECK(!t2smc_charge_limit_valid(false, true, 0), "chwa 0 rejected");
	CHECK(!t2smc_charge_limit_valid(false, true, 81), "chwa 81 rejected");

	/* CHLS wins when both exist (it supports the full range) */
	CHECK(t2smc_charge_limit_valid(true, true, 55), "chls+chwa 55");
}

static void test_rtc_offset_valid(void)
{
	const long long hi = (1LL << 47) - 1;
	const long long lo = -(1LL << 47);

	CHECK(t2smc_rtc_offset_valid(0), "rtc 0");
	CHECK(t2smc_rtc_offset_valid(hi), "rtc max");
	CHECK(t2smc_rtc_offset_valid(lo), "rtc min");
	CHECK(!t2smc_rtc_offset_valid(hi + 1), "rtc max+1 rejected");
	CHECK(!t2smc_rtc_offset_valid(lo - 1), "rtc min-1 rejected");
}

static void test_fan_write_check(void)
{
	struct stub s = { 0 };

	s.present[2][T2SMC_FAN_OPT_MIN] = true;
	s.present[2][T2SMC_FAN_OPT_MAX] = true;
	s.present[2][T2SMC_FAN_OPT_TARGET] = true;
	s.v[2][T2SMC_FAN_OPT_MIN] = 1000;
	s.v[2][T2SMC_FAN_OPT_MAX] = 6000;
	s.v[2][T2SMC_FAN_OPT_TARGET] = 3000;

	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 3000, false) == 0,
	      "check target in range");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 500, false) == -EINVAL,
	      "check target below min");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 7000, false) == -EINVAL,
	      "check target above max");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 3500, true) == -EINVAL,
	      "check min above current target");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 2500, true) == 0,
	      "check min within range below target");

	/* missing key: reader error must propagate, not be turned into -EINVAL */
	CHECK(t2smc_fan_write_check(stub_read, &s, 3, 3000, false) == -EIO,
	      "check reader error propagates");
}

int main(void)
{
	test_fan_speed_valid();
	test_charge_limit_valid();
	test_rtc_offset_valid();
	test_fan_write_check();

	if (failures) {
		fprintf(stderr, "t2smc range test: %d failure(s)\n", failures);
		return 1;
	}
	printf("t2smc range test: all cases passed\n");
	return 0;
}
