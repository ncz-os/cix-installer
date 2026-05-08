# Known Issue: GNOME doesn't reach desktop past login screen

**Filed:** 2026-05-08
**Status:** known-issue, future-investigation (not blocking r78 ship)
**Affects:** GNOME on Mali-G720 / Sky1 / Ubuntu 26.04 resolute
**Workaround:** ship XFCE only (current default; gnome-shell + gdm purged in `post-install/20-desktop.sh:148-189`)

## Symptom

When GNOME (gnome-shell + gdm + ubuntu-desktop-minimal stack) is installed on top of NCZ Reinhardt 26.5 r74/r75 builds running on Cix Sky1 / MS-R1 hardware:

- gdm greeter renders correctly
- User authenticates
- Session attempts to start
- Falls back to greeter (login loop) — no error visible to operator on tty1
- gnome-session log shows mutter / xdg-desktop-portal-gnome failures

## Hypothesis (operator)

We may be missing pieces that **Sky1-Linux** (the upstream community
project, https://github.com/Sky1-Linux) built for Debian 12 base but
which we did NOT replicate when porting to Ubuntu 26.04 resolute.

Likely candidates (named in current 20-desktop.sh + 22-display-fix.sh):

| Sky1-Linux artifact | Our equivalent | Status |
|---|---|---|
| `mesa-sky1` (custom Mesa fork w/ panvk patches) | TBD — possibly stock resolute Mesa 26.0 | unverified |
| `vulkan-wsi-layer` (Sky1 WSI compat shim) | TBD | unverified |
| `sky1-gpu-support` | TBD | unverified |
| `ffmpeg-sky1` (gpu-accelerated codecs) | TBD | unverified |
| `gstreamer-sky1` (gpu-accelerated media) | TBD | unverified |
| Custom `xdg-desktop-portal` integration | TBD | unverified |
| GNOME Wayland session-config patches | TBD | unverified |

GNOME on Wayland is especially fragile — needs full Mesa + Vulkan +
WSI integration. Any missing piece can cause login-screen-loop-back
without visible error.

## Why we shipped XFCE-only

XFCE 4 (X11) is more forgiving and works with stock resolute
panthor/panvk. Operator validated XFCE-on-Sky1 boots cleanly through
to desktop on .66 in r74 install (per task #74 completed
`r74 Reinhardt SHIP — install verified clean on .66`).

**This is not a regression** — it's a deliberate ship decision.
Reinhardt is XFCE-first by intent; GNOME is opt-in only when the
panvk/Wayland stack catches up.

## Future investigation (when bandwidth allows)

Dispatch Codex with:

1. Clone `Sky1-Linux/sky1-linux` and `Sky1-Linux/mesa-sky1` repos,
   inventory their build-time + runtime artifacts on Debian 12.
2. Diff against our resolute `post-install/20-desktop.sh` +
   `22-display-fix.sh` package install lists.
3. Identify the gap (likely: WSI layer, Mesa patches, or session
   integration glue).
4. Decide whether to:
   - (a) Port the missing piece(s) to Ubuntu 26.04 resolute
   - (b) Wait for upstream Mesa to merge equivalent (panvk is moving
     fast in mainline Mesa)
   - (c) Stay XFCE-only and document as long-term posture

## References

- `post-install/20-desktop.sh:148-189` (GNOME purge logic, current)
- `post-install/20-desktop.sh:212` (KDE Plasma 6 dropped — resolute
  X11 startplasma not supported, Wayland-only)
- Task #50: "Purge GNOME + lock NCX wallpaper rotation + polish XFCE"
  (completed)
- Task #51: "Add GNUStep + KDE as opt-in NCX flavors" (completed,
  but KDE per #20-desktop.sh:212 is non-functional)
- Sky1-Linux community: https://github.com/Sky1-Linux

## Constraints if/when this is investigated

- DO NOT introduce GNOME as default in any take21+ ISO. Operator
  has confirmed XFCE-only as the ship target.
- DO NOT modify the existing GNOME purge at `20-desktop.sh:148-189`
  unless the gap is conclusively identified AND the fix is verified
  on .66 hardware.
- The investigation result lands here as an addendum; if a fix is
  shipped, make it gated on a `NCZ_ENABLE_GNOME=1` build flag, not
  default-on.
