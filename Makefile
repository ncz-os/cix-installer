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
# SUBSTRATE ISO -- the debian-installer environment we build on top of. This
# is NOT cosmetic: build-iso-di.sh harvests the substrate's udebs (kernel
# module packages, fonts, GTK) and merges them into the image's own pool, so
# the substrate decides which d-i runs the install.
#
# It MUST match NCZ_BASE_CODENAME in release.conf, which is forky. Measured
# 2026-08-13, building the same tree both ways:
#
#   debian-testing (forky)  -> 249 udebs, 38x *-7.1.4+deb14-arm64-di
#                              unattended install reaches "Finish the installation"
#   debian-12.13.0 (bookworm) -> 279 udebs, 0x 7.1.4, 38x *-6.1.0-42-arm64-di
#                              plus ~30 stray bookworm font/GTK udebs, and the
#                              install stops at the interactive user prompt --
#                              the cmdline preseed is no longer honoured
#
# The bookworm build does not fail loudly. It writes 11.7 GB to the target and
# looks like a healthy run right up until it asks a question it should never
# have asked. Three ISOs were built that way before a control run against a
# known-good image showed the substrate was the variable.
#
# The old pin below existed because Cix's proprietary .debs were built against
# Bookworm glibc 2.36. That predates the FORKY migration; the shipped images
# have been forky-based since, and the vendor .debs come from the CIX debian13
# SDK. To build on a point release anyway, override on the command line:
#   make iso UPSTREAM_ISO=debian-12.13.0-arm64-netinst.iso
UPSTREAM_ISO  ?= debian-testing-arm64-netinst.iso
UPSTREAM_URL  := https://cdimage.debian.org/cdimage/weekly-builds/arm64/iso-cd/$(UPSTREAM_ISO)
UPSTREAM_SHA  := https://cdimage.debian.org/cdimage/weekly-builds/arm64/iso-cd/SHA256SUMS

# The weekly-builds FILENAME is stable but its CONTENT rotates: upstream
# republishes debian-testing-arm64-netinst.iso every week and drops the old
# one. Verifying only against upstream's own SHA256SUMS therefore proves the
# download was not corrupted while proving nothing about WHICH installer you
# got -- `make download` on a fresh checkout would silently pull a substrate
# nobody has tested, and the substrate decides which d-i runs the install.
#
# So pin the one that was actually validated end to end. Measured 2026-08-13:
# upstream had already moved to 69c4f9fce002... while the validated local copy
# was 07aa61fb3843..., i.e. the drift is not hypothetical.
#
# To adopt a newer substrate, do it deliberately: download it, run
# build/e2e-install-test.sh against an ISO built on it, and only then update
# this hash in the same commit as the evidence.
SUBSTRATE_SHA := 69c4f9fce00290f8068bc52e05bb158c81f3aaf36506a08d02d790a294411570

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
	@actual=$$(sha256sum $@.tmp | awk '{print $$1}'); \
	    if [ "$$actual" != "$(SUBSTRATE_SHA)" ]; then \
	        echo "[download] SUBSTRATE ROTATED"; \
	        echo "           expected (validated): $(SUBSTRATE_SHA)"; \
	        echo "           upstream now serves : $$actual"; \
	        echo "           Upstream republishes this filename weekly. Adopting the new"; \
	        echo "           installer is a deliberate act: build an ISO on it, run"; \
	        echo "           build/e2e-install-test.sh, then update SUBSTRATE_SHA."; \
	        rm -f $@.tmp; \
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
