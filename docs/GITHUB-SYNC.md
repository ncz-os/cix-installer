# GitHub copies of the GitLab projects

GitLab (`gitlab.com/ncz-os`) is where the projects live: merge requests,
issues, CI and the canonical commit history. Each public project also has a
repository under `github.com/ncz-os` that carries the same branches, tags and
files, updated every hour by `tools/sync-github-mirror.sh`.

The two forges keep separate release pages, because release files are hosted
differently on each. The sync tool never creates, moves or deletes a ref that carries a GitHub
release.

## What the GitHub copy contains

Every GitLab branch and tag, with the full history, filtered the same way on
every run:

| Rule | Effect on the copy |
|---|---|
| File size limit | A file version over 100 MiB (GitHub's per-file limit) is left out of the commit that adds it. The blob ids are recorded in `tools/github-sync/strip-blobs.txt`. |
| Text list | Literals from a site text list are replaced in file contents and commit messages. |
| Identity list | Author, committer and tagger identities are normalised with a site mailmap. |
| Refs | Only `refs/heads/*` and `refs/tags/*`; merge-request refs are not copied. |

Nothing else changes. In particular a commit that the filter does not touch,
and whose parents are untouched, keeps its GitLab sha. Projects whose history
needs no filtering therefore have identical shas on both forges.

Where a commit does differ, `history/gitlab-commit-map` on GitHub holds
`commit-map.tsv`: one line per rewritten commit, `gitlab_sha<TAB>github_sha`.

## Determinism

The filter is `git filter-repo` with `--prune-empty never`, so no commit is
dropped and the result depends only on the GitLab history and the three lists.
Two runs on the same input give the same shas (`build/test-github-sync.sh`
checks this), so each hourly run is an incremental push. A non-fast-forward
update is only needed when GitLab itself rewrote a ref; it is pinned with
`--force-with-lease` to the sha the previous run pushed.

## Running it

```sh
# plan only (default): fetch, build the copies, print the ref changes
tools/sync-github-mirror.sh [--repo NAME]... [--report plan.json]

# apply: creates, fast-forwards and GitLab-driven rewinds; --prune follows
# GitLab deletions
tools/sync-github-mirror.sh --apply --prune

# verify: every GitLab ref's tree (after the same rules) equals the GitHub tree
tools/check-github-sync.sh [--repo NAME]... [--verbose]
```

Plan actions: `create`, `fast-forward`, `rewind` (GitLab moved a ref
non-fast-forward), `remove` (GitLab deleted a ref), `force` (GitHub has
commits this tool did not push; needs `--allow-force`), `delete` (a ref only on
GitHub; needs `--prune-github-only` or a `prune_github_only=` entry in
`tools/github-sync/repos.tsv`), and `*-BLOCKED(release:...)` for any of these
on a ref with a GitHub release. Before any ref is moved or deleted its GitHub
value is pinned in a local backup repository (`--backup-bundle` also writes a
bundle of every GitHub ref).

`check-github-sync.sh` exits 1 when a ref is missing, extra or has a different
tree. Refs that differ only because a GitHub release holds them are listed as
`RELEASE` and do not count as drift unless `--strict-releases` is given.

## Settings

The tool reads its site settings like the build tooling
([BUILD-SITE-CONFIG.md](BUILD-SITE-CONFIG.md)): an environment variable, or the
first line of `~/.config/ncz/<file>`.

| Variable | File | Meaning |
|---|---|---|
| `NCZ_GHSYNC_WORKDIR` | `ghsync-workdir` | persistent cache, copies, state, backups, logs |
| `NCZ_GHSYNC_REPLACE_FILE` | `ghsync-replace-file` | text list (`literal==>replacement` per line), kept outside every repository |
| `NCZ_GHSYNC_MAILMAP` | `ghsync-mailmap` | mailmap file |
| `NCZ_GHSYNC_BACKUP_DIR` | `ghsync-backup-dir` | where `--backup-bundle` writes bundles |
| `NCZ_GHSYNC_GITLAB_BASE` | `ghsync-gitlab-base` | default `https://gitlab.com` |
| `NCZ_GHSYNC_GITHUB_BASE` | `ghsync-github-base` | default `https://github.com` |
| `NCZ_GHSYNC_GITHUB_API` | `ghsync-github-api` | default `https://api.github.com` |

Push credentials come from `GIT_ASKPASS`; the same helper answers the GitHub
API token prompt used for the release lookup. `git-filter-repo` must be on
`PATH`.

`tools/github-sync/run-hourly.sh` is one scheduled pass (check, plan, apply
with `--prune`, check) and `tools/github-sync/ghsync.service` /
`ghsync.timer` are example systemd user units for it.
