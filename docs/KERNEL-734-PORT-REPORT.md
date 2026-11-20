# KERNEL-734-PORT-REPORT — 7.3.4 on both lines (2026-11-13)

Operator 2026-11-13: **"Abandon 7.3.3 and build 7.3.4"** + "We should be
automatically tracking and building this in CI" (CI tracking is a fleet-ops
deliverable, `gitops/fleet/kernel-tracker` / `gitops/fleet/kernel-ci`; it only
proposes — branch + Hive job — and never ships or merges). Supersedes the
2026-11-09 7.4 line switch and the 2026-11-12 7.3.3 default. This report is
the 7.3.4 port record for both kernel lines and the carried-patch ledger
requested in lane A #20.

## Source

| | |
|---|---|
| Kernel | linux-stable tag `v7.3.4` (tag object `8310b43a724c54668eeaa6860234078a7886915a`) = peeled commit `7595a62d45ee1a2297eafa5f2ef5d0a45142d84d` ("Linux 7.3.4"), released 2026-11-10 |
| Previous | `v7.3.3` = `d50d994bffa3c7c6db2d8bc4c5f0c55e3f46b0cd`; the whole v7.3.3..v7.3.4 delta is the one release commit (1109 files) in our mirrors |
| Tarball | `linux-7.3.4.tar.xz` sha256 `b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f` (kernel.org sha256sums.asc, per the amd64 port doc) |

## arm64 Sky1 line (meta-cix series, NCZ work)

Branch `hv/ncz-lt-sky1-734-port-20261113` = `4d670d55` on meta-cix (base
`hv/ncz-lt-733-refcount-20261111` `7fbc046`). Recipe
`linux-cix-sky1-ncz_7.3.4.bb` + `linux-cix-sky1-ncz-7.3.4/` = the r299 series
(34 SRC_URI patches: the consolidated port patch + 0001–0011 + 0013–0034) and
the defconfig, byte-identical to the 7.3.3 copies. KVER `7.3.4-sky1-ncz`,
packaging rev **r304** (`assets/kernel/default-kernel.json`:
`7.3.4-sky1-ncz+r304`).

Verification (r298 method, on pristine v7.3.4):

- fuzz 0 replay in SRC_URI order: **34/34 apply** — 31 clean, 3 with line
  offsets only (port patch +1/+7/+47, 0001 +82, 0005 +1/+4 — same offset
  class as on v7.3.3), 0 failures.
- **0 reverse-applies** on pristine v7.3.4 (nothing upstreamed in
  v7.3.3..v7.3.4).
- Tree equality: replay(v7.3.3) + upstream v7.3.3..v7.3.4 ==
  replay(v7.3.4), tree `1d7450973281022398bdad4920f5965e4258a530`.
- `scripts/test-sky1-7.3.4-recipe.sh`: 45 structural checks + the
  `LINUX_STABLE_GIT` mirror check = **46/46 PASS**.
- 0034 (SCMI `mailbox_chan_available()` refcount-put, the fix r299 existed to
  ship, same as linux-cix `1b2eec81` fix #2) rides along unchanged.

Still owed on this line: kernel deb build on a build host (BUILD_REV=r304), DKMS
accelerator overlays (mali/panthor/vpu) rebuilt against the new
Module.symvers with the +ncz rev bump rule (new revision, epoch, manifest
rows, ledger — the +ncz4 pattern), then the image rebuilds and KVM gates.

## amd64 T2 line (lane A)

Branch `hv/lane-a-kernel-734-t2-20261113` = `95d6d19` on amd64-kernel-t2
(lane A, 2026-11-13 16:48Z). The 26-file queue (45 commits; 4001 is 20)
byte-identical to r297, applied on pristine v7.3.4 with plain `git am` (no
fuzz, no --3way). Upstream v7.3.3..v7.3.4 touches two queue-touched files
(2009 amdgpu_drv.c, 9508 asus-wmi.c) — both applied clean, hunks do not
overlap. Held patches 9011/9507 unchanged. Compile proof on a build host (gcc 15.2,
committed 7.3.3-r297 config + olddefconfig; config delta = toolchain strings
only): every queue-touched .c object enabled by the config plus fs/apfs,
t2bce, brcmfmac, bluetooth and all of amdgpu built clean. Per-patch table and
build evidence: `amd64-kernel-t2:docs/AMD64-7.3.4-R300-PORT.md` (their doc);
queue note: `patches/Readme.md`.

**Rev reconciliation:** the amd64 port doc proposes `7.3.4-r300` and defers to
the registry ("change PKGREL if the registry says otherwise"). The registry
already spends r300 on `7.4.0-rc1-sky1-ncz+r300` (dev line), so the shipping
rev is **r303** per `assets/kernel/default-kernel.json` (`7.3.4-r303`,
commit `57fa5f13`): build.sh/PKGREL and the staging run must say r303, and the
registry entries for both 7.3.4 builds are added at promotion.

## Carried patches — upstream status ledger (lane A #20)

| Carried patch | Line | Upstream | In v7.3.4? | Action |
|---|---|---|---|---|
| `9506-wifi-brcmfmac-map-RX-packet-IDs-bidirectional.patch` (fixes `f0ba5fd51ff2` which set `DMA_FROM_DEVICE`) | amd64 T2 queue | mainline `7ed5dce55fa8393972b1bf2bf5af1c818c5e7dc2` (author Jason Perlow); posted for 7.3-stable as **[PATCH 7.3 065/507]** (Greg KH review) | **No** — verified on the mirror (`merge-base --is-ancestor` fails; `msgbuf.c` in v7.3.4 still maps RX packet IDs `DMA_FROM_DEVICE`) | Carry in the 7.3.4 build. **Drop as soon as a 7.3.x stable release contains it (expected 7.3.5): detect by patch-id/subject match against the new tag, never by hand.** |

Rule for every carried patch (goes with the fleet-ops kernel tracker,
NG3-KCI-01/02): on each new pinned tag the tracker must report which carried
patches became upstream in that tag and propose their removal (patch-id or
subject match). Same drop-detection rule applies to the Sky1 series as its
patches make mainline.

## Release-note text (for the next image release notes)

> Kernel: both architectures now ship **7.3.4** (linux-stable, 2026-11-10) —
> amd64 T2 `7.3.4-t2-ncz`, arm64 Sky1 `7.3.4-sky1-ncz`. The arm64 series keeps
> the 0034 SCMI mailbox reference fix (the r299 fix); the T2 Wi-Fi stack keeps
> the brcmfmac RX packet-ID DMA bidirectional fix (upstreamed as
> `7ed5dce55fa8`, not yet in a stable release — carried until 7.3.5). 7.3.3
> images stay archived until the 7.3.4 ones are gated; hardware boot of 7.3.4
> is human-supervised (O6N first).

## Build/rebuild status (image | stage | ETA | blocker)

| image | stage | ETA | blocker |
|---|---|---|---|
| amd64 kernel debs | t2 port DONE (`95d6d19`), compile-proofed; deb build next on a build host (r303) | this cycle+ | none (rev note: use r303) |
| arm64 kernel debs | Sky1 port DONE (`4d670d55`), fuzz-0 + tree-equality proven; yocto/deb build next on a build host (r304) + DKMS overlay rev bump | overnight | none |
| amd64-server + amd64-desktop | wait for amd64 debs; rebuild on 7.3.4; amd64 gates as before | +1 cycle | build time |
| arm64-server + arm64-desktop | wait for arm64 debs; rebuild (arm64-server first); KVM gates on cixmini/O6N (60 s boot smoke first; tcg-scale fix merged `0ada4c2f`) | +1 cycle | build time |
| hardware boot 7.3.4 | operator-side, O6N first, then cixmini/two test machines/a test machine | after gates | human-supervised (operator) |
