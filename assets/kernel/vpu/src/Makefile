# SPDX-License-Identifier: GPL-2.0

MODULE_NAME := amvx
SRC_DIR := .
EXTRA_CFLAGS += -I$(PWD)/driver -I$(PWD)/driver/if -I$(PWD)/driver/dev -I$(PWD)/driver/if/v4l2 -I$(PWD)/driver/external
ccflags-y := -I$(src)/driver -I$(src)/driver/if -I$(src)/driver/dev -I$(src)/driver/if/v4l2 -I$(src)/driver/external

# Add objects for if module.
if-y := driver/if/mvx_if.o \
	driver/if/mvx_buffer.o \
	driver/if/mvx_firmware_cache.o \
	driver/if/mvx_firmware.o \
	driver/if/mvx_firmware_v2.o \
	driver/if/mvx_firmware_v3.o \
	driver/if/mvx_mmu.o \
	driver/if/mvx_secure.o \
	driver/if/mvx_session.o

# Add external interface.
if-y += driver/if/v4l2/mvx_ext_v4l2.o \
	driver/if/v4l2/mvx_v4l2_buffer.o \
	driver/if/v4l2/mvx_v4l2_session.o \
	driver/if/v4l2/mvx_v4l2_vidioc.o \
	driver/if/v4l2/mvx_v4l2_fops.o \
	driver/if/v4l2/mvx_v4l2_ctrls.o

# Add objects for dev module.
dev-y := driver/dev/mvx_dev.o \
	 driver/dev/mvx_hwreg.o \
	 driver/dev/mvx_hwreg_v500.o \
	 driver/dev/mvx_hwreg_v550.o \
	 driver/dev/mvx_hwreg_v61.o \
	 driver/dev/mvx_hwreg_v52_v76.o \
	 driver/dev/mvx_lsid.o \
	 driver/dev/mvx_scheduler.o \
	 driver/mvx_pm_runtime.o

ifneq ($(CONFIG_PLAT_DSM_SYSEVENT),)
dev-y += driver/dev/mvx_dsm.o
endif

OBJS := driver/mvx_driver.o \
	  driver/mvx_seq.o \
	  driver/mvx_log.o \
	  driver/mvx_log_group.o \
	  $(if-y) $(dev-y)

ifneq ($(KERNELRELEASE),)
	obj-m := $(MODULE_NAME).o
	$(MODULE_NAME)-objs :=  $(OBJS)
else
	COMPASS_DRV_BTENVAR_KPATH ?= /lib/modules/`uname -r`/build
	PWD :=$(shell pwd)

all:
	$(MAKE) -C $(COMPASS_DRV_BTENVAR_KPATH) M=$(PWD) modules
clean:
	$(MAKE) -C $(COMPASS_DRV_BTENVAR_KPATH) M=$(PWD) clean
endif
