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
| `amd64/ncz-console-saver` | `ncz-screensavers` `2367884f7ff31c03ce855a8d6247bd0705311eae` (`hv/ncz-lt-saver-inhibit-fifo-fix-20261111`), cargo 1.97.1 | `59932b579a34f341f709709029aa30de146c68a12b446c9da7516bad094ddd03` |
| `arm64/ncz-console-saver` | same commit, cargo 1.98.0 on aarch64 | `ae87fe6481cd3da209d0cfd3a29635f9b63614748c9c72fa3220075beaaee466` |
| `amd64/ncz-bh-console` | unchanged from the prior asset commit | `54b669e74d6a2ec23bd9d8eacc0f17598ee5206886a0ff460d928966b55a2a63` |
| `arm64/ncz-bh-console` | unchanged from the prior asset commit | `cfa589c910f5d5ed7dda56567fef037fd848588027e36a9d0e2079ffbd3e2dbf` |

The `2367884f` fix (2026-11-11): the suspend-inhibitor probe read every entry
under `/run/systemd/inhibit/`, including logind's per-lock `.ref` FIFOs, and
blocked forever — the daemon froze on its first tick (the saver never armed,
no log line) and SIGTERM could not interrupt the blocked read (restart needed
SIGKILL). The probe now skips non-regular entries; `MODE=block`-only record
matching is unchanged. Regression tests in the source tree cover the FIFO
entries and NetworkManager's verbatim `MODE=delay` record.
