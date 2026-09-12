#!/bin/bash
# 78-audio.sh — ensure the CIX Sky1 HDMI/DP audio stack autoloads on boot.
#
# Problem, measured on O6N (2026-09-12) comparing a real 7.2.5 boot against
# 7.3-rc2 after the CIXHA010 clock-driver fix (patches-7.2/0065): on 7.2.5
# dmesg shows the I2S-MC controller actually probing --
#   cdns-i2s-mc CIXH6011:02: I2S-MC driver probed
# -- and /proc/asound/cards lists a real HDMI/DP audio card. On 7.3-rc2 the
# module (snd_soc_cdns_i2s_mc) is present, correctly built (CONFIG_SND_SOC_
# CDNS_I2S_MC=m), and even loaded (lsmod shows it resident) -- but it never
# actually binds: no "probed" line in dmesg, /proc/asound/cards stays empty,
# and userspace (PipeWire) falls back to "dummy output". The module carries
# a correct ACPI modalias (acpi*:CIXH6011:*) and modules.alias is generated
# correctly by depmod -- this is the exact same udev-coldplug-timing class of
# bug already fixed for amvx (81-vpu.sh) and aipu (80-npu.sh): the ACPI
# device enumerates very early, before systemd-udevd's post-switch-root
# coldplug re-trigger reliably re-evaluates it against the real root's
# module set. List the modules explicitly here rather than relying on
# modalias autoload, same fix shape as the other two.
#
# RUNS INSIDE CHROOT / on-target (via run-all.sh). Owns ONLY the audio
# autoload step -- does not touch ALSA/PipeWire config, mixer settings, or
# any codec driver beyond ensuring these two modules are present at boot.
set +e

echo "[78] ensuring Sky1 HDMI/DP audio stack auto-loads on boot..."

mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/ncz-audio.conf << 'EOF'
# NCZ 26.7: Cix Sky1 HDMI/DP audio (Cadence I2S multi-channel + sky1-asoc-card)
# Probes CIXH6011:0[0-6] (I2S-MC controllers) and CIXH6070:00 (the ASoC sound
# card that binds them to the hdmi-audio-codec instances) -- creates the
# HDMI/DP ALSA card (aplay -l / /proc/asound/cards).
#
# Both modules carry correct ACPI modaliases and modules.alias is generated
# correctly by depmod, but they do not reliably autoload via udev coldplug
# alone (measured on O6N 2026-09-12: alias present, ACPI device present,
# module resident via lsmod, but never bound -- no "I2S-MC driver probed"
# line, no ALSA card, PipeWire falls back to dummy output). Same
# udev-coldplug-timing class of gap as aipu/NPU and amvx/VPU (see
# 80-npu.sh's and 81-vpu.sh's own ncz-*.conf comments) -- list them
# explicitly rather than rely on modalias autoload.
snd_soc_cdns_i2s_mc
snd_soc_sky1_sound_card
EOF

echo "[78] wrote /etc/modules-load.d/ncz-audio.conf"

exit 0
