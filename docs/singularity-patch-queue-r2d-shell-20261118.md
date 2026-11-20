# Singularity shell patch queue, 2026-11-18

Pinned shell: `d72363e8269efc89c90ae1edae7c7bd85f48373d`. The queue is applied in filename order. No patch was retired: the pinned `render_output()` still selects the credential label directly, and `Overview.update_grid_columns()` still accounts for a side dock only when autohide is off; neither implements the respective queued change.

Fork 0002 is now in the queue. Fork 0011 is superseded by the two queue 0013 patches: `render_output()`, `output_scale()` and `output_done()` handle output scaling, while `kb_keymap()` logs unsupported format, mmap, keymap and state failures and `kb_key()` reports unavailable input. No functional gap in fork 0011 was found. Fork 0012's geometry diagnostic is dropped, as requested; the fork inputs remain unchanged.

| Patch | Verdict | Evidence / port change |
| --- | --- | --- |
| `0002-ncz-suppress-the-hot-corner-hint-badge.patch` | ADD | Copied fork hot-corner badge suppression; applies at the pin. |
| `0003-plain-contrast-live-quadrant-and-wrap.patch` | KEEP | Background contrast and wrapping still apply. |
| `0005-plugins-add-a-screensaver-and-lock-category.patch` | KEEP | Screensaver and lock plugin category still applies. |
| `0013-lockscreen-honour-output-scale.patch` | KEEP | Physical buffers, Cairo and Wayland output scale handling. |
| `0013-lockscreen-keep-the-keyboard-diagnostics.patch` | KEEP | Keyboard diagnostics and unavailable-keyboard prompt. |
| `0014-lockscreen-host-an-out-of-process-frame-source.patch` | KEEP | Introduces the out-of-process frame source and tests. |
| `0015-lockscreen-overlay-unlock-prompt-on-screensaver.patch` | PORT | Restored overlay backdrop around upstream authentication-label change. |
| `0016-lockscreen-no-prompt-on-pointer-enter.patch` | PORT | Refreshed context after the overlay port. |
| `0017-lockscreen-freeze-saver-on-input.patch` | PORT | Refreshed frame-source and test context for HOLD. |
| `0018-lockscreen-share-the-login-card-field-label.patch` | PORT | Uses shared label helper while preserving upstream PIN versus passphrase selection. **C logic adjusted.** |
| `0019-lockscreen-yield-to-a-concurrent-lock-instance.patch` | PORT | Refreshed context for concurrent lock socket ownership. |
| `0020-lockscreen-keep-the-frame-source-backoff-across-handshakes.patch` | PORT | Refreshed context for handshake backoff. |
| `0021-overview-keep-the-app-grid-clear-of-the-dock.patch` | PORT | Merged dock insets with upstream phone layout and form-factor-aware fallback icon sizing. **Vala logic adjusted.** |
| `0022-core-follow-logind-lock-and-prepareforsleep.patch` | KEEP | Logind lock and sleep handling applies. |
| `0023-lockscreen-resume-the-saver-when-the-prompt-lowers.patch` | PORT | Refreshed frame-source resume context. |
| `0024-lockscreen-suspend-the-saver-behind-the-prompt.patch` | PORT | Refreshed frame-source suspend context. |
| `0025-about-keep-the-distro-logo-aspect-ratio.patch` | KEEP | Distro logo aspect-ratio correction applies. |

For 0015, the rejected hunk was restored unchanged after upstream's modified label assignment. Only 0018 and 0021 required changes to C or Vala logic beyond context refresh. Compilation and runtime tests were not verifiable offline; the frame-source test additionally requires built binaries and a headless compositor.

`bash .r2d-inputs/replay.sh --no-fork` produced the following complete shell output:

```text
APPLIED cix/singularity-shell/0002-ncz-suppress-the-hot-corner-hint-badge.patch
APPLIED cix/singularity-shell/0003-plain-contrast-live-quadrant-and-wrap.patch
APPLIED cix/singularity-shell/0005-plugins-add-a-screensaver-and-lock-category.patch
APPLIED cix/singularity-shell/0013-lockscreen-honour-output-scale.patch
APPLIED cix/singularity-shell/0013-lockscreen-keep-the-keyboard-diagnostics.patch
APPLIED cix/singularity-shell/0014-lockscreen-host-an-out-of-process-frame-source.patch
APPLIED cix/singularity-shell/0015-lockscreen-overlay-unlock-prompt-on-screensaver.patch
APPLIED cix/singularity-shell/0016-lockscreen-no-prompt-on-pointer-enter.patch
APPLIED cix/singularity-shell/0017-lockscreen-freeze-saver-on-input.patch
APPLIED cix/singularity-shell/0018-lockscreen-share-the-login-card-field-label.patch
APPLIED cix/singularity-shell/0019-lockscreen-yield-to-a-concurrent-lock-instance.patch
APPLIED cix/singularity-shell/0020-lockscreen-keep-the-frame-source-backoff-across-handshakes.patch
APPLIED cix/singularity-shell/0021-overview-keep-the-app-grid-clear-of-the-dock.patch
APPLIED cix/singularity-shell/0022-core-follow-logind-lock-and-prepareforsleep.patch
APPLIED cix/singularity-shell/0023-lockscreen-resume-the-saver-when-the-prompt-lowers.patch
APPLIED cix/singularity-shell/0024-lockscreen-suspend-the-saver-behind-the-prompt.patch
APPLIED cix/singularity-shell/0025-about-keep-the-distro-logo-aspect-ratio.patch
```

The replay command exits 1 because unrelated libsingularity, singularity-greeter and singularity-loginui patches fail; all shell lines above applied.
