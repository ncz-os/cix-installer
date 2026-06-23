# cix-installer Makefile — produces a customized Debian Installer ISO
# for the nclawzero distro on Cix Sky1 / cixmini.
#
# Targets:
#   make download   — fetch upstream Debian netinst-arm64 ISO
#   make iso        — build the cix-installer ISO (default target)
#   make verify     — sha256-check upstream ISO + final
#   make clean      — wipe build/
#   make distclean  — wipe build/ + downloads/
#   make qemu       — boot the built ISO in qemu-aarch64 + UEFI for testing

ROOT          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION       := $(shell date -u +%Y.%m.%d)
MODE          ?= full
VARIANT       ?= desktop
DEBIAN_REL    := 12
DEBIAN_POINT  := 12.13.0
UPSTREAM_ISO  := debian-$(DEBIAN_POINT)-arm64-netinst.iso
# Bookworm has been moved to the archive after Trixie became current.
# Pin to 12.13.0 (the last Bookworm point release at time of this commit)
# because Cix's proprietary .debs were built against Bookworm; mixing
# their bookworm-glibc-2.36 binaries with Trixie's glibc-2.41 risks
# subtle ABI breakage we don't want to debug.
UPSTREAM_URL  := https://cdimage.debian.org/cdimage/archive/$(DEBIAN_POINT)/arm64/iso-cd/$(UPSTREAM_ISO)
UPSTREAM_SHA  := https://cdimage.debian.org/cdimage/archive/$(DEBIAN_POINT)/arm64/iso-cd/SHA256SUMS

DOWNLOADS     := $(ROOT)/downloads
BUILD         := $(ROOT)/build
ASSETS        := $(ROOT)/assets
PRESEED       := $(ROOT)/preseed
POST          := $(ROOT)/post-install

MODE_SUFFIX   := $(if $(filter full,$(MODE)),,-$(MODE))
OUTPUT_ISO    := $(BUILD)/nclawzero-installer-cixmini-$(VERSION)$(MODE_SUFFIX).iso

.PHONY: all download iso verify clean distclean qemu help

all: iso

help:
	@grep -E '^# (Targets|  make )' $(MAKEFILE_LIST) | sed 's/^# //'

# -----------------------------------------------------------------------
# Step 1 — fetch upstream Debian Installer ISO
# -----------------------------------------------------------------------
download: $(DOWNLOADS)/$(UPSTREAM_ISO)

$(DOWNLOADS)/$(UPSTREAM_ISO):
	@echo "[download] $(UPSTREAM_URL)"
	@mkdir -p $(DOWNLOADS)
	@curl -fL -o $@.tmp $(UPSTREAM_URL)
	@curl -fL -o $(DOWNLOADS)/SHA256SUMS $(UPSTREAM_SHA)
	@expected=$$(grep '$(UPSTREAM_ISO)' $(DOWNLOADS)/SHA256SUMS | awk '{print $$1}'); \
	    actual=$$(sha256sum $@.tmp | awk '{print $$1}'); \
	    if [ "$$expected" != "$$actual" ]; then \
	        echo "[download] SHA256 MISMATCH: expected=$$expected actual=$$actual"; \
	        exit 1; \
	    fi
	@mv $@.tmp $@
	@echo "[download] OK ($$(du -h $@ 2>/dev/null | cut -f1))"

# -----------------------------------------------------------------------
# Step 2 — build the customized ISO via the staged build script.
# -----------------------------------------------------------------------
iso: $(OUTPUT_ISO)

$(OUTPUT_ISO): $(DOWNLOADS)/$(UPSTREAM_ISO) \
	               $(ROOT)/build/build-iso-di.sh \
	               $(PRESEED)/preseed-ubuntu.cfg \
	               $(PRESEED)/late.sh \
	               $(PRESEED)/extract-rootfs.sh \
	               $(PRESEED)/sshd-watcher.sh \
	               $(wildcard $(POST)/*.sh) \
	               $(wildcard $(ASSETS)/agent-stack/*) \
	               $(wildcard $(ASSETS)/branding/*) \
	               $(wildcard $(ASSETS)/kernel/*/*) \
	               $(wildcard $(ASSETS)/rootfs/*) \
	               $(wildcard $(ASSETS)/sky1-firmware/*)
	@echo "[iso] building $@ from $(DOWNLOADS)/$(UPSTREAM_ISO)"
	@bash $(ROOT)/build/build-iso-di.sh \
	    --bookworm-iso $(DOWNLOADS)/$(UPSTREAM_ISO) \
	    --root $(ROOT) \
	    --version $(VERSION) \
	    --output $@ \
	    --mode $(MODE) \
	    --variant $(VARIANT)
	@echo "[iso] DONE — $@ ($$(du -h $@ 2>/dev/null | cut -f1))"

verify: $(OUTPUT_ISO)
	@sha256sum $(OUTPUT_ISO) | tee $(OUTPUT_ISO).sha256

# -----------------------------------------------------------------------
# Step 3 — boot test in qemu-aarch64 with edk2 UEFI firmware (faster
# iteration than hardware). Requires a virtual disk to install onto.
# -----------------------------------------------------------------------
qemu: $(OUTPUT_ISO)
	@bash $(ROOT)/build/qemu-test.sh $(OUTPUT_ISO)

# -----------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------
clean:
	rm -rf $(BUILD)/iso-staging $(BUILD)/iso-staging-di $(BUILD)/*.iso $(BUILD)/*.sha256

distclean: clean
	rm -rf $(DOWNLOADS)
