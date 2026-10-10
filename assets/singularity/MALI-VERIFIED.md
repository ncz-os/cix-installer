# Singularity payload — vendor-Mali (SceneFX) verification receipt

Regression: **O6N default `7.3 Mali` rEFInd entry booted to a black screen**
(greetd `start-limit-hit`) after the pinned payload moved labwc from a
plain-wlroots build to one bundling **SceneFX 0.5**. Recorded 2026-10-10.
Operator ruling: Mali stays the DEFAULT; deliver the fix AND the source of the
regression.

## 1. Affected sources (representative pin and downstream-latest)

| repo | commit | quoted `#error` | note |
|---|---|---|---|
| labwc (pin, `2da90c41`) | `2da90c41a34b734805cd360f7e4996ad30ec4087` | via scenefx wrap | regressing payload |
| labwc (`singularity` HEAD) | `8a3efc4326859a01d1d8c497d92356615ead1859` | via scenefx wrap `revision=0.5` | latest still affected |
| scenefx (`0.5` tag) | `37ccd723bef49e6891156ffafce8f549f01446cc` | `quad.frag:4`, `tex.frag:9` | pinned wrap target |
| scenefx (HEAD) | `0070ae510426d0e665d5785129b68f03c7264d62` | `quad.frag:4`, `tex.frag:9` | **latest still affected** |
| wlroots (0.20 branch) | `d783533489e1f75d6886c2ab5c5960090ef268f8` | n/a | compositor chain is <0.21.0 |

Terminal proof the defect persists on latest: `grep -rn '#error "'` on scenefx
`0070ae51` and on the `0.5` tag both return the two `#error "Missing shader
preamble"` lines. So a latest-sources build still needs this patch.

Introducing upstream labwc commits (branch `singularity`): `32f44e93`
(SceneFX renderer mandatory), `a9f19c14` (`subprojects/scenefx.wrap`), pinned by
cix-installer `88e1641f` (labwc `6fe073cb → 2da90c41`). Last-known-good before
SceneFX: payload `20261007+bk0+tgzb69d3482` (labwc `6fe073cb`, plain wlroots).

## 2. Fix artifacts (bind these)

```
branch:                 fix/o6n-mali-scenefx-20261010
commit:                 2680f2a3c2dc4b96033f162d19208ef213643357
patch:                  assets/singularity/scenefx-patches/0001-render-fx_renderer-shaders-do-not-quote-the-shader-preamble-error.patch
patch sha256:           3d665841674e5c6a6b03005734ed9bb41c33a87cdbbe81d12351820b56b719b6
apply helper:           build/patch-singularity-scenefx.sh  (sha256 316641042c92f1121fdec7db31f1170b389c4e0b35ac276628868a32184683b1)
static gate:            build/check-singularity-shaders.sh   (sha256 7d29913f0fae08e473ef84a0641a53270dcfe5b977be7ea71e1367647033c576)
hardware smoke:         assets/singularity/scenefx-smoke/run_probe.sh (probe sha256 d31bd537b9d535257cc24746acbfbe3b75c22f9307ca0c4276c95df6687aa8d5)
```

The patch de-quotes the two `#error` directives only; it changes no shader
behaviour (the preamble is always substituted before compile).

## 3. Vendor-Mali smoke result (O6N, the failing test bed)

- Host: O6N `ncz-beemim-4060`, kernel `7.3.0-rc6-sky1-ncz`, rEFInd entry `7.3 Mali`
  (`module_blacklist=panthor,… sky1.gpu=vendor`, `mali_kbase`, `/dev/mali0`).
- Driver: `GL_VENDOR=ARM`, `GL_RENDERER=Mali-G720-Immortalis`,
  `GL_VERSION=OpenGL ES 3.2 v1.r53p0-00eac0.…`, EGL `1.5 Valhall-"r53p0-00eac0"`.
- `run_probe.sh <scenefx> <out> --require-mali`:
  - **patched: `programs=15 failures=0 expected=15`, rc 0.**
  - unpatched: `programs=15 failures=8`, rc 1 (quad, quad_clip, tex_rgba,
    tex_rgbx, tex_ext, tex_effects_rgba, tex_effects_rgbx, tex_effects_ext).
- A/B (same host/env): unpatched labwc (`e53a0286`) exits 1; last-known-good
  labwc (`b69d3482`) and the 4-byte-patched labwc both exit 0.

## 4. Filling the receipt after a payload build

Run `assets/singularity/scenefx-smoke/run_probe.sh <scenefx> <out> --require-mali`
on O6N (or any Sky1 Mali board) and paste the build's own identity:

```
payload deb:      ncz-singularity-desktop_<version>_arm64.deb
payload sha256:   <sha256>
resolved sources: <path> <commit>  (from singularity-opt.tgz.sources / resolver source-resolution.json)
mali smoke:       programs=15 failures=0  --require-mali  (Mali-G720-Immortalis, r53p0)
```

An **enforceable** acceptance gate that binds the built deb's resolved sources
and patch hash to this receipt is owned by the sibling `latest_payload` /
provenance work (`build/check-singularity-mali-receipt.py`); this document is
its input. Until that gate lands, the source→deb binding here is documented,
not machine-enforced.
