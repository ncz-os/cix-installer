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
DEBIAN_REL    := 12
DEBIAN_POINT  := 12.7.0
UPSTREAM_ISO  := debian-$(DEBIAN_POINT)-arm64-netinst.iso
UPSTREAM_URL  := https://cdimage.debian.org/cdimage/release/$(DEBIAN_POINT)/arm64/iso-cd/$(UPSTREAM_ISO)
UPSTREAM_SHA  := https://cdimage.debian.org/cdimage/release/$(DEBIAN_POINT)/arm64/iso-cd/SHA256SUMS

DOWNLOADS     := $(ROOT)/downloads
BUILD         := $(ROOT)/build
ASSETS        := $(ROOT)/assets
PRESEED       := $(ROOT)/preseed
POST          := $(ROOT)/post-install

OUTPUT_ISO    := $(BUILD)/nclawzero-installer-cixmini-$(VERSION).iso

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
	@cd $(DOWNLOADS) && grep '$(UPSTREAM_ISO)' SHA256SUMS | sha256sum -c -
	@mv $@.tmp $@
	@echo "[download] OK"

# -----------------------------------------------------------------------
# Step 2 — build the customized ISO via the staged build script.
# -----------------------------------------------------------------------
iso: $(OUTPUT_ISO)

$(OUTPUT_ISO): $(DOWNLOADS)/$(UPSTREAM_ISO) \
               $(PRESEED)/preseed.cfg \
               $(wildcard $(POST)/*.sh) \
               $(wildcard $(ASSETS)/agent-stack/*) \
               $(wildcard $(ASSETS)/branding/*)
	@echo "[iso] building $@ from $(DOWNLOADS)/$(UPSTREAM_ISO)"
	@bash $(ROOT)/build/build-iso.sh \
	    --upstream $(DOWNLOADS)/$(UPSTREAM_ISO) \
	    --root $(ROOT) \
	    --version $(VERSION) \
	    --output $@
	@echo "[iso] DONE — $@ ($(shell du -h $@ 2>/dev/null | cut -f1))"

verify: $(OUTPUT_ISO)
	@cd $(BUILD) && sha256sum nclawzero-installer-cixmini-$(VERSION).iso \
	    | tee nclawzero-installer-cixmini-$(VERSION).iso.sha256

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
	rm -rf $(BUILD)/iso-staging $(BUILD)/*.iso $(BUILD)/*.sha256

distclean: clean
	rm -rf $(DOWNLOADS)
