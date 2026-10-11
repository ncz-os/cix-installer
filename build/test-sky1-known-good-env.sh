#!/bin/bash
# test-sky1-known-good-env.sh -- lock the files/settings that make the O6N
# (arm64 Sky1, image 6351e0b3, 2026-10-11) audio/video good state reproducible
# from the post-install tree alone.
#
# READ-ONLY / CHROOT-SAFE: this test never touches /sys, /etc, systemd or a live
# device. It reads the hook sources and runs the Sky1 browser policy against a
# fixture root (its NCZ_BROWSER_ROOT seam). The installed-image counterpart is
# the "known-good env" section added to build/verify-installed-target.sh.
#
# Captured 2026-10-11 from O6N (read-only drift audit;
# ~/Projects/oc-mission-20261010/envcapture/REPORT.md):
#   * /etc/systemd/system/-.slice.d/10-ncz-rt-sched.conf       DisableControllers=cpu
#   * /etc/pipewire/pipewire.conf.d/99-ncz-audio-headroom.conf  min-quantum=2048
#   * /usr/local/sbin/ncz-vpu-governor-performance +
#     /etc/systemd/system/ncz-vpu-governor.service (arm64: enabled, NOT masked) +
#     /etc/udev/rules.d/71-ncz-vpu-governor.rules
#   * default browser chromium-ncz-sky1 (x-www-browser alternative, /etc/xdg +
#     /etc/skel mimeapps); Google Chrome kept as an explicit choice with its
#     VA-API-off wrapper, but unable to steal the default
#   * Sky1 HDMI/DP audio autoswitch installed + enabled for the user session
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
W="$(mktemp -d -t sky1-known-good.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      /'; FAILS=$((FAILS+1)); }

# hd LABEL FILE -> the heredoc body written by `cat > ... <<'LABEL'` in FILE.
hd() {
    awk -v l="$1" '
        (index($0, "<<" "\x27" l "\x27") || $0 ~ ("<<" l "$")) { f = 1; next }
        f && $0 == l     { f = 0 }
        f                { print }
    ' "$2"
}

HQ="$ROOT/post-install/43-hw-quirks.sh"
[ -f "$HQ" ] || { echo "FAIL  post-install/43-hw-quirks.sh missing"; exit 1; }

# --- 1. RT scheduling slice drop-in ------------------------------------------------
hd SLICEEOF "$HQ" > "$W/slice"
if grep -qx 'DisableControllers=cpu' "$W/slice" && grep -qx '\[Slice\]' "$W/slice"; then
    ok "43: -.slice drop-in disables the cpu controller (restores RT to PipeWire)"
else
    bad "43: 10-ncz-rt-sched.conf does not set DisableControllers=cpu" "$(cat "$W/slice")"
fi

# --- 2. PipeWire quantum floor -----------------------------------------------------
hd PWEOF "$HQ" > "$W/pw"
if grep -qE '^[[:space:]]*default\.clock\.min-quantum[[:space:]]*=[[:space:]]*2048' "$W/pw"; then
    ok "43: PipeWire min-quantum floored at 2048 (ALSA headroom under decode)"
else
    bad "43: 99-ncz-audio-headroom.conf does not floor min-quantum at 2048" "$(cat "$W/pw")"
fi

# --- 3. VPU (amvx) devfreq governor -------------------------------------------------
hd VPUEOF "$HQ" > "$W/vpugovernor"
hd VPUS   "$HQ" > "$W/vpusvc"
hd VPUR   "$HQ" > "$W/vpurule"
grep -q 'CIXH3010:00/governor' "$W/vpugovernor" && grep -q 'echo performance' "$W/vpugovernor" \
    && ok "43: ncz-vpu-governor-performance pins CIXH3010:00 -> performance" \
    || bad "43: VPU governor helper wrong" "$(cat "$W/vpugovernor")"
grep -qE '^Type=oneshot' "$W/vpusvc" && grep -qE '^WantedBy=graphical.target' "$W/vpusvc" \
    && grep -qE '^ExecStart=/usr/local/sbin/ncz-vpu-governor-performance' "$W/vpusvc" \
    && ok "43: ncz-vpu-governor.service is a graphical.target oneshot" \
    || bad "43: ncz-vpu-governor.service wrong" "$(cat "$W/vpusvc")"
grep -q 'KERNEL=="CIXH3010:00"' "$W/vpurule" && grep -q 'SYSTEMD_WANTS}+="ncz-vpu-governor.service"' "$W/vpurule" \
    && ok "43: udev rule tags CIXH3010:00 to start the governor unit" \
    || bad "43: 71-ncz-vpu-governor.rules wrong" "$(cat "$W/vpurule")"
# The udev rule must NOT run a program (a RUN+= retry loop can stall the udev
# worker at boot); the governor must be a systemd oneshot instead.
grep -q 'RUN+=' "$W/vpurule" && bad "43: VPU udev rule uses RUN+= (blocks the udev worker at boot)" \
    || ok "43: VPU udev rule is non-blocking (no RUN+=)"
# enabled by hand (chroot has no running systemd), NOT masked.
grep -q 'graphical.target.wants/ncz-vpu-governor.service' "$HQ" \
    && ok "43: VPU unit enabled via graphical.target.wants (chroot-safe)" \
    || bad "43: VPU unit is not enabled via graphical.target.wants"
grep -qE 'mask[[:space:]]+ncz-vpu-governor' "$HQ" && bad "43: the hook MASKS ncz-vpu-governor (must stay enabled)" \
    || ok "43: the hook never masks ncz-vpu-governor"

# --- 4. arm64 gate: the VPU governor must not install on amd64 ---------------------
# The whole VPU block is gated on `dpkg --print-architecture = arm64` with an
# explicit else (amd64/x86 must not get a Sky1 devfreq unit -- the class of leak
# that broke the T2 boot). Anchor on the hook's own gate text.
if grep -q 'if \[ "$(dpkg --print-architecture 2>/dev/null)" = "arm64" \]; then' "$HQ" \
   && grep -q 'VPU governor step skipped' "$HQ"; then
    ok "43: VPU governor block is arm64-gated (amd64 prints a skip)"
else
    bad "43: VPU governor block is not arm64-gated"
fi
# the arm64 branch must come BEFORE the closing of the gate (sanity: it is inside)
gate_line=$(grep -n 'print-architecture 2>/dev/null)" = "arm64"' "$HQ" | head -1 | cut -d: -f1)
vpu_line=$(grep -n '<<.VPUEOF.$' "$HQ" | head -1 | cut -d: -f1)
if [ -n "$gate_line" ] && [ -n "$vpu_line" ] && [ "$vpu_line" -gt "$gate_line" ]; then
    ok "43: VPU heredocs are inside the arm64 branch"
else
    bad "43: VPU heredocs are not inside the arm64 branch (gate=$gate_line vpu=$vpu_line)"
fi

# --- 5. browser default: chromium-ncz-sky1 on Sky1, Chrome cannot steal it ---------
POL="$ROOT/post-install/lib/sky1-browser-policy.sh"
B="$W/broot"
mkdir -p "$B/usr/share/applications" "$B/usr/bin" "$B/etc/xdg" "$B/etc/skel/.config"
for b in vivaldi-stable google-chrome-stable chromium-ncz-sky1; do printf '#!/bin/sh\n' > "$B/usr/bin/$b"; chmod +x "$B/usr/bin/$b"; done
printf '[Desktop Entry]\nName=Google Chrome\nExec=/usr/bin/google-chrome-stable %%U\n' > "$B/usr/share/applications/google-chrome.desktop"
printf '[Desktop Entry]\nName=Vivaldi\nExec=/usr/bin/vivaldi-stable %%U\n' > "$B/usr/share/applications/vivaldi-stable.desktop"
printf '[Desktop Entry]\nName=Chromium (NCZ)\nExec=/usr/bin/chromium-ncz-sky1 %%U\n' > "$B/usr/share/applications/chromium-ncz-sky1.desktop"
printf '[Default Applications]\ntext/html=vivaldi-stable.desktop\nx-scheme-handler/http=vivaldi-stable.desktop\nx-scheme-handler/https=vivaldi-stable.desktop\ninode/directory=thunar.desktop\n' > "$B/etc/xdg/mimeapps.list"
cp "$B/etc/xdg/mimeapps.list" "$B/etc/skel/.config/mimeapps.list"
bash -c "NCZ_BROWSER_ROOT='$B' NCZ_BROWSER_NO_ALTERNATIVES=1; . '$POL'; ncz_sky1_browser_policy" > "$W/policy.log" 2>&1
for m in "$B/etc/xdg/mimeapps.list" "$B/etc/skel/.config/mimeapps.list"; do
    if grep -qx 'text/html=chromium-ncz-sky1.desktop' "$m" && grep -qx 'x-scheme-handler/https=chromium-ncz-sky1.desktop' "$m"; then
        ok "browser: ${m#$B} -> chromium-ncz-sky1 for http/https/html"
    else
        bad "browser: ${m#$B} not on chromium-ncz-sky1" "$(cat "$m")"
    fi
done
# Chrome cannot take the default (enterprise policy) and a login re-assert heals drift.
grep -q '"DefaultBrowserSettingEnabled"[[:space:]]*:[[:space:]]*false' "$B/etc/opt/chrome/policies/managed/ncz-sky1-default-browser.json" 2>/dev/null \
    && ok "browser: Google Chrome DefaultBrowserSettingEnabled=false policy installed" \
    || bad "browser: Chrome default-browser policy missing"
[ -x "$B/usr/local/bin/ncz-sky1-browser-default" ] && ok "browser: session re-assert helper installed" \
    || bad "browser: session re-assert helper missing"
[ -f "$B/etc/xdg/autostart/ncz-sky1-browser-default.desktop" ] && ok "browser: session re-assert autostart wired" \
    || bad "browser: session re-assert autostart missing"
# Chrome stays an explicit choice: VA-API-off wrapper + override still written.
for w in google-chrome google-chrome-stable; do
    [ -x "$B/usr/local/bin/$w" ] && grep -q 'LIBVA_DRIVER_NAME=ncz-no-vaapi' "$B/usr/local/bin/$w" \
        && ok "browser: Chrome kept as an explicit choice ($w VA-API-off wrapper)" \
        || bad "browser: $w VA-API-off wrapper missing"
done
# The re-assert repairs the exact O6N drift.
if [ -x "$B/usr/local/bin/ncz-sky1-browser-default" ]; then
    sed "s#\[ -x /usr/bin/chromium-ncz-sky1 \]#[ -x \"$B/usr/bin/chromium-ncz-sky1\" ]#" "$B/usr/local/bin/ncz-sky1-browser-default" > "$W/reassert"
    printf '[Default Applications]\ntext/html=google-chrome.desktop\nx-scheme-handler/http=google-chrome.desktop\nx-scheme-handler/https=google-chrome.desktop\ninode/directory=thunar.desktop\n' > "$W/mimeapps.list"
    XDG_CONFIG_HOME="$W" sh "$W/reassert"
    grep -qx 'text/html=chromium-ncz-sky1.desktop' "$W/mimeapps.list" && grep -qx 'inode/directory=thunar.desktop' "$W/mimeapps.list" \
        && ok "browser: re-assert repairs a Chrome-stolen default, keeps other handlers" \
        || bad "browser: re-assert did not repair the drift" "$(cat "$W/mimeapps.list")"
fi

# --- 6. Sky1 HDMI/DP audio autoswitch installed + enabled for the user session -----
AS="$ROOT/post-install/20-desktop.sh"
grep -q 'ncz-sky1-audio-autoswitch.py' "$AS" && grep -q '/etc/systemd/user/ncz-sky1-audio-autoswitch.service' "$AS" \
    && grep -q 'systemctl --global enable ncz-sky1-audio-autoswitch.service' "$AS" \
    && ok "20: Sky1 audio autoswitch installed + global-enabled (real sink path)" \
    || bad "20: Sky1 audio autoswitch install/enable lines missing"
for f in "$ROOT/assets/audio/ncz-sky1-audio-autoswitch.py" "$ROOT/assets/audio/ncz-sky1-audio-autoswitch.service"; do
    [ -s "$f" ] && ok "assets: $(basename "$f") present" || bad "assets: $(basename "$f") missing"
done

echo "sky1 known-good env tests: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
