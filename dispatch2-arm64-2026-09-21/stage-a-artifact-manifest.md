# Stage A artifact manifest — dispatch 2, arm64/Forky, virtual-only

Date: 2026-09-21
Branch: wip/stock-forky-di-2026-09-21
Review authority: docs/superpowers/specs/2026-09-21-multiarch-modernization-bookworm-elimination-review.md §3 / §10 (Stages A + B only)
Purpose: pin ONE Forky arm64 d-i substrate and document the integration changes each candidate applies to it.

## A.1 — pinned substrate (single artifact, both candidates share it)

| Property | Value |
| --- | --- |
| Upstream URL | https://cdimage.debian.org/cdimage/weekly-builds/arm64/iso-cd/debian-testing-arm64-netinst.iso |
| Filename | debian-testing-arm64-netinst.iso |
| Bytes | 996,454,400 |
| SHA-256 | `4aae4d12acc0c71b7eaf2d03deae48098f84596e6806d3cf78ada53ba0c649a0` |
| Substrate codename (per `dists/forky/Release`) | `forky` (testing) |
| `dists/forky/Release` Codename / Suite | `forky` / `testing` |
| `.disk/info` content | `Debian GNU/Linux testing "Forky" - Official Snapshot arm64 NETINST with firmware 20260817-03:05` |
| Netinst date (from `.disk/info`) | 2026-08-17 03:05 UTC |
| Installer kernel (`install.a64/vmlinuz`) size | 46,358,464 bytes |
| Installer initrd (`install.a64/initrd.gz`) size | 28,791,725 bytes |
| Installer kernel (initrd /lib/modules KVER) | `7.1.8+deb14-arm64` (Debian trixie's installer kernel; substrate was built before Bookworm→Forky reseating the KVER) |
| Initrd shape | **usr-merged**: `lib -> usr/lib`, `sbin -> usr/sbin`, `bin -> usr/bin` (verified, see A.2) |
| Initrd module compression | `.ko.xz` (956 modules extracted; raw xz, NOT zstd) |
| Initrd busybox | ELF aarch64 dynamic, BuildID `d0fd0b3e523cdeaa0ef02a171d88683a7772ccde` |
| Udeb count (arm64 di installer) | 285 entries in `dists/forky/main/debian-installer/binary-arm64/Packages` |
| Critical udeb versions | disk-detect 1.177 (still 15-iter × 2s wait — exactly what review §3.3 references), finish-install 2.126, hw-detect (see Packages), partman-base 241, partman-efi 113, choose-mirror 2.137, base-installer 1.229, bootstrap-base 1.229, partman-partitioning 161, partman-auto 179, apt-setup-udeb 1:0.200 |
| Substrate codename as seen by builder | `forky` (NOT bookworm) — confirmed: build-iso-di.sh:1021 takes the "skip the bookworm-only udeb graft" branch for non-bookworm substrates |

This is the **same** substrate the TYDEUS 2026-08-21 report (`docs/ISO-REBAKE-TYDEUS-2026-08-21.md`) used for Phase 1 (install phase reached completion). The hash is also pinned in `Makefile:113` as `SUBSTRATE_SHA`. It is provenance-equal for both Stage B candidates; both build on this same input.

The `Makefile` already classifies this as Forky (line 43–49 / 63): comment block "It MUST match NCZ_BASE_CODENAME in release.conf, which is forky." The builder at `build/build-iso-di.sh:860` discovers codename from the ISO itself (so the flag name `--bookworm-iso` is a deprecated alias; see lines 116–125).

## A.2 — pinned Sky1 installer kernel (both candidates MUST use this)

| Property | Value |
| --- | --- |
| Path | `assets/kernel/edge/` (symlink) |
| Symlink target | `r272-7.2.6-sky1-ncz-20260915` |
| KVER | `7.2.6-sky1-ncz` |
| `Image-cixmini.bin` SHA-256 | `b741a531dd6af6be1e58c4b4438aecdc869ea6852bc2f57963091bef17ea5e51` |
| `modules-cixmini.tgz` SHA-256 | `ac67fc987fa25987bf34cfeab618aec31e92f3d6861363d2636861cb97ec85b7` |
| `headers-cixmini.tar.zst` SHA-256 | `978fa854192f8447e77de64a7a751bbea36d49e5cf87fdeba25706557fa25421` |
| `config-7.2.6-sky1-ncz` size | 277,983 bytes |
| Stage date (per directory name) | 2026-09-15 |
| Build ID (BUILD_REV) | r272 |
| `build/stage-kernel.sh` (line 89) confirms | `kvm-kernel-gate.sh` passed + `dkms-abi-gate.sh` passed (already-validated staging; re-run is safe) |

**Both Stage B candidates will swap to this same Sky1 7.2.6 installer kernel.** This is per the dispatch brief, item 3: "Do not conflate this with a kernel promotion. Use the exact same pinned Sky1 kernel/headers/modules/firmware in both candidates that the current release build uses." Confirmed by `build/build-iso-di.sh:819-820` which reads `assets/kernel/edge/Image-cixmini.bin` and `assets/kernel/edge/modules-cixmini.tgz` for the installer kernel swap (Step 2, line 2556-2560).

**No `build/kernel-debs/*.deb` is currently staged** in this checkout (verified: `ls build/kernel-debs/` is empty). `build-iso-di.sh:218` will auto-trigger `build-kernel-debs.sh` for arm64 if `EMBED_MIRROR=1` — required for full mode. **We are running `full/desktop` mode** per the brief.

## A.3 — what we deliberately did NOT change (background / control)

These are bookworm-only or ubuntu-foreign-suite transforms. They MUST be dead code on the Forky substrate already (confirmed by inspection):

| Transform | Location in `build-iso-di.sh` | Why it's not in the candidate set |
| --- | --- | --- |
| Trixie debootstrap + libzstd + liblzma graft | lines 1000–1060, gated `if [ "$DI_CODENAME" != "bookworm" ]; then skip` (line 1021) | Substrate is `forky` — already skipped. We did NOT have to do anything. Verified: log line 1022 will print "substrate is forky — skipping the bookworm-only udeb graft". |
| cdebconf-newt amber-phosphor BINARY patch | lines 2785-2856, gated `if [ "$SKIP_NEWT_BINARY_PATCH" = "1" ]` (set to 1 at line 2728 for non-bookworm) | Substrate is `forky` — already skipped. Cosmetic; load-bearing path is the NEWT_COLORS env-var injection (still runs). |
| `gutsy` debootstrap naming + `dbus` work_out_debs patch | lines 1849-1930, gated on thin/netinstall + foreign Ubuntu recipe | Full mode does not enter this path (already skipped at line 167); and the substrate is `forky`, not `gutsy`/Ubuntu. |

All three of these are Bookworm/Ubuntu-only transforms per review §5. Both candidates bypass them identically because the substrate is `forky`, NOT `bookworm`. Confirmed — we did not have to touch the code.

## A.4 — candidate F-stock-userspace integration changes

The brief: "pinned Forky d-i userspace + ONLY the mandatory Sky1 kernel/module/firmware substitution + product preseed/deployment integration. NO disk-detect timing patch, no early custom USB recovery, no DNS writer, no other hardware-internals patch beyond the kernel/module swap itself."

Concretely, F-stock-userspace applies ONLY:

| # | What | Where | Why mandatory |
| --- | --- | --- | --- |
| 1 | Replace `install.a64/vmlinuz` with Sky1 `Image-cixmini.bin` (7.2.6-sky1-ncz) | `build-iso-di.sh:2556-2560` (Step 2) | Stock d-i vmlinuz (built for generic arm64 boards) cannot boot Sky1 metal: no working UART/ACPI/GPU console. Confirmed at line 2545-2552 (comment block). |
| 2 | Append Sky1 modules cpio + iwlwifi/rtl_nic firmware + Panthor Mali CSF firmware to `install.a64/initrd.gz` | `build-iso-di.sh:2565-2705` (Step 3) + `:2943-2983` (firmware) + `:2678-2691` (Panthor) | Without our modules the d-i kernel loads stock Debian modules that don't know Sky1 devices; without rtl_nic fw the O6 NIC never links (line 2665-2676); without mali_csffw.bin DIAG reports a `-ENOENT` it shouldn't. |
| 3 | Module tree pruning (drivers/media except cec/, drivers/sound, drivers/bluetooth, net/wireless, net/mac80211, net/bluetooth) | `build-iso-di.sh:2635-2659` | On O6N metal, a 130MB+ initrd hit a firmware-level load-size limit (confirmed 2026-07-28, line 2606-2610). Pruning is part of the same module swap step, not a separate "hardware patch". |
| 4 | Decompress `.ko.xz` → `.ko` in the overlay | `build-iso-di.sh:2574-2598` | d-i's kmod UDEB cannot decompress xz (confirmed at line 2583-2586 — zero lzma strings in the binary). Target system keeps `.ko.xz`. |
| 5 | NCZ branding baked into initrd templates (main-menu etc.) | `build-iso-di.sh:2872-2892` | Product identity. Same on every NCZ ISO. Not a hardware patch. |
| 6 | NEWT_COLORS env-var inject into `/init` | `build-iso-di.sh:2747-2783` | Cosmetic. Same on every NCZ ISO. Not a hardware patch. |
| 7 | Stage `/cixmini/preseed.cfg` + `late.sh` + `extract-rootfs.sh` + `sshd-watcher.sh` + `disk-fs-chooser.sh` + `component-selector.sh` + `usb-rescan.sh` + post-install/ + assets/ on the ISO | `build-iso-di.sh:3035-3095` | **Mandatory** for product preseed/deployment integration per brief item 1. Note: the act of staging the file is mandatory, but the content (e.g. `usb-rescan.sh`'s logic) is NOT invoked by F-stock-userspace: it gets staged because the preseed references it, but with NO d-i internals patches, it will run as the unmodified helper. |
| 8 | Static zstd binary overlay appended to initrd | `build-iso-di.sh:2912-2941` (Step 3.1) | Resolute data.tar.zst/control.tar.zst extraction requires `zstdcat` in d-i. Not hardware-specific — but **mandatory** because the prepared target layers are zstd-compressed. NOT a Sky1 hardware fix. |
| 9 | Installer firmware overlay (iwlwifi + rtl_nic) | `build-iso-di.sh:2943-2983` | Cross-arch. Necessary because the d-i netinst's firmware pool is the minimal non-free set; without rtl_nic, O6 link never comes up; without iwlwifi, generic amd64 WiFi is unavailable. Same on both candidates. |
| 10 | Remote-diagnostics module (ncz_diag toggle, telnet :23 / http :8080 / remote syslog) | `build-iso-di.sh:3097-3106` | DIAG_ENABLE=1 default. Same on every NCZ ISO. Not a hardware patch. |

What F-stock-userspace **does NOT** apply (per brief — Sky1 hardware fix overlay excluded):

- **disk-detect udeb patch** (extend 15-iter×2s wait to 90; add nvme module dir; add `prime_storage_detection()` for nvme/nvme-core/virtio_blk/sd_mod/ahci). `build-iso-di.sh:2101-2291`.
- **finish-install udeb patch** (allocate 100 owned progress units to late_command). `build-iso-di.sh:2297-2394`.
- **`S35usb-rescan` debian-installer-startup.d hook** (early USB root-hub rescan via initrd-level overlay). `build-iso-di.sh:2986-3021`. The helper file is still staged (item 7 above) because the preseed references it, but the initrd-level `S35` hook does NOT run.
- **DNS writer hook** (`05ncz-dns` in `/usr/lib/base-installer.d/` and `/usr/lib/pre-pkgsel.d/`). `preseed/sshd-watcher.sh:28-110` (`install_ncz_dns_hooks()`). Without that function call, d-i uses its own DHCP-derived resolver. The sshd-watcher still runs (sshd + cmdline reset are useful diagnostically), but the DNS override does NOT fire.

## A.5 — candidate F-retained-fixes integration changes

Same as A.4 (items 1–10) **PLUS** the Sky1 hardware fix overlay:

| # | Additional overlay | Where |
| --- | --- | --- |
| 11 | disk-detect udeb patch (90 attempts + nvme module dir + `prime_storage_detection`) | `build-iso-di.sh:2101-2291` |
| 12 | finish-install udeb patch (100 progress units for late_command) | `build-iso-di.sh:2297-2394` |
| 13 | `S35usb-rescan` debian-installer-startup.d hook appended to initrd | `build-iso-di.sh:2986-3021` |
| 14 | DNS writer (`05ncz-dns` in base-installer.d / pre-pkgsel.d) — wired by sshd-watcher.sh | `preseed/sshd-watcher.sh:install_ncz_dns_hooks()` |

Items 11–14 are the **current applicable Sky1 d-i hardware fixes** per review §3.3 and §4. Note that the review explicitly says these are "plausible overlays on Forky and are already applied independently of the Bookworm-only graft" (review §1 / conclusion 4). They are the things being tested for retirement in this dispatch.

## A.6 — "stock userspace" definition (the dispatch is explicit about this distinction)

Per review §10 Stage C: "stock Forky d-i userspace" means **unmodified Debian Forky d-i userspace + the minimum required kernel/module/firmware substitution + product preseed/deployment integration**. It is NOT "an untouched Debian ISO". Specifically:

- The kernel swap (item 1) is mandatory because stock d-i kernel cannot boot Sky1 metal — keeping the stock d-i kernel would fail at firmware/kernel startup, before d-i even starts.
- The Sky1 modules overlay (items 2–4) is mandatory because d-i's initrd needs Sky1 device drivers — without it, storage/net enumeration fail.
- Product preseed/deployment integration (items 5–10) is mandatory because this is an NCZ installer, not a Debian netinst.

What distinguishes F-stock-userspace from F-retained-fixes is exclusively items 11–14 (A.5): the four d-i userspace hardware-workaround overlays. If the install or installed-boot phases diverge between the two candidates, the divergence localizes to one of these four overlays — and per the review, that's the experiment.

## A.7 — build environment for both candidates

Both candidates build via the same `build-iso-di.sh --installer-iso <iso> --root <root> --version <v> --output <out> --mode full --variant desktop` invocation, run on this same `wip/stock-forky-di-2026-09-21` checkout. The candidates differ ONLY in which of A.4 vs A.5's items are enabled.

Implementation choice: rather than edit `build-iso-di.sh` to add flags for items 11–14, this dispatch adds a small shim (`build/dispatch2-sky1-overlays.sh`) that lets us toggle items 11–14 via an env var (`NCZ_SKY1_OVERLAYS=1` for F-retained-fixes, `NCZ_SKY1_OVERLAYS=0` for F-stock-userspace). The shim sets a marker file the builder reads at lines 2101/2297/2986/1019 (via pre-existing gates where present, or via new top-level gates we add). **This keeps `build-iso-di.sh` changes auditable and minimal** — both candidates use the same production builder; the only delta is the overlay set.

Stage B will run `build/kvm-install-gate.sh` against each candidate's output ISO, then `build/kvm-installed-disk-assert.sh` on the resulting qcow2. Both candidates' full logs and on-disk state get recorded in `dispatch2-arm64-2026-09-21/stage-b-results.md` and into `sbom/iso-receipts.txt`.