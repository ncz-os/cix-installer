#!/bin/bash
# 66-ncz-lite-profile.sh -- install the NCZ-OS "lite" performance profile for
# weak GPUs / old PCs (operator 2026-10-12).
#
# NCZ-PLATFORM-GUARD: amd64 only (docs/PLATFORM-SPLIT-DESIGN.md). Arch order
# matches run-all.sh: NCZ_TARGET_ARCH, then the late.sh BUILD_ARCH stamp, then
# dpkg. An undetectable arch does NOT skip (legacy behavior).
_ncz_pg_arch="${NCZ_TARGET_ARCH:-}"
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(cat /usr/local/lib/cix-installer/BUILD_ARCH 2>/dev/null | tr -d '[:space:]')
[ -n "$_ncz_pg_arch" ] || _ncz_pg_arch=$(dpkg --print-architecture 2>/dev/null || true)
case "$_ncz_pg_arch" in
    amd64|x86_64|"") ;;
    *) echo "[${0##*/}] platform guard: arch=$_ncz_pg_arch is not amd64; skipping"; exit 0 ;;
esac
unset _ncz_pg_arch

# WHAT THIS HOOK INSTALLS (data + shell only -- no upstream code is patched):
#   /usr/bin/ncz-profile                          the CLI + first-login helper
#   /usr/share/ncz/lite/{rc-lite.fragment.xml,themerc-lite.fragment}   data
#   /usr/share/glib-2.0/schemas/dev.ncz.profile.gschema.xml            the key
#   /usr/lib/systemd/user/ncz-lite-profile.service                     user unit
#   /usr/share/doc/ncz-lite-profile.md                                 docs
#
# It does NOT apply lite anywhere: lite is chosen per user, once, at first
# login by the user service (or by hand with `ncz-profile lite`). arm64/Sky1
# never gets it (guard above); a server/headless variant skips it too.
#
# Idempotent. Never fails the install (exit 0 on every path).
# Test seam (build/test-lite-profile.sh): NCZ_LITE_ROOT, NCZ_LITE_SCHEMA_DIR,
# NCZ_LITE_SKIP_GLOBAL_ENABLE.
set -u

echo "[66] NCZ lite profile (weak GPU / old PC) -- data + user service"

VARIANT=desktop
[ -f /usr/local/lib/cix-installer/BUILD_VARIANT ] && VARIANT=$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)
case "$VARIANT" in
    server|headless) echo "[66]   $VARIANT variant: no desktop, skipping"; exit 0 ;;
esac

# Locate the asset tree. ROOT is the sysroot prefix ("" in the real install,
# a temp dir under the test seam).
_ROOT="${NCZ_LITE_ROOT:-}"
_dest() { printf '%s%s' "$_ROOT" "$1"; }

ASSETS=""
if [ -n "${NCZ_LITE_ASSETS:-}" ] && [ -f "${NCZ_LITE_ASSETS}/ncz-profile" ]; then
    ASSETS="$NCZ_LITE_ASSETS"
fi
for _r in /cdrom/ncz-payload /usr/local/lib/cix-installer; do
    [ -n "$ASSETS" ] && break
    if [ -f "$_r/assets/lite/ncz-profile" ]; then ASSETS="$_r/assets/lite"; break; fi
done
if [ -z "$ASSETS" ]; then
    echo "[66]   WARN: assets/lite/ncz-profile not found under /cdrom/ncz-payload or /usr/local/lib/cix-installer; lite profile not installed" >&2
    exit 0
fi

# --- CLI -------------------------------------------------------------------
install -d -m0755 "$(_dest /usr/bin)"
install -m0755 "$ASSETS/ncz-profile" "$(_dest /usr/bin/ncz-profile)"

# --- data fragments --------------------------------------------------------
install -d -m0755 "$(_dest /usr/share/ncz/lite)"
for f in rc-lite.fragment.xml themerc-lite.fragment; do
    if [ -f "$ASSETS/$f" ]; then
        install -m0644 "$ASSETS/$f" "$(_dest /usr/share/ncz/lite/$f)"
    fi
done

# --- docs ------------------------------------------------------------------
install -d -m0755 "$(_dest /usr/share/doc)"
if [ -f "$ASSETS/README.md" ]; then
    install -m0644 "$ASSETS/README.md" "$(_dest /usr/share/doc/ncz-lite-profile.md)"
fi

# --- the profile gschema key ----------------------------------------------
# An override cannot ADD a key to an existing schema, and the dev.sinty.desktop
# schema is upstream-owned (and lives under /opt/singularity/share, not the
# system schema dir), so the key lives in a small cix-owned schema. It is
# compiled together with every other schema in a directory, so a bad file would
# break gsettings for that whole directory: validate it --strict on a scratch
# copy first and install only when it compiles.
#
# Install into BOTH the system schema dir and the singularity share dir the
# session actually uses (GSETTINGS_SCHEMA_DIR=/opt/singularity/share/glib-2.0/
# schemas), so `ncz-profile` sees the key inside and outside the session.
SCHEMA_SRC="$ASSETS/dev.ncz.profile.gschema.xml"
if [ -n "${NCZ_LITE_SCHEMA_DIR:-}" ]; then
    _schema_dirs="$NCZ_LITE_SCHEMA_DIR"
else
    _schema_dirs="$(_dest /usr/share/glib-2.0/schemas)"
    _share="$(_dest /opt/singularity/share/glib-2.0/schemas)"
    [ -d "$_share" ] && _schema_dirs="$_schema_dirs $_share"
fi

if [ -f "$SCHEMA_SRC" ]; then
    for SCHEMA_DIR in $_schema_dirs; do
        install -d -m0755 "$SCHEMA_DIR"
        if ! command -v glib-compile-schemas >/dev/null 2>&1; then
            install -m0644 "$SCHEMA_SRC" "$SCHEMA_DIR/dev.ncz.profile.gschema.xml"
            echo "[66]   WARN: glib-compile-schemas missing; installed $SCHEMA_DIR/dev.ncz.profile.gschema.xml unvalidated" >&2
            continue
        fi
        SCRATCH=$(mktemp -d)
        cp "$SCHEMA_DIR"/*.gschema.xml "$SCRATCH"/ 2>/dev/null || true
        cp "$SCHEMA_DIR"/*.enums.xml "$SCRATCH"/ 2>/dev/null || true
        cp "$SCHEMA_DIR"/*.gschema.override "$SCRATCH"/ 2>/dev/null || true
        cp "$SCHEMA_SRC" "$SCRATCH/dev.ncz.profile.gschema.xml"
        if glib-compile-schemas --strict --dry-run "$SCRATCH" >"$SCRATCH/compile.log" 2>&1; then
            install -m0644 "$SCHEMA_SRC" "$SCHEMA_DIR/dev.ncz.profile.gschema.xml"
            if [ -z "${NCZ_LITE_SCHEMA_DIR:-}" ]; then
                glib-compile-schemas "$SCHEMA_DIR" 2>&1 | sed 's/^/[66]   /' || true
            fi
            echo "[66]   installed dev.ncz.profile schema in $SCHEMA_DIR"
        else
            echo "[66]   WARN: dev.ncz.profile schema does not compile against $SCHEMA_DIR; not installing it there:" >&2
            sed 's/^/[66]     /' "$SCRATCH/compile.log" >&2
        fi
        rm -rf "$SCRATCH"
    done
else
    echo "[66]   WARN: dev.ncz.profile.gschema.xml missing; the marker file is the only preference store" >&2
fi

# --- the first-login user service -----------------------------------------
UNIT_SRC="$ASSETS/ncz-lite-profile.service"
UNIT_DIR="$(_dest /usr/lib/systemd/user)"
if [ -f "$UNIT_SRC" ]; then
    install -d -m0755 "$UNIT_DIR"
    install -m0644 "$UNIT_SRC" "$UNIT_DIR/ncz-lite-profile.service"
    if [ "${NCZ_LITE_SKIP_GLOBAL_ENABLE:-0}" != "1" ]; then
        if systemctl --global enable ncz-lite-profile.service >/dev/null 2>&1; then
            echo "[66]   ncz-lite-profile.service installed; first-login auto select enabled for all users"
        else
            echo "[66]   WARN: could not globally enable ncz-lite-profile.service" >&2
        fi
    else
        echo "[66]   test seam: skipped systemctl --global enable"
    fi
else
    echo "[66]   WARN: ncz-lite-profile.service missing; no first-login auto select" >&2
fi

echo "[66]   lite profile installed (not applied; auto-selects once at first login)"
exit 0
