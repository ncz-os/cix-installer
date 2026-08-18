#!/bin/bash
# 22-locale-gen.sh — generate the locales the system actually uses, and wire
# CJK input when a CJK system language is selected.
#
# THE BUG THIS FIXES (measured on the built squashfs layers, 2026-08-18):
#
#   /usr/lib/locale/           -> C.utf8 and nothing else
#   /usr/share/i18n/           -> does not exist
#   /etc/default/locale        -> 0 bytes
#   locale-gen                 -> not installed
#   dpkg -l locales            -> not installed in EITHER squashfs layer
#
# while post-install/23-locale-env.sh wrote:
#
#   LANG=en_US.UTF-8
#   LC_ALL=en_US.UTF-8
#
# That locale was never generated, so setlocale() fails and glibc falls back to
# C/POSIX. The hook whose stated purpose is to stop the "'C' is not a UTF-8
# locale" fallback was itself pointing at a locale that did not exist. The
# `locales` package is now seeded in manifests/installer-base.pkgs; this hook
# does the generation.
#
# LANGUAGE SELECTION: honours /usr/local/lib/cix-installer/LANGUAGE, written by
# late.sh from the installer's language question (or the ncz_lang= cmdline).
# Absent or unreadable -> en_US.UTF-8, which is the historical default.
#
# Sky1 is a Chinese SoC and this project ships bilingual documentation, so
# zh_CN is a first-class target, not a nice-to-have: selecting it generates the
# locale AND enables fcitx5 so the user can actually type Chinese offline.
set -uo pipefail

CONF_DIR=/usr/local/lib/cix-installer
LANG_FILE="$CONF_DIR/LANGUAGE"

# Always generate these two regardless of the choice:
#   C.UTF-8      — the guaranteed-present fallback; anything that mis-parses the
#                  chosen locale still lands somewhere UTF-8 clean.
#   en_US.UTF-8  — historical default and what every prior image claimed to use.
ALWAYS="C.UTF-8 UTF-8
en_US.UTF-8 UTF-8"

SEL="en_US.UTF-8"
if [ -r "$LANG_FILE" ]; then
    _sel=$(tr -d ' \t\r\n' < "$LANG_FILE" 2>/dev/null || true)
    [ -n "$_sel" ] && SEL="$_sel"
fi
echo "[22] system language: $SEL"

# Map a locale to the locale.gen line and the charset.
case "$SEL" in
    zh_CN*)  EXTRA="zh_CN.UTF-8 UTF-8"; IME=fcitx5 ;;
    zh_TW*)  EXTRA="zh_TW.UTF-8 UTF-8"; IME=fcitx5 ;;
    ja_JP*)  EXTRA="ja_JP.UTF-8 UTF-8"; IME=fcitx5 ;;
    ko_KR*)  EXTRA="ko_KR.UTF-8 UTF-8"; IME=fcitx5 ;;
    en_US*)  EXTRA=""                 ; IME="" ;;
    *)       EXTRA="$SEL UTF-8"       ; IME="" ;;
esac

if ! command -v locale-gen >/dev/null 2>&1; then
    # Fail soft but LOUD. A silent skip here reproduces exactly the defect this
    # hook exists to fix, and it would look identical from the outside.
    echo "[22] ERROR: locale-gen is missing — the 'locales' package did not land."
    echo "[22]        The system will fall back to C/POSIX. Check that"
    echo "[22]        manifests/installer-base.pkgs seeded 'locales' into the base layer."
    exit 0
fi

install -d /etc
{
    printf '%s\n' "$ALWAYS"
    [ -n "$EXTRA" ] && printf '%s\n' "$EXTRA"
} > /etc/locale.gen
chmod 0644 /etc/locale.gen

echo "[22] generating: $(tr '\n' ',' < /etc/locale.gen | sed 's/,$//')"
if locale-gen >/dev/null 2>&1; then
    echo "[22]   locale-gen OK"
else
    echo "[22]   WARN: locale-gen returned nonzero"
fi

# Prove it, rather than assuming. A generated locale that is not actually
# resolvable is the same failure in a different costume.
if locale -a 2>/dev/null | grep -qiE "^${SEL%%.*}\.?(utf-?8)?$|^${SEL//-/}$"; then
    echo "[22]   verified: $SEL is present in locale -a"
else
    echo "[22]   WARN: $SEL not visible in locale -a — falling back to C.UTF-8"
    SEL="C.UTF-8"
fi

# System-wide default. /etc/default/locale is what PAM's pam_env and the
# console read; /etc/locale.conf is the systemd path.
printf 'LANG=%s\n' "$SEL" > /etc/default/locale
chmod 0644 /etc/default/locale
printf 'LANG=%s\n' "$SEL" > /etc/locale.conf
chmod 0644 /etc/locale.conf
echo "[22]   /etc/default/locale + /etc/locale.conf -> LANG=$SEL"

# ---------------------------------------------------------------------------
# Input method, only when a CJK language was chosen.
#
# The packages ship unconditionally (see manifests/desktop.pkgs); enabling them
# is what the language choice controls. An IME running for an en_US user is
# just a tray icon nobody asked for.
# ---------------------------------------------------------------------------
if [ -n "$IME" ] && command -v fcitx5 >/dev/null 2>&1; then
    install -d /etc/environment.d
    cat > /etc/environment.d/60-input-method.conf <<'ENVEOF'
# CJK input via fcitx5.
#
# GTK4 and Qt6 on Wayland prefer the compositor's text-input protocol, which
# the shipped labwc implements, so they need no module variable. GTK3, Qt5 and
# anything falling back to X11/Xwayland still consult these, and setting them
# is harmless where they are ignored.
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
ENVEOF
    chmod 0644 /etc/environment.d/60-input-method.conf

    # fcitx5 must be started by systemd --user, not XDG autostart.
    #
    # MEASURED on O6N 2026-08-18: nothing in this session processes
    # /etc/xdg/autostart -- no dex, no xdg-autostart-generator, no session
    # manager. An autostart .desktop here is inert. The wallpaper rotator was
    # installed correctly and never ran once for exactly this reason.
    install -d /usr/lib/systemd/user
    cat > /usr/lib/systemd/user/ncz-fcitx5.service <<'IMEUNIT'
[Unit]
Description=Fcitx 5 input method (CJK)
PartOf=graphical-session.target
After=graphical-session.target

[Service]
Type=simple
ExecStart=/usr/bin/fcitx5
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
IMEUNIT
    chmod 0644 /usr/lib/systemd/user/ncz-fcitx5.service
    if systemctl --global enable ncz-fcitx5.service >/dev/null 2>&1; then
        echo "[22]   enabled ncz-fcitx5.service for all users (systemd --global)"
    else
        echo "[22]   WARN: could not globally enable ncz-fcitx5.service"
    fi

    # Fallback for desktops that honour XDG autostart.
    install -d /etc/xdg/autostart
    cat > /etc/xdg/autostart/fcitx5-ncz.desktop <<'DESKEOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Comment=Chinese input method (enabled because a CJK system language was selected)
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
X-GNOME-Autostart-Phase=Applications
NoDisplay=true
DESKEOF
    chmod 0644 /etc/xdg/autostart/fcitx5-ncz.desktop
    echo "[22]   fcitx5 enabled (autostart + IM environment)"
else
    if [ -n "$IME" ]; then
        echo "[22]   WARN: CJK language selected but fcitx5 is not installed —"
        echo "[22]         the user will be able to READ but not TYPE $SEL."
    fi
fi

exit 0
