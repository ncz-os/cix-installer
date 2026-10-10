# SceneFX shader smoke — vendor-Mali regression gate

Hardware half of the O6N/Mali SceneFX black-screen gate (2026-10-10). Compiles
**every** SceneFX GLSL program through the *target* GLES driver and prints the
driver's own compile/link info log — which SceneFX's `compile_shader()` discards
(it only logs `Failed to compile shader`, not the `glGetShaderInfoLog` text).

## Why this exists

labwc (singularity branch, ≥ `2da90c41`) bundles **SceneFX 0.5** as a meson
`[wrap-git]` subproject and creates its fx renderer unconditionally at startup.
SceneFX's `quad.frag`/`tex.frag` guard the runtime-format preamble with
`#error "Missing shader preamble"`. The CIX/ARM **libmali** GLES compiler
(Valhall `r53p0-00eac0`, Mali-G720-Immortalis) rejects the double quote —
`L0001: Unknown character '"'(34)` — **even though the directive sits in a
disabled preprocessor branch** (the guard macro *is* defined). `glCompileShader`
fails, labwc cannot create the fx renderer, greetd crash-loops and the Sky1 Mali
boot is a black screen. Mesa/Panthor discard the inactive block correctly, so
the regression only appears on the vendor-Mali boot entry.

The fix de-quotes the two directives
(`assets/singularity/scenefx-patches/0001-*.patch`, applied by
`build/patch-singularity-scenefx.sh`). It changes no shader behaviour: the
preamble is always substituted before compile.

## Run it (on a Mali board, e.g. O6N)

```sh
# from a scenefx checkout (or a labwc build tree with subprojects/scenefx)
./run_probe.sh /path/to/scenefx
```

Output on a healthy (patched) payload — all 15 programs OK:

```
[driver] GL_RENDERER               = Mali-G720-Immortalis
[driver] GL_VERSION                = OpenGL ES 3.2 v1.r53p0-00eac0...
=== quad ===
  VERT     OK
  FRAG     OK
  LINK     OK
...
[summary] programs=15 failures=0
```

Unpatched payload fails `quad`, `quad_clip`, `tex_rgba`, `tex_rgbx`, `tex_ext`,
`tex_effects_rgba`, `tex_effects_rgbx`, `tex_effects_ext` with
`L0001: Unknown character '"'(34)` pointing at the `#error` line.

## Static counterpart

`build/check-singularity-shaders.sh <labwc>` runs in every payload build and
fails if the staged labwc embeds a quoted `#error` shader (no GPU required).
