SCOPE:
1. GPU (Mali-G720-Immortalis / panthor): glmark2-es2 + vulkan-tools test, mesa+vulkan utils already installed by post-install/16-gpu-userspace.sh; verify VK_ICD_FILENAMES, vkcube renders, panfrost vs panthor driver bind, DP display link trains.
2. CPU (Cortex-A720+A520 12c): stress-ng across all cores 30 min, cpufreq governor scaling test, thermal throttle headroom, SMP fairness, AVX/NEON SIMD smoke.
3. cross-arch ic-engine smoke (already ran v4.1.34 cobol on .66; rerun for 7.0.9 to detect any regression in 90/90 trials baseline).
4. MNEMOS embed via Sky1 NPU bge-small (per fleet-roles canonical NPU scope: embeddings ARE in scope) — validate /pantheon/v1/embeddings 200 OK + measured tok/s vs PYTHIA Xe iGPU baseline.
DELIVERABLE: docs/MSR1-7.0.9-validation-2026-05-24.md in cix-installer repo, sections per scope item, with PASS/FAIL + measured metrics. Commit on r75-review branch (or newer if rebased).