# Installer boot UX (arm64 Sky1 and amd64)

Status 2026-09-29. One code path for both architectures (`preseed/`, `build/`); only the kernel command line in
the rEFInd entries differs. Evidence (before/after) is under `docs/installer-ux/`.

## What the operator saw and what caused it

The photos from the MS-R1 and Radxa Orion O6N were of image 18e8a14 (and 7e1d9c2 for the em dash). Each row was reproduced in
KVM with the console-capture harness before it was changed.

| Symptom | Root cause (proved) | Fix | Gate |
|---|---|---|---|
| Component dialog row `desktop <ERR>`, title cut to `NCZ-OS install` | An EM DASH (U+2014) in the d-i template text. newt runs in the C locale in early d-i and cannot draw it; the rest of the paragraph is dropped. (The earlier `Choices-C` fix did not touch this.) | All d-i template text is ASCII (`component-selector.sh`, `disk-fs-chooser.sh`, `locale-keyboard-chooser.sh`, `late.sh` progress). The redundant multi-paragraph component text, which blanked the whole description under newt, is gone. | `build/test-installer-screens.sh` static ASCII check; the screen checker rejects `<ERR>` |
| `[diag]`, `ssh root@IP (password: ...)`, `[ncz components]` written over the dialog | `diag-console.sh`, `component-selector.sh` and two `preseed.cfg` loops wrote to `/dev/ttyAMA0` and `/dev/ttyS0`. When the console is a serial port (every KVM run, and headless installs) that port IS the terminal newt draws on. In 18e8a14 they also wrote to `/dev/console` and tty1. | Chatter goes to VT3 (Alt+F3) and log files only; nothing writes to the UI terminal. The default diag password is never printed. Failures (`FATAL`, `ABORT`) still reach the console. | screen checker rejects `[diag]`, `[ncz`, `password:` |
| Empty blue screen with only a light bar at the bottom, between the component dialog and the next question | newt's root window plus its help line ("<Tab> moves; ...") while d-i ran silent steps: `cdrom-detect`, the media preseed reload, `localechooser`, `load-cdrom`, `ethdetect`, `netcfg`. 14 to 25 s under KVM on BOTH arches, longer on hardware. | The hostname and component dialogs moved from the first `early_command` to `partman/early_command`, right before the disk chooser (`preseed.cfg`, `hostname-suggest.sh --prompt`, `component-selector.sh --prompt`). The silent steps now happen before the first dialog; after it, the questions and the install progress bars follow without a gap. A progress bar started from the helper does not survive the helper's exit (tried, and removed). | `build/kvm-installer-ui-check.sh` (below) |
| Stale-GPT clearing with no visible confirmation | The wipe ran silently inside the disk chooser. | Interactive installs get a review dialog ("ERASE /dev/x and install?", default No, lists disk, filesystem, rescue partition, components). Every erase shows a debconf progress bar naming the disk. Unattended runs (presets) log only. | verified by the harness on the new image |
| `Please press Enter to activate this console.` | busybox `askfirst` shells on tty2 and tty3 (d-i inittab). tty3 is also our log VT. | not changed: it lands on tty2/tty3, not on the UI terminal | screen checker rejects it on the UI terminal |

## Design in the image

* Every NCZ dialog frame title carries product, release and codename read from the medium
  (`NCZ-OS 26.7 Maximilian - name this computer`); the last body line carries platform and build
  (`arm64 (Sky1) | build c6806798`, `amd64 | build ...`). One helper, `preseed/ncz-ui.sh`.
* Order of the interactive block: hostname, components, disk, root filesystem, erase review, then progress bars.
* Diagnostics stay available without touching the screen: VT3, `/var/log/diag-console.log`, telnet/ssh/http.
* rEFInd 3 s timeout; Install entry `quiet loglevel=3 vt.global_cursor_default=0 consoleblank=0`.
* First boot of the installed system: the native KMS splash (`60-boot-splash.sh`).

Mockup (80x24; the real dialog also shows its own `<Go Back>` because partman runs it):

```
  +-----------[!!] NCZ-OS 26.7 Maximilian - optional components ------------+
  | Untick to skip an optional component. Enter accepts the defaults,        |
  | which install everything.                                                |
  |                                                                          |
  | arm64 (Sky1) | build c6806798                                            |
  |       [*] Full Singularity desktop (GUI labwc + greetd + branding)       |
  |       [*] ncz-recovery management container (nspawn)                     |
  |       [*] 4 GiB NCZRESCUE partition (rescue rootfs + kernel)             |
  |                                                    <Continue>            |
  +--------------------------------------------------------------------------+
```

Not built: a persistent stage list with per-stage marks, percentage bars for our own long steps beyond d-i's, and an
auto-reboot countdown. d-i's own progress dialogs and its `Remove the USB stick` note are what ship.

## How it is verified (and gated)

`build/boot-screens.py` boots the raw image as shipped (no hostname/components presets) and records what the operator
sees: arm64 reads the installer terminal (the serial port; `auto=true` makes `reopen-console` pick it) through a
VT100 emulator (`pyte`) into one text file per stable screen; amd64 samples the framebuffer through the qemu monitor
(newt's progress dialogs are not readable from the VT) and answers the dialogs on a timer. `build/check-installer-
screens.py` fails on `[diag]`, `[ncz...]`, credential text, `<ERR>`, the askfirst prompt, an unbranded dialog, and a
blank console after the component dialog. `build/kvm-installer-ui-check.sh` wraps both and runs at the end of
`build/kvm-install-gate-gpt.sh` for BOTH architectures; a missing `pyte` fails the gate.

Proof the gate rejects a bad image, on real defects and on both arches:

| image | arm64 | amd64 |
|---|---|---|
| dialogs early (c8e8be39 / 8c1ada79) | FAIL: blank console after the component dialog (0004-0029s) | FAIL: blank framebuffer 57 to 71 s after the component dialog |
| dialogs deferred (c6806798 and later) | PASS | PASS (21 distinct frames, never blank) |

Fixture tests, both directions: `build/test-installer-screens.sh` (15), `build/test-ncz-ui.sh` (15, incl. the
installer's busybox ash), `build/test-hostname-suggest.sh` (49).

## Only the real boards can show

The physical screen (linlon/DRM takeover of the framebuffer, monitor timing), boot time on hardware, and how long
the pre-dialog silent stretch really is with a slow link or USB rescans (KVM: 15 to 40 s).
