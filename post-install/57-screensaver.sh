#!/bin/bash
# 57-screensaver.sh — NCZ native Wayland screensaver / idle-lock, CONFIGURABLE.
#
# In Singularity (as in the standard Wayland model) the screen LOCK *is* the
# screensaver — there is no separate animated screensaver program. So "the
# screensaver" here = the idle -> lock behavior, and the lock SURFACE is the
# native Singularity lockscreen (/opt/singularity/bin/singularity-lockscreen,
# GTK4/Mali, singularity-loginui). This hook ships the whole stack AND a real,
# discoverable configuration UI so the operator controls it — not hardcoded
# timeouts:
#
#   idle timer   : swayidle (a wlroots ext-idle-notify-v1 client — NOT X11)
#   lock surface : /opt/singularity/bin/singularity-lockscreen via
#                  /usr/local/bin/ncz-lock (swaylock only as last-resort fallback)
#   display off  : wlopm (wlr-output-power-management) DPMS-off
#   config store : the dev.ncz.screensaver GSettings schema (5 keys)
#   config UI    : "Screensaver & Lock" — /usr/local/bin/ncz-screensaver-settings,
#                  a native GTK4/libadwaita app (Mali-accelerated), in the
#                  Singularity launcher under Settings
#   driver       : /usr/local/bin/ncz-idle-manager reads the schema, builds the
#                  swayidle args, and RESTARTS swayidle live when a setting
#                  changes (gsettings monitor) — no re-login needed
#
# ncz-idle-manager is launched (socket-gated, backgrounded) by
# /usr/local/bin/ncz-singularity (written in 20-desktop.sh).
#
# NOTE: earlier builds claimed a dev.sinty.lockscreen-driven config with a
# Singularity Settings panel. dev.sinty.lockscreen exists (Singularity ships it,
# 3 keys) but there is NO singularity-settings binary to host a panel and no NCZ
# config UI — so it was not operator-controllable. This hook supersedes that with
# the NCZ-owned dev.ncz.screensaver schema + the standalone GTK4 app, and removes
# the stale ncz-screensaver daemon + dev.sinty.lockscreen override.
#
# Config-only + idempotent. Safe in chroot (writes files + compiles the schema;
# starts no daemon). RUNS INSIDE CHROOT (build-squashfs-layers.sh desktop loop /
# run-all.sh) and on a live rootfs (O6N).
set -uo pipefail

echo "[57] NCZ native Wayland screensaver + config (swayidle -> singularity-lockscreen)"

VARIANT=desktop
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
fi
case "$VARIANT" in
    server|headless)
        echo "[57] BUILD_VARIANT=$VARIANT — headless SKU; skipping screensaver"
        exit 0
        ;;
esac

# ---------------------------------------------------------------------------
# 1) Purge the retired X11 xscreensaver + scrub any config a prior build left.
# ---------------------------------------------------------------------------
if dpkg -l xscreensaver 2>/dev/null | grep -q '^ii'; then
    echo "[57] purging xscreensaver (X11 — wrong stack for Wayland/Mali)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y xscreensaver 2>&1 | tail -3 || true
fi
rm -f /etc/skel/.xscreensaver /etc/xdg/autostart/xscreensaver.desktop 2>/dev/null || true
for h in /home/*; do [ -f "$h/.xscreensaver" ] && rm -f "$h/.xscreensaver" 2>/dev/null || true; done

# Retire the prior, non-configurable daemon + its dev.sinty.lockscreen override
# (superseded by ncz-idle-manager + dev.ncz.screensaver below).
rm -f /usr/local/bin/ncz-screensaver 2>/dev/null || true
rm -f /opt/singularity/share/glib-2.0/schemas/98-ncz-screensaver.gschema.override 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2) Install the Wayland idle/lock utilities (offline from the bundled pool;
#    also listed in manifests/desktop.pkgs so they're in the closure).
# ---------------------------------------------------------------------------
NEED=""
for p in swayidle swaylock wlopm; do
    dpkg -l "$p" 2>/dev/null | grep -q '^ii' || NEED="$NEED $p"
done
if [ -n "$NEED" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $NEED 2>&1 | tail -3 || \
        echo "[57] WARN: idle/lock utils not fully installed:$NEED (swayidle is required)"
fi

install -d -m0755 /usr/local/bin

# ---------------------------------------------------------------------------
# 3) ncz-lock — idempotent native lock wrapper. The lock SURFACE is always the
#    native Singularity lockscreen (Mali GLES, on-brand singularity-loginui);
#    swaylock is only a last-resort fallback if that binary is unavailable.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-lock <<'LOCK'
#!/bin/sh
# ncz-lock — lock the screen with the native Singularity lockscreen (Wayland,
# Mali-accelerated), idempotent (never double-locks). Falls back to swaylock ONLY
# if the native lock binary is unavailable. Wayland-native; no X11.
# The already-locked guard MUST use pgrep -f, not -x.
#
# pgrep -x matches the kernel comm, which is truncated to 15 characters.
# "singularity-lockscreen" is 22, so -x could NEVER match it -- pgrep even says
# so on stderr: "pattern that searches for process name longer than 15
# characters will result in zero matches". The guard has therefore never fired,
# and ncz-lock would happily start a SECOND lock client on top of a live one.
#
# That is not cosmetic. ext-session-lock allows exactly one lock client, and if
# a lock client goes away without unlock_and_destroy the compositor is required
# to keep the session locked with no client left to draw a prompt -- labwc does
# exactly this (src/session-lock.c: "manager->locked remains true and
# lock_outputs still hides the screens"). The result is a permanently black
# screen that only a reboot clears. A guard that cannot fire is one race away
# from that.
#
# -f matches the full command line, where the path is intact. swaylock is 8
# characters so -x is still correct for it.
if pgrep -f "/opt/singularity/bin/singularity-lockscreen" >/dev/null 2>&1 \
   || pgrep -x swaylock >/dev/null 2>&1; then
    exit 0
fi
# Keep the lock client's stderr. Without this it goes nowhere: swayidle execs
# ncz-lock which execs the locker, and nothing captures its output -- so when
# the lock screen stopped accepting keystrokes three times in one day there was
# no evidence at all to work from, only guesses. The locker reports whether its
# keymap loaded ("keymap accepted, keyboard ready") and names the reason when it
# does not; that single line is the difference between diagnosing this and
# theorising about it. Truncated per lock so the file cannot grow without bound.
NCZ_LOCK_LOG=${XDG_RUNTIME_DIR:-/tmp}/ncz-lock.log
if [ -x /opt/singularity/bin/singularity-lockscreen ]; then
    exec /opt/singularity/bin/singularity-lockscreen "$@" 2>"$NCZ_LOCK_LOG"
elif command -v swaylock >/dev/null 2>&1; then
    exec swaylock -f -c 000000
fi
exit 0
LOCK
chmod 0755 /usr/local/bin/ncz-lock

# ---------------------------------------------------------------------------
# 4) dev.ncz.screensaver GSettings schema — the operator-facing configuration
#    (5 keys). Shipped in the SYSTEM schema dir so `gsettings ... dev.ncz.
#    screensaver` resolves with no GSETTINGS_SCHEMA_DIR override (the manager and
#    the settings app both rely on that).
# ---------------------------------------------------------------------------
SYS_SCHEMADIR=/usr/share/glib-2.0/schemas
install -d -m0755 "$SYS_SCHEMADIR"
cat > "$SYS_SCHEMADIR/dev.ncz.screensaver.gschema.xml" <<'GSCHEMA'
<?xml version="1.0" encoding="UTF-8"?>
<!-- NCZ-OS native screensaver / idle-lock configuration.
     Read live by /usr/local/bin/ncz-idle-manager (drives swayidle) and exposed
     to the operator by the "Screensaver & Lock" GTK4 settings app. -->
<schemalist>
  <schema id="dev.ncz.screensaver" path="/dev/ncz/screensaver/">
    <key name="screensaver-enabled" type="b">
      <default>true</default>
      <summary>Screensaver Enabled</summary>
      <description>Master switch. When false, idle-lock and display-off are disabled entirely (no swayidle).</description>
    </key>
    <key name="lock-enabled" type="b">
      <default>true</default>
      <summary>Lock On Idle</summary>
      <description>Whether the screen locks after the idle timeout. When false, the display still blanks/powers off but the screen is not locked.</description>
    </key>
    <key name="idle-lock-delay" type="i">
      <range min="0" max="86400"/>
      <default>300</default>
      <summary>Idle Lock Delay</summary>
      <description>Seconds of inactivity before the screen locks. 0 means never auto-lock.</description>
    </key>
    <key name="display-off-delay" type="i">
      <range min="0" max="86400"/>
      <default>360</default>
      <summary>Display Off Delay</summary>
      <description>Seconds of inactivity before the display powers off (DPMS via wlopm). 0 means never power off the display.</description>
    </key>
    <key name="lock-on-suspend" type="b">
      <default>true</default>
      <summary>Lock On Suspend</summary>
      <description>Whether to lock the screen when the system suspends.</description>
    </key>
  </schema>
</schemalist>
GSCHEMA
glib-compile-schemas "$SYS_SCHEMADIR" 2>&1 | tail -1 || \
    echo "[57] WARN: glib-compile-schemas $SYS_SCHEMADIR failed (compiles on first session)"
echo "[57] dev.ncz.screensaver schema installed (enabled/300s lock/360s display-off/lock-on-suspend)"

# ---------------------------------------------------------------------------
# 5) ncz-idle-manager — reads dev.ncz.screensaver, drives swayidle, and restarts
#    it live on any settings change (gsettings monitor). Replaces the old
#    ncz-screensaver daemon.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-idle-manager <<'IDLEMGR'
#!/bin/bash
# ncz-idle-manager — NCZ-OS native Wayland screensaver / idle-lock manager.
#
# Reads the dev.ncz.screensaver GSettings schema, builds the swayidle argument
# list from it, and runs swayidle. It then watches the schema with
# `gsettings monitor` and RESTARTS swayidle whenever the operator changes a
# setting in the "Screensaver & Lock" app — so a change takes effect live, no
# re-login required. 100% Wayland-native (swayidle is a wlroots
# ext-idle-notify-v1 client), no X11.
#
# Schema keys (dev.ncz.screensaver):
#   screensaver-enabled (b) — master; false => no idle-lock, no display-off
#   lock-enabled        (b) — false => blank/DPMS only, screen not locked
#   idle-lock-delay     (i) — seconds before lock        (0 = never lock)
#   display-off-delay   (i) — seconds before DPMS off     (0 = never blank)
#   lock-on-suspend     (b) — lock on system suspend
#
# Launched (socket-gated, backgrounded) by /usr/local/bin/ncz-singularity.
command -v swayidle  >/dev/null 2>&1 || exit 0
command -v gsettings >/dev/null 2>&1 || exit 0

SCHEMA=dev.ncz.screensaver
# Schema must be installed/compiled; otherwise do nothing (fail safe).
gsettings list-keys "$SCHEMA" >/dev/null 2>&1 || exit 0

LOCK=/usr/local/bin/ncz-lock
[ -x "$LOCK" ] || LOCK=/opt/singularity/bin/singularity-lockscreen

RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
FIFO="$RT/ncz-idle-manager.$$.fifo"
SWAYIDLE_PID=""
MON_PID=""

gb() { # boolean key -> "true"/"false"
    v=$(gsettings get "$SCHEMA" "$1" 2>/dev/null)
    [ "$v" = "true" ] && echo true || echo false
}
gi() { # int key with fallback $2
    v=$(gsettings get "$SCHEMA" "$1" 2>/dev/null)
    case "$v" in ''|*[!0-9]*) echo "$2" ;; *) echo "$v" ;; esac
}

stop_swayidle() {
    # Terminate our swayidle child and REAP it (wait) before returning, so a
    # rapid burst of settings changes can never leak overlapping swayidle
    # instances. swayidle exits promptly on SIGTERM (running its resume cmds).
    if [ -n "$SWAYIDLE_PID" ]; then
        kill "$SWAYIDLE_PID" 2>/dev/null
        wait "$SWAYIDLE_PID" 2>/dev/null
    fi
    SWAYIDLE_PID=""
}

start_swayidle() {
    stop_swayidle
    if [ "$(gb screensaver-enabled)" = "false" ]; then
        echo "[ncz-idle-manager] screensaver disabled — swayidle not running"
        return
    fi
    lock_en=$(gb lock-enabled)
    idle=$(gi idle-lock-delay 300)
    dpms=$(gi display-off-delay 360)
    los=$(gb lock-on-suspend)

    have_action=0
    set -- -w
    # Lock on idle.
    if [ "$lock_en" = "true" ] && [ "$idle" -gt 0 ]; then
        set -- "$@" timeout "$idle" "$LOCK"
        have_action=1
    fi
    # Lock on suspend (before-sleep).
    if [ "$lock_en" = "true" ] && [ "$los" = "true" ]; then
        set -- "$@" before-sleep "$LOCK"
        have_action=1
    fi
    # Display power-off (DPMS) via wlopm.
    if command -v wlopm >/dev/null 2>&1 && [ "$dpms" -gt 0 ]; then
        set -- "$@" timeout "$dpms" "wlopm --off '*'" resume "wlopm --on '*'"
        have_action=1
    fi

    if [ "$have_action" -eq 0 ]; then
        echo "[ncz-idle-manager] no idle actions configured — swayidle idle"
        return
    fi
    swayidle "$@" &
    SWAYIDLE_PID=$!
    echo "[ncz-idle-manager] swayidle up (pid $SWAYIDLE_PID): lock=$lock_en idle=${idle}s dpms=${dpms}s suspend=$los"
}

cleanup() {
    stop_swayidle
    [ -n "$MON_PID" ] && kill "$MON_PID" 2>/dev/null
    rm -f "$FIFO"
    exit 0
}
trap cleanup INT TERM EXIT

# Clear any stray swayidle left by a previous manager / the old autostart before
# we take ownership (single desktop session; production launches only us).
pkill -x swayidle 2>/dev/null
sleep 0.2

start_swayidle

# Live reconfigure: gsettings monitor emits a line per change. Pipe it through a
# FIFO so the read loop runs in THIS shell (not a subshell) and can track the
# swayidle PID across restarts.
rm -f "$FIFO"
if mkfifo "$FIFO" 2>/dev/null; then
    gsettings monitor "$SCHEMA" > "$FIFO" 2>/dev/null &
    MON_PID=$!
    while IFS= read -r _line; do
        # Debounce: swallow a burst of rapid changes (e.g. the settings app
        # writing several keys at once) so we rebuild swayidle just once.
        while IFS= read -r -t 0.4 _more; do :; done
        echo "[ncz-idle-manager] settings changed ($_line) — reloading"
        start_swayidle
    done < "$FIFO"
else
    # No FIFO available: fall back to a static swayidle (still honors settings at
    # launch, just not live). Wait on the child so the manager stays alive.
    [ -n "$SWAYIDLE_PID" ] && wait "$SWAYIDLE_PID"
fi
IDLEMGR
chmod 0755 /usr/local/bin/ncz-idle-manager

# ---------------------------------------------------------------------------
# 6) ncz-screensaver-settings — the "Screensaver & Lock" config UI. Native GTK4
#    + libadwaita (same GTK4/Mali stack as the Singularity shell), on-brand NCZ
#    red accent + dark. Reads/writes dev.ncz.screensaver; changes take effect
#    live via ncz-idle-manager's gsettings monitor.
# ---------------------------------------------------------------------------
cat > /usr/local/bin/ncz-screensaver-settings <<'PYAPP'
#!/usr/bin/env python3
# ncz-screensaver-settings — "Screensaver & Lock" settings app for NCZ-OS
# Singularity. Native GTK4 + libadwaita (the same GTK4/Mali stack the Singularity
# shell uses — rendered on CIX Mali GLES), on-brand NCZ red accent, dark.
#
# It reads/writes the dev.ncz.screensaver GSettings schema. /usr/local/bin/
# ncz-idle-manager watches that schema and restarts swayidle live, so a change
# here takes effect immediately (or on next login at the latest).
import os

# Render on CIX Mali GLES via GTK4's GL renderer (there is no Vulkan on the Mali
# blob; without this GTK4 probes Vulkan and prints red init-failure noise). Set
# before GTK is initialized. Honors an explicit override if the operator set one.
os.environ.setdefault("GSK_RENDERER", "gl")
os.environ.setdefault("GDK_BACKEND", "wayland")

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Gtk, Adw, Gio  # noqa: E402

SCHEMA = "dev.ncz.screensaver"
NCZ_RED = "#e0121f"

# Force the on-brand red accent + dark, regardless of portal availability (labwc
# exposes no accent portal, so libadwaita would otherwise fall back to blue).
_CSS = f"""
@define-color accent_color {NCZ_RED};
@define-color accent_bg_color {NCZ_RED};
@define-color accent_fg_color #ffffff;
"""


def _minutes(seconds):
    return max(0, int(round(seconds / 60.0)))


class Window(Adw.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Screensaver & Lock")
        self.set_default_size(520, 560)
        self.settings = Gio.Settings.new(SCHEMA)
        self._guard = False

        toolbar = Adw.ToolbarView()
        header = Adw.HeaderBar()
        toolbar.add_top_bar(header)

        page = Adw.PreferencesPage()

        # --- Screensaver group ------------------------------------------------
        g_main = Adw.PreferencesGroup(
            title="Screensaver",
            description="Lock the screen and power off the display after a period of inactivity.",
        )
        self.row_enabled = Adw.SwitchRow(
            title="Enable screensaver",
            subtitle="Master switch for idle locking and display power-off",
        )
        self.settings.bind(
            "screensaver-enabled", self.row_enabled, "active",
            Gio.SettingsBindFlags.DEFAULT,
        )
        g_main.add(self.row_enabled)
        page.add(g_main)

        # --- Lock group -------------------------------------------------------
        g_lock = Adw.PreferencesGroup(title="Screen Lock")
        self.row_lock = Adw.SwitchRow(
            title="Lock screen when idle",
            subtitle="Require the password after the idle timeout",
        )
        self.settings.bind(
            "lock-enabled", self.row_lock, "active",
            Gio.SettingsBindFlags.DEFAULT,
        )
        g_lock.add(self.row_lock)

        self.row_idle = Adw.SpinRow(
            title="Idle timeout",
            subtitle="Minutes of inactivity before the screen locks",
            adjustment=Gtk.Adjustment(lower=1, upper=240, step_increment=1, page_increment=5),
        )
        g_lock.add(self.row_idle)

        self.row_suspend = Adw.SwitchRow(
            title="Lock on suspend",
            subtitle="Lock the screen whenever the system suspends",
        )
        self.settings.bind(
            "lock-on-suspend", self.row_suspend, "active",
            Gio.SettingsBindFlags.DEFAULT,
        )
        g_lock.add(self.row_suspend)
        page.add(g_lock)

        # --- Display group ----------------------------------------------------
        g_disp = Adw.PreferencesGroup(title="Display")
        self.row_dpms = Adw.SpinRow(
            title="Display off timeout",
            subtitle="Minutes of inactivity before the display powers off",
            adjustment=Gtk.Adjustment(lower=0, upper=240, step_increment=1, page_increment=5),
        )
        g_disp.add(self.row_dpms)
        page.add(g_disp)

        toolbar.set_content(page)
        self.set_content(toolbar)

        # Seconds<->minutes wiring for the two spin rows (schema stores seconds,
        # UI shows minutes).
        self._load_minutes()
        self.row_idle.connect("changed", self._on_idle_changed)
        self.row_dpms.connect("changed", self._on_dpms_changed)
        self.settings.connect("changed::idle-lock-delay", lambda *_: self._load_minutes())
        self.settings.connect("changed::display-off-delay", lambda *_: self._load_minutes())

        # Enable/disable dependent rows.
        self._sync_sensitivity()
        self.row_enabled.connect("notify::active", lambda *_: self._sync_sensitivity())
        self.row_lock.connect("notify::active", lambda *_: self._sync_sensitivity())

    def _load_minutes(self):
        self._guard = True
        self.row_idle.set_value(_minutes(self.settings.get_int("idle-lock-delay")))
        self.row_dpms.set_value(_minutes(self.settings.get_int("display-off-delay")))
        self._guard = False

    def _on_idle_changed(self, row):
        if self._guard:
            return
        self.settings.set_int("idle-lock-delay", int(row.get_value()) * 60)

    def _on_dpms_changed(self, row):
        if self._guard:
            return
        self.settings.set_int("display-off-delay", int(row.get_value()) * 60)

    def _sync_sensitivity(self):
        on = self.row_enabled.get_active()
        for r in (self.row_lock, self.row_dpms, self.row_suspend):
            r.set_sensitive(on)
        # Idle timeout only matters when locking is on.
        self.row_idle.set_sensitive(on and self.row_lock.get_active())


class App(Adw.Application):
    def __init__(self):
        super().__init__(application_id="dev.ncz.screensaver")

    def do_startup(self):
        Adw.Application.do_startup(self)
        # Dark to match the Singularity shell (no display needed for this).
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.PREFER_DARK)

    def do_activate(self):
        win = self.props.active_window
        if not win:
            win = Window(self)
            # Apply the on-brand red accent to this window's display (which now
            # exists — doing it in do_startup can hit a None default display).
            css = Gtk.CssProvider()
            css.load_from_data(_CSS.encode("utf-8"))
            Gtk.StyleContext.add_provider_for_display(
                win.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            )
        win.present()


if __name__ == "__main__":
    import sys

    sys.exit(App().run(sys.argv))
PYAPP
chmod 0755 /usr/local/bin/ncz-screensaver-settings

# ---------------------------------------------------------------------------
# 7) Launcher entry — "Screensaver & Lock" in the Singularity app grid, Settings
#    category. Installed into the canonical NCZ launcher dir (on the session
#    XDG_DATA_DIRS, ahead of /usr/share).
# ---------------------------------------------------------------------------
APPDIR=/opt/singularity/share/applications
install -d -m0755 "$APPDIR"
cat > "$APPDIR/dev.ncz.screensaver.desktop" <<'DESK'
[Desktop Entry]
Version=1.0
Type=Application
Name=Screensaver & Lock
GenericName=Screensaver and screen lock settings
Comment=Configure the screensaver, idle screen lock, and display power-off
Exec=/usr/local/bin/ncz-screensaver-settings
Icon=preferences-desktop-screensaver
Terminal=false
StartupNotify=true
StartupWMClass=dev.ncz.screensaver
Categories=Settings;DesktopSettings;System;
Keywords=screensaver;lock;idle;screen;power;display;blank;timeout;suspend;dpms;
DESK
update-desktop-database "$APPDIR" 2>/dev/null || true
echo "[57] 'Screensaver & Lock' config app + launcher installed"

echo "[57] native Wayland screensaver installed (configurable: dev.ncz.screensaver + ncz-idle-manager + GTK4 app; xscreensaver purged)"
exit 0
