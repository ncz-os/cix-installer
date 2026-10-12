# NCZ-OS lite profile (weak GPUs / old PCs)

**Operator request (2026-10-12):** *"for particularly weak GPU and older systems
(10 year mark) are there Singularity features we can disable in the UX and the
compositor ... amd64 build only"*. This document is the measured design: what
lite turns off, why each item earns its place, the automatic selection rule, and
how a user turns it on or off.

* Branch: `fix/lite-profile-amd64-20261012` (cix-installer, off
  `fix/rc6-final-20261012` @ `7112a12a`). amd64 only; arm64/Sky1 is untouched.
* Test hosts: **inspiron** 192.168.207.70 (Dell Inspiron 5521, 2013, Ivy Bridge
  HD 4000) and **cyclops** 192.168.207.89 (Mac Mini 5,1, 2011, Sandy Bridge
  HD 3000).

---

## 1. What "lite" is

A single, data-driven profile that sets the desktop, compositor and screensaver
knobs that cost the most on pre-2015 integrated GPUs and buys the biggest
CPU/GPU win for the least visual loss. It is **not** a new desktop — it is the
stock Singularity desktop with expensive optional effects turned off.

The profile is owned by cix-installer (data + shell only). The upstream
Singularity Settings UI is **not** patched; the preference is a small
cix-owned GSettings key (`dev.ncz.profile`, see §4).

## 2. Where the cost is (measured)

`docs/lite-profile.md` §5 carries the before/after ablation table from the two
test hosts. In summary, the two dominant costs on a Gen6/Gen7 Intel part are:

1. **Compositor work per frame** — background material (glass/blur), rounded
   window corners, and window shadows each add a full-surface pass.
2. **Animations** — open/close/scale/bounce transitions plus the shell's own
   per-frame motion. The shell already exposes `reduce-motion` and
   `motion-duration-scale`, which drive `<windowAnimations>` and
   `<durationScale>` in `~/.config/labwc/rc.xml`.

A constant **3–5 % idle CPU** in `singularity-desktop` is present on every host;
its true source is identified in §5 (it is not removed by lite unless a
settings key exists for it, and that is called out honestly).

## 3. The lite settings table

Everything lite changes (see `assets/lite/ncz-profile`, `LITE_SETTINGS`):

| schema:key | lite value | stock | why |
|---|---|---|---|
| `dev.sinty.desktop:background-effect` | `disabled` | `disabled` | compositor blur/material; pinned off |
| `dev.sinty.desktop:blur-strength` | `0` | `60` | only paid when a material is active |
| `dev.sinty.desktop:window-transparency` | `0` | `12` | only paid with a material |
| `dev.sinty.desktop:reduce-motion` | `true` | `false` | shell writes `<windowAnimations>no` |
| `dev.sinty.desktop:motion-duration-scale` | `0.30` | `1.0` | shell writes `<durationScale>0.30` |
| `dev.sinty.desktop:window-rounded-corners` | `false` | `true` | square corners |
| `dev.sinty.desktop:idle-dim-screen` | `false` | `true` | no pre-blank dim animation |
| `dev.sinty.desktop:allow-tearing` | `true` | `false` | fullscreen clients skip the vblank wait |
| `dev.ncz.screensaver:pool-gpu-class` | `weak` | `auto` | only savers measured weak-ok |
| `dev.ncz.screensaver:render-scale-mode` | `fixed` | `auto` | honour the scale below |
| `dev.ncz.screensaver:render-scale` | `0.5` | `1.0` | half-res shader savers |
| `dev.ncz.screensaver:max-render-height` | `720` | `0` | cap render height |
| `dev.ncz.screensaver:gpu-offload` | `off` | `auto` | no PRIME juggling on old iGPU |

`rendering-mode` is set to `software` **only** when the display GL really is
software (llvmpipe/softpipe/…); on a working Gen6/Gen7 i915/crocus pipeline lite
keeps hardware rendering (software rendering would be a slow regression).

The compositor half (applied by `ncz-profile`, installed as data under
`/usr/share/ncz/lite/`):

| file | lite value | stock |
|---|---|---|
| `~/.config/labwc/rc.xml` `<cornerRadius>` | `0` | `12` |
| `~/.config/labwc/rc.xml` `<windowAnimations>` | `no` | `yes` |
| `~/.config/labwc/rc.xml` `<durationScale>` | `0.30` | `1.00` |
| `~/.config/labwc/rc.xml` `<allowTearing>` | `fullscreen` | `no` |
| `~/.config/labwc/themerc-override` `window.*.shadow.size` | `0` | `40`/`28` |

> Honest caveat: singularity-desktop **regenerates** `rc.xml` and
> `themerc-override` from its own GSettings when the shortcut set or the accent
> changes. The durable half of lite is therefore the GSettings above (the shell
> derives the same rc.xml values from `reduce-motion`, `motion-duration-scale`
> and `allow-tearing`). ncz-profile patches the files on top and backs them up;
> a later shortcut edit may need `ncz-profile lite` re-run for `cornerRadius`.

## 4. Automatic selection (the rule)

`ncz-lite-profile.service` (a user unit, globally enabled, `WantedBy=
singularity-session.target`, same pattern as `ncz-display-scale.service`) runs
`ncz-profile auto-apply` once at first login. It classifies the display GPU:

    lite      software GL (llvmpipe / softpipe / swrast / lavapipe / zink), or
              Intel Gen <= 7.5: SNB (Sandy Bridge), IVB (Ivy Bridge),
              HSW (Haswell), and older ILK/BYT/CHT, including the marketing
              names HD Graphics 2000/2500/3000/4000/4200/4400/4600 and
              Iris 5100/5200.
    default   everything else — UHD 630 (CFL), Iris Xe, Arc, Mali, Adreno,
              Radeon, NVIDIA/RTX/GTX, Apple. An unlisted renderer is never
              demoted.

Inputs, in order: an explicit renderer string (`eglinfo -B` then `glxinfo -B`),
else the first DRM card's `vendor:device` and VRAM from sysfs. The rule is a
pure function (`ncz-profile class --renderer … --pci … --software …`) so it is
unit-tested with fake renderer strings, and it is monotone (default → lite only).

**Tested against the fleet** (rule-table test, `build/test-lite-profile.sh`):
UHD 630, Iris Xe, Arc, Mali-G720, Radeon 5500M, RTX 2060 and Apple M2 all stay
**default**; llvmpipe, HD 3000, HD 4000, Haswell and the `8086:0166`/`8086:0126`
PCI ids go **lite**. PEGASUS (UHD 630) is unaffected.

Key differs between Gen6 and Gen7: currently **no** — both go lite. §5 records
whether the HD 3000 (Gen6) data justified a separate class.

## 5. Measurements

See the mission report for the host facts, baseline, ablation table and the
before/after table. This file's job is the design; the numbers live in
`REPORT.md` and the copied evidence under ARGONAS
`/mnt/datapool/projects/ncz-session-2026-10-12/litebase/`.

## 6. User controls

    ncz-profile status        # what is set, what the rule would pick, why
    ncz-profile lite          # apply lite now
    ncz-profile default       # restore the stock values (exact prior values)
    ncz-profile auto          # re-arm the first-login selector
    ncz-profile list          # print every key lite sets
    ncz-profile class --renderer "…"   # dry-run the rule

The preference is the GSettings key `dev.ncz.profile:profile`
(`auto`|`lite`|`default`) — the "Settings key" the operator asked for, kept in a
cix-owned schema so no upstream file is touched. A marker file
(`$XDG_STATE_HOME/ncz/lite-profile/`) mirrors it so lite still works on payloads
that predate the key.

**Never re-apply.** `auto-apply` records `lite-applied=true` after its one
decision and is a no-op afterwards, so a user who then changes any setting keeps
their change. `ncz-profile auto` clears the flag to re-arm the selector.

## 7. Reversibility

Every key lite changes has its prior value recorded under
`$XDG_STATE_HOME/ncz/lite-profile/applied.json`; the two labwc files are backed
up to `*.ncz-lite-orig` next to themselves. `ncz-profile default` restores them
exactly (falling back to `gsettings reset` when no prior value was recorded).
