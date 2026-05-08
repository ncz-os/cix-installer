# Stability Sweep 6 - Desktop and Branding - 2026-05-08

## Executive summary

- Verdict: high-severity gaps were present in Magnetar headless gating and Plymouth staging.
- Patched in-place: 4 HIGH fixes across `post-install/20-desktop.sh`, `post-install/22-display-fix.sh`, `post-install/45-wallpaper-rotator.sh`, `post-install/56-icon-theme.sh`, and `post-install/60-plymouth.sh`; plus one `/etc/os-release` correctness fix in `post-install/50-brand.sh`. No commit made.
- Counts: HIGH 4, MEDIUM 6, LOW 5.
- XFCE remains the actual desktop default. `20-desktop.sh` sets LightDM `user-session=xfce`, but the current hook does not implement a real GNOME opt-in coexistence path.
- Magnetar server mode now uses the same `BUILD_VARIANT` sidecar as `48-magnetar-variant.sh` for the desktop-only hook skips. `50-brand.sh` and `60-plymouth.sh` still run on headless installs.

## Requested checks

- XFCE default: correct. LightDM defaults to `xfce` at `post-install/20-desktop.sh:61`, and `/etc/skel/.dmrc` is seeded with `Session=xfce` at `post-install/20-desktop.sh:370`.
- GNOME coexistence: not correct as a product contract. GNOME sessions are hidden and GNOME packages are purged at `post-install/20-desktop.sh:138` and `post-install/20-desktop.sh:150`.
- Magnetar skip mechanism: now consistent for desktop-only hooks. The sidecar is written by `preseed/late.sh:111` and consumed by `post-install/20-desktop.sh:8`, `post-install/22-display-fix.sh:11`, `post-install/45-wallpaper-rotator.sh:9`, and `post-install/56-icon-theme.sh:7`.
- Plymouth staging: now installs the theme assets, validates `background.png` and `lockup.png`, and rebuilds initrds for the target kernel versions from `KVER_LTS` and `KVER_NEXT`.
- `/etc/os-release`: now writes `PRETTY_NAME`, `NAME`, `VERSION_ID`, `BUILD_ID`, `ID`, `ID_LIKE=ubuntu`, `HOME_URL`, and `SUPPORT_URL` at `post-install/50-brand.sh:18`.
- Wallpaper rotator: not cron and not a system timer. It is a graphical-session autostart daemon from `/etc/xdg/autostart` at `post-install/45-wallpaper-rotator.sh:88` and loops every 600 seconds at `post-install/45-wallpaper-rotator.sh:81`.
- Icon theme: installs the theme system-wide, sets GNOME through dconf, and seeds XFCE through `/etc/skel`; the late installer hydrates `/etc/skel` into existing homes with `--ignore-existing` at `preseed/late.sh:263`.
- Display fix: pins the connected DRM card through `/etc/X11/xorg.conf.d/10-cixmini-primary-display.conf`, but does not set an explicit resolution.

## HIGH findings

### H1 - Magnetar server installs still ran desktop-only hooks before the headless toggle

File: `post-install/run-all.sh:167`, `post-install/run-all.sh:171`, `post-install/48-magnetar-variant.sh:18`, `preseed/late.sh:108`

Root cause: optional hooks run in numeric order. That means `20-desktop.sh`, `22-display-fix.sh`, `45-wallpaper-rotator.sh`, and `56-icon-theme.sh` ran before `48-magnetar-variant.sh` could set `multi-user.target` or mask display managers. The variant sidecar existed before post-install, but these hooks did not read it.

Why HIGH: a Magnetar install could still install XFCE, LightDM, xrdp, browser packages, Xorg display detector units, wallpaper autostart files, and icon theme defaults before being toggled headless. That violates the server SKU contract and leaves unnecessary graphical surface area on an appliance build.

Concrete diff applied:

- `20-desktop.sh` now exits early for `server|magnetar|headless` at `post-install/20-desktop.sh:8`.
- `22-display-fix.sh` now exits early for the same values at `post-install/22-display-fix.sh:11`.
- `45-wallpaper-rotator.sh` now exits early at `post-install/45-wallpaper-rotator.sh:9`.
- `56-icon-theme.sh` now exits early at `post-install/56-icon-theme.sh:7`.

### H2 - Plymouth theme was incomplete because `lockup.png` was never staged

File: `post-install/60-plymouth.sh:17`, `assets/branding/plymouth/nclawzero.script:19`, `assets/branding/plymouth/nclawzero.script:26`

Root cause: the Plymouth script references `background.png` and `lockup.png`, but the hook only converted the background image. The lockup source exists as `assets/branding/logo/nclawzero-lockup.jpg`, but no code placed it at `/usr/share/plymouth/themes/nclawzero/lockup.png`.

Why HIGH: a selected boot splash with a missing image can render as generic, broken, or blank depending on Plymouth script behavior. This is exactly the branding failure class in scope for this component.

Concrete diff applied:

- `60-plymouth.sh` now converts both background and lockup assets to the filenames used by the script at `post-install/60-plymouth.sh:27`.
- It validates all four required theme files and fails the optional hook loudly if any are missing at `post-install/60-plymouth.sh:40`.

### H3 - Plymouth initramfs rebuild used an implicit kernel instead of target NCZ kernels

File: `post-install/10-our-kernel.sh:110`, `post-install/60-plymouth.sh:78`, `post-install/60-plymouth.sh:100`, `post-install/80-npu.sh:100`

Root cause: `10-our-kernel.sh` creates target initrds for the staged NCZ kernels, but `60-plymouth.sh` previously ended with a plain `update-initramfs -u`. In a d-i chroot, implicit kernel selection can point at the installer/runtime kernel or only one installed kernel, not necessarily every staged NCZ kernel.

Why HIGH: the hook could report Plymouth success while the theme never landed in the initrd that systemd-boot actually loads.

Concrete diff applied:

- `60-plymouth.sh` now reads `/usr/local/lib/cix-installer/KVER_LTS` and `KVER_NEXT`, validates matching `/lib/modules/$kver`, and rebuilds each target initrd with `update-initramfs -u -k "$kver"` or `-c -k "$kver"`.
- If sidecars are unavailable, it falls back to existing `/boot/initrd.img-*` files and still requires matching module trees.
- Ordering is now correct for Plymouth: `10-our-kernel.sh` creates initrds, `60-plymouth.sh` rebuilds them with the selected splash, and `80-npu.sh` can still prepend its NPU SSDT CPIO before `70-bootloader.sh` stages the initrd to the ESP.

### H4 - Wallpaper rotation did not apply to active GNOME sessions

File: `post-install/45-wallpaper-rotator.sh:37`, `post-install/45-wallpaper-rotator.sh:51`, `post-install/20-desktop.sh:328`

Root cause: the rotator handled XFCE through `xfconf-query` and Openbox/Window Maker through `feh`/`wmsetbg`, but it never called GNOME `gsettings`. `20-desktop.sh` seeded a GNOME dconf default, but the 10-minute rotation path did not update GNOME sessions.

Why HIGH: the script claimed cross-DE wallpaper behavior but the GNOME path, if installed as an opt-in session, would not rotate and could keep stale or generic wallpaper after login.

Concrete diff applied:

- The rotator now detects GNOME from `XDG_CURRENT_DESKTOP`, `DESKTOP_SESSION`, or `gnome-shell`.
- It updates `org.gnome.desktop.background` `picture-uri`, `picture-uri-dark`, and `picture-options` at `post-install/45-wallpaper-rotator.sh:65`.

## MEDIUM findings

### M1 - GNOME opt-in coexistence is not implemented

File: `post-install/20-desktop.sh:30`, `post-install/20-desktop.sh:134`, `post-install/20-desktop.sh:150`

The XFCE default is deliberate and correct. LightDM is configured for XFCE, GDM is removed, and non-XFCE sessions are hidden. However, that means the current code does not match the requested "GNOME is opt-in" coexistence contract. There is no opt-in sidecar or env var that preserves GNOME packages and session files.

Recommended diff: add an explicit opt-in sidecar, for example `/usr/local/lib/cix-installer/ENABLE_GNOME`, that bypasses the GNOME purge and session hiding while keeping `user-session=xfce` as the LightDM default.

### M2 - Display fix pins a card, but does not set resolution

File: `post-install/22-display-fix.sh:32`, `post-install/22-display-fix.sh:53`, `post-install/22-display-fix.sh:76`

The hook detects connected DP/HDMI connectors, writes `Option "kmsdev"`, disables blanking, and removes seat tags from non-primary DRM cards. It does not write a `PreferredMode`, `Modeline`, or `xrandr` first-boot mode. The glob order checks DP connectors before HDMI connectors, so DP tends to win when both are connected.

Recommended diff: if MS-R1 needs a fixed operator mode, add a small connector-priority and mode sidecar, then write `Option "PreferredMode"` for the selected monitor.

### M3 - XFCE icon theme application is seeded, not enforced

File: `post-install/56-icon-theme.sh:34`, `post-install/56-icon-theme.sh:52`, `post-install/56-icon-theme.sh:59`, `preseed/late.sh:263`

The icon theme files are installed system-wide under `/usr/share/icons/NCZ`, and GNOME gets a system dconf default. XFCE receives `/etc/skel/.config/xfce4/.../xsettings.xml`; late.sh hydrates that into homes created before `late_command`, but uses `--ignore-existing`.

Impact: first install should land the setting for fresh users, but reruns will not override an existing user `xsettings.xml`. That is acceptable for install-time safety, but it is not a forced system-wide XFCE policy.

### M4 - Wallpaper rotation survives reboot only after graphical login

File: `post-install/45-wallpaper-rotator.sh:76`, `post-install/45-wallpaper-rotator.sh:88`, `post-install/45-wallpaper-rotator.sh:94`

The rotator is a session autostart daemon, not cron and not a systemd timer. It survives reboot in the normal desktop sense: after a user logs into a graphical session, `/etc/xdg/autostart/ncz-wallpaper-rotator.desktop` starts the daemon and the daemon loops every 600 seconds.

If the requirement is wallpaper rotation at the greeter or before any login, this needs a different mechanism. For current XFCE operator use, the session autostart model is coherent.

### M5 - `/etc/os-release` was missing `BUILD_ID` and exact `ID_LIKE=ubuntu`

File: `post-install/50-brand.sh:9`, `post-install/50-brand.sh:18`, `post-install/50-brand.sh:26`

Root cause: `50-brand.sh` wrote the NCZ identity but did not include `BUILD_ID`, and `ID_LIKE` was `"ubuntu debian"` rather than the requested `ubuntu`.

Concrete diff applied:

- `BUILD_ID` is now derived from `/usr/local/lib/cix-installer/BUILD_VERSION`, then `/etc/cix-installer/BUILD_VERSION`, with an `unknown` fallback.
- `ID_LIKE=ubuntu` is now exact.

### M6 - Magnetar identity is split between `50-brand.sh` and `48-magnetar-variant.sh`

File: `post-install/50-brand.sh:18`, `post-install/50-brand.sh:42`, `post-install/48-magnetar-variant.sh:168`

`50-brand.sh` always brands the OS as `NCZ 26.5 "Reinhardt"`. `48-magnetar-variant.sh` adds Magnetar-specific console issue text for server mode. That may be intentional if Reinhardt is the OS release codename and Magnetar is only the SKU, but it is not a single coherent variant-aware identity layer.

Recommended decision: either keep `PRETTY_NAME` release-wide as Reinhardt, or make `50-brand.sh` variant-aware and write Magnetar-specific `PRETTY_NAME`, `/etc/issue`, and MOTD text when `BUILD_VARIANT=server`.

## LOW findings + recommendations

### L1 - Stale NCX names remain in internal asset paths and comments

File: `assets/branding/icon-theme/NCX/index.theme:2`, `assets/branding/ncx-upstream-watch.sh:4`, `post-install/20-desktop.sh:164`

Runtime branding is mostly NCZ: the icon theme is installed to `/usr/share/icons/NCZ`, LightDM points at `NCZ`, and `/etc/os-release` uses `ID=ncz`. Historical NCX remains in source asset directories and internal watcher paths. I did not modify asset files because this sweep's edit constraint limits fixes to `post-install/` plus this document.

### L2 - `45-wallpaper-rotator.sh` still logs as `[55]`

File: `post-install/45-wallpaper-rotator.sh:7`, `post-install/45-wallpaper-rotator.sh:134`

The filename is `45-wallpaper-rotator.sh`, but operator log prefixes still say `[55]`. This is cosmetic but confusing during install log review.

### L3 - `60-plymouth.sh` still invokes `plymouth-set-default-theme -R`

File: `post-install/60-plymouth.sh:56`, `post-install/60-plymouth.sh:100`

The explicit target-kernel rebuild now closes the correctness gap. The earlier `-R` call may still do a redundant implicit rebuild before the explicit loop. Low-risk follow-up: use `plymouth-set-default-theme nclawzero` without `-R` if available, then rely only on the explicit target loop.

### L4 - Desktop display acceleration ownership is split

File: `post-install/20-desktop.sh:67`, `post-install/22-display-fix.sh:53`

`20-desktop.sh` sets Mesa panthor environment overrides, while `22-display-fix.sh` pins the Xorg KMS device. The split is workable, but troubleshooting "llvmpipe fallback" requires reading both hooks.

### L5 - Full runtime validation still requires hardware or chroot install media

Static shell validation passed locally, but I did not run apt installs, `update-initramfs`, LightDM, Xorg, or Plymouth inside a target chroot. The repo checkout has no live target root mounted.

## Test plan

Static validation already run:

```sh
bash -n post-install/20-desktop.sh post-install/22-display-fix.sh post-install/45-wallpaper-rotator.sh post-install/50-brand.sh post-install/56-icon-theme.sh post-install/60-plymouth.sh
shellcheck -S warning post-install/20-desktop.sh post-install/22-display-fix.sh post-install/45-wallpaper-rotator.sh post-install/50-brand.sh post-install/56-icon-theme.sh post-install/60-plymouth.sh
git diff --check -- post-install/20-desktop.sh post-install/22-display-fix.sh post-install/45-wallpaper-rotator.sh post-install/50-brand.sh post-install/56-icon-theme.sh post-install/60-plymouth.sh
```

Magnetar install smoke:

```sh
cat /target/usr/local/lib/cix-installer/BUILD_VARIANT
grep -R "Magnetar headless SKU" /target/var/log/cix-install/20-desktop.log /target/var/log/cix-install/22-display-fix.log /target/var/log/cix-install/45-wallpaper-rotator.log /target/var/log/cix-install/56-icon-theme.log
chroot /target systemctl get-default
chroot /target systemctl is-enabled lightdm 2>/dev/null || true
test ! -e /target/usr/local/bin/ncz-wallpaper-daemon
```

Desktop install smoke:

```sh
cat /etc/os-release
grep -E '^(PRETTY_NAME|NAME|VERSION_ID|BUILD_ID|ID|ID_LIKE|HOME_URL|SUPPORT_URL)=' /etc/os-release
cat /etc/lightdm/lightdm.conf.d/50-cixmini.conf
ls /usr/share/xsessions
```

Plymouth smoke:

```sh
test -s /usr/share/plymouth/themes/nclawzero/nclawzero.plymouth
test -s /usr/share/plymouth/themes/nclawzero/nclawzero.script
test -s /usr/share/plymouth/themes/nclawzero/background.png
test -s /usr/share/plymouth/themes/nclawzero/lockup.png
grep '^Theme=nclawzero$' /etc/plymouth/plymouthd.conf
for img in /boot/initrd.img-*; do lsinitramfs "$img" | grep -q 'plymouth/themes/nclawzero' && echo "theme in $img"; done
```

Wallpaper and icon smoke after desktop login:

```sh
/usr/local/bin/ncz-wallpaper-rotate
readlink -f /usr/share/backgrounds/ncz/default.jpg
xfconf-query -c xfce4-desktop -l | grep '/last-image$' | head
gsettings get org.gnome.desktop.background picture-uri 2>/dev/null || true
test -d /usr/share/icons/NCZ
gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null || true
xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || true
```

Display smoke on MS-R1:

```sh
systemctl status cix-detect-display.service --no-pager
cat /var/log/ncx-display-detect.log
cat /etc/X11/xorg.conf.d/10-cixmini-primary-display.conf
cat /etc/udev/rules.d/73-cixmini-primary-display.rules
glxinfo -B | grep -E 'OpenGL renderer|llvmpipe|panthor|Mali'
```
