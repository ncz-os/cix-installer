# Singularity payload — vendor-Mali (SceneFX) verification receipt

Regression: **O6N default `7.3 Mali` rEFInd entry booted to a black screen**
(greetd `start-limit-hit`) after the pinned payload moved labwc from a
plain-wlroots build to one bundling **SceneFX 0.5**. Recorded 2026-10-10.

## Last-known-good vs regressing payload

| | payload deb | labwc pin | SceneFX | Mali result |
|---|---|---|---|---|
| last-known-good | `ncz-singularity-desktop_20261007+bk0+tgzb69d3482_arm64.deb` | `6fe073cb94ddee9eefa2039671671139839ea5c91` | no | **desktop up** |
| regressing | `ncz-singularity-desktop_20261008005309+bk0+tgze53a0286_arm64.deb` | `2da90c41a34b734805cd360f7e4996ad30ec4087` | yes (0.5) | **black screen** |

The regressing pin entered with cix-installer commit `88e1641f`
("singularity: bump upstream pins to 2026-10-07 heads and rebase 5 carried
patches"); the SceneFX switch is upstream labwc commits `32f44e93` ("Render
ext-background-effect-v1 blur regions with SceneFX") and `a9f19c14`
("chore: build SceneFX statically as a subproject").

## Root cause (measured on hardware)

`/var/log/singularity-greeter/greeter.log`:

```
[ERROR] [render/fx_renderer/shaders.c:32] Failed to compile shader
[ERROR] [render/fx_renderer/fx_renderer.c:360] Could not link quad shader
[ERROR] [render/fx_renderer/fx_renderer.c:335] Failed to create the FX renderer
[ERROR] [../src/server.c:687] unable to create SceneFX fx renderer (GLES2 + DRM render node required)
```

`assets/singularity/scenefx-smoke/` on O6N (libmali) reports:

```
[driver] GL_VENDOR   = ARM
[driver] GL_RENDERER = Mali-G720-Immortalis
[driver] GL_VERSION  = OpenGL ES 3.2 v1.r53p0-00eac0...
0:4: L0001: Unknown character '"'(34)      <-- quad.frag line 4  (#error "…")
0:9: L0001: Unknown character '"'(34)      <-- tex.frag  line 9  (#error "…")
```

libmali rejects the `"` inside `#error` even in a disabled `#if` branch.

## Fix + verification

- Patch: `assets/singularity/scenefx-patches/0001-render-fx_renderer-shaders-do-not-quote-the-shader-preamble-error.patch`
- Applied by: `build/patch-singularity-scenefx.sh` (called from `build-singularity.sh`)
- Static gate: `build/check-singularity-shaders.sh` (every payload build)

Vendor-Mali smoke result (O6N, `sky1.gpu=vendor`, libmali `r53p0-00eac0`,
kernel `7.3.0-rc6-sky1-ncz`, 2026-10-10): **15/15 programs compile + link**
after the patch; the unpatched payload fails 8/15 (quad, quad_clip, tex_rgba,
tex_rgbx, tex_ext, tex_effects_rgba, tex_effects_rgbx, tex_effects_ext). A/B on
the same host/env: unpatched labwc (`e53a0286`) exits 1; the last-known-good
labwc (`b69d3482`) and the 4-byte-patched labwc both exit 0.

**Filling the receipt after a payload build:** run
`assets/singularity/scenefx-smoke/run_probe.sh` on O6N (or any Sky1 Mali board),
paste the `[summary] programs=N failures=0` line and the payload deb version
below, and update the table.

```
verified payload pin: <ncz-singularity-desktop_YYYYMMDD...+tgz...deb>
mali smoke:           programs=15 failures=0   (Mali-G720-Immortalis, r53p0)
```

## Latest-sources payload (r203 `refresh-sources --sources latest`, 2026-10-10)

The `refresh-sources` stage (`build/refresh-singularity-sources.sh --sources
latest`) resolved the current upstream heads and the arm64 payload was built on
ULTRA with the SceneFX patch:

| | value |
|---|---|
| payload deb | `ncz-singularity-desktop_20261010184606+bk0+tgza263986e_arm64.deb` |
| deb sha256 | `e88c03a89cb9fa58ec45cb20fbcb8a6035b420a9c416c0c58d8321cde091f321` |
| tarball sha256 | `a263986e89569d90480006f117fb01d01ca7570ea2f50114c6be1e16ae52876d` |
| superproject | `3c3c1f5245ea918383cd876311d7fdda67cb88d7` |
| labwc | `8a3efc4326859a01d1d8c497d92356615ead1859` |
| SceneFX (labwc wrap 0.5) | `37ccd723bef49e6891156ffafce8f549f01446cc` |
| libsingularity | `e665d3f50633ce771053a3a81afa00f78e1a5563` |
| static gate (`check-singularity-shaders.sh`) | **PASS** (0 quoted `#error`) |

Hardware smoke on **O6N** (`sky1.gpu=vendor`, Mali-G720-Immortalis, libmali
`r53p0-00eac0`) with the committed `assets/singularity/scenefx-smoke` harness,
using shaders generated from **this payload's** scenefx source
(`labwc@8a3efc43` → wrap `scenefx@0.5=37ccd72` + our patch):

```
[driver] GL_RENDERER = Mali-G720-Immortalis
[summary] programs=15 failures=0        # patched (our payload)   rc=0
[summary] programs=15 failures=8        # unpatched upstream 0.5  rc=1
```

Evidence: `rebuild/evidence/out-patched.log`, `out-raw.log`
(mission), copied to ARGONAS `reports/r203-amd64-evidence/`.

The latest upstream SceneFX `main` (`0070ae51…`) still carries the quoted
`#error`, so the patch remains required; `refresh-sources` records it and the
static gate keeps enforcing it.

