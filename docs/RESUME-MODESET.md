# Display re-modeset after resume

After **any** S3 suspend/resume the internal panel can flicker (on the desktop and
under the lock-screen saver) even though the kernel log shows a clean resume; a
fresh boot is steady. Measured 2026-11-18 on a MacBookPro16,1 (amdgpu eDP) on
three kernels: the base, the base plus the 7002 Navi14 patch, and that plus the
Wunner AER series. It is not a regression of any one patch set. One output
off/on cycle through the compositor cures it at once. An Intel-iGPU laptop left
a greeter that stopped painting after resume cycles: the same family.

`post-install/67-ncz-resume-modeset.sh` therefore installs, on **every amd64
machine** (not only T2 Macs):

* `/usr/local/sbin/ncz-resume-modeset` (`post-install/lib/ncz-resume-modeset`):
  for every Wayland compositor socket under `/run/user/<uid>/` (the logged-in
  user's and the greeter's) it runs `wlr-randr` as the socket's owner and, for
  each **enabled internal** connector (`eDP*`, `LVDS*`, `DSI*`), switches it
  off, waits about half a second and switches it on again (it retries for a few
  seconds if the compositor is not answering yet right after the resume). External outputs and
  disabled panels are never touched, no `--mode` is passed, overlapping runs
  are skipped (`flock`), and it always exits 0 with one journal line per action
  (`journalctl -t ncz-resume-modeset`).
* `/usr/lib/systemd/system-sleep/ncz-resume-modeset`: on `post` (suspend,
  hibernate, hybrid-sleep, suspend-then-hibernate) it schedules the helper half a
  second later with `systemd-run --no-block`, so a resume is never delayed. The
  panel flickers from the moment of resume until the re-modeset, so it runs as
  early as the compositor allows.

It does nothing on images without a compositor or `wlr-randr`. It is **not**
installed on arm64/Sky1: there an output disable->enable cycle is the DP
AUX-engine wedge trigger (see `post-install/55-greeter.sh`), so the hook is only
in `hooks.list.amd64` and the installer refuses any other architecture.
`build/test-resume-modeset.sh` pins all of this.
