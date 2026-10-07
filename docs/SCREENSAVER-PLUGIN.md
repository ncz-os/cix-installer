# Screensaver settings plugin: supply chain

The Singularity "Screensaver and Lockscreen" settings page (chooser, previews,
Black Hole colour modes, idle and lock timers) is the plugin
`ncz-screensavers-plugin`. It is a separate package from the engine
(`ncz-screensavers`), it is not published to the NCZ apt repo, and it links
`libsingularity.so.0` from the Singularity payload (`ncz-singularity-desktop`).
Every desktop image, amd64 and arm64, ships it.

## Pin

`post-install/lib/ncz-screensavers-plugin.lock` is the only place the plugin is
named: version, ARGONAS directory, source commit, and for each arch the deb
sha256, the payload version it was built against, and that payload's
`libsingularity` sha256. Every consumer below reads this file.

Current pin: 0.3.18 from `ncz-screensavers` `fix/r201-plugin-018-20261007`
(c5e1552d), built against the 2026-10-07 Singularity refresh payloads (amd64
`20261007185124+bk0+tgz8529a9b6`, arm64 `20261007184442+bk0+tgzfc441ab9`) and staged on
ARGONAS at `/mnt/datapool/projects/ncz-screensavers-debs/plugin-0.3.18b-20261007/`
(debs, `SHA256SUMS`, `BUILT-FROM.txt`, build and test logs).

0.3.18 is 0.3.17 rebuilt for the refreshed libsingularity: the plugin target now
names `libsoup-3.0`, because the new `singularity-1.0.vapi` uses `Soup.Session`
while its `.deps` and pkg-config `Requires:` do not list it (an upstream
libsingularity defect), and the build host needs the gtksourceview, gstreamer
and gtk4-layer-shell `-dev` packages the new `singularity-1.0.pc` requires.

The pin matches the final payloads built from `fix/singularity-converge-20261007`
(`ncz-singularity-debs/singularity-refresh-20261007b`).

Per-screensaver options open in place: the gear on a screensaver row expands
its options directly under that row, inside the Settings page, one screensaver
at a time, and a second click collapses them. The plugin opens no window of its
own for options (0.3.16 used a separate dialog); only Preview starts the
fullscreen screensaver.

## Path into the image

| Step | What | Where |
|---|---|---|
| stage (build host) | copy the pinned deb from ARGONAS, check sha256 and control fields | `make ssplugin-stage` (`build/stage-screensaver-plugin.sh ARCH`) into `build/ncz-screensavers-out/` |
| stage 2 gate | staged deb == pin; the image's payload matches the plugin's ABI | `build/check-ssplugin-abi.sh --arch ARCH`, run by `make image` |
| medium | pinned deb copied to `ncz-payload/assets/ncz-screensavers-plugin/` | `build/iso/write-usb-image.py` (`stage_ssplugin_deb`) |
| install | hook 59 installs the engine from the offline `/cdrom` pool, then the plugin from the medium (`apt-get install ./deb`, dependencies from `/cdrom`) | `post-install/59-ncz-screensavers-pkg.sh` with `post-install/lib/ncz-ssplugin-install.sh` |
| install gate | plugin installed at the pinned version, `.so`, `.plugin`, and the default-enabled override | `build/verify-installed-target-screensavers*.sh` (the KVM gate sets `VERIFY_EXPECT_SS_PLUGIN=1` from the pin) |

The plugin does not go through the stage-0 offline mirror. Stage 1 rebuilds
the Singularity payload after that mirror is built, and the plugin has to
match the payload. Shipping the plugin on the medium next to the payload means
a rebuilt plugin only needs restaging before stage 2, with no mirror rebuild.
Hook 59 is in the baked-mode allowlist (`MACHINE_HOOKS_RE` in `run-all.sh`).

## ABI guard

The plugin can be installed on a payload only when:

* the payload version equals `NCZ_SSPLUGIN_PAYLOAD_<arch>`, or
* the payload's `libsingularity.so.0` is byte-identical to
  `NCZ_SSPLUGIN_LIBSINGULARITY_SHA256_<arch>`. Every Singularity symbol the
  plugin imports (`singularity_plugin_get_type`, `singularity_widgets_*`) comes
  from that library, and identical bytes also mean identical struct layouts.

Matching symbol names alone is not enough, because a GObject class struct can
change size without any symbol changing. The build gate (stage 2) and the
installer apply the same rule (`ssplugin_abi_verdict`). On a mismatch the
installer refuses the plugin, so a mismatched `.so` is never loaded into
Settings, and the install gate fails.

Measured 2026-10-06 on ULTRA: the r199 arm64 payload `20261006+bk0+tgz5fa6f59c`
and a payload rebuilt from pinned upstream commits (`tgz11586e94`) carry
byte-identical `libsingularity` (`70bc3ae4...`), so a pinned-source rebuild
passes on `lib-identical`. A payload built from a newer upstream
`libsingularity` fails and needs a plugin rebuild.

## Rebuilding the plugin for a new payload

Rebuild amd64 on PROTEUS (192.168.207.68, container `debian:forky`) and arm64
on ULTRA (192.168.207.88, container `debian:testing`). Use an
`ncz-screensavers` checkout of `integration/cygnus-26.10-2026-10-03`, and the
payload deb that stage 1 produced (`assets/cix-debs/ncz-singularity-desktop_*_ARCH.deb`).

```sh
apt-get install ./ncz-singularity-desktop_<payload>_<arch>.deb valac meson ninja-build \
    libgtk-4-dev libgee-0.8-dev libjson-glib-dev libpeas-2-dev   # see logs/build-<arch>.log of the current pin
sh tools/build-plugin.sh /opt/singularity out/build-<arch>
NCZ_SINGULARITY_MIN=<payload yyyymmdd> sh tools/make-plugin-deb.sh <arch> out/build-<arch> \
    out/ncz-screensavers-plugin_<version>_<arch>.deb <version>
```

Use a new `<version>` for each rebuild. Then:

1. Copy both debs, `SHA256SUMS` and `BUILT-FROM.txt` to a new
   `ncz-screensavers-debs/plugin-<version>-<date>/` directory on ARGONAS.
2. Update the pin for both arches and commit.
3. Run `build/stage-screensaver-plugin.sh <arch>` and then stage 2.

## Checks

* `build/test-ssplugin-supply-chain.sh`: pin, staging, ABI gate, medium,
  offline install, registry and allowlist, each tested in both directions.
* `build/test-installed-target-verifier.sh`: the plugin cases.
* `build/verify-dual-arch-parity.sh`, section 2b: the pin covers both arches,
  and any staged deb matches it.
* `manifests/components.tsv`: the plugin is a required `staged-deb` row,
  generated from the pin.

## First login

The plugin's postinst adds `screensaver` to the distribution default
`enabled-plugins` (`99-zz-ncz-screensaver-plugin.gschema.override`, built on
20-desktop.sh's `99-ncz-defaults`), so a new user starts with the page enabled.
For existing users, `ncz-screensaver ensure-plugin` (`ExecStartPre` of the
globally enabled `ncz-screensaver-idled` user unit) enables the plugin once at
the next login and records a marker. A plugin the user turns off afterwards
stays off.
