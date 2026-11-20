# Singularity patch queue R2D: other subprojects

Pinned revisions come from `.r2d-inputs/pins.tsv`. Evidence below is from those pinned trees; each queue patch was checked by `bash .r2d-inputs/replay.sh --no-fork`.

| Patch path | Verdict | Evidence and change |
|---|---|---|
| `assets/singularity/patches/libsingularity/0002-user-theme-loads-above-base.patch` | KEEP | Applies unchanged to pinned libsingularity `ad770bec28a8fe0f10f0290aaf968f9512b01a66`; changes the user theme provider priorities in `src/style/style_manager.vala`. |
| `assets/singularity/patches/libsingularity/0003-build-cups-flags-not-a-vala-package.patch` | PORT | Pinned `meson.build` has `epoxy_dep` on the `libsingularity_deps` line and does not have the old queue context. Refreshed the hunk against that line while preserving the C-only `ipp_transport.c` static library and link behavior. |
| `assets/singularity/patches/libsingularity/0004-drag-lift-construct-drag-icon-with-new.patch` | MERGE | Pinned `src/animation/drag_lift.vala` calls `Gtk.DragIcon.get_for_drag(drag)`; the fork patch adds `new` for the Vala 0.56 named constructor, and the old queue patch instead introduced an unowned binding. Replaced the old queue patch with one patch carrying the requested `new Gtk.DragIcon.get_for_drag(drag)` call; deleted `0004-drag-lift-bind-drag-icon-unowned.patch`. |
| `assets/singularity/patches/libsingularity/0005-compat-vala-0.56-brightness-primary-owned.patch` | PORT (added) | Pinned `src/system/brightness_manager.vala` has the nullable `primary` getter without ownership annotation. Added `owned get` as required for the Vala 0.56 compatibility fix. |
| `assets/singularity/patches/singularity-greeter/0001-greeter-cancel-session-before-recreate.patch` | PORT | Pinned `src/greeter_main.c` has drifted around the cancel, send, and reply hunks. Refreshed the patch against the current function bodies, preserving in-flight reply tracking and restarting only after the cancel acknowledgement. |
| `assets/singularity/patches/singularity-greeter/0002-greeter-answer-info-error-messages.patch` | KEEP | Applies unchanged to pinned greeter `0910299215db80277c0b199fbd8299b18875789c`; `src/greeter_main.c` adds the null response for informational/error PAM messages. |
| `assets/singularity/patches/singularity-greeter/0003-greeter-match-the-lock-login-card.patch` | PORT | Pinned `src/greeter_main.c` differs at the prompt handling and auth-label contexts. Refreshed those hunks while retaining the shared field label, prompt gating, and output-scale behavior. Removed prior AI attribution from the patch text. |
| `assets/singularity/patches/singularity-leafs/0001-window-keep-the-toolbar-in-classic-titlebar-and-ssd-modes.patch` | KEEP | Applies unchanged to pinned leafs `1cbf7facecd46ba2832e90c5cddf95d3c25ee109`; `git apply --check` succeeded in replay. |
| `assets/singularity/patches/singularity-loginui/0001-splash-fit-logo-to-surface-and-scale-loading-bar.patch` | KEEP | Applies unchanged to pinned loginui `1a599d8786323af7fa86667322953ed42547662f`; changes `src/render.c`. |
| `assets/singularity/patches/singularity-loginui/0002-brand-splash-keep-logo-aspect-session-only.patch` | PORT | Pinned `src/brand.c` uses the old square scaling code. Refreshed the patch on the current file: fit the logo with one scale factor, center it, select best Cairo filtering, and load a wider source image for wordmarks. |
| `assets/singularity/patches/singularity-loginui/0003-loginui-share-the-login-card-field-label-session-only.patch` | KEEP | Applies unchanged to pinned loginui `1a599d8786323af7fa86667322953ed42547662f`; adds the shared label helper in `loginui.h` and `src/render.c`. |
| `assets/singularity/patches/singularity-nearby/0002-fix-keep-an-open-link-when-the-peer-announces-itself.patch` | KEEP | Applies unchanged to pinned nearby `c17a12a4eea061890598bc45f2c7498696dbc14a`; replay reports APPLIED. |
| `assets/singularity/patches/singularity-plugins/0002-wallpapers-bing-preferred-market.patch` | KEEP | Applies unchanged to pinned plugins `ace60dbcbb06a7000ee4d9e972cc03531dbb3df3`; replay reports APPLIED. |
| `assets/singularity/patches/singularity-plugins/0004-wallpapers-bing-prefetch.patch` | KEEP | Applies unchanged to pinned plugins `ace60dbcbb06a7000ee4d9e972cc03531dbb3df3`; replay reports APPLIED. |
| `assets/singularity/patches/singularity-plugins/0007-sensors-popover-tabs-per-category.patch` | KEEP | Applies unchanged to pinned plugins `ace60dbcbb06a7000ee4d9e972cc03531dbb3df3`; replay reports APPLIED. |
| `assets/singularity/patches/singularity-session/0001-session-no-software-fallback-with-gpu.patch` | KEEP | Applies unchanged to pinned session `2a1f43316e069235cbd4f4246bc30f20c652edaa`; replay reports APPLIED. |
| `assets/singularity/patches/singularity-session/0002-supervisor-per-run-logs-signals-core.patch` | KEEP | Applies unchanged to pinned session `2a1f43316e069235cbd4f4246bc30f20c652edaa`; replay reports APPLIED. |
| `assets/singularity/patches/singularity-write/0001-write-implement-accessibletext-vfuncs-added-in-gtk-4-22.patch` | MERGE | Pinned `src/ui/doc_view.vala` lacks the five GTK 4.22 `Gtk.AccessibleText` methods. The fork patch `0001-write-implement-new-gtk-accessibletext-vfuncs.patch` and this queue patch implement the same methods; kept one canonical queue patch implementing them; the supplied fork input remains untouched for its owner to empty. |

## Build checks

Compile was **NOT verified**; no compile was run in this offline task. Build review should include these patches, which change C or Vala code beyond context refresh: libsingularity `0004` and `0005`, greeter `0001` and `0003`, loginui `0002`, and write `0001`.

## Final `--no-fork` replay output

The assigned subprojects all report APPLIED. The remaining FAIL lines are singularity-shell, outside this assignment.

```text
APPLIED cix/libsingularity/0002-user-theme-loads-above-base.patch
APPLIED cix/libsingularity/0003-build-cups-flags-not-a-vala-package.patch
APPLIED cix/libsingularity/0004-drag-lift-construct-drag-icon-with-new.patch
APPLIED cix/libsingularity/0005-compat-vala-0.56-brightness-primary-owned.patch
APPLIED cix/singularity-greeter/0001-greeter-cancel-session-before-recreate.patch
APPLIED cix/singularity-greeter/0002-greeter-answer-info-error-messages.patch
APPLIED cix/singularity-greeter/0003-greeter-match-the-lock-login-card.patch
APPLIED cix/singularity-leafs/0001-window-keep-the-toolbar-in-classic-titlebar-and-ssd-modes.patch
APPLIED cix/singularity-loginui/0001-splash-fit-logo-to-surface-and-scale-loading-bar.patch
APPLIED cix/singularity-loginui/0002-brand-splash-keep-logo-aspect-session-only.patch
APPLIED cix/singularity-loginui/0003-loginui-share-the-login-card-field-label-session-only.patch
APPLIED cix/singularity-nearby/0002-fix-keep-an-open-link-when-the-peer-announces-itself.patch
APPLIED cix/singularity-plugins/0002-wallpapers-bing-preferred-market.patch
APPLIED cix/singularity-plugins/0004-wallpapers-bing-prefetch.patch
APPLIED cix/singularity-plugins/0007-sensors-popover-tabs-per-category.patch
APPLIED cix/singularity-session/0001-session-no-software-fallback-with-gpu.patch
APPLIED cix/singularity-session/0002-supervisor-per-run-logs-signals-core.patch
APPLIED cix/singularity-shell/0003-plain-contrast-live-quadrant-and-wrap.patch
APPLIED cix/singularity-shell/0005-plugins-add-a-screensaver-and-lock-category.patch
APPLIED cix/singularity-shell/0013-lockscreen-honour-output-scale.patch
APPLIED cix/singularity-shell/0013-lockscreen-keep-the-keyboard-diagnostics.patch
APPLIED cix/singularity-shell/0014-lockscreen-host-an-out-of-process-frame-source.patch
FAIL    cix/singularity-shell/0015-lockscreen-overlay-unlock-prompt-on-screensaver.patch :: error: patch failed: src/lockscreen/lock_main.c:483
FAIL    cix/singularity-shell/0016-lockscreen-no-prompt-on-pointer-enter.patch :: error: patch failed: src/lockscreen/lock_main.c:1017
FAIL    cix/singularity-shell/0017-lockscreen-freeze-saver-on-input.patch :: error: patch failed: src/lockscreen/lock_framesrc.c:53
FAIL    cix/singularity-shell/0018-lockscreen-share-the-login-card-field-label.patch :: error: patch failed: src/lockscreen/lock_main.c:120
FAIL    cix/singularity-shell/0019-lockscreen-yield-to-a-concurrent-lock-instance.patch :: error: patch failed: src/lockscreen/lock_framesrc.c:546
FAIL    cix/singularity-shell/0020-lockscreen-keep-the-frame-source-backoff-across-handshakes.patch :: error: patch failed: src/lockscreen/lock_framesrc.c:523
FAIL    cix/singularity-shell/0021-overview-keep-the-app-grid-clear-of-the-dock.patch :: error: patch failed: src/components/overview/overview.vala:385
APPLIED cix/singularity-shell/0022-core-follow-logind-lock-and-prepareforsleep.patch
FAIL    cix/singularity-shell/0023-lockscreen-resume-the-saver-when-the-prompt-lowers.patch :: error: patch failed: src/lockscreen/lock_framesrc.c:712
FAIL    cix/singularity-shell/0024-lockscreen-suspend-the-saver-behind-the-prompt.patch :: error: patch failed: src/lockscreen/lock_framesrc.c:75
APPLIED cix/singularity-shell/0025-about-keep-the-distro-logo-aspect-ratio.patch
APPLIED cix/singularity-write/0001-write-implement-accessibletext-vfuncs-added-in-gtk-4-22.patch
```

## Verification limits

The requested prior-work memory lookup could not be completed: the connected mnemos search was denied by the current approval policy, and no mnemos record tool was available in this session. No upstream changes were retired, so no upstream commit attribution was needed.

## Cleanup receipt

Removed all scratch trees and scripts from `.r2d-inputs/work/`; left the `.r2d-inputs` pins, replay script, bundles, and fork patch inputs unchanged. No commit or push was performed.
