# t2gmux owns APP000B on T2 hardware

Decision (2026-10-05, after an audit of the T2 patch set against 7.3): the in-kernel `apple_gmux` driver
is blacklisted on Apple T2 hardware. The DKMS `t2gmux` is the sole owner of
the APP000B function (dGPU mux power control). On non-T2 Macs and PCs the
in-kernel driver is untouched.

## What is bought
Two drivers cannot both claim the `APP000B` function on a T2 Mac:

- The in-kernel `apple_gmux` driver (added upstream as `drivers/platform/
  x86/apple-gmux.c`): supports pre-T2 Apple hardware only. On T2 it loads,
  binds, and never registers a handler for the T2 gmux — leaving the mux
  without an owner until something else (DKMS `t2gmux`, via a load-order
  race) takes over. On a MacBookPro16,1 the in-kernel driver was loaded but unbound;
  a real boot order flip would surface a duplicate handler.
- The DKMS `t2gmux` (KaiT2en, `modules/t2gmux`): supports the T2 gmux. Same
  class as t2smp vs in-kernel 9001, but with the opposite outcome — here the
  in-kernel driver is the inferior one for THIS fork (T2 hardware).

The rule is "one owner per piece of hardware, nothing we cannot test". The
held 9502 (`drivers/platform/x86/apple-gmux.c`) covers only
`MacBookPro15,1`; the T2 family (MacBookPro16,x etc.) is not in scope.

## What changes on T2
- `post-install/56-t2-dkms.sh` writes `/etc/modprobe.d/ncz-t2-gmux.conf`
  (`blacklist apple_gmux` and `install apple_gmux /bin/false`) so the
  in-kernel driver cannot autoload even if it is left on disk.
- The file is written ONLY when `ncz_is_t2_hardware` (DMI: Apple vendor AND
  known T2 product_name) returns 0. Detection is the same helper
  `assets/refind/ncz-refind-refresh-amd64.sh` uses for the rescue
  blacklist at entry generation — `assets/refind/ncz-t2-detect.sh`. One model list, no duplication
  (operator 2026-10-05).
- The blacklist file is NOT removed by a future non-T2 install — DMI does
  not change at runtime, so the only way to leave the blacklist is to
  physically move the drive to non-T2 hardware, which is not a supported
  scenario.

## What changes on non-T2 hardware
- Nothing. `ncz_is_t2_hardware` returns 1 on every pre-T2 Apple product
  (MacBookPro14,1 etc.), on every non-Apple machine, and on every VM, and
  the blacklist file is never written. The hook exits 0 silently on those.
- `build/test-t2-dkms-hook.sh` covers pre-T2 Mac, ASUS PC, QEMU fixtures
  explicitly (no `dms/ncz-t2-gmux.conf`).

## How
- `assets/refind/ncz-t2-detect.sh` provides `ncz_is_t2_hardware` /
  `ncz_t2_pci_bridge_present` / `ncz_t2_detect_detail`. The hook sources
  it via `NCZ_T2_DETECT` (default
  `/usr/local/lib/cix-installer/assets/refind/ncz-t2-detect.sh`).
- `build/test-t2-dkms-hook.sh` covers apple_gmux-on-T2 (file written),
  apple_gmux-on-pre-T2-Mac (file absent), apple_gmux-on-ASUS (hook
  inert), apple_gmux-on-QEMU (hook inert), and idempotent re-runs.

## See also
- `docs/T2-THUNDERBOLT.md` — `t2thunderbolt` opt-out.
- `docs/T2-SMP.md` — `t2smp` dropped in favour of in-kernel 9001.
- `assets/refind/ncz-t2-detect.sh` — DMI T2 detection (shared).
- `assets/kernel/t2gmux/PROVENANCE` — pinned upstream commit.