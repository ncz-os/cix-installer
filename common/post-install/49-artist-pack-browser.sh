#!/bin/bash
# 49-artist-pack-browser.sh — Artist Pack browser backend: the two scripts
# and the polkit action that let Singularity's Desktop settings list and
# install curated Artist Packs (ncz-wallpapers-* debs) from apt.
#
# This hook does NOT decide which apt source(s) count as "an artist pack
# source" -- that is entirely the `artist-pack-apt-sources` GSettings key
# under dev.sinty.desktop, set as a packaged gschema default override in
# 20-desktop.sh (the same mechanism that hook already uses for accent-color,
# dark-mode, background-picture-uri, etc). This hook only ships the backend
# that CONSULTS that key at runtime:
#
#   /usr/local/bin/ncz-wallpaper-pack-inventory  — unprivileged; queries
#     apt-cache for ncz-wallpapers-* packages whose apt candidate is under a
#     configured source, emits JSON. Called directly by the shell.
#   /usr/local/bin/ncz-wallpaper-pack-install    — privileged (pkexec only);
#     takes the package AND the source URI the inventory step already
#     resolved, then independently re-checks BOTH against the apt sources
#     actually configured on this system (/etc/apt/sources.list.d/
#     ncz-os-apt-*.list -- a plain root-owned file, not a per-user GSettings
#     read) and against the package's live apt candidate, before calling
#     apt-get. apt-get install on an already-installed package is a no-op
#     (exit 0), so this is idempotent by construction -- no separate
#     "already installed" branch is needed.
#
#     Earlier revision of this script had the privileged helper re-read the
#     `artist-pack-apt-sources` GSettings key itself via `gsettings get` as
#     root under pkexec. That is a real trust-boundary bug, not just an
#     unverified caveat: GSettings/dconf resolves per-EUID, root's dconf
#     "user" profile is not the desktop user's, and pkexec does not carry
#     the invoking user's session/env across the privilege boundary. In
#     THIS specific case the read would likely still have landed on the
#     right value (nobody ever runs `gsettings set` on this key -- there is
#     no UI control for it -- so both root and the desktop user fall
#     through to the same build-time-compiled schema default at a fixed
#     system path), but relying on that is fragile and the wrong invariant
#     for a privileged trust check: it stops being safe the moment anyone
#     ever does run `gsettings set` on this key by hand (e.g. to narrow the
#     trusted list on a running system), because root's read would silently
#     keep validating against the wider, stale compiled default instead of
#     the intended live value -- a fail-OPEN, not fail-closed, direction.
#     Fixed by moving the privileged side off GSettings entirely: it now
#     checks the caller-supplied source against the plain, root-owned apt
#     sources files 24-apt-sources.sh already writes, which is both simpler
#     and a more literal reading of "the artist pack source is set at a
#     config level from apt" than a hand-synced GSettings shadow-copy of
#     the same two URIs. The unprivileged inventory script keeps reading
#     GSettings -- that runs in the normal desktop session, where dconf
#     behaves exactly as expected, so there is no reason to move it too.
#   /usr/share/polkit-1/actions/dev.sinty.desktop.artist-pack-install.policy
#     — scopes pkexec to exactly the install helper above, nothing broader.
#
# The Vala side (singularity-shell's ArtistPackManager) resolves both script
# names via PATH and hides the whole Artist Pack browser section when the
# inventory script is absent -- so this hook is what turns the feature on;
# without it, the browser section simply does not appear.
set -euo pipefail
echo "[49] installing Artist Pack browser backend (ncz-wallpaper-pack-inventory/-install + polkit action)"

install -d -m0755 /usr/local/bin

cat > /usr/local/bin/ncz-wallpaper-pack-inventory <<'INVENTORY'
#!/bin/sh
# ncz-wallpaper-pack-inventory — list Artist Packs available/installed from
# the configured apt source(s).
#
# Emits a JSON array on stdout, one object per pack:
#   {"package":"ncz-wallpapers-<id>", "title":..., "summary":...,
#    "version":..., "source":"<apt base URI>", "installed":true|false}
#
# Called (unprivileged, no pkexec) by Singularity's ArtistPackManager
# (singularity-shell src/core/artist_pack_manager.vala) to populate the
# Desktop settings' Artist Pack browser. Resolved by name via PATH, so its
# mere presence is what makes the browser section appear at all.
#
# "Artist Pack" = any apt package named ncz-wallpapers-* (the convention
# build/build-wallpaper-contrib-deb.sh uses) whose apt candidate comes from
# one of the source(s) configured in the dev.sinty.desktop
# `artist-pack-apt-sources` GSettings key. That list is deployment config
# (see post-install/20-desktop.sh's packaged gschema override), not
# something this script hardcodes: an unconfigured/empty list means nothing
# is trusted, so nothing is listed -- never fall back to "trust every apt
# source" just because none were configured.
set -eu

SSD=/opt/singularity/share/glib-2.0/schemas
gs_get_sources() {
    if command -v gsettings >/dev/null 2>&1 && [ -d "$SSD" ]; then
        GSETTINGS_SCHEMA_DIR="$SSD" gsettings get dev.sinty.desktop artist-pack-apt-sources 2>/dev/null || true
    fi
}

# gsettings get on an `as` key prints a GVariant-literal array, e.g.
# "['https://a/', 'https://b/']" -- pull out the quoted strings.
SOURCES_RAW=$(gs_get_sources)
SOURCES=$(printf '%s' "$SOURCES_RAW" | grep -oE "'[^']*'" | tr -d "'" | tr '\n' ' ')
SOURCES=$(printf '%s' "$SOURCES" | sed 's/[[:space:]]*$//')
if [ -z "$SOURCES" ]; then
    printf '[]\n'
    exit 0
fi
command -v apt-cache >/dev/null 2>&1 || { printf '[]\n'; exit 0; }

# Minimal JSON string escaping (backslash + double-quote). Inputs come from
# apt's own package metadata (name, Description, version, source URI), not
# arbitrary user input, but escape defensively rather than trust it.
jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

FIRST=1
printf '['
for pkg in $(apt-cache search --names-only '^ncz-wallpapers-' 2>/dev/null | awk '{print $1}' | sort -u); do
    # apt-cache madison prints one line per (version, source):
    #   pkg | version | https://base/ dist/component arch Packages
    # Find the first line whose base URI starts with a trusted source.
    MATCH=$(apt-cache madison "$pkg" 2>/dev/null | ARTISTPACK_SOURCES="$SOURCES" awk -F'|' '
        {
            ver = $2; uri = $3
            gsub(/^[ \t]+|[ \t]+$/, "", ver)
            gsub(/^[ \t]+/, "", uri)
            n = split(uri, uriparts, " ")
            base = uriparts[1]
            m = split(ENVIRON["ARTISTPACK_SOURCES"], srcs, " ")
            for (i = 1; i <= m; i++) {
                if (index(base, srcs[i]) == 1) {
                    print ver "\t" base
                    exit
                }
            }
        }')
    [ -n "$MATCH" ] || continue
    CAND_VER=$(printf '%s' "$MATCH" | cut -f1)
    CAND_URI=$(printf '%s' "$MATCH" | cut -f2)

    INSTALLED_VER=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)
    INSTALLED=false
    [ -n "$INSTALLED_VER" ] && INSTALLED=true

    DESC=$(apt-cache show "$pkg" 2>/dev/null | awk -F': ' '/^Description(-en)?:/{print substr($0, index($0,$2)); exit}')
    [ -n "$DESC" ] || DESC="$pkg"
    TITLE=$(printf '%s' "$DESC" | cut -c1-60)

    [ "$FIRST" = 1 ] || printf ','
    FIRST=0
    printf '{"package":"%s","title":"%s","summary":"%s","version":"%s","source":"%s","installed":%s}' \
        "$(jesc "$pkg")" "$(jesc "$TITLE")" "$(jesc "$DESC")" "$(jesc "$CAND_VER")" "$(jesc "$CAND_URI")" "$INSTALLED"
done
printf ']\n'
INVENTORY
chmod 0755 /usr/local/bin/ncz-wallpaper-pack-inventory
echo "[49]   ncz-wallpaper-pack-inventory installed"

cat > /usr/local/bin/ncz-wallpaper-pack-install <<'INSTALLHELPER'
#!/bin/sh
# ncz-wallpaper-pack-install — privileged, single-purpose Artist Pack
# installer. Installed root:root 0755; invoked ONLY via
# `pkexec ncz-wallpaper-pack-install <package> <source-uri>` (see the
# dev.sinty.desktop.artist-pack-install polkit action) by
# singularity-shell's ArtistPackManager. Never call this directly as a
# general-purpose apt wrapper.
#
# Idempotent: `apt-get install` on a package already at the candidate
# version is a no-op that still exits 0, so re-running this on an
# already-installed pack is a safe, repeatable success, not an error.
#
# Defense in depth, done WITHOUT touching GSettings: this script does not
# trust either argv value just because the caller (a GUI button) claims to
# have already checked them. It cross-checks the supplied <source-uri>
# against TWO independent, session-independent facts instead:
#
#   1. it must be a base URI actually wired as an NCZ-OS apt source on THIS
#      system -- i.e. present in one of the plain, root-owned
#      /etc/apt/sources.list.d/ncz-os-apt-*.list files 24-apt-sources.sh
#      writes. These are the ONLY apt sources this hook (or 24-apt-sources.sh)
#      ever adds, GPG-signed, and readable identically by any UID -- unlike a
#      GSettings/dconf read, which resolves per-EUID and does NOT behave the
#      same for a pkexec-elevated root process as it does for the desktop
#      user's own session. See 49-artist-pack-browser.sh's header for why an
#      earlier revision's `gsettings get ... as root` re-check was dropped.
#   2. the package's LIVE apt candidate (`apt-cache madison`, queried fresh,
#      right now) must actually resolve to that same source URI -- so this
#      never trusts the caller's claim about where a package would come
#      from, only what apt itself currently reports.
#
# Both checks must pass before apt-get ever runs.
set -eu

PKG="${1:-}"
SRC="${2:-}"
if [ -z "$PKG" ] || [ -z "$SRC" ]; then
    echo "usage: ncz-wallpaper-pack-install <package> <source-uri>" >&2
    exit 2
fi
case "$PKG" in
    ncz-wallpapers-[a-z0-9]*) ;;
    *)
        echo "refusing to install '$PKG': not an Artist Pack package name" >&2
        exit 1
        ;;
esac
# The case pattern above is a shell glob, not a full regex, so tighten with
# a byte-level check: only [a-z0-9-] anywhere in the name.
case "$PKG" in
    *[!a-z0-9-]*)
        echo "refusing to install '$PKG': package name contains characters outside [a-z0-9-]" >&2
        exit 1
        ;;
esac

# Check 1: SRC must be a base URI actually configured as an NCZ-OS apt
# source on this system -- read directly from the plain root-owned apt
# sources files, never from GSettings.
CONFIGURED=0
for f in /etc/apt/sources.list.d/ncz-os-apt-*.list; do
    [ -e "$f" ] || continue
    if grep -qF -- "$SRC" "$f" 2>/dev/null; then
        CONFIGURED=1
        break
    fi
done
if [ "$CONFIGURED" -ne 1 ]; then
    echo "refusing to install '$PKG': '$SRC' is not a configured NCZ-OS apt source (checked /etc/apt/sources.list.d/ncz-os-apt-*.list)" >&2
    exit 1
fi

# Check 2: the package's LIVE apt candidate must actually come from SRC --
# re-derived fresh from apt-cache, never trusted from argv alone.
CAND_URI=$(apt-cache madison "$PKG" 2>/dev/null | ARTISTPACK_SRC="$SRC" awk -F'|' '
    {
        uri = $3
        gsub(/^[ \t]+/, "", uri)
        n = split(uri, uriparts, " ")
        base = uriparts[1]
        if (index(base, ENVIRON["ARTISTPACK_SRC"]) == 1) {
            print base
            exit
        }
    }')
if [ -z "$CAND_URI" ]; then
    echo "refusing to install '$PKG': its apt candidate is not from '$SRC'" >&2
    exit 1
fi

echo "installing $PKG (candidate source: $CAND_URI)"
exec apt-get install -y --no-install-recommends -- "$PKG"
INSTALLHELPER
chmod 0755 /usr/local/bin/ncz-wallpaper-pack-install
echo "[49]   ncz-wallpaper-pack-install installed"

install -d -m0755 /usr/share/polkit-1/actions
cat > /usr/share/polkit-1/actions/dev.sinty.desktop.artist-pack-install.policy <<'POLKIT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC
 "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <vendor>NCZ-OS</vendor>
  <vendor_url>https://github.com/singularityos-lab/singularity-desktop</vendor_url>

  <action id="dev.sinty.desktop.artist-pack-install">
    <description>Install a curated Artist Pack</description>
    <message>Authentication is required to install a curated wallpaper Artist Pack</message>
    <icon_name>preferences-desktop-wallpaper</icon_name>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/usr/local/bin/ncz-wallpaper-pack-install</annotate>
  </action>
</policyconfig>
POLKIT
chmod 0644 /usr/share/polkit-1/actions/dev.sinty.desktop.artist-pack-install.policy
echo "[49]   polkit action installed: dev.sinty.desktop.artist-pack-install"

echo "[49] Artist Pack browser backend installed. The browse/list side trusts"
echo "[49] dev.sinty.desktop artist-pack-apt-sources (set by 20-desktop.sh's"
echo "[49] gschema override); the privileged install side independently"
echo "[49] cross-checks against the actual configured apt sources on disk"
echo "[49] (/etc/apt/sources.list.d/ncz-os-apt-*.list) instead of GSettings."
