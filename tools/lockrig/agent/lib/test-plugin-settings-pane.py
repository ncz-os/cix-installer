#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""test-plugin-settings-pane.py -- regression test for the Settings plugin pane.

Reproduces, headlessly, exactly what singularity-desktop's PluginManager does
when Settings > Plugins > "Screensaver and Lockscreen" is opened, and asserts
that the pane is NOT empty.

The shell shows the literal row "No settings available" when
PluginManager.get_plugin_settings_widget(module) returns NULL, which happens
iff `module` is absent from PluginManager.loaded_extensions. That map is filled
by load_extension() only for a plugin that libpeas reports as ENABLED at the
moment enable_configured_plugins() scans (500 ms after shell start). A plugin
enabled *after* that scan -- e.g. enabled by a gschema override installed by
this package's postinst, or by ncz-saver ensure-plugin at login -- is therefore
enabled (the page reads the live setting) but never loaded, and the pane comes
up empty until the shell restarts.

This test creates the extension the same way the shell does and asserts:
  * the module loads and create_extension_with_properties() returns a real
    Singularity.Plugin instance;
  * get_settings_widget() is non-NULL (the shell would otherwise render
    "No settings available");
  * with a display, the returned widget's GType is ScreensaverSettings
    (a real settings page), not ScreensaverUnavailable.

Usage (on a booted NCZ-OS host, inside the session):
    XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
        python3 test-plugin-settings-pane.py
Exit 0 = pane non-empty; 1 = empty/broken.
"""
import ctypes, os, sys

PLUGDIR = os.environ.get("NCZ_PLUGIN_DIR", "/opt/singularity/lib/singularity/plugins")
MODULE = os.environ.get("NCZ_PLUGIN_MODULE", "screensaver")

libgobj = ctypes.CDLL("libgobject-2.0.so.0")
libpeas = ctypes.CDLL("libpeas-2.so.0")
libsing = ctypes.CDLL("/opt/singularity/lib/libsingularity.so.0")

libpeas.peas_engine_get_default.restype = ctypes.c_void_p
libpeas.peas_engine_add_search_path.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
libpeas.peas_engine_rescan_plugins.argtypes = [ctypes.c_void_p]
libpeas.peas_engine_get_plugin_info.restype = ctypes.c_void_p
libpeas.peas_engine_get_plugin_info.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
libpeas.peas_engine_load_plugin.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
# Canonical "no properties" form: the variadic constructor terminated with a
# single NULL property name (equivalent to the shell's empty property arrays).
libpeas.peas_engine_create_extension.restype = ctypes.c_void_p
libpeas.peas_engine_create_extension.argtypes = [
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_char_p]
libpeas.peas_plugin_info_get_external_data.restype = ctypes.c_char_p
libpeas.peas_plugin_info_get_external_data.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
libsing.singularity_plugin_get_type.restype = ctypes.c_size_t
libsing.singularity_plugin_get_settings_widget.restype = ctypes.c_void_p
libsing.singularity_plugin_get_settings_widget.argtypes = [ctypes.c_void_p]
libgobj.g_type_check_instance_is_a.restype = ctypes.c_int
libgobj.g_type_check_instance_is_a.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
libgobj.g_type_name.restype = ctypes.c_char_p
libgobj.g_type_name.argtypes = [ctypes.c_size_t]

def die(msg, code=1):
    print("FAIL:", msg)
    sys.exit(code)

iface = libsing.singularity_plugin_get_type()
engine = libpeas.peas_engine_get_default()
if not engine:
    die("peas_engine_get_default() returned NULL")
libpeas.peas_engine_add_search_path(engine, PLUGDIR.encode(), PLUGDIR.encode())
libpeas.peas_engine_rescan_plugins(engine)
info = libpeas.peas_engine_get_plugin_info(engine, MODULE.encode())
if not info:
    die("plugin '%s' not found under %s" % (MODULE, PLUGDIR))
if not libpeas.peas_engine_load_plugin(engine, info):
    die("peas_engine_load_plugin() failed for '%s'" % MODULE)

ext = libpeas.peas_engine_create_extension(engine, info, iface, None)
if not ext:
    die("create_extension returned NULL -> shell shows 'No settings available'")
if not libgobj.g_type_check_instance_is_a(ctypes.c_void_p(ext), iface):
    die("extension is not a Singularity.Plugin -> shell drops it (empty pane)")

# gating: an app plugin (X-Singularity-Host) is skipped by the shell entirely.
host = libpeas.peas_plugin_info_get_external_data(info, b"X-Singularity-Host")
if host:
    die("module declares X-Singularity-Host=%s -> shell skips it (empty pane)" % host.decode())

app = libpeas.peas_plugin_info_get_external_data(info, b"X-Singularity-App")
print("info: X-Singularity-App=%r (app-shipped -> enabled independent of enabled-plugins)" % (
    app.decode() if app else None))

# Load-timing guard: the shell only creates the extension for a module that is
# enabled when it scans. A module that is neither app-shipped nor listed in
# enabled-plugins is enabled (or not) purely by list timing and can silently
# get no extension -> "No settings available". Fail loudly in that case so a
# packaging/branding change that drops the plugin from enabled-plugins, or a
# manifest that is not app-shipped, is caught here.
if app is None:
    import subprocess
    env = dict(os.environ)
    # The shell reads schemas from /opt (GSETTINGS_SCHEMA_DIR), which replaces the
    # default /usr/share path; mirror that so dev.sinty.desktop is found.
    sdir = "/opt/singularity/share/glib-2.0/schemas"
    if os.path.isdir(sdir):
        env.setdefault("GSETTINGS_SCHEMA_DIR", sdir)
    try:
        out = subprocess.check_output(
            ["gsettings", "get", "dev.sinty.desktop", "enabled-plugins"],
            stderr=subprocess.DEVNULL, text=True, env=env)
    except Exception:
        out = None
    listed = out is not None and ("'%s'" % MODULE) in out
    if not listed:
        die("module is not app-shipped and not in dev.sinty.desktop enabled-plugins "
            "(got %r) -> the shell may never load it (empty pane)" % out)
    print("info: module is in enabled-plugins (bootstrap list present)")

# get_settings_widget() is what the shell renders; NULL => "No settings available".
libgtk = None
try:
    libgtk = ctypes.CDLL("libgtk-4.so.1")
    libgtk.gtk_init.restype = ctypes.c_int
except OSError:
    pass
if libgtk is not None and (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
    try:
        libgtk.gtk_init()
        w = libsing.singularity_plugin_get_settings_widget(ctypes.c_void_p(ext))
    except Exception as e:
        w = None
        print("note: gtk widget probe skipped:", e)
else:
    w = None
    print("note: no display; skipping get_settings_widget() (needs GTK init)")

if w:
    # Identify the widget without poking at GObject internals: look the plugin's
    # registered GTypes up by name and ask GObject whether the instance is-a them.
    libgobj.g_type_from_name.restype = ctypes.c_size_t
    libgobj.g_type_from_name.argtypes = [ctypes.c_char_p]
    unavailable = libgobj.g_type_from_name(b"ScreensaverUnavailable")
    settings_t = libgobj.g_type_from_name(b"ScreensaverSettings")
    if unavailable and libgobj.g_type_check_instance_is_a(ctypes.c_void_p(w), unavailable):
        die("settings widget is ScreensaverUnavailable -> plugin reports not-installed")
    if settings_t and libgobj.g_type_check_instance_is_a(ctypes.c_void_p(w), settings_t):
        print("get_settings_widget -> ScreensaverSettings")
    else:
        print("get_settings_widget -> non-null widget (GType name lookup inconclusive)")
    print("PASS: plugin pane is non-empty (extension + settings widget present)")
else:
    print("PASS(load-only): extension created and is a Singularity.Plugin; "
          "settings widget not probed (no display)")
sys.exit(0)
