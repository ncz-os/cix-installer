#!/usr/bin/env python3
"""build/components.py — component drift check / inventory / publish-diff.

Operator directive 2026-10-05 (Item C1). Pure Python 3 stdlib; runs on
STUDIO (macOS) and on the Linux build hosts; deterministic output (no
timestamps, stable sort order). Phase 2 wires `check` into `make parity`
and `make lint-platform`. The two seed-published findings that are
documented pre-AC gaps (chromium-ncz-sky1, ncz-ffmpeg) are waived until
the published-artifacts table lists them; every other error fails the gate.

Usage:
  components.py [--root DIR] [--registry PATH] check [--report-out PATH] [--no-exit]
  components.py [--root DIR] [--registry PATH] report --arch A --variant V
  components.py [--root DIR] [--registry PATH] diff-published

check
    Drift detection. Exit non-zero on any ERROR. Findings:
      row-format        kind/source/arch/variant/required outside the approved
                        vocabulary (required: yes | no | conditional:<cond>)
      row-installer     installed_by names a file that does not exist
      row-verifier      verified_by is empty or names a file that does not exist
      row-provenance    provenance is empty
      kind-shape        kernel/dkms without version_floor; staged-deb/npm with
                        the wrong source prefix
      manifest-registry a manifests/*.pkgs package with no registry row
      mirror-registry   an NCZ_LOCAL_DEBS package with no registry row
      hook-registry     a hook apt-get/dpkg/npm install with no registry row
      required-optional a required: yes row marked optional in NCZ_LOCAL_DEBS
                        (or required: no row marked required there); a
                        required manifest row absent from every manifest
      seed-published    an NCZ-apt-namespace name seeded in manifests/*.pkgs
                        that is absent from the published NCZ apt set
                        (offline: read from the item AC report; degraded note
                        when the report file is missing)
      arch-allowlist    arch-parity-allowlist.tsv side disagrees with the
                        registry arch set
      hook-arch         a hook runs on arch A (hooks.list.<A>) and installs a
                        package whose registry rows are for the other arch
      hook-never-runs   required: yes row whose installed_by hook appears in
                        no hooks.list.* file
    Warnings (do not affect the exit code):
      dkms-provenance   dkms source dir has no PROVENANCE file

report --arch A --variant V
    Print what an image of that arch/variant contains, grouped by
    kind/source, with required/floor shown.

diff-published
    Compare ncz-apt registry rows (source buildkite-packages or r2) against
    the apt repo contents described in ~/Projects/oc-apt-publish/report.md
    (override: NCZ_APT_PUBLISH_REPORT). Network optional: the report file is
    read locally; when it is missing the command degrades to a note and
    exits 0. Always informational (exit 0).

Author: Jason Perlow <jperlow@gmail.com>. No AI attribution
(commit-policy 2026-10-05).
"""

import argparse
import datetime
import os
import re
import sys
from pathlib import Path

# Column indices. The header order is fixed; build/gen-components-registry.py
# writes it. Do not reorder.
HEADER = (
    "name", "kind", "source", "arch", "variant", "required",
    "version_floor", "installed_by", "verified_by", "provenance", "notes",
)
COL_NAME, COL_KIND, COL_SOURCE, COL_ARCH, COL_VARIANT, COL_REQUIRED = \
    0, 1, 2, 3, 4, 5
COL_FLOOR, COL_INSTALLED_BY, COL_VERIFIED_BY, COL_PROVENANCE, COL_NOTES = \
    6, 7, 8, 9, 10

VALID_KINDS = {
    "debian", "ncz-apt", "staged-deb", "npm", "dkms",
    "kernel", "overlay", "firmware",
}
VALID_SOURCES_PREFIX = (
    "debian-forky", "buildkite-packages", "r2",
    "staged:", "npm:", "vendored:",
)
VALID_ARCHES = {"all", "arm64", "amd64"}
VALID_VARIANTS = {"desktop", "installer", "mgmt", "rescue", "server", "all"}
VALID_REQUIRED = {"yes", "no"}

# Phase 2 gate waivers. These are real findings, not silent drops: `check`
# still prints them. `check --gate` (the parity / lint-platform entry) does
# not fail the build on them, because the published-artifacts table is
# incomplete and phase 2 must not invent a publication.
#
#   chromium-ncz-sky1, ncz-ffmpeg: seeded in desktop.pkgs, resolve from the
#   live NCZ apt repo, absent from the item AC published-artifacts table
#   (docs/components-registry.md open question 2). Proposed fix: add both
#   names to that table. Not done here.
#
# ncz-screensavers-plugin is a required staged-deb row (pinned medium deb,
# post-install/lib/ncz-screensavers-plugin.lock); it is not an apt seed.
GATE_WAIVED = {
    ("seed-published", "chromium-ncz-sky1"),
    ("seed-published", "ncz-ffmpeg"),
}

# Names in the NCZ-apt namespace (custom-built debs), same rule as the
# generator: ncz-*, cix-*, or *-ncz-*.
def is_ncz_name(name):
    return (
        name.startswith(("ncz-", "cix-"))
        or "-ncz-" in name
    )


class Ctx:
    """Repository root + registry path + published set (lazy)."""

    def __init__(self, root, registry):
        self.root = Path(root).resolve()
        self.registry = (
            Path(registry).resolve()
            if registry else self.root / "manifests" / "components.tsv"
        )
        self._published = None
        self._published_degraded = False
        self.published_report = Path(os.environ.get(
            "NCZ_APT_PUBLISH_REPORT",
            str(Path.home() / "Projects" / "oc-apt-publish" / "report.md"),
        ))

    # ---- registry -----------------------------------------------------
    def load_registry(self):
        """Return (header, rows). Skips '#' comments and blank lines."""
        p = self.registry
        if not p.exists():
            print(f"error: registry not found: {p}", file=sys.stderr)
            raise SystemExit(2)
        rows, header = [], None
        with open(p, encoding="utf-8") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line or line.lstrip().startswith("#"):
                    continue
                cols = line.split("\t")
                if cols[COL_NAME] == "name":
                    header = cols
                    continue
                if len(cols) < len(HEADER):
                    cols = cols + [""] * (len(HEADER) - len(cols))
                rows.append({
                    "name": cols[COL_NAME],
                    "kind": cols[COL_KIND],
                    "source": cols[COL_SOURCE],
                    "arch": cols[COL_ARCH],
                    "variant": cols[COL_VARIANT],
                    "required": cols[COL_REQUIRED],
                    "version_floor": cols[COL_FLOOR],
                    "installed_by": cols[COL_INSTALLED_BY],
                    "verified_by": cols[COL_VERIFIED_BY],
                    "provenance": cols[COL_PROVENANCE],
                    "notes": cols[COL_NOTES],
                })
        if header is None:
            print(f"error: no header row found in {p}", file=sys.stderr)
            raise SystemExit(2)
        return header, rows

    # ---- published apt set (item AC report) ---------------------------
    def published(self):
        """Parse the 'Published artifacts' table of the item AC report.

        Returns (degraded, {name: {arch: {version, sha256}}}).
        """
        if self._published is not None:
            return self._published_degraded, self._published
        published = {}
        if not self.published_report.exists():
            self._published_degraded = True
            self._published = published
            return True, published
        for raw in self.published_report.read_text(encoding="utf-8",
                                                    errors="replace").splitlines():
            line = raw.strip()
            if not line.startswith("|") or line.count("|") < 4:
                continue
            cells = [c.strip().strip("`") for c in line.strip("|").split("|")]
            if len(cells) < 4:
                continue
            pkg, ver, arch, sha = cells[0], cells[1], cells[2], cells[3]
            if not pkg or pkg == "Package" or set(pkg) <= {"-", " "}:
                continue
            if arch in ("amd64", "arm64", "all") and re.match(r"^[0-9a-f]{64}$", sha):
                published.setdefault(pkg, {})[arch] = {
                    "version": ver, "sha256": sha,
                }
        self._published = published
        self._published_degraded = False
        return False, published

    def resolve(self, p):
        pp = Path(p)
        return pp if pp.is_absolute() else self.root / pp


# ---------------------------------------------------------------------------
# Ground-truth parsers (manifests, mirror, hooks, allowlist)
# ---------------------------------------------------------------------------


def parse_pkgs(root, fname):
    """Sorted plain package names from manifests/<fname>."""
    out = []
    p = root / "manifests" / fname
    if not p.exists():
        return out
    with open(p, encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            line = line.split("#", 1)[0].rstrip()
            if line:
                out.append(line)
    return sorted(set(out))


def gather_manifest_packages(root):
    """{package: [manifest, ...]} across every manifests/*.pkgs."""
    out = {}
    for f in sorted((root / "manifests").glob("*.pkgs")):
        for pkg in parse_pkgs(root, f.name):
            out.setdefault(pkg, []).append(f.name)
    return out


def gather_ncz_local_debs(root):
    """[(name, glob, raw_req)] from build/build-desktop-mirror.sh."""
    out = []
    p = root / "build" / "build-desktop-mirror.sh"
    if not p.exists():
        return out
    in_block = False
    for raw in p.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.rstrip("\n")
        if not in_block:
            if re.search(r"\bNCZ_LOCAL_DEBS\s*\+?=\s*\"", line):
                in_block = True
            continue
        if line.strip() == '"' or re.match(r"^\s*\"", line):
            in_block = False
            continue
        for tok in line.split():
            if tok.count("|") == 2:
                pkg, glob, req = tok.split("|")
                if pkg and glob:
                    out.append((pkg, glob, req))
    return out


def gather_arch_parity_allowlist(root):
    """{package: side} from build/arch-parity-allowlist.tsv."""
    out = {}
    f = root / "build" / "arch-parity-allowlist.tsv"
    if not f.exists():
        return out
    with open(f, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 4:
                out[parts[1]] = parts[2]
    return out


def gather_hook_lists(root):
    """{arch: [hook, ...]} from post-install/hooks.list.*.

    Arch from the filename: 'amd64' -> amd64, 'arm64' or 'sky1' -> arm64.
    """
    out = {}
    hooks_dir = root / "post-install"
    if not hooks_dir.exists():
        return out
    for f in sorted(hooks_dir.glob("hooks.list.*")):
        stem = f.name[len("hooks.list."):]
        if "amd64" in stem:
            arch = "amd64"
        elif "arm64" in stem or "sky1" in stem:
            arch = "arm64"
        else:
            continue
        hooks = []
        for raw in f.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.strip()
            if line and not line.startswith("#"):
                hooks.append(line)
        out[arch] = sorted(hooks)
    return out


RE_APT_INSTALL = re.compile(
    r"^(?:[A-Z_][A-Z0-9_]*=\S+\s+)*"          # optional VAR=val prefixes
    r"(?:timeout\s+\d+\s+)?"
    r"apt(?:-get)?\s+install\s+(.*)$"
)
RE_DPKG_INSTALL = re.compile(r"^(?:[A-Z_][A-Z0-9_]*=\S+\s+)*dpkg\s+-i\s+(.*)$")
RE_NPM_INSTALL = re.compile(r"^(?:[A-Z_][A-Z0-9_]*=\S+\s+)*npm\s+install\s+-g\s+(@?[\w./-]+)")
# A package-name-like token: lowercase alnum + . + - , at least two chars
# and at least one letter (drops stray '2' from '2>&1' splits, 'tail-10' etc.
# are dropped upstream by the metacharacter segmentation).
RE_PACKAGE_TOKEN = re.compile(r"^(?=[a-z0-9+.\-]*[a-z])[a-z0-9+.\-]{2,}$")
SHELL_STOP = {
    "&&", "||", "|", ">", "<", ">>", "2>", "2>&1", "1>&1", ";", "&",
    "if", "then", "else", "fi", "for", "do", "done", "case", "esac",
    "echo", "printf", "tail", "tee", "grep", "sed", "awk", "head", "true",
    "false", "local", "return", "exit",
}


def _logical_lines(text):
    """Join backslash-continued lines into logical statements."""
    out = []
    buf = ""
    for raw in text.splitlines():
        if raw.endswith("\\"):
            buf += raw[:-1] + " "
            continue
        buf += raw
        out.append(buf)
        buf = ""
    if buf:
        out.append(buf)
    return out


def gather_hook_installs(root):
    """{(hook, command): set(packages)} from post-install/*.sh.

    Scans logical statements (backslash continuations joined) for direct
    apt(-get) install / dpkg -i / npm install -g. Tokens that do not look
    like a package name (flags, shell words, $variables, paths) are dropped.
    """
    out = {}
    hooks_dir = root / "post-install"
    if not hooks_dir.exists():
        return out
    for sh in sorted(hooks_dir.glob("*.sh")):
        try:
            text = sh.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        found = {}
        for stmt in _logical_lines(text):
            stripped = stmt.strip()
            if not stripped or stripped.startswith("#"):
                continue
            code = stripped.split("#", 1)[0].rstrip()

            m = RE_APT_INSTALL.match(code)
            if m:
                # Only the command's own argument list: stop at the first
                # pipeline / redirection / control character, so `| tail-10`
                # or `2>&1` payloads never leak in as "packages".
                seg = re.split(r"[|><&;]", m.group(1), maxsplit=1)[0]
                pkgs = set()
                for tok in seg.split():
                    if tok.startswith("-"):
                        continue
                    if not RE_PACKAGE_TOKEN.match(tok):
                        continue
                    if tok in SHELL_STOP:
                        continue
                    pkgs.add(tok)
                if pkgs:
                    found.setdefault("apt-get install", set()).update(pkgs)
                continue

            m = RE_DPKG_INSTALL.match(code)
            if m:
                seg = re.split(r"[|><&;]", m.group(1), maxsplit=1)[0]
                for tok in seg.split():
                    if tok.startswith('"') or "$" in tok:
                        continue
                    if tok.endswith(".deb"):
                        base = os.path.basename(tok)
                        stem = re.split(r"_[0-9]", base, 1)[0] \
                            if "_" in base else base[:-4]
                        if RE_PACKAGE_TOKEN.match(stem):
                            found.setdefault(f"dpkg -i {base}", set()).add(stem)
                continue

            m = RE_NPM_INSTALL.match(code)
            if m:
                found.setdefault(f"npm install -g {m.group(1)}", set()).add(m.group(1))
        if found:
            out[sh.name] = found
    return out


# ---------------------------------------------------------------------------
# Subcommand: check
# ---------------------------------------------------------------------------


def installer_tokens(installed_by):
    """Every installer path in an installed_by cell.

    Splits on commas outside parentheses (so a parenthetical annotation such
    as "(apt-get install, best-effort)" stays attached), drops the
    "manifest" pseudo-installer, and returns each remaining path so a
    multi-installer row is checked in full.
    """
    out = []
    for tok in _split_paren_commas(installed_by):
        path = tok.split("(", 1)[0].strip()
        if not path or path == "manifest":
            continue
        out.append(path)
    return out


def cmd_check(ctx, args):
    _, rows = ctx.load_registry()
    findings = []  # (severity, code, msg)

    def add(sev, code, msg):
        findings.append((sev, code, msg))

    registry_names = {r["name"] for r in rows}
    arches_per_name = {}
    for r in rows:
        arches_per_name.setdefault(r["name"], set()).add(r["arch"])
    required_per_name = {}
    for r in rows:
        if r["required"] == "yes":
            required_per_name.setdefault(r["name"], []).append(r)

    # ---- per-row validation -------------------------------------------
    for r in rows:
        name = r["name"]
        if r["kind"] not in VALID_KINDS:
            add("error", "row-format",
                f"row {name!r}: unknown kind={r['kind']!r} "
                f"(allowed: {sorted(VALID_KINDS)})")
        if not any(r["source"].startswith(p) for p in VALID_SOURCES_PREFIX):
            add("error", "row-format",
                f"row {name!r}: unknown source={r['source']!r} "
                f"(allowed prefixes: {list(VALID_SOURCES_PREFIX)})")
        if r["arch"] not in VALID_ARCHES:
            add("error", "row-format",
                f"row {name!r}: unknown arch={r['arch']!r} "
                f"(allowed: {sorted(VALID_ARCHES)})")
        if r["variant"] != "all":
            for v in r["variant"].split(","):
                if v not in VALID_VARIANTS:
                    add("error", "row-format",
                        f"row {name!r}: unknown variant={v!r} in {r['variant']!r}")
        if (r["required"] not in VALID_REQUIRED
                and not r["required"].startswith("conditional:")):
            add("error", "row-format",
                f"row {name!r}: required={r['required']!r} outside "
                f"yes|no|conditional:<cond>")

        ib = r["installed_by"]
        if ib and ib != "manifest":
            for tok in installer_tokens(ib):
                p = ctx.resolve(tok)
                if not p.exists():
                    add("error", "row-installer",
                        f"row {name!r}: installed_by {tok!r} does not exist "
                        f"in the repo")
        vb = r["verified_by"]
        if not vb:
            add("error", "row-verifier",
                f"row {name!r}: verified_by is empty (every row needs a "
                f"verifier)")
        else:
            for tok in _split_paren_commas(vb):
                tok = tok.strip()
                if not tok:
                    continue
                path_str = tok.split("(", 1)[0].strip()
                p = ctx.resolve(path_str)
                if not p.exists():
                    add("error", "row-verifier",
                        f"row {name!r}: verified_by {path_str!r} does not "
                        f"exist in the repo")
        if not r["provenance"]:
            add("error", "row-provenance",
                f"row {name!r}: provenance is empty")

        if r["kind"] in ("kernel", "dkms") and not r["version_floor"]:
            add("error", "kind-shape",
                f"row {name!r}: {r['kind']} rows must carry a version_floor")
        if r["kind"] == "staged-deb" and not r["source"].startswith("staged:"):
            add("error", "kind-shape",
                f"row {name!r}: staged-deb requires a staged:<path> source")
        if r["kind"] == "npm" and not r["source"].startswith("npm:"):
            add("error", "kind-shape",
                f"row {name!r}: npm requires an npm:<pkg> source")
        if r["kind"] == "dkms":
            m = re.match(r"vendored:(assets/kernel/[^/]+)$", r["source"])
            if m and not (ctx.resolve(m.group(1)) / "PROVENANCE").exists():
                add("warn", "dkms-provenance",
                    f"row {name!r}: no PROVENANCE file at "
                    f"{m.group(1)}/PROVENANCE (t2smc is the reference)")

    # ---- manifest / mirror / hook coverage -----------------------------
    manifest_pkgs = gather_manifest_packages(ctx.root)
    for pkg, files in sorted(manifest_pkgs.items()):
        if pkg not in registry_names:
            add("error", "manifest-registry",
                f"manifest(s) {','.join(files)} seed {pkg!r} but the "
                f"registry has no row for it")

    ncz_debs = gather_ncz_local_debs(ctx.root)
    for pkg, glob, req in sorted(ncz_debs):
        if pkg not in registry_names:
            add("error", "mirror-registry",
                f"NCZ_LOCAL_DEBS row ({glob}, {req}) names {pkg!r} but the "
                f"registry has no row for it")

    hook_installs = gather_hook_installs(ctx.root)
    for hook in sorted(hook_installs):
        for cmd in sorted(hook_installs[hook]):
            for pkg in sorted(hook_installs[hook][cmd]):
                if pkg in registry_names:
                    continue
                add("error", "hook-registry",
                    f"hook {hook} ({cmd}) installs {pkg!r} but the registry "
                    f"has no row for it")

    # ---- required vs optional across sources ---------------------------
    # The NCZ_LOCAL_DEBS flag describes the STAGED pool path (optionality of
    # staging the .deb into desktop-mirror), so only staged-deb rows are
    # compared against it. An ncz-apt row (the published-repo path) has no
    # mirror flag: e.g. ncz-singularity-desktop's arm64 apt row is required
    # (20-desktop.sh hard-fails without it) even though the pool copy is
    # optional to stage.
    raw_req = {}
    for pkg, glob, req in ncz_debs:
        raw_req.setdefault(pkg, set()).add(req)
    pool_rows = [r for r in rows if r["kind"] == "staged-deb"]
    for r in pool_rows:
        if r["required"] == "yes" and "optional" in raw_req.get(r["name"], set()):
            add("error", "required-optional",
                f"{r['name']!r}: staged-deb row required=yes but "
                f"NCZ_LOCAL_DEBS marks the pool entry optional")
    for r in pool_rows:
        if r["required"] == "no" and "required" in raw_req.get(r["name"], set()):
            add("error", "required-optional",
                f"{r['name']!r}: staged-deb row required=no but "
                f"NCZ_LOCAL_DEBS marks the pool entry required")
    for name, rlist in sorted(required_per_name.items()):
        for r in rlist:
            if r["installed_by"] == "manifest" and name not in manifest_pkgs:
                add("error", "required-optional",
                    f"{name!r}: required=yes manifest row but no manifest "
                    f"seeds it")

    # ---- seed names vs published NCZ apt set ---------------------------
    degraded, published = ctx.published()
    if degraded:
        print(f"DEGRADED: published report not found at {ctx.published_report}; "
              f"seed-published check skipped (no network, no local report)",
              file=sys.stderr)
    else:
        pub_names = set(published)
        for pkg, files in sorted(manifest_pkgs.items()):
            if not is_ncz_name(pkg):
                continue
            if pkg not in pub_names:
                add("error", "seed-published",
                    f"seed name {pkg!r} (manifest(s) {','.join(files)}) is "
                    f"not in the published NCZ apt set per the item AC "
                    f"report; a fully offline mirror cannot resolve it from "
                    f"the apt repo")

    # ---- arch parity allowlist ------------------------------------------
    allow = gather_arch_parity_allowlist(ctx.root)
    for pkg, side in sorted(allow.items()):
        if pkg not in arches_per_name:
            continue  # subsumed by manifest-registry
        arches = arches_per_name[pkg]
        if side == "arm64-only" and "amd64" in arches:
            add("error", "arch-allowlist",
                f"{pkg!r}: arch-parity-allowlist says arm64-only but the "
                f"registry has an amd64 row")
        elif side == "amd64-only" and "arm64" in arches:
            add("error", "arch-allowlist",
                f"{pkg!r}: arch-parity-allowlist says amd64-only but the "
                f"registry has an arm64 row")

    # ---- hook arch vs registry arch (manifest/hook-list disagreement) ---
    hook_lists = gather_hook_lists(ctx.root)
    for hook in sorted(hook_installs):
        for arch, hooks in sorted(hook_lists.items()):
            if hook not in hooks:
                continue
            for cmd in sorted(hook_installs[hook]):
                for pkg in sorted(hook_installs[hook][cmd]):
                    arches = arches_per_name.get(pkg)
                    if arches is None:
                        continue  # subsumed by hook-registry
                    if arch not in arches and "all" not in arches:
                        add("error", "hook-arch",
                            f"hook {hook} runs on {arch} (hooks.list.{arch}) "
                            f"and installs {pkg!r}, whose registry arch is "
                            f"{sorted(a for a in arches if a != 'all')}")

    # ---- required rows whose hook never runs ----------------------------
    for name in sorted(required_per_name):
        for r in required_per_name[name]:
            ib = r["installed_by"]
            if ib and ib != "manifest":
                for hook in installer_tokens(ib):
                    m = re.match(r"post-install/(?:[\w.-]+/)*([\w.-]+\.sh)$", hook)
                    if not m:
                        continue
                    hookfile = m.group(1)
                    in_any = any(hookfile in hooks for hooks in hook_lists.values())
                    if not in_any:
                        add("error", "hook-never-runs",
                            f"{name!r}: required=yes row installed by {hook} "
                            f"but {hookfile} appears in no hooks.list.* file")

    # ---- output ----------------------------------------------------------
    errors = [f for f in findings if f[0] == "error"]
    warnings = [f for f in findings if f[0] == "warn"]
    findings.sort(key=lambda f: (f[0], f[1], f[2]))
    print("components.py check -- phases 1-3 (operator 2026-10-05)")
    print(f"root: {ctx.root}")
    print(f"registry: {ctx.registry}")
    print(f"rows: {len(rows)}")
    print(f"errors: {len(errors)}  warnings: {len(warnings)}")
    print()
    for sev, code, msg in findings:
        print(f"[{sev:<5}] {code}: {msg}")

    if args.report_out:
        report_path = Path(args.report_out)
        if not report_path.is_absolute():
            report_path = ctx.root / report_path
        report_path.parent.mkdir(parents=True, exist_ok=True)
        today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
        with open(report_path, "w", encoding="utf-8") as fh:
            fh.write(f"# Components drift report -- {today}\n\n")
            fh.write("Auto-generated by `build/components.py check` (Item C1, "
                     "phase 1);\n")
            fh.write("curated by the item operator. Findings are NOT fixed "
                     "here -- they feed\n")
            fh.write("S4 (mandatory screensaver install) and phase 2 "
                     "(enforce required/floor/arch\n")
            fh.write("from the registry).\n\n")
            fh.write(f"Registry: `{ctx.registry}` ({len(rows)} rows)\n\n")
            fh.write("## Summary\n\n")
            fh.write(f"- errors: {len(errors)}\n- warnings: {len(warnings)}\n\n")
            if not findings:
                fh.write("No drift detected.\n")
            else:
                fh.write("## Findings\n\n")
                for sev, code, msg in findings:
                    fh.write(f"- **[{sev}]** `{code}`: {msg}\n")
                fh.write("\n")
        print(f"\ndrift report written: {report_path}")

    blocking = errors
    if getattr(args, "gate", False):
        blocking = []
        for sev, code, msg in errors:
            waived = False
            for wcode, wname in GATE_WAIVED:
                if code == wcode and f"'{wname}'" in msg:
                    waived = True
                    break
            if not waived:
                blocking.append((sev, code, msg))
        if blocking:
            print(f"\ngate: {len(blocking)} unwaived error(s); refusing")
        elif errors:
            print(f"\ngate: {len(errors)} error(s), all in the documented "
                  f"waiver set; not failing the build")
    if blocking and not args.no_exit:
        raise SystemExit(1)
    return 0


def _split_paren_commas(s):
    """Split on commas outside parentheses (keeps '(annotation, x)' whole)."""
    out, buf, depth = [], [], 0
    for ch in s:
        if ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth = max(0, depth - 1)
            buf.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    if buf:
        out.append("".join(buf))
    return out


# ---------------------------------------------------------------------------
# Subcommand: report
# ---------------------------------------------------------------------------


def cmd_report(ctx, args):
    _, rows = ctx.load_registry()
    arch, variant = args.arch, args.variant
    print(f"components.py report -- arch={arch} variant={variant}")
    print(f"registry: {ctx.registry}")
    print()
    matched = []
    for r in rows:
        if arch != "all" and r["arch"] not in ("all", arch):
            continue
        if variant != "all":
            row_vars = {v.strip() for v in r["variant"].split(",")}
            if variant not in row_vars and "all" not in row_vars:
                continue
        matched.append(r)
    print(f"matched rows: {len(matched)}")
    print()
    by_kind_src = {}
    for r in matched:
        by_kind_src.setdefault(r["kind"], {}).setdefault(r["source"], []).append(r)
    for kind in sorted(by_kind_src):
        n = sum(len(v) for v in by_kind_src[kind].values())
        print(f"## kind = {kind}  ({n} rows)")
        for src in sorted(by_kind_src[kind]):
            print(f"  ### source = {src}")
            for r in sorted(by_kind_src[kind][src], key=lambda x: x["name"]):
                req = r["required"] or "-"
                floor = r["version_floor"] or "-"
                print(f"    {r['name']:<40s}  req={req:<11s} floor={floor}")
        print()
    return 0


# ---------------------------------------------------------------------------
# Subcommand: diff-published
# ---------------------------------------------------------------------------


def cmd_query(ctx, args):
    """Print one field of the rows matching name/kind. For build scripts.

    Exit 2 when nothing matches, so a caller that expected a row fails
    closed. Multiple matches print one line each (stable registry order).
    """
    _, rows = ctx.load_registry()
    want_kind = getattr(args, "kind", None)
    field = args.field
    if field not in HEADER:
        print(f"error: unknown field {field!r}", file=sys.stderr)
        raise SystemExit(2)
    hits = []
    for r in rows:
        if r["name"] != args.name:
            continue
        if want_kind and r["kind"] != want_kind:
            continue
        hits.append(r[field])
    if not hits:
        print(f"error: no registry row for name={args.name!r}"
              + (f" kind={want_kind!r}" if want_kind else ""),
              file=sys.stderr)
        raise SystemExit(2)
    for hit in hits:
        print(hit)
    return 0


def cmd_diff_published(ctx, args):
    _, rows = ctx.load_registry()
    degraded, published = ctx.published()
    print("components.py diff-published -- phase 1 (informational; always exit 0)")
    if degraded:
        print(f"DEGRADED: published report not found at {ctx.published_report}")
        print("(set NCZ_APT_PUBLISH_REPORT to override; the item AC report at")
        print(" ~/Projects/oc-apt-publish/report.md is the canonical source)")
        return 0
    print(f"published report: {ctx.published_report}")
    print(f"documented published packages: {len(published)}")
    print("(the table documents the item AC publication; the repo also holds")
    print(" pre-AC packages the table does not enumerate -- a NOT-IN-DOCSET")
    print(" finding below means 'not documented', not necessarily 'absent')")
    print()

    apt_rows = [r for r in rows if r["kind"] == "ncz-apt"
                and r["source"] in ("buildkite-packages", "r2")]
    print(f"registry ncz-apt rows from the apt repo: {len(apt_rows)}")
    print()

    drift = []
    for r in sorted(apt_rows, key=lambda x: x["name"]):
        arches = published.get(r["name"], {})
        want = {"amd64", "arm64"} if r["arch"] == "all" else {r["arch"]}
        for a in sorted(want):
            if a not in arches:
                drift.append((r["name"], a,
                              ("NOT-IN-DOCSET (registry row; not in the item "
                               "AC published-artifacts table)")))
    registry_names = {r["name"] for r in rows}
    for name in sorted(published):
        if name not in registry_names:
            note = ("published but intentionally never installed "
                    "(59-ncz-screensavers-pkg.sh refuses it)"
                    if name == "ncz-screensavers-gtk4-reference"
                    else "published; no registry row")
            drift.append((name, "-", f"NOT-IN-REGISTRY ({note})"))

    if not drift:
        print("OK: every documented published package maps to a registry row "
              "and vice versa.")
        return 0
    print(f"findings ({len(drift)}):")
    for name, arch, msg in drift:
        print(f"  - {name:<32s} arch={arch:<14s} {msg}")
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="NCZ-OS component registry tools (Item C1, phases 1-3)",
    )
    ap.add_argument("--root", default=None,
                    help="repo root (default: parent of the build/ dir "
                         "containing this script)")
    ap.add_argument("--registry", default=None,
                    help="registry TSV path (default: <root>/manifests/"
                         "components.tsv)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_check = sub.add_parser("check", help="drift check; non-zero exit on errors")
    p_check.add_argument("--report-out", default=None,
                         help="also write the drift report to this path")
    p_check.add_argument("--no-exit", action="store_true",
                         help="do not exit non-zero on errors (still prints them)")
    p_check.add_argument("--gate", action="store_true",
                         help="phase 2 build gate: exit 0 when the only "
                              "errors are the documented GATE_WAIVED findings")
    p_check.set_defaults(func=cmd_check)

    p_report = sub.add_parser("report", help="print image contents for arch/variant")
    p_report.add_argument("--arch", required=True, choices=sorted(VALID_ARCHES))
    p_report.add_argument("--variant", required=True)
    p_report.set_defaults(func=cmd_report)

    p_query = sub.add_parser(
        "query",
        help="print one field of the row(s) matching --name [--kind]",
    )
    p_query.add_argument("--name", required=True)
    p_query.add_argument("--kind", default=None, choices=sorted(VALID_KINDS))
    p_query.add_argument("--field", required=True, choices=list(HEADER))
    p_query.set_defaults(func=cmd_query)

    p_diff = sub.add_parser("diff-published",
                            help="compare ncz-apt rows against the item AC "
                                 "published-artifacts table")
    p_diff.set_defaults(func=cmd_diff_published)

    args = ap.parse_args(argv)
    if args.root:
        root = Path(args.root)
    else:
        root = Path(__file__).resolve().parent.parent
    ctx = Ctx(root, args.registry)
    return args.func(ctx, args)


if __name__ == "__main__":
    raise SystemExit(main())