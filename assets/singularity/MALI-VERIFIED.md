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
