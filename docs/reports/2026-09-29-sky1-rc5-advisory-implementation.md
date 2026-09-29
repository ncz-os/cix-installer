# Sky1 7.3-rc5 advisory: implementation and verification (2026-09-29)

> **Addendum (later on 2026-09-29).** Operator decisions superseded
> "port only if the boot shows a problem". Native PCIe (the 0027 remainder
> plus 0029), the 0089 runtime-PM gate and uncompressed modules are now built
> as the test kernel **r279**. See
> `docs/reports/2026-09-29-sky1-r279-build.md` and
> `docs/SKY1-R279-SUPERVISED-BOOT-TEST.md`.
>
> **Correction:** "`cix_scmi_register_em()` has no caller" below is wrong.
> The caller is the out-of-tree mali DKMS (`mali_kbase_devfreq.c:772`), and
> the mali overlay imports the symbol.

The operator accepted the orchestrator's Sky1 rc5 advisory. This report
records what was implemented, what source verification showed, and where
that verification contradicts the advisory. Nothing was booted, flashed, or
rebuilt into an image.

## Provenance

| Item | Value |
|---|---|
| rc5 base | torvalds `v7.3-rc5` = `72d3fcf802c45d00b300f25b848a93c3a2bd7c7e` |
| port branch | `kernel-73rc5-port` @ `3da51e546c4b` (207 commits). It existed only in the ULTRA mirror `~/yocto-work/kernel-mirrors/linux-cix-kernel-73rc5-port.git`, although the recipe says it is pushed. It is now pushed to GitLab and ARGONAS `ncz-os/linux-cix`. |
| recipe | meta-cix `linux-cix-sky1-ncz_7.3-rc5.bb` @ `d3176d6`: rc5 plus ONE consolidated diff (`sky1-ncz-v7.3-rc5-port.patch`). The patch is content-identical to `git diff 72d3fcf8..kernel-73rc5-port`: both hash to `bd18ad5b...` after hunk-header context is normalized. |
| r278 | `kernel-staging/r278-7.3.0-rc5-sky1-ncz-20260927`. Its `Module.symvers` exports `fwnode_drm_find_panel` from vmlinux. |
| prior verdict shas | `7990b7823816`, `612fa439e76a`, `d2805910aa72` and `2f7770fee0b9` are not git objects in any tree examined. They were treated as unverified and not relied on. |

Structural finding: the 7.3 recipe has no per-patch `SRC_URI`. The 205 raw
7.2 patches are not applied; their surviving intent lives in the port
branch's commits. In the raw-replay reports, "drop patch N" means "patch N is
not re-applied". It does NOT mean "its content is absent", and much of it is
present.

## Per-decision results

### 1. 0027 / 0029: not re-applied. The advisory's mainline-coverage claim is contradicted.

- The mainline commits `b5672f9463f2` (HPA flag), `ea34744eb094` (HPA LTSSM
  debugfs) and `d70e964dc099` (LGA LTSSM debugfs) are all in rc5. They add
  generic HPA infrastructure only. They do not cover 0027.
- Of 0027's content, the port carries `cdns_pcie_hpa_host_restore()`
  (`65108d59b2be`), `register_syscore()`, and the LMR base block
  (`23d4657ab234`).
- The port is **missing** from 0027: `cdns_pcie_hpa_create_region_for_ecam`,
  `sky1_cdns_pcie_find_capability`, `sky1_lga_reg_offsets`, the
  `"sky1-pcie-cix"` driver rename, `devm_clk_get_optional` for axi and apb,
  and the `vendor-id`, `device-id` and `cdns,no-inbound-bar` ACPI properties.
  `git grep` finds 0 hits for each in the port and in rc5.
- Consequence: `pci-sky1.c` and `pci-sky1-cix.c` both register `"sky1-pcie"`.
  Both are `=y` in the r278 config, and `pci-sky1.o` links first. Under the
  shipped cmdline `sky1_pcie_native=off pcie_pnp_en` (both rEFInd entry
  types), PCIe uses the ACPI PNP0A08/ECAM host and the CIX native driver is
  not used, so the clash only logs one `already registered` line. Native mode
  would be broken.
- 0029 requires the CLKT clkdev bridge (`clk_get_sys(acpi_dev_name(), ...)`).
  The port's `sky1_pcie_parse_clocks()` is the plain `devm_clk_get` version.
- Action: no forward-port (class-c, human decision). The recipe comment
  records the verified state. Boot-sheet items D3-D7 gate it: root ports,
  NVMe, USB3, the 17cd:0100 binding, and the name-clash line.

### 2. 0058: dropped, and the only caller is re-aimed

- The only caller is `trilin_dp_probe()`, added by 0008. The forward-port
  `3d3bd1842516` exported `fwnode_drm_find_panel()` as a wrapper around the
  static, counted `find_panel_by_fwnode()`.
- **`devm_drm_panel_attach()` does not exist in v7.3-rc5.**
  `drm_of_find_panel_or_bridge()` exists, but it walks OF graph
  ports/endpoints from a `device_node`, not an `"edp-panel"` phandle. The only
  exported match is `of_drm_find_panel()`, which returns a counted reference
  since `b71a623598d3`. `61aebeadff40`, `b71a623598d3` and `ac3baea883da` are
  all in rc5.
- 0008 had three defects: it never put the fwnode reference, it never put
  the counted panel reference, and `edp_panel` stayed **uninitialized** when
  no `edp-panel` property exists.
- New commit: linux-cix `feat/sky1-rc5-advisory-2026-09-29` `ac358595495b`
  "drm/cix: trilin-dp: drop fwnode_drm_find_panel(), use counted OF lookup".
  - It adds the helper `trilin_dp_find_edp_panel()`: with no reference it
    returns NULL; for an OF reference it calls `of_drm_find_panel()` and
    releases the reference with a devm `drm_panel_put`; for an ACPI reference
    it warns and probes as standard DP (no ACPI panel provider is built,
    since `CONFIG_DRM_CIX_EDP_PANEL` is unset); it always calls
    `fwnode_handle_put()`.
  - `drm_panel.c` and `drm_panel.h` are now byte-identical to rc5.
- It is wired into the recipe as
  `0001-drm-cix-trilin-dp-drop-fwnode_drm_find_panel-use-cou.patch` (PR r2).
  `git apply --check` passes on the port tip.
- **Build and link proof.** This is a full verification build, not a staged
  artifact: host gcc 16.2.1, r278 config after `olddefconfig` with no
  non-compiler deltas, `make Image modules` with rc=0.
  - `Module.symvers` holds 0 lines for `fwnode_drm_find_panel`.
  - `trilin-dpsub.ko` has 251 undefined refs and `linlon-dp.ko` has 275.
    **0 of them** are unresolved against `Module.symvers`.
  - `trilin-dpsub.ko` now imports `of_drm_find_panel`, `drm_panel_put` and
    `__devm_add_action`.
  - Negative control: r278's shipped `trilin-dpsub.ko` checked against the
    new `Module.symvers` shows exactly 1 unresolved symbol,
    `fwnode_drm_find_panel`. The check catches exactly this failure.

### 3. 0074: not re-applied. The claim that H15-H17 were absorbed by 0066/0068/0069 is wrong.

| Hunks | Evidence in the port tree |
|---|---|
| H1, H2 | `acpi_clk.c:252` `cix_acpi_clk_determine_rate`; `:519` `void cix_acpi_clk_remove` |
| H3-H6 | no `round_rate` and no `sky1_audss_clk_remove` in `clk-sky1-audss.c` |
| H7 | `phy-cix-usb2.c:9` includes `platform_device.h` |
| H8 | `acpi_resource_lookup.c:222` sets `cma->ranges[0].base_pfn` |
| H9 | `int cix_aec_gpio_set(` |
| H10 | `void cix_aec_remove(` |
| H11 | `dsdt_override.c:16` includes `linux/unaligned.h` |
| H12 | `void cix_ddrlp_remove(` |
| H13 | `cix-plat.c:95/165` guard `CONFIG_CIX_SMMU_ATTACH_NOTIFIER` |
| H14 | `cix-suspend.c` uses `IS_ENABLED(CONFIG_HISYSEVENT)` and `strscpy` |
| H15-H17 | **not** from 0066/0068/0069. 0069's copy still calls `perf_ops->device_domain_id()`, which is gone. The port's `cix_scmi_em.[ch]` come from `9fa83019a3ea` ("carries 0074+0172 hunks"): a 2-argument `cix_scmi_register_em(dev, perf_dev)` on `scmi_perf_domain_power_scale()` and `est_power()`, with no `device_domain_id` anywhere. The header is present. `cix_scmi_register_em()` has **no caller** in the tree. |

### 4. 0004 / 0005 / 0065 / 0105: nothing to delete. Coverage is only partial.

- There are no `SRC_URI` entries to delete (see Provenance).
- 0105 is covered: `clk-sky1-audss.c` has no `.prepare` op and no
  `put_noidle`.
- 0004, 0005 and 0065 are only **partly** covered by mainline
  `3730fe6032d9`, `7cd3ca90d921` and `b5fa9d3beec4`, which supply the DT
  AUDSS clock and reset. Their ACPI halves are carried in the port and are
  load-bearing, per recipe history: without CIXHA010 the DPU, audio and USB
  devices defer forever. They are:
  - `a4de88c36585`, the CIXHA010 provider (`clk-sky1-acpi.c`, `acpi_clk.c`);
  - `db1fd834dae3` and `cad63faa518b`, the reset-core ACPI lookup;
  - `219af72fa7e8`, reset-sky1 ACPI;
  - `3185f61df084`, audss reset `CIXH6062`;
  - `77b1624778cc`, audss clk `CIXH6061`.
- These must not be removed. This is documented in the recipe.

### 5. Class (b): nothing was ported

- The NPU chain 0119, 0120, 0121, 0123, 0125, 0159 and 0220 is marked
  **dropped by policy** in the recipe (DKMS `cix-npu-driver`/aipu). The
  port's `3da51e546c4b` already records that verdict. `aipu.ko` ships as an
  r278 overlay.
- Queued in the recipe as "port only if the r278 boot shows missing
  clocks/thermals": the CLKT chain 0096, 0138, 0147, 0148, 0157 and 0168
  (the base `clk-sky1-acpi.c` from 0065 is present), 0172, 0089, 0212 and
  0216.
- Correction to the raw-replay list: 0001 is already carried
  (`3d7823f9c2b2`, `535db5995054`), and so is 0091 (`6d3cab5b0154`,
  `9291c638f97a`).

### 6. Mirror auto-pull incident: shipping kernel debs pinned to the mainline KVER

- **Mechanism, reproduced from artifacts.**
  1. Staging r278 wrote `+r278` debs into `build/kernel-debs`.
  2. `build-vendor-mirror.sh` published every deb in that directory.
     `publish_deb` keeps whichever same-named package it copies last, so rc5
     replaced 7.2.8. ULTRA still holds the evidence in
     `build/forky-vendor-mirror.rc5-stale-20260928-234219/pool/main`.
  3. On the target, `10-our-kernel.sh` chose the `sort -V` newest
     `linux-image-cixmini`.
- **New `build/check-kernel-deb-pin.sh`.** For linux-image-cixmini and
  linux-headers-cixmini it requires Version `<KVER>+r<N>`, where KVER is read
  from `assets/kernel/mainline/KVER`. It also enforces:
  - `r<N>` is not older than the staged pointer directory;
  - one version per package;
  - `cixmini-boot`'s revision equals the image's.
  A directory with no Sky1 kernel packages passes.
- **`build-vendor-mirror.sh`** runs the pin on `KERNEL_DEBS` before
  publishing, and again on the final pool before indexing.
- **`post-install/10-our-kernel.sh`** selects
  `linux-{image,headers}-cixmini_${KVER_NEXT}+*.deb`, never the newest in the
  pool. Its apt fallback installs `linux-image-cixmini=<KVER_NEXT+rN>` or
  nothing.
- **Makefile `kernel-debs`.** The reuse test compared `<KVER>+r<N>` with bare
  KVER, so it never matched and every run rebuilt. The parser is fixed, and
  reuse now also requires the pin. Fixing only the parser would have let a
  stale `+r258` build of 7.2.8 be reused.
- **Test `build/test-kernel-deb-pin.sh`: 11/11 pass.**
  - It includes the requested case: the real `build-vendor-mirror.sh` run
    with 7.2.8 and rc5 sets in `KERNEL_DEBS` and the pin at 7.2.8 exits 1
    and publishes nothing.
  - It also covers rc5 only, a missing pin, the revision floor
    (`r258` vs the `r277` dir), a mixed-build `cixmini-boot`, and the parser.
- **Real data.** The pin FAILs on ULTRA's stale rc5 mirror pool and on
  `build/kernel-debs.rc5-r278-20260928-234219`. It also FAILs on ULTRA's
  current main-checkout `build/kernel-debs` (7.2.8 `+r258`, older than
  r277). That is LEAD's checkout and was left untouched.

### 7. Channel rename: mainline is the 7.2.x shipping line, edge is the 7.3.x test line

- **Pointer changes.**

  | Pointer | Before | After |
  |---|---|---|
  | `assets/kernel/mainline` | did not exist | → `r277-7.2.8-sky1-ncz-20260927` |
  | `assets/kernel/edge` | → r277 | → `r278-7.3.0-rc5-sky1-ncz-20260927` |
  | `assets/kernel/edge-experimental` | → `test-73rc3` | removed |

- **Files switched to `mainline` for the shipping kernel:**
  - `Makefile`, `build-kernel-debs.sh` (header fixed), `build-iso-di.sh`
    (installer kernel flavor/label), `build-installer-image.sh`,
    `build-baked-rootfs.sh`, `build-iso.sh`;
  - `build-squashfs-layers.sh` (the `KVER_NEXT` sidecar source),
    `kvm-kernel-gate.sh`, `release-kernel.sh`, `kernel-manifest.py` and
    `assets/kernel-manifest.json`;
  - `sbom/expected-assets.txt`, `verify-base-kernel-assets.sh`, and
    `stage-kernel.sh`. `stage-kernel.sh` now takes `NCZ_KERNEL_CHANNEL` and
    refuses an rc kernel as mainline or a release kernel as edge; edge is
    never packaged.
  - `post-install/10-our-kernel.sh` (headers channel), `preseed/late.sh`,
    the containers README, and the README.
- **The committed `kernel-manifest.json` was stale.** It still described
  r278 rc5 under "edge" (`590b3e2a`) after `b63676d9` repointed 7.2.8. It is
  regenerated from `mainline`, and `kernel-manifest.py check` reports OK.
- **Edge (test) line.**
  - The `KVER_EDGE` sidecar now comes from `assets/kernel/edge`.
  - Because edge is an absolute pool symlink,
    `build-squashfs-layers.sh` now stages a dereferenced copy of Image,
    modules, config, KVER and headers into the base.
    `10-our-kernel.sh` reads `assets/kernel/edge`.
  - Effect on the next image: the non-default "7.3 Edge / Experimental"
    entry becomes **rc5 (r278)** instead of rc3. This is the intended
    consequence of the rename and was flagged for LEAD 3.
- **Freshness gate** (`preflight-freshness-gate.sh` [3]):
  `check_arm64_channel` runs per pointer. Mainline must be stable class,
  required, and newest-stable. Edge must be prerelease class, is optional,
  and must be newest-rc. A wrong-class pointer FAILs, which catches the
  incident in both directions.
  - `test-arm64-freshness-gate.sh`: 9/9 pass, with FAIL counts asserted
    exactly.
  - The old full-gate case (case 4) was a **false pass**: the gate `cd`s to
    its own repo root and ignores `KERNEL_STAGING_DIR`, so the case checked
    the live checkout and pool. The new case 9 runs a synthetic repo copy
    with `--kernel-staging-dir`.
  - Live run on ULTRA: `[3] OK: arm64 mainline -> r277`, `[3] OK: arm64 edge
    -> r278`.
- **Kept on purpose** (installed-base compatibility):
  - the `KVER_NEXT`/`KVER_EDGE` sidecar names (`KVER_NEXT` now means
    mainline);
  - rEFInd titles, which already read "7.2 ... (Default)" and "7.3 Edge /
    Experimental";
  - `DEFAULT_TOKEN`;
  - the systemd-boot title strings;
  - `ncz-refind-refresh.sh`, whose log wording still says "edge kernel" for
    `KVER_NEXT`. Changing it needs a `cixmini-boot` version bump, so it is
    left as follow-up.
- **`linux-image-cixmini-edge` as a separate package: NOT done.** That name
  is in the image package's `Replaces`/`Conflicts`/`Provides` take-over list
  (`_OLD_NAMES`), so installing it beside `linux-image-cixmini` would remove
  the shipping kernel. It is follow-up work: first rename the take-over list
  entry, then carry the package through an OTA cycle.
- **Same-kernel proof.** `build/resolve-sky1-kernel-inputs.sh` evaluates the
  consumers' real resolution lines. Run on the pre-change tree (`a29709d4`)
  and on this branch, it shows identical shipping inputs:
  - `NEXT_KERN` r277 `Image` sha `59f7bbc9b0fc5471`;
  - modules sha `1e464c8f0e3d332f`;
  - `KVER_NEXT` `7.2.8-sky1-ncz`;
  - `BUILD_REV` `r277`;
  - the KVM-gated Image and the installer-image kernel are the same r277
    Image.
  The only diffs are the channel label, the pointer paths, the `KVER_EDGE`
  source (rc3 → rc5), and the new pin.

## Test evidence (branch head)

- `build/test-*.sh`: every suite passes. `test-under-di-busybox` needs ISO
  staging and was not run.
  - `test-platform-lint`: 37/37, with inventory rows added for the three new
    scripts.
  - `arm64-gates` 18/18, `installed-target-verifier` 68/68,
    `late-union-sync` 2/2.
- `bash -n` passes on every changed script. The new scripts are
  shellcheck-clean at `-S warning`; the remaining warnings in
  `stage-kernel.sh` and `build-vendor-mirror.sh` pre-date this change.

- Target apt pin, checked in a `debian:forky` container against a file repo
  holding 7.2.8+r277 and 7.3.0-rc5+r278: `apt-cache madison` lists rc5
  first, but the pipeline extracted from `10-our-kernel.sh` selects
  `7.2.8-sky1-ncz+r277` (`apt-get install -s` confirms it). With no
  matching version, the result is empty and nothing is installed.
- zoder adversarial review (`minimax-m3-cloud` / MiniMax-M3, 136 tool calls)
  covered all three diffs: `VERDICT: APPROVE`. Its one finding was the stale
  `edge-experimental` log labels in `10-our-kernel.sh`; they are fixed. Its
  refcount analysis confirms that `devm_add_action_or_reset` calls the action
  on failure and that `trilin_dp_edp_drop_panel()` does not put the panel.

## Open risks

- r278 has never booted on hardware. The supervised sheet is
  `docs/SKY1-R278-SUPERVISED-BOOT-TEST.md`.
- The linlon-dp re-aim is in the recipe (PR r2) but not in any staged
  kernel. r279 needs a Yocto build plus a rebuild of all four DKMS overlays
  before it can replace r278 on the edge pointer.
- The 0027 remainder (native Sky1 PCIe) is absent. Native mode must not be
  used on 7.3.
- `cix_scmi_register_em()` has no caller, so there is no GPU/CPU energy
  model on 7.3 until 0172 is re-aimed.
- `CONFIG_MODULE_COMPRESS_XZ=y` in both the r277 and r278 configs conflicts
  with the fleet "never xz-compress a kernel .ko" rule. This pre-dates the
  change and is not addressed here.
- The next image built from this branch carries rc5 as its experimental
  entry, a deliberate change from rc3.
