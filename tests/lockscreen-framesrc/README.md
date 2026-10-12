# lockscreen frame-source host — headless test

The lock client can present buffers rendered by a **separate process** (a
screensaver) on its `ext-session-lock-v1` surfaces, so a screensaver is visible
while the session is locked. The lock never runs renderer code, so a renderer
fault can only make it fall back to its own prompt.

The frame source keeps running while the lock is held. The first **real input**
raises the unlock prompt over the live saver — the clock and password card are
composited on top of the current frame with a translucent scrim, not dropped
onto a flat background — and after the prompt has been idle the raw frames show
again. If the source stops (crash, hang, GPU error), the prompt stays and is
drawn over a dark scrim: the lock is still held.

**No prompt before input.** Mapping the lock surface under a *stationary* cursor
must NOT raise the prompt: the compositor delivers a pointer ENTER (and, on some
compositors, an initial motion at the entered position) with no user action, and
that is not input. Only a real key press, pointer button or pointer movement
raises the prompt. The idle-lock flow is therefore:

`idle -> lock held + saver frames shown, NO prompt -> first real input -> prompt
over the live saver -> idle -> raw saver -> input again …`

This directory is the version-controlled copy of the harness that pins that
contract. It is exercised against the payload binary built from this repo's
singularity-shell patch queue (0013/0014/0015/0016).

Build with the feature on:

```sh
meson setup build -Dlock_framesrc=enabled
ninja -C build
```

`test-framesrc.sh` needs a real compositor in a throwaway environment. It drives
`labwc` (headless), a lock client, and `singularity-lock-framesrc-testsrc` (a
deterministic frame source that renders a trivial pattern into a memfd — no GPU),
and asserts on the lock's stderr and on real screen captures:

- frames from the source are presented; a key press raises the prompt **without
  stopping the source**, frames keep streaming behind it, and a screen capture
  shows the backdrop is the live saver rather than a flat fill;
- after the prompt is idle the raw frames return;
- with the cursor over the output **before** the lock starts, a stationary
  pointer (ENTER) does **not** raise the prompt, while a real pointer move, a
  pointer button and a key press each do (cases 7-9);
- `kill -9` of the source, a hung source, a short buffer fd and a source that
  dies on a GPU error each leave the **lock held** and the client alive;
- a build with the feature **off** is inert.

Environment (defaults assume the binaries are in `$WORK`, e.g. a container):

| var | meaning |
|---|---|
| `WORK` | scratch dir holding the binaries and `tmp/` |
| `LOCK` | feature-on lock client |
| `LOCKOFF` | feature-off lock client (case 6) |
| `SRC` | `singularity-lock-framesrc-testsrc` |

Requirements in the test environment: `labwc`, `wtype`, `wlrctl` (virtual
pointer for cases 7-9), `wayland-utils`, `grim`, `python3` with `PIL`. If
`wlrctl` or the `zwlr_virtual_pointer_manager_v1` protocol is unavailable the
pointer cases are skipped (they need a compositor that can inject a pointer).
