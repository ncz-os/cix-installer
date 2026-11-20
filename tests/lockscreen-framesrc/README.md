# lockscreen frame-source host — headless test

The lock client can present buffers rendered by a **separate process** (a
screensaver) on its `ext-session-lock-v1` surfaces, so a screensaver is visible
while the session is locked. The lock never runs renderer code, so a renderer
fault can only make it fall back to its own prompt.

The frame source keeps running while the lock is held. The first **real input**
raises the unlock prompt **over the held frame** (a translucent scrim, not a
flat background) and the saver is frozen/suspended, never left streaming behind
the prompt. When the prompt has been idle for the delay it lowers and the saver
resumes. If the source crashes, hangs or errors without a HOLD, the prompt stays
on a **flat dark fill**: fail-closed, the lock is still held.

**No prompt before input.** Mapping the lock surface under a *stationary* cursor
must NOT raise the prompt: a compositor pointer ENTER (and, on some compositors,
an initial motion at the entered position) is not user input. Only a real key
press, pointer button or pointer movement raises the prompt.

## Pause / freeze / HOLD contract

The source and the lock distinguish three stop modes:

- **freeze on demand** — the lock sends a control stop and the saver halts at the
  current frame; the frame is **kept** (never `cleared frames (fail-closed)`).
  Input while locked freezes the saver this way; the frame stays for the prompt.
- **pause** — a source that advertised `LFS_FLAG_PAUSE` in HELLO is suspended
  with `LFS_PAUSE` (no frames, frame held) and **continued** by the prompt
  timeout (`frame source resumed (renderer continues)`), with **no respawn**: the
  same process keeps running (`the source never saw PAUSE` is a failure).
- **HOLD** — the source declares it stopped rendering on purpose
  (`frame source HOLD: keeping the last frame`); the lock keeps the last frame,
  does **not** treat it as a fault, and does **not** clear it. A source that
  simply dies does the opposite: `cleared frames (fail-closed)`.

The prompt timeout is clamped to **at most 60 s** (`lock: prompt timeout 60000
ms`); a shorter requested timeout is kept verbatim.

## Exact owned-process cleanup

There is **no broad `pkill -f` / `pgrep -f` anywhere** in the harness. Every lock
client is launched with `setsid`, so the client and every frame-source
descendant it spawns live in ONE fresh process group whose `PGID == the lock
PID` (the group leader). That `PID:PGID:generation` triple is recorded at launch.

- The renderer is discovered **only** by walking `/proc` for members of the
  owned PGID and confirming `/proc/<pid>/exe` resolves to the real `$SRC` binary.
  A process that merely shares the `…-testsrc` basename is never matched.
- Fault injection (`kill -9` of the source) targets **only** an owned,
  exe-verified PID.
- Cleanup kills **only** the owned groups (`kill -9 -- -PGID`) and owned PIDs and
  then `wait`s for each, so no zombie leaks into the next case.
- The two-lock case (10) records **both** exact owned groups and cleans up each
  by its own PGID.

A synthetic canary (`task/tmp/canary-owned-cleanup.sh`) pins this: an owned
source descendant is discovered and cleaned, an unrelated same-basename process
survives, and nothing leaks. It uses only `/bin/sleep` copies — no GPU, no
compositor, no network.

## Source inputs / build

`build.sh` builds the three binaries the suite needs from explicit sources — no
stale copies are embedded:

| var | meaning |
|---|---|
| `SHELL_SRC` | singularity-shell meson root (`src/lockscreen/…`, `protocols/…`) |
| `LOGINUI_SRC` | singularity-loginui meson root (`loginui.h`, `widget.h`, `src/*.c`) |
| `WORK` | scratch dir holding the binaries and `tmp/` |

If unset, `build.sh` probes the payload tree under
`…/work/singularity-desktop/subprojects/` before failing fast. It compiles the
feature-**off** and feature-**on** (`-DLOCK_FRAMESRC`) locks plus
`singularity-lock-framesrc-testsrc`, generating the ext-session-lock-v1 protocol
with `wayland-scanner` into `$WORK` (which is on the include path).

`test-framesrc.sh` needs a real compositor in a throwaway environment. It drives
`labwc` (headless), a lock client, and the deterministic frame source, and
asserts on the lock's stderr and on real screen captures.

Environment (defaults assume the binaries are in `$WORK`, e.g. a container):

| var | meaning |
|---|---|
| `WORK` | scratch dir holding the binaries and `tmp/` |
| `LOCK` | feature-on lock client |
| `LOCKOFF` | feature-off lock client (case 6) |
| `SRC` | `singularity-lock-framesrc-testsrc` |

Requirements: `labwc`, `wtype`, `wayland-utils`, `grim`, `python3` with `PIL`.
The suite is 14 cases: frames render and input freezes the saver (1); `kill -9`
of the source, a hung source, a bad fd and a GPU error each keep the lock held
(2–5); the feature-off build is inert (6); HOLD keeps the last frame (7); a
crash clears it fail-closed (8); input before the freeze timer holds the frame
(9); a second lock client yields without clobbering the socket (10); a
crash-looping source backs off exponentially (11); no output means no source
(12); a pause-capable saver is suspended and resumed with no respawn (13); the
prompt timeout is clamped to 60 s (14).

### Owned-process engine

Ownership discovery, fault injection, and cleanup live in **one** shared file,
`tests/lockscreen-framesrc/owned-processes.sh`, sourced by both the harness and
the tracked unit test below. Neither copies the logic.

Ownership is recorded as `pid:pgid:generation:starttime`, where `starttime` is
the leader's Linux `/proc/<pid>/stat` start time (field 22). Before targeting a
group, `kill_owned_source`/`stop_all` verify the leader is **intact** (alive
*and* the same start time), so a reused PID can never qualify.

### Headless unit: `test-owned-cleanup.sh`

`test-owned-cleanup.sh` exercises the real engine with **no GPU, compositor, or
network**:

```sh
TMPDIR=/path/to/non-tmpfs/scratch bash tests/lockscreen-framesrc/test-owned-cleanup.sh
```

It requires an explicit `TMPDIR` (refuses a missing or `tmpfs` value rather than
defaulting to `/tmp`) and creates scratch under `<TMPDIR>/task/tmp/`. It builds
a real-src-named fixture in an owned `setsid` group plus an **unrelated canary
with the exact same basename** in another directory/group, then calls the actual
`owned_source_pid` / `kill_owned_source` / `stop_all` functions to assert owned
discovery, that fault injection refuses the unrelated PID, that cleanup reaps
the owned group while the canary survives, and that no owned orphan leaks. A
PASS here proves the production helper, not a copy.
