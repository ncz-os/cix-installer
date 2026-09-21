# NCZ-OS multi-architecture modernization and Bookworm elimination

Date: 2026-09-21  
Status: architectural review and proposed qualification plan; no implementation or boot qualification performed  
Reviewed checkout: `b83a41d23ee7b4ccb19fd11da7be982afa19cd84`

## 1. Decisions and direct answers

**Stock Forky arm64 d-i replacement: UNKNOWN as an unmodified d-i userspace on Sky1/O6N. The August TYDEUS failure does not establish a Forky d-i hardware incompatibility.** It was a failure to boot the installed virtual disk, with a reported partition/ESP defect, after a modified Forky-based installer completed installation. The missing experiment is a controlled, human-supervised O6N test of the pinned Forky installer userspace with the required Sky1 kernel, followed by comparison with the same image carrying the existing hardware fixes. Section 10 specifies the experiment and acceptance criteria.

The three possible meanings of “stock” need separate answers:

| Replacement under consideration | Assessment |
| --- | --- |
| An untouched Debian Forky netinst ISO, including Debian's stock kernel, replacing the complete NCZ installer | **No as a drop-in NCZ replacement.** It does not supply the NCZ layer deployment, product configuration, accelerator pipeline or standardized rEFInd installation. This review also has no O6N qualification of its stock kernel. |
| Stock Forky d-i userspace, with NCZ's mandatory Sky1 kernel/modules/firmware and normal product preseed | **Unknown on O6N.** This is the useful test of whether the d-i hardware hand-patches can disappear. TYDEUS did not isolate this configuration. |
| Pinned Forky d-i substrate, retaining a bounded Sky1 hardware overlay and NCZ deployment integration where necessary | **Credible and recommended direction for eliminating Bookworm; not yet release-qualified.** The code already supports a Forky substrate, and TYDEUS reached installation completion with one. No architectural dependency on a Bookworm target OS was found. |

The four requested conclusions are:

1. **Multi-architecture:** the common UEFI/d-i/layer-deployment architecture is sound, but the implementation still conflates CPU architecture, board family, build host and selected role. Some amd64 paths still require or stage Sky1 inputs. Make architecture an explicit artifact property and board support an explicit capability profile.
2. **Streamlining:** retain the prior incremental-assembly design; first simplify ownership of hooks, kernel finalization and installer compatibility transforms. These are more consequential than changing compression or replacing an image-building tool.
3. **Bookworm:** it can plausibly be eliminated as an active installer/build dependency. The current full install already deploys a Forky-prepared target directly. Retirement requires a pinned Forky candidate to pass complete install-and-boot gates and O6N qualification; it does not require a distro upgrade operation or removal of the custom kernel.
4. **Stock Forky d-i:** do not claim either a proven drop-in replacement or a proven hardware failure. The load-bearing historical failure is an installed-image integration failure, not evidence that Forky's d-i cannot operate Sky1 USB/NVMe. Existing USB/NVMe fixes are plausible overlays on Forky and are already applied independently of the Bookworm-only graft.

### Evidence and checkout caveats

The operator reports a failed SSH-authenticated pull from ARGONAS before this review, on the branch tracking `wip/mkosi-pipeline-2026-09-14`. This checkout may lack a handful of narrow fixes. Findings describe the commit above, not unobserved remote HEAD. No pull, build, installation, reboot or source-code change was attempted for this review.

Repository references use `path:line` at this checkout. Historical reports are evidence of what they record, not substitutes for raw logs or a new reproduction. Upstream source was checked on 2026-09-21; immutable source revisions are linked where available. Upstream master and current package metadata do **not** prove what is inside the pinned August netinst ISO. Exact binary inspection remains a release gate.

The prior [incremental ISO assembly design](2026-09-21-incremental-di-iso-assembly-design.md) was read first. This review also examined the complete TYDEUS report, the preseed and post-install execution paths, guardrails, mkosi design, release configuration and the operator's [kernel checklist](/home/jasonperlow/kernel-build-checklist-reference.md). No historical report's credential values are reproduced here.

## 2. What the two stages actually do today

### 2.1 Installer runtime and installed operating system are different artifacts

`build/build-iso-di.sh:2` still describes Bookworm d-i plus an Ubuntu late-command pivot. `post-install/run-all.sh:5` still describes a freshly installed Bookworm rootfs. Those descriptions do not match the current full-mode execution path.

The actual path is:

1. **Prepare the target OS at build time.** `release.conf:7` selects Debian, `release.conf:9` selects Forky, and `release.conf:26` pins the base archive snapshot. `build/build-base-rootfs.sh:155` runs mmdebstrap; the mkosi role-delta producer and squashfs producer produce the prepared base and desktop layers.
2. **Prepare a separate d-i runtime.** The ISO builder extracts the supplied netinst using `7z` (`build/build-iso-di.sh:794`), discovers its suite (`:813`), retains its udebs and reconstructs the media pool. The misleading `--bookworm-iso` option accepts testing media. The Bookworm-only Trixie debootstrap/library graft is explicitly skipped for other suites (`:974`).
3. **Boot d-i, choose components and partition the destination.** Preseed starts diagnostics, runs the foreground component selector and disk chooser, and supplies the partition recipe (`preseed/preseed.cfg:175`, `:246`, `:380`, `:437`). On arm64 the installer kernel and modules are replaced by Sky1 artifacts (`build/build-iso-di.sh:2496`); amd64 keeps the substrate installer kernel.
4. **Deploy the prepared target at the bootstrap boundary.** In full mode, the builder replaces debootstrap with the layer-extraction stub (`build/build-iso-di.sh:1056`, `:1093`). It unpacks base and selected desktop/hotfix content, handles the delta deletion semantics, validates the stack, fixes/verifies root mode after the last layer, and installs first-boot finalization (`:1230`, `:1331`, `:1439`). These are flattened files on the target filesystem, not a newly introduced runtime overlay operating system.
5. **Customize that Forky target.** `preseed/late.sh` stages metadata/assets, configures the local package source and executes `post-install/run-all.sh` in the target (`preseed/late.sh:445`, `:624`). Hooks perform kernel/package installation, machine configuration, accelerator work, rescue preparation and bootloader/initramfs generation. `post-install/70-bootloader.sh:4` standardizes rEFInd on both architectures. The late path finalizes APT sources and installation completion.

**There is no Bookworm target installation followed by `full-upgrade` or `dist-upgrade` in this full-mode path.** The target starts from prepared Forky layers. Package repair/configuration, individual package installs, source rewriting, and the conditional Ubuntu source branch at `preseed/late.sh:1292` are not an OS-level Bookworm-to-Forky upgrade. No executing full/dist-upgrade operation was found in the reviewed preseed/post-install trees; the disabled OTA hook is not an installation pivot either.

The two stages are therefore **d-i bootstrap environment → deployment/finalization of a separately prepared Forky OS**. Calling this a “pivot” is acceptable only if it means that environment boundary, not a distribution upgrade. Removing Bookworm changes the first environment; it does not require rearchitecting the second.

### 2.2 Full, thin and netinstall cannot be silently treated as equivalent

`build/build-iso-di.sh:118` distinguishes full, thin and netinstall. Full replaces debootstrap; thin/netinstall deliberately retain real debootstrap. Full also retains a tar-rootfs fallback when layers are absent (`:1600`, `:3489`). A release policy should require the intended layer stack explicitly instead of silently taking an older fallback.

The non-full paths remain less consolidated: preseed requests the Ubuntu `gutsy` debootstrap script (`preseed/preseed.cfg:511`), early setup creates a resolute-to-gutsy link (`:202`), and the builder patches foreign-suite debootstrap functions/scripts (`build/build-iso-di.sh:1694`). Netinstall's bootstrap pool has hard-coded resolute/arm64/ports assumptions (`:914`). Mirror rewriting updates some suite/host/path values but is not a complete protocol/component/recipe migration (`:3028`; preseed Ubuntu component defaults at `:544`).

Thus **“Forky full mode exists” is not proof that every mode is a correct native Forky bootstrap**. Either qualify thin/netinstall with Forky's native recipe and exact mirror closure, or mark them unsupported for a Forky-only release until that work is complete. Do not preserve a hidden Bookworm/Ubuntu path under a new release label.

### 2.3 The apparent duplicate extraction path is not the live authority

`preseed/extract-rootfs.sh` documents its own retirement from the live path. The `partman/late_command` setting at `preseed/preseed.cfg:418` is not a supported d-i hook; the real extraction runs inside the generated debootstrap stub. The guardrails explain how a test against the inactive script once gave a vacuous pass (`docs/ISO-BUILD-GUARDRAILS.md:83`).

Eventually generate the live stub and any test fixture from one maintained implementation. Until then, test the **literal generated BusyBox script**, not a Bash approximation or the inactive twin. Consolidating this is a mechanics change requiring explicit justification, not cosmetic cleanup.

## 3. What TYDEUS actually proves

### 3.1 It already used testing d-i, with substantial customization

The documented build command supplied `downloads/debian-testing-arm64-netinst.iso` to the historically named `--bookworm-iso` flag (`docs/ISO-REBAKE-TYDEUS-2026-08-21.md:250`). It substituted the Sky1 7.2 kernel, expanded compressed installer modules, retained required display/media modules and injected firmware (`:250–268`). This was neither a pristine Debian netinst test nor a Bookworm substrate test.

| Historical phase | Actual test | What can be concluded |
| --- | --- | --- |
| Phase 1 (`:284–332`) | Boot modified installer in an arm64 QEMU/AAVMF environment; install onto qcow2; reach finish/reboot handling | The modified testing-based runtime could execute the installation path in virtual hardware. This contradicts a blanket claim that Forky d-i cannot run the NCZ workflow. |
| Phase 2 (`:334–363`) | Boot that freshly installed qcow2 as a machine, after the installer phase | No kernel banner; reported EFI loader exception and a destination disk without a partition table/real ESP. This tests the installed result, not a second stage of d-i hardware detection. |
| Harness edits (`:365–390`) | Update success-marker matching and add the unattended test token | These explain how the install phase reached the next gate. They do not repair disk layout, qualify Sky1 hardware or establish an end-to-end pass. |

The narrative says 67 hooks ran, but its pasted summary reports `hooks reported done: 0` (`:298`). It also records optional failures and an NPU package transaction warning returning success (`:324–332`). Treat phase 1 as reported workflow completion, not proof that every installed subsystem was healthy.

### 3.2 Failure classification and limits of the diagnosis

The report says AAVMF attempted `/EFI/Linux/systemd-bootaa64.efi`, raised a synchronous exception and never produced a kernel banner. Its disk inspection reportedly found ext4 directly on `/dev/vda`, with EFI files in an ordinary directory and no GPT/MBR (`:336–348`). A missing real ESP is independently sufficient to make the intended removable-media UEFI installation defective.

**This is an image-layout/bootloader-handoff integration failure, structurally different from Sky1 USB enumeration, NVMe timing, ACPI or accelerator binding.** Porting an NVMe wait loop or USB rescan cannot repair a whole-disk ext4 image. Conversely, this failure does not establish that such hardware patches are incompatible with Forky d-i. There is no evidence here for a Forky-internals/Sky1 incompatibility.

The report's precise causal story is not fully established:

- It attributes a Boot0001 entry to `bootctl install --no-variables`; that flag does not itself create an NVRAM boot entry. A stale variable or another producer is possible, but unproven.
- It reports both QEMU rc=0 and a phase-2 timeout. Those summaries alone do not reconstruct the exact termination sequence.
- The exact exception's cause cannot be confirmed without the raw firmware log, variable store and disk image. The general statement that UEFI can only ever read FAT is also too broad; the intended standard ESP still needs to be an actual appropriately formatted partition.
- Its suggested `mklabel-gpt`/`mklabel-msdos` insertion into an expert recipe should not be copied as executable syntax. Use supported partman settings and inspect the resulting disk. NCZ's requirement is UEFI/GPT, not a new BIOS/MBR branch.

The current recipe has an ESP stanza and btrfs root (`preseed/preseed.cfg:437`); its ESP size is 2048 MB despite nearby 4-GB commentary. `preseed/disk-fs-chooser.sh:307` wipes disk ends; that operation alone does not create GPT. Absence of an explicit label assertion does not prove current d-i will reproduce the August layout defect: EFI-aware partman behavior and later changes matter. The missing proof is a captured **current** partition table, FAT ESP mount provenance and successful installed boot.

### 3.3 What changed since that report

The Makefile now defaults to a pinned testing/arm64 image and argues that its installer components should match Forky (`Makefile:38–65`). Its comments describe fewer/stabler applicable udebs and better unattended behavior than the Bookworm input. It pins the August image SHA at `:88`; this is meaningful provenance, not current hardware qualification.

Current code already skips the Bookworm graft and binary color patch on Forky, preserves usr-merge during the module overlay, preseeds `systemd-boot-installer/skip`, and uses rEFInd for installed amd64 as well as arm64 (`build/build-iso-di.sh:974`, `:2647`, `:2679`; `preseed/preseed.cfg:644`; `post-install/70-bootloader.sh:4`). These reduce the relevance of the old systemd-boot failure path. They do not prove the entire corrected image boots.

The Makefile's “validated end-to-end”/August gate claims (`Makefile:74–87`) are stronger than the cited report supports. Replace those claims with receipts identifying ISO hash, harness revision, both phase outcomes and hardware identity. A changed default is not such a receipt.

## 4. Architecture: unify policy, preserve real hardware differences

A single architecture switch is too coarse. Use four explicit inputs:

- **Architecture:** `arm64` or `amd64`; ELF/EFI machine type, Debian package architecture, tool triplet and installer paths.
- **Platform profile:** Sky1/O6N-family capabilities, T2 capabilities or generic UEFI; firmware, ACPI, controller and kernel requirements.
- **Kernel manifest:** exact installer/target/rescue kernel identities, headers, modules, firmware, four accelerator overlay records and boot payload digests.
- **Role selection:** desktop, headless, management container, rescue and optional applications.

An arm64 package must not imply “all Sky1 quirks apply”; an amd64 desktop selection must not be necessary to install T2 firmware. Build-time code consumes the declared target profile. Runtime code confirms hardware from ACPI/DMI/PCI topology or driver binding. It must not accidentally classify the target from the build host's `/sys`.

### 4.1 Genuine differences to retain

| Requirement | Evidence and treatment |
| --- | --- |
| Sky1 custom kernel, ACPI/EFI/SMMU/clock parameters and display-module preservation | `build/build-iso-di.sh:2496`, `:2567`, `:3550`. Keep profile-specific parameters and kernel pipeline; Forky userspace does not replace them. |
| USB controller enumeration/recovery | `preseed/usb-rescan.sh:124`, installer early rescan at `build/build-iso-di.sh:2959`, target helper in `post-install/41-usb2-rescan.sh`. Keep the early-before-media distinction. A preseed on unreadable USB cannot repair the event needed to read itself. |
| NVMe arrival and module availability | `build/build-iso-di.sh:2054`. Preserve evidence-based waiting/module priming while testing stock behavior; do not force every board through a Sky1 delay. |
| NPU ACPI differences between firmware/boards | `post-install/80-npu.sh:205` distinguishes newer ACPI from older board/SSDT cases. Preserve positive detection and fail-closed unknown-board behavior. |
| T2 firmware and network handling | `post-install/55-t2-firmware.sh:59` and `post-install/lib/hw-detect.sh`; iBridge network rule in `post-install/33-network.sh:59`. Detect real T2 hardware, not all amd64. |
| EFI binary name and kernel menu model | `post-install/70-bootloader.sh:9`. AA64/X64 filenames and Mali/Panthor versus stable/edge menu choices are legitimate data differences; rescue/promotion/config generation should share policy. |

The kernel checklist specifically warns that Sky1 root ports and a Cadence USB wrapper can share PCI ID `17cd:0100`. A generic PCI-ID-only udev rule is not a safe replacement for topology-aware handling.

### 4.2 Accidental architecture coupling and concrete defects

| Finding | Evidence | Recommendation |
| --- | --- | --- |
| amd64 build can require Sky1 installer assets before reaching its stock-kernel branch | Unconditional asset discovery/error paths at `build/build-iso-di.sh:766`; architecture split only at `:2496` | Resolve only the declared platform's inputs. A clean amd64 build must succeed without an arm64 asset cache. |
| Default upstream media is arm64 regardless of target selection | `Makefile:63`; builder supports both architectures at `build/build-iso-di.sh:104` | Per-architecture immutable substrate locks; reject an ISO whose architecture disagrees with the manifest. |
| Early diagnostic/bootstrap helpers contain arm64 assumptions | `preseed/preseed.cfg:178`; bootstrap index logic in `preseed/sshd-watcher.sh`; local-pool check at `preseed/late.sh:445` | Render paths from target architecture; verify bundled executable ELF type. Preserve early diagnostics on both architectures. |
| Generic asset copying can bring foreign kernels/tools into an image | `build/build-iso-di.sh:3088`, `:3124`, `:3456`; unconditional available arm64 KVER copy at `build/build-squashfs-layers.sh:927` | Use an allowlisted asset inventory, not directory presence or generic fallback. Validate every kernel/tool architecture. |
| Generic rescue aliases can select stale assets; rescue hook assumes Sky1 kernel | `build/build-iso-di.sh:3182`, `:3202`; `post-install/72-rescue-partition.sh:43` and `:51` | Explicit rescue rootfs **and** rescue kernel per profile. An amd64 rootfs alias is insufficient if the hook still takes the arm64 Image/KVER. |
| Hook criticality is based on names/history rather than target capabilities | `post-install/run-all.sh:168–212` | A declarative plan should list applicable hooks once, dependencies, build/install/first-boot phase and fatal/optional status. |
| Non-baked paths can schedule firmware/network twice | Required list includes 12/33; optional exclusion no longer excludes them (`post-install/run-all.sh:168`, `:209`) | Resolve a unique ordered plan and test it for each mode/profile. Under baked mode 10/11 remain required, while 12/33 move to optional; do not misread the older comments as actual behavior. |
| amd64 kernel setup depends on bake-time behavior | `build/build-squashfs-layers.sh:238`; baked optional filtering at `post-install/run-all.sh:212` | Express that dependency in the layer receipt; require correct installed amd64 kernel packages/KVER manifest, rather than assuming an install-time hook will repair them. |
| Generic desktop/source helpers retain arm64 details | `post-install/20-desktop.sh:753`, `:856`; browser source architecture at `post-install/53-chrome.sh:133` | Use dpkg architecture/triplet values where the behavior is genuinely common. |
| Target probes can see the build machine | Host `/sys`, `/proc`, `/dev` binds at `build/build-squashfs-layers.sh:253`; hardware probes in GPU hooks; runtime sysfs activity in `post-install/87-mpam-cache-partition.sh` | Separate offline file generation from runtime activation. Never use host PCI/display/resctrl observations to decide a baked target's contents. |

There is already good reusable practice: target display selection checks actual bound GPU drivers (`post-install/20-desktop.sh:487`), network rules use device properties, RTC logic checks available devices, and console sizing uses display information. Extend those patterns rather than adding more machine-name branches.

Systemd unit conditions and udev activation can replace some repeated service-side probing, with topology-aware helpers for complex cases. They do not repair a controller that fails to enumerate before d-i can read the media; nor should a systemd-dependent helper be injected into d-i's different runtime. See upstream [unit conditions](https://www.freedesktop.org/software/systemd/man/devel/systemd.unit.html).

## 5. Per-patch review against newer upstream d-i

This is a removal-candidate inventory, not a declaration that “new Debian fixes everything.” Every retirement needs the exact pinned runtime tested. Forky is rolling; a September source change need not exist in the August ISO.

| Local transform / reason | Upstream assessment | Disposition for Forky-only |
| --- | --- | --- |
| Trixie debootstrap/libzstd/liblzma graft into Bookworm, while retaining old bootstrap-base ABI (`build/build-iso-di.sh:953`) | Current Debian debootstrap is substantially newer; Forky already bypasses this branch. Local comments explain the old glibc mismatch. | **Remove from active Forky profile.** No need to transplant old ABI constraints into a new runtime. Keep historical recovery inputs separately until qualification completes. |
| Full-mode debootstrap replacement for squashfs deployment (`:1056`) | Native Debian debootstrap creates a package-based root; it does not implement NCZ's prepared layer contract. | **Retain NCZ deployment integration.** Later package it as a small versioned installer component rather than editing broad upstream scripts. This is product behavior, not a Bookworm workaround. |
| usr-merge/functions wrapper and `gutsy` gnupg/coreutils/dbus bootstrap edits (`:1694`) | Debian's native `sid`/`debian-common` path manages Debian bootstrap and usr-merge; the local work targets a foreign Ubuntu recipe. Reviewed [debootstrap revision](https://salsa.debian.org/installer-team/debootstrap/-/tree/04b7f139adc1fd722d707f8bc261001ef6fca9c9). | **Strong removal candidates for native Forky bootstrap.** Full mode does not need the real recipe; thin/netinstall must switch and qualify the native recipe before deletion. |
| Static zstd and `.deb` member support (`:499`, `:599`, `:2884`) | Upstream debootstrap functions already handle `control.tar.zst`/`data.tar.zst` through `zstdcat` at the revision above. That does not establish the executable is present in d-i. | **Condition on the actual runtime closure.** Drop a private zstd build only after real archive extraction works under the pinned initrd PATH/loader. If retained, lock source hash/toolchain and target architecture. |
| Expand `.ko.xz` modules before installer cpio (`:2529`) | [kmod 34.2-2 packaging](https://salsa.debian.org/debian/kmod/-/blob/627679a9d9cbb8549cb84934ed7d7423d802f7a6/debian/rules) enables xz for the udeb build, but disables zstd/zlib there. Its changelog also addresses compression-library inclusion. | **Candidate for removal for xz only**, after identifying the actual module loader and library closure in this initrd. Normal kmod feature support is not sufficient evidence. Do not infer `.ko.zst` support from tar.zst support. |
| Avoid overlaying a bare `/lib` directory onto Forky's usr-merge link (`:2647`) | This is a constraint on our cpio producer, not an upstream d-i defect. | **Retain artifact-shape validation.** Audit all archives; do not replace the symlink. |
| Newt binary color/branding patch calibrated to Bookworm (`:2668`) | Code already skips the binary patch outside Bookworm; `NEWT_COLORS` remains a separate configuration mechanism. | **Delete Bookworm binary patch from the Forky profile.** Retain data-driven branding as desired. |
| Extend disk-detect wait and load NVMe/virtio/storage modules (`:2054`) | [hw-detect revision aeb3b425](https://salsa.debian.org/installer-team/hw-detect/-/blob/aeb3b42588c6e0fdc40c2ab46d8beb6aa19d56ad/disk-detect.sh) still uses a 15-iteration, 2-second wait. It does not contain the local NVMe host/module additions. | **Not shown obsolete upstream.** Preserve as a candidate Sky1 overlay and measure removal. Use an absolute elapsed deadline: 90 loops with a possible 10-second settle each is not a reliable “180-second timeout.” |
| Early USB rescan plus later preseed/target recovery helpers (`:2959`; `preseed/usb-rescan.sh`; hook 41) | Reviewed generic hw-detect source does not establish a fix for the documented CIX controller behavior. No matching upstream fix was established. | **Retain pending O6N A/B evidence**, restrict by proven hardware topology, preserve active-storage guards. A generic udev settle is not evidence of equivalent recovery. |
| Neutralize flash-kernel/GRUB/no-bootloader scripts (`:1928`) and preseed systemd-boot skip | Upstream [systemd-boot-installer eligibility](https://salsa.debian.org/installer-team/systemd-boot-installer/-/blob/a8ab1871c9d57bfd46b3d9346fc7ef404d6513b2/debian/isinstallable) honors its skip setting. Inspected GRUB eligibility also honors `grub-installer/skip`. | **Prefer supported policy knobs** already present in preseed, then test whether package surgery can go. This is rEFInd ownership, not a Forky defect. Flash-kernel/no-bootloader removal remains separately unproven. |
| Scale finish-install progress to 100 units and long late-command progress (`:2246`) | [finish-install revision b1e4a7a3](https://salsa.debian.org/installer-team/finish-install/-/blob/b1e4a7a3eb4f87c7e747cc6eebcb9f4a96a329c5/debian/postinst) still accounts by script. | **NCZ UX integration remains**, unless the progress protocol is deliberately redesigned. It is not made obsolete by selecting Forky. |
| DNS writer/udhcpc overrides in `preseed/sshd-watcher.sh:234` | [netcfg revision 8f31cdf3](https://salsa.debian.org/installer-team/netcfg/-/blob/8f31cdf30de93c67928e2eacf722a7f7e26c4594/dhcp.c) handles DHCP nameservers and resolver writing. That does not prove the reported local failure fixed, or justify continuous resolver overwrites. | **Test deletion independently.** Prefer normal DHCP/preseed policy; retain a bounded diagnostic fallback only if reproduced. Test DHCP DNS, no DNS, offline mode and recovery after link changes. |
| Skip popularity-contest to avoid late debconf/fd problems (`preseed/sshd-watcher.sh:198`) | Inspected upstream [90popcon](https://salsa.debian.org/installer-team/pkgsel/-/blob/master/pre-pkgsel.d/90popcon) still installs the package then purges nonparticipants. Local comments describe a Forky failure, not merely Bookworm history. | **Do not label obsolete because of suite change.** Reproduce with correct debconf descriptor ownership; use supported selection/policy where possible. |
| Firmware reinjection and wireless module/payload changes (`:839`, `:2567`, `:2896`) | The builder deletes the substrate firmware tree before adding selected content. Newer Debian firmware availability alone cannot make locally removed files reappear. | **Keep an explicit firmware/module closure**, then remove duplicate vendoring only when the pinned upstream artifacts demonstrably supply it. Preserve the September all-architecture Wi-Fi fix. |

A patch ledger should record input package/version/hash, exact preimage or supported API, reason, target profile, regression test and removal condition. Fail closed if a textual patch no longer matches. Versioned, locally built udebs with provenance are preferable to unverified sed edits when a real Debian component change remains necessary; they still require regression tests and do not become “stock.”

The retired `preseed/locale-keyboard-chooser.sh:2` already says native localization replaced it. It is not a current blocker. Archive/remove that inactive implementation and the inactive extraction twin only after preserving the live-path tests and explanatory history.

## 6. Installer and target streamlining priorities

### 6.1 Make completion reflect the installed system, not one EFI filename

`preseed/late.sh:1104` considers a fallback EFI file or even `refind.conf` enough for its `ncz_bootable` predicate. `:1165` accepts either run-all success or that predicate; `:1420` can translate a nonzero result into success when root mode passes and boot files exist. This is intentionally independent of efivars, but it can also hide failures unrelated to efivars.

Retain the correct principle—Sky1 need not successfully write NVRAM—but replace the broad success override with explicit outcomes. Required kernel/initramfs/ESP/partition/root-mode failures must remain fatal. An unavailable optional NVRAM write is its own tolerated result. A configuration file is not proof of a FAT ESP, correct EFI architecture, valid kernel or successful boot.

The generated plan should define criticality by selected capability: a requested accelerator with no valid module or a requested rescue system without its own bootable root is not silently optional. `post-install/run-all.sh` already has critical-step handling; reconcile it with the late wrapper instead of adding another regex over logs.

### 6.2 One final kernel/initramfs/ESP transaction

Dracut is already the selected target mechanism (`post-install/94-dracut-config.sh:115` records the prior O6N work). Yet kernel installation pulls initramfs-tools (`post-install/10-our-kernel.sh:131`), boot hygiene/splash hooks manipulate its paths (`post-install/58-boot-hygiene.sh:212`; `post-install/60-boot-splash.sh:246`), and hook 94 later replaces it. The main rEFInd hook correctly runs through run-all's EXIT trap after the optional accelerator/dracut phase (`post-install/run-all.sh:386`, `:612`), rather than in filename order. However, `preseed/late.sh:971` can still apply NPU modules after that final bootloader pass has completed. Earlier package hooks may also refresh boot assets during kernel installation.

Define one finalization dependency chain:

`locked kernel packages + matching headers → all four overlay results + firmware + ACPI/GPU config → depmod → dracut for every declared KVER → verified /boot and ESP copies → rEFInd configuration → final receipt`.

The checklist's closed set is **mali/panthor GPU, cix-vpu-driver, cix-gpu-kmd and cix-npu-driver**: all four must be rebuilt for each new kernel version with headers from the same kernel build. A required in-tree driver/configuration change requires an actual kernel rebuild; changing an overlay alone cannot satisfy it.

No later hook may change a module, firmware dependency or initramfs configuration without invalidating this receipt and repeating the necessary finalization. Validate module ELF build IDs, the ESP initrd's GPU blacklist and retained `linlon-dp`, and the exact kernel identities. File mtimes, directory existence and `dkms status` are insufficient.

`post-install/11-fix-cixmini-boot.sh` repairs a package that still writes systemd-boot state. Move the rEFInd integration into the maintained package's proper lifecycle hooks, test install/upgrade/removal, then retire the self-healing rewrite. Do not remove it first merely because rEFInd is now policy. Replace mtime-based selection (`:97`) with manifest identity.

`post-install/10-our-kernel.sh:215` prunes other kernel/module trees, while its optional second-channel path at `:355` still handles raw experimental artifacts. These need reconciliation with the binding package-delivery and fallback-preservation rules. Use coinstallable versioned kernel packages and channel metapackages; preserve rescue/fallback entries, using additions or `.disable` changes as directed. Bookworm removal does not authorize deleting them.

### 6.3 Reduce install-time repair and mutable downloads

Vendor hook 25 repacks/adjusts maintainer scripts and performs forced dependency handling and broad package cleanup (`post-install/25-cix-proprietary.sh:221`, `:355`, `:398`, `:427`). Move deterministic package adaptation into reviewed build-time packages and solve their dependencies before image assembly. Keep only truly machine-specific configuration in late_command.

The Python/AI/application hooks still fetch mutable content or maintain overlapping environments: `post-install/40-claude-code.sh`, `46-python311.sh`, `47-embedkit.sh`, `47-llm-stack.sh`, and `88-noe-umd-venv.sh`. The older Python and Debian-13 SDK ABI choices can be real vendor requirements; they are not proof the entire OS must be Bookworm. Preserve required ABIs in locked environments with a wheel/artifact manifest. Do not replace them blindly with testing's default Python.

A full offline release should install its selected features without live npm/pip/uv/vendor/Apple downloads. T2 hook 55's online recovery download and desktop-only gating (`:81`, `:167`) need a deliberate firmware artifact/profile contract. Firmware availability should follow hardware capability, including headless installations.

### 6.4 Keep hardware activation out of layer baking

The layer builder binds host kernel interfaces into chroots. Hooks that probe GPUs, mount resctrl, write sysfs or run service logic can act on the host or infer the wrong target. Split each hook into offline generation, install-time disk/identity setup, and runtime hardware activation. The active hook plan must distinguish these contexts explicitly.

Do not replace every script with a systemd service: partitioning and offline target population remain installer work. Use runtime oneshots/udev for actions that require the installed kernel's hardware view. `post-install/87-mpam-cache-partition.sh` and CPU-idle policy in `85-power-perf-mode.sh` are concrete candidates for platform-scoped runtime activation.

### 6.5 Small modernization cleanups with real consequences

- `post-install/50-brand.sh:60` writes Ubuntu identity fields despite a Debian base. `post-install/54-gpu-accel.sh:101` can derive a Debian repository suite from branded `VERSION_CODENAME`. Preserve NCZ branding while using explicit base identity for repository policy. Vendor repository labels such as jammy in GPU tooling are separate ABI contracts, not evidence of an OS pivot; validate and lock them separately.
- Display hook 22 still writes Xorg/seat policy while the main desktop path uses the newer stack. Separate proven display-selection work from obsolete desktop-manager configuration; do not delete all GPU handling as “legacy.” `post-install/46-ncz-cli.sh` and `48-server-variant.sh` also retain older display-manager lists; diagnostics in hook 99 still emphasize bootctl despite rEFInd policy.
- `post-install/32-quadlet-shim.sh` is effectively inactive compatibility code. Removing it and retired localization code is lower risk than rewriting functioning hardware hooks.
- `post-install/39-usb-gpt-autofix.sh:31` repairs GPT on broadly selected USB devices. Correct ISO backup-GPT generation in the writer, as the prior design requires; restrict any recovery tool to positively identified media or an explicit operator repair. Runtime repair is not a substitute for correct image mechanics.
- `post-install/72-rescue-partition.sh:64` can fall back from a label to a spare partition and format it. Carry the installer's selected partition identities through a sealed result record; do not rediscover a rescue destination by guessing. Preserve the independent rescue system.

## 7. Bookworm-free reproducibility: what must actually be pinned

Keep `NCZ_BASE_MIRROR_SNAPSHOT=20260920T203924Z` (`release.conf:26`). “Forky only” means a declared snapshot and artifact set, not whatever testing serves on build day. The deliberate expiry exception remains scoped to historical snapshot metadata; signature verification remains enabled.

Use separate, related locks:

| Lock | Required identity |
| --- | --- |
| Installer substrate, per architecture | Immutable ISO/netboot artifact hash, source URL/archive location, authenticated checksum provenance, d-i package and udeb versions, installer kernel ABI |
| Target distribution | Forky snapshot, components, architecture, signed Release/index identities and complete package closure |
| Sky1 kernel/accelerators | Actual source tree/SRCREV, applied patch count/config, kernel/header build identity, all four per-KVER overlays, firmware and build IDs |
| Other platform/vendor inputs | T2 firmware, vendor SDK, application binaries/wheels and any compatibility repositories, each with version/hash/licensing provenance as applicable |
| Build tools | Container image digest, mkosi/mmdebstrap/squashfs/xorriso/tool versions and cross-toolchain identity |

The installer and target need compatible, independently recorded inputs; identical suite names are not sufficient. Udebs must match their initrd ABI and package set. The upstream [Forky preseeding manual](https://www.debian.org/releases/forky/arm64/apbs04.en.html) distinguishes installer-component and target mirror suites.

Concrete gaps:

- The Makefile combines a fixed SHA with a rotating weekly URL (`Makefile:63`, `:88`, `:111`). It should fail when those differ, as intended; retain the original artifact in an immutable store instead of silently updating the hash.
- `ensure_udeb` downloads from a live package index (`build/build-iso-di.sh:714`). A hash from that index alone is not a signed Release-to-package provenance chain. Resolve missing udebs from the locked installer universe rather than importing arbitrary current ABI dependencies.
- `post-install/23-base-apt-sources.sh:41` writes the snapshot URI but not the corresponding deb822 expiry exception. Carry it consistently into target APT, including after the snapshot has aged. Test this rather than relying on a fresh timestamp.
- Rescue and management-container producers still use independent debootstrap paths (`build/build-rescue-rootfs.sh:111`; `build/build-mgmt-rootfs.sh:100`). Their source/expiry/component handling should use the same release contract. The management producer constructs `forky-updates`/`forky-security` style pockets (`:103–105`); verify availability explicitly instead of mechanically deriving stable-release pocket names for testing. The rescue producer already documents and avoids the same missing testing-security-pocket failure (`build/build-rescue-rootfs.sh:48`); the management producer has not adopted that correction. This review did not independently fetch those Release files.
- Mutable `debian:$NCZ_BASE_CODENAME` container tags and builder package installs remain (`build/build-role-delta-mkosi.sh:435`; `build/build-base-rootfs.sh:145`). The snapshot does not lock those tools or vendor inputs automatically.
- Source hooks can reintroduce network repositories after a builder starts with an offline source configuration. Validate the finished source set and prove the full selected installation under network isolation.

Installed-system OTA policy is a separate decision from build reproducibility. Do not accidentally turn a release snapshot into permanent unmaintained update policy, or loosen the build lock merely to enable updates. Declare both policies explicitly.

An active-input audit must cover release CI, all supported modes, rescue/container producers and tools, not just grep comments for “Bookworm.” Historical documents, an archived fallback ISO and a compatible old vendor library do not constitute an active Bookworm bootstrap dependency. No unavoidable active Bookworm target dependency was found in the reviewed execution paths.

## 8. Tool choices: modernize the boundary that is actually redundant

### mmdebstrap versus ISO extraction

mmdebstrap already produces the target base. Its purpose is a Debian root filesystem/package bootstrap; it does not directly recreate d-i's initrd, udebs, media retrievers and bootable netinst layout. Replacing `7z` substrate extraction with mmdebstrap would remove a useful upstream installer artifact and create new assembly work, not deduplicate an equivalent operation. See the upstream [mmdebstrap manual](https://manpages.debian.org/testing/mmdebstrap/mmdebstrap.1.en.html).

The worthwhile consolidation is the **other target-rootfs producers**: move rescue and management-container builds onto shared snapshot/architecture/toolchain helpers, while preserving their distinct package/features contracts. Later, a locked upstream netboot initrd/kernel plus an explicit udeb/media manifest could replace netinst extraction. That would require qualifying media detection/retrieval and firmware closure; it is not necessary to eliminate Bookworm.

### dracut versus initramfs-tools

The target has already chosen dracut. Finish that consolidation and verify its output; do not launch another generator migration. D-i's own initrd remains its upstream installer artifact plus explicit overlays. Rebuilding that runtime with target dracut is a different and unnecessary architecture change.

### rEFInd versus systemd-boot

Keep rEFInd on both architectures and UEFI only. This is the explicit September unification, not an unresolved default. Share boot manifest generation and package lifecycle integration while retaining binary/cmdline differences. The prior proposal to use rEFInd for **installer media** is separate: current media still has GRUB-specific assembly and gate assumptions.

Systemd-boot offers boot-counting and automatic boot assessment; these could reduce a future rollback implementation, but switching would require a new product decision and complete qualification of rescue/menu behavior. The current rEFInd hook explicitly documents the absence of automatic edge-to-stable boot counting (`post-install/70-bootloader.sh:66`). No bootloader change follows from selecting Forky d-i. See upstream [automatic boot assessment](https://systemd.io/AUTOMATIC_BOOT_ASSESSMENT/).

### Compression, tar and 32-bit legacy

There is no evidence of a supported 32-bit product path requiring preservation: the builder admits arm64/amd64. Avoid adding i386/legacy BIOS machinery. Foreign-suite bootstrap scripts and duplicated old desktop/initramfs logic are more material legacy than an archive format's age.

Gzip `-9 -n` for the installer initrd (`build/build-iso-di.sh:2889`) gives deterministic timestamps but costs CPU. Measure a faster level or a supported alternative only after checking the **installer kernel's** decompressor and boot path; do not infer support from the target kernel. Content-addressed reuse avoids repeated compression more safely than an unqualified format change. Squashfs/module/archive compression are separate capability checks.

`md5sum.txt` is a Debian media-integrity convention (`build/build-iso-di.sh:3750`), not the provenance mechanism. Keep SHA-256/signature-based artifact trust while retaining media checks required by the installer.

The checklist's ban on `tar -C /` into a live rootfs is binding for kernel delivery. Tar under `$WORK`, a temporary initrd tree, an unbooted target extraction path or a management container directory is not automatically that prohibited operation (`build/build-iso-di.sh:2520`; `build/build-squashfs-layers.sh:860`; `post-install/38-recovery-container.sh`). Those paths still need metadata/usr-merge validation. Raw kernel/module installation into the target, bypassing package ownership, is a separate lifecycle problem and should be replaced by package delivery even when it is not a live-host untar.

## 9. Relationship to the two existing designs

### Explicit amendments to the incremental-assembly design

The prior design's conservative initial Bookworm baseline (`2026-09-21-incremental-di-iso-assembly-design.md:76`) and open questions at `:661` were appropriate before resolving the historical evidence. This review **amends that recommendation**: qualify an immutable Forky substrate as the intended baseline; do not retain Bookworm as an architectural requirement based on TYDEUS phase 2. Retain a separately identified fallback only until qualification, without describing an unverified historical image as known-good.

The prior question about a literal full-mode Bookworm-to-Forky upgrade is resolved here: the reviewed code deploys prepared Forky layers directly. Non-full recipe debt remains separately identified. The casper USB panic constraint remains unchanged; Forky d-i is still real d-i and is not casper/subiquity.

The content-addressed graph and transactional writer otherwise stand:

- Replace the multi-suite import/graft branch with a per-architecture Forky substrate node and a smaller explicit patch set.
- Delete Bookworm-only debootstrap/library graft and binary-branding nodes from the active profile. Native Forky recipe cleanup can remove additional non-full transforms after qualification.
- Keep separate nodes for installer kernel/module overlays, full-mode deployment component, preseed/payload, complete deb+udeb closure and indexes, target layers, EFI assets and the desired media inventory.
- Keep content digests, architecture/mode/profile isolation, transform/tool versions, immutable outputs, reflink workspace use, cold/warm equivalence, failure recovery and final-image verification.
- Keep the whole-ISO rewrite/growth economics explicit. Fewer compatibility transforms reduce fragile work and cache dependencies; they do not eliminate multi-gigabyte layer writes or make xorriso edits automatically in-place.
- Preserve explicit appended-ESP reconstruction and valid backup GPT on warm assembly. Do not rely on the target USB repair service to correct image-writing errors.

A snapshot change still invalidates the target closure/layers it affects; it need not invalidate an unchanged independently locked d-i runtime. Conversely, an installer udeb/ABI change invalidates applicable initrd transforms even if target layers stay identical. “Both are Forky” must not collapse those identities.

### Keep mkosi's present scope

The [mkosi phase-2 design](2026-09-14-mkosi-phase2-design.md) scoped mkosi to layers, not final bootable ISO packaging. That decision still holds. Bookworm elimination supplies a newer **d-i substrate**, not a replacement for d-i's hardware/install interaction. The prior incremental writer already addresses final media assembly.

Expanding mkosi to a live ISO now would require rebuilding the d-i integration around another output format and requalifying boot/media behavior, without removing the Sky1 kernel or NCZ deployment requirements. No demonstrated benefit justifies reopening that scope in this migration. Improvements to pinned mkosi containers, package metadata preservation and shared layer receipts remain in scope.

### Guardrails apply to all proposed refactoring

A declarative hook plan, one live extraction implementation, changed bootstrap recipe or changed writer is a **mechanics change**. Each needs an explicit reason and separate review of mechanics versus contents (`docs/ISO-BUILD-GUARDRAILS.md:9–22`). Do not bundle these with a kernel promotion or desktop package refresh.

Preserve build-time validation of every layer root, the live BusyBox extraction gate after the full layer stack, the late root-mode gate and first-boot verification. Validate persistent journal entries for the new boot. A mode check on the base layer alone does not protect against a bad final hotfix layer (`docs/ISO-BUILD-GUARDRAILS.md:66–120`).

## 10. Qualification plan: exactly how to answer the remaining stock question

This is a proposed sequence, not authorization to run hardware tests. No test was run for this review. The operator's kernel checklist governs: O6N only for Sky1 metal boot validation, human supervision, no unattended reboot, no build/production-host boot testing.

### Stage A — establish immutable candidates and static contracts

1. Record the currently accepted ISO's hash and its real test receipts, if available. Do not infer acceptance from a Makefile comment.
2. Select and archive one Forky arm64 d-i artifact with authenticated provenance. Record its package versions and exact initrd; select an independent amd64 counterpart. Preserve the target snapshot `20260920T203924Z` for this comparison.
3. Inventory and diff every local d-i change. Identify which are product deployment, kernel integration, hardware workarounds and old-suite compatibility. Remove only the already inapplicable Bookworm branch initially.
4. Inspect the actual initrd's executable architectures, usr-merge shape, module loader/compression libraries, zstd availability, firmware and udeb ABI closure. Test missing modules and empty required inputs as failures.
5. Generate and inspect the literal full-mode extraction stub and selected hook plan. Prove root permissions, delta semantics, offline closure and no accidental foreign-architecture assets. Use the prior design's cold/warm inventory and image-geometry checks.

### Stage B — full virtual install and installed boot

Run per-architecture virtual gates, using QEMU emulation where native acceleration is unavailable. These test virtual hardware, never imply T2/Sky1 physical validation.

The existing arm64 gate rewrites GRUB/console/preseed settings and forces test options (`build/kvm-install-gate.sh:101`, `:120`, `:135`, `:197`, `:204`). Record the precise delta from the release ISO. Adapt it deliberately if installer-media rEFInd is implemented; do not silently test a different boot frontend. Replace broad process-killing behavior in `build/e2e-install-test.sh:19` with per-run process ownership before using that harness on a shared build host.

Required evidence for **both** install and installed boot:

- Successful installer start, media discovery and storage discovery; expected selected-component plan; structured required-hook outcomes, not a single old success regex.
- Offline full install with no accidental network repair; native recipe verification separately for every supported thin/netinstall mode.
- Actual GPT output, correct FAT ESP type/filesystem, selected disk identity, real `/boot/efi` mount source, rescue partition identity if selected, and filesystem UUIDs matching configuration. EFI files in an unmounted directory fail.
- Correct AA64/X64 removable fallback EFI executable and coherent rEFInd entries. Boot with a fresh variable store and installation media detached; do not depend on an old Boot0001.
- A real installed-kernel banner, expected root mount, root mode 0755 after all first-boot work, selected services healthy, persistent journal containing that boot, and independently usable rescue entry where selected.
- For target kernel artifacts: package ownership, matching kernel/header identities, all required per-KVER overlay results, dracut outputs and ESP copies validated by content/build identity. Required failures cannot be overwritten by an EFI-file-presence heuristic.

Exercise baseline full/headless and full/desktop, with and without optional rescue/management components, plus each still-supported non-full mode. Add SATA/virtio/NVMe virtual storage cases where relevant to separate generic recipe assumptions from the chosen virtual device. A separate kernel gate remains required; it does not substitute for an installed-disk boot gate.

### Stage C — controlled O6N comparison of d-i userspace

Hold the **same** known-intended Sky1 kernel, headers/modules, firmware, command line, target snapshot, USB device/port and target-disk plan constant. Verify the actual source tree/SRCREV, applied patches, all four overlays, CONFIG_MODVERSIONS and build IDs first. Do not combine this experiment with a kernel promotion.

Prepare two candidates:

- **F-stock-userspace:** pinned Forky d-i userspace with only required kernel/module/firmware substitution, product preseed/deployment integration and diagnostic capture. No disk-detect timing patch, early custom USB recovery, DNS writer, or other unproven hardware-internals patch. Log the unavoidable integration changes so “stock userspace” is not confused with an untouched Debian ISO.
- **F-retained-fixes:** the identical artifact plus the current applicable Sky1 d-i hardware fixes. Exclude Bookworm-only grafts in both candidates. Keep NCZ deployment and bootloader policy equal.

First perform human-supervised, non-destructive installer startup/media/storage observation on O6N. Ensure the test configuration cannot enter unattended partitioning or reboot. Capture firmware/kernel/ACPI/controller information and timestamped USB/NVMe events over the existing serial/diagnostic paths. Only after early behavior is understood should the operator conduct an explicitly designated-disk installation and supervised installed/rescue boot.

If F-stock-userspace fails and F-retained-fixes passes, add/remove one fix at a time to identify the necessary overlay. That outcome answers the main architectural question: **Bookworm can go; fully stock d-i userspace cannot yet replace the identified fix on this hardware.** Submit a narrow upstream fix where appropriate, with the topology and timing evidence.

If both pass repeated cold USB starts, relevant port/device variations, storage discovery and the complete installed/rescue boot sequence, retire the hardware patches proven unnecessary for that pinned profile. That establishes a qualified Forky userspace replacement for O6N, not universal Sky1 coverage.

If both fail, classify the earliest failing boundary: firmware/kernel startup, controller enumeration, media retrieval, d-i component execution, target extraction, partition/ESP layout, or installed kernel boot. Compare against a genuinely qualified baseline when available. Do not automatically blame Forky or restore Bookworm without locating the difference.

An untouched stock-kernel Forky ISO can be a separate diagnostic experiment if the operator wants it, but it is not a prerequisite for retiring Bookworm userspace and cannot waive the mandated Sky1 kernel pipeline. QEMU cannot detect the checklist's PCI-ID collision or prove accelerator binding. Physical amd64/T2 qualification also remains a separate, explicitly authorized platform plan; this review does not authorize booting another production/build machine.

### Stage D — retirement criteria

Bookworm leaves active production inputs only after:

1. Pinned Forky install **and installed boot** receipts pass for each released architecture/mode; incomplete modes are explicitly excluded.
2. Human-supervised O6N evidence covers the retained Sky1 support profile, with rescue/fallback preserved and actual bound accelerator drivers verified, not merely module presence or `card0` existence.
3. No active Bookworm bootstrap/udeb/container dependency remains in the released build graph; all source and tool locks are recorded and no live-mirror fallback can mask missing inputs.
4. Source comments, option names and qualification claims describe the actual Forky/runtime-to-prepared-target flow. A temporary deprecated `--bookworm-iso` alias may preserve caller compatibility; it must not imply the input suite.
5. The release receipt names remaining local d-i patches and their removal conditions. “Bookworm-free” and “unmodified Debian Installer” are reported as different properties.

## 11. Recommended order of work

| Order | Bounded change | Completion evidence |
| --- | --- | --- |
| 1 | Correct the evidence baseline and pin candidate substrates; reconcile misleading header/Makefile claims | Artifact/version manifest, accurate historical phase results, no behavioral change |
| 2 | Establish truthful install/boot/ESP gates and failure propagation | Deliberately broken partition, initramfs and required-hook cases fail; optional efivars absence remains tolerated |
| 3 | Qualify Forky with existing applicable Sky1 fixes | Virtual install+boot receipts, then supervised O6N evidence; no simultaneous kernel promotion |
| 4 | Remove obsolete suite-specific transforms; qualify native non-full recipe or retire those modes | Exact initrd/udeb diff and mode-specific receipts |
| 5 | Fix architecture/profile leakage and introduce one kernel finalizer | Clean arm64-only/amd64-only asset builds; per-KVER /boot/ESP identity checks; preserved rescue |
| 6 | Implement the prior incremental graph/writer against the simplified inputs | Cold/warm equivalence, content provenance, valid EFI/GPT geometry and measured reuse |
| 7 | Move deterministic package repairs/downloads into locked producers; consolidate rootfs helpers and hook ownership | Offline installation, unique context-aware hook plan, smaller late-command work, unchanged product/hardware behavior |

The principal uncertainty is now narrow and testable: **which Sky1-specific d-i userspace patches remain necessary on the selected Forky artifact?** The evidence does not support treating Bookworm itself as the hardware fix. It supports carrying forward the proven kernel/hardware knowledge while replacing the old installer substrate under controlled qualification.
