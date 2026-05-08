# R78 take13 trixie d-i substrate audit

Audited commit: `bcd2d1e0cc4ad891685ac53255c9b2bc81619ca9`

Scope: `build/build-iso-di.sh`, `preseed/preseed-ubuntu.cfg`,
`preseed/late.sh`, `preseed/sshd-watcher.sh`,
`post-install/run-all.sh`, `post-install/09-diag-account.sh`.

Note: the requested local ISO
`/Users/jperlow/cix-installer/downloads/debian-13.4.0-arm64-netinst.iso`
was not present in this workspace, and no `downloads/` directory existed.
Local ISO pool/dists inspection could not be completed.

## Verdict

RED for the DNS premise. I did not find an `if`/`fi` nesting defect in the
new trixie graft conditional, and the common debootstrap-udeb patch path still
runs after the trixie skip. However, the core take13 claim is not verified:
trixie netcfg does not appear to turn `netcfg/get_nameservers` into an
append-to-DHCP mechanism. It remains a fallback/static-input path when DHCP did
not provide DNS. I also found no Debian d-i source evidence that busybox
`udhcpc` honors `/etc/resolv.conf.head`; that behavior is associated with
`dhcpcd` in installed systems, not clearly with busybox-udhcpc in d-i.

Do not treat the bookworm-to-trixie substrate switch as a DNS fix by itself.
Patch DNS at the DHCP script/netcfg producer, or tighten the watcher enough
that it cannot lose the pkgsel/grub-installer race.

## HIGH findings

1. `netcfg/get_nameservers` is not an append-to-DHCP override, so the original
DNS failure mode can survive take13.

`preseed/preseed-ubuntu.cfg:43` sets:

`d-i netcfg/get_nameservers string 192.168.207.1 8.8.8.8 1.1.1.1`

In Debian's documented trixie preseed example, `netcfg/get_nameservers` is
shown under static network configuration, while DHCP hostname/domain values are
explicitly allowed to take precedence over preseeded values. The netcfg DHCP
source path reads DNS supplied by DHCP and only asks `netcfg/get_nameservers`
when the interface has zero nameservers. That is fallback behavior, not append
behavior. Sources:

- Debian trixie preseed guide:
  https://www.debian.org/releases/stable/amd64/apbs04.en.html
- Debian trixie netcfg source package is 1.197:
  https://packages.debian.org/source/stable/netcfg
- netcfg DHCP source path:
  https://sources.debian.org/src/netcfg/1.197/dhcp.c/

Impact: if DHCP supplies only `192.168.207.1`, d-i can still run with the LAN
router DNS only until `sshd-watcher.sh` appends public resolvers. The current
watcher runs every 10s, so there is still a window where apt/pkgsel can hit the
same "Temporary failure resolving" cascade.

Pre-flash action: keep the LAN resolver first for `nclawzero.lan`, but patch
the producer path. Best option is to patch `/etc/udhcpc/default.script` in the
d-i environment so every DHCP bound/renew event writes router DNS plus
`8.8.8.8` and `1.1.1.1`. If that is too invasive, reduce the watcher interval
to 1s during install and write fallbacks before network-heavy phases. Do not
rely on `/etc/resolv.conf.head` until verified from the actual initrd script.

## MEDIUM findings

1. `pkgsel/install-recommends` is the wrong Debian d-i question name.

`preseed/preseed-ubuntu.cfg:340` uses `pkgsel/install-recommends`. Debian's
documented/accepted question is `pkgsel/include/install-recommends`. Historical
Ubuntu material used `pkgsel/install-recommends`, but Debian renamed/documented
the include-scoped question. Sources:

- Debian installation-guide changelog documents
  `pkgsel/include/install-recommends`:
  https://sources.debian.org/src/installation-guide/20190622/debian/changelog/
- Debian trixie package selection docs list `pkgsel/include` but not
  `pkgsel/install-recommends`:
  https://www.debian.org/releases/stable/amd64/apbs04.en.html

Impact: the line is probably silently ignored by Debian trixie d-i. The later
`base-installer/install-recommends=false` line is valid and should globally
mitigate Recommends, but the pkgsel-specific comment is false.

Action: replace or supplement with:

`d-i pkgsel/include/install-recommends boolean false`

2. Codename auto-detection is ambiguous on multi-codename media.

`build/build-iso-di.sh:376-382` checks `trixie` first, then `bookworm`.
If both directories exist, it silently chooses trixie while `find pool -name
'*.udeb'` captures the whole pool. The regenerated udeb index can then expose
mixed-runtime udebs. This is probably fine for official single-codename
netinst media, but it is fragile for multi-codename or symlink-heavy media.

Action: fail if more than one supported codename directory is present unless an
explicit override is supplied.

3. The trixie skip path lacks the graft branch's fail-fast udeb checks.

When `DI_CODENAME=trixie`, lines 463-509 skip the explicit graft. The common
path later checks exactly one `debootstrap-udeb`, but it does not assert the
presence of `libzstd1-udeb` and `liblzma5-udeb` in the staged pool. Official
trixie packages still use the expected source/package names:

- `debootstrap-udeb` 1.0.141:
  https://packages.debian.org/trixie/i386/debootstrap-udeb
- trixie d-i source package set includes base-installer 1.226, pkgsel 0.85,
  netcfg 1.197:
  https://packages.debian.org/source/trixie/debian-installer/

Action: after substrate udeb merge, assert exactly one debootstrap udeb and at
least one matching `libzstd1-udeb` and `liblzma5-udeb`, regardless of
bookworm/trixie substrate.

4. The amber cdebconf-newt binary patch is a bookworm-specific build-time
assumption.

`build/build-iso-di.sh:982-1034` binary-patches `newt.so` at a fixed offset and
aborts if the expected pointer is not there. Trixie cdebconf-newt can move that
table. If the take13 bake already passed this stage, this is moot for that
artifact. If not, this can block the bake for a cosmetic palette change.

Action: make the binary palette patch substrate-version keyed or non-fatal.

## LOW + NIT findings

- The outer trixie graft conditional is scoped correctly. `if [ "$DI_CODENAME"
  = "trixie" ]; then ... else ... if true; then ... fi; fi` closes the inner
  historical `if true` before the outer conditional. `bash -n` also passes.

- Step 4 works for trixie in shape: all substrate udebs are captured, copied
  into `pool/`, then `dpkg-scanpackages --type udeb --multiversion` regenerates
  the `resolute` udeb index from actual pool contents. The later debootstrap
  patch uses the same staged udeb whether it came from substrate capture or
  explicit graft.

- `.disk/base_installable` remains a valid d-i lever. Trixie source packages
  still carry the same media/base-on-CD model; `choose-mirror` checks
  `/cdrom/.disk/base_installable`, and base-installer's `get_mirror_info` uses
  that marker to force `file:///cdrom`. Sources:
  https://sources.debian.org/src/choose-mirror/2.133/choose-mirror.c/
  and https://sources.debian.org/src/base-installer/1.226/library.sh/

- `late.sh` replacing `/target/etc/resolv.conf` with a real file should not be
  undone by merely entering the chroot. There is no running systemd-resolved in
  `in-target`. The comment that boot will automatically re-symlink it is less
  certain; if that final state matters, add an explicit first-boot restore.

- `preseed/early_command` uses busybox-safe applets for the listed commands:
  `mkdir`, `chmod`, `printf`, `date`, `ls`, `cp`, `ln`, plus `echo`. It does
  not depend on `nohup`.

- `sshd-watcher.sh` process handling is acceptable. The DNS loop inherits the
  append-only log fd and should survive parent exit under busybox ash; `sshd`
  has long supported SIGHUP reload. The bigger issue is resolver race timing,
  not shell lifetime.

- `post-install/run-all.sh` Phase 0 `ls 0[0-9]-*.sh | sort` is idempotent for
  the intended pre-10 hooks. The optional hook regex excludes `0[0-9]`,
  `10-our-kernel`, `12-sky1-firmware`, `70-bootloader`, and `99-diagnostics`
  correctly.

- `post-install/09-diag-account.sh` runs in the target chroot with full Ubuntu
  userland; no trixie d-i busybox issue found.

- Non-load-bearing bookworm strings remain in comments, variables, and user
  flags (`--bookworm-iso`, `BOOKWORM_ISO`, "merging bookworm udebs", GRUB
  comments). They are confusing but not functional blockers.

## DNS resilience claim verification

Result: not verified; likely false as stated.

Verified:

- Trixie d-i uses newer component versions (`netcfg` 1.197, `base-installer`
  1.226, `pkgsel` 0.85 per Debian trixie source package index).
- The documented trixie preseed interface still treats
  `netcfg/get_nameservers` as static/fallback network configuration.
- The netcfg DHCP code path only asks for nameservers when DHCP did not
  provide any.
- `.disk/base_installable` remains part of trixie d-i behavior.

Not verified:

- No source evidence that Debian d-i busybox-udhcpc honors
  `/etc/resolv.conf.head`.
- No source evidence that trixie netcfg appends preseeded nameservers to
  DHCP-provided DNS.

Related source:

- Debian trixie installation information:
  https://www.debian.org/releases/trixie/debian-installer/
- Debian trixie preseed guide:
  https://www.debian.org/releases/stable/amd64/apbs04.en.html
- Debian trixie source package index:
  https://packages.debian.org/source/trixie/debian-installer/
- Debian busybox/udhcpc package details:
  https://packages.debian.org/ca/trixie/x32/net/udhcpc
- Debian bug discussion of d-i busybox-udhcpc writing resolver data:
  https://bugs.debian.org/927413

## Recommended take13 actions

Before flashing .66 hardware:

1. Fix DNS as an explicit NCZ behavior, not as an assumed trixie behavior.
   Patch d-i's DHCP resolver writer or make the watcher near-immediate. Preserve
   `192.168.207.1` first, append public fallbacks, and include
   `options timeout:2 attempts:3`.

2. Change `pkgsel/install-recommends` to
   `pkgsel/include/install-recommends` while keeping
   `base-installer/install-recommends=false`.

3. Add post-merge build assertions for `debootstrap-udeb`, `libzstd1-udeb`,
   and `liblzma5-udeb` in both substrate paths.

4. If take13 bake has not already passed, make the cdebconf-newt palette patch
   non-fatal or version-keyed for trixie.

If the bake passes and you still proceed to a smoke test:

1. During pkgsel, capture `/etc/resolv.conf`, `/var/log/syslog`, `ps`, and any
   `udhcpc` process state from network-console.

2. Confirm whether `/etc/udhcpc/default.script` exists in the actual initrd and
   whether it references `resolv.conf.head`. Only then decide whether writing
   `/etc/resolv.conf.head` is useful belt-and-suspenders.
