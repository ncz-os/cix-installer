# ncz-console-saver

The Magnetar Server console screen-saver daemon (order 2026-11-09 04:40Z).
It runs the colour ASCII black-hole console (`ncz-bh-console`, sibling crate
in `tools/bh-console/rust`) on the text console after a period of idleness and
gives the console back on any input, with no operator action.

## What it does

* **Idle watch** — keyboard/mouse activity via `/dev/input/event*` (evdev),
  with `logind` IdleHint or the active VT's atime as fallbacks. The screen is
  never polled.
* **Inhibitors** — the saver does not arm while (a) an ncz test lease is held
  (`/run/ncz/test-lease`, the fleet-ops lease-aware blanking contract,
  `hv/ncz-lt-lease-aware-blank-20261108`), (b) the active VT is in
  `KD_GRAPHICS`, (c) a sleep/suspend inhibitor is held, or (d) someone typed
  within `idle_seconds`.
* **Run** — starts `ncz-bh-console` on a **free** virtual console (kernel
  `VT_OPENQRY`, never an occupied one), switches to it, and on any input event
  kills the saver by its exact PID, switches back and restores console
  mode/cursor/colours. Never on serial consoles (`ttyS*`/`ttyAMA*`).
* **Failure backoff** — if the saver exits or crashes, the VT is restored and
  the next attempt happens after the next idle period, backing off on
  repeated failure (`max_failures`, default 3), then it stays off and logs
  once.
* **Blanking** — while armed the daemon raises the kernel `consoleblank`
  (default 300 -> 1800): the saver runs first and the kernel blank is only a
  last-resort backstop if the daemon dies. The previous value is restored on
  exit. tmux/ssh sessions are untouched (the saver only claims a free VT).

## Packaging (PACKAGE decision)

Shipped through **the existing payload path**: the release build of
`ncz-console-saver` + `ncz-bh-console`, this unit and `/etc/ncz/console-saver.conf`
ride the server image's existing payload (the `ncz-pool`/`ncz-assets` bundles
built by `build/build-image.sh`), not a separate deb. The server post-install
enables `ncz-console-saver.service`; the desktop image is untouched.

## Configuration

`/etc/ncz/console-saver.conf` (see `packaging/console-saver.conf`):

| key | default | meaning |
| --- | --- | --- |
| `enabled` | `1` | `0` disables the daemon on next start |
| `idle_seconds` | `180` | console idleness before arming |
| `grid` | `auto` | `auto` = target VT size (`stty size`), or `COLSxROWS` |
| `colour` | `auto` | `auto` = from `$TERM`, or `16`/`256`/`24` |
| `scene` | `blackhole` | reserved; the console has one scene today |
| `max_failures` | `3` | crashes tolerated before staying off |

## Disabling

* `enabled = 0` in `/etc/ncz/console-saver.conf`, or
* `systemctl disable --now ncz-console-saver` on the server image.

## Tests

* `cargo test` — the idle state machine with a fake clock and fake input
  (`tests/test_idle_state.rs`) and the configuration parser.
* KVM gate (server image): boot, `idle_seconds = 10`, assert the saver runs on
  the free VT, inject a key, assert the VT is restored and no process is left;
  assert the unit is enabled on server and absent on desktop; CPU <= 2% of one
  core and RSS < 16 MB.

## Provenance (binary lineage)

`ncz-console-saver` is the Rust idle daemon from `ncz-screensavers`
`tools/bh-console/saver`; `ncz-bh-console` is its sibling crate in
`tools/bh-console/rust` (unchanged here). Release builds, vendored verbatim:

| file | source | sha256 |
| --- | --- | --- |
| `amd64/ncz-console-saver` | `ncz-screensavers` `a9e93673648914be9569cb836d1e2fe074334a24` (`hv/ncz-lt-saver-inhibit-fifo-fix-20261111`), Debian forky toolchain (rustc 1.97.1 source tarball, gcc 16.2.0-4) | `18b4f06a441c753fbdb7c686bb644fcd754e44164d324484f3af1973be1c4fa3` |
| `arm64/ncz-console-saver` | same commit, cargo 1.98.0 on aarch64 | `739577187420d828b3d49e3191b5facb86253e18e20bf2a457c4ba3dce0a2f1d` |
| `amd64/ncz-bh-console` | unchanged from the prior asset commit | `54b669e74d6a2ec23bd9d8eacc0f17598ee5206886a0ff460d928966b55a2a63` |
| `arm64/ncz-bh-console` | unchanged from the prior asset commit | `cfa589c910f5d5ed7dda56567fef037fd848588027e36a9d0e2079ffbd3e2dbf` |

The `2367884f` fix (2026-11-11): the suspend-inhibitor probe read every entry
under `/run/systemd/inhibit/`, including logind's per-lock `.ref` FIFOs, and
blocked forever — the daemon froze on its first tick (the saver never armed,
no log line) and SIGTERM could not interrupt the blocked read (restart needed
SIGKILL). The probe now skips non-regular entries; `MODE=block`-only record
matching is unchanged. Regression tests in the source tree cover the FIFO
entries and NetworkManager's verbatim `MODE=delay` record.

The `a9e93673` fix (2026-11-14): the saver's text output does not poke the
kernel blank timer, so the 30 min `consoleblank` backstop blanked the screen
mid-animation on long idles (two test machines). While the saver runs the daemon now
sets the blank interval to 0 (`ESC[9;0]` on the saver's VT, re-asserted each
tick in case `ncz-console-blank` or setterm re-arm it) and restores the backstop
when the saver ends. The idle timer also counts from daemon start, so a service
restart on an old uptime no longer starts the saver at once.

The amd64 binary was REBUILT on the Debian forky toolchain (2026-11-15): the
first `a9e93673` amd64 build (cargo 1.98.0, sha256 `4610fc53…`) carried an
Ubuntu linker string (`GCC: (Ubuntu 15.2.0-16ubuntu1)`) and failed the image's
`check-no-ubuntu` gate — Ubuntu evidence is a hard failure there by design
(`build/forky-provenance.py`: no allow-by-reason mechanism). The replacement is
built from the same `a9e93673` source in a `debian:forky` container (rustc
1.97.1 built from a source tarball, gcc (Debian 16.2.0-4)) — the same lineage
as the pre-`a9e93673` vendored amd64 binary — and passes
`build/test-console-blank.sh` (the `ESC[9;0]` escape gate) unchanged. The
arm64 binary stays the `a9e93673` build as vendored: its ELF carries Red Hat
GCC strings, matching the arm64 lineage of the previous vendored binary, and
the gate's Ubuntu-evidence check passes on it.
