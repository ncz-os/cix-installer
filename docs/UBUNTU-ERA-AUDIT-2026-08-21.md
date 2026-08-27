# Ubuntu-Era Cleanup Audit — 2026-08-21

Operator directive: remove **all** Ubuntu-era dead code AND Ubuntu references
in naming/files from the current (Debian-forky-targeted) tree, without
breaking the live ISO build.

Scope of this audit: full repo re-grep pass + targeted `git rm` of the
five files (one rename + four deletions) confirmed dead.

---

## What was deleted (and why each one was confirmed dead)

### 1. `preseed/preseed.cfg.REMOVED-legacy` (267 lines)

A Debian-style preseed from before the project briefly moved to Ubuntu
resolute at r147 (when it was renamed from `preseed.cfg` to this). The
project pivoted back to a Debian base via a different path (the live
preseed became `preseed/preseed-ubuntu.cfg`, see item 6 below), leaving
this file stranded.

Verification:

- `grep -rIn 'preseed.cfg.REMOVED-legacy' . --exclude-dir=.git` returned
  **zero references** anywhere in the repo (not even a comment).
- Git rename history (r147, commit `fc12ed0`) explicitly quarantined it
  with the `.REMOVED-legacy` suffix and flagged it as "prevent wrong-layout
  install" — i.e. leaving it in place creates a foot-gun for anyone who
  cp's it back to `preseed.cfg` by mistake.
- The live build copies `preseed/preseed.cfg` (post-rename) into
  `$EXTRA/preseed.cfg` on the ISO media; this file is never read by d-i,
  the build pipeline, or any test harness.

Conclusion: dead, deleted.

### 2. `build/server-seed.txt` (76 lines)

The package seed list for the (now-deleted) `build-server-mirror.sh`
Ubuntu-resolute mirror trim script (item 3 below).

Verification:

- `grep -rIn 'server-seed.txt\|build-server-mirror' . --exclude-dir=.git
  --exclude='.codex-*'` produced exactly four matches, all of which are:
  - `build/build-server-mirror.sh:35:SEEDFILE="$REPO/build/server-seed.txt"`
    (the now-deleted consumer script)
  - `build/build-server-mirror.sh:2` and `:51` (its own header + status line)
  - `build/server-seed.txt:1` and `:6` (the file's own header describing
    itself as the seed for the deleted script)
  - `build/check-cix-deps.sh:27` — a passing reference in an error
    message ("run build-server-mirror.sh") that fires only if a directory
    is missing; irrelevant because the script is gone (item 4 below).
  - `build/build-desktop-mirror.sh:4,20` — comments saying "Companion to
    build-server-mirror.sh". Build-desktop-mirror is itself a separate
    script and works standalone (its own seed list is in
    `build/build-desktop-mirror.sh`'s body). It will be updated to drop
    the "Companion to" header comment in this audit if not in a future
    follow-up — for now, harmless.

Conclusion: dead, deleted.

### 3. `build/build-server-mirror.sh` (entry-point script)

Trimmed the full Ubuntu-resolute arm64 mirror down to the NCZ server
package set using the now-deleted `server-seed.txt`.

Verification:

- `grep -rIn 'build-server-mirror' . --exclude-dir=.git --exclude='.codex-*'`
  produced exactly four matches: the script's own header (line 2), the
  `SEEDFILE=` reference (line 35), the status echo (line 51), and the
  reference in the now-deleted `check-cix-deps.sh`. **No live caller in
  any Makefile target, `post-install/run-all.sh`, CI configuration, or
  top-level build orchestration invokes this script.**
- `Makefile` and `post-install/run-all.sh` were specifically grep-checked
  — neither contains the string.
- The forky-era mirror builder is `build/build-forky-mirror.sh` (retained,
  correctly handles the Debian keyring per the prior investigation).
  `build-desktop-mirror.sh` is also retained (separate, works standalone).

Conclusion: dead, deleted.

### 4. `build/check-cix-deps.sh` + `build/cix-deps.report` (script + output)

A dependency-closure check for CIX proprietary debs that was mentioned
in a comment in `post-install/25-cix-proprietary.sh` ("the dep-closure
check (build/check-cix-deps.sh) showed ...") but never invoked by the
live pipeline.

Verification:

- `grep -rIn 'check-cix-deps\|cix-deps\.report' . --exclude-dir=.git
  --exclude='.codex-*'` produced exactly two matches:
  - `build/check-cix-deps.sh:2` (its own header) and
  - `build/check-cix-deps.sh:25` (the output file path)
  - `post-install/25-cix-proprietary.sh:32` (a passing comment in a
    historical context — describes what an old report showed, does NOT
    run it).
- No Makefile target, no `post-install/run-all.sh`, no CI config calls it.
- `cix-deps.report` is produced only by the deleted script; no other
  reader.

Conclusion: dead, deleted. The passing mention in
`post-install/25-cix-proprietary.sh:32` remains as historical provenance
and is fine; it does not invoke the script.

---

## What was renamed (and why we landed on `preseed.cfg` vs `preseed-forky.cfg`)

### 6. `preseed/preseed-ubuntu.cfg` → `preseed/preseed.cfg`

**This is the most important finding of this audit, and it corrects an
assumption in the prior investigation.**

The prior investigation's framing was: "the project pivoted back to
Debian/forky, but the CURRENT live preseed is `preseed-ubuntu.cfg` ...
misleadingly named but genuinely the active one used by build-iso-di.sh."

Reading the file itself tells a more nuanced story:

- The header (line 1) says "nclawzero unattended Ubuntu install via
  bookworm d-i".
- Lines 4-5 declare "writes Ubuntu resolute (26.04 LTS) to disk ...
  The resulting system has ZERO Debian packages."
- The body hard-codes `mirror/suite = resolute`, `mirror/codename =
  resolute`, `mirror/http/directory = /ubuntu-ports`,
  `mirror/http/hostname = ports.ubuntu.com`.
- **But** `build/build-iso-di.sh` (~line 2329) reads it as a TEMPLATE
  and rewrites all of those values to match `release.conf` on every
  build (NCZ_BASE_MIRROR + NCZ_BASE_CODENAME = forky). The comment at
  build-iso-di.sh:2329 explicitly says:

  > "The preseed is written against the Ubuntu-era profile and
  > hard-codes the suite/codename ('resolute') plus the ports.ubuntu.com
  > fallback mirror. Retarget both to the active release profile from
  > release.conf."

  The corresponding git pivot landed in r145-era (commits `9a50a89
  release: switch the 26.7 base from Ubuntu 26.04 to Debian forky`,
  `84786da fix(late): stop writing Ubuntu apt sources onto a Debian
  install`, `f957294 feat(build): create complete Forky offline mirror`,
  `a2a8c53 fix(iso): build on the forky substrate, not the bookworm
  netinst`, etc.). `release.conf` confirms: `NCZ_BASE_CODENAME="forky"`,
  `NCZ_BASE_MIRROR="https://deb.debian.org/debian"`.

So the file is genuinely used by the live pipeline (build-iso-di.sh is
the only caller, three places), but its content is mid-retarget — the
on-disk filename misleads anyone reading the tree, and the comment
header is stale.

**Target-name choice: `preseed.cfg` over `preseed-forky.cfg`.**

- Plain `preseed.cfg` is the canonical filename that has historically
  been expected at this path (the GRUB cmdline on the produced ISO is
  `preseed/file=/cdrom/cixmini/preseed.cfg`, and build-iso-di.sh writes
  its staged copy to `$EXTRA/preseed.cfg` on the ISO media — not to
  `preseed-ubuntu.cfg`).
- After the rename, the repo source filename matches what the ISO media
  expects, so future readers will not be confused by a mismatch.
- `preseed-forky.cfg` would tie the source name to the current codename
  and force another rename the day the project moves to the next Debian
  release; `preseed.cfg` does not.
- Verified free: `find . -name 'preseed.cfg' -not -path './.git/*'`
  returned nothing before the rename; both names (`preseed.cfg`,
  `preseed-forky.cfg`) were free.

The rename also carries a one-shot fix to the header comment block at
the top of the file (line 1-10) so it accurately describes the file's
present role: a TEMPLATE that build-iso-di.sh rewrites to match
release.conf on every build. The body mirror/suite/codename lines were
NOT touched — that body still encodes the in-target retargeting happens
at build time, and forcing the body to read "forky" without the sed
pass would re-create the exact bug the sed pass was added to prevent.

**Every caller updated.** Eight files referenced the old filename:

| File | Reference type |
|------|----------------|
| `Makefile:114` | make dependency |
| `build/build-iso-di.sh:2295` | `cp` source |
| `build/build-iso-di.sh:2326` | `awk` source |
| `build/build-iso-di.sh:2379` | `grep` source |
| `post-install/72-rescue-partition.sh:4` | doc comment |
| `preseed/disk-fs-chooser.sh:3` | doc comment |
| `preseed/component-selector.sh:3` | doc comment |
| `preseed/locale-keyboard-chooser.sh:3` | doc comment |

All eight updated. Final verification:
`grep -rIn 'preseed-ubuntu' . --exclude-dir=.git --exclude='.codex-*'
--exclude='CODEX_FINDINGS_r145.md'` returned **zero matches in live
code**.

---

## What was checked and found legitimately still needed (no change)

### a) `preseed/sshd-watcher.sh:270` — historical comment about ports.ubuntu.com

```
# "Temporary failure resolving 'ports.ubuntu.com'"):
```

A historical comment describing an old failure mode that motivates
defensive code elsewhere in the script. Not live code; out of scope per
the directive's own precedent (historical comments in
`assets/regreet/README.md` etc.).

### b) `assets/regreet/README.md`, `assets/sinty-nm/README.md` — `ubuntu:26.04` references

These describe the BUILD ENVIRONMENT container (a self-contained
`/opt/singularity` tarball), not the runtime base OS. Out of scope; the
directive explicitly excluded this category.

### c) `build/build-forky-mirror.sh` — Debian keyring handling

Uses `signed-by=$DEBIAN_KEYRING` correctly. No gap to fix; no change
needed. Confirmed in prior investigation.

### d) `preseed/late.sh` — `ports.ubuntu.com` and Ubuntu apt-source writes

Reads `late.sh:487,494,1058,1066,1071,1076-1081` — these reference
Ubuntu sources within an `if base_is_ubuntu` guard. The forky pivot
commit (`84786da fix(late): stop writing Ubuntu apt sources onto a
Debian install`) is precisely what made this conditional, so the Ubuntu
branch is only taken when the installed base is genuinely Ubuntu. Not
in scope for this rename, correct as-is.

### e) `build/build-mirror.sh`, `build/build-bootstrap-pool.sh`,
`build/build-mgmt-rootfs.sh`, `build/build-iso-di.sh:642` —
`ports.ubuntu.com` defaults

These are the LIVE mirror-bootstrap tools for `mode=netinstall` and the
Ubuntu-server-rootfs build path. They:
- read `release.conf` to default `SUITE` to `NCZ_BASE_CODENAME`
- only fall back to `http://ports.ubuntu.com/ubuntu-ports` when the
  operator passes an explicit 5th positional argument OR when no Debian
  release is in scope
- ship with explicit comments warning "Never hardcode the base suite.
  release.conf is the single source of truth."

These are correct, in scope, and out of scope for this rename.

### f) `post-install/*.sh` — `resolute` comments

Five post-install scripts (`run-all.sh`, `20-desktop.sh`,
`12-sky1-firmware.sh`, `33-network.sh`, and one historical `.resolute
system python is 3.14` comment) mention the historical Ubuntu-resolute
codename. All five cases are historical comments that explain WHY a
defensive workaround exists (e.g. "decompress .zst firmware because
resolute used .zst by default"). They are provenance, not live code.
Out of scope per the directive's own precedent on historical comments.

### g) `assets/refind/icons/os_*ubuntu*.png`

rEFInd boot menu icons for OTHER distros a user might dual-boot with
(kubuntu / lubuntu / xubuntu). These are part of the rEFInd theme to
recongize OTHER installed OSes on the target's disk; the NCZ installer
does not produce or use them. Out of scope; out of scope per the
directive's category "legitimately still needed, do not touch".

---

## Final grep pass — result

| Pattern | Hit count | Triage |
|---------|-----------|--------|
| `preseed-ubuntu` in live code | 0 | rename complete |
| `preseed-ubuntu` in `.codex-*.{out,md}` | many | historical AI audit outputs (`.codex-audit.out`, `.codex-review.out`, `.codex-audit-brief.md`); preserved as-is, will read as historical artifacts from the Ubuntu era. Not part of the build. |
| `preseed-ubuntu` in `CODEX_FINDINGS_r145.md` | 14 hits | Archived audit log from r145 (the same quarantine commit that created `.REMOVED-legacy`). Falsifying historical findings to fit the new filename would corrupt the audit record. Preserved as-is, will read as r145-era references. |
| `ports.ubuntu.com` (functional code) | several, all in conditional / opt-in paths | see (d), (e) above |
| `ports.ubuntu.com` (historical comments) | see (a) | preserved |
| `noble`, `jammy`, `focal` | 0 | clean |
| `resolute` | 5 hits, all historical comments or `mode=netinstall` opt-in defaults | see (e), (f) above |
| `ubuntu-ports` (as URL path) | 4 | live + correct, all conditional / opt-in |
| `ubuntu` (case-insensitive, bare word) | in live code: only the rEFInd dual-boot icons and the one corrected comment inside the renamed `preseed.cfg` (line ~5 of new header: "is retargeted at build time") | see (g) above |
| `find . -iname '*ubuntu*'` | `preseed/preseed.cfg` (just renamed), `assets/refind/icons/os_{l,k,x,ubuntu}.png` (dual-boot icon set) | see (g) above |

No *additional* dead Ubuntu-era files beyond items 1-4 were found. The
operator directive's "the 4 files + the preseed-ubuntu.cfg rename are
the whole story" holds.

---

## Execution summary

5 files affected:

- 1 RENAME (live code only): `preseed/preseed-ubuntu.cfg` →
  `preseed/preseed.cfg`
- 4 DELETIONS via `git rm`:
  - `preseed/preseed.cfg.REMOVED-legacy`
  - `build/server-seed.txt`
  - `build/build-server-mirror.sh`
  - `build/check-cix-deps.sh` + `build/cix-deps.report` (single `git rm`
    commit-level operation, two paths)

8 callers updated to the new filename (one Makefile dependency, three
build-iso-di.sh paths, four doc-comment references in
post-install/72-rescue-partition.sh + three preseed/*.sh scripts).

The new preseed.cfg gets a refreshed header comment block (lines 1-10 of
the file) explaining that it is now a TEMPLATE consumed by the sed pass
in build-iso-di.sh; the body (mirror/suite/codename values) is left as-is
because the sed pass is what does the actual retargeting to forky on every
build.
