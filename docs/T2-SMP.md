# t2smp is not loaded

Decision (2026-10-05, after an audit of the T2 patch set against 7.3): the `t2smp` DKMS module is no longer built or loaded on T2
hardware. In-kernel patch 9001 is the sole owner of Apple T2 CPU-hotplug
ordering on amd64.

## What the module is
A CPU-hotplug ordering helper (KaiT2en, `modules/t2smp`): it sets up a
CPU-hotplug notifier at priority 1 with the matching `CPUHP_OFFLINE` callback
at -1 so the T2 bridge PCI device (`106b:1801`) is offline/online in the
right order with respect to the rest of the system. Same code lives in
upstream Linux as `arch/x86/kernel/cpu.c`'s Apple T2 patches.

## Why drop it
The DKMS module is a byte-for-byte duplicate of in-kernel patch 9001
(`amd64-kernel-t2` carries it under `9010-cpu-offline-t2-bridge.patch`):

- same notifier priority 1 / callback -1
- same `106b:1801` PCI gate
- same uninitialised `offlined-cpu` mask defect under
  `CONFIG_CPUMASK_OFFSTACK=y` (confirmed on a MacBookPro16,1 with 7.2.9, both `t2smp` and
  9001 were present and `t2smp` was loaded)

In-kernel wins by branching; the rule is "in-kernel over DKMS only when
equivalent" and 9001 is strictly upstream. Two drivers claiming the same
piece of hardware cannot coexist — a real load-order race on a MacBookPro16,1
2026-09-29 produced the duplicated handler chain.

## What changes without it
- The T2 CPU-hotplug ordering still happens, but via in-kernel 9001.
- The vendored DKMS source and `PROVENANCE` stay under
  `assets/kernel/t2smp/` so the patch history is preserved for review and
  for an emergency revert (none is planned).
- `dkms status` on a T2 Mac no longer lists `t2smp/0.1, ...: installed`.

## How
- `post-install/56-t2-dkms.sh` builds `t2smc` and `t2gmux` only.
- It writes `/etc/modprobe.d/ncz-t2smp.conf` (`blacklist` and
  `install t2smp /bin/false`) so the module cannot autoload even if it is
  left on disk, removes a stale DKMS registration from an older install,
  and removes any stale `/usr/src/t2smp-*` source tree. The blacklist and
  removal run on every install, including idempotent re-runs.
- `build/test-t2-dkms-hook.sh` covers default, idempotency, stale
  registration removal, missing on-policy `ncz-t2smp.conf` going away,
  multi-KVER builds and missing-KVER fatal paths on T2 hardware.

## See also
- `docs/T2-THUNDERBOLT.md` — `t2thunderbolt` opt-out.
- `docs/T2-GMUX.md` — `apple_gmux` blacklist on T2 in favour of `t2gmux`.
- `assets/kernel/KERNEL-POLICY` — the amd64 stable/edge channel policy.
- `assets/kernel/t2smp/PROVENANCE` — pinned upstream commit.