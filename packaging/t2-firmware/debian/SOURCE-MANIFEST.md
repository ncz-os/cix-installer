# Source & rights manifest — apple-firmware-script (native t2-firmware)

Pinned, public, immutable identities for every code asset this package ships
or references. No vendor/Ubuntu `.deb` payload is used as a source. Digests
were captured by fetching the exact bytes (raw.githubusercontent.com /
`git ls-remote`) on 2026-10-15.

## 1. Primary source (shipped as documentation, patched for install)

| Field | Value |
|---|---|
| Repo | `https://github.com/t2linux/wiki` |
| Commit (immutable) | `c16ca396f638727f943d577a24dcc0d7e5f0cdd8` |
| Path | `docs/tools/firmware.sh` |
| Bytes | 31831 |
| sha256 | `c1c1d8aa25bb5f089e46ccd0d9738fc13bfbd784f499aa924466c690f059961e` |
| License | MIT (in-file, lines 3-24) |
| Shipped as | `upstream/firmware.sh` (byte-for-byte identical, unmodified) |
| Installed helper | `get-apple-firmware` (minimal reviewed patch; see §5) |

Raw URL:
`https://raw.githubusercontent.com/t2linux/wiki/c16ca396f638727f943d577a24dcc0d7e5f0cdd8/docs/tools/firmware.sh`

Note: `gh-pages` carries a *different, older* copy (31825 B). Do not pin it.

## 2. Nested code asset — `get_from_online` runtime fetch (NOT shipped)

At script line ~1050 the `get_from_online` path downloads a helper at run
time. The installed helper pins this fetch to an immutable commit and
verifies the SHA-256 of the downloaded bytes before executing them.

```
https://raw.githubusercontent.com/kholia/OSX-KVM/4c378a4b5e0b219783683012bec680325eb40719/fetch-macOS-v2.py
```

Audit result:

| Field | Value |
|---|---|
| Upstream repo | `https://github.com/kholia/OSX-KVM` |
| Pinned commit | `4c378a4b5e0b219783683012bec680325eb40719` |
| File | `fetch-macOS-v2.py` |
| Bytes | 23644 |
| sha256 @ `4c378a4b…` | `39ac6d26bd265f5d32198062f515ad15ef93afb7a74e702be2b008090d5bd5f3` |
| Repo LICENSE | **absent** (HTTP 404 at repo root) — provenance must come from origin |

Actual origin of that file: it is a modified derivative of
`acidanthera/OpenCorePkg` `Utilities/macrecovery/macrecovery.py`
(`Upstream:` line 15). The upstream project is **BSD-3-Clause**.

| Field | Value |
|---|---|
| Origin repo | `https://github.com/acidanthera/OpenCorePkg` |
| HEAD resolved | `81ecf1a7e75c318dfc859ddabe5b91f4af757231` |
| LICENSE.txt sha256 | `4ca709aac88e7b297e794f464d6557203b23a4e92e792b579bb968fef2bce4c4` |
| License | BSD-3-Clause (`spdx_id: BSD-3-Clause`) |
| macrecovery.py @ HEAD | sha256 `3023a9b4ca79a5255d93c00f25ab5df37e6f938b729b797d9ecea56184b17aff` |

Disposition: this file is **executed, not shipped** — the package does not
contain it. The installed helper pins the fetch to the immutable commit
`4c378a4b…` and verifies the SHA-256 before execution. The package does not
relabel or relicense it. The original OpenCore BSD-3-Clause grant covers the
upstream `macrecovery.py`; it does **not** automatically cover the OSX-KVM
derivative modifications, whose redistribution scope is not asserted here.

## 3. Other external references in the source (documented, not shipped)

| Location | Reference | Disposition |
|---|---|---|
| `copy_to_efi` (~line 868) | self-copy fallback | The installed helper copies its own reviewed local bytes (`BASH_SOURCE`); on failure it prints an actionable manual-copy message. It does **not** download a mutable wiki copy. Rights = MIT (same upstream source). |
| `install_package` (`brew`, ~line 576) | `https://raw.githubusercontent.com/Homebrew/install/7a3f48c7e498d7df3237fd41c30f4d492857edf4/install.sh` | **macOS-only** branch (Homebrew). Pinned to immutable commit `7a3f48c7…`; install.sh sha256 `5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148`. Not shipped; never reached on Debian. Do **not** add a dependency for it. |
| `get_from_online` | `curl`, `dmg2img`, `losetup`, `mount`, `umount`, `python3`, `lsblk` | Runtime tools for the optional Apple-CDN path. Declared as `Depends`/`Recommends` where the default path needs them; see `debian/control`. |

## 4. Command-dependency audit (derived from the actual code paths)

Commands referenced anywhere in the script: `apt awk brew chmod chown cp curl
cut dmg2img dnf file git grep head install losetup mkdir mount pacman python
python3 rm sha256sum sudo tail tar unmount`.

Default / Debian-relevant paths and what they actually need:

- `get_from_efi`  → `mktemp mount tar umount` (+ script's own `chown`, `rmdir`)
- `get_from_macos`→ `mktemp mount tar umount lsblk` + optional APFS driver
- `get_from_online`→ `curl python3 dmg2img losetup mount umount lsblk tar mktemp`
- All paths call the embedded Python renamer → `python3` (stdlib only:
  `logging, os, os.path, re, sys, pprint, statistics, tarfile, io,
  collections, hashlib, pathlib`)

Declared `Depends:` = `python3, bash, coreutils, tar, util-linux, mount,
sudo, kmod, ca-certificates, mawk | gawk, curl`. `dmg2img` is `Recommends:` because only the optional Apple-CDN
path needs it. `brew`, `dnf`, `pacman`, `rpmbuild`, `git`, `makepkg`
are not Debian-path dependencies. The Debian package-manager path uses
`apt-get` from the already detected APT installation. Signed Forky snapshot
20261012T023456Z offers apfs-dkms 0.3.21-1 for the optional APFS driver path. This matches the actual code, not a generic "python-only" claim.

## 5. Installed-helper patch (relative to upstream)

The installed `get-apple-firmware` differs from `upstream/firmware.sh` only
in the following reviewed ways:

1. `get_from_online` pins the `fetch-macOS-v2.py` fetch to the immutable
   commit `4c378a4b…` and verifies its SHA-256
   (`39ac6d26…`) before executing it; a mismatch aborts without execution.
2. `install_package` (Homebrew branch) pins the `install.sh` fetch to the
   immutable commit `7a3f48c7…` and verifies its SHA-256
   (`5f333bbe…`) before executing it; a mismatch aborts without execution.
3. `copy_to_efi` copies the reviewed local script bytes via `BASH_SOURCE`
   instead of downloading a mutable wiki copy; on failure it prints an
   actionable manual-copy message.

4. Both Debian package-install branches simulate the exact install argument
   array and reject a failed simulation or any Remv line before real install.
   Download finalization failures return nonzero and preserve an existing
   destination; unverified replacement bytes are never executed.
