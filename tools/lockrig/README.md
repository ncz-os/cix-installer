# tools/lockrig — multi-host lock / saver / greeter test rig

Repeatable test rig for the NCZ lock screen + screensaver feed + greeter. It runs
a controlled suite (T1–T15) on every available test host, consolidates a
host×case matrix, and is designed to run **unchanged** against the RC6 images and
against the upcoming freeze-capable `ncz-screensavers 0.8.12` (+ `singularity-shell`
freeze patch). First run: 2026-10-12 (see `REPORT.md` in the mission dir).

```
tools/lockrig/
  hosts.tsv        # host inventory (name ip arch user display geometry gpu attended headless notes)
  lease.sh         # per-host lease: acquire/release/status/reap
  lockrig          # the driver: lockrig run --hosts ...
  report.sh        # consolidates per-host output into matrix.md / matrix.json / contact sheets
  test-lockrig.sh  # offline self-test (syntax + lease + report)
  Makefile         # make selftest | dry-run | run | run-all | status | matrix
  agent/           # deployed to each host (pushed under ~/Projects/lockrig/)
    preflight.sh   #   read-only host facts
    run_host.sh    #   live T1–T15 (runs as root on an NCZ host)
    headless.sh    #   headless labwc suite in a container (fallback / build hosts)
    lib/*.py       #   kbd2, ptr, evread, greetd_login, sampler, proctop
```

## Run

```
# offline validation of the rig itself (no hosts touched)
make selftest

# dry-run the headless labwc lock suite on the amd64 build host
tools/lockrig/lockrig run --hosts achilles --skip-install --out build/lockrig-out

# live run on the non-attended hosts
tools/lockrig/lockrig run --hosts pegasus,o6n,cixmini,proteus --out build/lockrig-out

# attended hosts LAST, one at a time (a human is physically present)
tools/lockrig/lockrig run --hosts chimera,medusa --allow-attended --out build/lockrig-out

# RC6 verification: install the candidate payload, then test (unchanged entry)
tools/lockrig/lockrig run --hosts pegasus,o6n --from-apt --out build/lockrig-out
tools/lockrig/lockrig run --hosts chimera --allow-attended --from-apt --out build/lockrig-out
```

Environment knobs:
- `LOCKRIG_OWNER`  — lease owner id (default `lockrig-<host>-<pid>`).
- `LOCKRIG_LEASE_DIR` — lease storage (default `~/Projects/oc-mission-20261010/hostlease`).
  Point this at the ARGONAS copy to share leases across machines.
- `LOCKRIG_STAGE_FEED` — abs path (on the host) to a freeze-capable
  `ncz-screensaver-feed` to use instead of the installed one (staged reversibly in
  the host scratch dir). Enables T3b/T4/T5/T8/T13/T15 on the pre-0.8.12 payload.
- `LOCKRIG_SKIP_GREETER=1` — skip the disruptive greeter cycle (T12).
- `LOCKRIG_BINDIR_ACHILLES` / `LOCKRIG_BINDIR_ULTRA` — harness binary dirs for the headless suite.

The driver never reboots. It acquires a lease before touching a host and refuses
if another owner holds a live lease. It leaves every host unlocked and logged in.

## Test cases

| id | case | pass condition |
|----|------|----------------|
| T1  | idle → lock at the 60 s override | lock client appears with no input |
| T2  | NO prompt before input | log has no `prompt raised over saver`; crops clean |
| T3  | saver animates during the intro | ≥3 distinct frame hashes over ~10 s + fps estimate |
| T3b | intro fps matches the policy | `lock_fps` from `--print-policy` vs captured fps |
| T4  | FREEZE after ~15 s | frame hash constant **and** feed CPU ~0 |
| T5  | held frame == last intro frame | hash equality with the last intro grab |
| T6  | pointer motion raises the prompt | uinput REL motion → prompt, still locked |
| T7  | key raises the prompt / stays locked | key → still locked |
| T8  | input before 15 s freezes immediately | frames constant after early input |
| T9  | wrong password rejected | still locked |
| T10 | right password unlocks | lock client exits, desktop returns |
| T11 | FAIL-CLOSED on feed `kill -9` | lock stays held, prompt reachable, correct pw unlocks |
| T12 | greeter login | wrong pw → no session; right pw → session starts |
| T13 | thermal governor (simulated hot) | feed pauses/drops fps above the threshold |
| T14 | DPMS blank-after-N | output blanks while locked, wakes on input |
| T15 | policy defaults present | `env -i feed --print-policy` carries `lock_fps=8 … freeze=always … freeze_after_s=15` |
| TRESTORE | host restore | unlocked, logged in, gsettings reset |

On hosts without a display (PROTEUS) or on the build hosts (ACHILLES/ULTRA), the
live cases fall back to the **headless labwc harness** (`agent/headless.sh` runs
`tests/lockscreen-framesrc/test-framesrc.sh` in a container) and the result is
tagged `mode=headless` — it says so rather than pretending the live path ran.
Harness binaries are per-arch: an amd64 build runs on amd64 hosts (ACHILLES,
PROTEUS); an arm64 host (ULTRA) needs an arm64 build staged, else the case is
**SKIP** with the reason (never a false FAIL).

### Test seams (T13/T14 and the freeze feed)

T13 and T14 exercise the freeze-capable feed's knobs through
`/etc/ncz/lock-renderer.env` (which the session launcher sources at lock time).
The rig **backs the file up first and restores it after every case**, so the seam
is fully reversible. On a feed without a `--print-policy` marker (pre-0.8.12)
both cases are **SKIP**, so the rig is unchanged between payloads.

| case | seam written into `lock-renderer.env` | assertion |
|------|--------------------------------------|-----------|
| T13  | `NCZ_FEED_THERMAL_ROOT=<fake hot hwmon tree>` (`temp1_input=95000`) | feed pauses (frames constant) above ~85 °C |
| T14  | `NCZ_SAVER_BLANK_AFTER_S=8` | output blanks while locked (grim mean < 2 %) and input wakes the prompt over the held frame |

T4 records the power trajectory (`pwavg` over `power.csv`): package W, GPU W and
max CPU temp for the intro window vs the freeze window, so a freeze is evidenced
by a **power drop**, not just a constant frame hash.

The policy knobs the freeze feed consumes (from `thermals/REPORT.md`):
`NCZ_SAVER_LOCK_FPS=8`, `NCZ_SAVER_RENDER_DIV=2`, `NCZ_SAVER_FREEZE=always`,
`NCZ_SAVER_FREEZE_AFTER_S=15`, `NCZ_SAVER_BLANK_AFTER_S=600` (default), and the
`NCZ_FEED_THERMAL_ROOT` test seam. `--print-policy` emits the compiled-in
defaults; T15 requires `lock_fps=8 … freeze=always … freeze_after_s=15`.

## Adding a host

1. Append one line to `hosts.tsv` (tab-separated), columns:
   `name  ip  arch  user  display  geometry  gpu  attended  headless  notes`.
   - `display=1` if a DRM output is connected and a graphical session can run.
   - `attended=1` if a human is physically at the machine (forces `--allow-attended`
     and makes the host run LAST, one at a time).
   - `headless=1` to use the container harness instead of the live cases.
2. Ensure SSH works: test hosts use `ncz/ncz` (`SSHPASS=REDACTED`), build hosts use the
   operator's key. `sudo -S` with the login password must work on NCZ test hosts.
3. `make selftest` to confirm the table parses.

## Safety rules (non-negotiable)

1. **Attended hosts** (`chimera`, `medusa`) run only with `--allow-attended`, LAST,
   one at a time, and with a short lock window. The operator is physically present.
2. **Leases**: never touch a host without a lease. `lease.sh acquire` refuses if
   another owner holds a live lease. If a session crashed, `lease.sh reap` drops
   the expired lease (TTL, default 45 min).
3. **Never reboot.** The rig has no reboot path. Kernel/refind are out of scope.
4. **Bootloader guard**: before/after any apt op the rig hashes
   `/boot/efi/EFI/BOOT/refind.conf`; if an apt operation rewrites it the rig reports
   it (restore from the pre-op copy if changed). Rescue entries must survive.
5. **Install is simulated first**: `apt-get install -s` must show **0 removals** or
   the rig refuses to install.
6. **Restore**: gsettings `idle-delay`/`hack-idle-delay` reset, host unlocked and
   logged in, the rig's own PIDs killed, host scratch removed (`~/Projects/lockrig`).
   No `/tmp` tmpfs scratch — host scratch is always under `~/Projects/lockrig`.
7. **No secrets**: the rig uses the built-in `ncz/ncz` test login only.

## RC6 verification (exact commands)

```
# 1. rig self-test
tools/lockrig/test-lockrig.sh

# 2. non-attended live hosts, installing the RC6 candidate from the repo
tools/lockrig/lockrig run --hosts pegasus,o6n,cixmini --from-apt --out build/lockrig-out

# 3. headless hosts (PROTEUS has no display; build hosts run the suite)
tools/lockrig/lockrig run --hosts proteus,achilles --skip-install --out build/lockrig-out

# 4. attended hosts LAST, one at a time
tools/lockrig/lockrig run --hosts chimera --allow-attended --from-apt --out build/lockrig-out
tools/lockrig/lockrig run --hosts medusa  --allow-attended --from-apt --out build/lockrig-out

# 5. matrix + exit code (non-zero on any FAIL)
tools/lockrig/report.sh --out build/lockrig-out --hosts pegasus,o6n,cixmini,proteus,achilles,chimera,medusa
```

On the RC6 payload (no freeze feed) T3b/T4/T5/T8/T13/T14/T15 are expected
FAIL/SKIP; against `ncz-screensavers 0.8.12` + the shell freeze patch they must all
PASS. The rig is unchanged between the two: only the installed payload differs.
