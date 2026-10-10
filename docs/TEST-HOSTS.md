# NCZ-OS canonical test fleet

The four hosts below are the **primary NCZ test systems** (operator directive
2026-10-10).  The nightly canary's hardware-smoke layer runs on all four; the
release-gating step (flashing a candidate weekly image and boot-testing it) stays
operator-only.

The machine-readable registry is `build/nightly/test-hosts.tsv`; the smoke runner
is `build/nightly/hw-smoke.sh`.  This document is the human contract.

## Roles

| Host | IP | Arch | GPU | Kernel (as of 2026-10-10) | Role |
|---|---|---|---|---|---|
| **O6N** (`ncz-beemim-4060`) | 192.168.207.3 | arm64 (CIX Sky1) | Mali-G720 (vendor libmali) | ncz sky1 | vendor-Mali arm64 primary — SceneFX/labwc colour, saver smoke |
| **MEDUSA** | 192.168.207.38 | amd64 (MacBookPro16,1 T2) | AMD Navi14 dGPU + Intel iGPU | `7.3.0-rc6-6-t2-edge-apple-sep-anfe-test` | T2 dGPU primary — real-GPU (radeonsi) payload + saver smoke |
| **CHIMERA** | 192.168.207.6 | amd64 (MacBookPro16,1 T2) | AMD Navi14 dGPU + Intel iGPU | `7.3.0-rc6-6-t2-edge-apple-sep-anfe-test` | second T2 dGPU — same as MEDUSA |
| **PEGASUS** | 192.168.207.85 | amd64 (ASUS ROG, NON-T2) | non-T2 dGPU | SEP test kernel | **control** machine: T2-vs-generic differences; verify identity before acting |

Credentials: MEDUSA/CHIMERA/PEGASUS use user `ncz`; PEGASUS creds live at
`~/.api_keys_master.json` → `fleet_test_hosts.pegasus_85_ncz`.  O6N is a dev
board reached as `root` with pubkey only (the smoke still writes only under that
user's `~/Projects`).

## Access method

* SSH from the build host, `BatchMode=yes`, `ConnectTimeout` bounded.  No agent
  assumptions.
* The smoke harness on each host, when used, lives under the host user's
  `~/Projects/ncz-nightly-smoke` (override per host with
  `NCZ_SMOKE_HARNESS_<HOST>`).  Nothing is written anywhere else.

## What the nightly MAY do on each host (read-only by default)

* Check reachability.
* Read DMI identity (`/sys/class/dmi/id/product_name`, `sys_vendor`).
* Check for a running GPU client (`ps -eo pid,comm | grep …`) and **SKIP** if one
  is found.
* Read `dmesg` and grep for the known regressions: `AER`, `ANFE`, `amdgpu`,
  `xhci`, `BCE` (read-only).
* With `--execute` **and** a present harness: launch the payload smoke
  (SceneFX probe / headless labwc / headless saver) **as the user**, headless,
  bounded by `timeout`, cleaning up by recorded exact PID.

## What the nightly must NEVER do on any of them

* Never `reboot`, never `flash`, never `suspend`/resume unattended.
* Never kill the desktop session; never interrupt a running test (a busy host is
  a recorded `SKIPPED(reason)`, not an interruption).
* Never read amdgpu debugfs (a read of `amdgpu_gpu_recover` resets the GPU and
  killed MEDUSA once).
* Never run two GPU clients at once (it invalidates numbers and slows the
  desktop).
* Never run as root except O6N's login account, and even there never write
  outside `~/Projects`.

## Operator hardware checklist (post-flash, operator-only)

After flashing the newest weekly that PASSED all gates, run on each host:

1. **O6N** — boot the vendor-Mali entry; confirm labwc starts (no SceneFX black
   screen), run `assets/singularity/scenefx-smoke/run_probe.sh`, one saver
   headless capture; check `dmesg` for SCMI/DVFS errors.
2. **MEDUSA** — boot on the T2 dGPU; run the amd64 payload smoke (labwc/SceneFX
   headless on radeonsi) + one saver capture; grep `dmesg` for AER/ANFE/amdgpu;
   do **not** touch amdgpu debugfs.
3. **CHIMERA** — same as MEDUSA.
4. **PEGASUS** — verify DMI identity first (non-T2), then the same amd64 payload
   smoke as the control; compare against the T2 results for T2-specific quirks.
