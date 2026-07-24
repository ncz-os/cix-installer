# assets/regreet — regreet greeter binary (GTK4, Mali-accelerated)

`regreet` is the NCZ-OS 26.7 SHIP greeter (ReGreet 0.5.0, arm64), rendered on
labwc under greetd on the CIX Mali GLES stack (libmali/libEGL_cix). GTK3
gtkgreet blackscreened on libmali; GTK4 regreet accelerates — zero compromise.

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

## How it's consumed

- `build/build-squashfs-layers.sh` (desktop layer) stages it into the overlay
  chroot; `post-install/20-desktop.sh` installs it to `/opt/regreet/bin/regreet`
  and bakes it into `desktop.squashfs`.
- `post-install/55-greeter.sh` writes the greetd + regreet + labwc config
  (`/etc/greetd/config.toml`, `regreet.toml`, `regreet.css`, `regreet-labwc/`,
  `/etc/tmpfiles.d/ncz-regreet.conf`).
- `/usr/local/bin/ncz-regreet-greeter` (installed by 20-desktop) is the wrapper
  that sources `ncz-gpu-env` and sets `GTK_USE_PORTAL=0` +
  `DBUS_SESSION_BUS_ADDRESS=/dev/null` (the fix that stops GTK4 blocking ~120s
  on xdg-desktop-portal on the `_greetd` bus → black screen), then execs
  `labwc -C /etc/greetd/regreet-labwc`.

Runtime deps: gtk4, libadwaita, glycin image loaders (`glycin-loaders`) — all in
the desktop mirror (`manifests/desktop.pkgs`).
