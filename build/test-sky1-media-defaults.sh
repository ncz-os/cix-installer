#!/bin/bash
# test-sky1-media-defaults.sh -- lock the Sky1 media defaults that were measured on
# O6N and MS-R1 on 2026-10-06 (docs/SKY1-MEDIA-STATUS.md):
#   1. the chromium-ncz-sky1 wrapper that 20-desktop.sh writes: run it with a stub
#      chrome binary and check the exact flags it passes;
#   2. the mpv.conf that 84-vpu-mpv.sh writes: V4L2 M2M copy decode, never VA-API
#      (VA-API decode fails or hangs on 7.3 with the CIX VA driver), never a
#      dmabuf-wayland first VO (it only takes VA-API surfaces -> software decode);
#   3. the packages the audio autoswitch and the media path need at runtime are in
#      the desktop seeds / the 20-desktop audio install line;
#   4. browsers (r201): chromium-ncz-sky1 is the Sky1 default and Vivaldi/Chrome run
#      with VA-API off (post-install/lib/sky1-browser-policy.sh, applied by 52/53 on
#      arm64 only; amd64 keeps Vivaldi).
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

# --- 4. browsers (r201): chromium-ncz-sky1 default on Sky1, VA-API off for Vivaldi/Chrome --
# Session-wide LIBVA_DRIVER_NAME=libcix_va (84-vpu-vaapi) puts stock-Chromium browsers on
# VA-API and the CIX VA-API decoder hangs on H.264/HEVC. Run the real policy
# (post-install/lib/sky1-browser-policy.sh) against a fixture root.
POL="$ROOT/post-install/lib/sky1-browser-policy.sh"
B="$W/broot"
mkdir -p "$B/usr/share/applications" "$B/usr/bin" "$B/etc/xdg" "$B/etc/skel/.config" "$B/etc/skel/Desktop" \
         "$B/home/ncz/.config" "$B/home/ncz/Desktop"
for b in vivaldi-stable google-chrome-stable chromium-ncz-sky1; do printf '#!/bin/sh\n' > "$B/usr/bin/$b"; chmod +x "$B/usr/bin/$b"; done
cat > "$B/usr/share/applications/vivaldi-stable.desktop" <<'VIV'
[Desktop Entry]
Name=Vivaldi
Exec=/usr/bin/vivaldi-stable %U
TryExec=/usr/bin/vivaldi-stable
Actions=new-window;new-private-window;

[Desktop Action new-window]
Exec=/usr/bin/vivaldi-stable --new-window

[Desktop Action new-private-window]
Exec=/usr/bin/vivaldi-stable --incognito
VIV
cat > "$B/usr/share/applications/google-chrome.desktop" <<'GC'
[Desktop Entry]
Name=Google Chrome
Exec=/usr/bin/google-chrome-stable %U

[Desktop Action new-window]
Exec=/usr/bin/google-chrome-stable
GC
printf '[Desktop Entry]\nName=Chromium (NCZ)\nExec=/usr/bin/chromium-ncz-sky1 %%U\n' > "$B/usr/share/applications/chromium-ncz-sky1.desktop"
# what 52-vivaldi.sh / 53-chrome.sh leave behind
printf '[Default Applications]\ntext/html=vivaldi-stable.desktop\nx-scheme-handler/http=vivaldi-stable.desktop\nx-scheme-handler/https=vivaldi-stable.desktop\ninode/directory=thunar.desktop\n' > "$B/etc/xdg/mimeapps.list"
cp "$B/etc/xdg/mimeapps.list" "$B/etc/skel/.config/mimeapps.list"
cp "$B/usr/share/applications/vivaldi-stable.desktop" "$B/etc/skel/Desktop/Vivaldi.desktop"
cp "$B/usr/share/applications/google-chrome.desktop" "$B/etc/skel/Desktop/Google-Chrome.desktop"
cp "$B/usr/share/applications/vivaldi-stable.desktop" "$B/home/ncz/Desktop/Vivaldi.desktop"
printf '[Default Applications]\ntext/html=vivaldi-stable.desktop\nx-scheme-handler/https=firefox.desktop\nx-scheme-handler/mailto=thunderbird.desktop\n' > "$B/home/ncz/.config/mimeapps.list"
apply_policy() { ( NCZ_BROWSER_ROOT="$B" NCZ_BROWSER_NO_ALTERNATIVES=1; . "$POL"; ncz_sky1_browser_policy ) > "$W/policy.log" 2>&1; }
apply_policy; apply_policy   # twice: idempotent
L="$B/usr/local/share/applications"
for id in vivaldi-stable.desktop google-chrome.desktop; do
    src="$B/usr/share/applications/$id"; ov="$L/$id"
    if [ ! -f "$ov" ]; then bad "browser: no override $ov"; continue; fi
    ne=$(grep -c '^Exec=' "$src"); no=$(grep -c '^Exec=env LIBVA_DRIVER_NAME=ncz-no-vaapi /usr/bin/[a-z-]* --disable-features=VaapiVideoDecoder,VaapiVideoEncoder\( \|$\)' "$ov")
    [ "$ne" = "$no" ] && ok "browser: $id override -- all $ne Exec= lines run with VA-API off (env + --disable-features before the args)" \
        || bad "browser: $id override has $no/$ne VA-API-off Exec= lines" "$(grep '^Exec=' "$ov")"
    grep -q '^Exec=.*ncz-no-vaapi.*ncz-no-vaapi' "$ov" && bad "browser: $id override applied twice" || true
    grep -q '^Exec=env .* /usr/bin/vivaldi-stable --disable-features=VaapiVideoDecoder,VaapiVideoEncoder %U$\|^Exec=env .* /usr/bin/google-chrome-stable --disable-features=VaapiVideoDecoder,VaapiVideoEncoder %U$' "$ov" \
        && ok "browser: $id main Exec keeps %U last" || bad "browser: $id main Exec mangled" "$(grep '^Exec=' "$ov")"
    [ "$(grep -v '^Exec=' "$src")" = "$(grep -v '^Exec=' "$ov")" ] && ok "browser: $id override differs only in Exec=" || bad "browser: $id override changed more than Exec="
done
for w in vivaldi-stable vivaldi google-chrome-stable google-chrome; do
    f="$B/usr/local/bin/$w"
    if [ -x "$f" ] && grep -qx 'export LIBVA_DRIVER_NAME=ncz-no-vaapi' "$f" \
       && grep -qE '^exec /usr/bin/(vivaldi-stable|google-chrome-stable) --disable-features=VaapiVideoDecoder,VaapiVideoEncoder "\$@"$' "$f"; then
        ok "browser: /usr/local/bin/$w wrapper execs /usr/bin by absolute path with VA-API off"
    else
        bad "browser: /usr/local/bin/$w wrapper wrong or missing" "$(cat "$f" 2>/dev/null)"
    fi
done
printf '#!/bin/sh\necho "LIBVA=$LIBVA_DRIVER_NAME"; for a in "$@"; do echo "$a"; done\n' > "$W/stub"; chmod +x "$W/stub"
out=$(sed "s#/usr/bin/vivaldi-stable#$W/stub#" "$B/usr/local/bin/vivaldi-stable" | LIBVA_DRIVER_NAME=libcix_va sh -s -- https://x.test)
[ "$out" = "$(printf 'LIBVA=ncz-no-vaapi\n--disable-features=VaapiVideoDecoder,VaapiVideoEncoder\nhttps://x.test')" ] \
    && ok "browser: wrapper overrides the session libcix_va and passes the URL through last" || bad "browser: wrapper run" "$out"
for m in "$B/etc/xdg/mimeapps.list" "$B/etc/skel/.config/mimeapps.list"; do
    bad_keys=""
    for k in text/html x-scheme-handler/http x-scheme-handler/https application/xhtml+xml; do
        grep -qx "$k=chromium-ncz-sky1.desktop" "$m" || bad_keys="$bad_keys $k"
    done
    [ -z "$bad_keys" ] && ok "browser: ${m#$B} -> chromium-ncz-sky1.desktop" || bad "browser: ${m#$B} keys not on chromium:$bad_keys" "$(cat "$m")"
    grep -qx 'inode/directory=thunar.desktop' "$m" && ok "browser: ${m#$B} keeps non-browser handlers" || bad "browser: ${m#$B} lost inode/directory"
    [ "$(grep -c '^text/html=' "$m")" = 1 ] && ok "browser: ${m#$B} has no duplicate keys after two runs" || bad "browser: duplicate keys in ${m#$B}"
done
U="$B/home/ncz/.config/mimeapps.list"
grep -qx 'text/html=chromium-ncz-sky1.desktop' "$U" && grep -qx 'x-scheme-handler/https=firefox.desktop' "$U" && grep -qx 'x-scheme-handler/mailto=thunderbird.desktop' "$U" \
    && ok "browser: existing user: seeded Vivaldi default moved to chromium, the user's own choices kept" || bad "browser: user mimeapps" "$(cat "$U")"
for d in "$B/etc/skel/Desktop/Vivaldi.desktop:vivaldi-stable.desktop" "$B/etc/skel/Desktop/Google-Chrome.desktop:google-chrome.desktop" "$B/home/ncz/Desktop/Vivaldi.desktop:vivaldi-stable.desktop"; do
    f="${d%%:*}"
    cmp -s "$f" "$L/${d#*:}" && ok "browser: desktop icon ${f#$B} is the VA-API-off launcher" || bad "browser: desktop icon ${f#$B} not the VA-API-off launcher"
done
[ -x "$B/usr/bin/vivaldi-stable" ] && [ -f "$B/usr/share/applications/vivaldi-stable.desktop" ] && ok "browser: Vivaldi and Chrome stay installed with their packaged launchers" || bad "browser: packaged launcher removed"

# the hooks: policy applied on arm64 only, from an EXIT trap (runs on early exits too)
for h in 52-vivaldi.sh 53-chrome.sh; do
    blk="$(awk 'index($0,"NCZ-SKY1-BROWSER-BEGIN"){f=1;next} index($0,"NCZ-SKY1-BROWSER-END"){f=0} f' "$ROOT/post-install/$h")"
    [ -n "$blk" ] || { bad "browser: $h has no NCZ-SKY1-BROWSER block"; continue; }
    for a in arm64 amd64; do
        # print the trap, then disarm it: the policy must never run against this host
        t=$(NCZ_TARGET_ARCH=$a bash -c "$blk"$'\n''trap -p EXIT; trap - EXIT' 2>/dev/null)
        case "$a:$t" in
            arm64:*_ncz_sky1_browser_exit*) ok "browser: $h arms the policy on arm64" ;;
            amd64:)                         ok "browser: $h leaves amd64 alone (Vivaldi stays default)" ;;
            *) bad "browser: $h trap on $a is '$t'" ;;
        esac
    done
done
# 20-desktop x-www-browser wrapper order
blk="$(awk '/^_ncz_br_arch="\$\{NCZ_TARGET_ARCH:-\}"$/{f=1} f{print} /^echo "\[20\] default browser:/{exit}' "$ROOT/post-install/20-desktop.sh" \
       | sed "s#/usr/local/bin/x-www-browser#$W/xwb#g; s#/etc/xdg#$W/xdg#g")"
for a in arm64 amd64; do
    rm -rf "$W/xwb" "$W/xdg"; NCZ_TARGET_ARCH=$a bash -c "$blk" >/dev/null 2>&1
    first=$(sed -n 's/^for b in \([^ ]*\) .*/\1/p' "$W/xwb" 2>/dev/null)
    want=/usr/bin/chromium-ncz-sky1; [ "$a" = amd64 ] && want=/usr/bin/vivaldi-stable
    [ "$first" = "$want" ] && ok "browser: 20-desktop x-www-browser on $a tries $want first" || bad "browser: x-www-browser on $a tries '$first' first" "$(cat "$W/xwb" 2>/dev/null)"
done

# Regression (r201 review): with NCZ_TARGET_ARCH unset and no BUILD_ARCH file, the arch probe
# must fall through to dpkg/uname instead of aborting the hook under `set -euo pipefail`.
rm -rf "$W/xwb" "$W/xdg"
if env -u NCZ_TARGET_ARCH bash -c "set -euo pipefail; $blk" >/dev/null 2>&1 && [ -s "$W/xwb" ]; then
    ok "browser: 20-desktop arch probe survives set -e with no NCZ_TARGET_ARCH/BUILD_ARCH"
else
    bad "browser: 20-desktop arch probe aborts under set -e with no NCZ_TARGET_ARCH/BUILD_ARCH"
fi
for f in 20-desktop 52-vivaldi 53-chrome; do
    if grep -n 'tr -d .\[:space:\]. < /usr/local/lib/cix-installer/BUILD_ARCH' "$ROOT/post-install/$f.sh" >/dev/null 2>&1; then
        bad "browser: $f.sh reads BUILD_ARCH with the abort-prone redirect order"
    else
        ok "browser: $f.sh BUILD_ARCH read is guarded"
    fi
done

echo "media defaults tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
