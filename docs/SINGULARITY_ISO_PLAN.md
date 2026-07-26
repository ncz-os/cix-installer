# Plan — Singularity replaces X/XFCE as the NCZ-OS 26.7 desktop

> **STATUS: largely executed, kept as historical planning record.** Since
> this plan was written, the desktop has shipped and moved further than the
> plan below: Singularity installs as a real `.deb`
> (`ncz-singularity-desktop`) via `apt-get install`, **not** the
> `singularity-opt.tgz` tarball extraction described in "Work items" below;
> the greeter is the **native `singularity-greeter`** (wlr-layer-shell,
> Mali-rendered, no llvmpipe), not `lightdm`/`regreet` as described here;
> Plymouth has been **removed entirely**, replaced by the native
> `singularity-boot-splash` (the plan below still lists `60-plymouth` as a
> kept hook); native networking (`sinty-nm`) and a native keyring have also
> landed, beyond this plan's scope. Treat this document as "why/how we got
> from XFCE to Singularity," not as a description of what ships today — see
> the top-level `README.md` for current state.
>
> **Release pitch (operator, 2026-07-24):** *Maximilian is a native-Mali, acceleration-first, modernized Linux distribution with the latest technologies that fully exploit the CIX Sky1 processor on the latest Linux kernel.* **Zero compromises. Zero kludges.**

**Directive:** Singularity Desktop becomes *the* desktop in the ISO; XFCE/X11 desktop is removed. NCZ-OS ships a single, Wayland-native, Mali-accelerated DE. Every layer — desktop, **greeter**, video, compute — is native Wayland + hardware-accelerated on Sky1. No X11, no software-render fallbacks presented as final, no hacks-that-hide-bugs.

## Zero-compromise gates (must all hold before "shippable")
- **Greeter:** Wayland-native + **Mali-accelerated** (regreet/GTK4 on labwc — NOT X11 lightdm, NOT software/pixman). GTK3 gtkgreet blackscreens on libmali; GTK4 (like the Singularity shell) accelerates — so regreet is the path.
- **Browser video:** pursue the real **cix-vaapi driver fix** (the driver ships in the 2026Q2 vendor SDK — the `SEPARATE_LAYERS` export + `VIDIOC_QBUF` capture-buffer bugs are candidates to patch ourselves, not just file). HW decode in the browser, not SW-as-acceptable. mpv/V4L2 HW is the floor, not the ceiling.
- **No kludges:** the "Overview Super+Space" hot-corner pill = fix the shell's `hide_hint()` dismiss (upstream Vala), not `opacity:0`. libexec/bin mismatch = packaging fix (upstream PR), not runtime symlinks. Every workaround becomes a real fix or an upstream PR.
- **Fully exploit Sky1:** GPU (Mali/libmali GLES today, Panthor/Vulkan roadmap), NPU (Zhouyi /dev/aipu), VPU (amvx V4L2) all wired and used; latest kernel (7.2 → release when ready).

## Current state (what ships today)
- Desktop closure = `lightdm lightdm-gtk-greeter xubuntu-core xfce4-session xfce4-*`, installed OFFLINE from the bundled `/cdrom` pool.
- Pool built by `build/build-desktop-mirror.sh`; embedded into the fat ISO by `build/build-iso-di.sh`.
- `build/build-squashfs-layers.sh` `build_layer()` desktop delta: pin LightDM, `user-session=xfce`, `x-session-manager -> xfce4-session`, then run brand hooks: `22-display-fix 50-brand 52-vivaldi 56-icon-theme 45-wallpaper-rotator 55-greeter 57-screensaver 57-qotd 30-agents 46-ncz-cli 60-plymouth`.
- `20-desktop.sh` = the XFCE installer (installs the curated XFCE set offline).

## Target state
- Desktop = **Singularity** (labwc/wlroots, GLES, CIX libmali). Single session. No XFCE, no X11 session.
- Greeter = **greetd + regreet (GTK4, Mali-accelerated Wayland)** on labwc. Session list curated to **Singularity only**. (lightdm-branded exists as a *temporary dev fallback only* — it is NOT the shipping greeter; X11 is a compromise.)
- Video = **mpv** default player (`hwdec=v4l2m2m-copy`, HW) **and** browser HW decode via the fixed cix-vaapi driver (pursued, not deferred). SW decode is not an acceptable ship state for "acceleration-first."
- GPU = driver-aware `ncz-gpu-env` (Mali default; Panthor experimental, hidden until it boots).

## Work items (file-by-file)

### 1. Package payload
- **`assets/singularity/singularity-opt.tgz`** — the built `/opt/singularity` tree (14 MB, built on .66 in an `ubuntu:26.04` arm64 container; canonical build recipe → `docs/upstream/singularity` + a `build/build-singularity.sh` to reproduce). Store the artifact on ARGONAS (`/mnt/datapool/archives/ncz/singularity/`) + fetch at ISO-build, OR commit via LFS. Staged into the ISO by `build-iso-di.sh` like the mali overlay.
- **`build/build-desktop-mirror.sh`** — replace the XFCE package set with Singularity's runtime deps (the ~254-pkg closure, 0-removals verified on resolute): `gtk4`/`libgtk-4-1`, `libgee-0.8-2`, `libpeas-2-0`, `libwebkitgtk-6.0-4`, `libvte-2.91-gtk4-0`, `libgtksourceview-5-0`, `libgtk4-layer-shell0`, `libadwaita`, `libgraphene`, `foot`, `xsettingsd`, `seatd`, `swaybg`, `grim`, `fuzzel`, `network-manager-gnome`, `pavucontrol`, `polkit`, `mpv`, plus labwc/wlroots runtime libs and `lightdm lightdm-gtk-greeter` (+ `greetd gtkgreet`/`regreet` once native lands). Drop `xubuntu-core xfce4-*`.

### 2. New desktop installer — `post-install/20-desktop.sh` (rewrite) → Singularity
Replaces the XFCE install with:
1. Install Singularity runtime deps offline from `/cdrom` pool (as today, new package list).
2. Extract `assets/singularity/singularity-opt.tgz` → `/opt/singularity`; fix perms; run `ldconfig`.
3. Install `/usr/local/bin/ncz-gpu-env` (Mali branch: **no** `__EGL_VENDOR_LIBRARY_FILENAMES` pin — that regression blackened libmali; Panthor branch keeps mesa vendor), `/usr/local/bin/ncz-singularity` (sources ncz-gpu-env; `/opt/singularity` on PATH/XDG_DATA_DIRS/LD_LIBRARY_PATH; `TERMINAL=foot`), `/usr/share/wayland-sessions/singularity.desktop`.
4. Singularity theme with the **corner-hint `opacity:0`** fix (kills the stuck "Overview Super+Space" pill) + **red accent** default (`dev.sinty.desktop accent-color=red`) as a packaged gschema override; NCZ **Maximilian** wallpaper default (`background-picture-uri` + swaybg autostart).
5. **libexec fix** — portal/polkit backends live in `/opt/singularity/libexec`; ship the session-script/exec-path fix (upstream PR `10-pr-libexec-path`) so they resolve.
6. NCZ app `.desktop` launchers rewritten `Exec=foot …` (not xterm); ensure NCZ `.desktop` dirs on the session `XDG_DATA_DIRS`; ship the NCZ hicolor icons.
7. Install `foot` + `xsettingsd`.

### 3. `build/build-squashfs-layers.sh` desktop delta (rewrite lines ~103-124)
- Pin LightDM (unchanged) BUT `user-session=singularity` (drop `60-ncz-xfce.conf`, drop `x-session-manager -> xfce4`).
- Curate sessions: ship only `singularity.desktop`; move any X11/other wayland sessions to `.hidden`.
- Brand the greeter: `lightdm-gtk-greeter.conf` → NCZ Maximilian background, dark theme, session/clock indicators (per the proven runtime config).
- Run brand hooks: `22-display-fix 50-brand 52-vivaldi 56-icon-theme(adapt) 45-wallpaper-rotator(adapt) 55-greeter(lightdm-brand) 57-qotd 30-agents 46-ncz-cli 84-vpu-mpv 60-plymouth` + **`20-desktop`(new Singularity installer)**.

### 4. Hook adaptations
- **`45-wallpaper-rotator.sh`** — xfconf → Singularity dconf (`dev.sinty.desktop background-picture-uri`) / swaybg; set NCZ Maximilian default.
- **`56-icon-theme.sh`** — point at Singularity's icon path, not xfce.
- **`55-greeter.sh`** — lightdm-gtk-greeter NCZ branding (bg/theme/indicators), Singularity-only session.
- **`84-vpu-mpv.sh`** (new) — `/etc/mpv/mpv.conf` → `hwdec=v4l2m2m-copy` (HW video). (`84-vpu-vaapi` browser stack stays staged, gated on CIX driver fix.)
- Keep: `50-brand 52-vivaldi 57-qotd 30-agents 46-ncz-cli 60-plymouth 26-gpu-default-mali 82-mali-gpu 83-vpu-ffmpeg 41-usb2-rescan`.
- **`MACHINE_HOOKS_RE`** in `run-all.sh` — add `84-vpu-mpv`; the desktop install runs via build_layer (baked), not MACHINE_HOOKS.

### 5. Removals
- `xubuntu-core`, `xfce4-*`, `x-session-manager` alternative, `60-ncz-xfce.conf`.
- XFCE references in `30-agents`, `31-remote-access`, `build-mirror.sh` — repoint/remove.
- X11 sessions from `/usr/share/xsessions` (curate to none; Singularity is Wayland).

## Open dependencies / gates
- **Greeter:** ship lightdm-branded now; swap to greetd/native when the native-greeter agent proves it renders (gtkgreet crash-loop root-cause pending) — a one-file swap (`greeter-session` + greetd enable) in build_layer.
- **Singularity artifact reproducibility:** `build/build-singularity.sh` (the .66 container recipe) so the `/opt/singularity` tarball is rebuildable, not a one-off.
- **LXQt/others dropped** — only Singularity is validated; no fallback DE in the chooser (labwc-xfce/lxqt were broken).

## Sequence
1. Land `build/build-singularity.sh` + stage the artifact.
2. Rewrite `20-desktop.sh` (Singularity installer) + `84-vpu-mpv.sh` + hook adaptations.
3. Rewrite the `build_layer` desktop delta (Singularity, not XFCE) + desktop-mirror package list.
4. Build a fresh ISO on the build host; install-test on O6N/KVM; iterate.
5. Swap greeter to greetd if/when native lands.
6. Commit (argonas→gitlab), ship ISO to .4.
