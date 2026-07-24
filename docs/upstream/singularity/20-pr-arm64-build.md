# PR draft — docs: arm64 / Debian-Ubuntu build support + vetro host tool

> **Branch:** `docs/arm64-debian-build`
> **Base:** `main`
> **Commit subject:** `docs: add aarch64 and Debian/Ubuntu build instructions`
> **No attribution/co-author trailers.**
> This is a **docs-only** PR — low risk. File it after the libexec fix.

---

## Summary

**What:** The build instructions in `CONTRIBUTING.md` are Fedora/Silverblue-only (`dnf`).
This PR adds (1) a Debian/Ubuntu dependency list, (2) an explicit statement that **aarch64
is supported and tested**, and (3) instructions for building **`vetro`** (the Go-based UI
transpiler) as a host tool when no distro package exists.

**Why:** Singularity builds cleanly on aarch64 with no source changes — the one thing
missing is documentation for non-Fedora and non-x86 builders. I brought it up on a Debian
arm64 distro (NCZ-OS, CIX Sky1) and the only friction was working out the dependency names
and the `vetro` bootstrap by hand.

**Scope boundary:** documentation only. No meson, source, or build-logic changes.

**Blast radius:** none — `CONTRIBUTING.md` only.

## Background: it already builds on aarch64

For the record, a clean build inside an `ubuntu:26.04` **aarch64** container:

```
Host machine cpu family: aarch64
Host machine cpu: aarch64
C compiler: gcc 15.2.0
Vala compiler: valac 0.56.18
Meson: 1.10.1
```

No architecture guards, no `#ifdef __aarch64__`, no arch-specific meson logic were needed.
The C Wayland bindings, the Vala shell, `libsingularity`, the portal, and the bundled
`labwc` + `wlroots` (0.20 fallback) all compile as-is. The value here is purely telling the
next arm64 builder "yes, this works, here's the dependency set."

## Proposed `CONTRIBUTING.md` additions

### 1. Debian / Ubuntu dependency list

Add alongside the existing Fedora block:

```bash
# Install dependencies (Debian / Ubuntu)
sudo apt install -y \
  valac meson ninja-build \
  libgtk-4-dev libadwaita-1-dev \
  libgtk4-layer-shell-dev \
  libwayland-dev wayland-protocols \
  libvte-2.91-gtk4-dev \
  libgtksourceview-5-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good gstreamer1.0-pipewire \
  libpulse-dev \
  libpolkit-gobject-1-dev libpolkit-agent-1-dev \
  libjson-glib-dev \
  libpeas-2-dev \
  libpipewire-0.3-dev \
  libgee-0.8-dev libgtk-4-unix-print-dev
```

> Note: exact package names are for Debian 13 / Ubuntu 26.04. On some releases the
> gtk4-layer-shell and libpeas-2 packages may be named differently or need a backport.
> (I'll pin these to the versions I actually verified before filing.)

### 2. Architecture support note

Add a short subsection:

```markdown
## Architecture support

Singularity builds and runs on both **x86_64** and **aarch64 (arm64)**. The aarch64 build
requires no source changes; it has been built and run on the CIX Sky1 (CD8180) SoC
(Radxa Orion O6N / MS-R1) in an `ubuntu:26.04` aarch64 container with meson 1.10.1 and
valac 0.56.18. See also the GLES-only / no-Vulkan notes if your GPU has no Vulkan driver.
```

### 3. Building the `vetro` host tool

`vetro` is a build-time host program (`find_program('vetro')`) used to transpile `.vetro`
UI files to `.ui` for `singularity-calculator`, `singularity-calendar`, and
`singularity-demo`. It lives in a separate repo (`singularityos-lab/vetro`, Go, MIT). On
distros without a `vetro` package it must be built and put on `PATH` before configuring:

```markdown
## Building vetro (UI transpiler host tool)

Some subprojects transpile `.vetro` files to `.ui` at build time using `vetro`. If your
distribution has no `vetro` package, build it from source (needs Go 1.24+) and put it on
your PATH before running `meson setup`:

    git clone https://github.com/singularityos-lab/vetro
    cd vetro && go build -o vetro .
    install -Dm755 vetro ~/.local/bin/vetro   # ensure ~/.local/bin is on PATH
```

## Validation evidence

- Full workspace build (top project + bundled labwc/wlroots) completed on aarch64 with the
  dependency set above; `meson install` produced a complete tree
  (`bin/ include/ lib/ libexec/ share/`, 34 MB).
- `vetro` built from source with `go build` and was picked up by `find_program('vetro')`.

(Validated on NCZ-OS 26.7, CIX Sky1, Radxa Orion O6N.)

## Compatibility

Additive documentation. Fedora instructions are untouched.

## Rollback

Revert the single docs commit.
