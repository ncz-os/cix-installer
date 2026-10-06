#!/usr/bin/env python3
"""build/gen-components-registry.py

Generate manifests/components.tsv from ground truth.

Operator directive 2026-10-05 (Item C1, phase 1). Pure Python 3 stdlib;
deterministic output (stable sort keys, no timestamps); safe to re-run.
Phase 2 wires `build/components.py check --gate` into `make parity` and
`build/lint-platform.sh`. Phase 3 (`--render-seeds`, `--render-local-debs`,
`--render-allowlist`) rewrites the seed files and the NCZ_LOCAL_DEBS block
from this registry; `--check` exits 1 when a rewrite would change a file.

Ground truth sources (parsed from this tree):
  - manifests/*.pkgs (per-arch seed manifests + install-extra + firmware BOM)
  - NCZ_LOCAL_DEBS rows in build/build-desktop-mirror.sh (optional/required)
  - build/arch-parity-allowlist.tsv (reviewed arm64/amd64 manifest divergence)
  - assets/kernel/KERNEL-POLICY (DEFAULT_BASE, EDGE_ENABLED; EDGE_BASE is retired),
    assets/kernel/amd64-stable/KVER, assets/kernel/amd64-stable-manifest.json,
    assets/kernel/sky1-manifest.json
  - assets/kernel/t2{smc,gmux,smp,thunderbolt}/{dkms.conf,PROVENANCE}
  - post-install/*.sh install commands + hooks.list.{amd64,sky1-arm64}
    (hook-only installs that no manifest seeds)

Output columns (TSV, fixed order; '#' = comment, blank lines allowed):
  name | kind | source | arch | variant | required | version_floor |
  installed_by | verified_by | provenance | notes

The column header line is aligned with build/components.py:HEADER.

Author: Jason Perlow <jperlow@gmail.com>. No AI attribution
(commit-policy 2026-10-05).
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

HEADER = (
    "name\tkind\tsource\tarch\tvariant\trequired\tversion_floor\t"
    "installed_by\tverified_by\tprovenance\tnotes"
)

KINDS = (
    "debian",       # standard apt package from a configured archive
    "ncz-apt",      # custom NCZ-OS deb in the Buildkite/R2 apt repo
    "staged-deb",   # vendor/NCZ .deb staged under assets/ or a build dir
    "npm",          # npm install -g from a hook
    "dkms",         # DKMS module built per-kernel by a hook
    "kernel",       # kernel image + headers + modules
    "overlay",      # kernel overlay .ko for an accelerator
    "firmware",     # firmware blob staged under assets/
)

# Canonical variant order for the union column (deterministic output).
VARIANT_ORDER = ("desktop", "installer", "mgmt", "rescue", "server")

# ---------------------------------------------------------------------------
# Curated constants, each with its provenance. These encode facts that live
# OUTSIDE the tree (the published-apt state) or that the tree states only in
# prose; the drift report cites them.
# ---------------------------------------------------------------------------

# Published set per ~/Projects/oc-apt-publish/report.md ("Published
# artifacts" table, item AC, 2026-10-05). The AC report also notes the repo
# holds pre-AC packages (old Singularity versions, "other packages") that the
# table does not document.
AC_PUBLISHED = {
    "ncz-singularity-desktop",
    "ncz-screensavers",
    "ncz-screensavers-gtk4-reference",
}

# The Singularity screensaver settings plugin is NOT an apt seed and not in
# NCZ_LOCAL_DEBS: it is unpublished (AC report open question 5) and
# ABI-coupled to the Singularity payload stage 1 rebuilds, so the image ships
# a pinned deb on the install medium. Its row comes from the pin file.
SSPLUGIN_LOCK_REL = "post-install/lib/ncz-screensavers-plugin.lock"


def parse_ssplugin_lock(path):
    """KEY=VALUE pairs of the plugin pin, or {} when the file is absent."""
    out = {}
    if not path.exists():
        return out
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"')
    return out

# install-extra.pkgs rows that are plain Debian packages, not NCZ-apt.
# (The manifest's own comment: the installer's user-setup step runs
# `apt-get install sudo` in the target; finish-install/pkgsel reach for
# installation-report and popularity-contest.)
INSTALL_EXTRA_DEBIAN = {"sudo", "installation-report", "popularity-contest"}
INSTALL_EXTRA_REQUIRED = {"sudo"}

# Manifest basename -> (arch, variant union). install-extra is arch-neutral
# and feeds the offline INSTALL mirror, so it spans all five variants.
MANIFEST_ARCH_VARIANT = {
    "desktop.pkgs": ("arm64", "desktop"),
    "desktop-amd64.pkgs": ("amd64", "desktop"),
    "installer-base.pkgs": ("arm64", "desktop,installer,mgmt,rescue,server"),
    "installer-base-amd64.pkgs": ("amd64", "desktop,installer,mgmt,rescue,server"),
    "rescue.pkgs": ("arm64", "rescue"),
    "rescue-amd64.pkgs": ("amd64", "rescue"),
    "mgmt.pkgs": ("arm64", "mgmt"),
    "firmware.pkgs": ("all", "desktop,installer,mgmt,rescue,server"),
    "install-extra.pkgs": ("all", "desktop,installer,mgmt,rescue,server"),
}


def is_ncz_name(name):
    """True for NCZ-apt-namespace package names (custom-built debs).

    Covers ncz-*, *-ncz-* (chromium-ncz-sky1) and cix-* (CIX/Sky1
    proprietary). Plain Debian names (firmware-*, libdrm-*, sudo, ...)
    return False.
    """
    return (
        name.startswith(("ncz-", "cix-"))
        or "-ncz-" in name
    )


def variant_union(sets):
    u = set()
    for s in sets:
        u.update(s)
    return ",".join(v for v in VARIANT_ORDER if v in u)


def parse_pkgs(path):
    """Sorted plain package names from a *.pkgs manifest.

    Skips blank lines and '#' comments; strips trailing inline
    '# reason' suffixes from package lines.
    """
    out = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            line = line.split("#", 1)[0].rstrip()
            if line:
                out.append(line)
    return sorted(set(out))


def parse_ncz_local_debs(path):
    """NCZ_LOCAL_DEBS rows from build/build-desktop-mirror.sh.

    Returns list of dicts: name, glob, req (raw 'required'/'optional'),
    arch (from the glob's arch suffix; the arm64 if-block forces arm64 for
    _all.deb globs staged there).
    """
    out = []
    in_block = False
    arm64_block = False
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()
    for raw in lines:
        line = raw.rstrip("\n")
        if re.match(r'\s*if\s+\[\s*"\$ARCH"\s*=\s*arm64\s+\];\s*then\b', line):
            arm64_block = True
            continue
        if arm64_block and re.match(r"\s*fi\b", line):
            arm64_block = False
            continue
        if not in_block:
            if re.search(r"\bNCZ_LOCAL_DEBS\s*\+?=\s*\"", line):
                in_block = True
            else:
                continue
        else:
            if line.strip() == '"' or re.match(r"^\s*\"", line):
                in_block = False
                continue
        for tok in line.split():
            if tok.count("|") != 2:
                continue
            pkg, glob, req = tok.split("|")
            if not pkg or not glob:
                continue
            if "${ARCH}" in glob or glob.endswith("_all.deb"):
                arch = "arm64" if (arm64_block and glob.endswith("_all.deb")) else "all"
            elif "_arm64.deb" in glob:
                arch = "arm64"
            elif "_amd64.deb" in glob:
                arch = "amd64"
            else:
                arch = "all"
            out.append({"name": pkg, "glob": glob, "req": req, "arch": arch})
    return out


def parse_dkms_conf(path):
    name = ver = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        m = re.match(r'PACKAGE_NAME="([^"]*)"', line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r'PACKAGE_VERSION="([^"]*)"', line)
        if m:
            ver = m.group(1)
    return name, ver


# T1 (operator 2026-10-05, post-install/56-t2-dkms.sh). required is the
# install policy, not "the source tree exists":
#   t2smc, t2gmux   default DKMS set on T2 hardware
#   t2thunderbolt   opt-in only (NCZ_T2_DKMS_EXTRA); blacklisted otherwise
#   t2smp           dropped: in-kernel patch 9001 owns CPU-hotplug ordering;
#                   the hook always blacklists it, dkms-removes it, and
#                   deletes /usr/src/t2smp-*. The vendored tree stays for review.
T2_DKMS_POLICY = {
    "t2smc": (
        "yes",
        "Default T2 DKMS module (thermal/SMC). Built per-kernel on T2 hardware.",
    ),
    "t2gmux": (
        "yes",
        "Default T2 DKMS module (APP000B gmux). Built per-kernel on T2 hardware; apple_gmux blacklisted.",
    ),
    "t2thunderbolt": (
        "conditional:NCZ_T2_DKMS_EXTRA=t2thunderbolt",
        "Opt-in only (operator 2026-10-05). Blacklisted and dkms-removed unless NCZ_T2_DKMS_EXTRA=t2thunderbolt.",
    ),
    "t2smp": (
        "no",
        "Dropped (operator 2026-10-05). In-kernel patch 9001 owns Apple T2 CPU-hotplug ordering; hook writes ncz-t2smp.conf, dkms-removes t2smp, and deletes /usr/src/t2smp-*. Vendored source is not built.",
    ),
}


def parse_t2_dkms_modules(kernel_root):
    """DKMS rows for assets/kernel/t2{smc,gmux,smp,thunderbolt}."""
    rows = []
    for d in ("t2smc", "t2gmux", "t2smp", "t2thunderbolt"):
        sub = kernel_root / d
        dkms_conf = sub / "dkms.conf"
        if not dkms_conf.exists():
            continue
        name, ver = parse_dkms_conf(dkms_conf)
        if not name:
            continue
        required, policy_note = T2_DKMS_POLICY.get(d, ("yes", "Apple T2 DKMS module."))
        prov_file = sub / "PROVENANCE"
        if prov_file.exists():
            first = prov_file.read_text(encoding="utf-8").strip().splitlines()
            provenance = (
                f"assets/kernel/{d}/dkms.conf; assets/kernel/{d}/PROVENANCE "
                f"({first[0] if first else 'vendor record'}); post-install/56-t2-dkms.sh"
            )
        else:
            provenance = (
                f"assets/kernel/{d}/dkms.conf (no PROVENANCE file); "
                "post-install/56-t2-dkms.sh"
            )
            policy_note += " PROVENANCE file missing."
        rows.append({
            "name": name,
            "kind": "dkms",
            "source": f"vendored:assets/kernel/{d}",
            "arch": "amd64",
            "variant": "desktop,installer,mgmt,rescue,server",
            "required": required,
            "version_floor": ver or "",
            "installed_by": "post-install/56-t2-dkms.sh (dkms build/install)",
            "verified_by": "build/verify-dkms-modules.sh",
            "provenance": provenance,
            "notes": policy_note,
        })
    return rows


def _policy_kv(kernel_root):
    """KEY=value pairs from assets/kernel/KERNEL-POLICY (comments ignored)."""
    out = {}
    policy_path = kernel_root / "KERNEL-POLICY"
    if not policy_path.exists():
        return out
    for raw in policy_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        out[key.strip()] = val.strip()
    return out


def _load_json(path):
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def parse_kernel_entries(kernel_root):
    """Kernel rows from KERNEL-POLICY + the pinned per-arch manifests.

    Unified 7.3 policy (operator 2026-10-05): one kernel per arch, no EDGE
    channel. amd64-edge-kernel and sky1-edge-kernel are not emitted. The
    floor is the pinned KVER, not a reconstructed EDGE_BASE string.
    """
    rows = []
    policy = _policy_kv(kernel_root)
    default_base = policy.get("DEFAULT_BASE", "")
    edge_enabled = policy.get("EDGE_ENABLED", "0")
    amd64_manifest = _load_json(kernel_root / "amd64-stable-manifest.json")
    sky1_manifest = _load_json(kernel_root / "sky1-manifest.json")

    kver_path = kernel_root / "amd64-stable" / "KVER"
    kver = ""
    if kver_path.exists():
        kver = kver_path.read_text(encoding="utf-8").strip()
    kver = kver or amd64_manifest.get("kver", "")
    if kver:
        applied = (amd64_manifest.get("source") or {}).get("applied_patches") or []
        held = (amd64_manifest.get("source") or {}).get("held_not_applied") or []
        applied_s = ",".join(str(p) for p in applied) if applied else "see manifest"
        held_s = ",".join(str(p) for p in held) if held else "none"
        rows.append({
            "name": "amd64-stable-kernel",
            "kind": "kernel",
            "source": "vendored:assets/kernel/amd64-stable",
            "arch": "amd64",
            "variant": "desktop,installer,mgmt,rescue,server",
            "required": "yes",
            "version_floor": kver,
            "installed_by": "post-install/10-amd64-kernel.sh",
            "verified_by": "build/verify-base-kernel-assets.sh,build/verify-kernel-default-policy.sh",
            "provenance": (
                "assets/kernel/amd64-stable/KVER; "
                "assets/kernel/amd64-stable-manifest.json; "
                "assets/kernel/KERNEL-POLICY (DEFAULT_BASE, EDGE_ENABLED=0)"
            ),
            "notes": (
                f"Default + installer + rescue kernel on amd64 ({kver}). "
                f"Applied patches include {applied_s}; held (not applied) {held_s}. "
                "No EDGE channel (EDGE_ENABLED="
                f"{edge_enabled})."
            ),
        })

    sky1_kver = sky1_manifest.get("kver", "")
    sky1_rev = sky1_manifest.get("build_rev", "")
    if not sky1_kver and default_base:
        sky1_kver = f"{default_base}.0-rc6-sky1-ncz"
    mainline_path = kernel_root / "mainline"
    if sky1_kver or mainline_path.exists() or default_base:
        rev_note = f" build_rev={sky1_rev}." if sky1_rev else ""
        rows.append({
            "name": "sky1-mainline-kernel",
            "kind": "kernel",
            "source": "vendored:assets/kernel/mainline",
            "arch": "arm64",
            "variant": "desktop,installer,mgmt,rescue,server",
            "required": "yes",
            "version_floor": sky1_kver,
            "installed_by": "post-install/10-our-kernel.sh",
            "verified_by": "build/verify-base-kernel-assets.sh,build/verify-kernel-default-policy.sh",
            "provenance": (
                "assets/kernel/sky1-manifest.json; "
                "assets/kernel/mainline (symlink -> NFS kernel staging); "
                "assets/kernel/KERNEL-POLICY (DEFAULT_BASE, EDGE_ENABLED=0)"
            ),
            "notes": (
                "Default + installer + rescue kernel on Sky1/arm64"
                f" ({sky1_kver}).{rev_note} No EDGE channel. Symlink target "
                "lives outside the repo."
            ),
        })
    # EDGE_ENABLED=0: do not emit amd64-edge-kernel or sky1-edge-kernel.
    # The overlay manifest rides along so parse_overlay_rows can cite it.
    return rows, sky1_manifest


def parse_overlay_rows(kernel_root, sky1_manifest):
    """Overlay .ko rows from sky1-manifest.json overlays_mirrored only.

    Keys are 'assets/kernel/<drv>/<kver>/<ko>'. (The artifacts section also
    holds 'overlays/<drv>/<kver>/<ko>' sha256 entries; those are the same
    files under a different prefix and must not be double-counted.) These
    are the pinned default-kernel overlays (S7, r285), not an EDGE channel.
    """
    rows = []
    rev = sky1_manifest.get("build_rev", "")
    mirrored = sky1_manifest.get("overlays_mirrored", {})
    installed_by = {
        "mali": "post-install/82-mali-gpu.sh",
        "panthor": "post-install/83-panthor-gpu.sh",
        "vpu": "post-install/81-vpu.sh",
        "npu": "post-install/80-npu.sh",
    }
    for key in sorted(mirrored):
        m = re.match(r"^assets/kernel/([^/]+)/([^/]+)/([^/]+)$", key)
        if not m:
            continue
        drv, row_kver, ko = m.groups()
        rows.append({
            "name": f"{drv}-{ko.removesuffix('.ko')}",
            "kind": "overlay",
            "source": f"vendored:{key}",
            "arch": "arm64",
            "variant": "desktop,mgmt,rescue,server",
            "required": "yes",
            "version_floor": row_kver,
            "installed_by": installed_by.get(drv, "post-install/86-cix-dkms-register.sh"),
            "verified_by": "build/verify-overlay-modversions.py,build/verify-overlays.py",
            "provenance": (
                f"assets/kernel/sky1-manifest.json (overlays_mirrored: {key}"
                + (f", build_rev={rev}" if rev else "")
                + ")"
            ),
            "notes": (
                f"Pinned Sky1 default-kernel overlay for {drv}"
                + (f" ({rev})" if rev else "")
                + "; no EDGE channel."
            ),
        })
    return rows, sky1_manifest.get("kver", "")


# Curated rows for hook-only installs (no manifest seeds them). Ground truth:
# the install command in the named hook; arch from hooks.list.{amd64,sky1-arm64};
# runtime gates (T2 detection, NPU presence) recorded in notes.
HOOK_ONLY_ROWS = [
    {
        "name": "apple-firmware-script",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/55-t2-firmware.sh (apt-get install)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/55-t2-firmware.sh",
        "notes": "T2-gated (is_t2_hardware); Apple T2 firmware tooling from the forky suite.",
    },
    {
        "name": "apple-t2-audio-config",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/55-t2-firmware.sh (apt-get install)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/55-t2-firmware.sh",
        "notes": "T2-gated (is_t2_hardware); T2 HDA audio configuration package.",
    },
    {
        "name": "dmg2img",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/55-t2-firmware.sh (conditional)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/55-t2-firmware.sh",
        "notes": "Only when extracting the T2 Recovery Image (.dmg) for firmware blobs.",
    },
    {
        "name": "systemd-coredump",
        "kind": "debian", "source": "debian-forky",
        "arch": "all", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/20-desktop.sh (apt-get install, best-effort || true)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/20-desktop.sh (diagnostics section)",
        "notes": "Desktop-session crash traceability (replaces the apport core-dump handler).",
    },
    {
        "name": "systemd-container",
        "kind": "debian", "source": "debian-forky",
        "arch": "all", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "yes", "version_floor": "",
        "installed_by": "post-install/38-recovery-container.sh (apt-get install)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/38-recovery-container.sh",
        "notes": "Host nspawn runtime for the recovery container (offline from the embedded server-mirror).",
    },
    {
        "name": "wpasupplicant",
        "kind": "debian", "source": "debian-forky",
        "arch": "all", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/33-network.sh (conditional fallback)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/33-network.sh",
        "notes": "Fallback wireless install when the driver firmware closure is incomplete.",
    },
    {
        "name": "aarch64-linux-gnu-gcc",
        "kind": "debian", "source": "debian-forky",
        "arch": "arm64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/79-dkms-prep.sh (conditional, missing-toolchain only)",
        "verified_by": "build/verify-dkms-modules.sh",
        "provenance": "post-install/79-dkms-prep.sh",
        "notes": "Cross-compiler for Sky1 kernel module rebuilds; installed only when the toolchain probe fails.",
    },
    {
        "name": "cix-noe-umd",
        "kind": "staged-deb",
        "source": "staged:assets/cix-debs/cix-noe-umd_*_${ARCH}.deb",
        "arch": "arm64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/88-noe-umd-venv.sh (apt from offline mirror, best-effort || true)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/88-noe-umd-venv.sh; build/build-gst-cix.sh ('cix-noe-umd ... which is not published'); build/stage-canonical-assets.sh (3.1.4 matched-stack pin)",
        "notes": "CIX NPU userspace (libnoe + wheels). NOT published to the NCZ apt repo; resolved from the offline vendor-mirror pool.",
    },
    {
        "name": "intel-driver-compiler-npu",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/54-gpu-accel.sh (HAS_INTEL_NPU gated)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/54-gpu-accel.sh (Intel OpenVINO repo block)",
        "notes": "Installed at runtime from apt.repos.intel.com/openvino (keyring intel-openvino.gpg); source label debian-forky is the nearest approved value (format gap, see drift report 2026-10-06).",
    },
    {
        "name": "intel-level-zero-npu",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/54-gpu-accel.sh (HAS_INTEL_NPU gated)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/54-gpu-accel.sh (Intel OpenVINO repo block)",
        "notes": "Installed at runtime from apt.repos.intel.com/openvino; source label approximate (format gap, see drift report 2026-10-06).",
    },
    {
        "name": "level-zero",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/54-gpu-accel.sh (HAS_INTEL_NPU gated)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/54-gpu-accel.sh (Intel OpenVINO repo block)",
        "notes": "Installed at runtime from apt.repos.intel.com/openvino; source label approximate (format gap, see drift report 2026-10-06).",
    },
    {
        "name": "openvino",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/54-gpu-accel.sh (HAS_INTEL gated)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/54-gpu-accel.sh (Intel OpenVINO repo block)",
        "notes": "Installed at runtime from apt.repos.intel.com/openvino; source label approximate (format gap, see drift report 2026-10-06).",
    },
    {
        "name": "intel-opencl-icd",
        "kind": "debian", "source": "debian-forky",
        "arch": "amd64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/54-gpu-accel.sh (HAS_INTEL gated)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "post-install/54-gpu-accel.sh (Intel OpenVINO repo block)",
        "notes": "Installed at runtime from apt.repos.intel.com/openvino; source label approximate (format gap, see drift report 2026-10-06).",
    },
]

# Vendor staged .debs that no manifest seeds and that are NOT in NCZ_LOCAL_DEBS.
VENDOR_DEB_ROWS = [
    {
        "name": "vivaldi-stable",
        "kind": "staged-deb",
        "source": "staged:assets/vivaldi/vivaldi-stable_*_${ARCH}.deb",
        "arch": "all", "variant": "desktop",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/52-vivaldi.sh (dpkg -i staged .deb)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "assets/vivaldi/ (vendor .debs, archived); post-install/52-vivaldi.sh",
        "notes": "Default browser (x-www-browser + xdg mime). Skipped on server/headless variants.",
    },
    {
        "name": "google-chrome-stable",
        "kind": "staged-deb",
        "source": "staged:build/forky-vendor-mirror/google-chrome-stable_*_${ARCH}.deb",
        "arch": "all", "variant": "desktop",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/53-chrome.sh (apt from the offline forky-vendor-mirror)",
        "verified_by": "build/verify-installed-target.sh",
        "provenance": "build/forky-vendor-mirror (pinned Google .deb, SHA256-verified); build/build-vendor-mirror.sh; manifests/desktop.pkgs; manifests/desktop-amd64.pkgs",
        "notes": "Second browser; Vivaldi stays default. Real arm64 Linux Chrome landed Q2 2026.",
    },
    {
        "name": "cixmini-boot",
        "kind": "staged-deb",
        "source": "staged:kernel-staging/<kver>/debs/cixmini-boot_*_arm64.deb",
        "arch": "arm64", "variant": "installer,desktop,mgmt,rescue,server",
        "required": "yes", "version_floor": "",
        "installed_by": "manifest (installer-base.pkgs) resolved via build/build-vendor-mirror.sh pool",
        "verified_by": "build/verify-offline-mirror-seeds.sh",
        "provenance": "manifests/installer-base.pkgs; build/build-vendor-mirror.sh (KERNEL_DEBS publish); assets/kernel/sky1-manifest.json (debs/cixmini-boot)",
        "notes": "cixmini bootloader glue; built per kernel release; Depends: ncz-usb-recovery.",
    },
    {
        "name": "linux-image-cixmini",
        "kind": "staged-deb",
        "source": "staged:kernel-staging/<kver>/debs/linux-image-cixmini_*_arm64.deb",
        "arch": "arm64", "variant": "installer,desktop,mgmt,rescue,server",
        "required": "yes", "version_floor": "",
        "installed_by": "manifest (installer-base.pkgs) resolved via build/build-vendor-mirror.sh pool",
        "verified_by": "build/verify-offline-mirror-seeds.sh",
        "provenance": "manifests/installer-base.pkgs; build/build-vendor-mirror.sh (KERNEL_DEBS publish); assets/kernel/sky1-manifest.json (debs/linux-image-cixmini)",
        "notes": "cixmini kernel image deb; the sky1-mainline-kernel row carries the version floor.",
    },
]

VENDOR_DEB_ROW_NAMES = {r["name"] for r in VENDOR_DEB_ROWS}

NPM_ROWS = [
    {
        "name": "@anthropic-ai/claude-code",
        "kind": "npm",
        "source": "npm:@anthropic-ai/claude-code",
        "arch": "all", "variant": "desktop,mgmt,rescue,server",
        "required": "no", "version_floor": "",
        "installed_by": "post-install/40-claude-code.sh (npm install -g after nodejs npm)",
        "verified_by": "post-install/40-claude-code.sh (claude --version)",
        "provenance": "post-install/40-claude-code.sh",
        "notes": "Operator-side dev CLI; not wired into any NCZ agent runtime (fleet directive).",
    },
]

FIRMWARE_ROWS = [
    {
        "name": "apple-t2-firmware-sonoma14",
        "kind": "firmware",
        "source": "staged:assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz",
        "arch": "amd64", "variant": "desktop,mgmt,rescue",
        "required": "yes", "version_floor": "",
        "installed_by": "post-install/55-t2-firmware.sh (extract to /lib/firmware/brcm/)",
        "verified_by": "post-install/55-t2-firmware.sh (brcmfmac*.apple,*.bin check)",
        "provenance": "assets/firmware/apple-t2/ (gitignored; extracted from a 753 MB macOS Sonoma 14 Recovery Image)",
        "notes": "Apple WiFi/BT firmware for T2 Macs (brcmfmac4355c1/4364b2/4364b3/4377b3). Network fallback only when the asset is missing.",
    },
    {
        "name": "sky1-firmware-blobs",
        "kind": "firmware",
        "source": "staged:assets/sky1-firmware/",
        "arch": "arm64", "variant": "desktop,installer,mgmt,rescue,server",
        "required": "yes", "version_floor": "",
        "installed_by": "post-install/12-sky1-firmware.sh (mali_csffw, dsp_fw, *.fwb to /lib/firmware)",
        "verified_by": "build/verify-assets.sh",
        "provenance": "assets/sky1-firmware/ (gitignored SoC blobs; restaged by build/stage-canonical-assets.sh)",
        "notes": "CIX Sky1 SoC firmware. Real blobs are not in the repo.",
    },
]


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--root", default=str(ROOT),
                    help="repo root (default: %(default)s)")
    ap.add_argument("--out", default=None,
                    help="output TSV path (default: <root>/manifests/components.tsv)")
    ap.add_argument("--render-seeds", action="store_true",
                    help="rewrite manifests/*.pkgs package lines from the registry")
    ap.add_argument("--render-local-debs", action="store_true",
                    help="rewrite NCZ_LOCAL_DEBS data lines from the registry")
    ap.add_argument("--render-allowlist", action="store_true",
                    help="confirm arch-parity-allowlist.tsv agrees with the registry")
    ap.add_argument("--check", action="store_true",
                    help="with a --render-*: exit 1 if a rewrite would change a file")
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    if args.render_seeds or args.render_local_debs or args.render_allowlist:
        rc = 0
        if args.render_seeds:
            rc |= cmd_render_seeds(root, args.check)
        if args.render_local_debs:
            rc |= cmd_render_local_debs(root, args.check)
        if args.render_allowlist:
            rc |= cmd_render_allowlist(root, args.check)
        return rc
    out_path = Path(args.out).resolve() if args.out else root / "manifests" / "components.tsv"

    all_rows = []

    # S4 version floor: one file, every consumer sources it. Empty when the
    # file is absent so a fixture that has no screensaver policy still emits.
    ss_floor = ""
    ss_env = root / "build" / "screensavers-version.env"
    if ss_env.exists():
        for raw in ss_env.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("NCZ_SCREENSAVERS_MIN_VERSION="):
                ss_floor = line.split("=", 1)[1].strip().strip('"').strip("'")

    # 0. Parse NCZ_LOCAL_DEBS FIRST: manifest rows for pool-served packages
    #    (libdrm-* etc.) must not duplicate the authoritative pool row.
    ncz_deb_rows = []
    bdm = root / "build" / "build-desktop-mirror.sh"
    if bdm.exists():
        ncz_deb_rows = parse_ncz_local_debs(bdm)
    ncz_deb_names = {r["name"] for r in ncz_deb_rows}
    # Which manifests seed each pool name (for the pool row's provenance).
    manifest_by_name = {}
    for fname in sorted(MANIFEST_ARCH_VARIANT):
        mpath = root / "manifests" / fname
        if mpath.exists():
            for pkg in parse_pkgs(mpath):
                manifest_by_name.setdefault(pkg, []).append(fname)

    # 1. plain apt packages per manifest.
    for fname, (arch, variant) in sorted(MANIFEST_ARCH_VARIANT.items()):
        path = root / "manifests" / fname
        if not path.exists():
            print(f"WARN: missing manifest {path}", file=sys.stderr)
            continue
        pkgs = parse_pkgs(path)
        for pkg in pkgs:
            ncz = is_ncz_name(pkg)
            if not ncz and pkg in ncz_deb_names:
                # libdrm-*: the NCZ_LOCAL_DEBS staged pool is the resolution
                # source (NCZ-patched 2.4.134-3+ncz, not forky); the pool
                # row is authoritative and cites the manifest.
                continue
            if pkg in VENDOR_DEB_ROW_NAMES:
                # cixmini-boot / linux-image-cixmini: kernel-build debs
                # served from the vendor-mirror pool, not forky packages;
                # the curated staged-deb row is authoritative.
                continue
            if ncz:
                kind, source = "ncz-apt", "buildkite-packages"
                if pkg not in AC_PUBLISHED:
                    notes = (
                        "NCZ apt name; NOT in the item AC published-artifacts "
                        "table (pre-AC publication or unpublished) -- diff-published "
                        "and the drift report track this."
                    )
                else:
                    notes = "Published per item AC (2026-10-05); Buildkite primary + R2 mirror."
                if pkg == "ncz-screensavers" and fname == "install-extra.pkgs":
                    notes += (
                        " Desktop variants require the staged pool copy at "
                        "NCZ_SCREENSAVERS_MIN_VERSION; this apt row is the "
                        "published name, not the pool required-flag."
                    )
            else:
                kind, source = "debian", "debian-forky"
                notes = ""
            if fname == "install-extra.pkgs" and pkg in INSTALL_EXTRA_DEBIAN:
                kind, source, notes = "debian", "debian-forky", (
                    "Offline install-mirror seed; a post-install hook installs it "
                    "(not a base/desktop closure package)."
                )
            required = (
                "no"
                if fname == "install-extra.pkgs" and pkg not in INSTALL_EXTRA_REQUIRED
                else "yes"
            )
            verified_by = (
                "build/verify-packages.sh"
                if ("desktop" in fname or "installer-base" in fname)
                else "build/verify-offline-mirror-seeds.sh"
            )
            all_rows.append({
                "name": pkg,
                "kind": kind,
                "source": source,
                "arch": arch,
                "variant": variant,
                "required": required,
                "version_floor": ss_floor if pkg == "ncz-screensavers" else "",
                "installed_by": "manifest",
                "verified_by": verified_by,
                "provenance": f"manifests/{fname}" + ("; NCZ apt repo" if kind == "ncz-apt" else ""),
                "notes": notes,
            })

    # 2. NCZ_LOCAL_DEBS rows (staged pool in build/desktop-mirror).
    #    Kind is staged-deb for every pool row: the component reaches the
    #    image from a staged .deb, regardless of whether the same name also
    #    has an ncz-apt/buildkite-packages row (one row per install path).
    for row in ncz_deb_rows:
        name = row["name"]
        required = "yes" if row["req"] == "required" else "no"
        base_note = {
            "ncz-singularity-desktop": "20-desktop.sh: staged-deb first, apt fallback (FATAL on amd64 if neither).",
            "ncz-screensavers": (
                "59-ncz-screensavers-pkg.sh; mandatory on desktop variants "
                "(operator 2026-10-05). Floor is NCZ_SCREENSAVERS_MIN_VERSION. "
                "The settings plugin is its own row (pinned medium deb)."
            ),
            "ncz-usb-recovery": (
                "41-usb2-rescan.sh (apt from the offline vendor-mirror pool); "
                "arm64-only (never published to an amd64 mirror); cixmini-boot Depends on it."
            ),
        }.get(name, "")
        libdrm_note = (
            "NCZ libdrm 2.4.134-3+ncz (Sky1 ACPI platform fix); built by "
            "build/build-libdrm-debs.sh."
            if name.startswith("libdrm") else ""
        )
        notes = "; ".join(x for x in (
            f"NCZ_LOCAL_DEBS: {row['req']}",
            base_note,
            libdrm_note,
        ) if x)
        installed_by = {
            "ncz-singularity-desktop": "post-install/20-desktop.sh",
            "ncz-screensavers": "post-install/59-ncz-screensavers-pkg.sh",
            "ncz-usb-recovery": "post-install/41-usb2-rescan.sh",
        }.get(name, "build/build-desktop-mirror.sh (pool staging; apt resolver installs)")
        verified_by = {
            "ncz-usb-recovery": "build/verify-installed-target.sh",
        }.get(name, "build/verify-desktop-mirror-seeds.sh")
        provenance = "build/build-desktop-mirror.sh (NCZ_LOCAL_DEBS)"
        if name in manifest_by_name:
            provenance += "; " + "; ".join(f"manifests/{m}" for m in manifest_by_name[name])
        all_rows.append({
            "name": name,
            "kind": "staged-deb",
            "source": f"staged:{row['glob'].split('$REPO/')[-1]}",
            "arch": row["arch"],
            "variant": "desktop,installer,mgmt,rescue,server",
            "required": required,
            "version_floor": (
                "2.4.134-3+ncz" if name.startswith("libdrm")
                else (ss_floor if name == "ncz-screensavers" else "")
            ),
            "installed_by": installed_by,
            "verified_by": verified_by,
            "provenance": provenance,
            "notes": notes,
        })

    # 2b. The Singularity screensaver settings plugin (pinned medium deb).
    pin = parse_ssplugin_lock(root / SSPLUGIN_LOCK_REL)
    if pin:
        all_rows.append({
            "name": pin["NCZ_SSPLUGIN_PKG"],
            "kind": "staged-deb",
            "source": (f"staged:build/ncz-screensavers-out/"
                       f"{pin['NCZ_SSPLUGIN_PKG']}_*_${{ARCH}}.deb"),
            "arch": "all",
            "variant": "desktop",
            "required": "yes",
            "version_floor": pin["NCZ_SSPLUGIN_VERSION"],
            "installed_by": "post-install/59-ncz-screensavers-pkg.sh",
            "verified_by": "build/check-ssplugin-abi.sh,build/verify-installed-target-screensavers-default.sh",
            "provenance": (f"{SSPLUGIN_LOCK_REL} (ARGONAS "
                           f"{pin['NCZ_SSPLUGIN_ARGONAS_DIR']}); "
                           "build/stage-screensaver-plugin.sh; docs/SCREENSAVER-PLUGIN.md"),
            "notes": (
                "Singularity Screensaver and Lockscreen settings page. Not published "
                "to the NCZ apt set (item AC open question 5); pinned sha256 per arch, "
                "carried on the install medium (ncz-payload/assets/ncz-screensavers-plugin), "
                "installed only over the Singularity payload it was linked against "
                "(version or byte-identical libsingularity)."
            ),
        })

    # 3. Vendor staged .debs (not in NCZ_LOCAL_DEBS, not seeded).
    for row in VENDOR_DEB_ROWS:
        if row["name"] in ncz_deb_names:
            continue
        all_rows.append(dict(row))

    # 4. Hook-only installs.
    for row in HOOK_ONLY_ROWS:
        all_rows.append(dict(row))

    # 5. T2 DKMS modules.
    all_rows.extend(parse_t2_dkms_modules(root / "assets" / "kernel"))

    # 6. Kernel entries + overlays (sky1-manifest.json).
    kernel_rows, edge_data = parse_kernel_entries(root / "assets" / "kernel")
    all_rows.extend(kernel_rows)
    overlay_rows, _ = parse_overlay_rows(root / "assets" / "kernel", edge_data)
    all_rows.extend(overlay_rows)

    # 7. npm.
    all_rows.extend(dict(r) for r in NPM_ROWS)

    # 8. Firmware blobs.
    all_rows.extend(dict(r) for r in FIRMWARE_ROWS)

    # Sort: name, kind order, arch, variant, required (deterministic).
    KIND_ORDER = {k: i for i, k in enumerate(KINDS)}

    def sort_key(r):
        return (
            r["name"].lower(),
            KIND_ORDER.get(r["kind"], 99),
            r["arch"],
            r["variant"],
            r["required"],
            r["source"],
        )

    # Dedup: one row per (name, kind, source, arch). Variants are unioned;
    # the tighter required wins (yes > no).
    def variant_set(s):
        return {v.strip() for v in (s or "").split(",") if v.strip()}

    # Normalize variant ordering on every row (deterministic column output).
    for r in all_rows:
        r["variant"] = variant_union([variant_set(r["variant"])]) or r["variant"]

    seen = {}
    for r in all_rows:
        key = (r["name"], r["kind"], r["source"], r["arch"])
        if key not in seen:
            row = dict(r)
            row["_prov_parts"] = [r["provenance"]] if r.get("provenance") else []
            seen[key] = row
            continue
        old = seen[key]
        old["variant"] = variant_union([variant_set(old["variant"]), variant_set(r["variant"])])
        if r["required"] == "yes" and old["required"] != "yes":
            old["required"] = "yes"
        if r.get("notes") and r["notes"] not in old.get("notes", ""):
            old["notes"] = "; ".join(x for x in (old.get("notes", ""), r["notes"]) if x)
        if r.get("provenance") and r["provenance"] not in old["_prov_parts"]:
            old["_prov_parts"].append(r["provenance"])

    # Finalize provenance order-independently: when a key was contributed by
    # more than one source row, the union of citations is sorted, so the
    # output does not depend on the order all_rows happened to be built in.
    for row in seen.values():
        parts = row.pop("_prov_parts", [])
        row["provenance"] = "; ".join(sorted(set(parts))) if parts else ""

    final = sorted(seen.values(), key=sort_key)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("# manifests/components.tsv -- NCZ-OS component registry (Item C1, phase 1)\n")
        f.write("#\n")
        f.write("# Operator directive 2026-10-05. TSV; one component per row. Generated by\n")
        f.write("# build/gen-components-registry.py from manifests/*.pkgs + NCZ_LOCAL_DEBS\n")
        f.write("# + KERNEL-POLICY + sky1-manifest.json + amd64-stable-manifest.json +\n")
        f.write("# post-install hook installs; audited by `build/components.py check`.\n")
        f.write("#\n")
        f.write("# Columns:\n")
        f.write("#   name            package name, or curated identifier for kernel / DKMS /\n")
        f.write("#                    overlay / firmware / npm rows.\n")
        f.write("#   kind            debian | ncz-apt | staged-deb | npm | dkms | kernel |\n")
        f.write("#                    overlay | firmware\n")
        f.write("#   source          debian-forky | buildkite-packages | r2 |\n")
        f.write("#                    staged:<path> | npm:<pkg> | vendored:<path>\n")
        f.write("#   arch            all | arm64 | amd64\n")
        f.write("#   variant         comma-list of desktop,installer,mgmt,rescue,server,\n")
        f.write("#                    or 'all'\n")
        f.write("#   required        yes | no | conditional:<cond>\n")
        f.write("#   version_floor   minimum acceptable version (semver-ish or kver); empty\n")
        f.write("#                    if not applicable\n")
        f.write("#   installed_by    hook or build script, or 'manifest' (install implicit\n")
        f.write("#                    in the apt resolver)\n")
        f.write("#   verified_by     verify*/check* script(s) that audit the install\n")
        f.write("#   provenance      source-of-truth path(s) or doc\n")
        f.write("#   notes           free-form, single line, no tabs\n")
        f.write("#\n")
        f.write("# Phases: phase 1 seeded this registry; phase 2 enforces required/floor/arch\n")
        f.write("# (K2 aer9011, T1 DKMS policy, S4 screensaver floor, S7 r285 overlays);\n")
        f.write("# phase 3 generates seed files and mirror rows from this registry.\n")
        f.write(HEADER + "\n")
        for r in final:
            notes = (r.get("notes") or "").replace("\t", " ").replace("\n", " ")
            fields = [
                r["name"], r["kind"], r["source"], r["arch"], r["variant"],
                r["required"], r["version_floor"], r["installed_by"],
                r["verified_by"],
                (r.get("provenance") or "").replace("\t", " "),
                notes,
            ]
            f.write("\t".join(fields) + "\n")

    print(f"wrote {len(final)} rows -> {out_path}")
    return 0


def _pkgs_names(path):
    """Package names in file order, comments and blanks skipped."""
    names = []
    if not path.exists():
        return names
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        names.append(line.split("#", 1)[0].strip())
    return names


def _seed_names_for(rows, fname):
    """Registry names whose provenance cites manifests/<fname>, file-stable order.

    google-chrome-stable is a staged-deb row (the vendor mirror), not a
    debian seed row, but both desktop manifests list it. Include it when
    the existing file does, so a regen does not drop a real seed.
    """
    cited = []
    marker = f"manifests/{fname}"
    for r in rows:
        if marker in (r.get("provenance") or "") and r["name"] not in cited:
            cited.append(r["name"])
    return cited


def render_pkgs(existing_text, names):
    """Rewrite package-name lines; keep every comment and blank line.

    The hand-written seeds interleave section comments with package
    names. Those comments are the byte-identity target, so they stay
    where they are. Only a non-comment, non-blank line is a package
    line, and it is replaced by the next name from ``names`` (which the
    caller has already ordered to match the file when the sets agree).
    A file with no package lines yet gets the names appended.
    """
    nl = "\n"
    if existing_text.startswith("\r") or "\r\n" in existing_text[:200]:
        nl = "\r\n"
    out = []
    pending = list(names)
    for raw in existing_text.splitlines():
        s = raw.strip()
        if s and not s.startswith("#"):
            if not pending:
                continue
            name = pending.pop(0)
            # Keep a trailing inline comment AND its padding. installer-base.pkgs
            # and rescue.pkgs align comments with runs of spaces; collapsing
            # them would fail the byte-identity check for no data change.
            if "#" in raw:
                out.append(name + raw[len(raw.split("#", 1)[0].rstrip()):])
            else:
                out.append(name)
        else:
            out.append(raw)
    out.extend(pending)
    text = nl.join(out)
    if not existing_text or existing_text.endswith(("\n", "\r\n")):
        text += nl
    return text


def cmd_render_seeds(root, check_only):
    """Rewrite manifests/*.pkgs package lines from the registry.

    Fails (exit 1) when the generated name set would differ from the
    file on disk. That is the byte-identity guard: phase 3 must not
    silently drop or add a seed. Comment headers are preserved, so a
    clean tree is not rewritten when the name set already matches.
    """
    reg_path = root / "manifests" / "components.tsv"
    rows = []
    for raw in reg_path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith(("#", "name\t")):
            continue
        cols = raw.split("\t")
        if len(cols) < 10:
            continue
        rows.append({"name": cols[0], "provenance": cols[9]})
    failed = 0
    for fname in sorted(MANIFEST_ARCH_VARIANT):
        path = root / "manifests" / fname
        if not path.exists():
            print(f"render-seeds: missing {path}", file=sys.stderr)
            failed += 1
            continue
        existing = _pkgs_names(path)
        generated = _seed_names_for(rows, fname)
        # Same names, possibly different order. The hand-written files are
        # the byte-identity target, so keep their order when the sets match.
        # A name the registry adds (or the file drops) is still a failure.
        if set(existing) == set(generated):
            generated = list(existing)
        if existing != generated:
            only_file = [n for n in existing if n not in generated]
            only_reg = [n for n in generated if n not in existing]
            print(f"render-seeds: {fname} name set differs "
                  f"(file-only={only_file or '-'} registry-only={only_reg or '-'})",
                  file=sys.stderr)
            failed += 1
            continue
        new_text = render_pkgs(path.read_text(encoding="utf-8"), generated)
        if new_text != path.read_text(encoding="utf-8"):
            if check_only:
                print(f"render-seeds: {fname} would change (name set matches; "
                      f"header/order rewrite)", file=sys.stderr)
                failed += 1
            else:
                path.write_text(new_text, encoding="utf-8")
                print(f"render-seeds: rewrote {fname}")
        else:
            print(f"render-seeds: {fname} unchanged")
    return 1 if failed else 0


def _registry_rows(root):
    rows = []
    reg_path = root / "manifests" / "components.tsv"
    for raw in reg_path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith(("#", "name\t")):
            continue
        cols = raw.split("\t")
        if len(cols) < 11:
            continue
        rows.append({
            "name": cols[0], "kind": cols[1], "source": cols[2],
            "arch": cols[3], "variant": cols[4], "required": cols[5],
            "version_floor": cols[6], "installed_by": cols[7],
            "verified_by": cols[8], "provenance": cols[9], "notes": cols[10],
        })
    return rows


def _mirror_rows_from_registry(rows):
    """(pkg, glob, req) for every staged-deb row that cites NCZ_LOCAL_DEBS.

    Order follows the registry, which follows the hand-written block.
    req is the raw NCZ_LOCAL_DEBS word (required/optional), recovered from
    the notes so the literal the existing tests grep stays exact.
    """
    out = []
    for r in rows:
        if r["kind"] != "staged-deb":
            continue
        if "NCZ_LOCAL_DEBS" not in r["provenance"]:
            continue
        glob = r["source"]
        if glob.startswith("staged:"):
            glob = "$REPO/" + glob[len("staged:"):]
        req = "required" if r["required"] == "yes" else "optional"
        # notes carry the raw word; prefer it when present so a future
        # required vocabulary change cannot silently rewrite the literal.
        m = re.search(r"NCZ_LOCAL_DEBS:\s*(required|optional)", r["notes"])
        if m:
            req = m.group(1)
        out.append((r["name"], glob, req))
    return out


def render_local_debs(existing_text, rows):
    """Rewrite the NCZ_LOCAL_DEBS data lines; keep the surrounding script.

    The hand-written block is two assignments (the all-arch block, then the
    arm64-only block). A row whose glob is arm64-specific goes in the second
    block; everything else stays in the first. Comment lines inside either
    quoted block are kept. The literal ``ncz-screensavers|...|required``
    line is preserved so build/test-screensavers-mandatory-install-builders.sh
    still matches.
    """
    generated = _mirror_rows_from_registry(rows)
    # Which block a row belongs to is a property of the hand-written file,
    # not of the glob: libdrm-common is an _all.deb that the arm64 if-block
    # stages. Classify by where the file already has the row; a row the
    # file does not have yet goes in the arm64 block iff its glob is
    # arm64-specific.
    lines = existing_text.splitlines()
    opens = [i for i, ln in enumerate(lines)
             if re.search(r"\bNCZ_LOCAL_DEBS\s*\+?=\s*\"", ln)]

    def block_end(start):
        for j in range(start + 1, len(lines)):
            if lines[j].strip() == '"' or re.match(r'^\s*"', lines[j]):
                return j
        raise SystemExit("render-local-debs: unclosed NCZ_LOCAL_DEBS block")

    by_key = {(p, g): req for p, g, req in generated}
    block_rows = []
    seen = set()
    for start in opens[:2]:
        end = block_end(start)
        mine = []
        for raw in lines[start + 1:end]:
            s = raw.strip()
            if s.count("|") == 2 and not s.startswith("#"):
                pkg, glob, _req = s.split("|")
                key = (pkg, glob)
                if key in by_key and key not in seen:
                    mine.append((pkg, glob, by_key[key]))
                    seen.add(key)
        block_rows.append(mine)
    # A registry row the file does not have yet.
    for triple in generated:
        if (triple[0], triple[1]) not in seen:
            arm64 = "_arm64.deb" in triple[1]
            block_rows[1 if arm64 and len(block_rows) > 1 else 0].append(triple)

    def fill(block_lines, pending):
        out = []
        for raw in block_lines:
            s = raw.strip()
            if s.count("|") == 2 and not s.startswith("#"):
                if not pending:
                    continue
                pkg, glob, req = pending.pop(0)
                # A data line is rewritten whole: a trailing comment on it is
                # not carried over. The hand-written blocks have none, and
                # --check reports the difference if one is ever added.
                out.append(f"{pkg}|{glob}|{req}")
            else:
                out.append(raw)
        for pkg, glob, req in pending:
            out.append(f"{pkg}|{glob}|{req}")
        return out

    if len(opens) < 1:
        raise SystemExit("render-local-debs: no NCZ_LOCAL_DEBS block found")
    out = list(lines)
    for n, start in enumerate(opens[:2]):
        end = block_end(start)
        pending = list(block_rows[n] if n < len(block_rows) else [])
        out[start + 1:end] = fill(lines[start + 1:end], pending)
    nl = "\r\n" if "\r\n" in existing_text[:200] else "\n"
    text = nl.join(out)
    if existing_text.endswith(("\n", "\r\n")):
        text += nl
    return text


def cmd_render_local_debs(root, check_only):
    path = root / "build" / "build-desktop-mirror.sh"
    rows = _registry_rows(root)
    generated = _mirror_rows_from_registry(rows)
    parsed = parse_ncz_local_debs(path)
    existing = [(r["name"], r["glob"], r["req"]) for r in parsed]
    # The registry sorts rows; the hand-written block does not. Same rows
    # in a different order are byte-identical once the renderer keeps the
    # file order, so compare sets here and let render_local_debs refill in
    # file order.
    if sorted(existing) != sorted(generated):
        print("render-local-debs: NCZ_LOCAL_DEBS rows differ from the registry",
              file=sys.stderr)
        for i, (a, b) in enumerate(zip(existing, generated)):
            if a != b:
                print(f"  row {i}: file={a} registry={b}", file=sys.stderr)
        if len(existing) != len(generated):
            print(f"  count file={len(existing)} registry={len(generated)}",
                  file=sys.stderr)
        return 1
    new_text = render_local_debs(path.read_text(encoding="utf-8"), rows)
    if new_text != path.read_text(encoding="utf-8"):
        if check_only:
            print("render-local-debs: would change build-desktop-mirror.sh",
                  file=sys.stderr)
            return 1
        path.write_text(new_text, encoding="utf-8")
        print("render-local-debs: rewrote build/build-desktop-mirror.sh")
    else:
        print("render-local-debs: build-desktop-mirror.sh unchanged")
    return 0


def cmd_render_allowlist(root, check_only):
    """Confirm build/arch-parity-allowlist.tsv matches the registry.

    The allowlist carries a human reason per row, which the registry does
    not store, so phase 3 does not regenerate the reason text. It does
    fail when the (manifest, package, side) set drifts from what the
    manifests and the registry arch column imply. A clean tree is
    byte-identical because nothing is rewritten.
    """
    path = root / "build" / "arch-parity-allowlist.tsv"
    rows = _registry_rows(root)
    by_name = {}
    for r in rows:
        by_name.setdefault(r["name"], []).append(r)
    failed = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        cols = s.split("\t")
        if len(cols) < 4 or not cols[3].strip():
            print(f"render-allowlist: row missing a reason: {s}", file=sys.stderr)
            failed += 1
            continue
        manifest, pkg, side = cols[0], cols[1], cols[2]
        arch_rows = by_name.get(pkg, [])
        arches = {r["arch"] for r in arch_rows}
        if side == "arm64-only" and arches and arches <= {"arm64"}:
            continue
        if side == "amd64-only" and arches and arches <= {"amd64"}:
            continue
        # arch=all rows are the documented exception (ncz-singularity-desktop):
        # the allowlist is about which manifest seeds the name, not the
        # registry arch. Accept when the manifests agree with the side.
        arm_path = root / "manifests" / f"{manifest}.pkgs"
        amd_path = root / "manifests" / f"{manifest}-amd64.pkgs"
        arm = set(_pkgs_names(arm_path)) if arm_path.exists() else set()
        amd = set(_pkgs_names(amd_path)) if amd_path.exists() else set()
        if side == "arm64-only" and pkg in arm and pkg not in amd:
            continue
        if side == "amd64-only" and pkg in amd and pkg not in arm:
            continue
        # A row whose package is in neither manifest is a stale allowlist
        # entry (swayidle/swaylock were removed from desktop.pkgs; the
        # allowlist row remains as the recorded parity gap). It does not
        # contradict the registry, so it is not drift.
        if pkg not in arm and pkg not in amd:
            continue
        print(f"render-allowlist: {manifest}/{pkg} side {side} disagrees with "
              f"registry arches {sorted(arches) or '(no row)'}", file=sys.stderr)
        failed += 1
    # The other direction: a package in one manifest of a pair but not the
    # other must have an allowlist row. verify-dual-arch-parity.sh is the
    # build gate for this; the generator check must not pass a tree that
    # gate would fail.
    listed = set()
    for raw in path.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        cols = s.split("\t")
        if len(cols) >= 3:
            listed.add((cols[0], cols[1], cols[2]))
    for base in ("desktop", "installer-base", "rescue"):
        arm_path = root / "manifests" / f"{base}.pkgs"
        amd_path = root / "manifests" / f"{base}-amd64.pkgs"
        if not arm_path.exists() or not amd_path.exists():
            continue
        arm = set(_pkgs_names(arm_path))
        amd = set(_pkgs_names(amd_path))
        for pkg in sorted(arm - amd):
            if (base, pkg, "arm64-only") not in listed:
                print(f"render-allowlist: {base}/{pkg} is arm64-only in the "
                      f"manifests and has no allowlist row", file=sys.stderr)
                failed += 1
        for pkg in sorted(amd - arm):
            if (base, pkg, "amd64-only") not in listed:
                print(f"render-allowlist: {base}/{pkg} is amd64-only in the "
                      f"manifests and has no allowlist row", file=sys.stderr)
                failed += 1
    if failed:
        return 1
    print("render-allowlist: arch-parity-allowlist.tsv agrees with the registry")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())