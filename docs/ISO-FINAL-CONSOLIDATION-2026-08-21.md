# ISO Final Consolidation - 2026-08-21

Host: TYDEUS
Repo: `/home/jasonperlow/work/cix-installer`
Final ISO: `build/nclawzero-installer-cixmini-2026.08.21-final.iso`

## Summary

This is the final consolidated 2026-08-21 ISO built from the TYDEUS
`~/work/cix-installer` clone. It keeps the clean edge-only kernel manifest
state from this clone, verifies that the Mali/Panthor overlays are present for
bare kernel version `7.2.0-sky1-ncz`, includes the gap-closure firmware and NPU
asset staging, and stages the newer sensors-fixed Singularity desktop package.

Final ISO:

- Path: `/home/jasonperlow/work/cix-installer/build/nclawzero-installer-cixmini-2026.08.21-final.iso`
- Size: `3954520064` bytes
- SHA256: `8401647006204fbc74f10faf8b0e76e4dfcc3e155c442f219a1bf46a7fa0ce1a`

## Part A - Builder Audit

### Kernel Manifest Check

`build/kernel-manifest.py check` was read end to end with the ISO build wiring
in `build/build-iso-di.sh`.

Findings:

- The edge kernel variant maps to `assets/kernel/edge`.
- The checked kernel version is read from `assets/kernel/edge/KVER`; the
  current value is the bare KVER `7.2.0-sky1-ncz`.
- GPU overlay presence checks use
  `assets/kernel/mali/7.2.0-sky1-ncz/` and
  `assets/kernel/panthor/7.2.0-sky1-ncz/`, not stale `rc5`, `rc6`, or `rc7`
  path names.
- Overlay vermagic checks run `modinfo -F vermagic` over each staged
  out-of-tree `.ko` and require the returned vermagic to match the directory
  KVER.
- In `build/build-iso-di.sh`, `STRICT_MANIFEST` defaults to `1` for
  `MODE=full` and `VARIANT=desktop`.
- The only ISO-level bypass is an explicit `STRICT_MANIFEST=0`; the final ISO
  was built and checked with `STRICT_MANIFEST=1`.

The strict manifest check is checking the correct KVER/path shape for the GPU
overlay requirement.

### Strictness and Bypass Search

I searched `build/` for `STRICT_MANIFEST`, `MANIFEST_STRICT`, `--force`, and
`--skip-manifest`.

Findings:

- `build/build-iso-di.sh` runs the manifest check in strict mode by default for
  the full desktop ISO path.
- `build/build-kernel-debs.sh` has its own permissive path, but that is not the
  full desktop ISO manifest gate used for this final ISO.
- No hidden `--skip-manifest` path was found in the ISO builder.

### Squashfs Layer Builder

The squashfs builder itself was audited by reading
`build/build-squashfs-layers.sh`, rebuilding the base and desktop layers, and
inspecting the resulting archives.

Actual builder issues were found and fixed:

- Root ownership guard: a previous `base.squashfs` had critical rootfs paths
  such as `/`, `/etc`, and `/var` owned by UID/GID `1000:1000`. That makes
  package maintainer scripts such as `systemd-tmpfiles` and `dbus-daemon`
  fail with unsafe path transitions. The builder now refuses to chroot into a
  base or desktop lowerdir unless `.`, `etc`, `usr`, `var`, and `var/lib` are
  `0:0`.
- Missing dependency declaration: the builder used Python for validation but
  did not declare `python3` as a required tool. It now does.
- Overlay metacopy materialization: overlayfs can place
  `trusted.overlay.metacopy=y` files in the upperdir with data still read from
  the merged lower view. The builder strips `trusted.overlay.*` xattrs before
  `mksquashfs`, so those files could become zero-byte files in the published
  desktop delta. The builder now materializes metacopy files from the merged
  view before unmounting and squashing. This directly prevents zero-byte
  outputs such as `/var/lib/dpkg/status`.

Layer rebuild results:

- `assets/squashfs/base.squashfs`
  - Size: `677781504` bytes
  - SHA256: `a951269dbd1133f5433f9dbe27d2a3c74d597449c26326ec3598dc3ec62eebce`
- `assets/squashfs/desktop.squashfs`
  - Size: `2034659328` bytes
  - SHA256: `8c60684e96dc19df025263ade39f1fb2ae865338d5ae3172a479d50ae2a1b891`

Post-rebuild checks:

- Critical rootfs paths in both layers are root-owned.
- The full extracted desktop rootfs has a non-empty
  `/var/lib/dpkg/status`.
- The desktop rootfs contains `ncz-singularity-desktop` version
  `20260821+bk1~sensorfix1`.
- `/opt/singularity/bin/labwc` is present in the desktop rootfs.
- Staged `assets/wallpaper` content was present 1:1 in the desktop layer under
  `/usr/local/lib/cix-installer/assets/wallpaper`.

Conclusion: the manifest builder logic is sound for the GPU overlay check, but
the squashfs layer builder did have real correctness bugs. Those builder bugs
were patched before the final ISO was built.

## Part B - Consolidation

### Gap-Closure Fixes

The gap-closure commits from the separate TYDEUS clone were already ancestors
of this clone's `HEAD` when this consolidation began. I still verified the
resulting state instead of trusting ancestry.

Verified staged assets:

- Full `assets/sky1-firmware` restaging is present, including VPU codec `.fwb`
  files, `dsp_fw.bin`, `mediatek`, and `rtw89` firmware.
- NPU-related CIX packages are staged, including `cix-ai-engine`,
  `cix-ai-test`, `cix-npu-driver-dkms`, `cix-npu-umd`, and the matched
  `cix-noe-umd` package.
- The pre-Q2 `cix-noe-umd_2.0.2` package is not staged by the final ISO path.
- `post-install/88-noe-umd-venv.sh` targets
  `3.1.4-cixdeb13-260714`, matching the current NOE KMD/UMD ABI stack.

No conflicts were introduced in this clone by the gap-closure work; it was
already linearly present below `545ca0b`.

### Singularity Desktop Sensor Fix

The requested sensors-fixed version is
`ncz-singularity-desktop_20260821+bk1~sensorfix1_arm64.deb`.

The artifact already present on TYDEUS was not safe to stage as-is: it was
larger than the prompt's recorded size but incomplete, and did not contain
`/opt/singularity/bin/labwc`. To avoid shipping a desktop package that would
drop the compositor/session payload, I repaired the package by overlaying the
sensorfix package contents onto the last complete
`20260820+bk0~g19e6662ffff0` package payload, preserving the newer package
version `20260821+bk1~sensorfix1`, recalculating `Installed-Size`, and
rebuilding the `.deb`.

Repaired and staged package:

- Mirror path:
  `build/forky-vendor-mirror/pool/main/n/ncz-singularity-desktop/ncz-singularity-desktop_20260821+bk1~sensorfix1_arm64.deb`
- Also staged in:
  `build/forky-mirror/pool/main/ncz-singularity-desktop_20260821+bk1~sensorfix1_arm64.deb`
- Size: `11391102` bytes
- SHA256: `3f7c633738d9d29e6d8306f027ab1d9ecd39f861f2b0c853da06f70ff291cfce`
- Verified contents include `labwc`, `singularity-desktop`,
  `singularity-greeter`, and `singularity-labwc-session`.

Both vendor mirror package indexes were regenerated after staging.

### Author Packs

I checked the author-pack documentation and the wallpaper rotator path. The
rotator discovers installed packs dropped into `/usr/share/backgrounds/`
without requiring an ISO rebuild.

Decision: do not bake the session's collection-only author-pack experiment
into this final ISO.

Rationale:

- The live O6N author packs were created directly on that host's live
  filesystem, not as complete repo-staged image payloads in this clone.
- The NCZ/Singularity first-party assets already ship through the existing
  repo paths.
- The Brandon Perlow pack is real user-facing content, but the complete
  10-image payload was not present in the repo/ISO source tree on TYDEUS.
- Baking only collection metadata into the ISO would advertise collections
  whose image payload was not guaranteed to exist on a fresh install.
- The correct path for those live-created packs is the existing runtime/OTA or
  content-package drop-in path under `/usr/share/backgrounds/`.

The collection-only experiment was preserved in a git stash and was not
included in the final ISO.

## Final Manifest and GPU Evidence

Strict check command:

```sh
STRICT_MANIFEST=1 python3 build/kernel-manifest.py check
```

Result:

```text
WARN: [edge] CONFIG_VIDEO_LINLON=m is IN-TREE in assets/kernel/edge/config-7.2.0-sky1-ncz - accelerators must ship out-of-tree (an in-tree copy masks the validated overlay/DKMS module at modprobe time)
manifest check OK (1 warning(s))
```

This is a real strict PASS. No `STRICT_MANIFEST=0` bypass was used.

Direct staged GPU module check:

```text
assets/kernel/mali/7.2.0-sky1-ncz/mali_kbase.ko 2089808
assets/kernel/mali/7.2.0-sky1-ncz/memory_group_manager.ko 30888
assets/kernel/mali/7.2.0-sky1-ncz/protected_memory_allocator.ko 23448
assets/kernel/panthor/7.2.0-sky1-ncz/panthor.ko 406320
```

`modinfo -F vermagic` for those modules returns `7.2.0-sky1-ncz`.

Direct ISO-internal check:

```text
/cixmini/assets/kernel/mali/7.2.0-sky1-ncz/mali_kbase.ko 2089808
/cixmini/assets/kernel/mali/7.2.0-sky1-ncz/memory_group_manager.ko 30888
/cixmini/assets/kernel/mali/7.2.0-sky1-ncz/protected_memory_allocator.ko 23448
/cixmini/assets/kernel/panthor/7.2.0-sky1-ncz/panthor.ko 406320
/cixmini/assets/cix-debs/cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz1_arm64.deb 94136
/cixmini/assets/cix-debs/cix-npu-umd_3.2.0-cixdeb13-260714_arm64.deb 375880
```

## Final ISO Build

Build command:

```sh
STRICT_MANIFEST=1 bash build/build-iso-di.sh \
  --bookworm-iso downloads/debian-testing-arm64-netinst.iso \
  --root /home/jasonperlow/work/cix-installer \
  --version 2026.08.21-final \
  --output build/nclawzero-installer-cixmini-2026.08.21-final.iso \
  --mode full \
  --variant desktop
```

The build completed successfully with strict manifest enabled.

Secret scan:

```text
GATE: PASS - no credentials in shippable artifacts
```

## Install Gate

Command:

```sh
bash build/kvm-install-gate.sh build/nclawzero-installer-cixmini-2026.08.21-final.iso
```

Phase 1 result:

```text
ended   19:31:27Z  (qemu rc=0)
install completed without a failed hook
```

The installer completed all post-install hooks without a failed hook. The gate
progress reached the CIX proprietary, NOE UMD venv, NPU embed server, Mali GPU,
Panthor GPU, DKMS registration, dracut, console font, and bootloader hooks.

Phase 2 result:

The installed NVMe target did not hand off to a kernel banner. The firmware
serial log showed:

```text
BdsDxe: starting Boot0001 "UEFI QEMU NVMe Ctrl ncztest01 1"
Synchronous Exception at 0x000000013BDE3194
```

The gate exited with:

```text
qemu rc=0
GATE FAIL: installed system produced no kernel banner - bootloader did not hand off (see /home/mini/cix-installer/build/kvm-install/boot.log)
```

This is the same separate installed-boot path class already documented for the
KVM gate; it is not a manifest or asset-staging failure. Phase 1 is the
relevant post-install-hook coverage for this consolidation task and passed.
