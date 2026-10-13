# Singularity payload — vendor-Mali SceneFX shader gate

Regression fixed: **Orion O6 default `7.3 Mali` boot black-screened** because the
pinned labwc bundle gained SceneFX 0.5, whose `quad.frag`/`tex.frag` quote a
`#error` that the CIX/ARM libmali GLES compiler rejects even inside a disabled
preprocessor branch. Full writeup: `assets/singularity/MALI-VERIFIED.md`.

This is the release-runbook step for the gate.

## Every payload build (automatic)

`build/build-singularity.sh`:
1. resolves labwc's `subprojects/scenefx.wrap` and applies
   `assets/singularity/scenefx-patches/` to the checked-out SceneFX **before**
   `make compile` (`build/patch-singularity-scenefx.sh`; it verifies the
   checked-out SceneFX commit and fails closed);
2. runs `build/check-singularity-shaders.sh` on the staged labwc and **fails the
   build** if the binary embeds a quoted `#error` shader.

Offline parity: `build/test-singularity-mali-shaders.sh` (in `make parity`)
proves the static gate fails closed and that the carried patch de-quotes only
the two `#error` lines.

## Every release (hardware, on a Mali board — Orion O6 is the test bed)

```sh
# from a SceneFX checkout, or a labwc build tree with subprojects/scenefx
assets/singularity/scenefx-smoke/run_probe.sh <scenefx-source-root> <outdir> --require-mali
```

Expect `programs=15 failures=0`. `--require-mali` fails unless
`NCZ_GPU_BACKEND=mali` and the driver reports `GL_VENDOR=ARM`, so a Mesa run
can never be recorded as Mali-verified. Paste the `[summary]` line and the
built payload deb version + sha256 into `assets/singularity/MALI-VERIFIED.md`
(or the release receipt the resolver consumes).

Do **not** boot the Panthor entry to work around this — Mali is the default and
the payload must work on it. The restore path for an already-black box is in
`o6nmali/REPORT.md` (downgrade the payload deb, restart greetd).
