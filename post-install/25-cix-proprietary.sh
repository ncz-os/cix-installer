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
# On Server (headless) those libs aren't present and aren't carried
# offline, so skip cix-gstreamer there; it ships on Desktop where
# 20-desktop pulls its libs online from ports.
IS_SERVER=0
if [ -f /usr/local/lib/cix-installer/BUILD_VARIANT ]; then
    case "$(tr -d ' \t\r\n' < /usr/local/lib/cix-installer/BUILD_VARIANT)" in
        server|headless) IS_SERVER=1 ;;
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
        # Desktop payload ownership lives in 20-desktop.sh and the ISO
        # /pool/main package. Some baked desktop roots still carry older
        # ncz-singularity-desktop debs in assets/cix-debs; installing them
        # here can downgrade the sensor-panel hotfix after it was applied.
        ncz-singularity-desktop_*.deb)
            echo "    skipping $deb (desktop payload is installed from /cdrom/pool/main by 20-desktop.sh)"
            continue ;;
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
        # matched NPU stack (cix-noe-umd 3.1.4 / cix-npu-umd 3.2.0, 26q2 SDK) installs
        # via the normal path below; only the legacy onnxruntime deb is skipped.
        cix-npu-onnxruntime_*.deb) continue ;;
        # Internal test/validation suites: never install on an end-user
        # desktop (cix-unit-test 755M, cix-ltp 269M, cix-gpu-test 55M,
        # cix-vpu-test). Pure dead weight on the installed system. (2026-06-25)
        cix-unit-test_*.deb|cix-ltp_*.deb|cix-gpu-test_*.deb|cix-vpu-test_*.deb) continue ;;
        # NEVER install, any variant (2026-08-04, validated on O6N/trixie):
        # cix-gstreamer drops GStreamer 1.22 core libraries into
        # /usr/share/cix/lib — an ldconfig'd directory — silently shadowing
        # the distro GStreamer (1.28) for EVERY process. That broke libgtk-4
        # (undefined symbol gst_video_info_dma_drm_to_video_info) and
        # crash-looped the desktop shell at login. cix-ffmpeg/cix-libav* are
        # the same hazard class (ffmpeg 5.1-era libs vs the distro's) and the
        # distro ffmpeg already does VPU VAAPI decode+encode with cix-vaapi
        # (validated: 1080p30 decode ~7% CPU, encode 13.2x realtime).
        # The media set that SHOULD ship instead: cix-vaapi, cix-libva*,
        # cix-libcme (hard dlopen dep of the VA driver), cix-vpu-firmware —
        # none of them match a skip rule, so staging them in assets/cix-debs
        # installs them via the normal path below.
        cix-gstreamer_*.deb|cix-ffmpeg_*.deb|cix-libav*_*.deb)
            echo "    skipping $deb (shadows distro media libraries via ldconfig'd /usr/share/cix/lib — see DRIVER_FIDELITY_72.md addendum)"
            continue ;;
    esac
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
# ----------------------------------------------------------------------
# Second cix-debian-misc initramfs defect: its hooks/cix_ko does
#
#   cp -r /lib/modules/${version}/kernel/drivers/gpu/drm/cix ${DESTDIR}/...
#
# A raw cp performs NO dependency resolution. linlon-dp.ko therefore lands in
# the initramfs WITHOUT drm_dma_helper.ko, even though modules.dep declares
# the dependency. Measured on O6N with r237:
#
#   [2.517165] linlon_dp: Unknown symbol drm_gem_dma_get_sg_table (err -2)
#   ... 11 unresolved drm_gem_dma_* / drm_fb_dma_* symbols, load FAILS
#   [4.534194] linlondp_platform_probe enter        <- only after root mounts
#   [4.536218] Console: switching to colour dummy device 80x25
#
# i.e. the display cannot come up during initramfs at all; it appears ~2s
# later on the retry against the real root. Listing the r237 initrd showed 11
# drm modules and zero matches for dma_helper.
#
# We add our OWN hook rather than editing cix_ko, because that file belongs to
# cix-debian-misc and any fix written into it is reverted on package upgrade.
# manual_add_modules resolves deps out of modules.dep, which is the whole
# point. Verified on O6N: after this hook, drm_dma_helper is in the initrd and
# the drm module count goes 11 -> 12.
#
# Note this is NOT fixable in the kernel config: CONFIG_DRM_GEM_DMA_HELPER is a
# promptless tristate whose value is forced by its selectors, so setting it =y
# in the defconfig is silently ignored (proven: the built .config is identical
# with and without that line).
# ----------------------------------------------------------------------
echo "--- installing ncz-drm-deps initramfs hook (cix_ko copies linlon-dp without its deps) ---"
install -d /etc/initramfs-tools/hooks
cat > /etc/initramfs-tools/hooks/ncz-drm-deps <<'NCZDRMHOOK'
#!/bin/sh
# Pull the cix DRM drivers in WITH their dependencies. cix-debian-misc's
# hooks/cix_ko cp -r's them in without any, which leaves linlon-dp.ko in the
# initramfs missing drm_dma_helper.ko and costs ~2s of black screen at boot.
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0;;
esac
. /usr/share/initramfs-tools/hook-functions
manual_add_modules linlon_dp
manual_add_modules trilin_dpsub
NCZDRMHOOK
chmod 0755 /etc/initramfs-tools/hooks/ncz-drm-deps
echo "[25] ncz-drm-deps hook installed (initramfs regenerated later by 58-boot-hygiene)"

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
        # 2026-08-02: post-install/22-display-fix.sh masks cix-check-display.service
        # (it is the GNOME-only vendor display watchdog, hardcoded to
        # /usr/bin/restart-display, and we do not run that stack). 22 runs before
        # 25, so this postinst's `systemctl enable cix-check-display` always hit a
        # masked unit and logged "Failed to enable unit: Unit
        # /etc/systemd/system/cix-check-display.service is masked" on every
        # install. The mask is the decision; drop the enable so the two steps stop
        # contradicting each other. (Keep the bluetooth-autoconnect enable.)
        sed -i -E '\#^[[:space:]]*systemctl[[:space:]]+enable[[:space:]]+cix-check-display#s|^[[:space:]]*|# [25-patched] |' /tmp/cdm-patch/DEBIAN/postinst
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

# ----------------------------------------------------------------------
# Bashism sweep over vendor maintainer scripts (2026-08-02).
#
# Several Cix debs declare `#!/bin/sh` but use bash-only syntax. Confirmed on
# O6N: cix-env's postinst is
#     #!/bin/sh
#     set -e
#     if [[ -e "/etc/default/cpufrequtils" ]]; then
# and /bin/sh is dash on Debian, so line 4 fails with `[[: not found`. Under
# `set -e` that aborts the script, so the cpufreq governor tweak never applied
# and dpkg saw a failing postinst.
#
# This was survivable on Ubuntu only by luck; it is not a Debian-specific
# regression so much as a latent vendor bug that the forky move exposed.
#
# Rather than rewrite vendor logic (risky — `[[ a && b ]]` has no safe
# mechanical translation to `[`), retarget the interpreter: bash is present on
# every profile, and bash running a script written for bash is exactly the
# author's intent. Peek at the control archive first (`dpkg-deb -e` unpacks
# only DEBIAN/, cheap) and do the expensive full unpack/repack ONLY for debs
# that actually need it.
# ----------------------------------------------------------------------
echo "--- scanning vendor maintainer scripts for bashisms under #!/bin/sh ---"
for i in "${!DEBS[@]}"; do
    deb="${DEBS[$i]}"
    [ -f "$deb" ] || continue
    ctrl=/tmp/cix-ctrl-peek
    rm -rf "$ctrl"; mkdir -p "$ctrl"
    dpkg-deb -e "$deb" "$ctrl" 2>/dev/null || continue
    needs_bash=""
    for ms in preinst postinst prerm postrm; do
        [ -f "$ctrl/$ms" ] || continue
        # only /bin/sh (with or without trailing flags); leave real bash alone
        head -1 "$ctrl/$ms" | grep -qE '^#!.*/sh([[:space:]]|$)' || continue
        # Bash-only constructs that dash does not implement. Over-matching is
        # harmless (bash runs a POSIX script correctly), under-matching leaves a
        # script broken, so the list is deliberately generous: `source` instead
        # of `.`, process substitution, arrays, shopt/select, BASH_* variables.
        grep -qE '\[\[|\]\]|<<<|<\(|>\(|\+=\(|\bBASH_[A-Z]|\$\{![A-Za-z_]|^[[:space:]]*function[[:space:]]+[A-Za-z_]|(^|[[:space:];&|])source[[:space:]]|(^|[[:space:];&|])(shopt|pushd|popd|mapfile|readarray|typeset)\b|(^|[[:space:];&|])(declare|local)[[:space:]]+-[aAin]|(^|[[:space:];&|])select[[:space:]]+[A-Za-z_]+[[:space:]]+in\b|(^|[[:space:];&|])read[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-a\b' \
            "$ctrl/$ms" && needs_bash="$needs_bash $ms"
    done
    rm -rf "$ctrl"
    [ -n "$needs_bash" ] || continue

    base=$(basename "$deb" .deb)
    echo "    $deb: bashism in$needs_bash — retargeting shebang to /bin/bash"
    work=/tmp/cix-shebang-$base
    rm -rf "$work"
    if ! dpkg-deb -R "$deb" "$work" 2>/dev/null; then
        echo "    WARN: could not unpack $deb — leaving it unpatched"
        rm -rf "$work"; continue
    fi
    for ms in $needs_bash; do
        sed -i -E '1s|^#!.*/sh([[:space:]].*)?$|#!/bin/bash\1|' "$work/DEBIAN/$ms"
        echo "      $ms -> $(head -1 "$work/DEBIAN/$ms")"
    done
    patched="$ASSETS/${base}.shpatched.deb"
    if dpkg-deb -b "$work" "$patched" >/dev/null 2>&1; then
        DEBS[$i]="$(basename "$patched")"
    else
        echo "    WARN: repack of $deb failed — leaving it unpatched"
    fi
    rm -rf "$work"
done

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

# r130.7 (CRITICAL boot fix — operator: NONE of the installed kernels boot,
# stable + edge + rescue-partition all dead, no video). cix-env's
# /etc/modprobe.d/blacklist.conf (+ /usr/lib copy) blacklists `btrfs` — but our
# root filesystem is BTRFS and CONFIG_BTRFS_FS=m in both kernels, so the module
# can NEVER load -> initramfs cannot mount the root -> every main rEFInd entry
# dies with no video. (r129 booted only because the dpkg overwrite-conflict
# aborted cix-env before this file landed; the r130.4 --force-overwrite made it
# install, which is exactly what bricked boot.) The same file also blacklists
# fuse/cuse and the ENTIRE kernel crypto family (aes/sha/dm-integrity/IMA/TLS/
# module-signature deps) — all wrong for a general-purpose desktop. Neutralize
# those filesystem + crypto blacklists; leave the genuinely board-specific
# hardware blacklists (absent sensors/gpio/regulators/ipmi/rng/typec) intact.
# This runs BEFORE 60-plymouth rebuilds the initramfs, so the corrected
# blacklist.conf is what gets baked into the initrd.
#
# amvx (r186.2): the vendor blacklist also blocks amvx (Linlon MVX VPU), a
# leftover from when the vendor's own out-of-tree blob was used; the in-tree
# amvx now replaces that blob and is fixed (cfddef0, vb2 q->lock overlay in
# 81-vpu.sh). Neutralize it here too so the VPU auto-loads at boot (ACPI
# match CIXH3010) instead of staying dark despite the fix already shipping.
UNBRICK_MODS="btrfs fuse cuse blocklayoutdriver overlay amvx \
aes-neon-blk sha512-arm64 aes-neon-bs sha3-ce sha512-ce chacha-neon crct10dif-ce \
sm3-ce xor-neon xxhash_generic sha256_generic xts af_alg cbc authenc des_generic \
blake2b_generic ecb ctr crypto_engine dh_generic sha3_generic sm3_generic \
ecdh_generic ecc sm3 ghash-generic ccm algif_rng gcm authencesn md5 cmac \
sm4_generic curve25519-generic xor michael_mic sm4"
for bl in /etc/modprobe.d/blacklist.conf /usr/lib/modprobe.d/blacklist.conf; do
    [ -f "$bl" ] || continue
    for m in $UNBRICK_MODS; do
        sed -i "s/^[[:space:]]*blacklist[[:space:]][[:space:]]*${m}[[:space:]]*$/# [25-unbrick] blacklist ${m}/" "$bl"
    done
    n=$(grep -c "^# \[25-unbrick\]" "$bl" 2>/dev/null || true)
    echo "[25] neutralized $n fs+crypto blacklist lines in $bl (btrfs root MUST be mountable)"
done
# Belt-and-suspenders: if btrfs is somehow still blacklisted anywhere, fail loud.
if grep -rqsE '^[[:space:]]*blacklist[[:space:]]+btrfs[[:space:]]*$' /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null; then
    echo "[25] FATAL: btrfs still blacklisted after neutralize — boot would brick" >&2
    grep -rnE '^[[:space:]]*blacklist[[:space:]]+btrfs' /etc/modprobe.d/ /usr/lib/modprobe.d/ 2>/dev/null | sed 's/^/    /'
fi

echo ""
echo "--- apt-get install -fy (resolve unmet apt deps) ---"
apt-get install -fy 2>&1 | tee /var/log/cix-install/25-apt-fix.log || true

# The desktop.squashfs base image carries an old dpkg "hold" selection on
# cix-noe-umd from an earlier build cycle (when 2.0.2 was the only confirmed-
# working version). dpkg preserves selection state across the upgrade to the
# matched 3.1.4 above, so a fresh install still showed "Status: hold ok
# installed" even though the correct version installed fine. Clear it so apt
# state matches reality (installed, not held).
apt-mark unhold cix-noe-umd 2>/dev/null || true

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
# kills downstream hooks (50-brand, 46-ncz-cli, ...) that have set -e.
# We've already captured what landed cleanly via dpkg -l above; the
# stuck packages weren't going to work anyway.
for pkg in $STUCK; do
    echo "    purging stuck package: $pkg"
    dpkg --purge --force-remove-reinstreq  "$pkg" 2>&1 | tail -3 || true
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
# NPU userspace now ships via the matched cix-noe-umd 3.1.4 deb (installed via
# the normal dpkg path above), so no dpkg-deb -x extract is needed. But the
# ld.so ordering below is still REQUIRED: /usr/share/cix/lib must win over the
# distro's same-named libs — libnoe (NPU runtime) AND the version-matched libva
# 2.22.1 (CIX VA-API / VPU decode). Run it whenever the dir exists.
if [ -d /usr/share/cix/lib ]; then
    if true; then
        # r26.7: was "cix-noe.conf" (no numeric prefix) -> sorted AFTER
        # aarch64-linux-gnu.conf alphabetically, so Ubuntu's own same-named
        # libraries silently won ld.so's resolution over CIX's copies here.
        # Confirmed real-world impact 2026-07-27: /usr/share/cix/lib ships a
        # version-matched libva 2.22.1 (CIX's VA-API runtime, paired with
        # libcix_va_drv_video.so, __vaDriverInit_1_22), but Ubuntu 26.04's
        # system libva is 2.23.0 (__vaDriverInit_1_23) -- with the old
        # unprefixed conf file, every VA-API consumer (Chrome included)
        # resolved the mismatched system libva.so and got a hard
        # __vaDriverInit_1_23-not-found failure, breaking VPU hardware video
        # decode/encode entirely. "00-" prefix matches the same fix already
        # applied to 00-cixgpu-pro.conf for the GL/EGL/Vulkan library set.
        echo "/usr/share/cix/lib" > /etc/ld.so.conf.d/00-cix-noe.conf
        rm -f /etc/ld.so.conf.d/cix-noe.conf
        ldconfig 2>/dev/null || true
    fi
    ls -l /usr/share/cix/lib/libnoe.so* 2>/dev/null | sed 's/^/    /'
    ls -l /usr/share/cix/pypi/*.whl     2>/dev/null | sed 's/^/    /'

    # numpy for the SYSTEM interpreter, because that is where cix-noe-umd's
    # own postinst puts the python bindings: it runs
    # "pip3 install <wheel> --break-system-packages" against system python.
    # NOE_Engine then imports numpy at MODULE SCOPE without declaring it as a
    # dependency, so without this the import dies with
    # "ModuleNotFoundError: No module named 'numpy'" even though libnoe
    # itself imports fine.
    #
    # MEASURED on the O6N v5 install 2026-08-17: libnoe imported cleanly from
    # /usr/local/lib/python3.14/dist-packages, NOE_Engine did not, solely for
    # this reason -- installing python3-numpy was sufficient to make it import
    # and then load and run a real model on the NPU.
    #
    # 88-noe-umd-venv.sh installs numpy into /opt/ncz/noe-venv, but that
    # covers only the venv; when the venv is unavailable or its wheel install
    # fails, the system interpreter is the working path and must not be left
    # one missing dependency short of functional.
    #
    # Simulated first per standing rule: an install that would REMOVE packages
    # is refused rather than silently amputating the system.
    if ! python3 -c 'import numpy' >/dev/null 2>&1; then
        _numpy_remv=$(apt-get install -y -s python3-numpy 2>/dev/null | grep -c '^Remv' || true)
        _numpy_remv=$(printf '%s' "${_numpy_remv:-0}" | tr -dc '0-9' | head -c 8)
        if [ "${_numpy_remv:-0}" = "0" ]; then
            echo "    NPU userspace: installing python3-numpy (NOE_Engine imports it at module scope)"
            if apt-get install -y python3-numpy >/dev/null 2>&1; then
                echo "    NPU userspace: python3-numpy installed"
            else
                echo "    NPU userspace: WARN python3-numpy install failed -- NOE_Engine will not import"
            fi
        else
            echo "    NPU userspace: WARN skipping python3-numpy -- apt wanted to REMOVE $_numpy_remv package(s)"
        fi
    fi
else
    echo "--- NPU userspace: /usr/share/cix/lib not present (matched cix-noe-umd not installed?) ---"
fi

# Bridge between vendor 6.6 .ko vermagic and our built kernel's KVER:
# RETIRED 2026-05-03 with the Sky1-Linux 6.18.14 switch. The cix-*-
# driver debs are now skipped entirely above (DEBS filter), and the
# in-tree 6.18 drivers (panthor, armchina-npu, in-tree amvx, drm/cix,
# cix_dsp_rproc with ACPI fix) take their place. No bridge needed.
RUNNING_KVER=$(uname -r)
echo "    running kernel: $RUNNING_KVER (no OoT bridge — Sky1-Linux in-tree)"

# cix-debian-misc ships cix-audio-switch.service with ExecStart=
# deliberately blanked (a stub for a feature never finished) --
# systemd correctly refuses it ("has no ExecStart=... Refusing"),
# harmless but noisy in the journal on every boot. Mask it rather
# than hand-editing the vendor unit file.
if systemctl list-unit-files cix-audio-switch.service 2>/dev/null | grep -q cix-audio-switch; then
    # `systemctl mask` refuses to replace the package's existing enablement
    # symlink. Disable first, then verify the mask instead of allowing a
    # pipeline through sed to hide systemctl's non-zero status.
    systemctl disable cix-audio-switch.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/multi-user.target.wants/cix-audio-switch.service
    if systemctl mask cix-audio-switch.service >/dev/null 2>&1 && \
       [ "$(systemctl is-enabled cix-audio-switch.service 2>/dev/null)" = masked ]; then
        echo "[25] cix-audio-switch.service masked (vendor stub, empty ExecStart=)"
    else
        echo "[25] WARN: cix-audio-switch.service could not be masked" >&2
    fi
fi

# cix-debian-misc also ships an unconditional request for
# pkcs8_key_parser. Neither NCZ kernel provides that loadable module (a
# built-in parser would not need modprobe), so systemd-modules-load emits a
# false boot error. Remove the stale vendor request.
if [ -f /usr/lib/modules-load.d/pkcs8.conf ]; then
    rm -f /usr/lib/modules-load.d/pkcs8.conf
    echo "[25] removed stale pkcs8_key_parser modules-load request"
fi

# Always exit 0 — Cix postinst quirks should not halt the installer.
# If something is genuinely broken, surfaces during agent runtime
# rather than killing the install before branding/bootloader land.
exit 0
