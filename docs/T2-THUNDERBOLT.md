# t2thunderbolt is not loaded by default

Decision (2026-10-05): the `t2thunderbolt` DKMS module is no longer built or loaded on T2 Macs.

## What the module is
Not a Thunderbolt driver. It is a power-management ordering quirk (KaiT2en, `modules/t2thunderbolt`): it adds device links between the Thunderbolt controller (NHI) and the T2 bridge (PCI `106b:1801`) so they suspend and resume in a safe order. The in-tree quirk covers other Apple controllers but not the Titan Ridge (`8086:15e8`, `8086:15eb`) and Ice Lake (`8086:8a0d`, `8086:8a17`) NHIs, which is what this module adds.

## What changes without it
- Thunderbolt itself still comes from the in-tree `thunderbolt` driver (docks, bolt, enumeration).
- What is not provided: the suspend/resume ordering between those NHIs and the T2 bridge. Whether its absence causes resume problems on a MacBookPro16,1 with a dock attached has not been exercised (kernel-log triage item 9); the test plan is in `docs/reports/`.

## How
- `post-install/56-t2-dkms.sh` builds `t2smc` and `t2gmux` only (and only on Apple T2 hardware). `t2smp` is dropped (in-kernel 9001 owns CPU offline, see `docs/T2-SMP.md`); `t2thunderbolt` is opt-in (this file).
- It writes `/etc/modprobe.d/ncz-t2thunderbolt.conf` (`blacklist` and `install ... /bin/false`) so the module cannot autoload even if it is left on disk, and removes a stale DKMS registration from an earlier install.
- Opt in: remove that file and install with `NCZ_T2_DKMS_EXTRA=t2thunderbolt`.
- The vendored source and PROVENANCE stay in `assets/kernel/t2thunderbolt/` so it can be re-enabled.
- `build/test-t2-dkms-hook.sh` covers default, idempotency, stale cleanup, opt-in, unknown names, non-Apple hardware, T2 DMI apple_gmux blacklist, rc-only kernel trees, multi-KVER builds, and missing-KVER fatal-on-T2 paths.

## See also
- `docs/T2-SMP.md` — why `t2smp` is dropped (kernel 9001 owns CPU offline).
- `docs/T2-GMUX.md` — why `apple_gmux` (in-kernel) is blacklisted on T2 hardware in favour of the DKMS `t2gmux`.
