# r268audio release validation

Kernel change: meta-cix e4dbc94 on wip/gpt6astra/2026-09-07-dp-audio-eld, patch 0232 (ACPI PWM backlight supplier) plus retained 0231 (disconnected DP startup). Kernel release: 7.2.3-sky1-ncz. No hardware playback claim.

The isolated installer worktree is /home/jasonperlow/isobuild/cix-installer-eld-validation on ULTRA. Its output is assets/kernel/r268audio-7.2.3-sky1-ncz-20260907 and build/kernel-debs/*r268audio*. The shared installer's source, edge pointer and manifest were not changed by this worktree.

## Build-flow fixes

- Native fixdep/modpost are rebuilt using Kbuild host-tool rules, retaining target elfconfig.h and devicetable-offsets.h. The helper verifies all 7,410 header/config/symbol hashes remain unchanged. Neither modules_prepare nor syncconfig runs.
- Both release preparation and the generated headers-package postinst use this helper; the package declares gcc and python3 dependencies.
- The ABI gate runs after helper preparation and again after DKMS compilation. DKMS always receives the exact staged --kernelsourcedir and --force for same-KVER revisions.
- Panthor's completed DKMS build output is copied uncompressed into the staged module archive, followed by depmod against that private root. The build host need not have the target kernel installed.
- stage-kernel respects NCZ_INSTALLER_DIR and lists packages only when packaging actually runs. --skip-mali-build allows resuming after a successful Mali build without skipping Panthor.

## Verified

Full kernel bitbake build passed (904 tasks). Full release workflow completed: Mali build, staged assets, KVM boot/PCI gate, staged-header ABI checks, Panthor build, module dependency generation, kernel/header/boot packages, four accelerator DKMS source packages and strict manifest check.

The manifest reports one existing CONFIG_VIDEO_LINLON=m warning about the in-tree VPU driver; it is not an audio result. KVM/TCG boot tests reached the expected root-mount stop without a supplied root filesystem. These machines do not emulate Sky1's DP/audio/GPU devices.

Extracted the final image and headers packages on PROTEUS. The image contains pwm_bl with CIXH5041 support, Panthor, mali_kbase, memory_group_manager and protected_memory_allocator. Packaged Panthor SHA256 matches the completed DKMS build exactly:

c0518501176f6ade6b32b9fc978aaf7bad8235be618e5e6a9a763a334396bcdc

The extracted headers postinst passes bash syntax checking and invokes the packaged helper. Running that exact packaged helper on PROTEUS succeeded with all 7,410 header/config/symbol hashes unchanged; it also passed on ULTRA. This tests host-tool preparation, not the full target postinst or target DKMS packages.

## Trial side effects and cleanup

A top-level make scripts_basic experiment on r267 triggered syncconfig, failed on missing flex and removed generated autoconf.h. The original r267 staged headers were restored from their untouched headers tarball; the six checked identity/config hashes matched afterward. The failed experimental directory was retained separately; it is not used for shipping.

Two trial DKMS installations into private module roots nevertheless invoked Fedora's configured `dracut --regenerate-all --force` hook on ULTRA. Both hooks returned 0; no reboot or boot-default change was issued. The attempted CLI override did not suppress the outer post-transaction hook. The final workflow therefore uses only dkms build and exports its output, avoiding dkms install entirely. The final log has no post-transaction command, and its run did not update the earlier hook log.

## Hardware remains pending

O6 was not accessed or changed. O6N was used only for read-only queries; its latest preflight returned `No route to host`. No candidate has been installed there and no board was rebooted. After O6N is reachable and the operator is present, validate both Mali and Panthor boot entries, preserving rescue/default fallback. O6N can validate backlight/panel binding and audio regressions but cannot prove the five-link O6 recovery because its ACPI disables DP02.
