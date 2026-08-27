# Kernel build and install runbook

This is the repeatable path for producing, packaging, gating, and installing
the NCZ CIX Sky1 kernel. It exists because the `7.2.0-sky1-ncz+r252` O6N
upgrade proved that a kernel package revision can change while the kernel
release string stays exactly `7.2.0-sky1-ncz`. DKMS keys its rebuild state by
that release string, so an upgrade that does not force a rebuild can leave GPU,
VPU, and NPU modules built against the previous kernel's `Module.symvers`.

The immediate r252 incident was not a kernel bug. `linux-headers-cixmini`
already carried the `OTA-DKMS-HEADER-FIX-2026-08-21` postinst sequence that
runs `dkms autoinstall -k "$KVER"` on every install, but the postinst tested:

```sh
if command -v dkms >/dev/null 2>&1; then
```

On the board, `dkms` existed at `/usr/sbin/dkms`, but the invoking PATH did not
include sbin directories:

```text
/usr/local/bin:/usr/bin:/bin:/usr/games
```

That made `command -v dkms` fail inside the maintainer script. The proof was
`/var/log/ncz-dkms-autoinstall.log`: it existed but was exactly 0 bytes. The
postinst only appends to that file after entering the `dkms autoinstall` branch,
so a zero-length file means the autoinstall block was skipped, not that DKMS ran
and failed later.

The live recovery that proved the diagnosis was:

```bash
sudo dkms remove  -m aipu -v 6.2.0 -k "$(uname -r)" || true
sudo dkms install -m aipu -v 6.2.0 -k "$(uname -r)" --force
sudo dkms remove  -m cix-gpu-kmd -v 1.0 -k "$(uname -r)" || true
sudo dkms install -m cix-gpu-kmd -v 1.0 -k "$(uname -r)" --force
sudo dkms remove  -m cix-vpu-driver -v 1.0.2-ncz1 -k "$(uname -r)" || true
sudo dkms install -m cix-vpu-driver -v 1.0.2-ncz1 -k "$(uname -r)" --force
sudo dkms remove  -m panthor-cix -v 7.2.0 -k "$(uname -r)" || true
sudo dkms install -m panthor-cix -v 7.2.0 -k "$(uname -r)" --force
sudo modprobe mali_kbase
systemctl status ncz-gpu-switcher.service --no-pager
```

After that, `modprobe mali_kbase` succeeded, dmesg reported
`mali CIXH5000:00: Probed as mali0`, and `ncz-gpu-switcher.service` changed
from failed to active/exited-success.

## Procedure

1. Verify the source identity before building.

   Follow item 0 in [KERNEL-BUILD-YOCTO.md](KERNEL-BUILD-YOCTO.md): compare the
   recipe `SRCREV` and intended tag against the real upstream kernel mirror, not
   a local memory of what the tag "should" be. The current shipping recipe is
   `linux-cix-sky1-ncz_7.2.bb` in `meta-cix`.

2. Confirm the Yocto build tree is clean.

   On ARGOS:

   ```bash
   cd ~/yocto-docker/meta-cix
   git status --short
   ```

   Do not build release artifacts from an unexplained dirty `meta-cix` tree.

3. Rebuild the kernel and run the established kernel gates.

   Use Yocto only:

   ```bash
   cd ~/yocto-docker
   source poky/oe-init-build-env build-cix-ncz71
   bitbake -c cleansstate linux-cix-sky1-ncz
   bitbake linux-cix-sky1-ncz
   ```

   Gate the result before promoting it:

   ```bash
   cd ~/cix-installer
   build/port-series.sh v7.2 ~/linux-72
   build/dkms-abi-gate.sh assets/kernel/edge/Image-cixmini.bin \
       /path/to/staged/headers \
       --config assets/kernel/edge/config-7.2.0-sky1-ncz
   build/kvm-kernel-gate.sh assets/kernel/edge/Image-cixmini.bin \
       assets/kernel/edge/config-7.2.0-sky1-ncz
   grep -q '^CONFIG_MODVERSIONS=y' assets/kernel/edge/config-7.2.0-sky1-ncz
   ```

   Keep real rebuild proof: compare the new kernel artifact checksum against the
   previous staged checksum. A release rebuild must produce explainable checksum
   movement, not a stale copy of the previous Image.

4. Promote the gated build to local kernel assets and regenerate manifests.

   `assets/kernel/edge/` is gitignored local staging, but the checksums are
   committed. After copying `Image-cixmini.bin`, `modules-cixmini.tgz`,
   `headers-cixmini.tar.zst`, `KVER`, and `config-$KVER`, regenerate both
   manifests:

   ```bash
   cd ~/cix-installer
   find assets/kernel/edge -maxdepth 1 -type f -printf '%p|%s|' \
       -exec sha256sum {} \; | sort
   python3 build/kernel-manifest.py gen
   python3 build/kernel-manifest.py check
   ```

   Also refresh the relevant `assets/kernel/edge/*` rows in
   `sbom/expected-assets.txt` with the new size and sha256. This is easy to
   forget: during the r252 session, `kernel-manifest.py check` failed once with
   a real sha256 drift until `assets/kernel-manifest.json` was regenerated.

5. Build the kernel debs with a freshly bumped package revision.

   `build/build-kernel-debs.sh` defaults `BUILD_REV` to the next release
   revision. Never repeat or decrease it: the Debian `+rNNN` revision is the
   only package-level distinction when the kernel release string remains
   `7.2.0-sky1-ncz`.

   ```bash
   cd ~/cix-installer
   STRICT_MANIFEST=1 bash build/build-kernel-debs.sh
   ```

   For the r252 incident fix, no Yocto rebuild is required. Rebuild only the
   `.deb` packages from the already-built r252 kernel assets with a higher
   `BUILD_REV`, because the changed payload is the
   `linux-headers-cixmini` postinst.

6. Run the DKMS-load verification gate before installing on real hardware.

   The static SBOM piece is part of normal preflight:

   ```bash
   bash build/verify-dkms-modules.sh
   ```

   The loadability gate must run in the target environment after the candidate
   kernel and headers debs are installed, but before declaring the upgrade safe:

   ```bash
   sudo build/verify-dkms-modules.sh --kver "$(uname -r)" --live-load
   ```

   Static and dry-run checks prove the expected registrations, module paths, and
   vermagic. `--live-load` is intentionally explicit because it really inserts
   modules. It is the part that catches the exact r252 failure class:
   `CONFIG_MODVERSIONS=y` rejects stale modules with messages like
   `disagrees about version of symbol` and `Unknown symbol ... (err -22)`, which
   a plain `modprobe -n` cannot surface.

   This is separate from `build/dkms-abi-gate.sh` by design. `dkms-abi-gate.sh`
   proves the staged headers and kernel image came from the same build. This
   gate proves the registered DKMS outputs for a target KVER are actually the
   modules the kernel can load.

7. Install the debs and perform immediate target checks.

   Use `dpkg -i`, never `tar -C /`:

   ```bash
   sudo dpkg -i build/kernel-debs/cixmini-boot_*_arm64.deb \
       build/kernel-debs/linux-image-cixmini_*_arm64.deb \
       build/kernel-debs/linux-headers-cixmini_*_arm64.deb
   ```

   Then check the running KVER:

   ```bash
   uname -r
   dkms status
   modprobe memory_group_manager
   modprobe protected_memory_allocator
   modprobe mali_kbase
   modprobe panthor
   modprobe amvx
   modprobe aipu
   systemctl --failed
   systemctl is-active ncz-gpu-switcher.service
   ```

   Every DKMS package in `sbom/expected-dkms-modules.txt` must show built or
   installed for the current KVER. `systemctl --failed` must be empty, and
   `ncz-gpu-switcher.service` must be active.

8. Boot-test on O6N only, human supervised.

   Follow the O6N-only rule in [KERNEL-BUILD-YOCTO.md](KERNEL-BUILD-YOCTO.md)
   and the current kernel-build checklist. Do not use `.66` for this boot test.
   Do not leave an unverified graphical default entry on real hardware.
