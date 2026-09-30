## Complexity read

This is a large, multi-stage, multi-hour build orchestration task (mirror generation,
squashfs layering, ISO assembly, boot verification) on a 3500+ line build script whose
exact invocation is not something I've personally run before -- I found real uncertainty
(a STALE script describing an abandoned architecture pivot sitting alongside the real
one) that needs resolving with real investigation, not guessing. Routed to you rather than
driven by hand because the operator explicitly wants this done overnight, unattended, and
this needs sustained judgement across many sequential steps where a wrong guess early
costs hours later. Treat this as ONE deliverable: a real, guardrail-passing, boot-verified
NCZ-OS ISO, with honest reporting if any stage cannot be completed rather than a
best-effort partial artifact presented as done.

## Host and access

Host: ARGOS, 192.168.207.22 (x86_64, production Yocto/Docker/apt-mirror host --
CLAUDE.md flags it "do not oversubscribe": max ONE heavy background job at a time, check
load before starting new ones, this build likely qualifies as the one heavy job for its
duration). Pubkey auth as `jasonperlow`. Real disk: 435G free on `/`, NFS mounts to
ARGONAS at `/mnt/argonas/datapool/*` (including `/mnt/argonas/datapool/git` holding the
canonical `cix-installer.git` bare repo and other checkouts, and
`/mnt/argonas/datapool/yocto-shared`).

Working checkout: `~/cix-installer-r266-build` -- a FRESH clone of
`https://gitlab.com/ncz-os/cix-installer.git`, branch `ocs-browser-clean`, currently at
commit `d6a2415` (the two audio/video stability-fix commits are the tip; `git log` to
confirm you're on the latest before starting, `git pull origin ocs-browser-clean` if not).

`release.conf` in that checkout confirms: `NCZ_BASE_NAME="Debian"`,
`NCZ_BASE_CODENAME="forky"` (Debian testing). This is the ACTUAL current release
identity -- do not let any script's comments about a different/older base override this.

## What's already staged, real and verified

- `assets/kernel/edge/`: real, validated r266 kernel (7.2.4-sky1-ncz base + the HDMI/DP
  audio ELD fix, patches 0231/0232). Full kernel-build-checklist already run and passed
  on this exact build (dkms-abi-gate, kvm-kernel-gate, port-series 205/205,
  CONFIG_MODVERSIONS=y confirmed) -- do not re-derive that work, it's done. Files:
  `Image-cixmini.bin`, `config-7.2.4-sky1-ncz`, `headers-cixmini.tar.zst`, `KVER`,
  `modules-cixmini.tgz`.
- `assets/singularity/singularity-opt.tgz`: the final combined singularity-desktop build
  -- includes a real crash fix (missing GSettings schema keys that were aborting the
  process), a provider-boundary refactor (OCS+Bing registered by default, Openverse/
  Unsplash present but unregistered), and pack/image delete capability. Built from
  singularity-shell@1bea180 + singularity-desktop@6fe8477 (schema fix), verified via a
  real production build (`ninja -C build singularity-desktop` succeeded) and real meson
  test suite (14/14 passing) on ULTRA (192.168.207.88), then live-verified on real O6N
  hardware (192.168.207.3, ssh `mini`/`mini` with
  `-o PubkeyAuthentication=no -o IdentitiesOnly=yes -o PreferredAuthentications=password`)
  -- schema keys round-trip correctly via `gsettings`, delete-feature symbols present in
  the deployed binary via `strings`.
- `post-install/43-hw-quirks.sh` (in the repo, will be applied by the installer itself,
  not something to run manually now) carries three real, hardware-verified fixes landed
  today: (1) cgroup `cpu` controller delegation disabled system-wide (fixes a real
  rtkit-daemon/PipeWire realtime-scheduling defect: Sky1's kernel has
  `CONFIG_RT_GROUP_SCHED=y` but cgroups v2 has no `cpu.rt_runtime_us` interface, so every
  non-root cgroup got zero RT runtime -- confirmed on real hardware, `rtkit-daemon`
  self-boost and PipeWire's own RTKit client boost both silently failed at the syscall
  level despite RTKit reporting success); (2) PipeWire `default.clock.min-quantum`
  raised to 2048 (system-wide) for AV1-decode-load audio-underrun headroom (measured: a
  real ALSA XRUN correlated with genuine zero-content DMA ring windows during AV1
  playback, absent under VP9 at matched resolution/bitrate); (3) VPU (amvx, ACPI id
  `CIXH3010:00`) devfreq governor pinned to `performance` via udev (was `simple_ondemand`
  and observed sitting at 350MHz of a 1000MHz max during active 4K AV1 decode). All three
  measured, applied, and reboot-persistence-verified on real O6N hardware.
- chromium: no version pin in the installer scripts -- `apt-get install chromium-ncz-sky1`
  during the build will naturally pull whatever's current in the Buildkite apt repo
  (`154.0.8037.0-ncz20260907` as of this writing, verified newer/better AV1 handling than
  the previous `151.0.7922.75-ncz20260810`). No action needed here beyond confirming the
  build actually reaches out to that repo during the bake (it's in
  `/etc/apt/sources.list.d/*.list` inside the target rootfs via the existing
  `apt-sources`/`buildkite-ncz-apt-keyring` mechanism already in this repo).

## What is NOT yet resolved -- your first real job

I found two DIFFERENT top-level ISO-assembly scripts in `build/`:

- `build-iso.sh` -- its own header says it was "Pivoted 2026-05-03 from Debian d-i
  (preseed) to Ubuntu Server (subiquity autoinstall via cloud-init)". This describes an
  architecture that does NOT match the current `release.conf` (Debian/forky) or the
  presence of a live `preseed/` directory (Debian d-i's own mechanism, not Ubuntu's).
  **I believe this script is stale/abandoned and must NOT be used**, but confirm this
  properly (check git log/blame on both files, check for a later commit that reverted the
  Ubuntu pivot, check docs/ for anything explaining the current architecture) rather than
  taking my read at face value.
- `build-iso-di.sh` (3589 lines) -- its header describes a Debian bookworm d-i base +
  Sky1 kernel + a `late_command` that swaps `/etc/apt/sources.list` from Debian to Ubuntu
  after the base lands, ending on "a Debian system on disk with our Sky1 kernels". This
  explicitly references proven behavior on **MS-R1** (the exact board the operator does
  not want to ship broken). This LOOKS like the real, current pipeline, consistent with
  `release.conf` and the live `preseed/` dir, but I have NOT confirmed this by finding a
  real prior successful invocation (a CI pipeline definition, a documented release
  runbook, or a shell history/wrapper script showing the actual flags used for r262/r263,
  the last real shipped releases per project history).

**Your first task**: definitively resolve which script is real, find (or reconstruct from
the script's own `usage()` and flag parsing) the actual correct invocation including
`--bookworm-iso PATH` (you need to locate or fetch a real Debian bookworm arm64 net-install
or live ISO to use as the base -- check `/mnt/argonas/datapool` and other NFS mounts
first for a cached one before downloading anything new), `--mode` (the script's own usage
text describes `full|thin|netinstall|netinstall-bootstrap` -- `full` is described as
default and most complete; use your judgement on which is appropriate for a real shippable
release, defaulting to `full` unless you find a documented reason otherwise), `--root`,
`--version` (use a real version string following this project's existing convention --
check recent git tags/prior release version strings for the pattern), `--output`.

Also resolve and run whatever mirror-generation prerequisite steps `build-squashfs-layers.sh`
and/or `build-iso-di.sh` actually require (I found `build/build-forky-mirror.sh`,
`build/build-vendor-mirror.sh`, `build/build-desktop-mirror.sh`, `build/build-mirror.sh`
in this checkout -- read each and figure out which ones are actually prerequisites for
the current pipeline vs. leftover/alternate-path scripts, the same "is this stale"
question as above). These mirror-generation steps may take a long time (large package
downloads) -- that's fine, this is meant to run overnight unattended.

## Guardrails -- read these files in full before building anything

- `~/.claude/rules/kernel-build-checklist.md` equivalent content is already satisfied for
  the kernel itself (see above) -- but re-verify nothing in the ISO assembly process
  disturbs that (e.g. never let a mirror/rootfs step silently substitute a different
  kernel or headers set than what's staged in `assets/kernel/edge/`).
- This repo's own `~/.claude/rules/iso-build-guardrails.md` -- CRITICAL, read it. Key
  points: ISO build MECHANICS (`build-squashfs-layers.sh`, `preseed/extract-rootfs.sh`,
  `build-iso-di.sh`/whichever is real) are stable and any change to them needs to say WHY
  in its own commit -- you should not need to change these files at all for a normal
  build; if you find yourself needing to, that's a signal something is more wrong than
  expected, stop and report rather than patching mechanics files blind. Also: **root
  filesystem mode must be 0755** (there's a real mechanical gate for this in
  `preseed/extract-rootfs.sh` already -- confirm it's intact, don't weaken it), persistent
  journal must actually survive a reboot on the installed system, and a broken boot should
  be diagnosed by comparing against the rescue partition, not assumed.
- **Never leave a board unbootable.** Always keep a working rescue entry; only add/rename-
  disable boot entries, never delete the working ones; change the default via sort-key
  only.
- **Ship kernels/packages via the installer's normal apt/dpkg path only. Never
  `tar -C /` anything into a live rootfs** -- this clobbers the usr-merge `/lib` symlink
  and is a total remote lockout.

## Boot-test constraints -- READ CAREFULLY, this is a real operational rule on this fleet

- **O6N (192.168.207.3) is the designated kernel/ISO boot-test board.** SSH `mini`/`mini`,
  flags: `-o PubkeyAuthentication=no -o StrictHostKeyChecking=no -o IdentitiesOnly=yes
  -o PreferredAuthentications=password`. Boot-testing here is expected and fine.
- **Do NOT touch cixmini/.66 (192.168.207.66) for this.** It is currently in an unknown,
  possibly-broken state from unrelated live debugging tonight (an attempted Panthor GPU
  boot-entry test left it unreachable at the network-stack level despite the physical
  link being up -- this needs PHYSICAL operator attention, not a remote fix, and is
  explicitly out of scope for you). Flashing/testing the finished ISO on `.66` is a
  follow-up step for the operator to do once `.66` is physically recovered, not part of
  your task.
- A fresh install from the finished ISO should be tested on O6N BEFORE declaring done --
  a full install (not just a kernel boot-test on top of an existing install, which is
  all that's been verified so far this session), confirming: boots to Mali entry by
  default, GPU/VPU/NPU all bind (per the checklist), zero ELD warnings, chromium launches
  and can play video, wallpaper picker shows only OCS+Bing, root fs mode 0755, journal
  persists across a reboot.

## What NOT to do

- Do not attempt to fix `.66` or reach it at all.
- Do not modify the already-verified kernel or singularity-desktop build artifacts --
  they're done; your job is assembling them into a real ISO, not re-deriving them.
- Do not weaken any existing guardrail/gate script to make a build succeed. If a gate
  fails, that's real signal -- find the actual root cause.
- Do not report success without a real, fresh-install boot test on O6N. A build that
  merely "completed with exit 0" is not sufficient, per this project's own repeated
  documented history of exactly that kind of false-positive (a "zero exit from mksquashfs
  is NOT evidence the archive it wrote can be read back" -- quoted directly from this
  repo's own build-squashfs-layers.sh comments, referencing a real incident).

## Report back with

- Which top-level ISO script you determined is real, and the evidence (not just your own
  read of the header comments).
- The exact invocation(s) used for every stage, in order.
- Real command output/evidence for each guardrail check, not a summary claim.
- The final ISO's location, size, and checksum.
- Full evidence from a real fresh-install boot test on O6N (not a kernel-only test on an
  existing install).
- Anything you could not complete or verify, stated plainly, rather than glossed over.
