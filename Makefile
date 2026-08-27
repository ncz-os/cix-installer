# cix-installer Makefile — produces a customized Debian Installer ISO
# for the nclawzero distro on Cix Sky1 / cixmini.
#
# Targets:
#   make download         — fetch upstream Debian netinst-arm64 ISO
#   make iso              — build the cix-installer ISO (default target; fast for dev iteration)
#   make iso-verified     — make iso, then run build/kvm-install-gate.sh against the result.
#                           This is the "safe to ship to hardware" path: the gate installs the
#                           ISO in KVM, boots what it installed, and asserts NCZ-ROOTMODE=755.
#                           The plain `iso` target stays fast for iteration; anything intended
#                           for real hardware should go through `iso-verified`.
#   make verify           — sha256-check upstream ISO + final
#   make clean            — wipe build/
#   make distclean        — wipe build/ + downloads/
#   make qemu             — boot the built ISO in qemu-aarch64 + UEFI for testing
#   make secretscan       — scan built artifact for credentials
#   make npu-ssdt-check   — verify NPU SSDT CPIO is present + well-formed
#   make npu-ssdt-selftest — self-test the npu-ssdt-gate.sh (5 isolated cases)

ROOT          := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VERSION       := $(shell date -u +%Y.%m.%d)
MODE          ?= full
VARIANT       ?= desktop

# LATEST_SINGULARITY_DEB / desktop-hotfix.squashfs -- 2026-08-27. The ISO
# target used to have NO dependency link to assets/squashfs/desktop-hotfix
# .squashfs or assets/cix-debs/*.deb at all: that squashfs layer was staged
# by a completely separate, unlinked script (build/build-squashfs-layers.sh)
# that nothing forced anyone to re-run. Result, confirmed the hard way: a
# real ISO build shipped a desktop-hotfix.squashfs (and therefore Singularity
# Desktop) from HOURS before the actual latest vendored .deb, silently,
# because the stale file already existed on disk and make had no reason to
# touch it. This is the same "silent skip is how the payload went stale"
# failure class this repo has hit more than once -- fixed here the same way,
# by making it a real Make dependency instead of a step someone has to
# remember.
LATEST_SINGULARITY_DEB := $(shell ls -1 $(ROOT)/assets/cix-debs/ncz-singularity-desktop_*.deb 2>/dev/null | sort -V | tail -1)
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
# Substrate rotated 2026-08-21: upstream serves
# 4aae4d12acc0c71b7eaf2d03deae48098f84596e6806d3cf78ada53ba0c649a0
# (last-modified 2026-08-17, +4 days since the prior pin 69c4f9fce0...).
# Adopted in this commit because the operator requested a real ISO; the prior
# pin was preventing `make download` outright. Validation: install-gate
# (build/kvm-install-gate.sh) PASS against the ISO built on this substrate —
# see docs/ISO-REBAKE-TYDEUS-2026-08-21.md §"Verification".
SUBSTRATE_SHA := 4aae4d12acc0c71b7eaf2d03deae48098f84596e6806d3cf78ada53ba0c649a0

DOWNLOADS     := $(ROOT)/downloads
BUILD         := $(ROOT)/build
ASSETS        := $(ROOT)/assets
PRESEED       := $(ROOT)/preseed
POST          := $(ROOT)/post-install

MODE_SUFFIX   := $(if $(filter full,$(MODE)),,-$(MODE))
OUTPUT_ISO    := $(BUILD)/nclawzero-installer-cixmini-$(VERSION)$(MODE_SUFFIX).iso

.PHONY: all download iso iso-verified verify clean distclean qemu help secretscan npu-ssdt-check kernel-debs vendor-mirror offline-mirror

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

kernel-debs:
	@if ! ls $(BUILD)/kernel-debs/*.deb >/dev/null 2>&1; then \
	    echo "[kernel-debs] no debs present; building local kernel packages"; \
	    bash $(ROOT)/build/build-kernel-debs.sh; \
	else \
	    echo "[kernel-debs] using existing debs from $(BUILD)/kernel-debs"; \
	    find $(BUILD)/kernel-debs -maxdepth 1 -name '*.deb' -printf '  %f\n' | sort; \
	fi

# SINTY_DEBS_ARG / sinty-out-sync -- 2026-08-27. verify-local-package-
# versions.sh treats EVERY .deb in a --debs-dir as an expected member of
# the mirror it is checking -- it has no per-package filtering. Pointing
# --debs-dir straight at assets/cix-debs/ (tried first, reverted) makes the
# check FAIL PERMANENTLY: that directory also holds ~30 dpkg-i-direct-only
# packages (cix-vaapi, cix-mesa, cix-gpu-umd, ...) that are staged onto the
# ISO's /cixmini/assets/cix-debs/ via 25-cix-proprietary.sh and were never
# meant to exist in the apt-mirror pool at all, so they always show
# "missing" regardless of anything real changing.
#
# build/sinty-out/ was always the RIGHT directory to point at -- narrowly
# scoped, only ever meant to hold the current singularity-desktop .deb --
# it was just never actually populated by anything (build-singularity-deb.sh
# defaults its OUT there, but every session's real convention landed the
# .deb in assets/cix-debs/ instead, same root cause 9a6c964 and 4251a57
# fixed elsewhere). Sync it from the one real canonical source instead of
# changing what it means.
sinty-out-sync:
	@mkdir -p $(BUILD)/sinty-out
	@rm -f $(BUILD)/sinty-out/ncz-singularity-desktop_*.deb
	@latest="$$(ls -1 $(ROOT)/assets/cix-debs/ncz-singularity-desktop_*.deb 2>/dev/null | sort -V | tail -1)"; \
	    if [ -n "$$latest" ]; then \
	        cp "$$latest" $(BUILD)/sinty-out/; \
	        echo "[sinty-out-sync] $$(basename "$$latest")"; \
	    fi

# Unconditional, not wildcard-gated: $(wildcard ...) evaluates at Makefile
# PARSE time, before sinty-out-sync's recipe has actually run, so on a
# fresh/empty build/sinty-out/ the wildcard check would resolve empty and
# silently skip the check all over again -- the exact bug being fixed here.
# Safe unconditionally: verify-local-package-versions.sh already treats an
# empty --debs-dir as "nothing expected from here" (compgen -G ... ||
# continue), not an error.
SINTY_DEBS_ARG := --debs-dir $(BUILD)/sinty-out

vendor-mirror: kernel-debs sinty-out-sync
	@echo "[vendor-mirror] publishing local debs and regenerating vendor index"
	@bash $(ROOT)/build/build-vendor-mirror.sh
	@bash $(ROOT)/build/verify-local-package-versions.sh \
	    --pool $(BUILD)/forky-vendor-mirror/pool \
	    --label forky-vendor-mirror \
	    $(SINTY_DEBS_ARG)

offline-mirror: vendor-mirror
	@if [ ! -d $(BUILD)/forky-mirror/pool ] || \
	    ! bash $(ROOT)/build/verify-local-package-versions.sh \
	        --pool $(BUILD)/forky-mirror/pool \
	        --label forky-mirror \
	        $(SINTY_DEBS_ARG) >/dev/null 2>&1 || \
	    ! bash $(ROOT)/build/verify-offline-mirror-seeds.sh \
	        --mirror $(BUILD)/forky-mirror \
	        --label forky-mirror >/dev/null 2>&1; then \
	    echo "[offline-mirror] missing or stale; rebuilding from refreshed vendor mirror"; \
	    rm -rf $(BUILD)/forky-mirror; \
	    bash $(ROOT)/build/build-forky-mirror.sh; \
	else \
	    echo "[offline-mirror] existing mirror matches local package pins and manifest seeds"; \
	fi


$(ROOT)/assets/python311/uv:
	@echo "[python311-assets] provisioning relocatable CPython 3.11 + uv (NPU venv, offline-first)"
	@bash $(ROOT)/build/build-python311-assets.sh
$(ROOT)/assets/squashfs/desktop-hotfix.squashfs: $(LATEST_SINGULARITY_DEB)
	@echo "[hotfix-squashfs] rebuilding from $(LATEST_SINGULARITY_DEB)"
	@bash $(ROOT)/build/build-squashfs-layers.sh hotfix
	@echo "[hotfix-squashfs] pruning superseded ncz-singularity-desktop debs from assets/cix-debs/"
	@cd $(ROOT)/assets/cix-debs && ls -1 ncz-singularity-desktop_*.deb 2>/dev/null | sort -V | head -n -1 | xargs -r rm -fv

$(OUTPUT_ISO): $(DOWNLOADS)/$(UPSTREAM_ISO) \
	               offline-mirror \
	               $(ROOT)/assets/squashfs/desktop-hotfix.squashfs \
	               $(ROOT)/assets/python311/uv \
	               $(ROOT)/build/build-iso-di.sh \
	               $(PRESEED)/preseed.cfg \
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
	@echo "[iso] scanning the built artifact for credentials"
	@bash $(ROOT)/build/secret-scan-gate.sh $@
	@echo "[iso] DONE — $@ ($$(du -h $@ 2>/dev/null | cut -f1))"

secretscan:
	@bash $(ROOT)/build/secret-scan-gate.sh

# Fast NPU SSDT asset check — same gate `make iso` will run in full-mode
# preflight. Useful as a build-host validation step before kicking off a
# full ISO build (catches the silent-skip regression that shipped ISOs
# without the MS-R1 NPU _HID override). Pass `regen=1` to allow the gate
# to auto-rebuild the CPIO from the committed .asl if it is missing.
npu-ssdt-check:
	@if [ "$(regen)" = "1" ]; then \
	    echo "[npu-ssdt-check] regen=1 -> gate may auto-rebuild missing CPIO"; \
	    bash $(ROOT)/build/npu-ssdt-gate.sh --regen; \
	else \
	    bash $(ROOT)/build/npu-ssdt-gate.sh; \
	fi

# Self-test the NPU SSDT gate (runs positive + 4 negative cases in an
# isolated temp tree, never touches assets/npu/). Requires iasl.
npu-ssdt-selftest:
	@bash $(ROOT)/build/npu-ssdt-gate.sh --self-test

verify: $(OUTPUT_ISO)
	@sha256sum $(OUTPUT_ISO) | tee $(OUTPUT_ISO).sha256

# iso-verified: build the ISO and then run kvm-install-gate.sh against it. The
# gate installs the just-built ISO in KVM (auto-falls back to TCG under qemu on
# non-aarch64 hosts like TYDEUS), boots what it installed, and asserts the
# NCZ-ROOTMODE=755 marker from the boot serial. ANYTHING INTENDED FOR REAL
# HARDWARE SHOULD GO THROUGH THIS TARGET, NOT THE PLAIN `iso` -- the 2026-08-26
# 0700-root incident is exactly the class of regression this gate catches at
# build time instead of on hardware. `iso` stays fast for dev iteration. The
# gate's workdir defaults to /home/mini/.../kvm-install (its built-in default);
# override with KVM_INSTALL_WORKDIR=/path on the make command line to relocate
# (the gate creates it if missing). See build/kvm-install-gate.sh for full
# timeout/accel/mem knobs.
iso-verified: $(OUTPUT_ISO)
	@echo "[iso-verified] running kvm-install-gate.sh against $(OUTPUT_ISO)"
	@if [ ! -x "$(ROOT)/build/kvm-install-gate.sh" ]; then \
	    echo "[iso-verified] FATAL: build/kvm-install-gate.sh missing or not executable" >&2; \
	    exit 1; \
	fi
	@if [ ! -f "$(OUTPUT_ISO)" ]; then \
	    echo "[iso-verified] FATAL: $(OUTPUT_ISO) not present after make iso" >&2; \
	    exit 1; \
	fi
	@mkdir -p "$${KVM_INSTALL_WORKDIR:-$(ROOT)/build/kvm-install}"
	@WORK="$${KVM_INSTALL_WORKDIR:-$(ROOT)/build/kvm-install}"; \
	if ! bash "$(ROOT)/build/kvm-install-gate.sh" "$(OUTPUT_ISO)" "$$WORK"; then \
	    rc=$$?; \
	    echo "" >&2; \
	    echo "[iso-verified] GATE FAILED (rc=$$rc): $(OUTPUT_ISO) is NOT safe to ship to hardware." >&2; \
	    echo "[iso-verified] See $$WORK/install.log and $$WORK/boot.log for the failure evidence." >&2; \
	    exit $$rc; \
	fi
	@echo "[iso-verified] PASS: $(OUTPUT_ISO) is safe to ship to hardware"

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
