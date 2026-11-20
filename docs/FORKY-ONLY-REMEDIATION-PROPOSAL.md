# Debian forky native package plan

Status: implementation proposal; no repository or package policy is changed by
this document. Debian forky only is the required end state. An allowlist entry
or a vendor-authored package does not establish Debian build provenance.

## Source inventory

The installer source currently configures two external package sources:

| Source | Installer path | Packages selected by the inspected code |
|---|---|---|
| Intel OpenVINO, suite `ubuntu24` | `post-install/lib/intel-accel.sh` | Versioned `libopenvino-intel-gpu-plugin-*` / `libopenvino-intel-npu-plugin-*`; NPU driver candidates when available |
| t2linux `t2-ubuntu-repo` | `post-install/55-t2-firmware.sh` | `apple-firmware-script`, `apple-t2-audio-config` on T2 hardware with the desktop option |

`post-install/lib/apt-separation.sh` lists additional T2 names for origin
pinning. That list is not evidence that every listed package is installed.
The same helper supplies the Debian GPU set: `intel-opencl-icd`,
`intel-media-va-driver`, `libze1`, and `libze-intel-gpu1` as appropriate.

Existing no-Ubuntu and provenance gates remain required. They do not prove
that a later hardware-specific install or deferred update obeyed the policy.
The `ubuntu24` suite name alone also cannot prove a package's build origin.
The installed package records and exact artifacts must be checked.

## Native replacement sequence

1. Capture each supported hardware path's resolved package names, versions,
   architecture, dependency closure, source revision, license, and artifact
   digest. Include deferred Intel installation and the T2 firmware/audio path.
   Record missing source or redistribution rights as unresolved gates.
2. Reuse byte-identical packages from the pinned Debian forky snapshot where
   available. For the remaining T2 helpers/audio configuration, identify the
   corresponding public upstream source and packaging at an exact revision;
   build in a clean pinned Debian forky environment. Preserve extraction,
   board-specific firmware checks, and audio configuration behavior.
3. For missing Intel OpenVINO plugins and NPU userspace, identify exact public
   source and packaging revisions and build their dependency closure for
   forky. Verify compiler, runtime ABI, Level Zero, and driver compatibility.
   Do not claim that changing a repository label rebuilds a binary.
4. Publish the resulting supported architecture packages through the normal
   reviewed package process. Verify repository indexes and downloaded package
   digests with a fresh client before changing installer resolution.
5. In a separate reviewed source change, replace the two external source
   paths with the native package set and tighten installed/deferred-source
   checks. Keep existing Debian GPU packages and device support intact.
6. Validate fresh installs and upgrades: T2 Wi-Fi/Bluetooth firmware and audio,
   Intel GPU acceleration, Intel NPU runtime, plus hardware without those
   features. Run install-option and provenance gates on both image arches.

This plan has not built or published replacements and has not validated device
parity. No feature removal or Ubuntu-built package exception is proposed.
Missing source, build failures, or failed device checks remain release gates;
they do not authorize silently dropping working firmware or acceleration.
