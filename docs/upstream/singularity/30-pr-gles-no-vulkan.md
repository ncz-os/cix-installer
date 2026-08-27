# PR draft — GLES-only / no-Vulkan compatibility note + optional WLR_RENDERER hook

> **Branch:** `docs/gles-no-vulkan` (or `feat/labwc-session-wlr-renderer` if the guard lands)
> **Base:** `main`
> **Commit subject:** `docs: note GLES-only / no-Vulkan GPU support`
> (or `feat: honor WLR_RENDERER override in labwc session` if the code hook is included)
> **No attribution/co-author trailers.**
> This is the lightest / most speculative of the three — frame it as a **note + optional
> guard**, not a critical fix. File it last.

---

## Summary

**What:** Document that Singularity runs on **GLES-only GPUs with no Vulkan driver** (e.g.
Arm **Mali** via `libmali`), and optionally let the labwc session honor a `WLR_RENDERER`
override so boards with GLES-only GPUs can force the GLES2 renderer if auto-selection ever
mis-picks.

**Why:** On the CIX Sky1 (Mali-G720, GLES 3.x, no Vulkan) the full Singularity session
comes up correctly with **no changes** — but that's a non-obvious, reassuring fact worth
writing down, and the escape hatch is cheap insurance for the next GLES-only board.

**Scope boundary:** a docs note, plus (optionally) one guarded env passthrough in the labwc
session script. No renderer code, no meson changes.

**Blast radius:** documentation; if the optional hook is included, one line in
`singularity-labwc-session` that is a no-op unless `WLR_RENDERER` is already set.

## Why it already works

Two independent renderer decisions, both already GLES-friendly:

1. **GTK4 (the shell and apps):** the session sets `GSK_RENDERER=gl`
   (`subprojects/singularity-session/src/singularity-desktop-session`), so GTK uses its
   **GL** renderer and never requests the Vulkan (`ngl`/`vulkan`) path. This is the single
   most important thing, and it's already upstream. 

2. **wlroots (labwc's compositor backend):** wlroots auto-selects a renderer. When no
   Vulkan renderer is available (GLES-only driver), it falls back to **GLES2**
   automatically. labwc comes up clean on Mali `libmali` with no override.

So the change here is mostly to *document* this — a GLES-only GPU is a supported
configuration — rather than to fix anything.

## Proposed docs note

Add to `CONTRIBUTING.md` (near the architecture note) or a short `docs/` page:

```markdown
## GPU / renderer requirements

Singularity does **not** require Vulkan. It runs on GLES-only GPUs (e.g. Arm Mali via
`libmali`):

- The shell and apps use GTK4's GL renderer (`GSK_RENDERER=gl`, set by the session).
- labwc / wlroots auto-selects its GLES2 renderer when no Vulkan renderer is present.

This has been verified on the Arm Mali-G720 (CIX Sky1, GLES 3.x, no Vulkan driver). If your
GPU has both and you need to force GLES2 in the compositor, set `WLR_RENDERER=gles2` in the
environment before starting the session.
```

## Optional code hook (only if maintainers want the guard)

`singularity-labwc-session` doesn't currently pass `WLR_RENDERER` through. wlroots reads it
straight from the environment, so no change is strictly required — but making the passthrough
explicit documents the intent and lets a distro pin it. A minimal, no-op-by-default version:

```diff
--- a/subprojects/singularity-session/src/singularity-labwc-session
+++ b/subprojects/singularity-session/src/singularity-labwc-session
@@
 export PATH="$BIN:$PATH"
 export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
 export SINGULARITY_BLUR_ENABLED=1
+
+# GLES-only GPUs (e.g. Arm Mali via libmali) have no Vulkan renderer; wlroots
+# already falls back to GLES2 automatically. Honor an explicit override if the
+# environment or a distro has set one, but never force it by default.
+if [ -n "${WLR_RENDERER:-}" ]; then
+    export WLR_RENDERER
+fi
```

I'd lean toward **docs-only** as the default and treat the code hook as optional — wlroots
already reads the env var, so the guard is belt-and-suspenders. Whichever the maintainers
prefer.

## Validation evidence

- Full Singularity session (labwc + shell + apps) running on Arm Mali-G720 (CIX Sky1), no
  Vulkan driver present, no `WLR_RENDERER` override needed — GLES2 auto-selected.
- `GSK_RENDERER=gl` confirmed in effect; no Vulkan calls from GTK.

(Validated on NCZ-OS 26.7, CIX Sky1, Radxa Orion O6N + MS-R1.)

## Compatibility

Docs are additive. The optional hook is a no-op unless `WLR_RENDERER` is already set, so it
cannot regress Vulkan-capable systems.

## Rollback

Revert the single commit.
