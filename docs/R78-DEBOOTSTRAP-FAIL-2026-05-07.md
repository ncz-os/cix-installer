# r78 chroot-target failure root cause + fix plan — 2026-05-07

Diagnosed live on .66 via `tools/di-diag.sh` (2026-05-07 ~20:50 EDT).

## Symptom on local console

d-i ends in red error dialog: "chroot target failure". Operator has
been seeing this on every take from take3 onward. Our take4/5/6 fixes
were all post-debootstrap; they never ran because debootstrap failed
upstream.

## Root cause — two compound bugs

### Bug A — debootstrap source is `/cdrom/`, not `ports.ubuntu.com`

From the d-i syslog on .66:

```
May  8 00:31:05 debootstrap: /usr/sbin/debootstrap \
    --components=main --debian-installer --resolve-deps --no-check-gpg \
    resolute /target file:///cdrom/ /usr/share/debootstrap/scripts/gutsy
May  8 00:31:06 debootstrap: mknod: /target/dev/null: No such file or directory
May  8 00:31:06 debootstrap: chroot: can't execute '/bin/true': No such file or directory
```

`/cdrom/pool/` in our netinstall ISO contains only 279 udebs (the d-i
substrate). No regular `.deb` packages. debootstrap can't find
base-essential pkgs (`coreutils`, `bash`, `dash`) → /target/bin/true
never gets installed → chroot fails.

Why is debootstrap using `/cdrom/` instead of the HTTP mirror?
Because base-installer detects that `/cdrom/dists/resolute/Release`
exists with a `main` component listed, and prefers /cdrom over the
network mirror.

Our build/build-iso-di.sh in netinstall mode does:
```
netinstall mode: writing empty regular Packages index for late.sh cdrom source
regenerating dists/resolute/Release with both regular + udeb indexes
```

We write an EMPTY `main/binary-arm64/Packages` so that late.sh's
sources.list snippet doesn't 404 — but base-installer takes that to
mean "/cdrom is a valid mirror" and uses it first.

### Bug B — debootstrap script `resolute` doesn't exist; falls back to `gutsy`

The script path resolved to `/usr/share/debootstrap/scripts/gutsy`
(Ubuntu 7.10, 2007). That's d-i's hardcoded fallback when the
codename's script isn't present.

We grafted trixie's debootstrap (commit `r78-take2`-era), but that
local graft is still debootstrap 1.0.141. Ubuntu added the resolute
symlink in 1.0.141ubuntu1, and Debian picked it up in 1.0.142, so the
installer still needs a resolute -> gutsy fallback when using the older
grafted udeb.

## Fix plan

### Fix A — force debootstrap onto the HTTP mirror

Modify `build/build-iso-di.sh` in netinstall mode to NOT advertise the
regular `main` component on /cdrom. Drop the empty Packages index +
remove `main` from /cdrom/dists/resolute/Release components list. Keep
only `debian-installer` so anna can still load udebs.

Code site: around line 1046-1058 of `build/build-iso-di.sh` (the awk
filter for netinstall mode), and the Release-regeneration block.

base-installer will then see:
- /cdrom has debian-installer udebs only (good for anna)
- /cdrom has no main component (so it can't be the bootstrap source)
- preseed says use ports.ubuntu.com → debootstrap fetches from there

### Fix B — ship a `resolute` debootstrap script

Stage `preseed/debootstrap-scripts/resolute` (a copy of Ubuntu's
upstream `resolute` script, or the latest known-good `noble`/`plucky`
script renamed) into the ISO as `/cixmini/debootstrap-scripts/resolute`.

Add a one-line copy in `preseed/early_command` BEFORE any d-i step
that invokes debootstrap:
```
cp /cdrom/cixmini/debootstrap-scripts/resolute \
   /usr/share/debootstrap/scripts/resolute
```

Source for the resolute script: Ubuntu launchpad
`git.launchpad.net/ubuntu/+source/debootstrap` HEAD on jammy/noble/etc.
The resolute script is essentially the same as plucky/noble with the
codename swapped — Ubuntu's debootstrap scripts have been stable for
many releases.

## Why the take6 fixes still mattered

Even with debootstrap working, the original Codex audit findings still
applied:
- early_command's heredoc would have broken d-i preseed parsing once
  install reached early_command processing
- magnetar in Phase 2 alphabetic sort would fail to materialize if
  10-our-kernel.sh aborted
- nohup in busybox would have failed-to-exec

Take6 closes those. Take7 (with this fix) closes the upstream blocker.

## Operator-side immediate value

`tools/di-diag.sh` now exists. Anytime d-i hits a red error dialog:
```
tools/di-diag.sh 192.168.207.66 diag > /tmp/di-diag-$(date +%s).txt
```
gives a complete forensic dump. Was a key diagnostic enabler for this
session — without it I had to ask the operator to read the screen.

## Question raised: "is there a better solution like telnet we can
turn off prior to shipping?"

Yes. The d-i network-console TTY+screen+curses path is annoyingly
complex for automation. Cleaner alternative for build-time diag:

**Spawn a tiny `socat`/`nc` shell on port 2222 from early_command,
killed in late.sh before reboot.** No auth, plain text, fleet-private
LAN only. Bypasses the screen multiplexer entirely.

```sh
# in preseed/early_command (sketch):
( while true; do
    nc -l -p 2222 -e /bin/sh
  done ) </dev/null >/dev/null 2>&1 &

# in preseed/late.sh near the top:
pkill -f 'nc -l -p 2222' 2>/dev/null
iptables -A INPUT -p tcp --dport 2222 -j DROP 2>/dev/null
```

**Caveat:** busybox `nc` in d-i may lack `-e`. Verified empirically
that busybox 1.35.0 in d-i ships with `nc` but `-e` flag depends on
build flags. Need to test. If `-e` absent, use a tiny shell wrapper:

```sh
mkfifo /tmp/sshell.fifo
( while true; do
    nc -l -p 2222 < /tmp/sshell.fifo | /bin/sh > /tmp/sshell.fifo 2>&1
  done ) &
```

**Even simpler:** ship `dropbear` as an extra binary in /cixmini/
(arm64 static, ~250KB). Spawn `dropbear -p 2222 -F -E -B -P /tmp/dropbear.pid`
from early_command. Clean SSH, key-based auth, no screen wrapper, no
interactive prompts. Killed in late.sh.

Recommend the dropbear approach for take8+ — gets us a "diag side-
channel" that's robust, scripted, and disabled before reboot. Defer
the implementation; di-diag.sh + the take7 build-iso-di.sh fix are
the higher priority items.

## Commit lineage to be added

```
48e9c91     tools(di-diag): add expect-based d-i shell driver
<NEXT>      fix(build): netinstall must not list main component on /cdrom
<NEXT2>     feat(preseed): ship resolute debootstrap script + early-stage copy-in
<NEXT3>     [r78-take7 baked]
```
