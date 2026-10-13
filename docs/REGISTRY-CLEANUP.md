# Package registry cleanup

The GitLab generic package registry holds release image parts
(`ncz-os-image`), the kernel source tarballs that are the corresponding
source for distributed kernels, and, in the zoder project, the nightly
binaries. Without retention every upload stays forever, including every
re-upload of a file under the same name. Three things keep it bounded.

## 1. GitLab cleanup policy (automatic)

Each project's package cleanup policy is set to keep **one** file per file
name inside a package version (`keepNDuplicatedPackageFiles = ONE_PACKAGE_FILE`).
GitLab applies it on its own schedule (about every 12 hours). It only removes
older copies of a file name inside the same version; it never removes a
version.

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
