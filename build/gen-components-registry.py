#!/usr/bin/env python3
"""build/gen-components-registry.py

Generate manifests/components.tsv from ground truth.

Operator directive 2026-10-05 (Item C1, phase 1). Pure Python 3 stdlib;
deterministic output (stable sort keys, no timestamps); safe to re-run.
NOT wired into any build in phase 1: this is the data-prep half of phase 1,
used offline to produce the registry that build/components.py then audits.

Ground truth sources (parsed from this tree):
  - manifests/*.pkgs (per-arch seed manifests + install-extra + firmware BOM)
  - NCZ_LOCAL_DEBS rows in build/build-desktop-mirror.sh (optional/required)
  - build/arch-parity-allowlist.tsv (reviewed arm64/amd64 manifest divergence)
  - assets/kernel/KERNEL-POLICY (STABLE_BASE / EDGE_BASE),
    assets/kernel/amd64-stable/KVER, assets/kernel/edge-manifest.json
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

# Seeds whose NCZ-apt publication is explicitly deferred; the staged .deb
# (NCZ_LOCAL_DEBS) is their only install path today. AC report open question
# 5: "Screensaver Settings plugin 0.3.16 is explicitly out of scope
# (orchestrator publishes later)".
KNOWN_UNPUBLISHED_SEEDS = {"ncz-screensavers-plugin"}

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
        prov_file = sub / "PROVENANCE"
        if prov_file.exists():
            first = prov_file.read_text(encoding="utf-8").strip().splitlines()
            provenance = f"assets/kernel/{d}/dkms.conf; assets/kernel/{d}/PROVENANCE ({first[0] if first else 'vendor record'})"
            prov_note = ""
        else:
            provenance = f"assets/kernel/{d}/dkms.conf (no PROVENANCE file; t2linux linux-t2-patches, same vendor as t2smc PROVENANCE)"
            prov_note = " PROVENANCE file missing (feeds phase 2)."
        rows.append({
            "name": name,
            "kind": "dkms",
            "source": f"vendored:assets/kernel/{d}",
            "arch": "amd64",
            "variant": "desktop,installer,mgmt,rescue,server",
            "required": "yes",
            "version_floor": ver or "",
            "installed_by": "post-install/56-t2-dkms.sh (dkms build/install)",
            "verified_by": "build/verify-dkms-modules.sh",
            "provenance": provenance,
            "notes": (
                "Apple T2 module; built per-kernel against "
                "/lib/modules/$" + "{kernelver}" + "/build." + prov_note
            ),
        })
    return rows


def parse_kernel_entries(kernel_root):
    """Kernel rows from KERNEL-POLICY + amd64-stable/KVER + edge-manifest.json."""
    rows = []
    stable_base = edge_base = ""
    policy_path = kernel_root / "KERNEL-POLICY"
    if policy_path.exists():
        for raw in policy_path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if line.startswith("STABLE_BASE="):
                stable_base = line.split("=", 1)[1].strip()
            elif line.startswith("EDGE_BASE="):
                edge_base = line.split("=", 1)[1].strip()

    kver_path = kernel_root / "amd64-stable" / "KVER"
    if kver_path.exists():
        kver = kver_path.read_text(encoding="utf-8").strip()
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
            "provenance": "assets/kernel/amd64-stable/KVER; assets/kernel/KERNEL-POLICY",
            "notes": (
                f"Default + installer boot kernel on amd64 ({kver}). "
                "Rescued from installer media by 70-bootloader.sh."
            ),
        })

    edge_manifest = kernel_root / "edge-manifest.json"
    edge_data = {}
    if edge_manifest.exists():
        edge_data = json.loads(edge_manifest.read_text(encoding="utf-8"))
    edge_kver = edge_data.get("kver", "")
    mainline_path = kernel_root / "mainline"
    if mainline_path.exists() or stable_base:
        rows.append({
            "name": "sky1-mainline-kernel",
            "kind": "kernel",
            "source": "vendored:assets/kernel/mainline",
            "arch": "arm64",
            "variant": "desktop,installer,mgmt,rescue,server",
            "required": "yes",
            "version_floor": f"{stable_base}-sky1-ncz" if stable_base else "",
            "installed_by": "post-install/10-our-kernel.sh",
            "verified_by": "build/verify-base-kernel-assets.sh,build/verify-kernel-default-policy.sh",
            "provenance": (
                "assets/kernel/mainline (symlink -> NFS kernel staging); "
                "assets/kernel/KERNEL-POLICY (STABLE_BASE)"
            ),
            "notes": (
                "Default + installer boot kernel on Sky1/arm64. Symlink target "
                "lives outside the repo (/mnt/argonas-yocto-shared/kernel-staging)."
            ),
        })
    if edge_data.get("channel") == "edge" and (edge_kver or edge_base):
        floor = edge_kver or f"{edge_base}-sky1-ncz"
        rows.append({
            "name": "sky1-edge-kernel",
            "kind": "kernel",
            "source": "vendored:assets/kernel/edge",
            "arch": "arm64",
            "variant": "desktop,mgmt,rescue,server",
            "required": "no",
            "version_floor": floor,
            "installed_by": "post-install/10-our-kernel.sh (non-default entry)",
            "verified_by": "build/verify-base-kernel-assets.sh,build/verify-kernel-default-policy.sh",
            "provenance": (
                f"assets/kernel/edge-manifest.json (kver={floor}, "
                f"build_rev={edge_data.get('build_rev', '?')}, staging "
                f"{edge_data.get('staging_dir', '?')}); assets/kernel/KERNEL-POLICY (EDGE_BASE)"
            ),
            "notes": "Bootable NON-default entry on Sky1/arm64 (kernel-channel policy 2026-10-05).",
        })
    if edge_base:
        rows.append({
            "name": "amd64-edge-kernel",
            "kind": "kernel",
            "source": "vendored:assets/kernel/amd64-edge",
            "arch": "amd64",
            "variant": "desktop,mgmt,rescue,server",
            "required": "no",
            "version_floor": f"{edge_base}-1-t2-edge-aerfix",
            "installed_by": "post-install/10-amd64-kernel.sh (non-default entry)",
            "verified_by": "build/verify-base-kernel-assets.sh,build/verify-kernel-default-policy.sh",
            "provenance": (
                "assets/kernel/KERNEL-POLICY (EDGE_BASE; amd64 edge = "
                "-1-t2-edge-aerfix, overlay patch 9010); "
                "docs/reports/2026-10-05-amd64-edge-rc6-revert.md"
            ),
            "notes": (
                "Bootable NON-default entry on amd64. assets/kernel/amd64-edge/ "
                "stamp dir not yet in the repo (stamps in T2 staging only); "
                "row exists so phase 2 enforcement can detect a missing edge install."
            ),
        })
    return rows, edge_data


def parse_overlay_rows(kernel_root, edge_data):
    """Overlay .ko rows from edge-manifest.json overlays_mirrored only.

    Keys are 'assets/kernel/<drv>/<kver>/<ko>'. (The artifacts section also
    holds 'overlays/<drv>/<kver>/<ko>' sha256 entries; those are the same
    files under a different prefix and must not be double-counted.)
    """
    rows = []
    kver = edge_data.get("kver", "")
    mirrored = edge_data.get("overlays_mirrored", {})
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
            "verified_by": "build/verify-overlays.py",
            "provenance": f"assets/kernel/edge-manifest.json (overlays_mirrored: {key})",
            "notes": (
                f"Edge-kernel overlay for {drv}; mainline kernel uses the same "
                "sources built against the mainline tree."
            ),
        })
    return rows, kver


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
        "provenance": "build/forky-vendor-mirror (pinned Google .deb, SHA256-verified); build/build-vendor-mirror.sh",
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
        "provenance": "manifests/installer-base.pkgs; build/build-vendor-mirror.sh (KERNEL_DEBS publish); assets/kernel/edge-manifest.json (debs/cixmini-boot)",
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
        "provenance": "manifests/installer-base.pkgs; build/build-vendor-mirror.sh (KERNEL_DEBS publish); assets/kernel/edge-manifest.json (debs/linux-image-cixmini)",
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
    args = ap.parse_args(argv)
    root = Path(args.root).resolve()
    out_path = Path(args.out).resolve() if args.out else root / "manifests" / "components.tsv"

    all_rows = []

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
            if ncz and pkg in KNOWN_UNPUBLISHED_SEEDS:
                # Staged-deb row (NCZ_LOCAL_DEBS) is the authoritative row;
                # the seed presence is noted there. Skip to avoid a phantom
                # buildkite-packages row for an unpublished name.
                continue
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
                "version_floor": "",
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
            "ncz-screensavers": "59-ncz-screensavers-pkg.sh; S4 (2026-10-06) makes the install mandatory.",
            "ncz-screensavers-plugin": (
                "59-ncz-screensavers-pkg.sh. Seed in install-extra.pkgs but NOT "
                "published to the NCZ apt set (item AC open question 5); the "
                "staged .deb is the only offline path -- drift, feeds S4."
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
            "ncz-screensavers-plugin": "post-install/59-ncz-screensavers-pkg.sh",
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
            "version_floor": "2.4.134-3+ncz" if name.startswith("libdrm") else "",
            "installed_by": installed_by,
            "verified_by": verified_by,
            "provenance": provenance,
            "notes": notes,
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

    # 6. Kernel entries + overlays (edge-manifest.json).
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
            seen[key] = dict(r)
            continue
        old = seen[key]
        old["variant"] = variant_union([variant_set(old["variant"]), variant_set(r["variant"])])
        if r["required"] == "yes" and old["required"] != "yes":
            old["required"] = "yes"
        if r.get("notes") and r["notes"] not in old.get("notes", ""):
            old["notes"] = "; ".join(x for x in (old.get("notes", ""), r["notes"]) if x)
        if r.get("provenance") and r["provenance"] not in old.get("provenance", ""):
            old["provenance"] = old["provenance"] + "; " + r["provenance"] if old.get("provenance") else r["provenance"]

    final = sorted(seen.values(), key=sort_key)

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("# manifests/components.tsv -- NCZ-OS component registry (Item C1, phase 1)\n")
        f.write("#\n")
        f.write("# Operator directive 2026-10-05. TSV; one component per row. Generated by\n")
        f.write("# build/gen-components-registry.py from manifests/*.pkgs + NCZ_LOCAL_DEBS\n")
        f.write("# + KERNEL-POLICY + assets/kernel/t2*/dkms.conf + edge-manifest.json +\n")
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
        f.write("# Phases (operator 2026-10-05): phase 1 = this registry + drift report;\n")
        f.write("# phase 2 = enforce required/floor/arch (after S1 merge r2 + S4 mandatory\n")
        f.write("# screensaver install); phase 3 = generate seed files and mirror rows.\n")
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


if __name__ == "__main__":
    raise SystemExit(main())