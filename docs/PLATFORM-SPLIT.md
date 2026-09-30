# Platform split: final structure and how to work in it

Design and rationale: `docs/PLATFORM-SPLIT-DESIGN.md`. Inventory (source of truth for
every file's class): `docs/platform-inventory.tsv`.

## Where things live

```
common/<root>/...                    shared files, and `mixed` files
platforms/sky1-arm64/<root>/...      Radxa Orion O6N / CIX Sky1, Debian forky arm64
platforms/amd64/<root>/...           Apple T2 MacBooks, ASUS/NVIDIA, generic x86
platform-tools/                      assembler, mover, verifier (stay at the repo root)
Makefile release.conf docs/ ...      repo-level files stay where they were
```

`<root>` is one of `post-install manifests assets build preseed tests tools scripts
packaging packages sbom docker kernel-source`. The path below the root is the path the
file always had (`assets/kernel/mali/...` is now
`platforms/sky1-arm64/assets/kernel/mali/...`), so `git log --follow` works and every
document that names a path still names it in the historical, flat form.

Feature tags (`t2`, `nvidia-cuda`) are a column in the inventory; they do not create
directories. One amd64 image serves all amd64 hardware and each feature hook detects its
hardware at runtime.

## The flat build view (compatibility layer)

Roughly 130 scripts, the Makefile, `preseed/late.sh`, the two image builders and the
fleet's staged blobs all read the flat paths (`post-install/`, `assets/`, `build/`,
...). Rewriting them by regex would change semantics (the builders copy whole
directories such as `assets/kernel` that now span several sources), so the split keeps
that contract instead: `platform-tools/platform-assemble.py` generates the flat
directories as **hard links** to the sources (no copy of the 1.1 GB asset tree). The
Makefile runs it before any rule or wildcard is evaluated; `make assemble` does it by hand.

* The flat directories are generated and git-ignored. **Edit the source files** under
  `common/` or `platforms/<p>/`; an edit made to a flat file (an editor or `sed -i` that
  swaps the inode) is discarded, with a warning, at the next assemble.
* `NCZ_ASSEMBLE_SCOPE=all` (default) links common + both platforms: byte-identical to
  the pre-split tree. `NCZ_ASSEMBLE_SCOPE=sky1-arm64` or `amd64` links common + that
  platform only, so a platform build cannot see the other platform's assets or hooks
  (`make ... NCZ_ASSEMBLE_SCOPE=amd64`). `all` stays the default until the per-platform
  scope has been through both image gates.
* Untracked blobs already in the flat directories (`assets/cix-debs/*.deb`,
  `assets/squashfs`, `build/` outputs) are never touched. Blobs may equally be staged
  under `platforms/<p>/assets/...` (the `.gitignore` rules are mirrored onto the source
  paths), where they are linked into the view. `assets/sky1-firmware/` is a Sky1 blob dir.
* Compatibility symlinks were not needed: the hard-linked flat view is the compatibility
  layer, and it is the same for the fleet hosts that reference flat paths. Tracked
  symlinks (`assets/kernel/edge`, `assets/docs/*.md`, `kernel-source/.../files`) are
  recreated verbatim in the view; their relative targets are only meaningful there.
* After a checkout, pull or rebase, `make` re-assembles first, but a script run directly does not:
  run `platform-tools/install-git-hooks.sh` once per clone to refresh the view on
  post-checkout, post-merge and post-rewrite. Do not assemble on a pre-split branch (its flat
  files are tracked there). The assembler takes an exclusive lock and writes its state file
  atomically, so concurrent `make` runs are safe.
* Known limit: a build step that WRITES a tracked file in place (for example
  `build/ota-image-digest.txt`) writes into the view; the change is not tracked. Copy such
  output to the source path if it must be committed.

## How to add things

| you add | do this |
|---------|---------|
| any file | add a row to `docs/platform-inventory.tsv` (`common`, `sky1`, `amd64`, `mixed`; feature `t2`/`nvidia-cuda` on amd64 rows), put the file under the matching source directory, `make assemble` |
| a hook | exact row for `post-install/NN-name.sh`; place it under `common/post-install/` or `platforms/<p>/post-install/`; `make gen-hooks-lists`; platform hooks start with an `NCZ-PLATFORM-GUARD` (or `ARCH GATE`) early exit; mixed hooks carry `# NCZ-MIXED-HOOK: <what is platform-specific>` |
| an asset | row, then place under `common/assets/` or `platforms/<p>/assets/` |
| a package | add it to the platform's `manifests/*.pkgs`; a one-sided package needs a row in `build/arch-parity-allowlist.tsv` (`make parity`) |
| a build script | row; `common/build/` for shared tooling and gates, `platforms/<p>/build/` for kernel, DKMS, OTA and per-platform gates |

New files that arrive at a flat path (for example from a branch cut before the split) are
moved by re-running `platform-tools/platform-split-move.py` (idempotent).

## How the build picks the platform

`ARCH` (Makefile) selects the manifests and builder branches as before.
`post-install/run-all.sh` picks the platform from `NCZ_PLATFORM`, else
`NCZ_TARGET_ARCH` / the `BUILD_ARCH` stamp / `dpkg`, loads
`hooks.list.<platform>` (generated by `build/gen-hooks-lists.sh`, stored under
`platforms/<p>/post-install/`), and runs only the listed hooks, logging every
`PLATFORM-SKIP`. No list, an empty or unreadable list, an unknown architecture or
`NCZ_HOOKS_LIST=none` means the legacy behavior.

## Checks

* `make lint-platform` (also part of `make image`): inventory format and coverage; every
  file lives under the source directory its class demands (`LINT-LAYOUT`); no tracked file
  at a flat build path; hook lists current and correct; no platform token in a COMMON
  hook (`build/platform-deny-patterns.txt`, reviewed exceptions in
  `docs/platform-deny-exceptions.tsv`); platform hooks guarded; mixed hooks marked.
* `make test-platform`: 41 unit tests for the lint, the generator and the `run-all.sh`
  list handling, positive and negative.
* `make parity`: manifest divergence, `ncz-screensavers` debs, hook arch-gate heuristic
  (release-branch gates).
* `platform-tools/verify-split.sh [--base REV] [--release REV]` (needs ~1.5 GB of TMPDIR; set TMPDIR to a disk path if /tmp is tmpfs): proves the split changed nothing a
  builder can see. Scope `all`: every file the pre-split tree tracked is present at the
  same flat path with the same git blob id and mode. Scopes `sky1-arm64` and `amd64`:
  exactly the base files whose inventory class is common, mixed or that platform. Both
  `make -n ARCH=arm64 image` and `make -n ARCH=amd64 image` output identical (paths and
  the short sha normalized). Then lint and unit tests. Files deliberately edited after the
  pure-rename commit (tooling that learned the new layout: `Makefile`, `.gitignore`,
  `build/lint-platform.sh`, `build/gen-hooks-lists.sh`, `build/test-platform-lint.sh`,
  `docs/platform-inventory.tsv`, `platform-tools/*`) are listed and excluded.

## Re-running after a rebase

```
git rebase <new release head>            # renames are followed by git
platform-tools/platform-split-move.py    # moves any file that arrived at a flat path
make assemble && platform-tools/verify-split.sh --base <last commit before the move>
```

## What is still open

* `mixed` files (14 hooks, `Makefile`, `preseed/late.sh`, ...) remain whole in `common/`
  with a marker; splitting them is future work.
* Manifests are still two full closures per base name; the common-plus-delta form is
  specified in the design document.
* `NCZ_ASSEMBLE_SCOPE=<platform>` builds need a full image gate per platform before it
  becomes the default.
