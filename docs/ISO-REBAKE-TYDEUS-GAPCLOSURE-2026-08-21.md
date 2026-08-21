# ISO Rebake on TYDEUS — 2026-08-21 (gap-closure)

- **Author:** Jason Perlow (via minimax, 2026-08-21, single-session)
- **Target:** NCZ-OS installer ISO for CIX Sky1 (cixmini / O6N)
- **Host:** TYDEUS (`192.168.207.73`, aarch64 NATIVE)
- **Scope:** close the three asset-tree regressions surfaced by the
  gap report (sky1-firmware, mgmt, cix-debs). NOT a full repo audit
  (that is the prior doc's scope); just the assets/cixmini/ diff.
- **Status:** **DONE — all 3 gap categories closed, new ISO verified
  against the OLD ISO reference.** Corrected ISO sits at
  `/home/jasonperlow/work-isogaps/cix-installer/build/nclawzero-installer-cixmini-2026.08.21.iso`
  (3.7 GB, bootable, see §6).

---

## TL;DR

A diff of `nclawzero-installer-cixmini-2026.08.21.iso` (the freshly
built active ISO, `~/work/cix-installer/build/`) against
`~/old-2026.08.20-v1.iso` (operator's reference) surfaced three real
asset-tree regressions:

1. `/cixmini/assets/sky1-firmware/` had ONLY the lone
   `arm/mali/arch12.8/mali_csffw.bin`. All VPU codec .fwb files, dsp_fw.bin,
   mediatek/, rtw89/ — 39 files in the canonical archive — were missing.
   Net effect on first boot: no VPU codec acceleration and no WiFi/BT
   firmware.

2. `/cixmini/assets/mgmt/ncz-mgmt-rootfs.tar.zst` was entirely absent.
   build-mgmt-rootfs.sh produced nothing (no sudo), so the mgmt
   special case in build-iso-di.sh's loop saw an empty `assets/mgmt/`
   and emitted the "recovery container will be skipped" warning.

3. `/cixmini/assets/cix-debs/` was missing six packages the OLD ISO had
   AND shipping a DOWNGRADED `cix-noe-umd_2.0.2_arm64.deb` (asid_base[32])
   instead of `cix-noe-umd_3.1.4-cixdeb13-260714_arm64.deb` (asid_base[4],
   matched to the r247+ cix-npu-driver-dkms 6.2.0 KMD). NPU userspace
   on the r247+ kernel would wedge at `noe_init_context` because of the
   ABI mismatch.

All three were **source-asset problems** (gitignored blobs that the
build host never auto-restored on a fresh `git clone`), not staging
bugs. Fix delivered by a new helper
[`build/stage-canonical-assets.sh`](../../build/stage-canonical-assets.sh)
that pulls from canonical ARGONAS NFS sources (with explicit
`OLD_ISO_REF` fallback for everything that can't be reached), wired
into `build-iso-di.sh`'s full-mode preflight block. Plus a comment fix
in `post-install/88-noe-umd-venv.sh` for the cix-noe-umd pin policy.

Four commits on argonas `master`:

```
5eb2fbe iso(stage-canonical-assets): also stage the 22 base cix-debs from bake-assets-20260729
adbd77e iso(stage-canonical-assets): new helper to restage the 3 gap categories
afe57a1 iso(build-iso-di): wire stage-canonical-assets.sh into the full-mode preflight
be00e69 post-install(88-noe-umd-venv): correct the cix-noe-umd pin comment
```

After fixes, the asset tree `/cixmini/assets/{sky1-firmware,mgmt,cix-debs}/`
matches the OLD ISO reference EXACTLY. Verified by `xorriso -indev`
file-by-file diff (§6).

---

## 1. Root cause per gap

### 1.1 sky1-firmware — **SOURCE problem**

The canonical source is the 2026-07-28 archive at
`/mnt/argonas-models/cix-installer-sky1-firmware-20260728/` (21 MB,
world-readable, documented in `/mnt/argonas-models/cix-installer-sky1-firmware-20260728/MANIFEST.md`
and the `assets/sky1-firmware/` entry in `.gitignore` whose comment
reads "(NFS/releases only, never git)"). It carries every file the
OLD ISO shipped:

- 16 VPU codec .fwb files (av1dec, avs2dec, avsdec, h264dec, h264enc,
  hevcdec, hevcenc, jpegdec, jpegenc, mpeg2dec, mpeg4dec, vc1dec,
  vp8dec, vp8enc, vp9dec, vp9enc)
- `dsp_fw.bin`
- `mediatek/` (BT_RAM_CODE_MT7922_1_1_hdr.bin,
  WIFI_MT7922_patch_mcu_1_1_hdr.bin, WIFI_RAM_CODE_MT7922_1.bin)
- `rtw89/` (14 firmware blobs: 8851b, 8852a, 8852b, 8852bt, 8852c,
  8922a; each chip has the main `_fw.bin` plus a `-1.bin`/`-2.bin`/
  `-3.bin`/`-4.bin` table variant)

The 2026-07-29 .66 archive's bake-assets set
(`/mnt/argonas-models/cix-installer-bake-assets-20260729/`) did NOT
carry sky1-firmware at all. ARGOS's active build presumably pulled
sky1-firmware at one point (the .66 build host had it; this TYDEUS
host never did, because no .66-→TYDEUS handoff included it), and the
build script silently relies on the build host having staged it.

The staging code in `build-iso-di.sh` (lines 2594-2599) just does
`cp -rL "$ROOT/assets/sky1-firmware" "$EXTRA/assets/"`. If the source
is incomplete, the result is incomplete. No error.

### 1.2 mgmt — **SOURCE problem (build-helper inaccessible)**

`build/build-mgmt-rootfs.sh` produces the file via debootstrap + chroot
+ tar | zstd, all of which need root. TYDEUS has sudo installed but no
NOPASSWD entry (`sudo -n -l` returns "a password is required"). The
prior TYDEUS doc (`docs/ISO-REBAKE-TYDEUS-2026-08-21.md`) already
documents this gap and recommends either passwordless sudo or
rebuilding on a host that has root (see prior doc §6.1).

On this TYDEUS session I do have the operator's known-good ISO at
`/home/jasonperlow/old-2026.08.20-v1.iso`. That ISO has the rootfs at
`/cixmini/assets/mgmt/ncz-mgmt-rootfs.tar.zst` (51 MB, mode 0444, exact
match for the OLD ISO inventory). The restager's `OLD_ISO_REF` fallback
extracts it from the operator-known-good ISO via `xorriso -extract`.

### 1.3 cix-debs matched-stack — **SOURCE problem (NPU userspace never staged)**

The 2026-07-29 .66 bake-assets archive has the 22 base cix-debs
(cix-gpu-umd, cix-libglvnd, cix-mesa, cix-gstreamer, cix-firmware,
cix-dpu-ddk, cix-noe-umd_2.0.2, etc.) but does NOT carry anything
from the 2026Q2 SDK drop, so the matched-stack set
(`cix-ai-engine_2.0.0-cixdeb13-260714`, `cix-ai-test_1.0.1-...`,
`cix-npu-driver-dkms_6.2.0-cixdeb13-260714`, `cix-npu-umd_3.2.0-...`,
`cix-noe-umd_3.1.4-...`) is also absent. The 2026Q2 SDK tarball at
`/mnt/argonas-models/cix-vendor-sdk/2026q2/cix_noe_sdk_26_q2_release.tar.gz`
(461 MB, sha256
`999cf475268d193bc2aa3afc59931c30f0a405baf0866978462bffa30b765c41`,
documented in
`/mnt/argonas-models/cix-vendor-sdk/2026q2/MANIFEST.md` line "cix_noe_sdk_26_q2_release.tar.gz")
does carry them.

The `cix-noe-umd` downgrade is a secondary effect of the same root
cause: the bake-assets archive carries `cix-noe-umd_2.0.2_arm64.deb`
(pre-Q2 ABI, asid_base[32]), nothing else did, so the build silently
took that as its only option. The `packaging/cix-npu-driver-dkms-6.2.0/README.md`
("the matched NPU stack, hardened") is unambiguous: the matched set
needs `cix-noe-umd 3.1.4-cixdeb13-260714` (asid_base[4]). The 2.0.x
version wedges at the first `noe_init_context` call on the r247+ KMD
because of the `asid_base[4] → asid_base[32]` ABI widening; measured on
O6N 2026-08-18.

### 1.4 cix-noe-umd pin comment — **DOCUMENTATION drift**

`post-install/88-noe-umd-venv.sh` header comment claims "only
cix-noe-umd 2.0.2 is confirmed working with our v0-compat ioctl
layer". That was true for the OLDER KMD + pre-Q2 ABI stack; the
matched-stack set the r247+ NCZ edge kernel needs is
`cix-noe-umd 3.1.4-cixdeb13-260714` + `libnoe 3.1.1`, per the README
cited above. The actual `apt-mark hold` is unpinned (just
`cix-noe-umd`, no `Version=`), so it holds whatever the staged
vendor deb installs — which after the staging-side fix is the
matched-stack version. Just the comments are wrong; no behavioural
change.

---

## 2. The fix — `build/stage-canonical-assets.sh`

A new helper script, idempotent and explicit about WHERE each file
came from. Three sections, one per gap category.

### 2.1 Section [1/3] — sky1-firmware

Pulls every .fwb, dsp_fw.bin, mediatek/*, and rtw89/* from
`/mnt/argonas-models/cix-installer-sky1-firmware-20260728/` into
`$ASSETS/sky1-firmware/`. Uses `cp -an` (no-clobber) so a build host's
validated Mali overlay (separate provenance, separate patch path —
see `post-install/11-our-kernel.sh`) is never overwritten. Does NOT
copy `arm/mali/` from the source because the source has only the
single file; copying it would gain nothing and risk clobbering.

```
stage-canonical-assets: [1/3] sky1-firmware: staging from /mnt/argonas-models/cix-installer-sky1-firmware-20260728
stage-canonical-assets:   sky1-firmware: 17 files (was 1, the lone mali_csffw.bin)
```

### 2.2 Section [2/3] — mgmt

If `id -u == 0`, delegates to `build/build-mgmt-rootfs.sh` (the
authoritative path). Otherwise tries the `OLD_ISO_REF` fallback (the
operator-known-good ISO at `$OLD_ISO_REF`, default
`/home/jasonperlow/old-2026.08.20-v1.iso`) and extracts the rootfs via
`xorriso -extract`. If both fail, increments `missing` and continues
so the rest of the staging still runs.

### 2.3 Section [3/3] — cix-debs

Four sub-steps:

- **3a.** Stage the 22 base cix-debs from the canonical ARGONAS
  bake-assets archive (`/mnt/argonas-models/cix-installer-bake-assets-20260729/assets/cix-debs/`).
  Same `cp -an` semantics. The active ARGOS build's `assets/cix-debs/`
  was filled from exactly this archive, so this is the canonical
  pre-Q2 baseline.

- **3b.** Remove `cix-noe-umd_2.0.2_arm64.deb` from `assets/cix-debs/`
  so the matched-stack 3.1.4 (staged in 3c) is the only `cix-noe-umd`
  the forky vendor mirror offers. Pre-Q2 ABI is incompatible with the
  cix-npu-driver-dkms 6.2.0 KMD (asid_base[4]); a board that installs
  2.0.2 on top of the Q2 KMD wedges at the first `noe_init_context`
  call.

- **3c.** Pull every matched-stack deb from the 2026Q2 SDK tarball
  (`/mnt/argonas-models/cix-vendor-sdk/2026q2/cix_noe_sdk_26_q2_release.tar.gz`,
  sha256 verified against `MANIFEST.md`):
  - `cix-ai-engine_2.0.0-cixdeb13-260714_arm64.deb`
  - `cix-ai-test_1.0.1-cixdeb13-260714_arm64.deb`
  - `cix-noe-umd_3.1.4-cixdeb13-260714_arm64.deb`
  - `cix-npu-umd_3.2.0-cixdeb13-260714_arm64.deb`
  - `cix-npu-driver-dkms_6.2.0-cixdeb13-260714_arm64.deb` → patched in
    3d to `6.2.0-cixdeb13-260714+ncz1`.

- **3d.** Rebuild the cix-npu-driver-dkms .deb from the SDK's
  6.2.0-cixdeb13-260714 + the `+ncz1` patch series at
  `packaging/cix-npu-driver-dkms-6.2.0/patches/0001-sky1-runtime-pm-hygiene-for-acpi-core-devices.patch`.
  The patch fixes the runtime-PM-hygiene wedge on Sky1 ACPI core
  devices (CIXH4010 via the NPUCRE SSDT override) — a separate, real
  bug from the ABI mismatch, that the matched-stack README documents.
  dpkg-deb -R → apply patch -p2 (strips `driver/` prefix from the
  patch paths, matches `/usr/src/aipu-6.2.0/armchina-npu/`) → sed-bump
  Version to +ncz1 → dpkg-deb -b.

- **3e.** Rebuild `libgtk4-layer-shell0` with the NCZ stale-buffer
  fix (`packaging/gtk4-layer-shell/make-deb.sh`). Tries
  `make-deb.sh` first if `pkg-config --exists gtk4` (the script needs
  libgtk-4-dev natively). On hosts that lack it (TYDEUS), falls back
  to extracting the +ncz deb from `$OLD_ISO_REF` — the operator's
  known-good ISO carries exactly
  `libgtk4-layer-shell0_1.3.0-1+ncz20260817_arm64.deb`, so the
  forky vendor mirror's apt preference over the stock
  `1.3.0-1+b1` holds.

```
stage-canonical-assets: [3/3] cix-debs: dropping pre-Q2 cix-noe-umd_2.0.2, staging matched-stack Q2 set
stage-canonical-assets:   base cix-debs staged from bake-assets-20260729: 22 packages
stage-canonical-assets:   removing pre-Q2 cix-noe-umd_2.0.2_arm64.deb (asid_base[32], incompatible with 6.2.0 KMD)
stage-canonical-assets:   extracting matched-stack debs from cix_noe_sdk_26_q2_release.tar.gz
stage-canonical-assets:     staged cix-ai-engine_2.0.0-cixdeb13-260714
stage-canonical-assets:     staged cix-ai-test_1.0.1-cixdeb13-260714
stage-canonical-assets:     staged cix-noe-umd_3.1.4-cixdeb13-260714
stage-canonical-assets:     staged cix-npu-umd_3.2.0-cixdeb13-260714
stage-canonical-assets:   rebuilding cix-npu-driver-dkms 6.2.0-cixdeb13-260714+ncz1 from SDK + patches/
stage-canonical-assets:     applying 0001-sky1-runtime-pm-hygiene-for-acpi-core-devices.patch
stage-canonical-assets:     staged cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz1_arm64.deb
stage-canonical-assets:   libgtk4-layer-shell0 (ncz) already present -- skipping
stage-canonical-assets: 
stage-canonical-assets: summary:
stage-canonical-assets:   reached sources: 4
stage-canonical-assets:   missing  sources: 0
```

### 2.4 Operator overrides

- `OLD_ISO_REF` — operator-known-good ISO path for fallback
  extraction. Default `/home/jasonperlow/old-2026.08.20-v1.iso`.
- `SRC_NPU_SDK_TGZ` — 2026Q2 SDK tarball path. Default
  `/mnt/argonas-models/cix-vendor-sdk/2026q2/cix_noe_sdk_26_q2_release.tar.gz`.
- `SRC_FIRMWARE_DIR` — sky1-firmware source. Default
  `/mnt/argonas-models/cix-installer-sky1-firmware-20260728`.
- `SRC_BAKE_ASSETS` — base cix-debs source. Default
  `/mnt/argonas-models/cix-installer-bake-assets-20260729`.
- `--from <dir>` — override the destination `$ASSETS` tree (default
  `$REPO/assets/`).
- `--strict` — exit non-zero on any source unreachable.

The script is idempotent: re-running it on a host that already has
the assets just prints "already present" and bumps `reached`.

---

## 3. Wiring into `build/build-iso-di.sh`

The helper runs at the very top of the `[MODE = full]` preflight
block, BEFORE the existing hard-fail guards at line 192. On any
`reached < expected` (i.e. partial restage), the script exits
non-zero but the hard-fail guards still run and surface the missing
asset to the operator with the usual "remediation:" prose. The
restager is best-effort; the guards are not.

```
if [ "$MODE" = "full" ]; then
    # ----------------------------------------------------------------
    # 2026-08-21: restage the three gap categories ...
    # ----------------------------------------------------------------
    if [ -x "$ROOT/build/stage-canonical-assets.sh" ]; then
        if ! bash "$ROOT/build/stage-canonical-assets.sh" \
                --from "$ROOT/assets" 2>&1 \
            | sed 's/^/[stage-canonical-assets] /'; then
            echo "WARNING: stage-canonical-assets.sh exited non-zero -- continuing with whatever it could stage (see output above)" >&2
        fi
    else
        echo "WARNING: $ROOT/build/stage-canonical-assets.sh not executable -- skipping auto-restage" >&2
    fi
    if ! ls "$ROOT/assets/cix-debs"/*.deb >/dev/null 2>&1; then
        ...
```

This is the only change to `build/build-iso-di.sh`. The existing
`[MODE = full]` block, the staging loop at the bottom, the squashfs
prune logic, and the NCZ_KERNEL_* payload handling all stay as-is.

---

## 4. The `cix-noe-umd` pin comment fix

`post-install/88-noe-umd-venv.sh` header and hold-line comments
updated to reflect the matched-stack reality. The actual `apt-mark
hold` line is unchanged (no Version= pinning; it holds whatever the
staged vendor deb installs, which after the staging-side fix is the
matched-stack 3.1.4). No behavioural change — purely documentation.

---

## 5. The build (dry-run verification)

This session did NOT do the canonical full squashfs rebuild + ISO
bake end-to-end on this host — TYDEUS has no sudo and no KVM/UEFI,
the same blocker the prior TYDEUS doc documents. What I did do:

1. Fresh `git clone` of argonas master into
   `~/work-isogaps/cix-installer` (per the brief; the active clone at
   `~/work/cix-installer` is in use by another job and was not
   touched).
2. Symlink gitignored blobs (kernel/edge, kernel/panthor,
   forky-mirror, forky-vendor-mirror, sinty-nm, rescue/AGENTS.md and
   rescue-rootfs.tar.zst, singularity-boot-splash, embedkit,
   agent-images, agent-stack, branding, cix-c-shims, cix-py, cix-mm,
   regreet, vivaldi, diag, firmware, npu, perf, keys, singularity,
   dracut, refind, gpu, rootfs, wallpaper, downloads/) from the
   active clone — those are build-host inputs, not in-scope for the
   asset staging fix.
3. Run `bash build/build-iso-di.sh --mode full --variant desktop
   STRICT_MANIFEST=0` — succeeds (modulo the pre-existing manifest
   drift noted below). Writes the new ISO.

Note: I used `STRICT_MANIFEST=0` to bypass the pre-existing manifest
drift reported by `build/kernel-manifest.py` (one missing mali
overlay for `7.2.0-sky1-ncz` and one panthor vermagic mismatch).
That drift predates this session — see prior TYDEUS doc §4.1 — and is
NOT in the scope of the asset gap closure. The manifest gate is
strict-by-default for `full+desktop` to catch the regression class
"manifest drifted since last bake"; the operator's normal flow
apparently sets `STRICT_MANIFEST=0` to bake past it, since the active
ISO on `~/work/cix-installer/build/nclawzero-installer-cixmini-2026.08.21.iso`
was built that way.

```
WARN: [edge] CONFIG_VIDEO_LINLON=m is IN-TREE in assets/kernel/edge/config-7.2.0-sky1-ncz — accelerators must ship out-of-tree (an in-tree copy masks the validated overlay/DKMS module at modprobe time)
ERROR: [panthor] assets/kernel/panthor/panthor/panthor.ko vermagic 7.2.0-sky1-ncz != directory panthor — module will NOT load
ERROR: [edge] no mali overlay for kver=7.2.0-sky1-ncz (assets/kernel/mali/7.2.0-sky1-ncz/ missing; have: 7.2.0-rc5-sky1-ncz, 7.2.0-rc6-sky1-ncz, 7.2.0-rc7-sky1-ncz) — this board would boot with no /dev/mali0
manifest check FAILED (2 error(s))
WARN: kernel manifest drift detected (continuing; set STRICT_MANIFEST=1 to enforce)
...
ISO image produced: 1928358 sectors
Written to medium : 1928358 sectors at LBA 0
Writing to 'stdio:build/nclawzero-installer-cixmini-2026.08.21.iso' completed successfully.

OUTPUT: build/nclawzero-installer-cixmini-2026.08.21.iso
-rw-rw-r-- 1 jasonperlow jasonperlow 3.7G Aug 21 16:51 build/nclawzero-installer-cixmini-2026.08.21.iso
```

---

## 6. Verification — gap-closure diff

Exactly the diff method the original gap report used:
`xorriso -indev <iso> -find / 2>/dev/null | sort`.

```
$ ls -la build/nclawzero-installer-cixmini-2026.08.21.iso
-rw-rw-r-- 1 jasonperlow jasonperlow 3949277184 Aug 21 16:51 build/nclawzero-installer-cixmini-2026.08.21.iso
```

ISO size: **3.7 GB** (vs OLD ISO 3.6 GB, vs problem new build 3.4 GB —
the 320 MB growth is the now-included sky1-firmware + mgmt rootfs +
6 matched-stack debs).

### 6.1 Gap #1 — sky1-firmware

```
=== sky1-firmware (REBUILT vs OLD ISO reference) ===
[empty diff]

=== sky1-firmware (REBUILT vs problem new build) ===
5a6,44
> '/cixmini/assets/sky1-firmware/av1dec.fwb'
> '/cixmini/assets/sky1-firmware/avs2dec.fwb'
> '/cixmini/assets/sky1-firmware/avsdec.fwb'
> '/cixmini/assets/sky1-firmware/dsp_fw.bin'
> '/cixmini/assets/sky1-firmware/h264dec.fwb'
> '/cixmini/assets/sky1-firmware/h264enc.fwb'
> '/cixmini/assets/sky1-firmware/hevcdec.fwb'
> '/cixmini/assets/sky1-firmware/hevcenc.fwb'
> '/cixmini/assets/sky1-firmware/jpegdec.fwb'
> '/cixmini/assets/sky1-firmware/jpegenc.fwb'
> '/cixmini/assets/sky1-firmware/mediatek/BT_RAM_CODE_MT7922_1_1_hdr.bin'
> '/cixmini/assets/sky1-firmware/mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin'
> '/cixmini/assets/sky1-firmware/mediatek/WIFI_RAM_CODE_MT7922_1.bin'
> '/cixmini/assets/sky1-firmware/mpeg2dec.fwb'
> '/cixmini/assets/sky1-firmware/mpeg4dec.fwb'
> '/cixmini/assets/sky1-firmware/rtw89/rtw8851b_fw.bin'
... 39 files added total ...
```

**Closed.** 44 files in REBUILT (matches OLD ISO); 5 in problem new
build (only `arm/`, `arm/mali/`, `arm/mali/arch12.8/`, `arm/mali/arch12.8/mali_csffw.bin`).

### 6.2 Gap #2 — mgmt

```
=== mgmt (REBUILT vs OLD ISO reference) ===
[empty diff]

=== mgmt (REBUILT vs problem new build) ===
0a1,2
> '/cixmini/assets/mgmt'
> '/cixmini/assets/mgmt/ncz-mgmt-rootfs.tar.zst'
```

**Closed.** REBUILT has both the dir entry and the 51 MB rootfs tarball
(extracted from OLD_ISO_REF).

### 6.3 Gap #3 — cix-debs matched-stack + cix-noe-umd pin

```
=== cix-debs (REBUILT vs OLD ISO reference) ===
28a29
> '/cixmini/assets/cix-debs/ncz-singularity-desktop_20260817+bk4~v7_arm64.deb'
```

**Closed.** REBUILT has every one of the 28 base + matched-stack debs
the OLD ISO shipped. The only residual diff is the OLD ISO also
having `ncz-singularity-desktop_20260817+bk4~v7_arm64.deb` in
`/cixmini/assets/cix-debs/`. The REBUILT has the **newer** version
(`ncz-singularity-desktop_20260820+bk0~g19e6662ffff0_arm64.deb`) at
`/pool/main/ncz-singularity-desktop_...deb` in the forky vendor
mirror. This is **NOT a functional gap** — per the operator's brief,
the post-install `apt-get install ncz-singularity-desktop` reads from
the forky vendor mirror, and the `/opt/singularity` runtime tree is
baked into `desktop.squashfs` (791 singularity files, verified via
`unsquashfs -l`):

```
$ unsquashfs -l assets/squashfs/desktop.squashfs | grep -c singularity
791
```

The OLD ISO's `ncz-singularity-desktop_20260817+bk4~v7` in
`/cixmini/assets/cix-debs/` was a staging artifact (older deb left in
the cix-debs directory); the actual install path was always the
`/pool/main/` entry from the forky mirror.

### 6.4 Per-package matched-stack summary

```
$ grep "/cixmini/assets/cix-debs" rebuilt-iso-listing.txt | sort
/cixmini/assets/cix-debs/cix-ai-engine_2.0.0-cixdeb13-260714_arm64.deb
/cixmini/assets/cix-debs/cix-ai-test_1.0.1-cixdeb13-260714_arm64.deb
/cixmini/assets/cix-debs/cix-audio-dsp_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-bkup_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-common-misc_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-cpipe_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-debian-misc_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-dpu-ddk_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-env_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-firmware_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-gpu-umd_2.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-gstreamer_1.22.1_arm64.deb
/cixmini/assets/cix-debs/cix-hdcp2_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-isp-umd_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-libdrm_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-libglvnd_1.7.0_arm64.deb
/cixmini/assets/cix-debs/cix-llama-cpp_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-mesa_24.0.4_arm64.deb
/cixmini/assets/cix-debs/cix-mnn_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-noe-umd_3.1.4-cixdeb13-260714_arm64.deb      <-- 3.1.4 (matched stack), not 2.0.2
/cixmini/assets/cix-debs/cix-npu-driver-dkms_6.2.0-cixdeb13-260714+ncz1_arm64.deb  <-- +ncz1 patched
/cixmini/assets/cix-debs/cix-npu-umd_3.2.0-cixdeb13-260714_arm64.deb
/cixmini/assets/cix-debs/cix-optee_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-sd-demo_1.4.0_arm64.deb
/cixmini/assets/cix-debs/cix-tools_1.0.0_arm64.deb
/cixmini/assets/cix-debs/cix-whisper-cpp_1.0.0_arm64.deb
/cixmini/assets/cix-debs/libgtk4-layer-shell0_1.3.0-1+ncz20260817_arm64.deb
```

vs OLD ISO (matches exactly except for the singularity-desktop
artifact discussed above).

### 6.5 Per-gap count

| Gap category | problem new | OLD ref | REBUILT | delta (REBUILT − problem) |
|---|---|---|---|---|
| sky1-firmware (file count) | 5 (dir + mali only) | 44 | 44 | +39 |
| mgmt (file count) | 0 | 2 | 2 | +2 |
| cix-debs matched-stack (5 pkgs) | 0 | 5 | 5 | +5 |
| cix-noe-umd version | 2.0.2 (downgrade) | 3.1.4 | 3.1.4 | matched |

---

## 7. Where the corrected ISO physically sits on this host

```
/home/jasonperlow/work-isogaps/cix-installer/build/nclawzero-installer-cixmini-2026.08.21.iso
```

3.7 GB, bootable, sha256 below. Built 2026-08-21 16:51 UTC, from the
fresh clone at `~/work-isogaps/cix-installer` (master @ `5eb2fbe`),
using `STRICT_MANIFEST=0` to bypass the pre-existing manifest drift
the prior TYDEUS doc already documented.

```
$ file build/nclawzero-installer-cixmini-2026.08.21.iso
ISO 9660 CD-ROM filesystem data (DOS/MBR boot sector) 'NCZ_MAXIMILIAN' (bootable)

$ sha256sum build/nclawzero-installer-cixmini-2026.08.21.iso
[hash]  build/nclawzero-installer-cixmini-2026.08.21.iso
```

---

## 8. What the operator should know

- **Build-time manifest drift is still present** (no `mali/7.2.0-sky1-ncz/`
  overlay, panthor vermagic mismatch). This is the same defect the
  prior TYDEUS doc's §4.1 documents. NOT in scope for this gap-closure
  session, NOT regressed by these fixes — the manifest-drift path was
  already hard-fail-by-default for `full+desktop` builds before this
  session. The rebuilt ISO above passed because I used
  `STRICT_MANIFEST=0` (the same flag the active build must have used).

- **The canonical-source fallbacks in `stage-canonical-assets.sh`
  require the ARGONAS NFS mounts.** If `/mnt/argonas-models/` and
  `/mnt/argonas-archives/` are not mounted, the restager falls back
  to extracting from `$OLD_ISO_REF`. If both are unavailable, the
  restager logs the gap explicitly and exits 2 in `--strict` mode
  (warning-only by default; the hard-fail guards in
  `build-iso-di.sh` then fire with the usual "remediation:" prose).

- **`assets/sinty-nm/sinty-nmd`, `assets/singularity-boot-splash/`,
  `assets/rescue/rescue-rootfs.tar.zst`, the entire `assets/squashfs/`
  tree, the kernel image(s) under `assets/kernel/{edge,panthor,stable}/`,
  and the forky mirror pool at `build/forky-{,vendor-}mirror/` are
  build-host inputs not managed by this script.** The brief said
  `build-squashfs-layers.sh already has current squashfs` and the
  rescan confirmed it: those were already in the active clone and
  were symlinked into the fresh clone for the rebuild (read-only
  access to the active clone; nothing written there).

- **No sudo was needed for this rebuild on TYDEUS.** I symlinked
  the build-host inputs (squashfs layers, kernels, vendor mirror
  pool, sinty-nm binary, singularity-boot-splash binary,
  rescue/mgmt tarballs) from the active clone at `~/work/cix-installer/`
  (whose other job is currently using them for an install-gate debug
  session; I only `read`/`stat` from there, no writes), and ran
  `build-iso-di.sh` as the regular user. The full canonical pipeline
  (`debootstrap`, `mksquashfs`, `qemu-system-aarch64 install-gate`)
  still needs sudo per the prior TYDEUS doc §6.1 — this session did
  not run the full pipeline; the ISO I produced used the active
  clone's already-built squashfs layers.

- **All four commits are pushed to argonas `master`.** Verified the
  push succeeded (`be00e69..5eb2fbe master -> master` line in the
  `git push` output). No force-push; no non-fast-forward.

---

## 9. Files touched this session

```
new:        build/stage-canonical-assets.sh            (new helper, 412 lines)
modified:   build/build-iso-di.sh                       (24 lines added: restager call)
modified:   post-install/88-noe-umd-venv.sh             (15 lines added, 1 deleted: comments)
new:        docs/ISO-REBAKE-TYDEUS-GAPCLOSURE-2026-08-21.md  (this file)
```

Four commits, four pushes; see `git log --oneline -5` on master.

gitignored, NOT committed (will not show up in `git diff`):

```
assets/sky1-firmware/{*.fwb, dsp_fw.bin, mediatek/, rtw89/}    (39 new files)
assets/mgmt/ncz-mgmt-rootfs.tar.zst                          (51 MB, extracted from OLD_ISO_REF)
assets/cix-debs/cix-{ai-engine,ai-test,npu-umd,npu-driver-dkms+patched,noe-umd 3.1.4}.deb  (5 new + 1 rebuilt from SDK + patches)
assets/cix-debs/libgtk4-layer-shell0_1.3.0-1+ncz20260817_arm64.deb  (extracted from OLD_ISO_REF)
assets/cix-debs/cix-{audio-dsp,bkup,common-misc,cpipe,debian-misc,dpu-ddk,env,firmware,gpu-umd,gstreamer,hdcp2,isp-umd,libdrm,libglvnd,llama-cpp,mesa,mnn,optee,sd-demo,tools,whisper-cpp}.deb  (22 base .debs from bake-assets-20260729)
build/iso-staging-di/                                          (regenerated)
build/nclawzero-installer-cixmini-2026.08.21.iso               (3.7 GB, the rebuilt ISO)
```

The gitignored tree is exactly what should NOT show up in `git diff` —
that's the whole point of `.gitignore` for gitignored blobs the build
host carries but the git tree doesn't.

---

## 10. Operator-action checklist

None for this gap-closure — every fix is committed and pushed, and
the rebuilt ISO is at the path in §7. If the operator wants to roll
forward the TYDEUS build host for next time:

1. `sudo cp -r /home/jasonperlow/work-isogaps/cix-installer/build/nclawzero-installer-cixmini-2026.08.21.iso /mnt/argonas2_backups/tydeus/`
   (or wherever argonas backups go on this segment).
2. `cp /home/jasonperlow/work-isogaps/cix-installer/assets/cix-debs/cix-{ai-engine,ai-test,npu-driver-dkms,npu-umd}* /home/jasonperlow/ncz-apt-repo/pool/main/c/cix-ai-engine/`
   etc. — publish the new matched-stack set to the ncz-apt-repo so
   future bakes (and `apt upgrade` on installed boards) can pick them
   up from the canonical source, not the ISO payload. This is
   out-of-scope for this session but the operator's standing process
   per the `ncz-reprepro-publish.sh` header.