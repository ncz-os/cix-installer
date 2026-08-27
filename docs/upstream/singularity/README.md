# Upstream contributions to Singularity Desktop — staged drafts

Draft contributions from **NCZ-OS 26.7 "Maximilian"** back to
[`singularityos-lab/singularity-desktop`](https://github.com/singularityos-lab/singularity-desktop)
(project site: sinty.dev).

**Status: STAGED / DRAFT ONLY. Nothing here has been filed.** Hold until the NCZ-OS ISO
bakes and the changes are re-verified on the release image, then file per the checklist
below.

## Context

NCZ-OS 26.7 ships **Singularity as its default desktop** on the new **CIX Sky1 (CD8180)**
arm64 SoC (Mali-G720, GLES-only / no Vulkan), hardware-validated on **Radxa Orion O6N** and
**MS-R1**. Likely the first arm64 distro — and first on a Mali GLES-only SoC — to ship
Singularity by default. During bring-up we found a genuine bug and two documentation gaps
worth sending upstream.

## Files

| File | What | Filing target |
|------|------|---------------|
| `00-intro-issue.md` | Friendly intro/announcement | **GitHub Discussion** (post FIRST) |
| `10-pr-libexec-path.md` | Fix: session launcher execs polkit agent from `bin/` but meson installs it to `libexecdir` → silent exit-127 for any `libexecdir != bindir` prefix | **PR** (highest value; file first among PRs) |
| `20-pr-arm64-build.md` | Docs: Debian/Ubuntu deps + aarch64 support statement + `vetro` host-tool build | **PR** (docs-only) |
| `30-pr-gles-no-vulkan.md` | Docs (+ optional guard): GLES-only / no-Vulkan GPU compatibility | **PR** (lightest; file last) |

## Upstreamable vs. downstream-only

**Upstreamable (in these drafts):**

- **libexec-vs-bin path bug** — confirmed reproducible from upstream sources alone: a clean
  `meson install --prefix=/usr` puts `singularity-polkit-agent` in `/usr/libexec` while
  `singularity-desktop-session` execs `$BIN/singularity-polkit-agent` (= `/usr/bin`). Only
  masked today because `deploy-to-host.sh` flattens libexec into bin. **Clearly correct,
  highest value.**
- **arm64 build docs** — the tree is already architecture-clean (built on aarch64 with no
  source changes); what's missing is Debian/Ubuntu deps, an aarch64 support statement, and
  the `vetro` host-tool bootstrap.
- **GLES-only / no-Vulkan note** — `GSK_RENDERER=gl` is already set upstream and wlroots
  auto-falls-back to GLES2, so this is a documentation note + optional `WLR_RENDERER`
  passthrough, not a code-critical fix.

**KEEP DOWNSTREAM (do NOT upstream):**

- `/opt/singularity` prefix (and the NCZ build Makefile's repeated `--prefix` artifact).
- `ncz-gpu-env` GPU-environment selector.
- NCZ wallpaper / red-accent / branding.
- `xterm` → `foot` `.desktop` rewrites.
- lightdm / greetd choices (upstream targets GDM).
- CIX `libmali` driver paths and the `singularity-portal` **wrapper script** — note the
  upstream binary is `xdg-desktop-portal-singularity`; `singularity-portal` is an NCZ
  deploy-script wrapper, not an upstream name. Don't reference it upstream.
- Kernel / DKMS / bootloader work — entirely NCZ.

**Watch-outs (things that look upstreamable but aren't):**

- The task framing mentioned "scripts exec `$BIN/singularity-portal`." That specific name
  is a **downstream wrapper**. Upstream, the portal binary (`xdg-desktop-portal-singularity`)
  is D-Bus-activated, not exec'd by the session script. The confirmed upstream bug is the
  **polkit agent** path — scope PR #10 to that and only mention the portal/auth-helper as
  the same install-dir class.
- `--force-fallback-for=wlroots-0.20` is upstream's own labwc handling, not an NCZ change —
  don't present it as a contribution.

## Upstream norms (from CONTRIBUTING.md / CLA.md — verified 2026-07-24)

- **License:** GPLv3-only. **CLA:** you agree by submitting a PR (retain copyright, grant
  license; contributions stay GPLv3-only).
- **Language:** Vala (GTK4). Build: meson + ninja; `vetro` (Go) is a build-time host tool.
- **Branches:** PR against `main`; `feat/<name>`, `fix/<name>`, `docs/<name>`, etc. One
  feature/fix per PR.
- **Commits:** Conventional Commits — `<type>: <subject>`, lowercase subject. Close issues
  with `<type>[closes #ID]: <title>` (e.g. `fix[closes #2]: ...`).
- **Do NOT add co-author or attribution trailers.** (Matches our own no-AI-footer rule.)
- **Questions/announcements → GitHub Discussions.** Bugs → Issues with OS + compositor
  version, repro steps, and `journalctl --user -u singularity-desktop -n 100`.
- Review tag: `@singularityos-lab/core`.

## Filing checklist (AFTER the ISO bakes — do not file before)

1. **Re-verify every claim on the release image**, not the build container. Re-run the
   libexec repro, the aarch64 build, and the GLES session on the baked ISO.
2. **Post `00-intro-issue.md` as a GitHub Discussion first.** Let it breathe.
3. **File PRs on a calm cadence — max 3-4/day to this upstream, spaced ~1h apart.** Order:
   `10` (libexec fix) → `20` (arm64 docs) → `30` (GLES note). Do the work up front; release
   it slowly. Bursty pushes read as automation and risk GitHub T&S.
4. **Identity on every commit:** `Jason Perlow <jperlow@gmail.com>`. Never `@nvidia.com`.
   **No `Co-Authored-By` / "Generated with" / any AI footer.** No `Signed-off-by` (repo
   doesn't use DCO).
5. **Human-style branch names** (`fix/session-libexec-path`, not a generated UUID). Present
   every PR as deliberate, careful human work: fill the PR body, paste real validation
   command output, engage reviewer comments specifically.
6. **Pin exact dependency/tool versions** in the arm64 docs PR before filing (Debian 13 /
   Ubuntu 26.04 package names actually verified).
7. **Squash to one focused commit per PR** with a conventional-commit subject.

## Verification provenance

All findings verified 2026-07-24 against the live upstream clone and NCZ build artifacts on
`.66` (`/home/jasonperlow/sinty-build/`): upstream git `40100fd`, meson 1.10.1, valac
0.56.18, aarch64. The libexec bug was confirmed by inspecting the staged install tree
(`stage/opt/singularity/libexec/singularity-polkit-agent` present; not in `bin/`) against
`singularity-desktop-session`'s `$BIN/singularity-polkit-agent` exec line.
