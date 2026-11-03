# PLAN-FB152: static gate over post-install scripts (cix-installer, base main)

## Measured corpus reality (2026-11-03, base main 9baa5eb4)
- 89 `post-install/*.sh`; ALL pass `bash -n` today.
- Strict mode: 41 declare `set -e`, 71 declare `set -u`, 24 use deliberate
  `set +e` (best-effort/forensics scripts, e.g. 99-diagnostics "NEVER aborts",
  05-time-sync "BEST-EFFORT, ALWAYS EXITS 0").
- 86 reference `/etc/` or `/usr/`; 74 match at least one guard token.
- Exclusions: `55*` = 55-greeter.sh + 55-t2-firmware.sh (exist, report-only);
  `npu-ssdt.sh` does NOT exist anywhere in the tree (stale exclusion, report);
  `forky-provenance.py` lives at `build/`, not `post-install/` (report).

## Design (ratchet, read-only)
Static pytest gate; NEVER executes a script (`bash -n` syntax check only,
plus text scans). Three per-script properties:
1. `bash -n` clean.
2. Strict mode (`set -e` present) OR named in the allowlist with a reason
   taken from the script's own header (best-effort/forensics).
3. Writers (reference /etc/ or /usr/): >=1 guard heuristic (marker/stamp
   file, `[ -f`/`[ -e`, `grep -q`, `install -m`, `mkdir -p`, `|| true`,
   `command -v`, `systemctl is-enabled|is-active`, `diff|cmp -s`)
   OR allowlisted with reason.
`55*` scripts are scanned and reported but never fail the suite. The
allowlist (`tests/postinstall_gate_allowlist.json`) grandfathers measured
reality with per-script reasons; NEW scripts must comply or be explicitly
added. A planted-bad-script self-test (temp overlay dir, monkeypatched scan
root) proves the gate fires on all three properties.

## Files
- New: `tests/test_postinstall_static_20261103.py` (stdlib + pytest only)
- New: `tests/postinstall_gate_allowlist.json` (measured exemptions)
- New: `docs/POSTINSTALL_GATE.md` (findings with file:line, stale exclusions)
- NO script edits: adding `set -e` to installer hooks is not proven safe
  without executing them, which the brief forbids. (Brief permits safe fixes;
  none clear that bar; recorded here.)

## Tests
- `test_all_scripts_pass_bash_n` (subprocess `bash -n`, read-only)
- `test_strict_mode_or_allowlisted` (+ planted strict violation fires)
- `test_writers_have_idempotence_guard_or_allowlisted` (+ planted viol. fires)
- `test_gate_fires_on_planted_bad_script` (all three properties at once)
- `test_allowlist_is_exact` (every entry names a real script + valid reason;
  no orphan entries; 55* never in allowlist since report-only)
- `test_excluded_paths_are_report_only` (55* scanned, reported, never fail)

## Risks
- Heuristic false negatives on exotic guard idioms → allowlist with reason,
  never weaken the heuristic silently (record in gate doc).
- `bash` on PATH required for the syntax check (present on any installer
  dev host; skip cleanly with a precise reason if absent).
- shellcheck is informational only, never a test dependency.
