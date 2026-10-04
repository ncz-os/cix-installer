#!/usr/bin/env python3
"""Cygnus 26.10 Singularity THEME + ACCENT integration gate.

Plain ``python3`` (no pytest required) or under pytest. It proves, against the
real files, that:

1. The installable override (generated + staged under assets/branding) equals
   the token-derived block from tools/gen-cygnus.py -- no hand-copied hex.
2. post-install/20-desktop.sh writes the token-derived accent/theme defaults
   (it starts from the generated file and appends its non-Cygnus keys) and no
   longer hard-codes ``accent-color='red'``.
3. The resulting combined ``99-ncz-defaults.gschema.override`` compiles with
   ``glib-compile-schemas --strict --dry-run`` against the REAL
   dev.sinty.desktop schema (key names, types, enum values, ranges).
4. The Cygnus theme is installed where libsingularity searches
   (/usr/share/themes/Cygnus) and ``singularity-theme='Cygnus'`` resolves.
5. Every @named_color the theme references is a base name defined by
   libsingularity or a name the theme itself defines, and every selector it
   targets a class/state that exists in the shell.
6. The NCZ overlay patch for user-theme priority still applies.

Checks that need the singularity source/schema clone (the real upstream
libsingularity/desktop tree) are reported SKIP, not FAIL, when it is absent;
they run on this host at ~/Projects/singularity-sync-real-*.
"""

from __future__ import annotations

import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve()
CYGNUS = HERE.parents[1]  # branding/cygnus
REPO = HERE.parents[3]  # repo root
GEN = CYGNUS / "tools" / "gen-cygnus.py"
TOKENS = CYGNUS / "tokens.json"
GENERATED_OVERRIDE = (
    CYGNUS / "generated" / "singularity" / "99-ncz-cygnus.gschema.override"
)
INSTALLER_DIR = REPO / "assets" / "branding" / "singularity-theme"
INSTALLER_OVERRIDE = INSTALLER_DIR / "99-ncz-cygnus.gschema.override"
DESKTOP = REPO / "post-install" / "20-desktop.sh"
PATCH = (
    REPO
    / "assets"
    / "singularity"
    / "patches"
    / "libsingularity"
    / "0002-user-theme-loads-above-base.patch"
)

# The user theme is installed here; find_theme_dir() looks for
# <dir>/Cygnus/singularity/style.css among /usr/share/themes etc.
THEME_DIR = "/usr/share/themes/Cygnus"

errors: list[str] = []
skips: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def skip(msg: str) -> None:
    skips.append(msg)


def load_gen():
    spec = importlib.util.spec_from_file_location("gen_cygnus", GEN)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def find_singularity_tree() -> Path | None:
    """Locate the real singularity-desktop/libsingularity checkout."""
    env = os.environ.get("NCZ_SINGULARITY_SYNC")
    candidates = []
    if env:
        candidates.append(Path(env))
    candidates += [
        Path(p)
        for p in sorted(
            glob.glob(str(Path.home() / "Projects" / "singularity-sync-real-*"))
        )
    ]
    candidates += [
        Path("/opt/singularity"),
        Path.home() / "Projects" / "singularity-desktop",
    ]
    for c in candidates:
        if (
            c
            / "subprojects"
            / "libsingularity"
            / "src"
            / "style"
            / "style_manager.vala"
        ).is_file():
            return c
    return None


def find_schema() -> tuple[Path, Path] | None:
    """Return (schema_xml, libsingularity) if the real schema is available."""
    tree = find_singularity_tree()
    if tree is None:
        return None
    schema = tree / "data" / "dev.sinty.desktop.gschema.xml"
    libsing = tree / "subprojects" / "libsingularity"
    if schema.is_file() and libsing.is_dir():
        return schema, libsing
    return None


# --------------------------------------------------------------------- checks
def check_generated_matches_tokens(gen, tokens: dict) -> None:
    expected = gen.gschema_override(tokens)
    for path in (GENERATED_OVERRIDE, INSTALLER_OVERRIDE):
        if not path.is_file():
            err(f"missing generated override: {path.relative_to(REPO)}")
        elif path.read_text() != expected:
            err(f"{path.relative_to(REPO)} != token-derived gen-cygnus.py output")

    # Explicit value assertions (so a regression names the key it broke).
    s = tokens["singularity"]
    checks = {
        "accent-color": f"accent-color='{s['accent-color']}'",
        "custom-accent-color": f"custom-accent-color='{s['custom-accent-color']}'",
        "singularity-theme": f"singularity-theme='{s['theme-name']}'",
        "theme-mode": f"theme-mode='{s['theme-mode']}'",
    }
    text = expected
    for key, line in checks.items():
        if line not in text:
            err(f"generated override missing token-derived {key}: {line}")
    colors = ", ".join(f"'{c}'" for c in s["custom-accent-colors"])
    if f"custom-accent-colors=[{colors}]" not in text:
        err("generated override custom-accent-colors != tokens.json")


def check_generator_not_handcopied() -> None:
    body = DESKTOP.read_text()
    if "accent-color='red'" in body:
        err("post-install/20-desktop.sh still hard-codes accent-color='red'")
    if 'cp "$CYGNUS_GS_SRC"' not in body:
        err("20-desktop.sh does not copy the generated Cygnus override into place")
    if 'cat >> "$SCHEMADIR/99-ncz-defaults.gschema.override"' not in body:
        err("20-desktop.sh no longer appends its non-Cygnus keys to the override")
    if THEME_DIR not in body:
        err(f"20-desktop.sh does not install the theme to {THEME_DIR}")


def check_schema_compiles() -> None:
    found = find_schema()
    if found is None:
        skip("schema compile: no singularity-sync clone found")
        return
    schema, _libsing = found
    override = INSTALLER_OVERRIDE.read_text()

    m = re.search(
        r"cat >> \"\$SCHEMADIR/99-ncz-defaults\.gschema\.override\" <<'GSCHEMA'\n(.*?)\nGSCHEMA\n",
        DESKTOP.read_text(),
        re.DOTALL,
    )
    if not m:
        err("could not extract the appended GSCHEMA heredoc from 20-desktop.sh")
        return
    combined = override.rstrip("\n") + "\n" + m.group(1) + "\n"

    with tempfile.TemporaryDirectory() as td:
        td = Path(td)
        (td / "dev.sinty.desktop.gschema.xml").write_text(schema.read_text())
        (td / "99-ncz-defaults.gschema.override").write_text(combined)
        p = subprocess.run(
            ["glib-compile-schemas", "--strict", "--dry-run", str(td)],
            capture_output=True,
            text=True,
            check=False,
        )
        if p.returncode != 0:
            err(
                "glib-compile-schemas --strict rejected the combined override:\n"
                + (p.stdout + p.stderr).strip()
            )


def check_theme_installed(gen, tokens: dict) -> None:
    css = INSTALLER_DIR / "Cygnus" / "singularity" / "style.css"
    if not css.is_file():
        err(f"installable theme missing {css.relative_to(REPO)}")
        return
    for rel in (
        "Cygnus/index.theme",
        "Cygnus/singularity/style.css",
        "Cygnus/singularity/style-dark.css",
        "Cygnus/singularity/style-light.css",
        "Cygnus/gtk-4.0/gtk.css",
        "Cygnus/gtk-4.0/gtk-dark.css",
    ):
        if not (INSTALLER_DIR / rel).is_file():
            err(f"installable theme missing {rel}")
    # The generated copy and the staged copy must agree.
    for rel in ("Cygnus/singularity/style.css", "Cygnus/singularity/style-dark.css"):
        a = (CYGNUS / "generated" / "singularity" / rel).read_text()
        b = (INSTALLER_DIR / rel).read_text()
        if a != b:
            err(f"generated/ and assets/ copies of {rel} differ")

    # singularity-theme='Cygnus' resolves only if the theme lands in a real
    # libsingularity find_theme_dir() search path. Prove that against the code.
    found = find_schema()
    if found is None:
        skip("theme search-path check skipped (no singularity-sync clone)")
    else:
        _schema, libsing = found
        sm = (libsing / "src" / "style" / "style_manager.vala").read_text()
        search_dirs = re.findall(r'"(/usr/local/share/themes|/usr/share/themes)"', sm)
        if "/usr/share/themes" not in search_dirs:
            err(
                "libsingularity no longer searches /usr/share/themes, so "
                f"singularity-theme='Cygnus' would not resolve (code dirs={search_dirs})"
            )


def check_theme_colors_and_selectors() -> None:
    theme_files = sorted((INSTALLER_DIR / "Cygnus").rglob("*.css"))
    if not theme_files:
        err("no theme CSS files under assets/branding/singularity-theme/Cygnus")
        return
    defined: set[str] = set()
    referenced: dict[str, str] = {}
    for f in theme_files:
        text = f.read_text()
        for name in re.findall(r"@define-color\s+([A-Za-z_][A-Za-z0-9_]*)", text):
            defined.add(name)
        # Skip the @define-color directive itself; only color references count.
        refs = re.sub(r"@define-color", "", text)
        for name in re.findall(r"@([A-Za-z_][A-Za-z0-9_]*)", refs):
            referenced.setdefault(name, f.name)

    found = find_schema()
    base: set[str] = set()
    if found is None:
        # Without the clone, still allow the documented base names the theme
        # actually uses, so this gate works on any host.
        base = {"accent_color", "accent_bg_color", "accent_fg_color"}
        skip("named-color base-name check used a minimal fallback set (no clone)")
    else:
        _schema, libsing = found
        for f in (
            libsing / "src" / "style" / "style.css",
            libsing / "src" / "style" / "style.dark.css",
            libsing / "src" / "style" / "style.light.css",
            libsing / "src" / "style" / "style_manager.vala",
        ):
            if f.is_file():
                base |= set(
                    re.findall(
                        r"@define-color\s+([A-Za-z_][A-Za-z0-9_]*)", f.read_text()
                    )
                )

    for name, where in sorted(referenced.items()):
        if name not in defined and name not in base:
            err(
                f"{where}: references undefined @{name} (not theme-defined, not a base name)"
            )

    # Selectors that do not exist in the shell must not be generated. Strip CSS
    # comments first so the explanatory comments that NAME the old selectors
    # ("there is no .sidebar-item class") are not read as live rules.
    style = re.sub(
        r"/\*.*?\*/",
        "",
        (INSTALLER_DIR / "Cygnus" / "singularity" / "style.css").read_text(),
        flags=re.DOTALL,
    )
    for bad in (
        ".sidebar-item",
        ".quick-setting-tile:checked",
        ".workspace-preview:selected",
        ".singularity .link",
    ):
        if bad in style:
            err(
                f"theme targets a selector/class that does not exist in the shell: {bad}"
            )
    for good in (
        ".navigation-sidebar row:selected",
        ".sidebar-row:selected",
        ".quick-setting-tile.active",
        ".workspace-preview.selected",
    ):
        if good not in style:
            err(f"theme lost its real selector {good}")


def check_selectors_exist_in_shell() -> None:
    found = find_schema()
    if found is None:
        skip("shell class existence check skipped (no singularity-sync clone)")
        return
    _schema, libsing = found
    shell = libsing.parent / "singularity-shell" / "src"
    roots = [libsing / "src", shell]
    needles = {
        "navigation-sidebar": None,
        "sidebar-row": None,
        "quick-setting-tile": None,
        "workspace-preview": None,
    }
    for root in roots:
        for f in root.rglob("*.vala"):
            text = f.read_text(errors="ignore")
            for n, where in needles.items():
                if where is None and re.search(
                    rf'add_css_class\s*\(\s*"{re.escape(n)}"', text
                ):
                    needles[n] = str(f.relative_to(libsing.parent))
    for n, where in needles.items():
        if where is None:
            err(
                f"selector class .{n} not found in libsingularity/singularity-shell sources"
            )
    # .selected is a CLASS applied to workspace cards.
    ov = shell / "components" / "overview" / "workspace_overview.vala"
    if ov.is_file() and 'add_css_class("selected")' not in ov.read_text():
        err(
            "workspace_overview.vala no longer marks the current card with class 'selected'"
        )


def check_patch_applies() -> None:
    if not PATCH.is_file():
        err(f"missing overlay patch {PATCH.relative_to(REPO)}")
        return
    found = find_schema()
    if found is None:
        skip("overlay patch git apply --check skipped (no singularity-sync clone)")
        return
    _schema, libsing = found
    base = ["git", "-C", str(libsing), "apply", "--check"]
    forward = subprocess.run(
        [*base, str(PATCH)], capture_output=True, text=True, check=False
    )
    if forward.returncode == 0:
        return
    # Already-applied is a valid state (the build applies it in place); the
    # apply-downstream-patches.sh idempotency check treats it the same way.
    reverse = subprocess.run(
        [*base, "--reverse", str(PATCH)], capture_output=True, text=True, check=False
    )
    if reverse.returncode != 0:
        err(
            "overlay patch neither applies to nor is present in the current "
            "libsingularity checkout:\n" + forward.stderr.strip()
        )


def check_patch_documents_upstream() -> None:
    readme = (REPO / "assets" / "singularity" / "patches" / "README.md").read_text()
    if "0002-user-theme-loads-above-base.patch" not in readme:
        err(
            "patches/README.md does not document 0002-user-theme-loads-above-base.patch"
        )
    if "Mirko" not in readme:
        err("patches/README.md does not state the change is proposed to Mirko Brombin")


# ----------------------------------------------------------------- harness
def run() -> int:
    gen = load_gen()
    tokens = json.loads(TOKENS.read_text())
    check_generated_matches_tokens(gen, tokens)
    check_generator_not_handcopied()
    check_schema_compiles()
    check_theme_installed(gen, tokens)
    check_theme_colors_and_selectors()
    check_selectors_exist_in_shell()
    check_patch_applies()
    check_patch_documents_upstream()

    for s in skips:
        print(f"SKIP: {s}")
    if errors:
        print("\nFAIL", *errors, sep="\n  ")
        return 1
    print("\nOK: Cygnus Singularity theme/accent integration gates pass")
    return 0


def test_cygnus_singularity_integration():
    assert run() == 0


if __name__ == "__main__":
    sys.exit(run())
