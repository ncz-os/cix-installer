# Bootloader handoff investigation, 2026-09-27

Status: BLOCKED on access to the decisive arm64 artifact. The observed defect
is an installed arm64 system that falls through to the EFI shell; its causal
code defect is UNKNOWN. This is an evidence report, not a completed causal
attribution. No boot-path fix is included.

All repository line citations below refer to main@42dd3a6
(42dd3a63308bcf07d5f4570d76c4829ab2508d61). Investigation branch:
`wip/proteus/bootloader-rootcause-2026-09-27`, based on that commit. The first
tool call read `post-install/run-all.sh` and `post-install/70-bootloader.sh`.

## Answers in investigation order

1. **Did hook 70 execute on arm64? UNKNOWN.** It is neither a REQUIRED_HOOKS
   member nor an optional hook. It has a dedicated, explicit EXIT-trap path.
   Absence from the required list is not an orphan defect in this case.
   `run-all.sh:168-190` defines required hooks; `:209-210` excludes 70 from
   optional hooks; `:322-324` deliberately exempts it from the orphan audit.
   `:413-420` invokes it when present after the required-failure skip branch;
   `:421` captures its pipeline status, `:459-462` propagates failure, and
   `:484` installs the trap. Missing hook files can still bypass that branch:
   `:413` tests existence, with no corresponding missing-file failure. That
   is a shared latent gap, not evidence that it happened on arm64.
2. **What is on the installed arm64 ESP? UNKNOWN.** The actual
   `/home/jasonperlow/kvm-arm64-gate2/target.qcow2` could not be read because
   TYDEUS rejected SSH authentication (commands and output below). Neither an
   empty ESP nor an absent `BOOTAA64.EFI` has been established by this
   investigation. An EFI-shell fallthrough is not a filesystem listing.
3. **Is the arm64 rEFInd binary on the actual medium? UNKNOWN.** The current
   raw-GPT builder explicitly requires it and stages the same asset tree for
   both architectures, as detailed below. Source intent is not verification
   of the particular installed medium.
4. **Does amd64 share the failure, or just depend on NVRAM?** The completed
   cbc831a disk has a real `EFI/BOOT/BOOTX64.EFI`, valid x86-64 EFI format,
   configuration, kernels and initrds on its actual ESP. Thus it does not
   have the hypothesized missing-fallback-file defect. Its recorded boot
   uses an NVRAM entry pointing at that same fallback file. An empty-NVRAM
   boot was not performed, so firmware discovery with empty variables
   remains UNKNOWN. Whether it shares the as-yet-unidentified arm64 cause
   is also UNKNOWN. The main@42dd3a6 amd64 run already reached login during
   this investigation; its gate process was still running when sampled.

## Supplied observation (accepted, not re-derived)

The operator measured main@42dd3a6 on TYDEUS using real KVM, `cpu=host`:
phase 1 ran 16:43:22Z to 16:52:27Z, QEMU rc=0, without a failed hook.
Phase 2 returned rc=124 and no kernel banner. The supplied boot.log excerpt
enumerates all three target GPT partitions and starts Boot0002,
`EFI Internal Shell`, ending at `Shell>`. The supplied install.log counts
are partman=7, base-system-install=1, finish-install=1, kernel=6,
refind=0 and grub=0. Phase 1 is accepted as a genuine pass.

Those facts establish the reported phase-2 failure, but do not distinguish
an absent loader from an unusable loader or a firmware discovery problem.
In particular, zero serial-log matches do not establish non-execution:
the passing amd64 control has the same zero counts.

## Why the serial log cannot settle hook execution

`preseed/late.sh:25-27` redirects stdout and stderr to
`/target/var/log/cix-installer-late.log`. The chroot invocation is at
`:793` (fallback `:804`). `run-all.sh:419-420` additionally tees hook 70's
output to `/var/log/cix-install/70-bootloader.log` inside that target.
These are the decisive logs, not a substring count in serial output.

Actual command on HYDRA:

```sh
for s in refind grub 70-bootloader; do
    printf '%s ' "$s"
    grep -ac "$s" ~/kvm-amd64-complete/install.log
done
```

Actual output:

```text
refind 0
grub 0
70-bootloader 0
```

Nevertheless, the completed amd64 ESP's `ncz-debug.txt` contains:

```text
TRAP ORIGINAL_RC=0 REQUIRED_PHASE_OK=1
TRAP 70bl=YES
```

This diagnostic is written by `run-all.sh:399-401`. The generated
`refind.conf` also identifies `2026.09.27-cbc831a` and
`ncz-refind-refresh-amd64`. These disk artifacts contradict the inference
that absent serial matches imply the bootloader was never invoked.

## Actual amd64 ESP inspection

Read-only extraction from the completed run, executed through
`ssh jasonperlow@192.168.207.78`; only new files in
`/tmp/bootloader-rootcause/` were written. No source disk was mounted or
modified:

```sh
mkdir -p /tmp/bootloader-rootcause
qemu-img dd -f qcow2 -O raw \
  if=/home/jasonperlow/kvm-amd64-complete/target.qcow2 \
  of=/tmp/bootloader-rootcause/amd64-esp.raw \
  bs=512 skip=2048 count=3997696
mdir -i /tmp/bootloader-rootcause/amd64-esp.raw ::/EFI/BOOT
mdir -i /tmp/bootloader-rootcause/amd64-esp.raw ::/
mtype -i /tmp/bootloader-rootcause/amd64-esp.raw ::/ncz-debug.txt
mtype -i /tmp/bootloader-rootcause/amd64-esp.raw ::/EFI/BOOT/refind.conf
mcopy -i /tmp/bootloader-rootcause/amd64-esp.raw \
  ::/EFI/BOOT/BOOTX64.EFI /tmp/bootloader-rootcause/BOOTX64.EFI
file /tmp/bootloader-rootcause/BOOTX64.EFI
sha256sum /tmp/bootloader-rootcause/BOOTX64.EFI
```

The GPT header was separately extracted with `qemu-img dd`, `bs=512 count=34`,
and decoded with Python `struct.unpack_from('<QQ', entry, 32)` and
`uuid.UUID(bytes_le=entry[:16])`. Actual results:

```text
GPT signature: b'EFI PART'
partition 1 type c12a7328-f81f-11d2-ba4b-00a0c93ec93b
partition 1 UUID 9ad45a01-8b40-4524-9b31-387cbd989ced
partition 1 start,end (2048, 3999743)
partition 3 UUID b24f5333-5c10-4c62-b4f4-eb3f5d4677fe
```

This confirms the extraction covers partition 1, not the install medium.
Actual filesystem listing, with mtools short names expanded from its
long-name column:

```text
EFI/BOOT/BOOTX64.EFI                 313856 bytes
EFI/BOOT/ncz-banner.png             3675825 bytes
EFI/BOOT/ncz.png                     12920 bytes
EFI/BOOT/icons/                      directory
EFI/BOOT/refind.conf                   1895 bytes
EFI/BOOT/vars/                       directory
/vmlinuz-7.2.7-2-t2-trixie          14123520 bytes
/initrd.img-7.2.7-2-t2-trixie       72843086 bytes
/vmlinuz-7.3.0-rc4-3-t2-trixie-xhcifix    13136384 bytes
/initrd.img-7.3.0-rc4-3-t2-trixie-xhcifix 64250437 bytes
```

`file` reported `PE32+ executable for EFI (application), x86-64 (stripped
to external PDB), 8 sections`. Loader SHA-256:
`3a3f5bf7dc8cddae937a743a214713e98219bfb3221e6700e828e92729c74982`.
Extracted ESP SHA-256:
`cb2b80251ecf2a3d9868cb2511d4437673be7f7b3bc8e5ebfc4d513d033ed986`.

The actual configuration has `scanfor manual`, `use_nvram false`, a stable
entry loading `/vmlinuz-7.2.7-2-t2-trixie`, its matching initrd, and
`root=PARTUUID=b24f5333-5c10-4c62-b4f4-eb3f5d4677fe`, matching partition 3.
`use_nvram false` is rEFInd configuration; it does not prove firmware
fallback discovery was exercised.

## New amd64 main observation

`ssh jasonperlow@192.168.207.78 'cat ~/kvm-amd64-main/boot-serial0.log'`
returned these relevant lines (terminal control sequences omitted):

```text
BdsDxe: starting Boot0004 "nclawzero (rEFInd)" from HD(1,GPT,7AB955D6-98AA-4199-9C1F-798E7C4C53D0,0x800,0x3D0000)/\EFI\BOOT\BOOTX64.EFI
Starting vmlinuz-7.2.7-2-t2-trixie
Build: 2026.09.27-42dd3a6  (2026-09-27T17:13:47Z)
ncz-123456 login:
```

At 17:22:26 UTC, `boot.log` was still zero bytes and the QEMU process was
still running under `timeout 600`, with `-accel kvm -cpu host`. The gate
appends the serial file after QEMU exits (`build/kvm-install-gate-gpt.sh:278-280`).
This is direct evidence of handoff and login on main, not a claimed final
gate exit status. Its live disk was not extracted while QEMU was writing it.

## Asset staging and runtime comparison

The raw-GPT path `build/iso/write-usb-image.py:348-363` selects required
assets by architecture: amd64 requires `refind_x64.efi`, its refresh script
and kernel postinst hook; arm64 requires `refind_aa64.efi` and its refresh
script. Missing inputs raise an error; the complete refind tree is copied
into `ncz-payload/assets/refind`. `preseed/late.sh:218-242` refreshes scripts
and starts union-syncing assets into the installed metadata tree.
This is symmetric binary staging, not an arm64 omission in the source.

The older ISO builder also stages arm64 explicitly:
`build/build-iso-di.sh:3392-3401` uses `build/refind-bin/refind_aa64.efi`,
falling back to the tracked asset. Its missing-binary path only warns
(`:3438-3439`), unlike the raw-GPT writer's fatal check. This does not prove
which files exist on the measured arm64 medium.

`post-install/70-bootloader.sh:160-163` dispatches by dpkg architecture.
The arm64 path installs and invokes `ncz-refind-refresh` (`:87-103`);
amd64 installs and invokes its corresponding script (`:128-157`).
The arm64 refresh rejects a missing binary (`assets/refind/ncz-refind-refresh.sh:113-116`)
and an absent or non-vfat ESP mount (`:121-133`). It writes and verifies
`/boot/efi/EFI/BOOT/BOOTAA64.EFI` (`:595-600`). The amd64 counterpart writes
and verifies `BOOTX64.EFI` (`assets/refind/ncz-refind-refresh-amd64.sh:340-345`).
Both separately attempt best-effort NVRAM registration (arm64 `:895-908`,
amd64 `:536-545`). An NVRAM entry is additional to the fallback file.

## Introduced versus newly observable

UNKNOWN for the unidentified arm64 cause. The accepted chronology makes
this failure newly observable after the install-stall repairs; it does not
date its introduction. This exact repository-root command returned no diff:

```sh
git -C "$(git rev-parse --show-toplevel)" diff cbc831a 42dd3a6 -- \
  post-install/run-all.sh post-install/70-bootloader.sh assets/refind \
  build/iso/write-usb-image.py
```

The four commits changed initrd patching, debootstrap patching, tests and
preseed early-command ordering (`git -C "$(git rev-parse --show-toplevel)"
diff cbc831a 42dd3a6 --stat`). That rules out a direct edit to these bootloader
files, not an indirect runtime effect. No revert is proposed.

## Access blocker and decisive next evidence

Actual attempt from PROTEUS:

```sh
ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
  -o ConnectTimeout=10 jasonperlow@192.168.207.73 hostname
```

Result: `jasonperlow@192.168.207.73: Permission denied (publickey,password).`
The same attempt through HYDRA also failed authentication. HYDRA itself is
accessible, but `sudo -n true` returns
`sudo: interactive authentication is required`. The available identity and
fleet credential location were requested from the operator; neither was
available during this investigation. No sudo was needed for the completed
amd64 read-only extraction.

Once TYDEUS access is restored, inspect the stopped target disk read-only:
decode its GPT, extract partition 1, recursively list `/EFI`, check
`BOOTAA64.EFI` size, PE machine type and hash, and read `ncz-debug.txt`.
Then read the installed root's `var/log/cix-install/70-bootloader.log`,
`progress.tsv`, `var/log/cix-installer-late.log`, and the retained
`usr/local/lib/cix-installer/post-install/70-bootloader.sh`. These separate
non-execution, a missing hook file, a reported failure, and a wrong write
destination. An empty ESP alone cannot distinguish all of those cases.

Inspect the actual medium's `ncz-payload/assets/refind/refind_aa64.efi`
and the installed metadata asset at
`usr/local/lib/cix-installer/assets/refind/refind_aa64.efi`; compare hashes
and validate architecture. If the correct fallback loader is already
present, investigate firmware discovery/load rejection before blaming the
hook. Finally test disposable disk copies with fresh firmware variables,
running gates as root with verified KVM, to settle empty-NVRAM behavior on
both architectures. No such new gate or boot-path fix was run or landed.
