# Post-install static gate (FB152)

Static, read-only gate over `post-install/*.sh`, enforced by
`tests/test_postinstall_static_20261103.py` (stdlib + pytest only; scripts
are never executed — `bash -n` syntax check plus text scans). Exemptions live
in `tests/postinstall_gate_allowlist.json`: anything predating the gate is
grandfathered with a reason, and every new hook must comply or be explicitly
added. A planted bad script proves the gate fires on all three properties.

## Corpus result at base main (89 live hooks)

- `bash -n`: all 89 parse cleanly.
- Strict mode (`set -e`): 43 declare it; 46 do not and are allowlisted below
  (18 declare a deliberate `set +e`; 28 simply predate the gate). Adding
  `errexit` to installer hooks is unproven without executing them, which is
  forbidden, so no hook was edited.
- Idempotence: all 86 hooks referencing `/etc/` or `/usr/` match at least
  one guard heuristic (marker/stamp file, `[ -f`/`[ -e`, `grep -q`,
  `install -m`, `mkdir -p`, `|| true`, `command -v`, `is-enabled/is-active`,
  `cmp -s`). Zero gaps; no idempotence exemptions exist.

## Strict-mode exemptions (46)

Deliberate `set +e` (best-effort/forensics style), file:line of the opt-out:

- post-install/32-quadlet-shim.sh:8
- post-install/35-fstrim-fix.sh:5
- post-install/36-telemetry.sh:39
- post-install/37-failsafe-access.sh:29
- post-install/39-usb-gpt-autofix.sh:33
- post-install/43-hw-quirks.sh:104
- post-install/50-brand.sh:14
- post-install/52-vivaldi.sh:29
- post-install/53-chrome.sh:36
- post-install/54-gpu-accel.sh:49
- post-install/57-qotd.sh:10
- post-install/80-npu.sh:39
- post-install/81-vpu.sh:45
- post-install/82-mali-gpu.sh:30
- post-install/83-panthor-gpu.sh:34
- post-install/84-vpu-mpv.sh:18
- post-install/84-vpu-vaapi.sh:59
- post-install/99-diagnostics.sh:16 (header: "NEVER aborts run-all.sh")

Grandfathered (no `set -e` anywhere; anchor is the shebang), all honest
pre-gate state:

- post-install/05-time-sync.sh:1 (header: "BEST-EFFORT, ALWAYS EXITS 0")
- post-install/13-firmware-bom.sh:1
- post-install/16-mesa-gpu-2613.sh:1
- post-install/21-flatpak-arch-filter.sh:1
- post-install/22-locale-gen.sh:1
- post-install/26-gpu-default-mali.sh:1
- post-install/37-ntp-hostname.sh:1
- post-install/41-usb2-rescan.sh:1
- post-install/44-apple-vbt-spoof.sh:1
- post-install/44-rtc-sync.sh:1
- post-install/46-python311.sh:1
- post-install/51-ncz-tour-slides.sh:1
- post-install/56-t2-dkms.sh:1
- post-install/59-desktop-curate.sh:1
- post-install/59-ncz-screensavers-pkg.sh:1
- post-install/61-chromium-icon.sh:1
- post-install/62-cygnus-screensaver-default.sh:1
- post-install/63-ncz-idle-lock-order.sh:1
- post-install/64-ncz-lock-saver-plan.sh:1
- post-install/64-t2-power-cap.sh:1
- post-install/65-ncz-titlebar-buttons.sh:1
- post-install/72-rescue-partition.sh:1
- post-install/79-dkms-prep.sh:1
- post-install/83-vpu-ffmpeg.sh:1
- post-install/86-cix-dkms-register.sh:1
- post-install/88-noe-umd-venv.sh:1
- post-install/97-firstboot-report.sh:1
- post-install/98-gpu-health.sh:1

## Report-only hooks (never fail, never allowlisted)

- post-install/55-greeter.sh (`set +e` at line 27)
- post-install/55-t2-firmware.sh (`set +e` at line 75)

## Stale exclusions in the brief

- `post-install/npu-ssdt.sh` does not exist anywhere in the tree at base
  main; nothing to exclude.
- `forky-provenance.py` lives at `build/forky-provenance.py`, not under
  `post-install/`; out of the gate's scope, untouched.
- `post-install/90-ota-channel.sh.disabled` is not a live hook (`.disabled`
  suffix) and is outside the gate; noted, untouched.

## shellcheck (informational only, not a test dependency)

`shellcheck -S warning post-install/*.sh` flags 25 files at warning level
or above on this host. Informational: shellcheck is not installed by the
gate and its findings are not enforced. Reproduce with the command above;
triage is future work, not this task.
