# Stability Sweep 3 - Build Pipeline - 2026-05-08

## Executive summary

- Verdict: high-severity build pipeline gaps were present in the d-i ISO repacker, mirror builder, and top-level Makefile.
- Patched in-place: 5 HIGH fixes across `build/build-iso-di.sh`, `build/build-mirror.sh`, and `Makefile`; no commit made.
- Counts: HIGH 5, MEDIUM 8, LOW 6.
- Could not run two full bakes locally: this checkout has no `downloads/`, no kernel/rootfs assets, no mirror tree, and no local `xorriso`.
- Highest remaining risk after patches: reproducible SHA is still not guaranteed because timestamps, Release dates, host stamps, and ISO filesystem dates are not all controlled.

## HIGH findings

### H1 - Netinstall size validator accepted malformed stat output

File: `build/build-iso-di.sh:122`, `build/build-iso-di.sh:1450`

Root cause: the validator previously used `stat -f %z "$OUTPUT" || stat -c %s "$OUTPUT" || echo 0`. On Linux, `stat -f` is filesystem stat mode, not file-size mode. If it exits zero with non-size output, the `stat -c` fallback never runs and `[ "$ISO_SIZE_BYTES" -le 0 ]` receives malformed text.

Concrete diff applied:

- Added `file_size_bytes()` at `build/build-iso-di.sh:122`.
- Prefer GNU `stat -c %s`, then BSD `stat -f %z`, then `wc -c`.
- Reject any empty or non-digit output before integer comparisons.
- Replaced the old chained fallback with `ISO_SIZE_BYTES=$(file_size_bytes "$OUTPUT") || exit 1` at `build/build-iso-di.sh:1451`.

Why HIGH: this is the exact bug class from the take16 bake. It let the script continue far enough to print `OUTPUT:` but failed late with a shell integer diagnostic instead of a controlled build error.

### H2 - d-i build dependency gate omitted tools used later

File: `build/build-iso-di.sh:116`

Root cause: the early dependency check only covered `xorriso 7z cpio gzip find depmod dd ar`, but the script later calls `apt-ftparchive`, `dpkg-scanpackages`, `python3`, `tar`, `gunzip`, `md5sum`, `xargs`, `awk`, `sed`, `sort`, and others.

Concrete diff applied:

- Expanded the tool gate at `build/build-iso-di.sh:116` through `build/build-iso-di.sh:119`.
- The build now fails before ISO staging if required host tools are missing.

Why HIGH: missing `apt-ftparchive`, `dpkg-scanpackages`, or `python3` previously failed after expensive staging and udeb mutation work, which is exactly the class of late pipeline failure this sweep is meant to remove.

### H3 - `md5sum.txt` generation was allowed to fail silently

File: `build/build-iso-di.sh:1415`

Root cause: the d-i repacker used `... > md5sum.txt 2>/dev/null || true`, masking missing `md5sum`, `xargs`, traversal errors, or an empty checksum file.

Concrete diff applied:

- Removed `|| true` from the checksum generation path at `build/build-iso-di.sh:1416`.
- Added a non-empty file assertion at `build/build-iso-di.sh:1417`.

Why HIGH: a final ISO with stale or empty checksum metadata is a silent artifact integrity regression. It also hid missing-tool failures from the same class as H2.

### H4 - Mirror builder produced incomplete mirrors after package failures

File: `build/build-mirror.sh:226`, `build/build-mirror.sh:255`

Root cause: after a bulk `apt-get install -d` failure, the fallback loop printed `skip: $pkg` and continued. The base-set `--reinstall` pull also downgraded errors to a warning. That can produce a mirror that indexes cleanly but lacks required packages.

Concrete diff applied:

- Added a host and chroot dependency gate at `build/build-mirror.sh:23`.
- Changed the per-package fallback to collect failures and exit non-zero at `build/build-mirror.sh:232` through `build/build-mirror.sh:246`.
- Changed base-set `--reinstall` failure from warning to hard error at `build/build-mirror.sh:258` through `build/build-mirror.sh:262`.

Why HIGH: an incomplete embedded mirror can pass ISO assembly and fail only during install, causing the exact repeated install-failure loop the operator is trying to eliminate.

### H5 - Makefile still invoked the obsolete casper repacker

File: `Makefile:67`, `Makefile:80`

Root cause: `make iso` downloaded a Debian netinst ISO but invoked `build/build-iso.sh`, whose own header says it expects an Ubuntu Server live ISO with `/casper/`. That path would fail the layout check in `build/build-iso.sh:262` or build the wrong pipeline if inputs changed.

Concrete diff applied:

- Added `MODE ?= full` and `VARIANT ?= desktop` at `Makefile:14`.
- Made non-full output names mode-specific at `Makefile:33`.
- Switched the recipe to `build/build-iso-di.sh --bookworm-iso ... --mode $(MODE) --variant $(VARIANT)` at `Makefile:80`.
- Updated dependencies to include the d-i build script and the preseed scripts it stages at `Makefile:67` through `Makefile:78`.
- Updated `clean` to remove `build/iso-staging-di` at `Makefile:102`.

Why HIGH: the default orchestrator was pointed at the wrong build pipeline. Any operator using `make iso` could waste a bake on the dead casper path.

## MEDIUM findings

### M1 - Reproducible SHA is not currently achievable

File: `Makefile:13`, `build/build-iso-di.sh:170`, `build/build-iso-di.sh:1434`

Root cause: `VERSION` defaults to current date, `BUILD_DATE` uses wall-clock time, `BUILD_HOST` embeds the local hostname, apt Release files include generated dates, and the xorriso invocation does not normalize ISO timestamps. The newly written files under staging also inherit current mtimes.

Concrete diff recommended:

- Add a shared `SOURCE_DATE_EPOCH` date helper for `BUILD_DATE`.
- Use deterministic `BUILD_HOST` when `SOURCE_DATE_EPOCH` is set, or allow `BUILD_HOST_OVERRIDE`.
- Normalize staging mtimes before xorriso when `SOURCE_DATE_EPOCH` is set.
- Set xorriso volume dates and apt-ftparchive Release Date from the same epoch.

Verification: two consecutive ARGOS bakes with the same `SOURCE_DATE_EPOCH`, inputs, and output paths should produce identical SHA256.

### M2 - Build version is not embedded in all requested places

File: `build/build-iso-di.sh:956`, `build/build-iso-di.sh:1291`, `build/build-iso-di.sh:1346`, `preseed/late.sh:88`

Root cause: the build version is present in `/cixmini/BUILD_VERSION` and the GRUB banner, and `late.sh` copies sidecars into the target. `.disk/info` only says Netinstall/Thin/Offline and does not include `$VERSION`. No scoped build script modifies target `/etc/os-release`.

Concrete diff recommended:

- Include `$VERSION` and `$MODE` in `.disk/info`.
- Add a post-install or late-stage owned by the relevant audit to write `/etc/os-release` fields such as `BUILD_ID` or `VERSION_ID` without editing `preseed/*` in this sweep.

### M3 - Full/thin modes still degrade to LTS-only when NEXT assets are absent

File: `build/build-iso-di.sh:384`, `build/build-iso-di.sh:1269`

Root cause: NEXT assets are required only when the installer kernel flavor is `next` or mode is `netinstall`. In `full` and `thin`, `STAGE_NEXT_KERNEL=1` but missing NEXT assets only produce `NEXT kernel: not present - installer will ship LTS only`.

Concrete diff recommended:

- If the full/thin contract is "LTS plus NEXT", fail when `STAGE_NEXT_KERNEL=1` and any NEXT asset is missing.
- If LTS-only full/thin remains allowed, update comments and release notes to say NEXT is optional outside netinstall.

### M4 - `build/build-iso.sh` is legacy code but still executable

File: `build/build-iso.sh:1`, `build/build-iso.sh:52`, `build/build-iso.sh:569`

Root cause: the script is the old Ubuntu Server live-ISO/casper path. The Makefile no longer calls it after H5, but the script remains executable and its dependency gate omits tools it later uses (`mkfs.vfat`, `mcopy`, `mmd`, `mdir`, `md5sum`, `xargs`, `tar`, `awk`, `sed`).

Concrete diff recommended:

- Either move it to a clearly named legacy path and remove from normal docs, or add a hard "deprecated/manual only" banner.
- If retained, expand the tool gate and add the same checksum non-empty assertion used in H3.

### M5 - `build/70-bootloader.sh` diverges from authoritative `post-install/70-bootloader.sh`

File: `build/70-bootloader.sh:1`, `post-install/70-bootloader.sh:1`, `post-install/run-all.sh:47`

Root cause: `post-install/run-all.sh` invokes `/usr/local/lib/cix-installer/post-install/70-bootloader.sh`. The copy under `build/` is not referenced by build scripts and is stale: it requires `KVER_LTS`, defaults to LTS, and lacks NEXT boot-counting and initrd staging present in `post-install/70-bootloader.sh`.

Concrete diff recommended:

- Remove `build/70-bootloader.sh` if unused, or replace it with a tiny wrapper/comment that points to `post-install/70-bootloader.sh`.
- Do not edit `post-install/*` in this sweep.

### M6 - cdebconf palette patch handles unknown pointer, but not short binaries

File: `build/build-iso-di.sh:1080`, `build/build-iso-di.sh:1107`

Root cause: trixie explicitly copies an unmodified `newt.so` to the overlay path, and the unknown pointer case writes an unmodified copy before exiting zero. However, `struct.unpack_from` can still raise if a future `newt.so` is shorter than `PALETTE_OFFSET + 8`.

Concrete diff recommended:

- Before unpacking, check `len(data) >= PALETTE_OFFSET + 8`; on failure, warn and copy unmodified `newt.so` to the overlay path.

### M7 - Branding generator is Python 3 compatible, but not deterministic or atomic

File: `build/gen-branding-assets.py:116`, `build/gen-branding-assets.py:154`, `build/gen-branding-assets.py:197`, `build/gen-branding-assets.py:289`

Root cause: `python3 -m py_compile` passes under the local Python 3, and the code is ordinary Python 3. It calls nondeterministic external image APIs without seeds and overwrites candidate PNG files directly via `Path.write_bytes`.

Concrete diff recommended:

- Write to `path.with_suffix(path.suffix + ".tmp")`, then `replace()`.
- Add a run manifest containing prompts, model names, response metadata, and hashes.
- Do not claim same input produces same PNG unless providers expose and honor deterministic seeds.

### M8 - QEMU smoke test lacks an early tool dependency check

File: `build/qemu-test.sh:31`, `build/qemu-test.sh:42`

Root cause: the script checks firmware paths but not `qemu-img`, `qemu-system-aarch64`, or `truncate` before it starts mutating sidecar disk/varstore files.

Concrete diff recommended:

- Add `for t in qemu-img qemu-system-aarch64 truncate; do command -v "$t" ...; done` near `build/qemu-test.sh:15`.

## LOW findings + recommendations

- Heredocs: no terminator collision found. Quoted heredocs are used for literal embedded shell/Python where needed; unquoted `GRUB`, `REFINDCONF`, and apt Release heredocs intentionally expand build variables.
- Codename auto-detect: the multi-codename guard is present at `build/build-iso-di.sh:450`, and the override refuses missing dist directories at `build/build-iso-di.sh:438` through `build/build-iso-di.sh:445`.
- Trixie graft skip: the trixie substrate path skips the bookworm-on-trixie graft at `build/build-iso-di.sh:532`, then the common assertion verifies debootstrap/zstd/lzma udebs at `build/build-iso-di.sh:548` through `build/build-iso-di.sh:592`.
- Netinstall mode coherence: `EMBED_MIRROR=0` writes empty regular Packages for Release consistency at `build/build-iso-di.sh:889` through `build/build-iso-di.sh:908`, and removes `.disk/base_installable` at `build/build-iso-di.sh:949` through `build/build-iso-di.sh:954`.
- Cleanup: `build/build-iso-di.sh` removes its staging dir at start, and `Makefile:102` now removes both old and d-i staging dirs.
- `extract-kernel-headers.sh` uses temp output plus rename at `build/extract-kernel-headers.sh:129` through `build/extract-kernel-headers.sh:134`; determinism of tar member order is still not guaranteed.

## Test plan

1. Static validation after patches:

```sh
bash -n build/build-iso-di.sh build/build-mirror.sh build/build-iso.sh build/extract-kernel-headers.sh build/qemu-test.sh build/70-bootloader.sh
shellcheck -S warning build/build-iso-di.sh build/build-mirror.sh
python3 -m py_compile build/gen-branding-assets.py
make -n iso MODE=netinstall VARIANT=server
make -n verify MODE=netinstall
```

2. Build take20-test netinstall on ARGOS:

```sh
export SOURCE_DATE_EPOCH=1778198400
make clean
make iso MODE=netinstall VARIANT=desktop VERSION=take20-test
```

Expected shape:

- Log contains no `integer expression expected`.
- Log contains `netinstall size OK: N bytes (<500 MB)`.
- `make -n iso MODE=netinstall` shows `build/build-iso-di.sh`, not `build/build-iso.sh`.
- Output path is `build/nclawzero-installer-cixmini-take20-test-netinstall.iso`.

3. Inspect ISO metadata:

```sh
ISO=build/nclawzero-installer-cixmini-take20-test-netinstall.iso
7z x -so "$ISO" cixmini/BUILD_MODE
7z x -so "$ISO" cixmini/BUILD_VERSION
7z x -so "$ISO" .disk/info
7z x -so "$ISO" boot/grub/grub.cfg | grep -E 'take20-test|kernel:|Mode:'
7z l "$ISO" | grep -E 'dists/questing/main/debian-installer/binary-arm64/Packages.gz|cixmini/post-install/70-bootloader.sh'
```

4. Verify H1 directly on Linux:

```sh
ISO=build/nclawzero-installer-cixmini-take20-test-netinstall.iso
stat -c %s "$ISO"
stat -f %z "$ISO" || true
```

Expected: the script used the GNU `stat -c %s` path and did not consume GNU `stat -f` filesystem output.

5. Mirror hard-fail regression test:

```sh
cp build/build-mirror.sh /tmp/build-mirror-test.sh
# In the copy only, add a guaranteed bogus package to PKGS, then run against a disposable chroot.
# Expected: script exits non-zero and prints "refusing to build incomplete mirror".
```

6. Determinism check on ARGOS after M1 is fixed:

```sh
export SOURCE_DATE_EPOCH=1778198400
make clean && make iso MODE=netinstall VERSION=take20-test-a
sha256sum build/nclawzero-installer-cixmini-take20-test-a-netinstall.iso
make clean && make iso MODE=netinstall VERSION=take20-test-a
sha256sum build/nclawzero-installer-cixmini-take20-test-a-netinstall.iso
```

Expected after M1 follow-up: identical SHA256. Expected today: likely different SHA256 due uncontrolled timestamps and Release dates.

