# assets/regreet — regreet greeter binary (GTK4, Mali-accelerated) — SUPERSEDED

> **This greeter is no longer shipped.** `regreet` was the NCZ-OS 26.7 greeter
> during an earlier point in the Singularity migration; it has since been
> **replaced by the native `singularity-greeter`** (a raw Wayland
> wlr-layer-shell client sharing the `singularity-loginui` Cairo renderer with
> the lockscreen/boot-splash — no GTK, no `xdg-desktop-portal` dead-bus
> workaround). See `post-install/55-greeter.sh` (header: "supersedes regreet")
> and the top-level `README.md`. This directory and its README are kept for
> historical reference; do not treat `regreet` as the current greeter.

`regreet` was a prior-generation greeter (ReGreet 0.5.0, arm64), rendered on
labwc under greetd on the CIX Mali GLES stack (libmali/libEGL_cix). GTK3
gtkgreet blackscreened on libmali; GTK4 regreet accelerated — but it still
carried GTK/portal overhead the native greeter avoids entirely.

**The binary is a build-time blob and is gitignored** (like the Singularity
payload). It is NOT committed.

## Supplying it

Fetch the built arm64 binary (11.5 MB, built in an ubuntu:26.04 arm64
container) onto the build host:

```bash
# from .66:
scp jasonperlow@192.168.207.66:/tmp/regreet assets/regreet/regreet
chmod 0755 assets/regreet/regreet
# sha256: 62da36964f4a9dd3bb2653fdb2c90425b9c883a88400016687e8772ca40cd5e5
```

## How it was consumed (historical — no longer wired up)

- `build/build-squashfs-layers.sh` (desktop layer) staged it into the overlay
  chroot; `post-install/20-desktop.sh` installed it to `/opt/regreet/bin/regreet`
  and baked it into `desktop.squashfs`.
- `post-install/55-greeter.sh` wrote the greetd + regreet + labwc config
  (`/etc/greetd/config.toml`, `regreet.toml`, `regreet.css`, `regreet-labwc/`,
  `/etc/tmpfiles.d/ncz-regreet.conf`).
- `/usr/local/bin/ncz-regreet-greeter` (installed by 20-desktop) was the wrapper
  that sourced `ncz-gpu-env` and set `GTK_USE_PORTAL=0` +
  `DBUS_SESSION_BUS_ADDRESS=/dev/null` (the fix that stopped GTK4 blocking ~120s
  on xdg-desktop-portal on the `_greetd` bus → black screen), then exec'd
  `labwc -C /etc/greetd/regreet-labwc`.

None of the above is present in the current `build/build-squashfs-layers.sh`
or `post-install/20-desktop.sh`/`55-greeter.sh` — both now explicitly say "no
regreet" (see the comments in those files). The runtime deps (gtk4,
libadwaita, glycin image loaders) are likewise no longer required by the
greeter (though gtk4 may still be pulled in for other Singularity apps).
