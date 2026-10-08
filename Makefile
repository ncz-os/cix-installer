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
ARCH          ?= $(shell dpkg --print-architecture 2>/dev/null || uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
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
# Substrate = the NETINST, not netboot/mini.iso. The netinst carries its own
# /pool (285 udebs) and /dists/<codename>/Release, so anna and choose-mirror
# are satisfied from the medium. mini.iso carries neither, which makes the
# live archive a hard boot-time dependency and puts the install on the
# DHCP/DNS settling race (see build/iso/import-substrate.py, which supports
# BOTH layouts). Forky is testing and rotates under us; an on-media closure
# is the only stable target until it releases.
UPSTREAM_ISO  ?= debian-testing-$(ARCH)-netinst.iso
UPSTREAM_URL  := https://cdimage.debian.org/cdimage/weekly-builds/$(ARCH)/iso-cd/$(UPSTREAM_ISO)
UPSTREAM_SHA  := https://cdimage.debian.org/cdimage/weekly-builds/$(ARCH)/iso-cd/SHA256SUMS
UPSTREAM_SHA_NAME := $(UPSTREAM_ISO)

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
# Substrate rotated again 2026-09-25. The replacement below passed the native
# arm64 build/kvm-install-gate.sh install-and-detached-boot gate on ULTRA.
# Validated substrate pins. arm64 is pinned to the Debian weekly netinst with
# installer build 20260921 (sha256 below): the substrate every arm64 image that
# passed the KVM install gate was built on, including ncz-os-arm64-20260929-18e8a14.
# Debian republishes the filename weekly and drops the old build, so a fresh
# worktree (empty downloads/) used to float silently to whatever was current.
# The pinned file is kept on ARGONAS (SUBSTRATE_CACHE_DIRS, one directory per
# host spelling) and the download rule copies it from there and verifies the
# sha256; if it cannot, it FAILS rather than floating.
# Adopting a newer installer is a deliberate act: build on it, run the KVM gate,
# store the ISO in the cache directory as <name>-<yyyymmdd>-<sha8>.iso, then
# change the pin below. Override on the command line for an experiment:
#   make image SUBSTRATE_SHA=<sha256-of-the-new-iso>
#
# amd64 pin added 2026-10-06 (KNOWN-ISSUES #11). The hash is the
# debian-testing-amd64-netinst.iso that the r199 KVM gate actually validated,
# re-measured on the shared cache rather than copied from the backlog:
#   /mnt/argonas/datapool/projects/ncz-os-assets/substrate/
#     debian-testing-amd64-netinst-20260926-c517f8ff.iso
# Three independent checks agree on c517f8ff...: the sha256 of that file, the
# 8-char tag in its own cached filename, and the value already recorded in
# KNOWN-ISSUES-r199.md. Its Packages snapshot stamp is 20260921, matching the
# forky mirror the r199 amd64 gate consumed (the other ISO on PROTEUS is the
# older 20260914 weekly). NOTE: the substrate ISO does NOT float weekly for a
# pinned arch any more -- the download rule fetches the pinned sha and fails if
# the cache cannot supply it.
ifeq ($(ARCH),arm64)
SUBSTRATE_SHA ?= bcdea12698a4c643fbbc68c69fb8be96a3f292bdfa1b5c41c8fdaeaae6944f67
else ifeq ($(ARCH),amd64)
SUBSTRATE_SHA ?= c517f8fffadbaca4d3b07a4268591f4250fd35034988d3113623dc340ed635db
endif
SUBSTRATE_SHA ?=
SUBSTRATE_CACHE_DIRS ?= /mnt/argonas-projects/ncz-os-assets/substrate \
                        /nfs-shared/ncz-os-assets/substrate \
                        /mnt/argonas/datapool/projects/ncz-os-assets/substrate

DOWNLOADS     := $(ROOT)/downloads
BUILD         := $(ROOT)/build
ASSETS        := $(ROOT)/assets
PRESEED       := $(ROOT)/preseed
POST          := $(ROOT)/post-install

MODE_SUFFIX   := $(if $(filter full,$(MODE)),,-$(MODE))
BUILD_DATE    := $(shell date -u +%Y%m%d)
# BUILD_SHA used to silently fall back to empty when git rev-parse failed
# (dubious-ownership inside the rootful imagebuild container, missing git,
# shallow clone with --depth=0, etc.), producing artifacts named
# `ncz-os-<arch>-<date>-.img` -- the 2026-09-28 arm64 incident. Directive 10
# requires the commit SHA be stamped into the artifact; an unstamped one is
# not a real artifact. Fail LOUD here instead, and let the operator either
# fix git ownership (`git config --global --add safe.directory '*'`) or pass
# BUILD_SHA explicitly on the make command line. The check is a real shell
# exit, not a $(if) test, so `make` itself stops with a clear diagnostic.
BUILD_SHA     := $(shell git rev-parse --short HEAD 2>/dev/null)
ifneq ($(filter image image-verified all,$(or $(MAKECMDGOALS),all)),)
ifeq ($(strip $(BUILD_SHA)),)
$(error BUILD_SHA is empty: git rev-parse failed (dubious-ownership, missing git, or detached HEAD?). Run `git config --global --add safe.directory '*'` and retry, or set BUILD_SHA=<sha> on the make command line. An unstamped `ncz-os-<arch>-<date>-.img` is not a valid artifact.)
endif
endif
OUTPUT_IMAGE  := $(BUILD)/ncz-os-$(ARCH)-$(BUILD_DATE)-$(BUILD_SHA)$(MODE_SUFFIX).img

.PHONY: parity all download image image-verified iso iso-verified verify clean distclean qemu help secretscan npu-ssdt-check kernel-debs usb-recovery-deb libdrm-debs apt-policy-deb vendor-mirror desktop-mirror offline-mirror lint-platform gen-hooks-lists test-platform test-cygnus-branding test-boot-speed test-timesync-retry test-boot-sequence ssplugin-stage

all: image

help:
	@grep -E '^# (Targets|  make )' $(MAKEFILE_LIST) | sed 's/^# //'

# -----------------------------------------------------------------------
# Step 1 — fetch upstream Debian Installer ISO
# -----------------------------------------------------------------------
download: $(DOWNLOADS)/$(UPSTREAM_ISO)

$(DOWNLOADS)/$(UPSTREAM_ISO):
	@mkdir -p $(DOWNLOADS)
	@if [ -z "$(SUBSTRATE_SHA)" ]; then \
	    echo "[download] WARNING: no substrate pin for $(ARCH); this floats to whatever Debian serves today (set SUBSTRATE_SHA)"; \
	fi
	@if [ -n "$(SUBSTRATE_SHA)" ]; then \
	    short=$$(printf '%s' "$(SUBSTRATE_SHA)" | cut -c1-8); \
	    for d in $(SUBSTRATE_CACHE_DIRS); do \
	        for f in $$d/*-$$short.iso; do \
	            [ -f "$$f" ] || continue; \
	            actual=$$(sha256sum "$$f" | awk '{print $$1}'); \
	            if [ "$$actual" = "$(SUBSTRATE_SHA)" ]; then \
	                echo "[download] pinned substrate $(SUBSTRATE_SHA) from $$f"; \
	                if cp "$$f" $@.tmp && mv $@.tmp $@; then break 2; fi; \
	                echo "[download] WARNING: copying the pinned substrate from $$f failed; will not accept anything but the pin"; \
	                rm -f $@.tmp; \
	            fi; \
	            echo "[download] WARNING: $$f does not match the pin (sha256 $$actual); ignoring it"; \
	        done; \
	    done; \
	fi
	@if [ ! -f $@ ]; then \
	    echo "[download] $(UPSTREAM_URL)"; \
	    curl -fL -o $@.tmp $(UPSTREAM_URL) && \
	    curl -fL -o $(DOWNLOADS)/SHA256SUMS $(UPSTREAM_SHA) || { rm -f $@.tmp; exit 1; }; \
	    expected=$$(grep '$(UPSTREAM_SHA_NAME)$$' $(DOWNLOADS)/SHA256SUMS | awk '{print $$1}'); \
	    actual=$$(sha256sum $@.tmp | awk '{print $$1}'); \
	    if [ "$$expected" != "$$actual" ]; then \
	        echo "[download] SHA256 MISMATCH: expected=$$expected actual=$$actual"; \
	        rm -f $@.tmp; exit 1; \
	    fi; \
	    if [ -n "$(SUBSTRATE_SHA)" ] && [ "$$actual" != "$(SUBSTRATE_SHA)" ]; then \
	        echo "[download] SUBSTRATE ROTATED"; \
	        echo "           pinned (validated)  : $(SUBSTRATE_SHA)"; \
	        echo "           upstream now serves : $$actual"; \
	        echo "           and the pinned ISO was not found in: $(SUBSTRATE_CACHE_DIRS)"; \
	        echo "           Upstream republishes this filename weekly. Restore the pinned ISO"; \
	        echo "           into one of those directories (name it <anything>-$$(printf '%s' $(SUBSTRATE_SHA) | cut -c1-8).iso),"; \
	        echo "           or adopt the new installer deliberately: build an image on it, run"; \
	        echo "           make image-verified (build/kvm-install-gate-gpt.sh), then update the pin."; \
	        rm -f $@.tmp; exit 1; \
	    fi; \
	    mv $@.tmp $@; \
	fi
	@echo "[download] OK ($$(du -h $@ 2>/dev/null | cut -f1))"

# -----------------------------------------------------------------------
# Step 2 — build the customized ISO via the staged build script.
# -----------------------------------------------------------------------
image: $(OUTPUT_IMAGE)

# There is no ISO target. The deliverable is the raw GPT disk image above;
# the retired `iso` / `iso-verified` names fail loudly instead of aliasing.
iso iso-verified:
	@echo "make $@: there is no ISO build. The deliverable is a raw GPT .img: use 'make image' or 'make image-verified'." >&2; exit 2

# Bug 1 fix (2026-09-28, arm64/Sky1 freshness). The previous shape -- "reuse
# whatever .debs already sit in $(BUILD)/kernel-debs/" -- silently shipped a
# stale kernel when a previous build run had been started against a newer
# assets/kernel/mainline symlink target, the new run switched the symlink back
# to an older one (the staged dated dir pool is rotated independently of
# any in-flight ISO build), and the existing build/kernel-debs/ directory
# still held the newer .debs. The vendor mirror therefore published the
# newer kernel while KVER said the older one, and post-install/10-our-
# kernel.sh then aborted the whole base layer:
#     WARN: edge kernel unavailable -- Phase 1 cannot continue.
#     ERROR: no kernel installed (edge failed) -- Phase 1 cannot continue.
#     [sqfs] ERROR: required base hook 10-our-kernel failed
# Exactly the class of staleness already gated on the amd64 side by
# build/preflight-freshness-gate.sh -- mirror its shape here: compare the
# version carried by the existing .debs (extracted from the .deb
# filename -- the same key the post-install hook resolves) against
# assets/kernel/mainline/KVER (following the symlink, since mainline IS a
# symlink), and rebuild -- rotating the stale set aside, never deleting
# it, the same convention build-squashfs-layers.sh uses for stale
# base.squashfs layers -- when they disagree. The freshness comparison
# is purely a Makefile-side invariant: build-kernel-debs.sh itself
# (resolve_kver) already hard-fails on a stale sidecar KVER inside its
# own scope, and we want the same guarantee at the wrapper level so the
# wrapper never silently publishes a stale set.
#
# arm64-only: this target is the Sky1 kernel package target. The amd64
# kernel line(s) live under assets/kernel/amd64-{stable,edge} and are
# staged via build/stage-amd64-kernel.sh, never via this target. $(ARCH)
# is the build host's dpkg architecture, not the target ISO's --
# NCZ_TARGET_ARCH on the build invocation distinguishes the two; the
# existing arm64-only `using existing debs` path is preserved exactly
# for ARCH=arm64 hosts. For ARCH!=arm64 (i.e. amd64 build hosts, the
# usual case), this target is a no-op as before.
#
# 2026-09-29: the freshness key is now the SHIPPING pointer
# assets/kernel/mainline (was assets/kernel/edge), and reuse additionally
# requires build/check-kernel-deb-pin.sh to pass. Before this the parser
# compared "<KVER>+r<N>" (the filename version) with bare KVER, which never
# matched, so every run rebuilt; fixing only the parser would have made a
# stale +r258 build of 7.2.8 reusable while the pointer names r277. The pin
# checks KVER, the revision floor, and one version per package.
#
# The four branches below, in order:
#   (a) arch != arm64: skip (no-op on amd64 build hosts).
#   (b) build/kernel-debs/*.deb absent: build from scratch.
#   (c) assets/kernel/mainline/KVER absent: mainline symlink is dangling or the
#       staged pool is empty -- build-kernel-debs.sh's resolve_kver will
#       refuse to package against a stale sidecar, so we refuse too at
#       the wrapper level rather than silently publishing a set whose
#       KVER we cannot verify. Rotate any existing set aside (never
#       delete: the operator may need the .deb to confirm what was
#       actually shipped before the freshness mismatch was caught) and
#       rebuild.
#   (d) KVER present: compare what the existing linux-image-cixmini
#       _arm64.deb carries (parsed from the filename, the same key the
#       post-install hook resolves) against assets/kernel/mainline/KVER.
#       If they match, REUSE (no rebuild). If they disagree, ROTATE
#       THE STALE SET ASIDE and rebuild -- same shape as
#       build-squashfs-layers.sh's base.squashfs staleness rotation,
#       same defect class closed by 3fc79c3 for desktop-mirror and by
#       preflight-freshness-gate.sh for the kernel-staging pool on
#       amd64. Confirmed live 2026-09-28: an arm64 build run had
#       previously been started against a newer edge symlink target,
#       the symlink was rotated back to 7.2.8-sky1-ncz, the stale
#       build/kernel-debs/ still held a 7.3.0-rc5-sky1-ncz+r278 set,
#       and post-install/10-our-kernel.sh then aborted the whole base
#       layer with "no kernel installed (edge failed)" because the
#       vendor mirror had published rc5 while KVER said 7.2.8.
#
# Operator directive 2026-09-30 (the .66 incident), updated 2026-10-04: the 7.2.9
# release kernel must be the default kernel on every arch. Gate the kernel-debs target with the kernel-default
# policy verifier before doing anything else -- a misdirected
# assets/kernel/mainline symlink (the .66 root cause) silently produces
# wrong .debs here if this gate is skipped.
kernel-debs:
	@if [ ! -x "$(ROOT)/build/verify-kernel-default-policy.sh" ]; then \
	    echo "[kernel-debs] FATAL: $(ROOT)/build/verify-kernel-default-policy.sh is missing or not executable" >&2; \
	    exit 1; \
	fi
	@if ! bash $(ROOT)/build/verify-kernel-default-policy.sh --root $(ROOT) --arch arm64; then \
	    echo "[kernel-debs] FATAL: kernel default policy failed -- refusing to package" >&2; \
	    exit 1; \
	fi
	@if [ "$(ARCH)" != arm64 ]; then \
	    echo "[kernel-debs] skipping Sky1 kernel packages for $(ARCH)"; \
	elif ! ls $(BUILD)/kernel-debs/*.deb >/dev/null 2>&1; then \
	    echo "[kernel-debs] no debs present; building local kernel packages"; \
	    bash $(ROOT)/build/build-kernel-debs.sh; \
	elif [ ! -f "$(ROOT)/assets/kernel/mainline/KVER" ]; then \
	    echo "[kernel-debs] assets/kernel/mainline/KVER missing -- cannot verify freshness; rebuilding" >&2; \
	    _kdebs_ts="$$(date -u +%Y%m%d-%H%M%S)"; \
	    if mv "$(BUILD)/kernel-debs" "$(BUILD)/kernel-debs.stale-$${_kdebs_ts}" 2>/dev/null; then \
	        echo "[kernel-debs]   rotated stale set aside as $(BUILD)/kernel-debs.stale-$${_kdebs_ts}" >&2; \
	    else \
	        echo "[kernel-debs]   WARN: could not rotate stale set aside ($(BUILD)/kernel-debs exists but KVER is gone)" >&2; \
	    fi; \
	    bash $(ROOT)/build/build-kernel-debs.sh; \
	else \
	    _want_kver="$$(tr -d '[:space:]' < "$(ROOT)/assets/kernel/mainline/KVER")"; \
	    _have_kver="$$(ls -1 $(BUILD)/kernel-debs/linux-image-cixmini_*_arm64.deb 2>/dev/null \
	        | head -1 \
	        | sed -nE 's/.*linux-image-cixmini_([^_+]+)(\+[^_]*)?_arm64\.deb/\1/p')"; \
	    if [ -z "$$_have_kver" ]; then \
	        echo "[kernel-debs] existing set carries no linux-image-cixmini_*_arm64.deb -- rebuilding"; \
	        bash $(ROOT)/build/build-kernel-debs.sh; \
	    elif [ "$$_have_kver" = "$$_want_kver" ] \
	         && bash $(ROOT)/build/check-kernel-deb-pin.sh "$(ROOT)/assets/kernel/mainline/KVER" "$(BUILD)/kernel-debs"; then \
	        echo "[kernel-debs] using existing debs from $(BUILD)/kernel-debs (KVER=$$_have_kver matches assets/kernel/mainline/KVER and passes the kernel pin)"; \
	        find $(BUILD)/kernel-debs -maxdepth 1 -name '*.deb' -printf '  %f\n' | sort; \
	    else \
	        echo "[kernel-debs] STALE: existing debs (KVER=$$_have_kver) do not match assets/kernel/mainline (KVER=$$_want_kver, revision floor from the staged dir)" >&2; \
	        _kdebs_ts="$$(date -u +%Y%m%d-%H%M%S)"; \
	        if mv "$(BUILD)/kernel-debs" "$(BUILD)/kernel-debs.stale-$${_kdebs_ts}" 2>/dev/null; then \
	            echo "[kernel-debs]   rotated stale set aside as $(BUILD)/kernel-debs.stale-$${_kdebs_ts}" >&2; \
	        else \
	            echo "[kernel-debs]   WARN: could not rotate stale set aside -- removing in place" >&2; \
	            rm -rf "$(BUILD)/kernel-debs"; \
	        fi; \
	        bash $(ROOT)/build/build-kernel-debs.sh; \
	    fi; \
	fi

# SINTY_DEBS_ARG / sinty-out-sync -- 2026-08-27. verify-local-package-
# versions.sh treats EVERY .deb in a --debs-dir as an expected member of
# the mirror it is checking -- it has no per-package filtering. Pointing
# --debs-dir straight at assets/cix-debs/ (tried first, reverted) makes the
# check FAIL PERMANENTLY: that directory also holds ~30 dpkg-i-direct-only
# packages (cix-vaapi, cix-mesa, cix-gpu-umd, ...) that are staged onto the
# ISO's /ncz-payload/assets/cix-debs/ via 25-cix-proprietary.sh and were never
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

usb-recovery-deb:
	@if [ "$(ARCH)" != arm64 ]; then \
		echo "[usb-recovery-deb] Sky1-only package; skipping on ARCH=$(ARCH)"; \
	elif ! ls $(BUILD)/usb-recovery-deb/ncz-usb-recovery_*.deb >/dev/null 2>&1; then \
		echo "[usb-recovery-deb] no package present; building it"; \
		bash $(ROOT)/build/build-usb-recovery-deb.sh; \
	else \
		echo "[usb-recovery-deb] using existing package from $(BUILD)/usb-recovery-deb"; \
	fi

vendor-mirror: kernel-debs usb-recovery-deb sinty-out-sync
	@echo "[vendor-mirror] publishing local debs and regenerating vendor index"
	@bash $(ROOT)/build/build-vendor-mirror.sh
	@bash $(ROOT)/build/verify-local-package-versions.sh \
	    --pool $(BUILD)/forky-vendor-mirror/pool \
	    --label forky-vendor-mirror \
	    $(SINTY_DEBS_ARG)

# Always run the builder: it removes debs of any other revision (a stale +ncz1 set must never be "existing"),
# and reuses/stages the sha256-pinned set for this arch instead of rebuilding.
libdrm-debs:
	@bash $(ROOT)/build/build-libdrm-debs.sh

# ncz-apt-policy (manifests/install-extra.pkgs seed, both arches, Architecture: all) is built locally for the
# offline mirror -- NOT fetched from the live repo -- so an image build needs no publish. Always rebuilt
# (deterministic, seconds); verify-desktop-mirror-seeds.sh then rebuilds an existing desktop mirror that lacks it or carries an older build.
apt-policy-deb:
	@rm -f $(BUILD)/ncz-apt-policy-deb/ncz-apt-policy_*.deb
	@echo "[apt-policy-deb] building ncz-apt-policy for the offline mirror"
	@bash $(ROOT)/build/build-ncz-apt-policy-deb.sh

desktop-mirror: vendor-mirror libdrm-debs apt-policy-deb
	@if [ ! -d $(BUILD)/desktop-mirror/dists/$(shell . $(ROOT)/release.conf; printf '%s' "$$NCZ_BASE_CODENAME") ]; then \
		echo "[desktop-mirror] missing; building desktop package closure"; \
		bash $(ROOT)/build/build-desktop-mirror.sh; \
	elif ! bash $(ROOT)/build/verify-desktop-mirror-seeds.sh \
	        --mirror $(BUILD)/desktop-mirror --label desktop-mirror; then \
		echo "[desktop-mirror] STALE vs the desktop manifest; rebuilding"; \
		mv $(BUILD)/desktop-mirror $(BUILD)/desktop-mirror.stale-$$(date -u +%Y%m%d-%H%M%S); \
		bash $(ROOT)/build/build-desktop-mirror.sh; \
		bash $(ROOT)/build/verify-desktop-mirror-seeds.sh \
		    --mirror $(BUILD)/desktop-mirror --label desktop-mirror; \
	else \
		echo "[desktop-mirror] using existing mirror from $(BUILD)/desktop-mirror"; \
	fi

offline-mirror: desktop-mirror
	@if [ ! -d $(BUILD)/forky-mirror/pool ] || \
	    ! { [ "$(ARCH)" != "arm64" ] || \
	      bash $(ROOT)/build/verify-local-package-versions.sh \
	        --pool $(BUILD)/forky-mirror/pool \
	        --label forky-mirror \
	        $(SINTY_DEBS_ARG) >/dev/null 2>&1; } || \
	    ! bash $(ROOT)/build/verify-offline-mirror-seeds.sh \
	        --mirror $(BUILD)/forky-mirror \
	        --label forky-mirror >/dev/null 2>&1 || \
	    ! bash $(ROOT)/build/verify-firmware-bom.sh \
	        --mirror $(BUILD)/forky-mirror \
	        --label forky-mirror >/dev/null 2>&1; then \
	    echo "[offline-mirror] missing or stale; rebuilding from refreshed vendor mirror"; \
	    rm -rf $(BUILD)/forky-mirror; \
	    bash $(ROOT)/build/build-forky-mirror.sh; \
	else \
	    echo "[offline-mirror] existing mirror matches local package pins and manifest seeds"; \
	fi
	@bash $(ROOT)/build/verify-firmware-bom.sh --mirror $(BUILD)/forky-mirror --label forky-mirror


# Pinned build inputs (rescue rootfs, python311, wallpaper debs, recovery rootfs) come from the
# ARGONAS store, checksum-pinned in manifests/build-inputs.tsv; see build/stage-build-inputs.sh.
.PHONY: stage-build-inputs
stage-build-inputs:
	@bash $(ROOT)/build/stage-build-inputs.sh --arch $(ARCH)

$(ROOT)/assets/python311/uv:
	@bash $(ROOT)/build/stage-build-inputs.sh --arch $(ARCH) --only assets/python311
$(ROOT)/assets/squashfs/desktop-hotfix.squashfs: $(LATEST_SINGULARITY_DEB)
	@echo "[hotfix-squashfs] rebuilding from $(LATEST_SINGULARITY_DEB)"
	@bash $(ROOT)/build/build-squashfs-layers.sh hotfix
	@echo "[hotfix-squashfs] pruning superseded ncz-singularity-desktop debs from assets/cix-debs/"
	@cd $(ROOT)/assets/cix-debs && ls -1 ncz-singularity-desktop_*.deb 2>/dev/null | sort -V | head -n -1 | xargs -r rm -fv

$(OUTPUT_IMAGE): $(DOWNLOADS)/$(UPSTREAM_ISO) \
	               offline-mirror \
	               $(ROOT)/assets/squashfs/desktop-hotfix.squashfs \
	               $(ROOT)/assets/python311/uv \
	               $(ROOT)/build/build-installer-image.sh \
	               $(ROOT)/build/verify-arm64-inputs.sh \
	               $(ROOT)/build/iso/import-substrate.py \
	               $(ROOT)/build/iso/stage-ncz-payload.py \
	               $(ROOT)/build/iso/patch-debootstrap-stub.py \
	               $(ROOT)/build/iso/patch-initrd-t2-kernel.py \
	               $(ROOT)/manifests/net-firmware.tsv \
	               $(ROOT)/build/iso/build-refind-esp.py \
	               $(ROOT)/build/iso/write-usb-image.py \
	               $(PRESEED)/preseed.cfg \
	               $(PRESEED)/late.sh \
	               $(PRESEED)/extract-rootfs.sh \
	               $(PRESEED)/sshd-watcher.sh \
	               $(wildcard $(POST)/*.sh) \
	               $(ROOT)/post-install/lib/ncz-screensavers-plugin.lock \
	               $(wildcard $(POST)/lib/*.sh) \
	               $(wildcard $(BUILD)/ncz-screensavers-out/ncz-screensavers-plugin_*.deb) \
	               $(wildcard $(ASSETS)/agent-stack/*) \
	               $(wildcard $(ASSETS)/branding/*) \
	               $(wildcard $(ASSETS)/kernel/*/*) \
	               $(wildcard $(ASSETS)/rootfs/*) \
	               $(wildcard $(ASSETS)/sky1-firmware/*)
	@echo "[image] pinned build inputs (recovery rootfs, rescue rootfs, python311, wallpaper debs)"
	@bash $(ROOT)/build/stage-build-inputs.sh --arch $(ARCH)
	@echo "[image] platform-split lint (inventory, hooks.list, deny patterns, guards, manifest divergence)"
	@bash $(ROOT)/build/lint-platform.sh
	@echo "[image] preseed early_command shape/size"
	@bash $(ROOT)/build/check-early-command-size.sh $(PRESEED)/preseed.cfg
	@echo "[image] verifying arm64 inputs (sky1-firmware, cix-debs, rescue-rootfs, mirror)"
	@NCZ_TARGET_ARCH=$(ARCH) bash $(ROOT)/build/verify-arm64-inputs.sh --mirror
	@echo "[image] screensaver settings plugin: staged deb == pin, ABI == the Singularity payload (docs/SCREENSAVER-PLUGIN.md)"
	@bash $(ROOT)/build/check-ssplugin-abi.sh --arch $(ARCH)
	@if [ -n "$(SUBSTRATE_SHA)" ]; then \
	    actual=$$(sha256sum $(DOWNLOADS)/$(UPSTREAM_ISO) | awk '{print $$1}'); \
	    if [ "$$actual" != "$(SUBSTRATE_SHA)" ]; then \
	        echo "[image] substrate $(DOWNLOADS)/$(UPSTREAM_ISO) is sha256 $$actual, not the pinned $(SUBSTRATE_SHA)"; \
	        echo "[image] delete it and re-run (the pinned ISO is restored from $(SUBSTRATE_CACHE_DIRS)), or override SUBSTRATE_SHA deliberately"; \
	        exit 1; \
	    fi; \
	    echo "[image] substrate matches the pin ($(SUBSTRATE_SHA))"; \
	fi
	@echo "[image] building $@ from $(DOWNLOADS)/$(UPSTREAM_ISO)"
	@ARCH=$(ARCH) SUBSTRATE_ISO=$(DOWNLOADS)/$(UPSTREAM_ISO) \
	  SUBSTRATE_URL=$(UPSTREAM_URL) OUTPUT=$@ \
	  WORK_DIR=$${BUILD_WORK_DIR:-$(HOME)/build-tmp/cix-installer-$(ARCH)} \
	  BUILD_VERSION=$(VERSION)-$(BUILD_SHA) \
	  bash $(ROOT)/build/build-installer-image.sh
	@echo "[image] scanning the built artifact for credentials"
	@bash $(ROOT)/build/secret-scan-gate.sh $@
	@echo "[image] DONE — $@ ($$(du -h $@ 2>/dev/null | cut -f1))"

# Singularity screensaver settings plugin (docs/SCREENSAVER-PLUGIN.md): copy
# the pinned deb from ARGONAS into build/ncz-screensavers-out/. Run on the
# build HOST (needs the ARGONAS mount) before `make image`; the image recipe
# only verifies (build/check-ssplugin-abi.sh), it never fetches.
ssplugin-stage:
	@bash $(ROOT)/build/stage-screensaver-plugin.sh $(ARCH)

# Platform split (docs/PLATFORM-SPLIT-DESIGN.md): the inventory in
# docs/platform-inventory.tsv is the source of truth; post-install/hooks.list.*
# are generated from it and run-all.sh runs only the listed hooks.
lint-platform:
	@bash $(ROOT)/build/lint-platform.sh

gen-hooks-lists:
	@bash $(ROOT)/build/gen-hooks-lists.sh

test-platform:
	@bash $(ROOT)/build/test-platform-lint.sh
	@$(MAKE) --no-print-directory test-cygnus-branding

# boot-speed regression tests (docs/BOOT-SPEED.md): no Type=oneshot unit may
# sit in multi-user.target's critical chain just to poll for the network.
test-boot-speed:
	@bash $(ROOT)/build/test-boot-speed.sh

# item G (docs/BOOT-SPEED.md section 8): the systemd-timesyncd fast-retry
# drop-in must ship on both arches and time sync must never order the greeter.
test-timesync-retry:
	@bash $(ROOT)/build/test-timesync-retry.sh

# docs/BOOT-SEQUENCE.md (2026-10-06): installer NIC-wait / clock bounds, Sky1-only
# display pin, bounded NetworkManager-wait-online, diag-console alive() order.
test-boot-sequence:
	@bash $(ROOT)/build/test-boot-sequence.sh

secretscan:
	@bash $(ROOT)/build/secret-scan-gate.sh

# NIC/Bluetooth firmware: baked into the d-i initrd (manifests/net-firmware.tsv)
# and every mapped package seeded in the firmware BOM. NCZ_FIRMWARE_POOL=<pool>
# additionally checks the real firmware-*.deb contents.
.PHONY: test-net-firmware
test-net-firmware:
	@bash $(ROOT)/build/test-net-firmware.sh

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

verify: $(OUTPUT_IMAGE)
	@sha256sum $(OUTPUT_IMAGE) | tee $(OUTPUT_IMAGE).sha256

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
image-verified: $(OUTPUT_IMAGE)
	@echo "[image-verified] running kvm-install-gate-gpt.sh against $(OUTPUT_IMAGE)"
	@if [ ! -x "$(ROOT)/build/kvm-install-gate-gpt.sh" ]; then \
	    echo "[image-verified] FATAL: build/kvm-install-gate-gpt.sh missing or not executable" >&2; \
	    exit 1; \
	fi
	@if [ ! -f "$(OUTPUT_IMAGE)" ]; then \
	    echo "[image-verified] FATAL: $(OUTPUT_IMAGE) not present after make image" >&2; \
	    exit 1; \
	fi
	@mkdir -p "$${KVM_INSTALL_WORKDIR:-$(ROOT)/build/kvm-install}"
	@WORK="$${KVM_INSTALL_WORKDIR:-$(ROOT)/build/kvm-install}"; \
	if ! ARCH=$(ARCH) bash "$(ROOT)/build/kvm-install-gate-gpt.sh" "$(OUTPUT_IMAGE)" "$$WORK"; then \
	    rc=$$?; \
	    echo "" >&2; \
	    echo "[image-verified] GATE FAILED (rc=$$rc): $(OUTPUT_IMAGE) is NOT safe to ship to hardware." >&2; \
	    echo "[image-verified] See $$WORK/install.log and $$WORK/boot.log for the failure evidence." >&2; \
	    exit $$rc; \
	fi
	@echo "[image-verified] PASS: $(OUTPUT_IMAGE) is safe to ship to hardware"

# -----------------------------------------------------------------------
# Step 3 — boot test in qemu-aarch64 with edk2 UEFI firmware (faster
# iteration than hardware). Requires a virtual disk to install onto.
# -----------------------------------------------------------------------
qemu: $(OUTPUT_IMAGE)
	@echo "Use build/kvm-install-gate-gpt.sh $(OUTPUT_IMAGE) for raw-GPT media"

# -----------------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------------
# iso-staging*/ and *.iso are leftovers of the retired ISO builder on old build
# hosts; nothing writes them now, clean still sweeps them.
clean:
	rm -rf $(BUILD)/iso-staging $(BUILD)/iso-staging-di $(BUILD)/*.iso $(BUILD)/*.img $(BUILD)/*.sha256

distclean: clean
	rm -rf $(DOWNLOADS)

# Cygnus 26.10 branding: generator freshness + contrast gates, and the Singularity
# theme/accent integration (generated override == tokens, schema-compiles, theme
# install path, valid selectors, overlay patch still applies). The rEFInd theme
# QEMU harness (branding/cygnus/tests/test-refind-theme.sh) needs a THEME_DIR/OUT_DIR
# and qemu, so it stays a manual tool and is deliberately not wired here.
test-cygnus-branding:
	@echo "[cygnus] branding generator freshness + contrast gates"
	@python3 $(ROOT)/branding/cygnus/tests/test_cygnus_contrast.py
	@python3 $(ROOT)/branding/cygnus/tests/test_cygnus_singularity.py

# static dual-architecture parity: manifest pairs, ncz-screensavers debs, hook arch-gate lint (docs/DUAL-ARCH-PARITY.md)
# components.py check --gate is the phase 2 registry enforcement entry.
parity:
	python3 build/components.py check --gate
	python3 build/gen-components-registry.py --render-seeds --render-local-debs --render-allowlist --check
	build/test-dual-arch-parity.sh
	build/verify-dual-arch-parity.sh
	build/test-amd64-intel-vaapi.sh
	build/test-no-software-render.sh
	build/lint-no-software-render.sh
	build/test-singularity-supervisor-forensics.sh
	build/test-panthor-vulkan.sh
	build/test-installer-screens.sh
	build/test-installer-flow.sh
	build/test-usb2-rescan-sky1-only.sh
	build/test-usb2-rescan-greetd.sh
	branding/cygnus/tests/test-refind-theme-config.sh
	build/test-refind-rescue-promotion.sh
	build/test-wallpaper-rotator-relogin.sh
	python3 build/test_wallpaper_fit.py
	python3 -m unittest build/iso/tests/test_stage_payload_desktop_guard.py
	python3 -m unittest build/iso/tests/test_patch_initrd_firmware.py
	build/test-boot-speed.sh
	build/test-timesync-retry.sh
	build/test-boot-sequence.sh
	build/test-greeter-output-mode.sh
	python3 build/test_display_scale.py
	build/test-chromium-icon.sh
	build/test-libpeas-plugin-icon.sh
	build/test-run-all-baked-allowlist.sh
	build/test-sky1-audio-policy.sh
	build/test-sky1-media-defaults.sh
	build/test-screensaver-default.sh
	build/test-screensavers-mandatory-install.sh
	build/test-ssplugin-supply-chain.sh
	build/test-ncz-ui.sh
	build/test-release-identity.sh
	build/test-base-stamp.sh
	build/test-reap-images.sh
	REPO_ROOT=$(ROOT) bash build/test-amd64-kernel-classifier.sh
	bash build/test-amd64-t2-detect.sh
	bash build/test-nouveau-runpm.sh
	bash build/test-gpu-probe-no-hang.sh
	bash build/test-hook-watchdog.sh
	bash build/test-amd64-cuda-gates.sh
	build/test-arm64-freshness-gate.sh
	bash build/test-singularity-pins.sh
	@bash build/test-singularity-deb-version.sh; rc=$$?; if [ $$rc -ne 0 ] && [ $$rc -ne 77 ]; then exit $$rc; fi
	build/test-overlay-modversions.sh
	build/test-amd64-dracut-isolation.sh
	build/test-kernel-default-policy.sh
	build/test-rescue-kernel-channel.sh
	build/test-late-npu-aipu.sh
	build/test-gpu-install-progress.sh
	build/test-progress-bar-drive.sh
	build/test-firstboot-gpu.sh
	build/test-dkms-btf-toolchain.sh
	build/test-fwupd-i2c-mask.sh
	build/test-apt-sources-offline-canary.sh
	build/test-dkms-prep-keep-going.sh
	build/test-dkms-prep-genksyms.sh
	build/test-stale-singularity-prune.sh
	build/test-kernel-purity-pin.sh
	build/test-kernel-purity-guards.sh
	bash build/test-apt-separation.sh
	bash build/test-ncz-repo-policy.sh
	bash build/test-ncz-apt-policy-deb.sh
	bash build/test-apt-sources-hook-container.sh
	bash build/test-install-extra-local-debs.sh
	bash build/test-desktop-mirror-local-debs.sh
	build/test-no-debian-kernel.sh
	bash build/test-firmware-bom-hook.sh
	bash build/test-desktop-apt-require.sh
	bash build/test-build-inputs.sh
	bash build/test-deb-rev-defaults.sh
	bash build/test-panthor-hook-overlay-fallback.sh
	bash build/test-panthor-fallback-real-overlay.sh
	bash build/test-npu-dkms-deferral.sh
	bash build/test-hooks-fail-loudly.sh
	$(MAKE) --no-print-directory test-cygnus-branding
