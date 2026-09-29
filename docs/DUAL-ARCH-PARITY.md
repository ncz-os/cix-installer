# Dual-architecture parity (arm64 Sky1 and amd64 T2/x86)

Operator rule (2026-09-29): both builds contain every fix that is common to both. A fix lands in ONE implementation,
is verified on BOTH installed targets, and anything that is platform-only says so, in writing, in this file.

Branch: `release/dual-arch-2026-09-29`. Enforcement: `make parity` (static) and the KVM install gate for each arch.

## The rule (short form)

1. Classify every commit, hook, asset and package as COMMON, SKY1 (arm64 only) or AMD64/T2 (x86 only) when it is added.
2. COMMON code has one implementation and is asserted by `build/verify-installed-target.sh <root> <debugfs> <arch>`,
   which the KVM gate runs against BOTH installed targets. If you add a COMMON behavior, add its assertion there.
3. Platform-only hooks gate themselves on the architecture and log-and-no-op elsewhere
   (`build/lint-hook-arch-gates.sh` fails the build for a hook that names a platform and has no arch check).
4. Package lists come in pairs (`<m>.pkgs` / `<m>-amd64.pkgs`). A package in only one of them must have a row with a
   reason in `build/arch-parity-allowlist.tsv`.
5. The two installed targets must agree on the `[fact]` lines the verifier prints:
   `build/verify-dual-arch-parity.sh --facts arm64.txt amd64.txt`.
6. ncz-screensavers arm64 and amd64 debs come from ONE staged version directory with one `BUILT-FROM.txt` commit.

## Tools

| what | where |
|---|---|
| static parity (manifests, screensaver debs, hook lint) | `make parity` = `build/verify-dual-arch-parity.sh` |
| fact comparison of two installed targets | `build/verify-dual-arch-parity.sh --facts A B` |
| hook arch-gate lint + allowlist | `build/lint-hook-arch-gates.sh`, `build/hook-arch-allowlist.tsv` |
| manifest allowlist | `build/arch-parity-allowlist.tsv` |
| shared installed-target verifier | `build/verify-installed-target.sh` (arm64 wrapper `verify-installed-target-arm64.sh`) |
| fixture tests | `build/test-dual-arch-parity.sh`, `build/test-installed-target-verifier.sh` |
| KVM gate | `build/kvm-install-gate-gpt.sh` (`ARCH=arm64|amd64`) |

## Classification of the work since 9ec1e87

Verified-in column: V = shared verifier section (runs for both arches), K = KVM gate step, U = unit/fixture test, S = static gate.

### COMMON (both arches, one implementation)

| item | commits | verified |
|---|---|---|
| early_command size budget (helper + `check-early-command-size.sh`, 13,000 B) | 1409580 2fe38a7 | S (build-iso-di.sh), K (media detection) |
| late.sh dangling-symlink union-sync fix, final ldconfig, `/etc/.updated`, ldconfig.service race drop-in | 1bb080f a9bdb2d 33f988c | U test-late-union-sync; V (ld) |
| One IAU-name hostname algorithm (`ncz-<star>-<4 digits>`), prompt-able, overridable, kept across preseed reload | 66e5410 878e824 6e52502 29afe3d | U test-hostname-suggest (44); V hostname regex; fact `hostname_format_ok` |
| First-boot failed-units report and allowlist | 0a84f26 3f88398 | K (both arches read `/var/log/ncz-first-boot-failed.txt`) |
| sudo, installation-report, popularity-contest in the offline index | dcf13e0 | V sudo + sudo group member |
| Installer boot UX: 3 s rEFInd, quiet console, `consoleblank=0` | dcf13e0 | U build-refind-esp fixtures; S |
| Component selector `Choices-C` fix; diag-console never prints the password or writes to the console | 7ac1e36 23cc9c3 dcf13e0 | U; screen-content gate (planned, see below) |
| Bing wallpaper prefetch (helper, timer, patched plugin) | 25d6391 e26c70a 1cf1aed | V (vii); K `# wallpaper-bing-rc=0|75`; fact `bing_plugin_patched` |
| Sensors adaptive contrast overlay patch `0005` | 7e1d9c2 2291c70 | V (viii); fact `sensors_plugin_patched` |
| All Singularity overlay patches, fresh deb (stale baked deb cannot override) | 7e1d9c2 | V (vii)(viii); stage 1 `hotfix` |
| ncz-screensavers package wiring (0.3.4 both arches from one source) | 7d75b1e 713d986 00b69d1 28a868c | V (vi); fact `screensavers_version`; S `make parity` |
| Release identity files (`BUILD_ARCH`, `BUILD_VERSION`, `RELEASE`, `/etc/issue`) | b7468a5 | V (id); facts `release_version`, `release_codename` |
| Media stack follows V4L2, VA-API optional | 2850340 | V (v) arm64; amd64 uses VA-API from the distro (intel-media-va-driver), not asserted |
| Substrate pin (arm64 pinned by sha256, amd64 warns) | 9abd22b | S Makefile |
| Verifier and gate infrastructure, boot-timeline harness | bade878 185c2f6 b7468a5 b9bc476 | U |
| Doc: runbooks and results | 6066bfb 08de3c7 f9f2457 ecdb95e 220e10d | n/a |
| Never software render if a GPU exists | (policy, in progress) | see "Policy: no software rendering" |

### SKY1 only (arm64)

| item | commits | verified |
|---|---|---|
| Sky1 firmware (16 fwb, dsp_fw, mali_csffw), aipu KMD, amvx/VPU, cixdec0/cixenc0, h264_v4l2m2m | bade878 2666e6b 18e8a14 | V (i)-(iii) arm64 |
| Kernel-debs staging freshness (`build-kernel-debs.sh` BUILD_REV from the edge symlink) | 3dc8b55 d0d229d | S |
| chromium-ncz-sky1, mpv `hwdec=v4l2m2m-copy` | 2850340 84-vpu-mpv | V (iv)(v) arm64 |
| Sky1 audio autoswitch | 195bb66 | V (v-b) arm64 |
| Stage-2 Sky1 ISO build fixes, ULTRA container runbook | 3297eba 771e71e 9a5edc3 4c0affc 4b47ef6 | S |
| linlon_dp/trilin_dpsub module blacklist on Install/Expert entries | dcf13e0 | U build-refind-esp (arm64 only) |
| Hooks 11 15 25 26 41 47 83 84 88 89 (self-gated to arm64) | this branch | S lint |

### AMD64 / T2 only

| item | verified |
|---|---|
| T2 kernel tree present, no Sky1 policy leaked (serial-getty@ttyAMA0, ncz-performance-mode, cix-detect-display) | V (amd64) |
| Hooks 10-amd64-kernel, 44-apple-vbt-spoof, 55-t2-firmware, 56-t2-dkms (DMI or arch gated) | S lint |
| amd64 microcode, Intel VA driver, syslinux/grub rescue tools | manifests allowlist |
| CUDA 13.4 pool (feat/amd64-cuda-13-4, pending zoder APPROVE) | pending |

## COMMON items not yet verified on both arches

* The media stack assertion (V4L2/VA-API) is arm64 only; the x86 stack is distro VA-API and has no assertion.
* CUDA is x86 only and not yet merged.
* Real-hardware behavior (linlon/DRM blank hypothesis, boot timing, hardware decode) can only be shown on a real O6N/MS-R1.

## Hooks still without an arch check

`build/hook-arch-allowlist.tsv` lists them with a reason. LEAD 8's platform split (phase B, per-platform hook lists) is
the real fix; the lint stops NEW ungated hooks.

## Policy: no software rendering

If a machine has a GPU it must never render in software. Tracked as a COMMON item; see the implementation notes in the
release record.
