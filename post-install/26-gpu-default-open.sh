#!/bin/bash
# 26-gpu-default-open.sh — make the open Mesa stack the default GPU compute
# provider by demoting the CIX proprietary libmali blob out of the global
# dynamic-linker path so it cannot shadow the OpenCL ICD loader.
#
# Why: the cixgpu-pro package (installed by 25-cix-*) ships
# /etc/ld.so.conf.d/00-cixgpu-pro.conf, which puts /opt/cixgpu-pro/lib FIRST
# in the ld cache. That makes its libOpenCL.so.1 — a non-ICD vendor lib that
# needs the CIX mali_kbase kernel driver (NOT present; panthor owns the GPU) —
# the system libOpenCL, shadowing ocl-icd's ICD loader so
# /etc/OpenCL/vendors/rusticl.icd is never honored ("No mali devices found").
#
# Renaming the conf lets ocl-icd win -> rusticl enumerates the Mali-G720 via
# panthor (OpenCL 3.0 / Mesa 26.1.3). The CIX blob stays on disk for a future
# opt-in GPU switcher (panthor <-> cix mali_kbase, landing with the 7.1 DKMS
# kbase). Must run AFTER 25-cix-* (which installs the cixgpu-pro conffile).
#
# RUNS INSIDE CHROOT (via run-all.sh). Offline-safe, idempotent.
set -uo pipefail

CONF=/etc/ld.so.conf.d/00-cixgpu-pro.conf
if [ -f "$CONF" ]; then
    mv "$CONF" "$CONF.disabled"
    echo "[26] demoted CIX proprietary libmali from global ld path (open Mesa = default GPU compute)"
elif [ -f "$CONF.disabled" ]; then
    echo "[26] CIX proprietary libmali already demoted"
else
    echo "[26] no $CONF (CIX proprietary GPU stack not installed) — open Mesa already default"
fi
ldconfig 2>/dev/null || true

WIN=$(ldconfig -p 2>/dev/null | awk "/libOpenCL.so.1 /{print \$NF; exit}")
echo "[26] system libOpenCL.so.1 -> ${WIN:-<none>}"
exit 0
