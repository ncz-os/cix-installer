# Package registry cleanup

The GitLab generic package registry holds release image parts
(`ncz-os-image`), the kernel source tarballs that are the corresponding
source for distributed kernels, and, in the zoder project, the nightly
binaries. Without retention every upload stays forever, including every
re-upload of a file under the same name. Three things keep it bounded.

## 1. GitLab cleanup policy (automatic)

Every project's package cleanup policy is set to keep **one** file per file
name inside a package version (`keepNDuplicatedPackageFiles = ONE_PACKAGE_FILE`).
GitLab applies it on its own schedule (about every 12 hours). It only removes
older copies of a file name inside the same version; it never removes a
version.

Before the policy was first applied (2026-10-13), the older copies it would
remove from tagged release versions were downloaded, checked against the
registry's sha256 and archived: `zoder` 0.2.0 `install.sh` (4025 bytes,
sha256 `91fa9779f41951310679a5106c7f4970baef1ac9371ef60424e7ccd5a7485a6b`) and
`mnemos` 3.0.1 `mnemos_os-3.0.1-py3-none-any.whl` (248269 bytes, sha256
`9e90932575d350e3fb888445be0e5dd60910fc6bbfee48a0d129bcc64c5e3bc1`) and
`mnemos_os-3.0.1.tar.gz` (555158 bytes, sha256
`1652969788560540513b744af99168e020629265c7a629b3bdec448036a676b6`). The
newest file of each name, which is what a download returns, stays.

Policy per project as of 2026-10-13 (the group-wide "generic duplicates
allowed" setting is unchanged):

| Project | Before | After | First run (UTC) |
|---|---|---|---|
| `argonautsystems/calliope` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:09 |
| `argonautsystems/clio` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:10 |
| `argonautsystems/etlantis` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:09 |
| `argonautsystems/ic-engine` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:10 |
| `argonautsystems/InvestorClaw` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:14 |
| `ncz-os/charon` | not created | not set: archived (read-only) | - |
| `ncz-os/chromium-ncz-sky1` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:39 |
| `ncz-os/cix-gen` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:06 |
| `ncz-os/cix-installer` | ONE_PACKAGE_FILE | ONE_PACKAGE_FILE | 2026-10-14 04:28:05 |
| `ncz-os/debs` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:12 |
| `ncz-os/distro-core` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:13 |
| `ncz-os/graeae` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:51 |
| `ncz-os/graeae-hive-mind` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:56 |
| `ncz-os/knemon` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:52 |
| `ncz-os/linux-cix` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:50 |
| `ncz-os/linux-rpi` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:49 |
| `ncz-os/linux-t2-ncz` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:38 |
| `ncz-os/mcp-contracts` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:02 |
| `ncz-os/mcp-stdio-rs` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:57 |
| `ncz-os/meta` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:12 |
| `ncz-os/meta-base` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:13 |
| `ncz-os/meta-cix` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:06 |
| `ncz-os/mnemos` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:14 |
| `ncz-os/mnemos-bridge-aider` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:59 |
| `ncz-os/mnemos-bridge-anthropic` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:00 |
| `ncz-os/mnemos-bridge-claude-connector` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:59 |
| `ncz-os/mnemos-bridge-core` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:01 |
| `ncz-os/mnemos-bridge-crewai` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:58 |
| `ncz-os/mnemos-bridge-gemini` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:00 |
| `ncz-os/mnemos-bridge-openai` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:01 |
| `ncz-os/mnemos-embedkit` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:57 |
| `ncz-os/mnemos-hot-rs` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:45 |
| `ncz-os/mnemos-rs` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:45 |
| `ncz-os/mnemos-stiphos` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:50 |
| `ncz-os/mnemosctl` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:02 |
| `ncz-os/mpf` | not created | not set: archived (read-only) | - |
| `ncz-os/ncz-os-security-policy-project` | not created | not set: package registry disabled | - |
| `ncz-os/ncz-ports` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:54 |
| `ncz-os/ncz-tools` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:08 |
| `ncz-os/ncz-wayland-screenhack` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:40 |
| `ncz-os/pantheon` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:52 |
| `ncz-os/pi-gen` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:11 |
| `ncz-os/singularity-wallpaper-rotator` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:40 |
| `ncz-os/tokenomics` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:48 |
| `ncz-os/wayshade` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:38 |
| `ncz-os/worker-hive-relay` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:54 |
| `ncz-os/zcon` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:28:05 |
| `ncz-os/zepo` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:44 |
| `ncz-os/zoder` | ALL_PACKAGE_FILES | ONE_PACKAGE_FILE | 2026-10-14 04:27:49 |

The same policy was set on the 16 non-public projects the maintainers can administer.

Archived projects are read-only, so the policy can only be set after they are
unarchived; a project with the package registry disabled has nothing to clean.

Check or set it with GraphQL (token with the `api` scope):

```graphql
query { project(fullPath: "ncz-os/cix-installer") {
  packagesCleanupPolicy { keepNDuplicatedPackageFiles nextRunAt } } }

mutation { updatePackagesCleanupPolicy(input: {
  projectPath: "ncz-os/cix-installer",
  keepNDuplicatedPackageFiles: ONE_PACKAGE_FILE }) {
  packagesCleanupPolicy { keepNDuplicatedPackageFiles } errors } }
```

## 2. Pruning at publish time

`tools/publish-release-gitlab.sh --prune-old [--keep N]` deletes older
versions of the image package right after a release is published, keeping
the newest N (default 1), and removes release links that pointed at a deleted
version. Use `--dry-run` first to see what it would remove.

## 3. Weekly retention run

`tools/gitlab-registry-cleanup.sh` applies the rules in
[`tools/registry-retention.conf`](../tools/registry-retention.conf):

| Package | Versions kept | Duplicate files |
|---|---|---|
| `ncz-os-image` | newest 2, plus any version a release links to | newest copy per name |
| `zoder-nightly` `master` | always | newest copy per name |
| `zoder-nightly` dated (`YYYY-MM-DD`) | newest 14 | newest copy per name |
| `zoder-nightly` per-run (`run-*`) | newest 14 | newest copy per name |
| anything not listed (kernel source, pristine bases, tagged zoder releases) | all, never looked at | untouched |

A version that an asset link of any release still points at is never removed.
The run is a dry run unless `--apply` is given; `--manifest FILE` writes the
planned removals (package ids, file names, sizes, sha256) before anything is
removed, and `--log FILE` appends one summary line per run.

```sh
# dry run, print the plan
NCZ_GITLAB_TOKEN_HELPER=~/.config/ncz/gitlab-token tools/gitlab-registry-cleanup.sh

# apply, keeping a manifest and a log line
NCZ_GITLAB_TOKEN_HELPER=~/.config/ncz/gitlab-token tools/gitlab-registry-cleanup.sh \
  --apply --manifest "registry-cleanup-$(date -u +%F).json" --log registry-cleanup.log
```

The token helper is any command that prints the token (like `GIT_ASKPASS`);
the token reaches curl on stdin and is never on a command line. Listing needs
`read_api`, removal needs `api`.

### Schedule

Run it weekly from the publish host, from a clean checkout of `main`. The
first weeks run as a dry run only; review the log, then switch the second
line on:

```cron
# m  h  dom mon dow
15   7  *   *   1   cd ~/src/cix-installer && git pull -q --ff-only && NCZ_GITLAB_TOKEN_HELPER=$HOME/.config/ncz/gitlab-token tools/gitlab-registry-cleanup.sh --manifest ~/registry-cleanup/plan-$(date -u +\%F).json --log ~/registry-cleanup/cleanup.log > ~/registry-cleanup/last-dry-run.txt 2>&1
#45  7  *   *   1   cd ~/src/cix-installer && NCZ_GITLAB_TOKEN_HELPER=$HOME/.config/ncz/gitlab-token tools/gitlab-registry-cleanup.sh --apply --manifest ~/registry-cleanup/applied-$(date -u +\%F).json --log ~/registry-cleanup/cleanup.log > ~/registry-cleanup/last-apply.txt 2>&1
```

Change retention only by editing `tools/registry-retention.conf` and running
the tests: `bash build/test-gitlab-registry-cleanup.sh`.

## Never removed

Kernel source and pristine-base tarballs (`linux-source-*`,
`linux-pristine-base-*`) are the corresponding source for kernels in images
that were distributed ([SOURCE-RELEASES.md](SOURCE-RELEASES.md)). No rule names
them, so neither the weekly run nor the cleanup policy removes them (each
holds a single file).
