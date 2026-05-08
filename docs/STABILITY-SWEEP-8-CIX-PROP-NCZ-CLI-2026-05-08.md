# Stability Sweep 8 - Cix Proprietary and ncz CLI - 2026-05-08

## Executive summary

- Verdict: two HIGH gaps were present in this component: the CIX apt signing key was accepted without a pinned fingerprint, and the proprietary deb hook did not cleanly skip the absent/empty `assets/cix-debs` netinstall case.
- Patched in-place: 2 HIGH fixes across `post-install/25-cix-ppa.sh` and `post-install/25-cix-proprietary.sh`; no commit made.
- Counts: HIGH 2, MEDIUM 7, LOW 4.
- PPA scope: the scoped code adds only the CIX official apt repo at `archive.cixtech.com`; it does not add a Sky1-Linux apt source. The Mesa hook only writes apt preferences for `*sky1*` versions.
- `cix-noe-umd` ownership is now clear: package install plus Python 3.13 postinst recovery is owned by `25-cix-ppa.sh`; `25-cix-proprietary.sh` explicitly filters it out; `80-npu.sh` owns the kernel module/SSDT path only, though its installed doc still contains stale manual userspace instructions.
- `ncz` routing, help, non-root status paths, root-required checks, and the `install mnemos` exit-2 stub are coherent. `install nemoclaw` has explicit handling for non-root, missing `podman`, missing template, and failed image pull.

## Requested checks

- PPA(s) added: `25-cix-ppa.sh` writes only `deb [signed-by=/usr/share/keyrings/cix-deb-repo.gpg] https://archive.cixtech.com/debian trixie main` at `post-install/25-cix-ppa.sh:85`. No scoped hook writes a Sky1-Linux apt source; `15-mesa-sky1-pin.sh` only writes a preferences file at `post-install/15-mesa-sky1-pin.sh:29`.
- Key verification: now fixed. The CIX key must match fingerprint `03953A5B64B263FECF6B55771736B9F1A2FAE91E` before the repo is enabled at `post-install/25-cix-ppa.sh:21` and `post-install/25-cix-ppa.sh:76`.
- Pin priority: CIX packages have no explicit apt preference, so normal apt candidate/version selection applies. Mesa `*sky1*` package versions are priority `1001`, above Ubuntu main/default candidates, at `post-install/15-mesa-sky1-pin.sh:34` and `post-install/15-mesa-sky1-pin.sh:75`.
- Idempotence: CIX keyring/source list and Mesa preferences are overwritten in place, not appended, at `post-install/25-cix-ppa.sh:46`, `post-install/25-cix-ppa.sh:85`, and `post-install/15-mesa-sky1-pin.sh:29`. The proprietary hook now cleanly exits when the deb payload is missing or empty at `post-install/25-cix-proprietary.sh:34` and `post-install/25-cix-proprietary.sh:46`.
- PPA network failure: after a trusted key exists, archive/network failure is warn-and-continue for `apt-get update` and `cix-noe-umd` install at `post-install/25-cix-ppa.sh:89` and `post-install/25-cix-ppa.sh:95`. Partial/wedged `cix-noe-umd` states are still fail-loud at `post-install/25-cix-ppa.sh:113`.
- Mesa known issue: the current pin targets Sky1-Linux Mesa 26 package versions, not stock questing Mesa. This audit does not recommend adding GNOME/Sky1 package pieces back; the known issue explicitly keeps XFCE-only as the ship posture at `docs/KNOWN-ISSUE-GNOME-LOGIN-LOOP-2026-05-08.md:40` and `docs/KNOWN-ISSUE-GNOME-LOGIN-LOOP-2026-05-08.md:80`.

## HIGH findings

### H1 - CIX apt signing key was trusted without fingerprint verification

File: `post-install/25-cix-ppa.sh:21`, `post-install/25-cix-ppa.sh:22`, `post-install/25-cix-ppa.sh:55`, `post-install/25-cix-ppa.sh:76`

Root cause: the hook previously copied a bundled key or fetched `ppa-gpg-public-key.asc` and immediately used it as the `signed-by` key for `archive.cixtech.com`. That scoped apt trust to one keyring, but it did not verify the key identity before enabling a third-party package source.

Why HIGH: this repo installs privileged CIX userspace from that archive, including `cix-noe-umd`, and the hook can run during unattended installs. Trust-on-first-use is not enough for a release installer.

Concrete diff applied:

- Added a pinned CIX key fingerprint constant.
- Added keyring fingerprint extraction in a temporary `GNUPGHOME`.
- Staged and fetched keys are rejected on fingerprint mismatch.
- If no verified key is available, the hook removes stale `cix-ppa.list` and exits 0 instead of leaving a broken unauthenticated repo path.
- The installed keyring is re-checked before writing the source list.

### H2 - Proprietary deb hook did not cleanly handle absent/empty netinstall payloads

File: `post-install/25-cix-proprietary.sh:27`, `post-install/25-cix-proprietary.sh:34`, `post-install/25-cix-proprietary.sh:40`, `post-install/25-cix-proprietary.sh:46`

Root cause: the hook required `/usr/local/lib/cix-installer/assets/cix-debs` to exist and then used `ls *.deb` pipelines to derive the install set. In netinstall mode the directory can be absent or tracked only by `.gitkeep`, so the old behavior was either a hard failure or a noisy empty `dpkg -i --force-depends` call.

Why HIGH: this component must support both full and netinstall modes. The absence of bundled closed-source debs is expected in netinstall and should not make the post-install sweep look failed.

Concrete diff applied:

- Added `/cdrom/cixmini/assets/cix-debs` fallback for manual recovery runs.
- Missing directory now logs a netinstall/no-payload skip and exits 0.
- Empty directory now logs a netinstall skip and exits 0.
- Replaced `ls | grep` install-set derivation with a bash array over `./*.deb`.
- If every deb is filtered out, the hook exits before invoking `dpkg`.

## MEDIUM findings

### M1 - Mesa pin has no scoped source owner

File: `post-install/15-mesa-sky1-pin.sh:29`, `post-install/15-mesa-sky1-pin.sh:34`, `post-install/15-mesa-sky1-pin.sh:66`, `post-install/25-cix-ppa.sh:85`

`15-mesa-sky1-pin.sh` pins `mesa-vulkan-drivers`, `mesa-libgallium`, `libgl1-mesa-dri`, `libegl-mesa0`, `libgbm1`, `libglapi-mesa`, `libosmesa6`, `libdisplay-info3`, and `libllvm21` when their versions match Sky1 naming. The priority is `1001`, so a Sky1 candidate beats Ubuntu main.

Gap: no scoped hook adds the Sky1-Linux apt source that would provide those candidates. `25-cix-ppa.sh` adds CIX official only. This does not mean the pin is wrong; it means the pin is only effective if the Sky1 packages are already present through a bootstrap pool, manual source, or prebaked state.

No code change in this sweep: the operator directive is XFCE-only, and the known GNOME issue explicitly says not to add the missing Sky1/GNOME pieces back by default.

### M2 - CIX archive outage degrades quietly after the key is trusted

File: `post-install/25-cix-ppa.sh:89`, `post-install/25-cix-ppa.sh:95`, `post-install/25-cix-ppa.sh:146`, `post-install/25-cix-ppa.sh:245`

The hook intentionally treats `apt-get update` and `apt-get install cix-noe-umd` failure as warn-and-continue. If the package remains absent, it logs a skip. That is coherent with the r78 netinstall note, but the final line still says the runtime layer was applied even if no runtime landed.

Recommendation: change the final summary to report actual state, for example `cix-noe-umd=ii`, `absent`, or `recovered`, rather than a generic success line.

### M3 - `cix-noe-umd` is installed unversioned

File: `post-install/25-cix-ppa.sh:87`, `post-install/80-npu.sh:147`, `post-install/80-npu.sh:192`

The package install is unversioned. The NPU status doc says the current kernel-side compatibility layer bridges `cix-noe-umd 2.0.x`, and only `2.0.2` is confirmed working. If the CIX archive serves a newer incompatible `cix-noe-umd`, apt will choose it unless repository metadata or package versions prevent that.

Recommendation: once the archive version set is verified on target hardware, pin or request the known-compatible userspace version explicitly. Do not infer this from package names alone.

### M4 - `80-npu.sh` still documents manual `cix-noe-umd` installation

File: `post-install/25-cix-proprietary.sh:70`, `post-install/25-cix-ppa.sh:87`, `post-install/80-npu.sh:161`, `post-install/80-npu.sh:219`

Runtime ownership is now:

- `25-cix-proprietary.sh` filters out `cix-noe-umd`, `cix-npu-umd`, and `cix-npu-onnxruntime`.
- `25-cix-ppa.sh` installs and recovers `cix-noe-umd`.
- `80-npu.sh` installs the kernel module, SSDT override, modules-load file, and status doc.

Gap: the generated status doc in `80-npu.sh` still tells operators to curl and `dpkg -i` `cix-noe-umd_2.0.2_arm64.deb`. That is stale split-ownership documentation. It belongs to the next NPU/docs sweep because `80-npu.sh` is out of scope here.

### M5 - Proprietary deb install tolerates partial package loss by design

File: `post-install/25-cix-proprietary.sh:144`, `post-install/25-cix-proprietary.sh:148`, `post-install/25-cix-proprietary.sh:152`, `post-install/25-cix-proprietary.sh:160`

The full-mode install pattern is the usual `dpkg -i --force-depends`, then `apt-get install -fy`, then `dpkg --configure -a`. That handles normal transitive dependency ordering across a pile of vendor debs. The hook then purges `iU`/`iF` packages and exits 0.

This is acceptable for known vendor postinst breakage, but it means a full-mode target can finish with fewer proprietary packages than the original 37-deb capture. The logs under `/var/log/cix-install/25-*` are the source of truth.

### M6 - `ncz install nemoclaw` starts the service but does not enable it

File: `post-install/46-ncz-cli.sh:229`, `post-install/46-ncz-cli.sh:239`, `post-install/46-ncz-cli.sh:240`, `assets/agent-stack/nemoclaw.container:22`

The command pulls the image, creates the volume, copies the quadlet, reloads systemd, and starts `nemoclaw.service`. The quadlet has an `[Install]` section, but the CLI does not run `systemctl enable --now nemoclaw.service`.

Impact: verify on a real target whether the active quadlet is boot-persistent. If not, `install nemoclaw` is really "start now" rather than an installed service.

### M7 - `ncz` NPU wrapper staging uses only the `/cdrom` path

File: `post-install/46-ncz-cli.sh:28`, `post-install/46-ncz-cli.sh:29`, `post-install/30-agents.sh:31`

`46-ncz-cli.sh` stages `/opt/cix/npu_embed_v2.py` only from `/cdrom/cixmini/assets/cix-py/npu_embed_v2.py`. Other hooks already prefer `/usr/local/lib/cix-installer/assets/...` because `/cdrom` is not bind-mounted in netinstall mode.

Impact: the CLI itself installs, and `ncz install mnemos` is still a stub, but direct wrapper use may be absent on netinstall targets. Add the same late-copy fallback when `install mnemos` becomes real.

## LOW findings + recommendations

### L1 - `25-cix-ppa.sh` header is stale for DKMS ownership

File: `post-install/25-cix-ppa.sh:2`, `post-install/25-cix-ppa.sh:178`, `post-install/25-cix-ppa.sh:209`

The header still says the hook installs `cix-npu-driver-dkms` and `cix-vpu-driver-dkms`. Current code intentionally does not install `cix-npu-driver-dkms`, and it only tries VPU DKMS when kernel headers are present.

### L2 - VPU DKMS iF/iU branch logs ERROR but exits success

File: `post-install/25-cix-ppa.sh:212`, `post-install/25-cix-ppa.sh:223`, `post-install/25-cix-ppa.sh:226`

The comment says iF/iU should hard-fail, but the branch purges and continues. This may be intentional because VPU is optional; align the comment with the behavior or return nonzero.

### L3 - Legacy `assets/ncz-cli.sh` is stale and says `ncx`

File: `assets/ncz-cli.sh:2`, `post-install/46-ncz-cli.sh:37`

The installed CLI is generated by `46-ncz-cli.sh`, not `assets/ncz-cli.sh`. The asset still says `ncx` and lacks the current command surface. It is not runtime-active, but it can confuse future audits.

### L4 - `ncz status` assumes `/dev/aipu0`, while NPU docs also use `/dev/aipu`

File: `post-install/46-ncz-cli.sh:314`, `post-install/80-npu.sh:130`, `post-install/80-npu.sh:156`

The status command checks `/dev/aipu0` and `/dev/cix-noe0`. The NPU hook docs say the module creates `/dev/aipu`. If hardware uses `/dev/aipu`, `ncz status` can under-report NPU presence.

## Test plan

Static validation run locally:

```sh
bash -n post-install/15-mesa-sky1-pin.sh post-install/25-cix-proprietary.sh post-install/25-cix-ppa.sh post-install/46-ncz-cli.sh
shellcheck -S warning post-install/15-mesa-sky1-pin.sh post-install/25-cix-proprietary.sh post-install/25-cix-ppa.sh post-install/46-ncz-cli.sh
git diff --check -- post-install/25-cix-proprietary.sh post-install/25-cix-ppa.sh
```

Generated `ncz` body checks run locally from the heredoc:

```sh
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -n
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -s -- help
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -s -- install --help
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -s -- install mnemos   # rc=2
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -s -- models pull      # rc=2
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -s -- install nemoclaw # rc=1 as non-root
sed -n '38,355p' post-install/46-ncz-cli.sh | bash -s -- status           # rc=0, no sudo prompt
```

Key material inspection run locally:

```sh
GNUPGHOME=/tmp/cix-installer-gnupg gpg --show-keys --with-fingerprint assets/cix-deb-repo.gpg
shasum -a 256 assets/cix-deb-repo.gpg
```

Observed CIX key:

```text
pub fingerprint: 0395 3A5B 64B2 63FE CF6B 5577 1736 B9F1 A2FA E91E
sub fingerprint: B4E5 7BE2 34B0 E3F5 547E 65FF 9871 36EB 0CC8 EC87
asset sha256: 0edc3d545f1e9aa56807aba07c6970df6587cdb9d9712dc7f6104e784d7ff63f
```

Target chroot checks to run on the next ISO:

```sh
chroot /target bash /usr/local/lib/cix-installer/post-install/15-mesa-sky1-pin.sh
chroot /target apt-cache policy mesa-vulkan-drivers libdisplay-info3 libllvm21
cat /target/etc/apt/preferences.d/99-sky1-mesa26.pref

chroot /target bash /usr/local/lib/cix-installer/post-install/25-cix-ppa.sh
chroot /target apt-cache policy cix-noe-umd
chroot /target dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' cix-noe-umd || true
find /target/usr -name 'libnoe.so*' -print

chroot /target bash /usr/local/lib/cix-installer/post-install/25-cix-proprietary.sh
tail -80 /target/var/log/cix-install/25-dpkg.log /target/var/log/cix-install/25-apt-fix.log /target/var/log/cix-install/25-dpkg-configure.log
chroot /target dpkg -l | awk '/^iU|^iF|^ii.*cix-/ {print}'

chroot /target ncz help
chroot /target ncz install mnemos; test "$?" = 2
chroot /target ncz status
chroot /target sudo ncz install nemoclaw
chroot /target systemctl status nemoclaw.service --no-pager
chroot /target systemctl is-enabled nemoclaw.service || true
```

Not run locally: apt install against `archive.cixtech.com`, target chroot execution, Podman pull/start of NemoClaw, or hardware validation for Mesa/NPU/VPU device nodes.
