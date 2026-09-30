# Singularity theme priority: what Cygnus can and cannot set today

**Status:** this comes from reading the code (upstream libsingularity, HEAD as
of 2026-09-25). It has not yet been confirmed on a running session. Confirm it
on a real host before raising it upstream.

## What upstream documents

`singularity-themes/themes/SingularityExample/singularity/style.css` says a
theme's `style.css` "is loaded above the built-in libsingularity base, so any
rule here overrides the default Singularity look".

## What the code does

`libsingularity/src/style/style_manager.vala`:

| Provider | GTK priority |
|---|---|
| Base palette + structure + accent (`style.css`, `style.dark.css` / `style.light.css`, accent block): one provider | `GTK_STYLE_PROVIDER_PRIORITY_USER` (800) |
| Switch/toggle accent overrides | `USER + 1` (801) |
| Recolor provider | `USER + 2` (802) |
| User theme `singularity/style.css` | `APPLICATION + 5` (605) |
| User theme `style-dark.css` / `style-light.css` | `APPLICATION + 6` (606) |

In GTK, a provider with a higher priority wins regardless of selector
specificity, and a named color resolves from the highest-priority provider
that defines it. So a user theme:

- **can** add properties the base leaves unset, and can use its own named colors (`@cygnus_cyan`),
- **can** follow the user's accent through `@accent_color`,
- **cannot** override a base named color (`@window_bg`, `@surface_bg`, `@text_color`, ...) or any property the base already sets.

## What this means for Cygnus

| Cygnus element | Works today? |
|---|---|
| Magenta accent: `accent-color='custom'`, `custom-accent-color='#D6208C'` (gschema override) | Yes. This is the setting path upstream supports. |
| Cyan focus ring, cyan links, magenta-to-cyan progress, selection tint (theme rules using `cygnus_*` names) | Yes, where the base does not already set the same property |
| Violet-black surfaces (`window_bg`, `surface_*`, `panel_bg`, ...) redefined in `style-dark.css` | **No**, until the theme loads above the base |

## Proposed upstream fix (for Mirko: not filed, not patched here)

Load the user theme providers above the base, as the template already
documents: for example `PRIORITY_USER + 3` for `style.css` and `PRIORITY_USER
+ 4` for the variant, so a theme can also override the accent providers only
where it chooses to. This is a small, general fix that matches what the
template promises, and it is not NCZ-specific. Following the contribution
rules, it should be proposed upstream first. It should become an NCZ overlay
patch (`assets/singularity/patches/libsingularity/`) only if the operator asks
for that before upstream decides.
