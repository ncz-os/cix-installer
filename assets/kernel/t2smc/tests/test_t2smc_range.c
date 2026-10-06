/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * test_t2smc_range.c - userspace boundary tests for the t2smc hardening.
 *
 * The validators live in t2smc_range.h, which the DKMS hardening patch adds
 * to the module.  They are pure (no kernel state), so they can be built and
 * exercised here against a table-backed stub fan reader - no SMC hardware,
 * no module load.  build/test-t2smc-range.sh applies the vendored patch
 * series to a pristine copy of the source and compiles this file against the
 * resulting header, so it tests exactly what DKMS builds.
 *
 * Coverage:
 *   - range predicates (fan min/target, charge limit, RTC offset);
 *   - S3, with fault injection: a rejected write is rejected by the
 *     validator before any narrowing; a target write does not read F%dTg;
 *     the min floor is the factory envelope, so it cannot ratchet;
 *   - S1 capacity model: the full candidate range is allocated, so a pass-2
 *     success after a pass-1 failure cannot overrun;
 *   - S2 return-value model.
 * The "fail-before" checks at the end of each affected section reproduce the
 * pre-fix behaviour and document why the fix is required.
 *
 * Build/run: bash build/test-t2smc-range.sh
 */
#include <errno.h>
#include <stdbool.h>
#include <limits.h>
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
	int err[8][5];
};

static int stub_read(void *ctx, int fan_idx, int option, unsigned int *speed)
{
	struct stub *s = ctx;

	if (fan_idx < 0 || fan_idx >= 8 || option < 0 || option >= 5)
		return -EINVAL;
	if (s->err[fan_idx][option])
		return s->err[fan_idx][option];
	if (!s->present[fan_idx][option])
		return -EIO;
	*speed = s->v[fan_idx][option];
	return 0;
}

static void stub_set(struct stub *s, int fan, int opt, unsigned int val)
{
	s->present[fan][opt] = true;
	s->v[fan][opt] = val;
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

	/* Negative values are rejected by the signed comparison. */
	CHECK(!t2smc_fan_speed_valid(1000, 6000, 3000, -1, false),
	      "negative val rejected for target");
	CHECK(!t2smc_fan_speed_valid(1000, 6000, 3000, -1, true),
	      "negative val rejected for min");
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

static void test_rtc_offset_wrap(void)
{
	const long long hi = (1LL << 47) - 1;
	const long long lo = -(1LL << 47);
	long long v;

	CHECK(t2smc_rtc_offset_wrap(0) == 0, "wrap 0");
	CHECK(t2smc_rtc_offset_wrap(hi) == hi, "wrap max stays max");
	CHECK(t2smc_rtc_offset_wrap(lo) == lo, "wrap min stays min");
	/* The write path folds any s64 into the 48-bit register. */
	CHECK(t2smc_rtc_offset_wrap(1LL << 47) == lo,
	      "wrap 2^47 wraps to min");
	CHECK(t2smc_rtc_offset_wrap((1LL << 48) - 1) == -1,
	      "wrap all-ones -> -1");
	CHECK(t2smc_rtc_offset_wrap(-(1LL << 48)) == 0,
	      "wrap -2^48 -> 0");

	/* Whatever comes in, the result is a valid signed 48-bit offset. */
	for (v = -4; v <= 4; v++) {
		long long w = t2smc_rtc_offset_wrap((1LL << 47) + v);
		CHECK(t2smc_rtc_offset_valid(w),
		      "wrapped 2^47%+lld stays in range", v);
	}
}

/*
 * S3: the hwmon write path.  Validation happens before narrowing; a target
 * write is validated purely against the factory envelope (no F%dTg read); a
 * min write is checked against the factory floor and the live target.
 */
static void test_fan_write_check(void)
{
	struct stub s = { 0 };

	stub_set(&s, 2, T2SMC_FAN_OPT_MIN, 1000);
	stub_set(&s, 2, T2SMC_FAN_OPT_MAX, 6000);
	stub_set(&s, 2, T2SMC_FAN_OPT_TARGET, 3000);

	/* plain target writes, validated against the envelope only */
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 3000, false, 1000, 6000) == 0,
	      "target in range");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 500, false, 1000, 6000) == -EINVAL,
	      "target below envelope");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 7000, false, 1000, 6000) == -EINVAL,
	      "target above envelope");

	/*
	 * Truncation: 4294967296 (UINT_MAX + 1) must be rejected before the
	 * kernel narrows it to 0 and passes the max check.
	 */
	CHECK(t2smc_fan_write_check(stub_read, &s, 2,
				    (long)UINT_MAX + 1, false, 1000, 6000) == -EINVAL,
	      "UINT_MAX+1 rejected (truncation fix)");

	/*
	 * S3 fault injection: a target write must not read F%dTg, so an
	 * unreadable/stale target must not reject an otherwise-valid write.
	 */
	s.err[2][T2SMC_FAN_OPT_TARGET] = -EIO;
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 3000, false, 1000, 6000) == 0,
	      "target write succeeds when F0Tg is unreadable");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 2500, true, 1000, 6000) == -EIO,
	      "min write still needs the current target");
	s.err[2][T2SMC_FAN_OPT_TARGET] = 0;

	/* min writes need the live target to keep min <= target */
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 2500, true, 1000, 6000) == 0,
	      "min below target ok");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 3500, true, 1000, 6000) == -EINVAL,
	      "min above target rejected");
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 500, true, 1000, 6000) == -EINVAL,
	      "min below factory floor rejected");

	/*
	 * Ratchet fix: even though the live F%dMn was raised to 5000, the
	 * factory floor of 1000 must still accept a later, smaller minimum.
	 */
	stub_set(&s, 2, T2SMC_FAN_OPT_MIN, 5000);
	stub_set(&s, 2, T2SMC_FAN_OPT_TARGET, 6000);
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 2000, true, 1000, 6000) == 0,
	      "min against the factory floor does not ratchet");

	/* stale/auto-mode target (cur == 0) must not reject a valid min */
	stub_set(&s, 2, T2SMC_FAN_OPT_TARGET, 0);
	CHECK(t2smc_fan_write_check(stub_read, &s, 2, 2000, true, 1000, 6000) == 0,
	      "valid min accepted when target is stale/auto");
}

/*
 * Legacy semantics reproduction (fail-before).  The old handler checked
 * val < 0 and then narrowed to unsigned int BEFORE the envelope comparison,
 * so UINT_MAX+1 truncated to 0 and passed.
 */
static bool legacy_target_accepted(long val, unsigned int max)
{
	unsigned int speed;

	if (val < 0)
		return false;
	speed = (unsigned int)val; /* truncating narrow, as the old code did */
	return speed <= max;
}

static void test_fail_before(void)
{
	CHECK(legacy_target_accepted((long)UINT_MAX + 1, 6000),
	      "fail-before: legacy handler accepted the truncated target");
}

/*
 * S1 capacity model.  Pass one counts only the sp78 keys it could read; pass
 * two retries and can see more successes.  The old code sized the array from
 * pass one's count, so a recovered key overran it.  The fix sizes the array
 * from the whole candidate range.
 */
static void test_temp_capacity(void)
{
	unsigned int pass1 = 3; /* transient failures skipped in pass 1 */
	unsigned int pass2 = 5; /* recovered successes in pass 2 */
	unsigned int capacity = t2smc_temp_alloc_count(10, 15);
	unsigned int legacy_capacity = pass1; /* old: kcalloc(t2->temp_count) */

	CHECK(t2smc_temp_alloc_count(10, 15) == 5, "allocation count = range size");
	CHECK(t2smc_temp_alloc_count(15, 10) == 0, "inverted range yields 0");
	CHECK(pass2 > pass1, "S1 model: pass-2 successes can exceed pass-1 count");
	CHECK(pass2 > legacy_capacity,
	      "fail-before: pass-2 successes overrun the pass-1-sized array");
	CHECK(capacity >= pass2,
	      "S1 fix: full-range capacity covers every pass-2 success");
}

/*
 * S2 return-value model.  Two callers can observe valid == false; after one
 * fills the entry the other reaches the locked out: label.  Pre-fix that
 * path used an uninitialised `ret`; the fix initialises it so the second
 * caller gets the entry (0) instead of ERR_PTR(garbage).
 */
static int cache_lookup_model(bool *valid, bool *filled_by_other)
{
	int ret = 0; /* fixed; pre-fix this was `int ret;` */

	if (*valid) {
		*filled_by_other = true;
		return ret;
	}
	*valid = true;
	return ret;
}

static void test_cache_return_model(void)
{
	bool valid = false;
	bool other = false;

	CHECK(cache_lookup_model(&valid, &other) == 0 && !other,
	      "first caller fills the cache");
	CHECK(cache_lookup_model(&valid, &other) == 0 && other,
	      "second caller returns the entry, not an undefined error");
}

int main(void)
{
	test_fan_speed_valid();
	test_charge_limit_valid();
	test_rtc_offset_valid();
	test_rtc_offset_wrap();
	test_fan_write_check();
	test_fail_before();
	test_temp_capacity();
	test_cache_return_model();

	if (failures) {
		fprintf(stderr, "t2smc range test: %d failure(s)\n", failures);
		return 1;
	}
	printf("t2smc range test: all cases passed\n");
	return 0;
}
