# Kernel policy: ONE unified 7.3 kernel on every arch (no 7.2.x, no edge)

Operator decision 2026-10-05 (evening). Supersedes the same-day morning policy
(`STABLE_BASE=7.2.9`, `EDGE_BASE=7.3.0-rc6`) and the 2026-09-30
`docs/reports/2026-09-30-kernel-default-policy.md` "default is never an -rcN"
rule, which the operator explicitly overrode for this cycle. Decision record:
`~/.claude/projects/-Users-jasonperlow/memory/project_unified_kernel_7_3_decision_2026_10_05.md`.

Operator, verbatim: *"move to 7.3 as our unified kernel ... now that we know we
can boot and run in a stable fashion on the T2 systems and also Sky1."* and,
correcting the first draft: *"not even 7.2.9 rescue. One kernel, and rescue has
blacklist of accelerators"*.

## Rule

| | version | boots as |
|---|---|---|
| default boot kernel | **7.3**, pinned per arch | graphical default on T2 Macs + generic PC (amd64) and Sky1 (arm64) |
| installer boot kernel | **7.3**, same pin | installer media on both arches |
| RESCUE | **the SAME pinned 7.3 kernel** | a separate rEFInd entry that loads the default KVER with the accelerator drivers blacklisted |
| edge | **does not exist** | removed (no separate edge entry, no edge assets, no edge KVER sidecar) |

- 7.2.x (including 7.2.9) is retired everywhere: no default, no rescue, no
  edge, no installer.
- ONE kernel is shipped. There is no second kernel line and no
  `RESCUE_BASE`/`EDGE_BASE` series of its own.
- Today the pins are the release-candidate builds, replaced by 7.3.0 final
  builds later:
  - amd64: `7.3.0-rc6-4-t2-edge-aer9010` (the T2 kernel with the plain
    revert of `eddba19b8b5f`, "PCI/AER: Support Advisory Non-Fatal Errors",
    and no Apple-only quirk; `CGROUP_DMEM` off; nouveau fix 9012) —
    `assets/kernel/amd64-stable/KVER`. Operator decision 2026-10-06, after
    Alex Deucher reported on LKML that the commit breaks non-Apple boards
    too: revert it, and remove the other T2 power-cut mitigations (the 9011
    quirk build `7.3.0-rc6-3-t2-edge-aer9011` and `pcie_ports=compat`).
    The verifier refuses an `aer9011` pin. Details:
    `docs/reports/2026-10-06-amd64-rc6-4-aer9010.md`; earlier history:
    `docs/reports/2026-10-05-amd64-edge-rc6-revert.md`.
  - arm64/Sky1: `7.3.0-rc6-sky1-ncz` (r284) — `assets/kernel/mainline/KVER`
    and `variants.mainline.kver` in `assets/kernel-manifest.json`.
- The rescue entry is *redefined*, not removed: the "never delete a rescue
  entry" rule is satisfied by booting the same kernel with the accelerators
  blacklisted, not by retaining an old known-good kernel.

## Why

Two shipping kernels double the test matrix and 7.2.9 stops receiving upstream
security fixes within weeks of 7.3.0. 7.3 has booted and run stable on T2 Macs
(MEDUSA) and on Sky1 r282. 7.3.0 final is expected ~2 weeks after rc7 (~2026-10-11,
likely the last RC); 7.2.x is legacy/EOL; the LTS is undecided (probably 7.4).

## Rescue: same kernel, accelerators blacklisted

The single RESCUE entry loads the same `/vmlinuz-<default-KVER>` as the default
entry. Its only difference is a `module_blacklist=` command line derived from the
real accelerator driver set of each arch (encoded machine-readably in
`assets/kernel/KERNEL-POLICY`):

- **arm64/Sky1** — `RESCUE_ARM64_BLACKLIST`:
  `panthor,panfrost,mali_kbase,memory_group_manager,protected_memory_allocator,amvx,aipu,armchina_npu,cix_vpu,linlon_vpu`.
  Every GPU/VPU/NPU driver (and its aliases) is dropped. `linlondp` is the
  display controller and is never blacklisted; the console stays on the Sky1
  framebuffer. This is the same all-accelerators-off posture the rescue
  partition already used.
- **amd64** — target-aware, because the x86 kernel is unified for T2 Macs and
  generic PCs and the rescue entry must never be a black screen:
  - On an Apple T2 Mac the internal panel is wired to the AMD dGPU (this is the
    reason a dGPU reset takes a T2 MacBook down; see
    `~/.claude/projects/-Users-jasonperlow/memory/feedback_no_debugfs_gpu_reads_on_t2_hosts.md`
    and the live MEDUSA notes), so `amdgpu` is **kept** and only the other
    GPU/compute stacks are dropped — `RESCUE_AMD64_BLACKLIST_T2`:
    `nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nouveau,radeon`.
  - On a generic (non-T2) PC all discrete GPU stacks are dropped —
    `RESCUE_AMD64_BLACKLIST_GENERIC`:
    `amdgpu,radeon,nouveau,nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm` — and
    the console stays up via `simpledrm`/`efifb`/fbdev (or an unblacklisted
    iGPU), which is exactly the "working console/display" requirement.

  The T2/generic decision is made **on the target** by the DMI detector
  `assets/refind/ncz-t2-detect.sh` (cherry-picked from
  `feat/amd64-edge-compat-20261005`, tip 67b641a). It is the same detector that
  gates `pcie_ports=compat` onto the default entry on T2 only.

Both arches also keep the rescue-partition entry (`root=PARTUUID=<rescue part>`)
and the operator-staged `*-rescue` ESP sparing/auto-promotion safety net: those
still boot whatever kernel is staged in the rescue slot, but the *generated*
rescue entry is now the same-7.3-with-blacklist entry above.

## amd64: `pcie_ports=compat` moves to the DEFAULT entry (T2 only)

Operator directive 2026-10-05 (compat branch): the T2 PCIe mode
`pcie_ports=compat` (defence in depth on top of the AER fix, now the 9011
quirk) now applies to
the **default** 7.3 entry on Apple T2 hardware only — never on generic PCs, and
never on non-T2 Intel Macs, VMs or servers (where it would needlessly disable
AER/PME/native hotplug). It is gated at entry-generation time by the DMI
detector. See `docs/reports/2026-10-05-amd64-edge-pcie-ports-compat.md`.

## Enforcement

Implemented in this change:

- `assets/kernel/KERNEL-POLICY` is the machine-readable source of truth:
  `DEFAULT_BASE=7.3`, `RC_DEFAULT_ALLOWED=1` + `RC_DEFAULT_EXPIRY_NOTE=replace by
  7.3.0 final`, `RESCUE_SAME_KERNEL=1`, the per-arch rescue blacklists, and
  `EDGE_ENABLED=0`. `STABLE_BASE`/`EDGE_BASE` are gone.
- `build/verify-kernel-default-policy.sh` check 10 is rewritten: the default
  kernel on each arch must match `DEFAULT_BASE` (7.3); an -rcN default is
  allowed only while `RC_DEFAULT_ALLOWED=1` and the pin really is an -rcN (a
  stale allowance fails); any 7.2.x default or any staged 7.2.x asset fails; the
  rescue markers (same default KVER + the arch blacklist) are required; there is
  no edge channel to stage. `build/test-kernel-default-policy.sh` covers every
  path, including the "7.3 final with RC_DEFAULT_ALLOWED still 1" stale-flag
  failure and the "7.2.9 asset staged" failure.
- `build/verify-no-debian-kernel.sh` and the kernel-purity tests pin the
  expected KVERs to the unified 7.3 builds (no Debian kernel, no 7.2.9).
- `assets/refind/ncz-refind-refresh-amd64.sh` and `assets/refind/
  ncz-refind-refresh.sh` emit one default entry on the 7.3 pin, a console
  entry, and the same-kernel rescue entry with the blacklist; the amd64 edge
  entries and the `KVER_EDGE` plumbing are removed.
- `post-install/10-amd64-kernel.sh` installs the single 7.3 amd64 kernel;
  `post-install/10-our-kernel.sh` installs the single 7.3 Sky1 kernel; the 7.2.x
  and edge paths are gone.
- `build/stage-amd64-kernel.sh`, `build/publish-amd64-kernel.sh`,
  `build/verify-base-kernel-assets.sh`, `build/resolve-sky1-kernel-inputs.sh`
  and `build/preflight-freshness-gate.sh` carry the single 7.3 line only.
- `assets/kernel/edge` (symlink) and `assets/kernel/amd64-edge/` are removed;
  `assets/kernel/mainline` now points at the r284 7.3 build; the 7.2.9 overlay
  `.ko` mirrors are retired (history in git). Manifests:
  `assets/kernel-manifest.json` (Sky1 mainline = 7.3.0-rc6-sky1-ncz),
  `assets/kernel/amd64-stable-manifest.json`, `assets/kernel/sky1-manifest.json`.

## When 7.3.0 final lands (checklist)

1. Rebuild the amd64 kernel on 7.3.0 final (9011 AER quirk carried, unless
   upstream fixes ANFE on 106b:1802 first; 9010 stays held); Sky1
   7.3.0 final rebuild lands separately.
2. Repin `assets/kernel/amd64-stable/KVER` and `assets/kernel/mainline` (+
   `assets/kernel-manifest.json` / `sky1-manifest.json` /
   `amd64-stable-manifest.json`) to the final KVERs.
3. Remove the `RC_DEFAULT_ALLOWED=1` line (and its expiry note) from
   `assets/kernel/KERNEL-POLICY`; the verifier then refuses any -rcN default.
4. Restage the 7.3.0 final accelerator overlays under
   `assets/kernel/<drv>/<final-kver>/` and retire the rc6 mirrors.
5. Re-run the full lint + tests on HYDRA and the arm64 verifiers on ULTRA; then
   re-gate the image.
