# Upstream contributions to Singularity Desktop — FILED 2026-08-09

Contributions from **NCZ-OS 26.7 "Maximilian"** back to
[`singularityos-lab/singularity-desktop`](https://github.com/singularityos-lab/singularity-desktop)
(project site: sinty.dev).

**Status: ALL THREE PRs FILED 2026-08-09** (operator directive, superseding the earlier
"hold until the ISO bakes" gate). Each was re-verified against upstream `d73dea5` at filing
time, not taken on faith from the drafts below.

| PR | Target | State |
|----|--------|-------|
| [singularity-session#5](https://github.com/singularityos-lab/singularity-session/pull/5) | `singularity-session`, base `main` | libexec fix — bug re-confirmed live before filing |
| [singularity-desktop#233](https://github.com/singularityos-lab/singularity-desktop/pull/233) | `singularity-desktop`, base `master` | Debian/arm64/vetro docs |
| [singularity-desktop#234](https://github.com/singularityos-lab/singularity-desktop/pull/234) | `singularity-desktop`, base `master` | GLES/no-Vulkan docs |

Also un-drafted [`sinty-nm#1`](https://github.com/singularityos-lab/sinty-nm/pull/1) (iwd
`FlagNoAutoStart`), which had sat as a **draft** since 2026-07-30 with zero reviewer
activity — draft PRs never enter a maintainer's review queue, which is almost certainly why
it got no response rather than any objection to the change.

### Corrections made at filing time

- **`30-pr-gles-no-vulkan` lost its code hook.** Upstream has since added a software-render
  retry in `singularity-labwc-session` (#78) that sets `WLR_RENDERER=pixman` itself, so the
  drafted passthrough became redundant. Filed as docs-only, and the page now documents that
  retry instead. Also moved to a standalone `docs/gpu-support.md` so it does not collide
  with #233's `CONTRIBUTING.md` edit.
- **`20-pr-arm64-build` shipped the proven apt list**, taken from `build/build-singularity.sh`
  (which actually completes an aarch64 container build), not the shorter drafted list. The
  draft was missing `libsoup-3.0-dev`, `gobject-introspection`, `libupower-glib-dev`,
  `libnm-dev`, `libgoa-1.0-dev`, `sassc`, `scdoc` and `hwdata`.

## Context

NCZ-OS 26.7 ships **Singularity as its default desktop** on the new **CIX Sky1 (CD8180)**
arm64 SoC (Mali-G720, GLES-only / no Vulkan), hardware-validated on **Radxa Orion O6N** and
**MS-R1**. Likely the first arm64 distro — and first on a Mali GLES-only SoC — to ship
Singularity by default. During bring-up we found a genuine bug and two documentation gaps
worth sending upstream.

## Files

| File | What | Filed as |
|------|------|----------|
| `10-pr-libexec-path.md` | Fix: session launcher execs polkit agent from `bin/` but meson installs it to `libexecdir` → silent exit-127 for any `libexecdir != bindir` prefix | [singularity-session#5](https://github.com/singularityos-lab/singularity-session/pull/5) |
| `20-pr-arm64-build.md` | Docs: Debian/Ubuntu deps + aarch64 support statement + `vetro` host-tool build | [singularity-desktop#233](https://github.com/singularityos-lab/singularity-desktop/pull/233) |
| `30-pr-gles-no-vulkan.md` | Docs: GLES-only / no-Vulkan GPU compatibility | [singularity-desktop#234](https://github.com/singularityos-lab/singularity-desktop/pull/234) |

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

## Filing conventions (applied to #5 / #233 / #234)

1. **Re-verify every claim against current upstream before filing** — not against the
   drafts. Done at `d73dea5`; this is what caught the now-redundant `WLR_RENDERER` hook and
   the incomplete apt list.
2. **Max 3-4 PRs/day to one upstream.** Bursty pushes read as automation and risk GitHub
   T&S. Filed 1 to `singularity-session`, 2 to `singularity-desktop`.
3. **Identity on every commit:** `Jason Perlow <jperlow@gmail.com>`. Never `@nvidia.com`.
   **No `Co-Authored-By` / "Generated with" / any AI footer.** No `Signed-off-by` (repo
   doesn't use DCO).
4. **Human-style branch names** (`fix/session-libexec-path`, not a generated UUID). Fill the
   PR body, paste real validation output, engage reviewer comments specifically.
5. **One focused commit per PR** with a conventional-commit subject.
6. **Base branch differs per repo** — `singularity-desktop` defaults to `master`,
   `singularity-session` and `singularity-shell` to `main`. Their `CONTRIBUTING.md` says to
   PR against `main` regardless; check the actual default before opening.

## Verification provenance

All findings verified 2026-07-24 against the live upstream clone and NCZ build artifacts on
`.66` (`/home/jasonperlow/sinty-build/`): upstream git `40100fd`, meson 1.10.1, valac
0.56.18, aarch64. The libexec bug was confirmed by inspecting the staged install tree
(`stage/opt/singularity/libexec/singularity-polkit-agent` present; not in `bin/`) against
`singularity-desktop-session`'s `$BIN/singularity-polkit-agent` exec line.
