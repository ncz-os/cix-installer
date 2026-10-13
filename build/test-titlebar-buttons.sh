#!/bin/bash
# test-titlebar-buttons.sh -- every window has minimize, maximize and close
# buttons by default (post-install/65-ncz-titlebar-buttons.sh).
#
# The default must be SYSTEM-wide (a GSettings schema override, not a per-user
# dconf write), so it holds for the first login, for users created later and
# across package upgrades. This test FAILS when:
#   * the hook no longer sets org.gnome.desktop.wm.preferences button-layout
#     to include minimize and maximize, or sets it per user instead of as a
#     schema default;
#   * the effective default read back through GSettings lacks minimize or
#     maximize (wm.preferences schema in /usr/share or in the Singularity dir);
#   * the classic titlebar default (dev.sinty.desktop legacy-titlebar) is lost;
#   * the hook is missing from either architecture's hook list or run-all.sh;
#   * Leafs (singularity-leafs) loses the patch that keeps its toolbar, and
#     so its window buttons, in classic titlebar mode.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/65-ncz-titlebar-buttons.sh"
export G_MESSAGES_DEBUG=
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

WANT="'appmenu:minimize,maximize,close'"

# --- static checks (run everywhere) ---------------------------------------------
for p in sky1-arm64 amd64; do
    if grep -qx '65-ncz-titlebar-buttons.sh' "$ROOT/post-install/hooks.list.$p"; then ok "hook listed for $p"; else bad "hook not listed for $p"; fi
done
if grep -q '|65-ncz-titlebar-buttons|' "$ROOT/post-install/run-all.sh"; then ok "hook allowed by run-all.sh"; else bad "hook missing from run-all.sh MACHINE_HOOKS_RE"; fi
if grep -q "^BUTTON_LAYOUT=\"appmenu:minimize,maximize,close\"$" "$HOOK"; then ok "hook layout constant includes minimize and maximize"; else bad "hook layout constant changed"; fi
if grep -qE '(^|[^#]*)(gsettings set|dconf write)' "$HOOK"; then bad "hook writes a per-user setting (must be a schema default)"; else ok "hook writes no per-user setting"; fi
if grep -q '/usr/share/glib-2.0/schemas' "$HOOK"; then ok "hook targets the system schema dir"; else bad "hook does not target /usr/share/glib-2.0/schemas"; fi

# Leafs hides its window toolbar (each leaf has its own hover controls). In the
# classic titlebar mode that toolbar IS the titlebar with the window buttons, so
# the carried patch must keep the hide limited to the floating-bubbles mode.
LEAFS_PATCH="$ROOT/assets/singularity/patches/singularity-leafs/0001-window-keep-the-toolbar-in-classic-titlebar-and-ssd-modes.patch"
if [ -f "$LEAFS_PATCH" ] \
   && grep -q '^+ *if (floating_bubbles) {$' "$LEAFS_PATCH" \
   && grep -q '^- *toolbar.visible = false;$' "$LEAFS_PATCH" \
   && grep -q '^+ *toolbar.visible = false;$' "$LEAFS_PATCH"; then
    ok "Leafs keeps its titlebar buttons in classic titlebar mode (carried patch)"
else
    bad "Leafs patch missing or no longer limits the toolbar hide to floating-bubbles mode"
fi

if ! command -v glib-compile-schemas >/dev/null 2>&1 || ! command -v gsettings >/dev/null 2>&1; then
    echo "titlebar-buttons tests: $pass passed, $fail failed (functional cases need glib-compile-schemas + gsettings)"
    [ "$fail" = 0 ] || exit 1
    echo "SKIP: functional cases"; exit 0
fi

# --- fixtures --------------------------------------------------------------------
mkwm() {   # mkwm DIR -- the wm.preferences schema with the upstream default
    mkdir -p "$1"
    cat > "$1/org.gnome.desktop.wm.preferences.gschema.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="org.gnome.desktop.wm.preferences" path="/org/gnome/desktop/wm/preferences/">
    <key name="button-layout" type="s">
      <default>'appmenu:close'</default>
      <summary>b</summary>
    </key>
    <key name="num-workspaces" type="i">
      <default>4</default>
      <summary>n</summary>
    </key>
  </schema>
</schemalist>
XML
}
mkdesktop() {   # mkdesktop DIR [nokey]
    mkdir -p "$1"
    local lt='    <key name="legacy-titlebar" type="b">
      <default>false</default>
      <summary>l</summary>
    </key>'
    [ "${2:-}" = nokey ] && lt=''
    cat > "$1/dev.sinty.desktop.gschema.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<schemalist>
  <schema id="dev.sinty.desktop" path="/dev/sinty/desktop/">
    <key name="force-ssd" type="b">
      <default>false</default>
      <summary>f</summary>
    </key>
$lt
    <key name="window-rounded-corners" type="b">
      <default>true</default>
      <summary>r</summary>
    </key>
  </schema>
</schemalist>
XML
}
run() {   # run SINGULARITY_DIR GNOME_DIRS
    NCZ_TITLEBAR_SCHEMA_DIR="$1" NCZ_TITLEBAR_GNOME_SCHEMA_DIRS="$2" bash "$HOOK" >"$T/out" 2>&1
}
# eff DIRS SCHEMA KEY -- effective default through GSettings (memory backend:
# no user value, exactly what a brand-new user sees). Dirs listed first win,
# matching GSETTINGS_SCHEMA_DIR plus XDG_DATA_DIRS in the session.
eff() {
    local d out=""
    for d in $1; do glib-compile-schemas "$d" 2>/dev/null; out="${out:+$out:}$d"; done
    GSETTINGS_SCHEMA_DIR="$out" GSETTINGS_BACKEND=memory gsettings get "$2" "$3" 2>/dev/null
}

# 1. the shipped layout: wm.preferences in /usr/share, desktop schema in the
#    Singularity dir
mkwm "$T/a/usr"; mkdesktop "$T/a/opt"
run "$T/a/opt" "$T/a/usr $T/a/opt"; rc=$?
if [ "$rc" = 0 ]; then ok "hook exits 0"; else bad "hook rc=$rc: $(tail -3 "$T/out")"; fi
got=$(eff "$T/a/opt $T/a/usr" org.gnome.desktop.wm.preferences button-layout)
if [ "$got" = "$WANT" ]; then ok "new-user default button-layout = $WANT"; else bad "new-user button-layout is '$got', expected $WANT"; fi
case "$got" in *minimize*maximize*) ok "default layout has minimize and maximize" ;; *) bad "default layout lacks minimize/maximize: '$got'" ;; esac
got=$(eff "$T/a/opt $T/a/usr" dev.sinty.desktop legacy-titlebar)
if [ "$got" = true ]; then ok "classic titlebar default (legacy-titlebar) = true"; else bad "legacy-titlebar is '$got', expected true"; fi
got=$(eff "$T/a/opt $T/a/usr" org.gnome.desktop.wm.preferences num-workspaces)
if [ "$got" = 4 ]; then ok "other wm.preferences keys untouched"; else bad "num-workspaces changed to '$got'"; fi
got=$(eff "$T/a/opt $T/a/usr" dev.sinty.desktop window-rounded-corners)
if [ "$got" = true ]; then ok "other desktop keys untouched"; else bad "window-rounded-corners changed to '$got'"; fi
for d in "$T/a/usr" "$T/a/opt"; do
    if glib-compile-schemas --strict --dry-run "$d" >/dev/null 2>&1; then ok "$(basename "$d") schema dir compiles --strict"; else bad "$(basename "$d") schema dir does not compile"; fi
done

# 2. a user's own choice still wins over the default (keyfile backend = a
#    real per-user store)
mkdir -p "$T/kf"
GSETTINGS_SCHEMA_DIR="$T/a/opt:$T/a/usr" GSETTINGS_BACKEND=keyfile XDG_CONFIG_HOME="$T/kf" \
    gsettings set org.gnome.desktop.wm.preferences button-layout 'appmenu:close' 2>/dev/null
got=$(GSETTINGS_SCHEMA_DIR="$T/a/opt:$T/a/usr" GSETTINGS_BACKEND=keyfile XDG_CONFIG_HOME="$T/kf" \
    gsettings get org.gnome.desktop.wm.preferences button-layout 2>/dev/null)
if [ "$got" = "'appmenu:close'" ]; then ok "user choice overrides the default"; else bad "user choice not honoured: '$got'"; fi

# 3. idempotent
before=$(cat "$T/a/usr/99-ncz-titlebar.gschema.override" "$T/a/opt/99-ncz-titlebar.gschema.override" | cksum)
run "$T/a/opt" "$T/a/usr $T/a/opt"
after=$(cat "$T/a/usr/99-ncz-titlebar.gschema.override" "$T/a/opt/99-ncz-titlebar.gschema.override" | cksum)
if [ "$before" = "$after" ]; then ok "second run is idempotent"; else bad "second run changed the overrides"; fi

# 4. survives a package upgrade: the upgrade replaces the schema XML and
#    recompiles the dir (dpkg trigger / payload postinst); the unowned override
#    file stays and the default holds
mkwm "$T/a/usr"
got=$(eff "$T/a/opt $T/a/usr" org.gnome.desktop.wm.preferences button-layout)
if [ "$got" = "$WANT" ]; then ok "default holds after the schema is reinstalled and recompiled"; else bad "default lost after reinstall: '$got'"; fi

# 5. the payload carries its own wm.preferences copy: it shadows /usr/share in
#    the session, so the default must be set there too
mkwm "$T/b/usr"; mkwm "$T/b/opt"; mkdesktop "$T/b/opt"
run "$T/b/opt" "$T/b/usr $T/b/opt"
got=$(eff "$T/b/opt $T/b/usr" org.gnome.desktop.wm.preferences button-layout)
if [ "$got" = "$WANT" ]; then ok "default set when the Singularity dir shadows wm.preferences"; else bad "shadowed wm.preferences default is '$got'"; fi
got=$(eff "$T/b/opt $T/b/usr" dev.sinty.desktop legacy-titlebar)
if [ "$got" = true ]; then ok "legacy-titlebar still set alongside the shadowed layout"; else bad "legacy-titlebar lost with shadowed layout: '$got'"; fi

# 6. no Singularity desktop schema, or no legacy-titlebar key: the button
#    layout default is still set
mkwm "$T/c/usr"; mkdir -p "$T/c/opt"
run "$T/c/opt" "$T/c/usr $T/c/opt"; rc=$?
got=$(eff "$T/c/usr" org.gnome.desktop.wm.preferences button-layout)
if [ "$rc" = 0 ] && [ "$got" = "$WANT" ]; then ok "layout default set without the desktop schema"; else bad "without desktop schema: rc=$rc layout '$got'"; fi
if [ ! -e "$T/c/opt/99-ncz-titlebar.gschema.override" ]; then ok "no desktop override without the desktop schema"; else bad "desktop override written without the schema"; fi
mkwm "$T/d/usr"; mkdesktop "$T/d/opt" nokey
run "$T/d/opt" "$T/d/usr $T/d/opt"; rc=$?
got=$(eff "$T/d/usr" org.gnome.desktop.wm.preferences button-layout)
if [ "$rc" = 0 ] && [ "$got" = "$WANT" ]; then ok "layout default set without the legacy-titlebar key"; else bad "without legacy key: rc=$rc layout '$got'"; fi
if glib-compile-schemas --strict --dry-run "$T/d/opt" >/dev/null 2>&1; then ok "desktop dir without the key still compiles"; else bad "desktop dir without the key broken"; fi

# 7. no wm.preferences schema anywhere: warn, never break, exit 0
mkdir -p "$T/e/usr"; mkdesktop "$T/e/opt"
run "$T/e/opt" "$T/e/usr $T/e/opt"; rc=$?
if [ "$rc" = 0 ] && grep -q 'button-layout default not set' "$T/out"; then ok "missing wm.preferences schema is reported, exit 0"; else bad "missing wm.preferences: rc=$rc $(tail -2 "$T/out")"; fi

echo "titlebar-buttons tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
