#!/bin/bash
# 25-cix-proprietary.sh — install Cix Sky1 closed-source userspace .debs.
#
# Renamed from 00- to 25- so it runs AFTER 20-desktop.sh. Several Cix
# packages (notably cix-debian-misc, cix-gstreamer) have postinst
# scripts that touch GNOME-stack files (gdm3 daemon.conf, glib schema
# compilation, pulseaudio paths, fcitx, etc.) and depend on libglib2.0-*,
# gdm3, dbus, fontconfig already being installed. With 20-desktop
# pulling those in first, cix-* postinsts can complete cleanly instead
# of failing with 'glib-compile-schemas: command not found' and
# 'sed: cannot read /etc/gdm3/daemon.conf'.
#
# 37 packages captured via dpkg-repack from a stock Cix factory image:
# audio DSP, GPU/Mali, NPU/NoE, VPU, ISP, mesa, libdrm, libglvnd,
# llama.cpp, MNN, ONNX runtime, whisper.cpp, gstreamer, etc.
#
# Skip the Cix kernel debs — we installed our linux-cix-msr1 in
# 10-our-kernel.sh.
#
# Resilience: some Cix postinsts have known shell bugs ('[: too many
# arguments') that fail even when deps are met. We treat those as
# non-fatal — package contents land via dpkg --unpack/configure, and
# the install proceeds. Remaining postinst issues are logged for
# follow-up but don't halt the installer.
set -uo pipefail

ASSETS=/usr/local/lib/cix-installer/assets/cix-debs
if [ ! -d "$ASSETS" ] && [ -d /cdrom/cixmini/assets/cix-debs ]; then
    ASSETS=/cdrom/cixmini/assets/cix-debs
fi

# Variant-aware filtering. The dep-closure check (build/check-cix-deps.sh) showed
# every Cix userland deb installs against the server-only mirror EXCEPT
# cix-gstreamer, which needs desktop multimedia/graphics libs (libasound2,
# libcairo2, libdrm-amdgpu1/etnaviv1) that only exist in Ubuntu's desktop set.
# On Magnetar (headless/server) those libs aren't present and aren't carried
# offline, so skip cix-gstreamer there; it ships on Reinhardt (desktop) where
# 20-desktop pulls its libs online from ports.
IS_SERVER=0
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    case "$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)" in
        server|magnetar|headless) IS_SERVER=1 ;;
    esac
fi

mkdir -p /var/log/cix-install

if [ ! -d "$ASSETS" ]; then
    echo "[25] Cix proprietary userspace .debs: asset directory missing at $ASSETS"
    echo "[25] skipping proprietary Cix .debs (netinstall/no bundled payload)"
    exit 0
fi

DEB_COUNT=$(find "$ASSETS" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')

echo "[25] Cix proprietary userspace .debs from $ASSETS"
echo "    package count: $DEB_COUNT"
echo ""

if [ "$DEB_COUNT" = "0" ]; then
    echo "[25] no bundled proprietary Cix .debs found; skipping (netinstall mode)"
    exit 0
fi

cd "$ASSETS" || { echo "ERROR: cannot cd to $ASSETS"; exit 1; }
# Skip:
#   1. Cix's kernel image/headers debs (we installed our own in 10-)
#   2. Cix's kernel-module driver debs (post 2026-05-03 kernel jump
#      from 6.6.10 → 6.18.14-cix-sky1, these prebuilt .ko's are
#      vermagic-incompatible — they install into /lib/modules/6.6.10-
#      cix-build-generic/extra but the kernel won't load them. Same
#      hardware is now driven by in-tree drivers shipped with the new
#      kernel: panthor (GPU, was mali_kbase), armchina-npu (NPU, was
#      aipu), amvx in-tree (VPU, replaces vendor amvx blob), drm/cix
#      (display, replaces trilin_dptx), cix_dsp_rproc with ACPI fix.
#      Installing the 6.6 .ko packages just pollutes the modules tree
#      with files that fail vermagic check. Skip entirely.)
DEBS=()
NOE_UMD_DEB=""
for deb in ./*.deb; do
    [ -e "$deb" ] || continue
    deb=${deb#./}
    case "$deb" in
        linux-image-*-cix-build-generic_*.deb|linux-headers-*-cix-build-generic_*.deb) continue ;;
        cix-npu-driver_*.deb|cix-gpu-driver_*.deb|cix-vpu-driver_*.deb|cix-isp-driver_*.deb|cix-wlan_*.deb|cix-csi-driver_*.deb|cix-noe-kmd_*.deb) continue ;;
        # cix-noe-umd 2.0.2: the only UMD validated against our in-tree
        # armchina_npu (v0-compat) KMD. It ships libnoe.so.0.6.0 +
        # /usr/share/cix/pypi/{libnoe,NOE_Engine}-2.0.0 wheels (cp311/cp312),
        # which 47-embedkit.sh wires into the py3.11 NPU venv.
        # UMD 1.1.1 (libnoe 0.5.0) and 3.1.2 fail job-submit on this KMD.
        #
        # We do NOT dpkg -i this deb: its postinst pip-installs the libnoe
        # wheel into the SYSTEM python (3.14), which the wheel rejects
        # (requires <3.13,>=3.11) → postinst exits 1 → dpkg leaves the
        # package half-configured (iF) → the iU/iF purge sweep below removes
        # it AND deletes /usr/share/cix/lib + /usr/share/cix/pypi. Instead we
        # record the deb path here and dpkg-deb -x extract its FILES only
        # (no maintainer scripts) AFTER the purge sweep — see the
        # "NPU userspace files" block further down.
        cix-noe-umd_2.0.2_*.deb) NOE_UMD_DEB="$deb"; continue ;;
        cix-npu-umd_*.deb|cix-noe-umd_*.deb|cix-npu-onnxruntime_*.deb) continue ;;
    esac
    # Magnetar/server: skip desktop-class Cix userland (needs desktop libs).
    if [ "$IS_SERVER" = 1 ]; then
        case "$deb" in
            cix-gstreamer_*.deb)
                echo "    [server] skipping desktop-class $deb (needs desktop multimedia libs)"
                continue ;;
        esac
    fi
    DEBS+=("$deb")
done

echo "Skipping vermagic-incompatible cix-*-driver debs (post-Sky1-switch):"
for deb in ./*.deb; do
    [ -e "$deb" ] || continue
    deb=${deb#./}
    case "$deb" in
        cix-npu-driver_*.deb|cix-gpu-driver_*.deb|cix-vpu-driver_*.deb|cix-isp-driver_*.deb|cix-wlan_*.deb|cix-csi-driver_*.deb|cix-noe-kmd_*.deb)
            echo "    $deb"
            ;;
    esac
done

# ----------------------------------------------------------------------
# Patch cix-debian-misc.deb to remove its broken initramfs-tools rename
# block. The postinst unconditionally runs:
#
#   mv /usr/share/initramfs-tools/init                       original/
#   mv /usr/share/initramfs-tools/original/cix_init          init
#   mv /usr/share/initramfs-tools/scripts/init-top/udev      original/
#   mv /usr/share/initramfs-tools/original/cix_udev          init-top/udev
#   mv /usr/share/initramfs-tools/scripts/init-premount/plymouth original/
#   mv /usr/share/initramfs-tools/original/cix_plymouth      init-premount/
#
# But cix_init / cix_udev / cix_plymouth are NOT actually shipped in
# the deb's data.tar (verified 2026-05-03: only `original/` empty dir
# and `hooks/cix_ko` ship). The first mv of each pair succeeds — moving
# Debian's working scripts into original/ — then the matched mv fails
# on a missing source. End state: /usr/share/initramfs-tools/init is
# gone, and update-initramfs warns `cp: cannot stat /usr/share/
# initramfs-tools/init: No such file or directory` and builds a 221MB
# initrd that's missing /init. Booting it kernel-panics ("can't run /
# init") and triggers an infinite reboot loop on real hardware.
#
# Workaround: extract the deb, comment out only the 6 mv lines, repack,
# install the patched version. All other Cix postinst behavior (glib
# schema rebuild, gdm3 daemon.conf, logind tweaks, fcitx, pulseaudio)
# is preserved. Real fix is upstream at Cix — they need to either ship
# the cix_init etc. files or drop the rename block.
# ----------------------------------------------------------------------
CDM_ORIG="$ASSETS/cix-debian-misc_1.0.0_arm64.deb"
CDM_PATCHED=/tmp/cix-debian-misc-noinitrd-patch.deb
if [ -f "$CDM_ORIG" ]; then
    echo "--- patching cix-debian-misc.deb to neuter init-rename block ---"
    rm -rf /tmp/cdm-patch
    mkdir -p /tmp/cdm-patch
    dpkg-deb -R "$CDM_ORIG" /tmp/cdm-patch
    if [ -f /tmp/cdm-patch/DEBIAN/postinst ]; then
        # Comment any mv touching /usr/share/initramfs-tools/{init,scripts/...,original/cix_*}
        sed -i -E '\#^[[:space:]]*mv[[:space:]]+/usr/share/initramfs-tools/(init|scripts/init-(top|premount)/(udev|plymouth)|original/cix_(init|udev|plymouth))#s|^|# [25-patched] |' \
            /tmp/cdm-patch/DEBIAN/postinst
        # r130.4 (Codex review of .66 install): the cix-debian-misc postinst is
        # written against a Cix factory image (GDM3 + PulseAudio reference paths +
        # /etc/rc.local). On our XFCE/LightDM target those files are absent, so:
        #   - the gdm3 daemon.conf sed errors "can't read /etc/gdm3/daemon.conf"
        #   - the two pulseaudio analog-output-headphones.conf mv's "cannot stat"
        #   - the FINAL line (cat /etc/rc.local | grep timedatectl … && sed … rc.local)
        #     fails because /etc/rc.local does not exist → postinst returns exit 2
        #     (it's the LAST command, so its rc becomes the script's rc) → dpkg
        #     leaves cix-debian-misc half-configured (iF) → the iU/iF purge sweep
        #     drops it. That last line ALSO injects `timedatectl set-local-rtc 1`
        #     (a Windows-dual-boot RTC convention we explicitly do NOT want on a
        #     Linux box). Neuter the three target-incompatible blocks; keep the
        #     wanted tweaks (logind lid/power, snd/timer udev MODE, NM p2p unmanage,
        #     bluetooth-autoconnect, cix-check-display). Append a final `exit 0` so
        #     a stray non-zero from any remaining best-effort command can never
        #     half-configure the package again.
        sed -i -E '\#/etc/gdm3/daemon\.conf#s|^[[:space:]]*|# [25-patched] |' /tmp/cdm-patch/DEBIAN/postinst
        sed -i -E '\#/usr/share/pulseaudio/alsa-mixer/paths/(cix-)?analog-output-headphones\.conf#s|^[[:space:]]*|# [25-patched] |' /tmp/cdm-patch/DEBIAN/postinst
        sed -i -E '\#timedatectl[[:space:]]+set-local-rtc#s|^[[:space:]]*|# [25-patched] |' /tmp/cdm-patch/DEBIAN/postinst
        grep -qE '^[[:space:]]*exit[[:space:]]+0[[:space:]]*$' /tmp/cdm-patch/DEBIAN/postinst \
            || printf '\n# [25-patched] never half-configure on a best-effort tweak failure\nexit 0\n' >> /tmp/cdm-patch/DEBIAN/postinst
        echo "    patched postinst — commented mv lines:"
        grep -nE '^# \[25-patched\]' /tmp/cdm-patch/DEBIAN/postinst | sed 's/^/      /'
    fi
    dpkg-deb -b /tmp/cdm-patch "$CDM_PATCHED" >/dev/null
    # Swap the patched deb into the install set
    for i in "${!DEBS[@]}"; do
        case "${DEBS[$i]}" in
            cix-debian-misc_*) unset 'DEBS[i]' ;;
        esac
    done
    cp "$CDM_PATCHED" "$ASSETS/cix-debian-misc_1.0.0_arm64.patched.deb"
    DEBS+=("cix-debian-misc_1.0.0_arm64.patched.deb")
fi

if [ "${#DEBS[@]}" -eq 0 ]; then
    echo "[25] no installable Cix proprietary .debs remain after kernel/driver/NPU filters; skipping"
    exit 0
fi

echo "--- dpkg -i (collect failures, continue) ---"
# r130.4 (Codex review): add --force-overwrite. cix-env ships
# /etc/modprobe.d/blacklist.conf (a 13957-byte Sky1-specific blacklist, also
# at /usr/lib/modprobe.d/blacklist.conf) but declares no Conflicts/Replaces, so
# it collides with kmod's stock /etc/modprobe.d/blacklist.conf and dpkg aborts
# ("trying to overwrite '/etc/modprobe.d/blacklist.conf', which is also in
# package kmod"). Overwriting with the Sky1 blacklist is the intended end state.
# Scoped to this proprietary cix bundle (consistent with the existing
# --force-depends posture); upstream fix is a proper Replaces:/Conflicts:.
dpkg -i --force-depends --force-overwrite "${DEBS[@]}" 2>&1 | tee /var/log/cix-install/25-dpkg.log || true

echo ""
echo "--- apt-get install -fy (resolve unmet apt deps) ---"
apt-get install -fy 2>&1 | tee /var/log/cix-install/25-apt-fix.log || true

echo ""
echo "--- dpkg --configure -a (retry half-configured packages with deps now resolved) ---"
dpkg --configure -a 2>&1 | tee /var/log/cix-install/25-dpkg-configure.log || true

echo ""
echo "Cix packages installed (ii):"
dpkg -l | awk '/^ii.*cix-/ {print "  " $2 " " $3}' | tee /var/log/cix-install/25-cix-installed.log

echo ""
echo "Cix packages with known issues (iU/iF — half-installed):"
STUCK=$(dpkg -l 2>/dev/null | awk '/^iU|^iF/ {print $2}')
echo "$STUCK" | sed 's/^/  /'

# Force-purge any half-configured packages. Without this, every later
# apt-get call retries the broken postinst and exits non-zero, which
# kills downstream hooks (30-agents, 50-brand, ...) that have set -e.
# We've already captured what landed cleanly via dpkg -l above; the
# stuck packages weren't going to work anyway.
for pkg in $STUCK; do
    echo "    purging stuck package: $pkg"
    dpkg --purge --force-remove-reinstreq --force-remove-essential "$pkg" 2>&1 | tail -3 || true
done

# ----------------------------------------------------------------------
# NPU userspace files: extract cix-noe-umd 2.0.2 data.tar to / WITHOUT
# running its maintainer scripts (see the DEBS filter above for why we
# can't dpkg -i it on a py3.14 system). This lands:
#   /usr/share/cix/lib/libnoe.so{,.0,.0.6.0}
#   /usr/share/cix/pypi/{libnoe,NOE_Engine}-2.0.0-*.whl
# and makes libnoe.so discoverable via ld.so. 47-embedkit.sh then installs
# the wheels into the py3.11 NPU venv. Done AFTER the iU/iF purge sweep so
# nothing removes the files we just laid down.
# ----------------------------------------------------------------------
if [ -n "${NOE_UMD_DEB:-}" ] && [ -e "$NOE_UMD_DEB" ]; then
    echo "--- staging NPU userspace from $NOE_UMD_DEB (dpkg-deb -x, no postinst) ---"
    dpkg-deb -x "$NOE_UMD_DEB" / 2>&1 | tail -3 || true
    if [ -d /usr/share/cix/lib ]; then
        echo "/usr/share/cix/lib" > /etc/ld.so.conf.d/cix-noe.conf
        ldconfig 2>/dev/null || true
    fi
    ls -l /usr/share/cix/lib/libnoe.so* 2>/dev/null | sed 's/^/    /'
    ls -l /usr/share/cix/pypi/*.whl     2>/dev/null | sed 's/^/    /'
else
    echo "--- NPU userspace: no cix-noe-umd 2.0.2 deb found to stage ---"
fi

# Bridge between vendor 6.6 .ko vermagic and our built kernel's KVER:
# RETIRED 2026-05-03 with the Sky1-Linux 6.18.14 switch. The cix-*-
# driver debs are now skipped entirely above (DEBS filter), and the
# in-tree 6.18 drivers (panthor, armchina-npu, in-tree amvx, drm/cix,
# cix_dsp_rproc with ACPI fix) take their place. No bridge needed.
RUNNING_KVER=$(uname -r)
echo "    running kernel: $RUNNING_KVER (no OoT bridge — Sky1-Linux in-tree)"

# Always exit 0 — Cix postinst quirks should not halt the installer.
# If something is genuinely broken, surfaces during agent runtime
# rather than killing the install before branding/bootloader land.
exit 0
