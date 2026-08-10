#!/bin/bash
# build-singularity.sh — reproducible build of the NCZ-OS Singularity Desktop
# payload (/opt/singularity) for CIX Sky1 (arm64).
#
# NCZ-OS 26.7 "Maximilian" ships Singularity Desktop (labwc/wlroots, GTK4/Vala,
# GLES on CIX libmali) as THE desktop, replacing XFCE/X11. This script produces
# the canonical, rebuildable `singularity-opt.tgz` artifact that
# post-install/20-desktop.sh extracts to /opt/singularity at desktop-layer bake
# time. Without this the tarball is a one-off; with it, the payload is
# reproducible from upstream sources.
#
# METHOD (matches the .66 bring-up build, docs/upstream/singularity/):
#   1. ubuntu:26.04 arm64 container (native aarch64 — build on cixmini/.66,
#      ULTRA, or any arm64 host with docker/podman).
#   2. clone singularityos-lab/singularity-desktop --recursive.
#   3. build the `vetro` Go host tool (UI transpiler) and put it on PATH.
#   4. meson setup --prefix=/opt/singularity --libdir=lib ; ninja ; meson install
#      to a DESTDIR stage (top project + bundled labwc/wlroots).
#   5. tar the staged /opt/singularity tree -> out/singularity-opt.tgz.
#
# The tarball extracts to `opt/singularity/...` so `tar -C / -xzf` lands it at
# /opt/singularity (it touches ONLY /opt/singularity — never /lib — so it is
# safe on a live rootfs, unlike a full rootfs/module tarball).
#
# USAGE (on an arm64 build host, e.g. .66):
#   ./build/build-singularity.sh
#   ./build/build-singularity.sh --push-argonas   # also stage on ARGONAS
#
# Outputs:
#   $OUT/singularity-opt.tgz   (default: ./build/sinty-out/singularity-opt.tgz)
set -euo pipefail

# ---- config ----------------------------------------------------------------
# Build image. STAYS ubuntu:26.04 even though the TARGET is Debian Forky, and
# the reason is specific: Forky only ships valac 0.56.19, and that compiler
# SIGBUSes ("Bus error", exit 135) building
# subprojects/singularity-plugins/emoji-search/emoji-search.vala. A debian:forky
# build was attempted and dies at [275/619]. Ubuntu 26.04 carries a newer valac
# that compiles the tree. So the distro mismatch is deliberate and forced.
#
# The mismatch has a real cost that MUST be handled rather than ignored: Ubuntu
# 26.04 has libsodium.so.23, Forky has libsodium.so.26. A payload built here
# linked singularity-keyring against .23 and died on the board with
#   error while loading shared libraries: libsodium.so.23
# That binary is the org.freedesktop.secrets provider, so desktop secrets were
# silently dead while 27 of the 28 binaries looked perfectly fine.
#
# Handled by VENDORING the divergent libraries into the payload's own lib dir
# (see the vendor step after meson install). That fits the payload's design --
# it is self-contained under /opt/singularity and the session already puts
# /opt/singularity/lib first on LD_LIBRARY_PATH.
#
# The build-container link check below CANNOT catch this class of bug, because
# in this container the soname resolves fine. The authoritative gate is the
# on-target check: after installing a payload, verify every binary in
# /opt/singularity/bin resolves. Do not skip it.
IMAGE="${SINGULARITY_IMAGE:-ubuntu:26.04}"
SRC_REPO="${SINGULARITY_REPO:-https://github.com/singularityos-lab/singularity-desktop}"
# Upstream's default branch is `master`, not `main` — `main` does not exist on
# singularityos-lab/singularity-desktop, so a bare run used to die in
# `git clone --branch`.
SRC_REF="${SINGULARITY_REF:-master}"
# Optional checked-out superproject.  This is intentionally explicit: local
# NCZ fixes must never be mistaken for an upstream main build.
SRC_DIR="${SINGULARITY_SOURCE_DIR:-}"
VETRO_REPO="${VETRO_REPO:-https://github.com/singularityos-lab/vetro}"
PREFIX="/opt/singularity"
OUT="${OUT:-$(cd "$(dirname "$0")/.." && pwd)/build/sinty-out}"
ARGONAS_DST="/mnt/datapool/archives/ncz/singularity"
PUSH_ARGONAS=0
[ "${1:-}" = "--push-argonas" ] && PUSH_ARGONAS=1

# Container engine: prefer docker, fall back to podman.
CE="$(command -v docker || command -v podman || true)"
[ -n "$CE" ] || { echo "ERROR: need docker or podman on the build host" >&2; exit 1; }
[ -z "$SRC_DIR" ] || [ -d "$SRC_DIR" ] || {
    echo "ERROR: SINGULARITY_SOURCE_DIR is not a directory: $SRC_DIR" >&2
    exit 1
}

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) ;;
    *) echo "WARN: host arch=$ARCH — Singularity payload is arm64; build MUST run on/emulate aarch64 (this container image is $IMAGE)." >&2 ;;
esac

mkdir -p "$OUT"
echo "== build-singularity =="
echo "   image  = $IMAGE"
echo "   source = $SRC_REPO @ $SRC_REF"
[ -z "$SRC_DIR" ] || echo "   local  = $SRC_DIR (explicit NCZ source override)"
echo "   prefix = $PREFIX"
echo "   out    = $OUT/singularity-opt.tgz"

# ---- in-container build script ---------------------------------------------
# Everything below runs inside the arm64 ubuntu:26.04 container. The DESTDIR
# stage is tarred and copied out via the bind-mounted /out.
BUILD_SCRIPT='
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# Build deps (Debian 13 / Ubuntu 26.04 names — see docs/upstream/singularity/
# 20-pr-arm64-build.md). No arch guards needed; the tree builds clean on aarch64.
apt-get install -y --no-install-recommends \
    ca-certificates git golang-go \
    libglib2.0-bin \
    valac meson ninja-build pkg-config gettext \
    libgtk-4-dev libadwaita-1-dev libgtk4-layer-shell-dev \
    libwayland-dev wayland-protocols \
    libvte-2.91-gtk4-dev libgtksourceview-5-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-plugins-good gstreamer1.0-pipewire \
    libpulse-dev libpolkit-gobject-1-dev libpolkit-agent-1-dev \
    libjson-glib-dev libpeas-2-dev libpipewire-0.3-dev \
    libgee-0.8-dev libsoup-3.0-dev \
    libgirepository-1.0-dev gobject-introspection \
    libupower-glib-dev \
    libatspi2.0-dev libcmocka-dev libdbusmenu-glib-dev libfontconfig-dev \
    libglib2.0-dev libgudev-1.0-dev libinput-dev libnm-dev \
    libpng-dev librsvg2-dev libsecret-1-dev libxml2-dev libpixman-1-dev \
    libpoppler-glib-dev libsystemd-dev libtracker-sparql-3.0-dev \
    libupower-glib-dev \
    libwebkitgtk-6.0-dev libxcb1-dev libxcb-ewmh-dev \
    libxcb-icccm4-dev libxkbcommon-dev \
    libpam0g-dev libgcrypt20-dev libcrypt-dev libsodium-dev \
    hwdata xwayland libxcb-dri3-dev \
    libxcb-composite0-dev libxcb-render0-dev libxcb-res0-dev \
    libxcb-xfixes0-dev libxcb-errors-dev libxcb-present-dev \
    sassc scdoc \
    libdisplay-info-dev \
    libseat-dev \
    libliftoff-dev \
    libnm-dev \
    libgoa-1.0-dev \
    sassc \
    libdrm-dev libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev \
    libinput-dev \
    libpoppler-glib-dev \
    hwdata \
    scdoc \
    libdisplay-info-dev \
    libseat-dev \
    libliftoff-dev \
    build-essential

mkdir -p /work && cd /work

# vetro host tool (UI .vetro -> .ui transpiler). Go 1.24+.
git clone --depth 1 "'"$VETRO_REPO"'" vetro
( cd vetro && go build -o /usr/local/bin/vetro . )
vetro --version 2>/dev/null || true

# Singularity Desktop (recursive: bundled labwc/wlroots + subprojects).  The
# local override is for reviewed NCZ commits that have not yet been published
# upstream; it is mounted read-only and copied into the disposable container
# workspace before any build writes occur.
if [ -n "${SINGULARITY_SOURCE_DIR:-}" ]; then
    cp -a "$SINGULARITY_SOURCE_DIR" singularity-desktop
else
    git clone --recursive --branch "'"$SRC_REF"'" "'"$SRC_REPO"'" singularity-desktop
fi
cd singularity-desktop

# NCZ shell integration: close the launcher popup before opening the full-screen
# workspace chooser.
#
# Upstream added a hide_overview() helper that closes app_menu, overview and the
# secondary overviews together -- but toggle_workspace_overview() does not call
# it; it only closes `overview`. The AppMenu therefore stays mapped underneath
# and the full-screen workspace chooser visually hovers over the app picker.
# Route the workspace toggle through upstream own helper.
#
# The previous form of this patch inserted lines by hand with `git apply` against
# main.vala:798. Upstream refactored that function, the hunk stopped applying and
# it FAILED THE WHOLE BUILD. Anchor on code shape and assert instead, so a future
# refactor gives a clear error rather than a silent miss.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ]; then
python3 - <<'"'"'PY_NCZ_WS'"'"'
import io
p = "subprojects/singularity-shell/src/core/main.vala"
src = io.open(p).read()
old = "        if (overview != null && overview.showing) {\n            overview.toggle();\n        }\n        if (!ensure_workspace_overview()) return;"
new = ("        // NCZ: close the launcher popup AND the app menu, not just the overview.\n"
       "        // The workspace chooser is a full-screen TOP layer; leaving AppMenu\n"
       "        // mapped lets the chooser hover over and occlude the app picker.\n"
       "        hide_overview();\n"
       "        if (!ensure_workspace_overview()) return;")
if "hide_overview();\n        if (!ensure_workspace_overview())" in src:
    print("NCZ: workspace-chooser patch already applied")
elif old in src:
    io.open(p, "w").write(src.replace(old, new, 1))
    print("NCZ: workspace chooser now closes the app menu via hide_overview()")
else:
    raise SystemExit("NCZ workspace-chooser patch: anchor not found - upstream moved, re-check")
PY_NCZ_WS
fi

# NCZ shell fix: opening the launcher, closing it, then opening it again killed
# the whole shell with
#     Gdk-Message: Error 71 (Protocol error) dispatching to Wayland display.
# and singularity-desktop exited 1. The session script respawns it, so it
# presents as "the desktop reset" rather than a crash. Fully deterministic: the
# SECOND open does it, at any speed -- adding delay between toggles does not
# help, which is what ruled out a timing race.
#
# The overview sets its layer twice: once at construction (overview.vala:59) and
# again in the show path (overview.vala:404). The layer is only ever TOP -- those
# are the only two set_layer() calls in the file -- so the second is redundant.
# But it runs after hide() has unmapped the window, so gtk4-layer-shell issues
# zwlr_layer_surface_v1.set_layer against the layer surface destroyed at unmap,
# and the compositor terminates the client. The first open works because the
# window has never been mapped and the construction-time surface is still live.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ] && ! grep -q "do NOT call set_layer" subprojects/singularity-shell/src/components/overview/overview.vala; then
python3 - <<'"'"'PY_NCZ_OVERVIEW'"'"'
p = "subprojects/singularity-shell/src/components/overview/overview.vala"
src = open(p).read()
needle = "                opacity = 0;\n                set_layer(this, GtkLayerShell.Layer.TOP);\n                present();"
repl = (
    "                opacity = 0;\n"
    "                // Do NOT call set_layer() here: the layer is set once at\n"
    "                // construction and never changes, and re-issuing it on a\n"
    "                // window hide() has unmapped is a request against a\n"
    "                // destroyed layer surface.\n"
    "                //\n"
    "                // present() is deliberately RETAINED. An earlier revision\n"
    "                // swapped it for set_visible(true) on the theory that the\n"
    "                // xdg_activation token it requests was the crash. That was\n"
    "                // WRONG -- the trace was identical afterwards. The real\n"
    "                // cause was a stale buffer on a reused wl_surface, fixed by\n"
    "                // unrealize() in the hide path below. present() carries\n"
    "                // focus semantics this window relies on, so it stays.\n"
    "                present();"
)
if needle not in src:
    raise SystemExit("NCZ overview set_layer patch: anchor not found - upstream moved, re-check")
open(p, "w").write(src.replace(needle, repl, 1))
print("NCZ: removed redundant set_layer() from overview re-show path")
PY_NCZ_OVERVIEW
fi

# NCZ shell fix #2 (the real one): the launcher crash is a REUSED wl_surface.
#
# Root cause, from WAYLAND_DEBUG=1 on the board. GTK keeps one wl_surface alive
# across hide/show; gtk4-layer-shell destroys the zwlr_layer_surface_v1 at unmap
# and creates a NEW one over that SAME wl_surface on the next open. Comparing a
# working cycle against the crashing one inside a single session:
#
#   working  (#77 -> #64)          crashing (#64 -> #82)
#   destroy()                      destroy()
#   attach(nil); commit()          attach(nil); commit()
#   <nothing>                      attach(wl_buffer#79); commit()   <-- stray
#   get_layer_surface(#64)         get_layer_surface(#82)
#   commit() -> configure OK       commit() -> ERROR 2
#
# The only difference is a frame queued by the 180ms closing animation that
# lands ~0.7ms AFTER the unmap, re-attaching a live buffer to the now-roleless
# surface. wl_surface state is persistent, so that buffer is still current when
# the next layer surface is created; its first commit therefore carries a buffer
# before any configure, which wlroots rejects with zwlr_layer_surface_v1 error 2
# "layer_surface has never been configured". Whether that frame lands is a race
# on wl_buffer.release, which is why the shell died after a VARIABLE number of
# opens instead of deterministically.
#
# Upstream has NO fix. gtk4-layer-shell issue #94 is this exact bug (same error,
# same "random after N opens", reproduces only on the gl/vulkan renderers) and
# was closed merely because Hyprland changed. PR #119 fixed the teardown
# ordering and was rejected as a smithay bug. Library main @2026-07-25 still has
# no client-side fix, so upgrading the Debian package does not help.
#
# Fix: unrealize() after hide() drops the GdkSurface, so the next open allocates
# a brand-new wl_surface that cannot carry a stale buffer. This is exactly what
# gtk4-layer-shell itself does in gtk_layer_surface_remap(), which calls
# gtk_widget_unrealize() then gtk_widget_map() -- a supported, exercised path.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ] && ! grep -q "NCZ: drop the GdkSurface" subprojects/singularity-shell/src/components/overview/overview.vala; then
python3 - <<'"'"'PY_NCZ_UNREALIZE'"'"'
p = "subprojects/singularity-shell/src/components/overview/overview.vala"
src = open(p).read()
needle = (
    "                    main_box.remove_css_class(\"animating-out\");\n"
    "                    hide();\n"
    "                    PreviewCache.get_default().clear();\n"
)
repl = (
    "                    main_box.remove_css_class(\"animating-out\");\n"
    "                    hide();\n"
    "                    // NCZ: drop the GdkSurface, do not merely unmap it.\n"
    "                    // GTK reuses one wl_surface across hide/show, and\n"
    "                    // gtk4-layer-shell builds a fresh layer surface over\n"
    "                    // it on the next open. A frame queued by the closing\n"
    "                    // animation can land after the unmap and re-attach a\n"
    "                    // live buffer; the next open then commits that stale\n"
    "                    // buffer before any configure, and the compositor\n"
    "                    // kills the client -- wl_display error 2,\n"
    "                    // layer_surface has never been configured.\n"
    "                    // unrealize() forces a fresh wl_surface next time.\n"
    "                    // Same call gtk4-layer-shell uses in its own remap.\n"
    "                    // The cast is REQUIRED: GtkWindow implements GtkNative,\n"
    "                    // so a bare unrealize() binds to gtk_native_unrealize,\n"
    "                    // an internal vfunc, not gtk_widget_unrealize. Verified\n"
    "                    // by inspecting the C valac emits for each spelling.\n"
    "                    ((Gtk.Widget) this).unrealize();\n"
    "                    PreviewCache.get_default().clear();\n"
)
if needle not in src:
    raise SystemExit("NCZ overview unrealize patch: anchor not found - re-check")
open(p, "w").write(src.replace(needle, repl, 1))
print("NCZ: overview drops its GdkSurface on hide (fresh wl_surface per open)")
PY_NCZ_UNREALIZE
fi

# NCZ shell fix #3: the SAME stale-buffer crash in EVERY layer-shell window.
#
# The launcher was only the first instance. An audit of the shell found 19
# windows calling gtk4-layer-shell init_for_window(), of which SIX hide and then
# re-show -- the cycle that triggers the fault:
#
#   dock.vala                 hide=2  show=10
#   sidebar.vala              hide=5  show=5
#   app_menu.vala             hide=4  show=1
#   hot_corner_manager.vala   hide=2  show=1
#   workspace_overview.vala   hide=4  show=2   <- operator hit this one next
#   overview.vala             hide=2  show=1   <- patched separately above
#
# Each is a distinct chance for the same crash: a frame queued by a closing
# animation re-attaches a live buffer to the now-roleless wl_surface, and the
# next open commits it before any configure --
#   wl_display error 2, layer_surface has never been configured.
#
# Patched generically rather than per-file: in a class that calls
# init_for_window(), a bare `hide();` statement IS this.hide() on the layer
# window, so every one of them needs the GdkSurface dropped. Qualified calls
# (popover.hide(), child.hide()) are deliberately NOT matched.
#
# unrealize() on a never-realized widget is a documented no-op, so the
# constructor-time hide() in workspace_overview is harmless.
#
# The proper upstream shape is a shared close helper; this is the downstream
# equivalent applied uniformly.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ]; then
python3 - <<'"'"'PY_NCZ_ALLWIN'"'"'
import io, re, sys
files = [
    "subprojects/singularity-shell/src/components/dock/dock.vala",
    "subprojects/singularity-shell/src/components/sidebar/sidebar.vala",
    "subprojects/singularity-shell/src/components/overview/app_menu.vala",
    "subprojects/singularity-shell/src/core/hot_corner_manager.vala",
    "subprojects/singularity-shell/src/components/overview/workspace_overview.vala",
]
NOTE = "NCZ: drop the GdkSurface so the next open gets a fresh wl_surface"
pat = re.compile(r"^([ \t]+)hide\(\);[ \t]*$", re.M)
total = 0
for f in files:
    try:
        src = io.open(f).read()
    except IOError:
        raise SystemExit("NCZ all-window patch: missing %s - tree layout changed" % f)
    if "init_for_window" not in src:
        raise SystemExit("NCZ all-window patch: %s is not a layer-shell window - re-check" % f)
    if NOTE in src:
        print("NCZ: %s already patched" % f.split("/")[-1]); continue
    n = len(pat.findall(src))
    if n == 0:
        raise SystemExit("NCZ all-window patch: no bare hide() in %s - upstream moved" % f)
    def sub(m):
        ind = m.group(1)
        return (ind + "hide();\n"
                + ind + "// " + NOTE + ".\n"
                + ind + "// Cast required: GtkWindow implements GtkNative, so a bare\n"
                + ind + "// unrealize() binds to gtk_native_unrealize, not the widget one.\n"
                + ind + "((Gtk.Widget) this).unrealize();")
    io.open(f, "w").write(pat.sub(sub, src))
    total += n
    print("NCZ: %-26s %d close path(s) patched" % (f.split("/")[-1], n))
print("NCZ: layer-window unrealize applied to %d close paths" % total)
PY_NCZ_ALLWIN
fi

# NCZ: remove the Overview / Super+Space hover label on the activities button.
#
# The panel sets a GTK tooltip on the activities button in the top-left corner.
# It renders as a hint bubble directly over the application-menu icon and
# lingers on this stack; the operator asked for it gone.
#
# Two earlier attempts targeted the WRONG widget, recorded so nobody repeats
# them: a CSS suppression of .corner-hint (which only applies while the
# Singularity GTK theme is active, and the desktop may be on Adwaita), then
# removal of the top-left corner-hint overlay. Neither touched this tooltip.
# Confirmed by observing the corner-hint removal live in the running payload
# while the label was still on screen.
#
# Comments out every assignment to activities_btn.tooltip_text: the initial one
# and the shortcut_changed handler that re-applies it.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ]; then
python3 - <<'"'"'PY_NCZ_TIP'"'"'
import io, re
p = "subprojects/singularity-shell/src/components/panel/panel.vala"
src = io.open(p).read()
if "NCZ: activities tooltip disabled" in src:
    print("NCZ: activities tooltip already suppressed")
else:
    # Assign null rather than commenting the statement out. One of these sites is
    # the sole body of an `if (action == ...)` inside the shortcut_changed
    # handler, so commenting it leaves a dangling if and Vala fails with
    # "syntax error, following expression/statement delimiter ; missing".
    pat = re.compile(r"^([ \t]*)activities_btn\.tooltip_text\s*=.*?;[ \t]*$", re.M | re.S)
    n = len(pat.findall(src))
    if n == 0:
        raise SystemExit("NCZ activities-tooltip patch: no assignment found - upstream moved")
    out = pat.sub(lambda m: m.group(1) + "activities_btn.tooltip_text = null; // NCZ: hint bubble sat over the app-menu icon", src)
    io.open(p, "w").write(out)
    print("NCZ: activities button tooltip removed (%d assignment site(s))" % n)
PY_NCZ_TIP
fi

# NCZ: remove the top-left corner hint badge (the app-grid glyph that sits over
# the application-menu icon).
#
# This is a SEPARATE widget from the tooltip patched above, and getting that
# wrong cost three round trips. There are two independent producers of a
# top-left hint and removing either one alone leaves the other on screen:
#
#   1. panel.vala      - _corner_tl, an Overlay carrying a .corner-hint-badge
#                        Image ("view-app-grid-symbolic"), added to the panel
#                        overlay unconditionally at construction.
#   2. hot_corner_manager.vala - HotCornerHintWindow, its own wlr-layer-shell
#                        window anchored TOP|LEFT for corner 0, shown on hover.
#
# Earlier passes removed (1) while the tooltip was still live, then removed the
# tooltip while (1) was restored by a botched patch-block rewrite. Each time the
# operator correctly reported the overlay still present. Remove all three.
#
# A CSS rule on .corner-hint is NOT a fix: it only applies while the Singularity
# GTK theme is loaded, and the desktop can be on Adwaita.
if [ -z "${SINGULARITY_SOURCE_DIR:-}" ]; then
python3 - <<'"'"'PY_NCZ_CORNER'"'"'
import io, re

# (1) panel: never parent the top-left hint into the overlay. The widget itself
# is kept so the corner==0 lookup near panel.vala:977 stays valid; it simply
# never has a parent, so it never draws.
p = "subprojects/singularity-shell/src/components/panel/panel.vala"
src = io.open(p).read()
if "NCZ: top-left corner hint" in src:
    print("NCZ: panel top-left corner hint already removed")
else:
    pat = re.compile(r"^([ \t]*)overlay\.add_overlay\(_corner_tl\);[ \t]*$", re.M)
    if len(pat.findall(src)) != 1:
        raise SystemExit("NCZ corner-hint patch: expected exactly 1 add_overlay(_corner_tl) - upstream moved")
    src = pat.sub(lambda m: m.group(1) + "// NCZ: top-left corner hint not parented - it drew over the app-menu icon", src)
    io.open(p, "w").write(src)
    print("NCZ: panel top-left corner hint removed")

# (2) hot corner manager: refuse to show a hint window for corner 0 (TOP|LEFT).
# Guard inside show_hint() rather than at the construction site so every caller
# is covered, including the hover path that lazily builds the window.
p = "subprojects/singularity-shell/src/core/hot_corner_manager.vala"
src = io.open(p).read()
if "NCZ: no top-left hint" in src:
    print("NCZ: hot-corner top-left hint already suppressed")
else:
    pat = re.compile(
        r"(private void show_hint\(int corner, string\? action\) \{\n)",
    )
    if len(pat.findall(src)) != 1:
        raise SystemExit("NCZ hot-corner patch: show_hint signature not found - upstream moved")
    src = pat.sub(
        lambda m: m.group(1)
        + "            // NCZ: no top-left hint - it overlaid the application-menu icon.\n"
          "            if (corner == 0) { hide_hints(); return; }\n",
        src,
    )
    io.open(p, "w").write(src)
    print("NCZ: hot-corner top-left hint window suppressed")
PY_NCZ_CORNER
fi

# Top project. --libdir=lib keeps libs at $PREFIX/lib (not lib/<triplet>) so the
# session launchers'"'"' fixed LD_LIBRARY_PATH=$PREFIX/lib resolves.
meson setup build --prefix='"$PREFIX"' --libdir=lib --buildtype=release
# Bundled labwc/wlroots (labwc uses the wlroots-0.20 fallback wrap upstream ships).
if [ -f Makefile ] && grep -q LABWC_BUILD Makefile; then
    # Upstream'"'"'s Makefile hard-codes `meson setup $(LABWC_BUILD) --prefix=/usr`,
    # which would stage labwc into /work/stage/usr instead of the payload prefix
    # and trip the `test -x $PREFIX/bin/labwc` sanity check below. That rule only
    # fires when build.ninja is absent, so configure labwc ourselves FIRST with
    # the right prefix and `make` will reuse it and only run `meson compile`.
    if [ -d subprojects/labwc ] && [ ! -f subprojects/labwc/build/build.ninja ]; then
        meson setup subprojects/labwc/build subprojects/labwc \
            --prefix='"$PREFIX"' --buildtype=release -Dxwayland=enabled \
            --force-fallback-for=wlroots-0.20
    fi
    make compile
else
    ninja -C build
    # labwc subproject, if the tree carries it as a separate meson project
    if [ -d subprojects/labwc ]; then
        meson setup build-labwc subprojects/labwc --prefix='"$PREFIX"' \
            --buildtype=release -Dxwayland=enabled --force-fallback-for=wlroots-0.20
        ninja -C build-labwc
    fi
fi

# Install into the DESTDIR stage.
rm -rf /work/stage
DESTDIR=/work/stage meson install -C build

# labwc is a separate Meson project.  `make install` in the desktop tree is a
# host-deployment helper and does not reliably honour DESTDIR, so it can leave
# the payload with the previous labwc even when `make compile` built a newer
# compositor.  Install the exact build directory explicitly and fail the
# artifact build if it cannot be staged.
LABWC_BUILD_DIR=""
if [ -d subprojects/labwc/build ]; then
    LABWC_BUILD_DIR="subprojects/labwc/build"
elif [ -d build-labwc ]; then
    LABWC_BUILD_DIR="build-labwc"
fi
[ -n "$LABWC_BUILD_DIR" ] || {
    echo "ERROR: labwc build directory is missing after compilation" >&2
    exit 1
}
DESTDIR=/work/stage meson install -C "$LABWC_BUILD_DIR"

# The upstream Meson install deliberately installs schema XML, but it does not
# install a compiled GSettings database.  Raw XML is not usable by GSettings at
# runtime: launching singularity-desktop then aborts with "Settings schema
# 'dev.sinty.desktop' is not installed".  Compile *inside the staged prefix*
# so the payload is self-contained and GSETTINGS_SCHEMA_DIR can point solely at
# /opt/singularity/share/glib-2.0/schemas.
SCHEMA_DIR="/work/stage'"$PREFIX"'/share/glib-2.0/schemas"
test -f "$SCHEMA_DIR/dev.sinty.desktop.gschema.xml"
glib-compile-schemas --strict "$SCHEMA_DIR"
test -s "$SCHEMA_DIR/gschemas.compiled"

# Sanity: the shell, session launcher, and compositor must all exist.
test -x "/work/stage'"$PREFIX"'/bin/singularity-desktop"
test -x "/work/stage'"$PREFIX"'/bin/singularity-labwc-session"
test -x "/work/stage'"$PREFIX"'/bin/labwc"
test -s "/work/stage'"$PREFIX"'/share/glib-2.0/schemas/gschemas.compiled"

# --- singularity-boot-splash (NATIVE KMS boot splash — Plymouth replacement) --
# Separate upstream repo (github.com/singularityos-lab/singularity-boot-splash),
# NOT part of singularity-desktop. Toolkit-less libdrm + shared singularity-
# loginui Cairo renderer: owns the DRM device directly, animates the branded
# logo/loading-bar, hands off to the labwc greeter. Built here so it ships INSIDE
# the /opt/singularity payload alongside the greeter/lock/splash, all on the same
# loginui pixels. Replaces plymouth (which never covered Sky1s late KMS).
cd /work
git clone --depth 1 --recurse-submodules \
    https://github.com/singularityos-lab/singularity-boot-splash.git
cd singularity-boot-splash
meson setup build --prefix='"$PREFIX"' --libdir=lib --buildtype=release
ninja -C build
DESTDIR=/work/stage meson install -C build
test -x "/work/stage'"$PREFIX"'/bin/singularity-boot-splash"

# --- VENDOR DIVERGENT LIBRARIES ----------------------------------------------
# The build container is Ubuntu 26.04 but the target is Debian Forky (see IMAGE
# for why that mismatch is forced). Any library whose SONAME differs between the
# two must travel inside the payload, or the binary linking it dies on the board.
#
# libsodium is the measured case: Ubuntu 26.04 = libsodium.so.23, Forky =
# libsodium.so.26. singularity-keyring links it, and shipped broken.
#
# Copy the real object plus its SONAME symlink into the payload lib dir. The
# session already puts /opt/singularity/lib ahead of the system path, so the
# vendored copy wins on the target without touching system libraries.
VENDOR_SONAMES="libsodium.so"
for base in $VENDOR_SONAMES; do
    for real in /usr/lib/*-linux-gnu/"$base".*.*.*; do
        [ -f "$real" ] || continue
        soname=$(objdump -p "$real" 2>/dev/null | awk "/SONAME/ {print \$2}")
        [ -n "$soname" ] || continue
        cp -a "$real" "/work/stage'"$PREFIX"'/lib/"
        ln -sf "$(basename "$real")" "/work/stage'"$PREFIX"'/lib/$soname"
        echo "vendored: $soname -> $(basename "$real")"
    done
done

# --- LINK CLOSURE GATE -------------------------------------------------------
# Every staged binary must resolve every shared library against the payload
# itself plus this container. Because the container image now matches the TARGET
# distro, an unresolved soname here means the payload would be broken on the
# board too.
#
# This gate exists because it was missing: a build made in ubuntu:26.04 linked
# singularity-keyring against libsodium.so.23, Forky ships libsodium.so.26, and
# the payload shipped looking perfectly healthy. 27 of 28 binaries were fine;
# the one that was not is the org.freedesktop.secrets provider, so desktop
# secrets silently died. Only a link check on real hardware caught it.
STAGE_PREFIX="/work/stage'"$PREFIX"'"
BROKEN=0
for f in "$STAGE_PREFIX"/bin/*; do
    [ -f "$f" ] && [ -x "$f" ] || continue
    file -b "$f" | grep -q ELF || continue
    missing=$(LD_LIBRARY_PATH="$STAGE_PREFIX/lib" ldd "$f" 2>/dev/null \
                | awk "/not found/ {print \$1}" | tr "\n" " ")
    if [ -n "$missing" ]; then
        echo "LINK CLOSURE FAIL: $(basename "$f") -> $missing" >&2
        BROKEN=$((BROKEN+1))
    fi
done
if [ "$BROKEN" -ne 0 ]; then
    echo "ERROR: $BROKEN staged binary/binaries have unresolved libraries." >&2
    echo "       The build image must match the target distro (see IMAGE)." >&2
    exit 1
fi
echo "link closure: all staged binaries resolve"

# Package. Paths are opt/singularity/... so `tar -C /` lands at /opt/singularity.
cd /work/stage
tar -czf /out/singularity-opt.tgz opt/singularity
echo "STAGED $(du -h /out/singularity-opt.tgz | cut -f1)"
'

echo "== running build in $IMAGE ($CE) =="
CE_ARGS=(--rm -v "$OUT":/out -e SRC_REF="$SRC_REF")
if [ -n "$SRC_DIR" ]; then
    CE_ARGS+=(-v "$SRC_DIR":/src:ro -e SINGULARITY_SOURCE_DIR=/src)
fi
"$CE" run "${CE_ARGS[@]}" "$IMAGE" bash -euo pipefail -c "$BUILD_SCRIPT"

echo ""
echo "== done =="
ls -lh "$OUT/singularity-opt.tgz"
# `| head -3` would SIGPIPE tar and, under `set -o pipefail`, abort this script
# with 141 AFTER a fully successful build — skipping the ARGONAS push below.
# sed drains the stream, so tar's real exit status still propagates.
echo "  top entries:"; tar tzf "$OUT/singularity-opt.tgz" | sed -n '1,3p'

if [ "$PUSH_ARGONAS" = 1 ]; then
    echo "== staging on ARGONAS ($ARGONAS_DST) =="
    GIT_SSH="${GIT_SSH:-sshpass -p REDACTED ssh -o PubkeyAuthentication=no}"
    $GIT_SSH root@192.168.207.101 "mkdir -p $ARGONAS_DST" || true
    sshpass -p 'REDACTED' scp -o PubkeyAuthentication=no \
        "$OUT/singularity-opt.tgz" "root@192.168.207.101:$ARGONAS_DST/" \
        && echo "  pushed to ARGONAS:$ARGONAS_DST/singularity-opt.tgz"
fi

echo ""
echo "Next: stage into the repo for the ISO build:"
echo "  cp $OUT/singularity-opt.tgz assets/singularity/singularity-opt.tgz"
echo "(the blob is gitignored — build-squashfs-layers.sh bakes it into desktop.squashfs;"
echo " build-iso-di.sh also stages it to /cixmini/assets/singularity for install-time.)"
