# Release image hosting

NCZ-OS release images are published in more than one place so a download
never depends on a single host.

| Where | Role | What is there |
|---|---|---|
| GitHub Releases (`github.com/ncz-os/cix-installer/releases`) | Main download page; the README and release notes link here | Every release, each with its split image parts, `PARTS.sha256`, `SHA256SUMS` and `ncz-join-image.sh` |
| GitLab release + generic package registry (`gitlab.com/ncz-os/cix-installer/-/releases`) | Second download location | The latest release only: the same files, stored in the project's generic package registry and linked from the GitLab release of the same tag |
| Object storage | Fallback for heavy download traffic | The same files, linked from the release notes when used |

The files are byte-identical in every location, so the same `PARTS.sha256` and
`SHA256SUMS` check a download from any of them, and `ncz-join-image.sh` works
the same way on files from any source (see the release notes for the steps).

## Downloading from GitLab

Open the release on `gitlab.com/ncz-os/cix-installer/-/releases` and download
the parts for your architecture plus `PARTS.sha256`, `SHA256SUMS` and
`ncz-join-image.sh`. Each asset also has a stable direct address:

    https://gitlab.com/ncz-os/cix-installer/-/releases/<tag>/downloads/<file>

which redirects to the package file

    https://gitlab.com/api/v4/projects/<project-id>/packages/generic/ncz-os-image/<version>/<file>

No account or token is needed to download from the public project.

## Publishing a release to GitLab

`tools/publish-release-gitlab.sh` takes a staged release folder (the split
parts, `PARTS.sha256`, `SHA256SUMS` and `ncz-join-image.sh`) and an existing
tag:

    tools/publish-release-gitlab.sh --dir <staged-folder> --tag <tag> --dry-run
    tools/publish-release-gitlab.sh --dir <staged-folder> --tag <tag> --notes <notes.md> --prune-old

What it does, in order:

1. Checks every part against `PARTS.sha256`, refuses parts that are not
   listed, and refuses any file over the registry's per-file limit (5 GiB on
   GitLab.com; override with `NCZ_GITLAB_MAX_FILE_BYTES`). Nothing is sent if
   a check fails.
2. Confirms the tag exists. The tool never creates tags; push the tag first.
3. Uploads each file to the generic package `ncz-os-image`, version = the tag
   without a leading `v` (override with `--package` / `--version`). The sha256
   the registry reports for each upload must equal the local one (up to three
   attempts). Files already present with the same sha256 are skipped, so a
   re-run only sends what changed; older copies of a re-uploaded file name are
   removed so each name resolves to exactly one verified file.
4. Creates the GitLab release for the tag, or updates its title and notes,
   and adds or updates one asset link per file (parts as `package` links,
   checksum files and the join script as `other` links).
5. With `--prune-old`, deletes older versions of the package, keeping the
   newest `--keep N` (default 1, so only the release just published stays on
   GitLab), and removes the asset links of older releases that pointed at a
   deleted version. Older releases themselves, their notes and tags are kept;
   their files stay available from GitHub Releases.

`--dry-run` makes no change: it runs the local checks and, when a token is
available, reads the current registry and release state and prints every
upload, release change, link change and deletion it would make.

### Token

The token needs the `api` scope on the project. It is never passed on a
command line and never printed. The tool reads it, in this order, from:

* `NCZ_GITLAB_TOKEN_HELPER` - a command run with no arguments that prints the
  token on stdout (the same idea as `GIT_ASKPASS`);
* the environment variable whose name is in `NCZ_GITLAB_TOKEN_VAR` (default
  `GITLAB_TOKEN`).

The token reaches `curl` on stdin as a config file, so it is not visible in
the process list.

### Other settings

| Variable | Default | Meaning |
|---|---|---|
| `NCZ_GITLAB_API` | `https://gitlab.com/api/v4` | API base |
| `NCZ_GITLAB_PROJECT` | `ncz-os/cix-installer` | project path or numeric id |
| `NCZ_GITLAB_MAX_FILE_BYTES` | `5368709120` | per-file size limit checked before upload |

### Limits that matter for a release

* GitHub limits release assets to 2 GiB per file, which is why images are
  split into parts; the same parts are used on GitLab.
* GitLab.com accepts generic package files up to 5 GiB each. The package
  registry does not count toward the project repository size limit.
* A two-architecture release is about 7 GB. With `--prune-old` and the
  default `--keep 1`, GitLab holds only one release's worth of image files.
* GitLab.com rate-limits package registry requests to 1,000 per minute per
  IP address; downloading one release is a handful of requests.

## Tests

`build/test-publish-release-gitlab.sh` runs the tool against a mocked `curl`
(no network): dry runs make no change, uploads are verified by sha256, a bad
or unlisted part, a missing file, an oversize file or a missing tag stops the
run before any change, re-runs skip unchanged files, `--prune-old` keeps the
newest versions and removes stale links, and the token never appears in
`curl`'s arguments or in the output.
