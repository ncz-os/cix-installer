# Cygnus 26.10 Singularity theme integration

Status: **wired in as the default** (item I of the Cygnus 26.10 integration).
The old Maximilian red accent is gone from the out-of-box defaults.

## What ships

| Piece | Path | Installed to |
|---|---|---|
| Theme | `assets/branding/singularity-theme/Cygnus/` (generated) | `/usr/share/themes/Cygnus/` |
| Override block | `assets/branding/singularity-theme/99-ncz-cygnus.gschema.override` (generated) | base of `/opt/singularity/share/glib-2.0/schemas/99-ncz-defaults.gschema.override` |

Both are generated from `branding/cygnus/tokens.json` by
`branding/cygnus/tools/gen-cygnus.py`; never edit the generated copies.

`post-install/20-desktop.sh`:

1. copies the theme tree to `/usr/share/themes/Cygnus` (a
   libsingularity `StyleManager.find_theme_dir()` search path) and normalizes
   modes (dirs 0755, files 0644);
2. starts the packaged `99-ncz-defaults.gschema.override` from the generated
   block (`accent-color='custom'`, `custom-accent-color='#D6208C'`,
   `custom-accent-colors=[...]`, `singularity-theme='Cygnus'`,
   `theme-mode='dark'`, `dark-mode=true`) and appends its non-Cygnus keys, so a
   token change flows through with no hex literal in the script.

The accent and the cyan focus rings / selection tint work on a stock
libsingularity. The violet-black surfaces need the NCZ overlay patch
`assets/singularity/patches/libsingularity/0002-user-theme-loads-above-base.patch`,
which raises the user theme provider above the base palette. The same change
is proposed upstream to Mirko Brombin (the maintainer) but is **not filed** by
this task; see `singularity/UPSTREAM-NOTE.md`.

## Verification

- `make test-cygnus-branding` (also wired into `make parity` and
  `make test-platform`): generator freshness (`gen-cygnus.py --check`), the
  contrast gate, the `20-desktop.sh` override == token-derived values, a
  `glib-compile-schemas --strict --dry-run` compile of the combined override
  against the real `dev.sinty.desktop` schema, theme install-path and
  named-color/selector checks, and `git apply --check` of the overlay patch.
- `branding/cygnus/tests/test_cygnus_singularity.py` is the integration gate.
