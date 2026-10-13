# Release image hosting

NCZ-OS release images are published in more than one place so a download
never depends on a single host.

| Where | Role | What is there |
|---|---|---|
| GitHub Releases (`github.com/ncz-os/cix-installer/releases/latest`) | Main download page; the README and release notes link here | The current release as release files: per architecture its split image parts, `PARTS-<arch>.sha256` and `SHA256SUMS-<arch>`; then `ncz-join-image.sh`, `SHA256SUMS` and `NOTES.md` |
| GitLab release + generic package registry (`gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest`) | Second download location; GitLab is the canonical project | The same release: the same files, stored in one generic package per architecture plus a common package, and linked from the GitLab release of the same tag in an `amd64/` and an `arm64/` folder |
| Object storage | Fallback for heavy download traffic | The same files, linked from the release notes when used |

The files are byte-identical in every location, so the same checksum files
check a download from any of them, and `ncz-join-image.sh` works
the same way on files from any source (see the release notes for the steps).

## Release pages

**One release page per forge, always.** Each of GitHub and GitLab has exactly
one release object: the current release. When a new release is published,
the previous release pages are removed on both forges. Git tags are kept for
every release, so the source of any release stays at its tag.

The two pages are at parity: the same tag, the same title, the same notes,
the same files (names, sizes, sha256, in the same order), the same checksum
files and join script, and the same status wording. GitHub hosts the files
as release assets; GitLab hosts them in the generic package registry and
links them from the release. Apart from the release files, the GitHub
repository is a mirror of GitLab.

GitLab has no pre-release flag, so the status of a release ("preview") is
said in its title and notes. GitHub never treats a pre-release as the
"latest" release, so a release that the stable links below must reach is
published with the GitHub pre-release flag off.

The source offer for the GPL code in an image lives in the release notes,
in [SOURCE-RELEASES.md](SOURCE-RELEASES.md) and in the git tags; it does not
depend on older release pages.

### Release layout

Releases have one folder per architecture where the forge can show one.
GitLab can: a release link's name and direct path may contain `/`, so the
architecture files are listed as `amd64/<file>` and `arm64/<file>`. GitHub
cannot: release assets are one flat list and an asset name cannot hold a
`/`. The closest equivalent on GitHub is per-architecture file names and
checksum files, uploaded as two contiguous groups. Both pages list the same
files in the same order:

| # | GitHub asset | GitLab link name, direct path, link type | GitLab package |
|---|---|---|---|
| 1 | `ncz-os-amd64-<date>-<build>.img.zst.part-NN` (every part) | `amd64/ncz-os-amd64-<date>-<build>.img.zst.part-NN`, `/amd64/ncz-os-amd64.img.zst.part-NN`, package | `ncz-os-image-amd64` |
| 2 | `PARTS-amd64.sha256` | `amd64/PARTS-amd64.sha256`, `/amd64/PARTS-amd64.sha256`, package | `ncz-os-image-amd64` |
| 3 | `SHA256SUMS-amd64` | `amd64/SHA256SUMS-amd64`, `/amd64/SHA256SUMS-amd64`, package | `ncz-os-image-amd64` |
| 4 | the same three kinds of file for arm64 | the same under `arm64/` | `ncz-os-image-arm64` |
| 5 | `ncz-join-image.sh` | `ncz-join-image.sh`, `/ncz-join-image.sh`, other | `ncz-os-image-common` |
| 6 | `SHA256SUMS` | `SHA256SUMS`, `/SHA256SUMS`, other | `ncz-os-image-common` |
| 7 | `NOTES.md` | `NOTES.md`, `/NOTES.md`, other | `ncz-os-image-common` |

* GitLab link names carry the `amd64/` or `arm64/` folder; the file names
  inside the folders and every GitHub asset name are the same. The parity
  check compares the GitLab names with the folder removed.
* Each architecture package also holds a copy of `ncz-join-image.sh`, so
  one package is a complete download for that architecture; only the
  common copy is linked from the release.
* `SHA256SUMS` is kept: it is exactly `SHA256SUMS-amd64` followed by
  `SHA256SUMS-arm64`, it gives one stable address for both images, and it is
  what the image audit file is checked against. There is no combined
  `PARTS.sha256` any more; `ncz-join-image.sh` uses `PARTS-<arch>.sha256` and
  `SHA256SUMS-<arch>` (and still accepts the combined files of older
  releases).
* A release may carry one architecture only; the other folder and its
  files are then absent.
* The release notes have one section per architecture, amd64 first, under
  a heading naming the architecture, with its download table, the image
  sha256, the `sh ncz-join-image.sh <arch>` command and its hardware list.
  GitHub and GitLab get the same body.

The staged release folder mirrors this layout:

    <staged>/amd64/   ncz-os-amd64-<date>-<build>.img.zst.part-NN  PARTS-amd64.sha256  SHA256SUMS-amd64
    <staged>/arm64/   ncz-os-arm64-<date>-<build>.img.zst.part-NN  PARTS-arm64.sha256  SHA256SUMS-arm64
    <staged>/         ncz-join-image.sh  SHA256SUMS  NOTES.md  TITLE  PRERELEASE

### Stable addresses

Documentation, the README, the website and release notes link only to
these addresses, which always reach the current release:

| What | GitHub | GitLab |
|---|---|---|
| Release page | `https://github.com/ncz-os/cix-installer/releases/latest` | `https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest` |
| A small file | `https://github.com/ncz-os/cix-installer/releases/latest/download/<file>` | `https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/<file>` |
| An architecture's checksum files | `https://github.com/ncz-os/cix-installer/releases/latest/download/PARTS-<arch>.sha256` (and `SHA256SUMS-<arch>`) | `https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/<arch>/PARTS-<arch>.sha256` (and `<arch>/SHA256SUMS-<arch>`) |
| An image part | take the name from `PARTS-<arch>.sha256` or the page | `https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/<arch>/ncz-os-<arch>.img.zst.part-NN` |
| Screenshots | `https://raw.githubusercontent.com/ncz-os/cix-installer/main/docs/screenshots/...` | `https://gitlab.com/ncz-os/cix-installer/-/raw/main/docs/screenshots/...` |
| Source of a release | `https://github.com/ncz-os/cix-installer/tree/<tag>` | `https://gitlab.com/ncz-os/cix-installer/-/tree/<tag>` |

`<file>` is one of `SHA256SUMS`, `ncz-join-image.sh` and `NOTES.md`; those
names, and `PARTS-<arch>.sha256` and `SHA256SUMS-<arch>`, never change. The
image parts carry the build in their names
(`ncz-os-<arch>-<date>-<build>.img.zst.part-NN`). On GitLab each part link
also has a stable direct path without the build
(`<arch>/ncz-os-<arch>.img.zst.part-NN`), so the GitLab address above never
changes. GitHub has no aliases for release files: a second, stable-named copy
of every part would double the stored bytes, so on GitHub users take the
part names from `PARTS-<arch>.sha256` (which the stable address above always
serves) or from the page.

Links to a tag's release page (`/releases/tag/<tag>`, `/-/releases/<tag>`),
to a tag's download (`/releases/download/<tag>/...`) or to a package file
stop working when the next release replaces the page.
`tools/check-release-links.sh` (run by `make lint-platform`) fails on them in
`README*.md` and `docs/`, and on a latest-release file address whose name is
not one of the stable names above; the kernel source packages linked from
`kernel-source/` are not release files and are not affected.

### Release notes and screenshots

The staged release folder holds the notes as `NOTES.md` (start from
[releases/release-page-template.md](releases/release-page-template.md)),
the title as `TITLE` (one line) and the GitHub pre-release flag as
`PRERELEASE` (`yes` or `no`). `NOTES.md` uses the GitLab forms of the links
above; the GitHub page gets the same text with those links in their GitHub
form, and the parity check compares the two with the link forms normalised.
`NOTES.md` is also attached as a release file.

Screenshots shown on the release page are files in `docs/screenshots/<release>/`
on `main`, referenced by their absolute raw URL (a relative image path does
not render on a release page). Both forges render the other's raw URLs
too, through their image proxies, but each page uses its own forge's URL.
Before a screenshot is committed:

* the name says what it shows, numbered for order: `NN-what-it-shows.png`;
* nothing on screen names a host, an IP address, a user name, an e-mail
  address, a serial number, a MAC address or a network name (check terminal
  prompts, window titles, notifications, the login screen user list,
  network and Bluetooth menus, file paths and `About` pages);
* no private wallpaper, document or browser tab is visible;
* metadata is stripped (`exiftool -all= file` or equivalent).

### Retention

* **GitLab** keeps the image files of the current release only: publishing
  runs `tools/publish-release-gitlab.sh --prune-old` (keep 1), which deletes
  older versions of each of `ncz-os-image-amd64`, `ncz-os-image-arm64` and
  `ncz-os-image-common` separately (the version just published is always
  kept), every version of the older single `ncz-os-image` package, and the
  release links that pointed at a deleted version. Other packages (the
  kernel source packages) are never touched.
* **GitHub** keeps the files of the current release, which are exactly the
  staged set; removing the previous release page removes its files. A file
  that must stay reachable after its release is replaced is linked from the
  current release notes to a permanent home (the tag's source tree, the
  kernel source packages), not kept on an old release page.
* Git tags are kept on both forges unless the operator decides otherwise.

### Tools

`tools/check-release-parity.sh` (read-only) compares the two release pages:

    tools/check-release-parity.sh --tag v26.10-preview2
    tools/check-release-parity.sh --tag v26.10-preview2 --quick       # names and sizes only
    tools/check-release-parity.sh --tag v26.10-preview2 --release-dir <staged-folder>

It fails (exit 1, with a readable difference) when either forge has more
than one release page or none for the tag; when the files are not in the
release layout (per-architecture groups in the canonical order, the GitLab
folder names, link types, packages and stable paths); when the title, the notes
(link forms normalised), the GitHub draft/pre-release state or the stable
"latest" addresses differ from what is expected; when the file lists, sizes
or sha256 differ (GitHub API digests, GitLab registry checksums; a file
without an API digest is downloaded and hashed); when a GitLab link is not
a package file of the project or its direct path is not the stable alias;
when any file other than the parts differs byte for byte between the two
pages, `SHA256SUMS` is not `SHA256SUMS-amd64` followed by `SHA256SUMS-arm64`,
or a `PARTS-<arch>.sha256` does not list exactly that architecture's parts on
the page; when the notes lack a section per architecture (amd64 first) with
its image sha256 and join command; or when the screenshot sets differ or a
screenshot does not answer HTTP 200 with the sha256 of the repository file.

`tools/sync-release-pages.sh` publishes a staged release folder to both
pages and retires every other release page. It is a dry run unless given
`--apply`, and `--apply` also needs `--operator-approved <file>` (a file
naming the tag) and `--audit-ok <file>` (a `PASS <sha256>` line for every
image in `SHA256SUMS`, no `FAIL` line), so it cannot publish unattended or
publish an image that did not pass the image audit. It never creates, moves
or deletes git tags; the tag must exist on both forges first.

    tools/sync-release-pages.sh --dir <staged-folder> --tag v26.10-preview2
    tools/sync-release-pages.sh --dir <staged-folder> --tag v26.10-preview2 --apply \
        --operator-approved <approval-file> --audit-ok <audit-file>

Order of work: local checks (the release layout, parts, names, size limits,
the architecture sections of the notes, notes links, screenshots present), the gates, GitLab (`publish-release-gitlab.sh
--prune-old`), GitHub (release, then files in the canonical order, each
verified by size and sha256), a parity check that ignores the other
releases, retirement of every other release object on both forges, and a
final full parity check. The dry run prints every upload, update, deletion
and each release page that would be retired.

### Cutover to a new release

The new release tag is named by the operator and created at the final
image source commit before publishing. Then:

1. Upload the new files: `sync-release-pages.sh --apply` publishes the new
   release on GitLab and on GitHub.
2. Parity: the tool checks the two new pages (other releases ignored).
3. Retire: the tool removes every other release page on both forges, with
   their files on GitHub and their links on GitLab. Tags are kept, so
   `/tree/<tag>` source links keep working.
4. Final parity: the tool checks again, now including "one release page per
   forge" and the stable "latest" addresses.

Run `check-release-parity.sh --tag <tag>` again afterwards from any machine.

### Release checklist

1. Images built, gated and audited; the audit result is written as
   `PASS <sha256> <image>` lines.
2. The operator names the tag; the tag is pushed to GitLab at the image
   source commit. The filtered GitHub sync (`tools/sync-github-mirror.sh`,
   [GITHUB-SYNC.md](GITHUB-SYNC.md)) then pushes the tag to GitHub, where it
   points at the filtered copy of that commit. Check that the tag is on GitHub
   before any GitHub release step: a release created for a tag GitHub does
   not have yet makes GitHub create the tag itself, at the wrong commit.
3. Staged folder in the release layout: `amd64/` and `arm64/` with their
   parts, `PARTS-<arch>.sha256` and `SHA256SUMS-<arch>`; `ncz-join-image.sh`,
   `SHA256SUMS`, `NOTES.md` (one section per architecture) (from the template, screenshots committed on `main` and
   checked against the privacy list), `TITLE`, `PRERELEASE`.
4. `tools/check-release-links.sh --files <staged-folder>/NOTES.md`
5. `tools/sync-release-pages.sh --dir <staged-folder> --tag <tag>` (dry run);
   read the plan, including the release pages it will retire.
6. The operator writes the approval file; run again with `--apply`.
7. `tools/check-release-parity.sh --tag <tag>` passes.

## Downloading from GitLab

Open <https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest>
and download the files in the folder of your architecture (`amd64/` or
`arm64/`: the parts, `PARTS-<arch>.sha256` and `SHA256SUMS-<arch>`) plus
`ncz-join-image.sh`. Each file also has a stable direct
address (see [Stable addresses](#stable-addresses)):

    https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/<file>
    https://gitlab.com/ncz-os/cix-installer/-/releases/permalink/latest/downloads/<arch>/<file>

which redirect to the release of the current tag and then to the package
file in the registry. One architecture's whole folder is also the generic
package `ncz-os-image-<arch>` (with a copy of the join script) on the
project's package registry page. No account or token is needed to download from the
public project.

## Publishing a release to GitLab

`tools/sync-release-pages.sh` runs this step for a release; it can also be
run on its own. `tools/publish-release-gitlab.sh` takes a staged release
folder in the release layout and an existing tag:

    tools/publish-release-gitlab.sh --dir <staged-folder> --tag <tag> --dry-run
    tools/publish-release-gitlab.sh --dir <staged-folder> --tag <tag> --notes <notes.md> --prune-old

What it does, in order:

1. Checks the folder against the release layout: every part against its
   `PARTS-<arch>.sha256`, no unlisted or misplaced part, `SHA256SUMS` equal
   to the per-architecture files, and no file over the registry's per-file
   limit (5 GiB on GitLab.com; override with `NCZ_GITLAB_MAX_FILE_BYTES`).
   Nothing is sent if a check fails.
2. Confirms the tag exists. The tool never creates tags; push the tag first.
3. Uploads the files to the generic packages `ncz-os-image-amd64`,
   `ncz-os-image-arm64` (each with a copy of `ncz-join-image.sh`) and
   `ncz-os-image-common`, version = the tag without a leading `v` (override
   with `--package` / `--version`). The sha256 the registry reports for each
   upload must equal the local one (up to three attempts). Files already
   present with the same sha256 are skipped, so a re-run only sends what
   changed; older copies of a re-uploaded file name are removed so each name
   resolves to exactly one verified file.
4. Creates the GitLab release for the tag, or updates its title and notes,
   and adds or updates one asset link per file in the canonical order: the
   `amd64/` and `arm64/` folders (type package), then the common files (type
   other), each with the stable direct path from [Release layout](#release-layout).
   Links of the release that are not in the staged set are removed.
5. With `--prune-old`, deletes older versions of each package separately,
   keeping the newest `--keep N` (default 1, so only the release just
   published stays on GitLab), deletes the older single `ncz-os-image`
   package, and removes the asset links of older releases that pointed at a
   deleted version.

`--dry-run` makes no change: it runs the local checks and, when a token is
available, reads the current registry and release state and prints every
upload, release change, link change and deletion it would make.

### Token

The token needs the `api` scope on the project. It is never passed on a
command line and never printed. The tools read it, in this order, from:

* `NCZ_GITLAB_TOKEN_HELPER` - a command run with no arguments that prints the
  token on stdout (the same idea as `GIT_ASKPASS`);
* the environment variable whose name is in `NCZ_GITLAB_TOKEN_VAR` (default
  `GITLAB_TOKEN`).

The GitHub token of `check-release-parity.sh` and `sync-release-pages.sh`
is read the same way from `NCZ_GITHUB_TOKEN_HELPER` or the variable named in
`NCZ_GITHUB_TOKEN_VAR` (default `GITHUB_TOKEN`); it needs write access to the
repository's releases (`contents: write`) for `--apply`. Without tokens the
parity check reads both public projects anonymously.

Tokens reach `curl` on stdin as a config file, so they are not visible in
the process list. Files are always downloaded without a token.

### Other settings

| Variable | Default | Meaning |
|---|---|---|
| `NCZ_GITLAB_API` | `https://gitlab.com/api/v4` | GitLab API base |
| `NCZ_GITLAB_PROJECT` | `ncz-os/cix-installer` | project path or numeric id |
| `NCZ_GITLAB_MAX_FILE_BYTES` | `5368709120` | per-file size limit checked before upload |
| `NCZ_GITHUB_REPO` | `ncz-os/cix-installer` | GitHub repository |
| `NCZ_GITHUB_API` | `https://api.github.com` | GitHub API base |
| `NCZ_GITHUB_MAX_FILE_BYTES` | `2147483648` | GitHub release file limit (files must be smaller) |
| `NCZ_RELEASE_APPROVAL_FILE` | - | default for `--operator-approved` |
| `NCZ_RELEASE_AUDIT_FILE` | - | default for `--audit-ok` |

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

`build/test-publish-release-gitlab.sh` runs the GitLab publisher against a
mocked `curl` (no network): dry runs make no change, uploads go to one
package per architecture plus the common package and are verified by
sha256, layout errors (a bad, unlisted, misplaced or wrong-architecture
part, a missing file, a combined `SHA256SUMS` that does not match), an
oversize file or a missing tag stop the run before any change, re-runs skip
unchanged files, links sit in `amd64/` and `arm64/` folders in the canonical
order with stable direct paths, stale links are removed, `--prune-old` keeps
the newest versions of each package, removes the old single package and
stale links and never touches the kernel source packages, and the token
never appears in `curl`'s arguments or in the output.

`build/test-release-parity.sh` runs `check-release-parity.sh`,
`sync-release-pages.sh` and `check-release-links.sh` against a mocked GitHub
and GitLab (no network): matching pages pass; a different title, body,
file, size, sha256, small-file content, file order, GitLab folder name,
link type or package, combined `SHA256SUMS`, `PARTS-<arch>.sha256`
contents, missing architecture section or join command, unexpected file,
screenshot, extra release page, missing release, pre-release flag or
"latest" address fails with a readable difference; the sync dry run changes
nothing and lists the releases it would retire; `--apply` without the
approval or audit gate, with a missing screenshot, a release-specific link,
notes without architecture sections, a folder outside the layout or a
missing tag changes nothing; a gated `--apply` publishes both pages,
retires every other release (tags kept) and ends at parity; and no token
reaches `curl`'s arguments or the output.
