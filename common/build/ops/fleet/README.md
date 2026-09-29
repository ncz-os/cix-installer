# build/ops/fleet — fleet backup to argonas2

**REFERENCE COPIES.** These files are hand-deployed to each host at
`/usr/local/bin/ncz-backup.sh` and `/etc/systemd/system/ncz-backup.{service,timer}`.
They are NOT auto-deployed from this repo. To change fleet behaviour, edit the
host copies and update these to match — the same convention used by
`build/ops/argos/ncz-reprepro-publish.sh`.

They live in git because on 2026-08-11 they lived NOWHERE ELSE: the script that
exists specifically to stop silent backup loss was itself unbacked-up, present
only on the 11 hosts running it. Losing a host would have lost the recovery
mechanism along with the data.

## Why the script is shaped the way it is

The contract is **"prove data landed"**, not "run rsync". It writes a
`.ncz-backup-heartbeat` carrying the measured size and fails loudly on an empty
backup, because on 2026-08-10 three independent silent failures were found at
once — empty per-host dirs five weeks old, a dead pull job, and a daily
snapshot of 256K that made the snapshot list look healthy.

## Target

argonas2 = **192.168.207.41**, export `/mnt/datapool/backups`, one
`<hostname>/` subdirectory per host. Auth is `truenas_admin` or `jasonperlow`
with the fleet password — `root` is refused and `admin` is publickey-only.

## Excludes, and one that is NOT a workaround

Caches, `node_modules`, Trash, sockets, proc/sys — the usual.

Container and image stores (`~/.local/share/containers/storage`,
`/var/lib/containers/storage`, `/var/lib/docker`) are excluded for a specific
measured reason. Those overlay layers are owned by mapped subordinate UIDs with
restrictive modes, and the NFS target squashes to a single uid, so rsync cannot
recreate the directories and returns **rc=23**. That failed the ENTIRE backup
even though every byte of real user data had transferred — ACHILLES 2026-08-11,
113 errors, all of them under `containers/storage/overlay`, on a 14G backup
that was otherwise complete.

The fix excludes that content (it is reconstructible with `podman pull`)
instead of suppressing rc=23. Suppressing the exit code would hide a real
failure of something that actually matters, which is precisely the bug this
whole arrangement exists to prevent.

## Deploying a change

Do NOT edit the script on a host while its backup is running: bash reads a
script by byte offset, so changing the length mid-run mangles the line it is
about to execute. Check `systemctl is-active ncz-backup.service` first and skip
any host reporting `active` or `activating`.
