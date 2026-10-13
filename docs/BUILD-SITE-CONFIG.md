# Build site configuration

The build and release tooling in this repository does not hardcode where a
project's artifact store is mounted, which machines build which architecture, or
where results are published. Each build host supplies those values itself.

None of this is needed to read the source, to run the tests, or to fetch the
publicly available build inputs (`build/stage-build-inputs.sh --arch <arch> --public`).

## How a value is looked up

For the settings in the first table, `build/lib/ncz-site.sh` returns, in order:

1. the environment variable, when it is set and not empty;
2. otherwise the first line of `${XDG_CONFIG_HOME:-$HOME/.config}/ncz/<file>`;
3. otherwise nothing. The calling script then either skips that step or stops
   with a message naming the variable and the file.

A one-time setup on a build host is therefore, for example:

```sh
mkdir -p ~/.config/ncz
echo /srv/store/build-inputs > ~/.config/ncz/build-inputs-dir
```

## Build settings

| Variable | File under `~/.config/ncz/` | Used by | Meaning |
|---|---|---|---|
| `NCZ_YOCTO_SHARED_DIR` | `yocto-shared-dir` | `build/build-image.sh`, `build/stage-kernel.sh`, `build/stage-amd64-kernel.sh`, `build/publish-amd64-kernel.sh`, `build/ncz-yocto.sh`, `build/preflight-freshness-gate.sh`, `build/verify-overlay-modversions.py`, `build/verify-kernel-default-policy.sh` | Root of the shared Yocto export (`downloads/`, `sstate-cache/`, `kernel-staging/`) |
| `NCZ_BUILD_INPUTS_DIR` | `build-inputs-dir` | `build/stage-build-inputs.sh` | Store holding the pinned build inputs of `manifests/build-inputs.tsv` |
| `NCZ_SUBSTRATE_CACHE_DIRS` | `substrate-cache-dir` | `Makefile`, `build/stage-substrate.sh`, `build/refresh-substrate.sh` | Directories searched for the pinned Debian netinst images |
| `NCZ_IMAGE_ARCHIVE` | `image-archive-dir` | `build/stage-to-argonas.sh`, `build/ship-image.sh` | Archive that receives gated images |
| `NCZ_SSPLUGIN_SRC_ROOT` | `projects-dir` | `build/stage-screensaver-plugin.sh`, `build/verify-dual-arch-parity.sh` | Store "projects" root holding the screensaver settings plugin packages |
| `NCZ_VENDOR_ARCHIVE_DIR` | `vendor-archive-dir` | `build/stage-canonical-assets.sh` | Archive of vendor SDK and bake assets |
| `NCZ_AMD64_HOST`, `NCZ_ARM64_HOST` | `amd64-build-host`, `arm64-build-host` | `build/build-image.sh --arch both` | `[user@]host` that builds each architecture over ssh |
| `NCZ_STORE_SSH_COMMAND` | `store-ssh-command` | `build/ncz-yocto.sh`, `build/preflight-freshness-gate.sh`, `build/singularity-nightly-track.sh` | `GIT_SSH_COMMAND` used for the store's git remotes |
| `NCZ_YOCTO_FALLBACK_BASE` | `yocto-fallback-base` | `build/ncz-yocto.sh` (`build/yocto-layers.conf`) | Optional base URL of private mirrors of the Yocto layers; the public GitLab URLs are always tried first |
| `NCZ_MAC_DEST` | `ship-dest` | `build/ship-image.sh` | `[user@]host:dir` that receives a shipped image |
| `NCZ_SINGULARITY_STAGE_DEST` | `singularity-stage-dest` | `build/build-singularity.sh --push` | `[user@]host:/dir` that receives the built desktop payload |
| `NCZ_STORE_PASS` | (environment only) | `build/build-singularity.sh --push` | Optional password for that destination, passed to `sshpass -e`, never on the command line |
| `NCZ_SUDO_PASS_FILE`, `NCZ_SUDO_PASS_KEY` | `sudo-pass-file`, `sudo-pass-key` | `build/lib/priv.sh` | JSON file and (dotted) key holding the sudo password, used only when the build is not root and has no passwordless sudo; fed to `sudo -S` on stdin. Key default `sudo_password` |
| `NCZ_SHIP_PASS_FILE` | (environment only) | `build/ship-image.sh` | Password file (mode 0600) for the ship destination; default `~/.config/ncz/ship.pass` |

## Publishing and operations scripts

These scripts read plain environment variables (no `~/.config/ncz` file):

| Variable | Used by | Meaning (default) |
|---|---|---|
| `NCZ_APT_REPO_DIR` | `build/ops/publish/ncz-reprepro-publish.sh`, `backfill-buildkite-packages.sh` | Local reprepro tree (`$HOME/ncz-apt-repo`) |
| `NCZ_R2_PUBLISH_ENV` | the same two scripts | Credentials file for the object-store publish (`$HOME/.config/ncz-r2-publish.env`) |
| `NCZ_PUBLISH_SCRATCH` | `build/ops/publish/ncz-reprepro-publish.sh` | Scratch directory (`$HOME/.cache/ncz-publish-tmp`) |
| `NAS_HOST`, `NAS_EXPORT`, `MNT` | `build/ops/backup/ncz-backup.sh` | Backup NFS server and export (required; or the first line of `/etc/ncz/backup-nas-host` and `/etc/ncz/backup-nas-export`) and the local mount point. **The default mount point is now `/mnt/ncz-backups`.** |
| `NCZ_SYNC_WORKDIR` | `tools/nightly/ncz-singularity-sync.sh` | Bare mirror used by the nightly sync (`$HOME/sinty-build/sync/singularity-desktop-mirror.git`) |
| `STORE_HOST`, `STORE_DST`, `STORE_PASS` | `tools/nightly/ncz-singularity-sync.sh` | Staging destination `[user@]host`, its directory, and its password; set in `/etc/ncz/singularity-sync.env` |
| `NCZ_INSTALL_LOG_DIR` | `build/ncz-logd.sh` | Where install logs collected from a target are written. **The default is now `~/ncz-install-logs`.** |
| `LOCKRIG_HOSTS` | `tools/lockrig/lockrig` | Test-host inventory. Otherwise `~/.config/ncz/lockrig-hosts.tsv`, then a git-ignored `tools/lockrig/hosts.tsv`, then the documentation-only `tools/lockrig/hosts.example.tsv`. Per-host harness paths come from `LOCKRIG_BINDIR_<NAME>`. |

## Installed-system setting

| Variable | Used by | Meaning |
|---|---|---|
| `NCZ_DEFAULT_LOGHOST` | `post-install/36-telemetry.sh` | Log host used when `/etc/ncz-loghost` contains `default`. Empty by default, which forwards nowhere. Log forwarding is off unless `/etc/ncz-loghost` exists; writing the log host address into that file is the usual way to turn it on. |
