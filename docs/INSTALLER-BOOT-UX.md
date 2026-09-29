# Installer boot UX (arm64 Sky1 and amd64)

Status 2026-09-29. Applies to both architectures; the code is shared (`preseed/`, `build/`), nothing is per-arch
except the kernel command line in the rEFInd entries.

## What the operator saw (MS-R1, image 18e8a14) and what caused it

| Symptom | Root cause (proved) | Fix | Gate |
|---|---|---|---|
| Component dialog row rendered `desktop <ERR>`; dialog title cut to `NCZ-OS install` | An EM DASH (U+2014) in the d-i template `Description` and the description list. newt runs in the C locale in early d-i and cannot draw it. Reproduced in KVM on 7e1d9c2 (the earlier `Choices-C` fix did not touch this). | All d-i template text is ASCII (`component-selector.sh`, `disk-fs-chooser.sh`, `locale-keyboard-chooser.sh`, `late.sh` progress templates) | `build/test-installer-screens.sh` static ASCII check; screen checker rejects `<ERR>` |
| `[diag]` lines, `ssh root@IP (password: ...)`, `[ncz components]` lines written over the dialog | `diag-console.sh say()`, `component-selector.sh log()` and two `preseed.cfg` loops wrote to `/dev/ttyAMA0` and `/dev/ttyS0`. On an install whose console is a serial port (and in every KVM run) that port IS the terminal newt draws on; any write corrupts the dialog. | Chatter goes to VT3 (Alt+F3) and log files only. Nothing writes to the UI terminal; failures still go to `/dev/console`. The default diag password is never printed. | screen checker rejects `[diag]`, `[ncz`, `password:` |
| Blue screen with a light bar at the bottom | newt root window plus only its help line: the gap between dialogs while a long non-interactive step runs (KVM: 27 s to 44 s before the first dialog) | NOT fixed. Needs a progress dialog for the early phase (media detection, NIC bring-up). | none yet |
| `Please press Enter to activate this console.` | busybox `askfirst` shells on tty2 and tty3 (d-i inittab). tty3 is also our log VT. | not changed (contained to tty2/tty3, not the UI terminal) | screen checker rejects it on the UI terminal |

## Design now in the image

* Every NCZ dialog frame title carries the product, release and codename from the medium
  (`NCZ-OS 26.7 Maximilian - name this computer`), and the last body line carries the platform and build
  (`arm64 (Sky1) | build 7e1d9c2`, `amd64 | build ...`). One helper: `preseed/ncz-ui.sh`
  (`ncz_ui_brand`, `ncz_ui_id`), baked in the initrd and staged on the medium.
* Diagnostics stay available without touching the screen: VT3, `/var/log/diag-console.log`, telnet/ssh/http as
  before.
* rEFInd: 3 s timeout, `quiet loglevel=3 vt.global_cursor_default=0 consoleblank=0` on the Install entry; Expert
  keeps `loglevel=4`.
* First boot of the installed system: the native KMS splash (`60-boot-splash.sh`, singularity-boot-splash) is
  the boot screen; `98-gpu-health` and `97-firstboot-report` run quietly after multi-user.

## Mockup (80x24, ASCII-safe)

```
  NCZ-OS 26.7 Maximilian - optional components
  +--------------------------------------------------------------+
  | Untick to skip an optional component. Enter accepts the      |
  | defaults, which install everything.                          |
  |                                                              |
  |   [*] Full Singularity desktop (GUI labwc + greetd + ...)    |
  |   [*] ncz-recovery management container (nspawn)             |
  |   [*] 4 GiB NCZRESCUE partition (rescue rootfs + kernel)     |
  |                                                              |
  |  arm64 (Sky1) | build 7e1d9c2                                |
  |                          <Continue>                          |
  +--------------------------------------------------------------+
```

Not built (needs a redesign of how d-i draws long steps, tracked as follow-up): a persistent stage list with
per-stage marks, a percentage bar for partitioning / base install / desktop closure / bootloader, and an
auto-reboot countdown on the final screen. d-i's own progress dialog and the `Remove the USB stick` note are
what ship today.

## How it is verified

`build/boot-screens.py IMAGE WORKDIR --interactive --answer 'REGEX=KEYS'` boots the raw image under KVM exactly as
shipped, reads the installer's terminal (serial) through a VT100 emulator (`pyte`, install in a venv) and writes one
text file per stable screen to `WORKDIR/serial-screens/`, plus `screens/` (qemu framebuffer dumps) and, with `--vt`,
the fbcon VT text over the diagnostic telnet. `build/check-installer-screens.py DIR` then fails on `[diag]`,
`[ncz...]`, credential text, `<ERR>`, the askfirst prompt, and (with `--require-header`) a dialog without the
brand. `--require-dialog TEXT` proves the dialog was reached. Fixture tests: `build/test-installer-screens.sh`
(both directions), `build/test-ncz-ui.sh` (bash, sh, dash and the installer's busybox ash).

In KVM the installer's terminal is the serial port because `auto=true` makes `reopen-console` pick the first
console; on the real boards it is the monitor. The content is the same; only hardware can show the physical screen
(linlon/DRM takeover, boot timing).
