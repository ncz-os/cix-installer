# Build hosts — environment parity tracking (ULTRA vs ARGOS)

Started 2026-09-11 after a full ISO build session on ULTRA surfaced several
host-environment gaps (Fedora Asahi Remix is not Debian-family, unlike every
other build host this pipeline has run on). Tracking the deltas here so
setting up a parallel amd64 build environment on ARGOS doesn't have to
re-derive them.

## Current state

| | ULTRA | ARGOS |
|---|---|---|
| Arch | aarch64 (native) | x86_64 (native) |
| OS | Fedora Linux Asahi Remix 44 | Ubuntu 25.10 |
| Role | Primary build host, base-rootfs pipeline retargeted here 2026-09-11 (was ARGOS+qemu) | Original/legacy build host; kept in sync as the designated x86 host for a future amd64 NCZ-OS target |
| Repo checkout | `~/cix-installer-r266-iso` | `~/cix-installer-r266-build` (different directory name — same repo, same branch, kept fast-forwarded) |

## Environment deltas found and closed (ULTRA, 2026-09-11)

These were all genuinely needed on ULTRA because Fedora is not Debian-family
— none of them are ULTRA-vs-ARGOS *target-architecture* differences, they are
Fedora-vs-Debian *package-availability* differences. **All were already
present natively on ARGOS (confirmed 2026-09-11) because Ubuntu ships them by
default** — zero action needed there for these:

- `apt-get` / `apt-ftparchive` — needed on ULTRA for `build-forky-mirror.sh`,
  `build-vendor-mirror.sh`, `build-desktop-mirror.sh` (all run apt tooling
  directly on the host, not in a container). Already native on ARGOS.
- `debian-archive-keyring` at `/usr/share/keyrings/` — same scripts, signed
  Debian mirror access. Already present on ARGOS.
- `glibc-static` — needed on ULTRA to link the static **aarch64** zstd binary
  natively (see below). **Does not apply to ARGOS the same way**: ARGOS is
  x86_64 building an aarch64-target binary, so it uses the aarch64
  cross-toolchain path instead (see next item), not native static linking.

## Environment already present on ARGOS, verified 2026-09-11

Checked directly rather than assumed, since guessing this class of thing
wrong wastes a build cycle:

- `aarch64-linux-gnu-{gcc,ar,ranlib,strip}` — the full cross-toolchain is
  installed. This is what `build-iso-di.sh`'s
  `prepare_static_zstd_aarch64()` uses on any non-aarch64 host (the fix
  landed this session in `da8bd77` branches on `uname -m`: native
  `cc/ar/ranlib/strip` on an aarch64 host, the `aarch64-linux-gnu-*`
  cross-prefixed tools everywhere else — ARGOS was already correctly
  provisioned for the "everywhere else" branch before this session even
  started, which is presumably *why* ARGOS was the original host for this
  step).
- `podman` and `docker` — both present.
- `mmdebstrap` (1.5.7-3) resolves inside a `debian:forky` container via
  podman on ARGOS, identical to ULTRA.
- **`build/build-base-rootfs.sh` is native-arch-only as of `087b37e`, NOT
  cross-arch.** An earlier version of this script (`5eaace2`) was believed
  host-architecture-agnostic but was never actually re-run after being
  committed — trying it for real on ARGOS is what caught that it was
  broken (exit 127, a nested-quoting bug in a customize-hook that also
  turned out to be unnecessary complexity; see `087b37e`'s commit message
  for the full story). The fixed version explicitly refuses cross-arch
  (`x86_64 -> arm64`) with a clear error rather than attempting it, because
  cross-arch needs `qemu-user-static`'s binfmt_misc registration to carry
  the `F` (fix-binary) flag — **checked directly on ARGOS: it does not**
  (`cat /proc/sys/fs/binfmt_misc/qemu-aarch64` shows `flags: POF`, missing
  `F`). Without `F`, a container that doesn't itself carry a copy of
  `qemu-aarch64-static` cannot exec foreign-arch code, which is exactly
  what `debian:forky` (a stock image) doesn't have. Re-registering with
  `F` (typically `podman run --rm --privileged multiarch/qemu-user-static
  --reset -p yes`) is the concrete next step if ARGOS needs to
  cross-bootstrap an arm64 rootfs — not attempted here; this session only
  diagnosed the gap precisely enough that the next attempt doesn't have to
  re-derive it. **Runs correctly on ARGOS today only for an amd64 target on
  the amd64 host** (the same native-arch path ULTRA uses for aarch64), once
  the amd64-target work described below actually exists.
- `qemu-aarch64-static` binary present (not via the `qemu-user-static` dpkg
  itself, per `dpkg -l` — installed some other way, doesn't matter, the
  binary is what both `build-iso-di.sh` and the old (now-retired)
  debootstrap+qemu base-rootfs path needed).
- Repo checkout on the same branch (`ocs-browser-clean`), fast-forwarded to
  `da8bd77` this session (was 8 commits behind, no local divergence).

## What is genuinely NOT done: an amd64 NCZ-OS *target*

Everything above is about ARGOS being ready to **run this pipeline as a
build host** (which, per the "already present" list, it substantially
already was). It is a different and much larger question from making
NCZ-OS itself buildable **for an amd64 target** (a real x86_64 product
variant, not just cross-building the existing arm64-Sky1 image on an x86
host).

The codebase has real, scattered arm64-target assumptions that a genuine
amd64 target would need to generalize, not just re-run on a different host.
Examples surfaced this session alone (there are certainly more; this is not
a complete audit):

- `prepare_static_zstd_aarch64()` in `build-iso-di.sh` is hardcoded to
  produce an aarch64 ELF (`file "$bin" | grep -Eq 'ARM aarch64|ARM64'`) for
  the d-i initrd, because the d-i initrd's architecture always matches the
  *installed system's* architecture, not the build host's. An amd64 target
  needs the amd64 equivalent of this function (or a generalized
  target-arch-parameterized version), not a host-arch branch.
- Kernel/firmware/mesa staging throughout `post-install/` and
  `build-squashfs-layers.sh`'s `BASE_HOOKS`/`BAKE_HOOKS` assume the CIX
  Sky1 arm64 kernel, DKMS modules, and GPU stack — none of that exists for
  amd64 and would need either a parallel hardware target or a real "generic
  x86_64 hardware" profile decision.
- `manifests/*.pkgs` architecture-specific package names (`arm64` appears
  throughout `build-forky-mirror.sh`/`build-vendor-mirror.sh` as a hardcoded
  `ARCH` default) would need per-target seed manifests or an `ARCH=amd64`
  parameterization actually exercised end-to-end, not just accepted as a
  shell variable.

**This is a real, separate architecture-generalization project, not an
environment-setup task.** Nothing above was implemented this session —
flagging it here so the scope difference between "ARGOS can run the
pipeline" (done) and "NCZ-OS has an amd64 target" (not started) doesn't get
conflated later.

## Cross-references

- `docs/ISO-BUILD-GUARDRAILS.md` — mechanics-vs-contents distinction this
  doc's "genuinely not done" section leans on: an amd64 target is a
  mechanics change (affects every board/variant), not a contents change,
  and needs the same commit-message scrutiny that file calls for.
- Commits: `be4d601`, `5eaace2`, `087b37e` (base-rootfs pipeline retarget +
  mmdebstrap swap + the fix once ARGOS testing caught it broken),
  `da8bd77` (native-toolchain branch for the static zstd builder).
