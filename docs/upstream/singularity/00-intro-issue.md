# Intro / announcement (GitHub Discussion — "Show and tell" or General)

> **Filing target:** open this as a **GitHub Discussion**, not an Issue. CONTRIBUTING.md
> directs questions/announcements to Discussions. Post it first, before any PR, so the
> maintainers have context for the fixes that follow. Keep it warm and specific; no
> AI/bot phrasing.
>
> **Title:** `Singularity as the default desktop on a full arm64 distro (CIX Sky1 / Mali GLES-only)`

---

Hi folks,

I wanted to introduce myself and share where Singularity Desktop has ended up, because
I think it's a first and it might be interesting to you.

I maintain **NCZ-OS**, a small Debian-based Linux distribution for the new **CIX Sky1
(CD8180)** arm64 SoC. Our upcoming release, **26.7 "Maximilian"**, ships **Singularity
as the default desktop environment** — not as an optional session you install after the
fact, but as the desktop the ISO boots into out of the box, greeter and all.

As far as I can tell this makes NCZ-OS:

- likely the **first arm64 distribution to ship Singularity as its default desktop**, and
- likely the **first to run it on a Mali GLES-only / no-Vulkan GPU** (Arm **Mali-G720**,
  via the vendor `libmali` GLES driver).

### The hardware

- **SoC:** CIX Sky1 (CD8180), 12-core arm64, Mali-G720 GPU (GLES 3.x, **no Vulkan** —
  the platform simply has no Vulkan driver).
- **Boards validated:** **Radxa Orion O6N** and the **MS-R1**. Both are real, shipping
  CIX developer boards, and both run the default Singularity session end to end.

### How it runs

The stack is exactly yours — `labwc` + bundled `wlroots` (0.20 fallback subproject),
`libsingularity`, the shell, the portal, the polkit agent, the bundled apps. Rendering
works out of the box on GLES:

- GTK4 uses the **GL** renderer (`GSK_RENDERER=gl`, which your session already sets), so
  it never asks for Vulkan.
- `wlroots` auto-selects its **GLES2** renderer because no Vulkan renderer is present, and
  labwc comes up cleanly.

I was genuinely surprised how little arm64 friction there was. Singularity built cleanly
in an `ubuntu:26.04` **aarch64** container (meson 1.10.1, valac 0.56.18, gcc 15.2) with no
source patches — the codebase is already architecture-clean. The only real bumps were
(1) a `libexecdir`-vs-`bindir` path assumption in the session launcher, and (2) the fact
that the build docs are Fedora-only, so I had to work out the Debian/Ubuntu dependency set
and the `vetro` host-tool build myself.

### What I'd like to contribute back

I've got a few small, focused PRs ready that I'll open on a calm cadence after our ISO
bakes. In rough priority order:

1. **A real bug fix** — the session launcher execs the polkit agent from `bin/` but meson
   installs it to `libexecdir`, so a clean `meson install` to any prefix where
   `libexecdir != bindir` (e.g. `/usr` → `/usr/libexec`) silently fails to start the
   agent. Easy, self-contained fix.
2. **arm64 / Debian build docs** — the Debian/Ubuntu dependency list, a note that aarch64
   is supported and tested, and how to build the `vetro` transpiler as a host tool when
   there's no distro package for it.
3. **A GLES-only / no-Vulkan compatibility note** — documenting that Singularity runs on
   GLES-only GPUs like Mali, and an optional `WLR_RENDERER` override hook for boards where
   renderer auto-selection ever needs a nudge.

None of the NCZ-specific stuff (our `/opt` prefix, branding, GPU-env selector, display
manager choices) belongs upstream — I'll keep all of that downstream. These three are the
pieces I think are genuinely useful to everyone.

Two quick asks:

- Would you be open to these PRs? Happy to split or reshape them however you prefer.
- If you keep a list of distributions shipping Singularity, we'd be glad to be on it, and
  glad to help however's useful (testing on real CIX hardware, arm64 CI, etc.).

Thanks for building this — it's a genuinely nice desktop, and it's been a pleasure to get
it running on brand-new silicon.

— Jason Perlow (jperlow@gmail.com)
