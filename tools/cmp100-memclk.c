// SPDX-License-Identifier: GPL-2.0-only
// cmp100-memclk: volatile HBM memory-clock lever for the CMP 100-210, via NVML.
//
// Applies a memory-clock VF offset of +138, which takes HBM from the stock
// 810 MHz to 877 MHz (~+8% device bandwidth). This is a supported NVML API
// call, not a raw PLL reprogram: it is reversible, resets on power loss like
// every other lever in this project, and cannot wedge the card the way an
// out-of-sequence FBPA PLL write can. The +138 value and the 877 MHz result
// are the path validated on 10de:1d84 by:
//   - Brazzo978/CmpUnlocker-100-210  (HBM 877 profile, NVML VF offset)
//   - duggasco/CMP100-210            (810 -> 877.5 MHz, +8.4% measured)
//
// It is deliberately a tiny standalone binary with its own extern NVML
// declarations, so it builds against just libnvidia-ml.so.1 from the installed
// driver (no -dev headers package required).
//
//   cmp100-memclk apply <bdf> [offset]   set offset (default 138), verify, roll back on failure
//   cmp100-memclk reset <bdf>            set offset to 0
//   cmp100-memclk read  <bdf>            print "offset=<n> mem=<MHz>"
//
// Exit 0 on success. The caller (cmp100-unlock) treats any failure as
// non-fatal: the Tensor/PCIe unlock is independent and stays applied.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *nvmlDevice_t;
typedef int nvmlReturn_t;
#define NVML_SUCCESS 0
#define NVML_DEVICE_NAME_BUFFER_SIZE 64
#define NVML_CLOCK_MEM 2

#define HBM_OFFSET_DEFAULT 138
#define HBM_CLOCK_EXPECT 877

extern nvmlReturn_t nvmlInit_v2(void);
extern nvmlReturn_t nvmlShutdown(void);
extern const char *nvmlErrorString(nvmlReturn_t);
extern nvmlReturn_t nvmlDeviceGetHandleByPciBusId_v2(const char *, nvmlDevice_t *);
extern nvmlReturn_t nvmlDeviceGetName(nvmlDevice_t, char *, unsigned int);
extern nvmlReturn_t nvmlDeviceGetCudaComputeCapability(nvmlDevice_t, int *, int *);
extern nvmlReturn_t nvmlDeviceGetClockInfo(nvmlDevice_t, int, unsigned int *);
extern nvmlReturn_t nvmlDeviceGetMemClkVfOffset(nvmlDevice_t, int *);
extern nvmlReturn_t nvmlDeviceGetMemClkMinMaxVfOffset(nvmlDevice_t, int *, int *);
extern nvmlReturn_t nvmlDeviceSetMemClkVfOffset(nvmlDevice_t, int);

static int fail(const char *what, nvmlReturn_t r)
{
	fprintf(stderr, "cmp100-memclk: %s: %s\n", what, nvmlErrorString(r));
	nvmlShutdown();
	return 1;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: cmp100-memclk apply|reset|read <bdf> [offset]\n");
		return 2;
	}
	const char *cmd = argv[1];
	const char *bdf = argv[2];
	int want = (argc >= 4) ? atoi(argv[3]) : HBM_OFFSET_DEFAULT;

	nvmlReturn_t r = nvmlInit_v2();
	if (r != NVML_SUCCESS) {
		fprintf(stderr, "cmp100-memclk: nvmlInit: %s\n", nvmlErrorString(r));
		return 1;
	}

	nvmlDevice_t dev;
	r = nvmlDeviceGetHandleByPciBusId_v2(bdf, &dev);
	if (r != NVML_SUCCESS)
		return fail("handle for bdf", r);

	// Target gate: Volta (CUDA 7.0) and a CMP 100-210 / V100 board name. The
	// name can read as a V100 once the Tensor stage has run, so match either
	// rather than pinning the pre-unlock string; still refuse any non-Volta part.
	char name[NVML_DEVICE_NAME_BUFFER_SIZE] = {0};
	r = nvmlDeviceGetName(dev, name, sizeof name);
	if (r != NVML_SUCCESS)
		return fail("get name", r);
	int major = 0, minor = 0;
	r = nvmlDeviceGetCudaComputeCapability(dev, &major, &minor);
	if (r != NVML_SUCCESS)
		return fail("cuda capability", r);
	int name_ok = strstr(name, "CMP 100-210") != NULL || strstr(name, "V100") != NULL;
	if (!name_ok || major != 7 || minor != 0) {
		fprintf(stderr,
			"cmp100-memclk: refusing %s: need a Volta CMP 100-210 / V100 (cc 7.0), got \"%s\" cc %d.%d\n",
			bdf, name, major, minor);
		nvmlShutdown();
		return 1;
	}

	int cur = 0;
	r = nvmlDeviceGetMemClkVfOffset(dev, &cur);
	if (r != NVML_SUCCESS)
		return fail("read HBM offset", r);

	if (strcmp(cmd, "read") == 0) {
		unsigned int mem = 0;
		nvmlDeviceGetClockInfo(dev, NVML_CLOCK_MEM, &mem);
		printf("offset=%d mem=%u\n", cur, mem);
		nvmlShutdown();
		return 0;
	}

	if (strcmp(cmd, "reset") == 0)
		want = 0;
	else if (strcmp(cmd, "apply") != 0) {
		fprintf(stderr, "cmp100-memclk: unknown command: %s\n", cmd);
		nvmlShutdown();
		return 2;
	}

	// The NVML offset range reads unreliably on CMP parts, so a value outside it
	// is a note, not a refusal (the readback below is the real safety check).
	int lo = 0, hi = 0;
	if (nvmlDeviceGetMemClkMinMaxVfOffset(dev, &lo, &hi) == NVML_SUCCESS && (want < lo || want > hi))
		fprintf(stderr, "cmp100-memclk: note: offset %d outside NVML range %d..%d (unreliable on CMP)\n",
			want, lo, hi);

	r = nvmlDeviceSetMemClkVfOffset(dev, want);
	if (r != NVML_SUCCESS)
		return fail("set HBM offset", r);

	// Success is the offset taking, verified by readback. Roll back to the prior
	// value on any mismatch.
	int got = 0;
	r = nvmlDeviceGetMemClkVfOffset(dev, &got);
	if (r != NVML_SUCCESS || got != want) {
		fprintf(stderr, "cmp100-memclk: offset readback %d != requested %d; resetting to %d\n",
			got, want, cur);
		nvmlDeviceSetMemClkVfOffset(dev, cur);
		nvmlShutdown();
		return 1;
	}

	// The resulting clock is reported for confirmation only. At idle it can sit
	// below 877 until a context loads, so a low reading is a note, not a failure.
	unsigned int mem = 0;
	nvmlDeviceGetClockInfo(dev, NVML_CLOCK_MEM, &mem);
	if (strcmp(cmd, "apply") == 0 && want == HBM_OFFSET_DEFAULT && mem && mem != HBM_CLOCK_EXPECT)
		fprintf(stderr, "cmp100-memclk: note: mem clock reads %u MHz (expect %u once a context loads)\n",
			mem, HBM_CLOCK_EXPECT);
	printf("offset=%d mem=%u\n", got, mem);
	nvmlShutdown();
	return 0;
}
