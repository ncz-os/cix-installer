# ISO build guardrails

**Read this before touching `build/build-squashfs-layers.sh`,
`preseed/extract-rootfs.sh`, `build/build-iso-di.sh`, or
`post-install/run-all.sh`'s hook-invocation framework.**

## The core rule

**The ISO build MECHANICS are stable. Only the image CONTENTS change
build-to-build.**

- Mechanics = the files listed above: the chroot/overlay/bake sequence
  shape, the squashfs-layer pipeline, the partman/extraction recipe
  structure, the hook-invocation framework itself. These run for EVERY
  board and EVERY variant built from this pipeline — a bug here is silent
  and systemic, not scoped to one image or one fix.
- Contents = which packages/assets/fixes get baked in, individual
  post-install hook bodies, kernel/driver versions, desktop config.
- A commit touching a mechanics file needs to say WHY the mechanics needed
  to change, in the commit message — not just what changed.
- If a PR touches both mechanics and contents, call out the mechanics part
  separately so it gets extra review.
- When chasing an unexplained regression across boards/variants, check
  `git log` on the mechanics files FIRST. A symptom that looks
  content-shaped ("the kernel changed", "the network broke") is often
  actually a mechanics regression.

## Why this exists

2026-08-26: a fresh O6N install shipped with the root filesystem (`/`) at
mode 0700 instead of 0755. Three symptoms looked unrelated — greetd
panicked (`unable to set working directory: Permission denied`), the NIC
never linked, `rtc-efi` hung on every boot — and it took hours of live
hardware debugging (serial console, rescue-partition chroot, `namei -l`
permission walks) to find they were one root cause: the squashfs-layer
build pipeline baked a bad root permission into `base.squashfs`, which
`preseed/extract-rootfs.sh`'s `unsquashfs -f -d /target` then faithfully
reproduced on every install. It affected every board built from that image,
not just O6N.

## Mandatory checks on a fresh install

- **Root filesystem mode is 0755.** `stat -c '%a' /` must read `755`. This
  is enforced as a MECHANICAL gate in `preseed/extract-rootfs.sh` — the
  install fails loudly if violated. Do not remove or weaken that gate.
- **Persistent journal survives a reboot.** `journalctl --list-boots`
  should show an entry matching the CURRENT boot's timestamp. Confirmed
  broken the same night as the above (only stale entries from an earlier
  date persisted) — that gap blocked post-mortem debugging of the exact
  incident this doc describes.
- **When 2+ symptoms look unrelated on a broken boot, compare against the
  rescue partition boot** (separate ext4 root, `nvme0n1p2`) before assuming
  independent bugs. Booting rescue and checking whether the same symptoms
  reproduce there is the fastest way to tell "one root cause, several
  symptoms" from "several real bugs" — it settled this incident in one
  boot cycle.

See also `~/.claude/rules/kernel-build-checklist.md` (kernel-specific,
separate concern) on hosts that have it.


## ROOT CAUSE FOUND (2026-08-26, round 3): a 0700-root squashfs LAYER

The mechanism behind the whole incident, found and proven the same day:

**`unsquashfs -f -d /target` re-stamps /target's OWN mode from EACH
squashfs layer's root entry — and the LAST layer wins.** Verified
empirically with both the bundled sqtools unsquashfs and squashfs-tools
4.6.1: an existing 0755 directory became 0700 after force-extracting a
layer whose root entry was `drwx------`.

`desktop-hotfix.squashfs` was built 2026-08-25 ~20:09 by an out-of-repo
process (there is NO committed builder for the hotfix layer) from a
staging directory with mode 0700 — the `mktemp -d` signature (its interior
files are group-writable/umask-002 while the root is 0700; only mktemp
does that combination). Every install then extracted base (root 755) →
desktop (755) → desktop-hotfix (**700**), leaving / at 0700.

Why TWO fix rounds missed it:

- **Round 1 looked at the wrong layer.** It verified base.squashfs's root
  entry (755, correct) and never inspected the role/hotfix deltas.
- **Round 1 gated a script that never runs.** `preseed/extract-rootfs.sh`
  is invoked via `d-i partman/late_command` — which is NOT a real d-i
  preseed hook (d-i only has partman/early_command; see the r159 note in
  build-iso-di.sh). The REAL extraction path is the r40/r159 debootstrap
  STUB baked into the patched bootstrap-base udeb by build-iso-di.sh, and
  it had no gate. The "gate PASSED" observation on O6N was vacuous — the
  gate never executed.
- **Round 2 chased a phantom second actor.** The rescue-partition
  `Modify: 14:27:39` on / is ordinary directory-mtime churn (top-level
  entries like /vmlinuz, /initrd.img created during the hook window) — a
  chmod updates ctime, not mtime. There was only ever ONE stamp: the
  hotfix extraction inside the stub, whose completion message
  ("r159 stub: squashfs rootfs ready") is the 14:22:38 syslog line that
  was misattributed to the round-1 gate. Round 2's late.sh corrective
  chmod DOES cure the symptom (it runs after the stub), but by placement
  luck, not by knowledge of the mechanism.

### The defenses now in place (all layers)

1. **Build-time (the class killer):** `build-iso-di.sh` asserts EVERY
   staged squashfs layer's root entry is `drwxr-xr-x` before it lands on
   the ISO (`assert_squashfs_root_mode`), with the offending layer named
   and the rebuild recipe printed. A bad hotfix layer now fails the BUILD.
2. **Build-time (base):** round-1 chmod before mksquashfs in
   `build-squashfs-layers.sh` (still valid).
3. **Install-time, LIVE path:** the r159 stub pins `chmod 0755 $TARGET`
   after the FULL layer stack and hard-fails (exit 1 → bootstrap-base
   red-screens) if it does not verify.
4. **Install-time, late window:** round-2 (`ae2cc0f`) corrective chmod +
   hard gate in `preseed/late.sh` before every reboot path, with the r155
   "bootable → exit 0" heuristic routed around via `_ncz_root_mode_ok`.
5. **First boot:** the LIVE `ncz-firstboot` (written by the stub in
   build-iso-di.sh) checks / AFTER `dpkg --configure -a`, corrects, and
   always prints `NCZ-ROOTMODE: <mode>` to kmsg+console.
6. **Build self-test:** `build/kvm-install-gate.sh` phase 2 asserts the
   `NCZ-ROOTMODE:` marker from the boot serial capture; phase 1 hard-fails
   on the gates' "refusing to ship a broken install" FATALs. A 0700 root
   is now a gate failure at build time, not a hardware discovery.
7. **Release path:** `make iso-verified` wires the gate into the build flow
   -- depends on `make iso`, then runs the gate against the built artifact,
   and fails the build on any gate failure. Anything intended for real
   hardware should be built with `make iso-verified`, not `make iso`. The
   plain `iso` target stays fast for dev iteration; the gate adds a full
   KVM install+boot cycle (90 min install + 10 min boot timeouts; auto-
   falls back to TCG under qemu on non-aarch64 hosts like TYDEUS).

### Diagnostic tooling

`MODEWATCH=1 build/kvm-install-gate.sh <iso>` instruments the qemutest
ISO with a /target mode watcher (polls 5x/sec; on any transition dumps
`ps` + syslog tail and announces on the serial capture). The watcher is
injected into disk-fs-chooser.sh (which runs via partman/early_command, so
it is live from partman onward and observes the stub extraction). It
exists because two ship-and-discover hardware cycles were spent on static
grep that one instrumented run would have answered.

### Standing traps this incident exposed (fix candidates)

- **`preseed/extract-rootfs.sh` is dead code** on the current install
  flow (partman/late_command is not consumed by d-i), yet preseed.cfg
  still sets it and the file still carries authoritative-looking gates.
  It is ALSO near-duplicated inside the build-iso-di.sh stub heredoc —
  two copies of the same extraction logic, one real, one decoy. Fixes
  landed in the decoy pass review and ship nowhere.
  **Status (2026-08-26):** closed structurally by
  `build/check-extract-rootfs-consistency.sh` — a build-time preflight
  that diffs the r159 branch baked into the stub against the equivalent
  branch in `preseed/extract-rootfs.sh`, and FAILS THE BUILD on any
  drift (after normalization for whitespace, comments, variable-name
  variants, and logging prefixes). The longer-promised unification
  (making `extract-rootfs.sh` the single source of truth and embedding
  it into the stub heredoc at build time) is deferred pending its own
  reviewed look — the stub's r159 branch is ~430 lines of extraction +
  post-extraction setup (dpkg configure, ssh-keygen, networkd cleanup,
  ncz-baked marker, ncz-firstboot generation, fstab scaffolding) and
  collapsing that into `extract-rootfs.sh` is a larger refactor than
  the original audit assumed. The consistency check is the cheap
  mechanical gate that closes the "two copies silently diverged" trap
  in the meantime: a fix made in one file and forgotten in the other
  cannot reach a shipped ISO.
- **`desktop-hotfix.squashfs` has no committed builder.** It was built by
  hand/agent outside the repo, which is how a mktemp-mode dir got baked
  in. Any layer that ships on the ISO needs a committed builder script
  that stages into an explicitly `install -d -m 0755` root (as
  build-squashfs-layers.sh already does for base).
  **Status (2026-08-26):** closed by `build_hotfix()` in
  build/build-squashfs-layers.sh. Reproduces the layer from the latest
  `assets/cix-debs/ncz-singularity-desktop_*.deb` (which is the actual
  source of `/opt/singularity`); stages into `$WORK/hotfix` with explicit
  `install -d -o root -g root -m 0755`; writes the
  `desktop-hotfix.overlay-manifest` with the `opaque opt/singularity`
  marker; mksquashfs at the same compression settings as base/desktop;
  and runs `verify_squashfs()` for the same cold-read corruption guard
  as the other layers. Invoked via `bash build/build-squashfs-layers.sh
  hotfix` (or as part of `all`). Provenance of the hotfix content is
  partially recoverable: 588/589 files come from the .deb (the .deb
  itself is reproducible via build/build-singularity.sh +
  build/build-singularity-deb.sh), 1 file (`/etc/ld.so.conf.d/singularity.conf`)
  is staged explicitly, and 6 labwc man-page timestamps regenerate from
  the deb's labwc build date. The original 2026-08-25 ad-hoc build's full
  derivation is not preserved -- this is the honest "we can rebuild it
  reproducibly now, we don't have full provenance for what it originally
  patched" trade-off, not a claim of full traceability.
- **`build/iso-staging-di/` contains committed COPIES of preseed/ +
  post-install/.** They are build artifacts refreshed on every build —
  grep hits there are decoys; do not read or edit them.

## Testing d-i-environment shell code before shipping (2026-08-26)

Rounds 4-5 of the incident above both shipped gate-code bugs that only
manifested in the actual debian-installer BusyBox runtime -- a missing
`stat` applet, then a corrupted `awk` invocation from a stray bash
quote-escaping trick applied inside a Python-generated patch. Both were
"verified" by hand-typing an equivalent command in a normal bash shell,
which is a DIFFERENT environment from the one the code actually runs in.

**`build/test-under-di-busybox.sh` closes this gap.** It extracts the REAL
substrate initrd (`build/iso-staging-di/install.a64/initrd.gz`) and chroots
into it to run the exact BusyBox build (currently v1.38.0 Debian
1:1.38.0-3+b1) that d-i actually uses at install time -- confirmed to be a
DIFFERENT applet set from other busybox binaries on a build host (e.g. the
diag module's own static `assets/diag/busybox-arm64`, v1.37.0 Ubuntu, DOES
have `stat`; testing against that instead would have given a false pass on
exactly the round-4 bug).

```
sudo bash build/test-under-di-busybox.sh 'ls -ld /tmp | awk '"'"'{print $1}'"'"''
sudo bash build/test-under-di-busybox.sh -f path/to/snippet.sh
sudo bash build/test-under-di-busybox.sh --applet-list
```

Requires `make iso` (or at least the early staging steps of
`build/build-iso-di.sh`) to have run at least once, so the initrd exists.
Requires root (chroot). Caches the extraction (keyed on the initrd's mtime)
so repeat invocations are fast.

**Any change to code that runs inside the d-i environment** (the r159 stub
in build/build-iso-di.sh, preseed/extract-rootfs.sh, preseed/late.sh,
diag-console.sh) should be run through this tool against the LITERAL
committed line before the commit lands -- not an equivalent typed into a
normal shell. This is now the standard practice, not optional.
