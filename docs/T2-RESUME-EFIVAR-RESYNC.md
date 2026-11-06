# T2 (MEDUSA, MacBookPro16,1) — `efivarfs: removing variable …` flood after S3 resume

Date: 2026-10-17. Task: T2-RESUME-2 (code-level investigation; no test-host changes).

Symptom (MEDUSA, kernel `7.3.0-rc7-t2-ncz`): right after S3 resume the kernel logs
`efivarfs: resyncing variable state`, then ~60 lines of
`efivarfs: removing variable <name>-<guid>` — including `PK`, `KEK`, `db`, `dbx`,
`AppleSecureBoot*`, `BridgeOS*`, `MLB`, `ROM`, `SrNm` — then one or more
`efivarfs: creating variable …` lines (the session observed
`AppleSecureBootPolicy`) and `efivarfs: finished resyncing variable state`.
Immediately afterwards `fwupd` fails to read `db`/`dbx`
("no data to read" / "Error opening file").

## What was actually examined

| Input | Exact revision | Used for |
|---|---|---|
| Upstream tree, checked out locally (`git fetch --depth 1 <sha>`) | torvalds/linux commit `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907` = tag `v7.3-rc7` (the `SRCREV_kernel` of the T2 line, `kernel-source/SOURCE.md`) | every kernel code claim below |
| T2 patch series as it is applied to that base | `https://gitlab.com/ncz-os/linux-t2-ncz`, tag `v7.3.0-rc7-t2-ncz-2` (`35249a98`), `patches/series` (24 patches) | whether the T2 carry-patches touch efivarfs / EFI runtime / PM |
| Upstream efivarfs history up to `v7.3-rc7` | `git log v7.3-rc7 -- fs/efivarfs` | when the resync landed and what changed since |
| The four-line summary in `kernel-source/SOURCE.md` | — | cross-check only |

Line numbers cited are from `24a19b953e2a3d0ea5a8c4951a0ab8f32720c907`; code is
re-quoted with the upstream tab indentation.

## TL;DR

1. **The flood is the efivarfs thaw-time resync**, `efivarfs_unfreeze_fs()`
   (`fs/efivarfs/super.c:469`), reached on every S3 wake because the sb is
   registered `FS_POWER_FREEZE` (`fs/efivarfs/super.c:552`). It landed as
   **`efivarfs: support freeze/thaw` (Christian Brauner, committed 2025-05-09,
   merged for v6.16 via `vfs-6.16-rc1.super`)**, replacing the earlier
   `PM_POST_HIBERNATION`-only resync (Bottomley, committed 2025-01-22). The date
   matters: the brief's "around v6.15/v6.16" is right, and the *thaw* variant that
   runs on S3 is precisely the v6.16 one — the v6.15 shape could not have produced
   this log on S3.
2. **(a) It is a view resync, not a data operation.** For every dentry it issues
   one `GetVariable()` size probe; `size == 0` — which covers "firmware says
   `EFI_NOT_FOUND`" **and every other error status**, because `err` is collapsed
   to `size = 0` — deletes the dentry (`simple_recursive_removal()`, pure VFS), and
   then one `GetNextVariable()` walk recreates dentries for variables the
   firmware still enumerates (`efivarfs_check_missing` → `efivarfs_create_dentry`).
   **Dentry deletion is not caused by the firmware.** The kernel deletes the
   dentry whenever the *probe* says zero; the firmware only decides that by
   answering the probe. So the log proves the firmware-fact "`GetVariable()`
   returned a non-`EFI_BUFFER_TOO_SMALL` status for these ~60 variables at thaw
   time" and nothing more. Whether that is "the variables are genuinely gone"
   or "the T2 RT service is degraded right after resume" is not decidable from
   this log; §(a.5) gives the on-host discriminator.
3. **(b) NVRAM is not touched by the resync.** No write RT service is reachable
   from the thaw path: `SetVariable()` is called only from
   `efivar_entry_set_get_size()` (the `write()` path) and `efivar_entry_delete()`
   (direct `efivar` API, not called by efivarfs), and every EFI call in the resync
   is handed to the firmware worker under a **read-only** action table (§(b.2)).
4. **(c) The fwupd failure is the read path, not the resync.** After the resync,
   the `db`/`dbx` dentries are *gone* — the read is not a 0-byte read of an
   existing file, it is `open()` failing with `ENOENT` unless something
   re-creates the dentry first. That distinction drives the workaround in
   §Recommended action (re-create the dentries with `efivarfs_check_missing()`'s
   own logic — i.e. a re-mount — rather than "just re-read").
5. **(d) Upstream status: this is a known, still-argued-about false-positive
   class, not an unknown T2 bug.** The resync cannot tell "gone" from "error", the
   removal log is emitted at `pr_info` (a normal console level), and the
   create/remove churn the session saw (`AppleSecureBootPolicy` recreated) is the
   signature of a variable whose enumeration and read views disagree. No
   T2/Apple-specific report was found — see the "unproven" note at the end about
   what could not be searched from this host.

## (a) What the log actually is

### (a.1) Why the resync runs on S3

`fs/efivarfs/super.c:546`:

```c
static struct file_system_type efivarfs_type = {
	.owner		= THIS_MODULE,
	.name		= "efivarfs",
	.init_fs_context = efivarfs_init_fs_context,
	.kill_sb	= efivarfs_kill_sb,
	.parameters	= efivarfs_parameters,
	.fs_flags	= FS_POWER_FREEZE,
};
```

`include/linux/fs.h:2298`: `#define FS_POWER_FREEZE 256 /* Always freeze on suspend/hibernate */`.

`kernel/power/suspend.c` (the S3 path) freezes and thaws *all* superblocks on
every suspend cycle:

- `suspend.c:385` — `filesystems_freeze(filesystem_freeze_enabled)`
- `suspend.c:393` — `filesystems_thaw()` on the success path
- `suspend.c:563` — `filesystems_thaw()` on the resume-failed/abort path

`fs/super.c:1249` is where the flag earns its name: with `freeze_all == false`
(i.e. no `filesystems_freeze=` kernel command line) only superblocks whose
`fs_flags` carry `FS_POWER_FREEZE` are frozen — efivarfs being the only one.
`filesystems_thaw()` (`fs/super.c:1293`) then calls `->thaw_super`, which ends
in `efivarfs_unfreeze_fs()`.

Consequence worth knowing **before** going hunting: with
`filesystems_freeze=0` on the kernel command line the flag is ignored
(`fs/super.c:1249`) and the resync does not run at all. That is the cheapest
confirmation experiment on a test host — it is *not* recommended as a permanent
workaround (§Recommended action) because it also disables data-FS freeze/thaw.

### (a.2) The resync itself

`fs/efivarfs/super.c:469`:

```c
static int efivarfs_unfreeze_fs(struct super_block *sb)
{
	struct dentry *child = NULL;

	/*
	 * Unconditionally resync the variable state on a thaw request.
	 * Given the size of efivarfs it really doesn't matter to simply
	 * iterate through all of the entries and resync. Freeze/thaw
	 * requests are rare enough for that to not matter and the
	 * number of entries is pretty low too. So we really don't care.
	 */
	pr_info("efivarfs: resyncing variable state\n");
	for (;;) {
		int err;
		unsigned long size = 0;
		struct inode *inode;
		struct efivar_entry *entry;

		child = find_next_child(sb->s_root, child);
		if (!child)
			break;

		inode = d_inode(child);
		entry = efivar_entry(inode);

		err = efivar_entry_size(entry, &size);
		if (err)
			size = 0;
		else
			size += sizeof(__u32);

		inode_lock(inode);
		i_size_write(inode, size);
		inode_unlock(inode);

		/* The variable doesn't exist anymore, delete it. */
		if (!size) {
			pr_info("efivarfs: removing variable %pd\n", child);
			simple_recursive_removal(child, NULL);
		}
	}

	efivar_init(efivarfs_check_missing, sb, false);
	pr_info("efivarfs: finished resyncing variable state\n");
	return 0;
}
```

Three properties matter:

1. `err = efivar_entry_size(); if (err) size = 0;` — **every** failure mode
   (`EFI_NOT_FOUND`, `EFI_DEVICE_ERROR`, `EFI_ACCESS_DENIED`,
   `EFI_OUT_OF_RESOURCES`, `EFI_ABORTED`, or the `-EINTR`/`-ENODEV` of
   `efivar_lock()` itself) is indistinguishable at this point and leads to the
   same "removing variable" line.
2. The line is `pr_info`, i.e. level 6 — it is printed on a normal console. A
   benign resync is therefore *always* noisy on hardware where the firmware is
   slow to settle after resume. Apple T2 is such hardware (§a.6).
3. The resync does not hold the efivars lock across the whole loop: each
   `efivar_entry_size()` takes and drops it (`drivers/firmware/efi/vars.c:142`),
   and the `efivar_init()` walk takes it again. A firmware service that becomes
   available *between* two probes is therefore not observed consistently.

### (a.3) The probe

`fs/efivarfs/vars.c:494`:

```c
int efivar_entry_size(struct efivar_entry *entry, unsigned long *size)
{
	efi_status_t status;
	int err;

	*size = 0;

	err = efivar_lock();
	if (err)
		return err;

	status = efivar_get_variable(entry->var.VariableName,
				     &entry->var.VendorGuid, NULL, size, NULL);
	efivar_unlock();

	if (status != EFI_BUFFER_TOO_SMALL)
		return efi_status_to_err(status);

	return 0;
}
```

Note the `DataSize = NULL` call: UEFI-spec `GetVariable()` with a `NULL`
`DataSize` is a pure "does this exist / how big is it" probe and cannot modify
anything. `efivar_get_variable()` (`drivers/firmware/efi/vars.c:184`) is
`__efivars->ops->get_variable(...)`, i.e. the UEFI RT service through the
runtime-wrapper worker.

**Correction to a common reading of the fwupd error:** `efivarfs_file_read()`
(`fs/efivarfs/file.c:79`) returns `0` (EOF) only for `-ENOENT`
("uncommitted variable"); *any other* error is returned negative, i.e.
`read()` fails with `EIO`/`EACCES`/`EINVAL`, not with a short read. So the
0-byte read and the failed read have different causes, and the observed
"Error opening file" is a third: `open()` on a deleted dentry.

### (a.4) The create side

`efivar_init()` (`fs/efivarfs/vars.c:375`) walks `GetNextVariable()` under the
lock and calls `efivarfs_check_missing()` (`fs/efivarfs/super.c:425`) for each
name it sees; a name without a dentry produces
`pr_info("efivarfs: creating variable %s\n", name)` and
`efivarfs_create_dentry()`, which allocates the inode, copies name/GUID and
calls `__efivar_entry_get()` — a read — to seed `i_size`. No write RT service,
no `SetVariable()`.

So at the end of a resync the dentry set equals *what `GetNextVariable()`
returned*, and each dentry's size equals *what `GetVariable()` answered most
recently*. The two views come from two different firmware entry points. The
session's log shows them disagreeing in both directions in a single pass:
~60 removals (probe said absent) followed by at least one creation
(enumerate said present). That is the signature of a firmware whose
`GetVariable()`/`GetNextVariable()` answers are not consistent for a few
seconds after resume — not of 60 variables having been wiped.

### (a.5) So: "firmware no longer reports them" or "T2 RT degraded"?

The kernel cannot answer this; the log records neither the status code (it is
discarded at `super.c:496`) nor how long the condition lasts. What the kernel
*does* tell us is which answers are needed for each hypothesis:

| Observation (after resume) | Conclusion |
|---|---|
| `ls /sys/firmware/efi/efivars/ \| grep -c .` returns ~the pre-suspend count, `db`/`dbx` present, and reading them yields data | **Transient firmware view.** The values were never gone; the probe raced the T2 RT service settling. Later re-sync re-created the dentries. |
| `db`/`dbx` still absent, but an enumeration tool (`efivar -l`, `fwupdmgr get-devices`) lists them | **Partial view**: enumeration sees them, `GetVariable()` still fails — firmware-side, persistent for this boot. |
| Variables absent from enumeration too (`efivar -l`), and still absent after a reboot | **Genuine deletion by firmware.** Only then does the NVRAM *content* question arise — and the resync still is not the writer. |
| Log comes back every resume for the same list | Not a race — deterministic, i.e. firmware behaviour for those namespaces (`AppleSecureBoot*`, `BridgeOS*`, `PK`/`KEK`/`db`/`dbx`). |

The cheap ordering test that separates the last row from the first: run
`grep . /sys/firmware/efi/efivars/* >/dev/null` immediately at resume and again
30 s later (raw dump, no name assumption — `Name-GUID` filenames are not
stable across firmware versions, so do not hard-code `db-8be4df61-…`), and
`journalctl -k -b | grep -c 'efivarfs: removing variable'`.

### (a.6) Why the T2 specifically would have a slow view

Not proven here — but the T2 patch series we ship (**this package's own
`patches/series`, 24 patches**) contains three items whose subject is exactly
"reach the firmware too early after a power state change":

- `9001-ACPI-x86-Apple-T2-systems-need-early-CPU-offlining.patch`
- `9503-wifi-brcmfmac-handle-missing-D3-ACK-on-BCM4377-T2-Macs.patch`
- `5002-drm-appletbdrm-Add-suspend-and-resume-support.patch`

None of them touches `fs/efivarfs/`, `drivers/firmware/efi/` or the PM core
(checked against the applied tree: `git diff v7.3-rc7 --stat` shows no hunk in
those paths), so **our T2 kernel does not change any of the code discussed
here.** efivarfs and the EFI runtime wrappers in the shipped kernel are
stock v7.3-rc7.

## (b) Are the NVRAM contents affected? No — from the code path

### (b.1) The only writers in the efivarfs code base

```c
/* fs/efivarfs/vars.c:470 — efivar_entry_delete() */
status = efivar_set_variable_locked(entry->var.VariableName, ..., 0, 0, NULL, false);

/* fs/efivarfs/vars.c:581 — efivar_entry_set_get_size() */
status = efivar_set_variable_locked(name, vendor, attributes, *size, data, false);
```

`efivar_set_variable_locked()` (`drivers/firmware/efi/vars.c:209`) is the only
function in `fs/efivarfs/` + `drivers/firmware/efi/vars.c` that reaches
`SetVariable()`. Its callers are:

- `efivar_entry_set_get_size()` ← `efivarfs_file_write()` (a userspace `write()`
  to an efivars file),
- `efivar_entry_delete()` ← `efivarfs_unlink()`, i.e. a userspace `unlink()`
  of an efivars file (`fs/efivarfs/inode.c:123`).

Both are *userspace-initiated* syscalls. Neither is reachable from
`efivarfs_unfreeze_fs()`, `efivarfs_check_missing()` or
`efivarfs_create_dentry()`, and `simple_recursive_removal()` — the deletion
primitive the resync uses — does not go through `->unlink` at all; it calls
`d_invalidate`/`fsnotify_delete`/`d_make_discardable` directly (§b.3). The
distinction matters for a tool author: a *resync* removal never writes, but a
tool that reacts to the transient `ENOENT` with `unlink`-then-recreate *does*.

### (b.2) Even a mis-routed call cannot write during a resync

The EFI runtime is not called directly; `efi_queue_work()` hands the operation
to a worker that dispatches through a **compile-time action table**
(`drivers/firmware/efi/runtime-wrappers.c`), one `case` per RT service. Only
`EFI_SET_VARIABLE` maps to `set_variable`. The resync only ever enters
`EFI_GET_VARIABLE` / `EFI_GET_NEXT_VARIABLE_NAME`. There is no "generic call"
path that could be redirected to a write.

### (b.3) The resync's removal side is pure VFS

`__simple_recursive_removal()` (`fs/libfs.c:597`) performs, per victim dentry:
`inode_set_ctime_current`, `clear_nlink`, `d_invalidate`, the caller's
`callback` (`NULL` here), `fsnotify_delete`, `d_make_discardable`, and
`dput`. It deliberately bypasses `->unlink`; that is why VFS-internal
deletions (the resync, `efivarfs_file_release()` on an uncommitted variable)
cannot write NVRAM even though a userspace `unlink()` of the same file can. The `struct efivar_entry` that backs the inode is slab memory
(`efivarfs_alloc_inode`, `fs/efivarfs/super.c:45`) and is freed with the inode
— it is not a persistent object. **No EFI call, no block device, no write.**

### (b.4) What is lost: the uncommitted-variable flag

`efivarfs_file_release()` (`fs/efivarfs/file.c:122`) deletes the dentry when
the last reader closes a size-0 file — this is efivarfs' own representation of
"this variable was created by a failed write, or has been deleted". That is the
one stateful thing a resync interacts with: a dentry the resync zeroed *and*
that is then opened and closed disappears. It is still a dentry operation;
NVRAM is unchanged.

**Conclusion (b):** the resync cannot corrupt or delete NVRAM contents. It can
only be *wrong about the view*. If bytes in NVRAM differ after resume, the
writer was the firmware (or a userspace `write()`/`efivar` call by a tool
reacting to the transient absence — worth keeping in mind for boot-entry
repair scripts, which should never "repair" a variable they only failed to
*read*).

## (c) User-visible impact

### (c.1) The three distinct failure shapes

| Shape | Path | What userspace sees |
|---|---|---|
| Dentry removed by resync | `open("/sys/firmware/efi/efivars/<name>-<guid>")` after `simple_recursive_removal()` | `ENOENT` — "Error opening file". This is the shape of the reported `fwupd` failure: the file is gone, not empty. |
| Dentry alive, probe fails with `-ENOENT` | `efivarfs_file_read()`, `err == -ENOENT` | `read()` returns 0 — "no data to read". This is the *old* "uncommitted variable" convention, now also produced by a firmware `EFI_NOT_FOUND`. |
| Dentry alive, probe fails otherwise | `EIO`/`EACCES`/`EINVAL` from `efi_status_to_err()` | `read()` fails with an errno, which most tools surface as a generic read error. |

`fwupd`'s `efi_esrt`/`efi_capsule` plugins, `mokutil`, `efibootmgr -v`,
`efivar -p`, `bootctl status` and our own `ncz` efivars readers all open by
path, so all of them hit shape 1 first and shape 2/3 only after something
re-created the path. Practical meaning: **right after resume, "variable not
found" is not evidence that the variable is not in NVRAM**, and a tool must not
act on it destructively (re-creating a `Boot####` entry, re-enrolling keys,
"fixing" a boot order).

### (c.2) Recovery without a reboot

The dentries come back by themselves at the **next** freeze/thaw cycle (next
suspend/resume) — `efivarfs_check_missing()` re-creates every name the firmware
enumerates. Within the same boot, the same code runs on a fresh mount, and
`efivarfs_type` is single-instance (`efivarfs_get_tree()` →
`get_tree_single()`), so `mount -t efivarfs efivarfs <dir>` where efivarfs is
not otherwise mounted is the way to force the enumeration again. Because the
superblock is usually mounted, the practical in-boot recovery is a
*umount + mount* — which needs the mount to be idle. For `fwupd` specifically
the least invasive action is: retry after the next resume, or reboot.

### (c.3) Boot entries

`Boot####`, `BootOrder`, `BootNext`, `Driver*`, `ConIn/ConOut/ErrOut`, `Lang`,
`OsIndications` and `Timeout` are the names efivarfs marks *removable*
(`variable_validate[]`, `fs/efivarfs/vars.c:169`); `PK`/`KEK`/`db`/`dbx` and the
Apple names are not. Removability only controls whether the inode may be
unlinked from userspace — it does **not** make the resync delete them, and it
does not change what happens on read. There is therefore no special
boot-entry risk beyond (c.1).

## (d) Upstream status

### (d.1) The mechanism's history, as it actually landed

`git log v7.3-rc7 -- fs/efivarfs` (commit id, author date as reported by
cgit; each id resolves in `24a19b953e2a`):

| Commit subject | Author | Committed | Landed via |
|---|---|---|---|
| `efivarfs: add variable resync after hibernation` (`b5d1e6ee761a`) | James Bottomley | 2025-01-22 | v6.15 (`efi-next-for-v6.15`) |
| `efivarfs: fix NULL dereference on resume` (`11092db5b573`) | James Bottomley | 2025-03-18 | v6.15 |
| `efivarfs: use I_MUTEX_CHILD nested lock to traverse variables on resume` (`dec1277875a5`) | Ard Biesheuvel | 2025-03-17 | v6.15 |
| **`efivarfs: support freeze/thaw`** (`0e4f9483959b`) | Christian Brauner | **2025-05-09** | **v6.16** (`vfs-6.16-rc1.super`) |
| `power: always freeze efivarfs` (`a3f8f8662771`) | Christian Brauner | 2025-11-12 | v6.17 |
| `convert efivarfs` (`e11e24760858`) | Al Viro | 2025-11-16 | v6.18 |
| `efivarfs: fix error propagation in efivar_entry_get()` (`4b22ec1685ce`) | Kohei Enju | 2026-01-19 | 6.19 |
| `efivarfs: Rate limit statfs() handler` (`b2326338dc68`) | Ard Biesheuvel | 2026-08-20 | v7.3 |

Two consequences:

- The *pre-6.16* code is not what MEDUSA ran. Before `support freeze/thaw`
  there was no `->unfreeze_fs`; the resync was a `pm_notifier` on
  `PM_POST_HIBERNATION` and pointed `efivar_entry_size()`'s error at
  `size = 0` already, but it **did not run on S3** — it ran from
  `pm_notifier_call_chain` on the hibernation path only. v6.16 was released
  2025-07-27 with `support freeze/thaw` already in; so the S3-time resync has
  been in every stable kernel since 6.16, and any "it worked before" baseline
  must be a kernel older than that. Nothing between v6.16 and v7.3 removed the
  resync.
- Nothing between v6.16 and v7.3 changed the resync's inability to distinguish
  "absent" from "error"; `fix error propagation in efivar_entry_get()` fixed
  the *read* path, not the probe.

### (d.2) Is a false-positive removal a known complaint?

The properties that would make it one are all in the code: (i) probe errors
collapsed to zero, (ii) deletion logged at `pr_info`, (iii) recreate/remove
churn for views that disagree, (iv) a single probe with no retry, which is what
Bottomley's original series avoided by design (the patch was written for
"another OS changed NVRAM while we hibernated", not for "the firmware is slow
after resume"). Those are the exact points any upstream report or patch would
have to make. **What could not be done from this host:** a lore.kernel.org /
LKML full-text search — lore.kernel.org answered HTTP 403 to automated
requests from this worker and git.kernel.org's log endpoints work but carry no
mailing-list data. So this report does **not** claim "no upstream report
exists"; it claims the code-level gap is present in v7.3-rc7 and states where
it would be filed (linux-efi; `get_maintainer.pl fs/efivarfs/` →
Ard Biesheuvel, James Bottomley, the EFI list). A grep of `v7.3-rc7`'s
`fs/efivarfs/` and `drivers/firmware/efi/` found no readiness gate, retry, or
T2/Apple quirk, which is the actionable fact.

## Recommended action

**None in the image.** This job writes no kernel patch, and there is nothing
image-side that would be correct: our T2 kernel is stock v7.3-rc7 in the paths
involved (§a.6), and the resync is upstream behaviour that must stay for the
hibernation case.

**Operator guidance (documentation, not code):** right after S3 resume,
treat `ENOENT`/`0-byte` results from efivars as *unknown*, not as *absent*.
Retry after some seconds, after the next resume, or after a reboot; never let a
tool "repair" a boot entry, key enrollment or `gpu-power-prefs` from such a
read. If a tool must write, reading the variable first without this rule can
turn a transient view into a real change.

**If the next MEDUSA session proves it is deterministic** (same list every
resume, still absent at 30 s): file upstream on **linux-efi** with the kernel
version and the `journalctl -k` excerpt, and ask for (i) the status code in
the `removing variable` message and (ii) not deleting on a non-`EFI_NOT_FOUND`
error *or* a bounded retry. That is the patch this investigation justifies —
it is knowingly out of scope for this job.

**What not to do:** `filesystems_freeze=0` on the kernel command line does
suppress the resync (§a.1) but disables freeze/thaw for every filesystem
including the root FS — a data-integrity hazard in exchange for cosmetic log
noise. Do not ship it.

## Unproven / residual uncertainty

- **Which of the hypothesised firmware behaviours is true on MEDUSA** —
  transient post-resume `GetVariable()` failure, per-namespace disagreement
  between `GetVariable()` and `GetNextVariable()`, or genuine deletion. The
  kernel discards the evidence (§a.2 items 1 and 3); §(a.5) says how to
  collect it.
- **No upstream/mailing-list search was possible from this host** (lore 403).
  The absence of a known-report claim in §(d.2) is therefore a statement about
  the code, not about the mailing lists.
- **No MEDUSA hardware access:** all timing statements about T2 RT service
  readiness are inference from the log pattern and the shipped T2 patch set
  (§a.6), not measurement.
- **The `apple-bce`/`t2bce` driver is not in v7.3-rc7's tree** (`drivers/staging/`
  and `MAINTAINERS` have no `apple-bce`; the T2-BCE stack arrives as patch
  `1001-Add-t2bce-driver-stack.patch`). Whether its PM callbacks interact with
  RT readiness is unexamined — it does not call any EFI service.
