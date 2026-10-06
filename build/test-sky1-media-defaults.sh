#!/bin/bash
# test-sky1-media-defaults.sh -- lock the Sky1 media defaults that were measured on
# O6N and MS-R1 on 2026-10-06 (docs/SKY1-MEDIA-STATUS.md):
#   1. the chromium-ncz-sky1 wrapper that 20-desktop.sh writes: run it with a stub
#      chrome binary and check the exact flags it passes;
#   2. the mpv.conf that 84-vpu-mpv.sh writes: V4L2 M2M copy decode, never VA-API
#      (VA-API decode fails or hangs on 7.3 with the CIX VA driver), never a
#      dmabuf-wayland first VO (it only takes VA-API surfaces -> software decode);
#   3. the packages the audio autoswitch and the media path need at runtime are in
#      the desktop seeds / the 20-desktop audio install line.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
W="$(mktemp -d -t sky1-media-defaults.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }

# --- 1. Chromium wrapper ---------------------------------------------------------
awk '/<<.CHROMIUMWRAPPER.$/ {f=1; next} /^CHROMIUMWRAPPER$/ {f=0} f' "$ROOT/post-install/20-desktop.sh" > "$W/wrapper"
if [ ! -s "$W/wrapper" ]; then
    bad "chromium wrapper heredoc not found in post-install/20-desktop.sh"
else
    printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$W/chrome"; chmod +x "$W/chrome"
    sed "s|/opt/chromium-ncz-sky1/chrome|$W/chrome|" "$W/wrapper" > "$W/wrapper.sh"
    args="$(sh "$W/wrapper.sh" --user-arg 2>&1)"
    has() { printf '%s\n' "$args" | grep -qx -- "$1"; }
    has --ozone-platform=wayland && ok "wrapper: Wayland ozone platform" || bad "wrapper: --ozone-platform=wayland missing"
    feats="$(printf '%s\n' "$args" | sed -n 's/^--enable-features=//p' | tr ',' '\n')"
    printf '%s\n' "$feats" | grep -qx AcceleratedVideoDecoder && ok "wrapper: AcceleratedVideoDecoder enabled (V4L2VideoDecoder on the VPU)" \
        || bad "wrapper: AcceleratedVideoDecoder not enabled (Chromium would decode in software)"
    printf '%s\n' "$feats" | grep -qiE 'vaapi' && bad "wrapper: enables a VA-API feature; this Chromium has no VA-API" || ok "wrapper: no dead VA-API feature flags"
    printf '%s\n' "$args" | grep -qE -- '^--(disable-accelerated-video-decode|disable-gpu|use-gl=swiftshader|disable-features=.*AcceleratedVideoDecoder)' \
        && bad "wrapper: disables hardware decode/GPU" || ok "wrapper: does not disable hardware decode or the GPU"
    printf '%s\n' "$args" | grep -q -- '^--disable-features=.*AudioServiceOutOfProcess' && ok "wrapper: keeps the in-process audio service (silent-PCM fix)" \
        || bad "wrapper: AudioServiceOutOfProcess no longer disabled"
    [ "$(printf '%s\n' "$args" | tail -1)" = --user-arg ] && ok "wrapper: user arguments are passed through last" || bad "wrapper: user arguments lost or reordered"
fi

# --- 2. mpv.conf -------------------------------------------------------------------
H="$ROOT/post-install/84-vpu-mpv.sh"
conf="$(awk '/<<MPVCONF$/ {f=1; next} /^MPVCONF$/ {f=0} f' "$H")"
hw="$(sed -n 's/^ *_HWDEC=//p' "$H" | tr -d '"' | sort -u)"
vo="$(sed -n 's/^ *_VO=//p' "$H" | tr -d '"' | sort -u)"
printf '%s\n' "$conf" | grep -qx 'hwdec=$_HWDEC' || bad "84-vpu-mpv: mpv.conf no longer takes hwdec from \$_HWDEC"
[ "$hw" = v4l2m2m-copy ] && ok "mpv: hwdec=v4l2m2m-copy on every path" || bad "mpv: hwdec choices '$(echo $hw)' (want only v4l2m2m-copy; VA-API decode fails/hangs)"
case "$vo" in dmabuf-wayland*) bad "mpv: vo starts with dmabuf-wayland (VA-API-only VO -> software decode)";; *) ok "mpv: first VO is not dmabuf-wayland ($vo)";; esac
grep -qE '^[^#]*hwdec=vaapi|_HWDEC=vaapi' "$H" && bad "mpv: a VA-API hwdec path is still written" || ok "mpv: no VA-API hwdec path left"

# --- 3. seeds / runtime deps -------------------------------------------------------
for m in desktop.pkgs desktop-amd64.pkgs; do
    for p in alsa-utils pulseaudio-utils pipewire pipewire-pulse wireplumber mpv ffmpeg; do
        grep -qxF "$p" "$ROOT/manifests/$m" || bad "seed manifests/$m lacks $p"
    done
done
[ "$FAILS" = 0 ] && ok "seeds: audio/media runtime packages present in both desktop manifests"
line="$(awk '/apt-get install -y \\$/ {getline n; if (n ~ /pipewire-pulse/) print n}' "$ROOT/post-install/20-desktop.sh")"
for p in pipewire pulseaudio-utils alsa-utils; do
    printf '%s\n' "$line" | grep -qw -- "$p" || { bad "20-desktop audio install line lacks $p (autoswitch needs it)"; continue; }
done
printf '%s\n' "$line" | grep -qw alsa-utils && ok "20-desktop: audio install line carries alsa-utils (aplay probe) and pipewire (pw-dump via pipewire-bin)"

echo "media defaults tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
