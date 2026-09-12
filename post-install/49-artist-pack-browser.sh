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
#     re-derives and re-checks the trusted source list itself before calling
#     apt-get, rather than trusting the caller's argv. apt-get install on an
#     already-installed package is a no-op (exit 0), so this is idempotent
#     by construction -- no separate "already installed" branch is needed.
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
# `pkexec ncz-wallpaper-pack-install <package>` (see the
# dev.sinty.desktop.artist-pack-install polkit action) by
# singularity-shell's ArtistPackManager. Never call this directly as a
# general-purpose apt wrapper.
#
# Idempotent: `apt-get install` on a package already at the candidate
# version is a no-op that still exits 0, so re-running this on an
# already-installed pack is a safe, repeatable success, not an error.
#
# Defense in depth: this script does NOT trust its argv package name just
# because it matched the naming pattern. It re-derives the trusted apt
# source list from the SAME dev.sinty.desktop `artist-pack-apt-sources`
# GSettings key the (unprivileged) inventory script reads, and refuses to
# install anything whose apt candidate is not actually from one of those
# sources -- the caller (a GUI button) already claims to have checked this,
# but a pkexec entry point must not rely on the caller having checked
# anything.
set -eu

PKG="${1:-}"
if [ -z "$PKG" ]; then
    echo "usage: ncz-wallpaper-pack-install <package>" >&2
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

SSD=/opt/singularity/share/glib-2.0/schemas
gs_get_sources() {
    if command -v gsettings >/dev/null 2>&1 && [ -d "$SSD" ]; then
        GSETTINGS_SCHEMA_DIR="$SSD" gsettings get dev.sinty.desktop artist-pack-apt-sources 2>/dev/null || true
    fi
}
SOURCES_RAW=$(gs_get_sources)
SOURCES=$(printf '%s' "$SOURCES_RAW" | grep -oE "'[^']*'" | tr -d "'" | tr '\n' ' ')
SOURCES=$(printf '%s' "$SOURCES" | sed 's/[[:space:]]*$//')
if [ -z "$SOURCES" ]; then
    echo "refusing to install '$PKG': no artist-pack-apt-sources are configured" >&2
    exit 1
fi

CAND_URI=$(apt-cache madison "$PKG" 2>/dev/null | ARTISTPACK_SOURCES="$SOURCES" awk -F'|' '
    {
        uri = $3
        gsub(/^[ \t]+/, "", uri)
        n = split(uri, uriparts, " ")
        base = uriparts[1]
        m = split(ENVIRON["ARTISTPACK_SOURCES"], srcs, " ")
        for (i = 1; i <= m; i++) {
            if (index(base, srcs[i]) == 1) {
                print base
                exit
            }
        }
    }')
if [ -z "$CAND_URI" ]; then
    echo "refusing to install '$PKG': its apt candidate is not from a configured artist-pack-apt-sources entry" >&2
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

echo "[49] Artist Pack browser backend installed. Trusted source(s) come from"
echo "[49] dev.sinty.desktop artist-pack-apt-sources (set by 20-desktop.sh's"
echo "[49] gschema override), not from anything in this hook."
