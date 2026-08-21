#!/bin/bash
# 88-noe-umd-venv.sh — install the CIX NPU userspace (cix-noe-umd) into a
# Python venv the wheels will actually accept.
#
# Why this exists: cix-noe-umd's postinst does
#
#     pip3 install /usr/share/cix/pypi/libnoe-2.0.0-...whl --break-system-packages
#     pip3 install /usr/share/cix/pypi/NOE_Engine-2.0.0-...whl --break-system-packages
#
# against the SYSTEM interpreter. On Debian forky that is Python 3.14, and the
# wheels pin Requires-Python >=3.11,<3.13, so the install aborts:
#
#     ERROR: Package 'libnoe' requires a different Python: 3.14.6 not in '<3.13,>=3.11'
#
# dpkg then leaves the package half-configured (state "iF"), which also blocks
# later apt transactions. Debian forky ships no python3.11 or python3.12, so the
# interpreter has to come from somewhere else: uv installs a standalone CPython
# for aarch64, which is already the fleet-sanctioned way to get a Python that is
# not the system one.
#
# Approach: build the venv, install the wheels into it, then rewrite the deb's
# postinst so it targets the venv directly. The package reaches a properly
# configured state instead of being force-marked. The original postinst is kept
# as .ncz-orig for reference.
#
# --- Why this hook REWRITES the postinst (and not just the wheels) ---
# The postinst is a maintainer script. Maintainer scripts are part of a
# package's CONTROL archive and are written by dpkg directly into
# /var/lib/dpkg/info/<pkg>.postinst. dpkg-divert governs only DATA-archive
# files, not maintainer scripts, so a diversion would register cleanly but
# never be honoured. (Verified: dpkg-divert succeeds on the command line
# but the vendor postinst is still what gets executed on upgrade.) The
# only way to keep the rewrite intact across an `apt upgrade` of the
# package is to also `apt-mark hold` it.
#
# The hold is the protection. The rewrite itself is kept idempotent so
# that if an operator manually `apt-mark unhold cix-noe-umd && apt upgrade`
# (e.g. to chase a security update) the next run of this hook will
# re-apply the rewrite against the new vendor postinst and self-heal.
# 2026-08-21 update: the matched NPU stack is now KMD 6.2.0 + UMD 3.1.4 (asid_base[4]),
# not the older 2.0.x (asid_base[32]) stack. UMD 2.0.2 wedges at noe_init_context on
# the r247+ KMD because of the asid_base[4] -> asid_base[32] ABI widening; see
# packaging/cix-npu-driver-dkms-6.2.0/README.md ("the matched NPU stack, hardened").
# 80-npu.sh still claims 2.0.2 (its MobileNet 640-inf/s measurement was on MS-R1
# with the v0-compat ioctl layer + the OLDER KMD); on the r247+ NCZ edge kernel
# the 2.0.2 UMD cannot query capability and every NPU call dies before loading
# a graph. The pin below stays at whatever the staged vendor deb installs (no
# explicit Version= pin) and the staging-side fix in build/stage-canonical-assets.sh
# removes the pre-Q2 cix-noe-umd_2.0.2 from assets/cix-debs/ so the forky vendor
# mirror's 3.1.4-cixdeb13-260714 wins. The +ncz2 DKMS package preserves the
# O6N-validated +ncz1 runtime-PM fix and adds the MS-R1 IRQ-probe fix.
#
# Per docs/post-install/80-npu.sh only cix-noe-umd 2.0.2 is confirmed
# working with our v0-compat ioctl layer, so the hold is also the
# documented policy.
#
# Never fatal: the NPU kernel driver and /dev/aipu do not depend on any of this.
# Without it you lose Python inference, not the device.
set -uo pipefail

VENV=/opt/ncz/noe-venv
PYVER=3.12          # wheels accept 3.11 or 3.12; 3.12 is the newer supported one
WHEELDIR=/usr/share/cix/pypi

echo "[88] setting up the NPU userspace (cix-noe-umd) venv"

# --- pin the package at the validated version -------------------------------
# Per 80-npu.sh only cix-noe-umd 2.0.2 is confirmed working with our
# v0-compat ioctl layer; an `apt upgrade` would reinstall the vendor
# postinst and restore the apt-wedging bug the rewrite below exists to
# prevent. The hold is what keeps the rewrite in place.
#
# We do NOT try to hold at the top of this hook. On a fresh install the
# package is not yet installed when this hook starts (it is installed
# by the block immediately below, or by a later hook, or by the OEM
# image); a `if dpkg -s ... ; then hold ; fi` at the top of the hook
# silently no-ops on exactly the path that matters. The hold is applied
# at the bottom of this hook, after install + configure + rewrite,
# guarded by `dpkg -s` against the package's now-known-installed
# state. Verified both orderings:
#   - already-present: bottom-of-hook sees dpkg -s succeed; hold runs.
#   - freshly-installed: bottom-of-hook sees dpkg -s succeed; hold runs.
# A manual `apt-mark unhold cix-noe-umd && apt upgrade` (operator
# chasing a security update) is still self-healing: the rewrite block
# below detects the restored vendor postinst and re-applies our
# replacement on the next hook run; the hold will also be re-applied
# at the bottom.

# --- the runtime package (ships libnoe.so + the wheels) ----------------------
if ! dpkg -s cix-noe-umd >/dev/null 2>&1; then
    echo "[88] installing cix-noe-umd"
    DEBIAN_FRONTEND=noninteractive apt-get install -y cix-noe-umd >/dev/null 2>&1 || true
fi
if [ ! -d "$WHEELDIR" ]; then
    echo "[88] no wheels at $WHEELDIR — cix-noe-umd not available; skipping"
    exit 0
fi

# --- an interpreter the wheels accept ---------------------------------------
UV=$(command -v uv || echo "$HOME/.local/bin/uv")
if [ ! -x "$UV" ]; then
    echo "[88] installing uv (needed for a standalone CPython $PYVER)"
    curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null | sh >/dev/null 2>&1 || true
    UV="$HOME/.local/bin/uv"
fi
if [ ! -x "$UV" ]; then
    echo "[88] WARNING: uv unavailable — cannot build the venv; NPU inference will not work"
    exit 0
fi

"$UV" python install "$PYVER" >/dev/null 2>&1 || true

if [ ! -x "$VENV/bin/python" ]; then
    mkdir -p "$(dirname "$VENV")"
    "$UV" venv --python "$PYVER" "$VENV" >/dev/null 2>&1 \
        || { echo "[88] WARNING: could not create $VENV"; exit 0; }
fi
echo "[88] venv: $VENV ($("$VENV/bin/python" --version 2>&1))"

# --- the wheels, plus what they actually need --------------------------------
# NOE_Engine imports numpy at module scope but does not declare it, so a venv
# built only from the shipped wheels raises ModuleNotFoundError on first import.
# pip is seeded because the deb's postinst calls pip3 (see the shim below).
#
# RESOLVE THE WHEELS EXPLICITLY. The previous version passed
# "$WHEELDIR"/NOE_Engine-*.whl straight to uv, and the vendor actually ships
# the PEP-427-normalised name -- lowercase, underscore:
#
#     /usr/share/cix/pypi/noe_engine-3.0.0-py3-none-manylinux2014_aarch64.whl
#
# so that glob NEVER MATCHED. An unmatched glob is passed through literally,
# and uv rejects the whole invocation on the one bad argument:
#
#     error: The wheel filename "NOE_Engine-*.whl" is invalid: Must have a Python tag
#
# which means libnoe, numpy AND pip were all silently skipped too -- one bad
# glob emptied the entire venv. Measured on O6N 2026-08-18: /opt/ncz/noe-venv
# existed, was on the right interpreter (3.12.14), and contained nothing but
# _virtualenv.py, so the NPU embed server (89-npu-embed-server.sh runs
# $VENV/bin/python) could never start. The `|| echo WARNING` hid it: a warning
# in a 40-hook install log reads as noise, and nothing downstream checked.
#
# Accept both spellings, and require each wheel to actually resolve.
shopt -s nullglob
_wheels=()
for _pat in 'libnoe-*.whl' 'noe_engine-*.whl' 'NOE_Engine-*.whl'; do
    for _w in "$WHEELDIR"/$_pat; do _wheels+=("$_w"); done
done
shopt -u nullglob

if [ ${#_wheels[@]} -eq 0 ]; then
    echo "[88] WARNING: no libnoe/noe_engine wheels matched in $WHEELDIR — NPU inference will not work"
    echo "[88]          contents: $(ls -1 "$WHEELDIR" 2>/dev/null | tr '\n' ' ')"
else
    echo "[88] installing ${#_wheels[@]} wheel(s) + numpy into $VENV"
    "$UV" pip install --python "$VENV/bin/python" "${_wheels[@]}" numpy pip \
        >/dev/null 2>&1 \
        || echo "[88] WARNING: wheel install into $VENV failed"
fi

# --- keep the venv in step with the deb, FOREVER, not just at install -------
#
# This hook is POST-INSTALL, so it runs once on a fresh image and never again.
# That is not sufficient, and cixmini proved it: on 2026-08-18 that board had
# kernel driver AIPU KMD v6.2.0 and cix-noe-umd 3.1.4 installed, while
# /opt/ncz/noe-venv still held libnoe 2.0.0 / NOE-Engine 2.0.0 from an earlier
# image. The old user-mode driver cannot query the newer kernel driver's
# capabilities, so every NPU call died before loading a graph:
#
#     [UMD ERR] aipu.cpp:57: query capability [fail]
#     RuntimeError: npu: noe_init_context fail
#
# It reads like a kernel or hardware fault and is neither -- and it had sat
# broken on the build host for an unknown length of time, because nothing
# re-syncs the venv when the deb is upgraded.
#
# Install a boot-time oneshot that compares the installed cix-noe-umd version
# against a stamp and re-syncs the wheels when they differ. Cheap (a dpkg-query
# and a string compare on the common path) and idempotent.
install -d /usr/local/lib/cix-installer
cat > /usr/local/lib/cix-installer/sync-noe-venv.sh <<'SYNC'
#!/bin/bash
# Re-sync /opt/ncz/noe-venv when cix-noe-umd changes version.
# The user-mode driver in the venv must match the kernel driver, or every NPU
# call fails at noe_init_context with "query capability [fail]".
set -uo pipefail
VENV=/opt/ncz/noe-venv
WHEELDIR=/usr/share/cix/pypi
STAMP=/var/lib/ncz/noe-venv.stamp
[ -x "$VENV/bin/python" ] || exit 0
[ -d "$WHEELDIR" ] || exit 0
cur=$(dpkg-query -W -f='${Version}' cix-noe-umd 2>/dev/null || echo none)
prev=$(cat "$STAMP" 2>/dev/null || echo none)
# Re-sync when the deb moved OR the venv cannot import -- the second catches a
# venv broken for any other reason without needing to know why.
if [ "$cur" = "$prev" ] && "$VENV/bin/python" -c 'import numpy, NOE_Engine' >/dev/null 2>&1; then
    exit 0
fi
echo "[noe-venv-sync] cix-noe-umd=$cur (was $prev) — re-syncing $VENV"
UV=$(command -v uv || echo /usr/local/bin/uv)
[ -x "$UV" ] || { echo "[noe-venv-sync] uv missing — cannot sync"; exit 0; }
shopt -s nullglob
w=()
for pat in 'libnoe-*.whl' 'noe_engine-*.whl' 'NOE_Engine-*.whl'; do
    for f in "$WHEELDIR"/$pat; do w+=("$f"); done
done
shopt -u nullglob
[ ${#w[@]} -gt 0 ] || { echo "[noe-venv-sync] no wheels in $WHEELDIR"; exit 0; }
"$UV" pip install --python "$VENV/bin/python" "${w[@]}" numpy pip >/dev/null 2>&1
if "$VENV/bin/python" -c 'import numpy, NOE_Engine' >/dev/null 2>&1; then
    install -d "$(dirname "$STAMP")"; printf '%s' "$cur" > "$STAMP"
    echo "[noe-venv-sync] OK — venv imports cleanly"
else
    echo "[noe-venv-sync] WARNING: venv still cannot import NOE_Engine/numpy"
fi
SYNC
chmod 0755 /usr/local/lib/cix-installer/sync-noe-venv.sh

cat > /etc/systemd/system/ncz-noe-venv-sync.service <<'UNIT'
[Unit]
Description=Re-sync the NPU user-mode driver venv with the installed cix-noe-umd
Documentation=https://github.com/nclawzero/cix-installer
ConditionPathExists=/opt/ncz/noe-venv/bin/python
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=no
ExecStart=/usr/local/lib/cix-installer/sync-noe-venv.sh

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable ncz-noe-venv-sync.service >/dev/null 2>&1 \
    && echo "[88]   enabled ncz-noe-venv-sync.service (venv follows the deb across upgrades)" \
    || echo "[88]   WARN: could not enable ncz-noe-venv-sync.service"
printf '%s' "$(dpkg-query -W -f='${Version}' cix-noe-umd 2>/dev/null || echo none)" \
    > /var/lib/ncz/noe-venv.stamp 2>/dev/null || {
        install -d /var/lib/ncz
        printf '%s' "$(dpkg-query -W -f='${Version}' cix-noe-umd 2>/dev/null || echo none)" \
            > /var/lib/ncz/noe-venv.stamp 2>/dev/null || true
    }

# VERIFY, do not assume. The bug above survived because the only evidence of
# failure was an echo nobody read. Import what the embed server imports, and
# say plainly whether the venv is usable.
if "$VENV/bin/python" -c 'import numpy, NOE_Engine' >/dev/null 2>&1; then
    echo "[88]   venv OK: NOE_Engine + numpy import cleanly"
else
    echo "[88]   WARNING: $VENV cannot import NOE_Engine/numpy — NPU embed server will not start"
    "$VENV/bin/python" -c 'import numpy, NOE_Engine' 2>&1 | tail -2 | sed 's/^/[88]     /'
fi

# --- let the deb finish configuring ------------------------------------------
# The obvious approach -- drop a pip3 shim in /usr/local/bin and let the vendor
# postinst pick it up -- DOES NOT WORK, and silently. dpkg runs maintainer
# scripts with a fixed PATH that does not include /usr/local/bin:
#
#     POSTINST PATH=[/usr/sbin:/usr/bin:/sbin:/bin]      (measured on forky)
#
# so the shim is invisible and /usr/bin/pip3 (system python 3.14) runs anyway,
# fails the Requires-Python bound, and leaves the package half-configured "iF".
# That state blocks EVERY later apt transaction on the image, which is how a
# shipped board ended up unable to install anything at all.
#
# So rewrite the postinst to target the venv directly. The vendor original is
# kept as .ncz-orig for reference. dpkg-divert is NOT an option: maintainer
# scripts come from a package's CONTROL archive and are written by dpkg
# directly into /var/lib/dpkg/info/ — a diversion would register cleanly but
# be ignored. The `apt-mark hold` set below (after install + configure)
# is what keeps this rewrite in place across `apt upgrade`.
PI=/var/lib/dpkg/info/cix-noe-umd.postinst
if [ -f "$PI" ]; then
    # Idempotent rewrite: if the current postinst is already the one we
    # wrote, do nothing; if it's the vendor original, back it up first;
    # if it's a freshly-restored vendor postinst (operator did
    # `unhold + apt upgrade` of cix-noe-umd), back that up too so we keep
    # a reference and then re-apply our replacement. This is what makes
    # a manual unhold self-heal.
    if grep -q 'Rewritten by cix-installer hook 88-noe-umd-venv.sh' "$PI" 2>/dev/null; then
        echo "[88] postinst already rewritten — leaving in place"
    else
        # Rotate the backup so an unhold+upgrade captures the new
        # vendor postinst as the reference, not the original install.
        if [ -f "${PI}.ncz-orig" ]; then
            mv "${PI}.ncz-orig" "${PI}.ncz-orig.prev"
        fi
        cp "$PI" "${PI}.ncz-orig"
        cat > "$PI" <<EOF
#!/bin/sh
# Rewritten by cix-installer hook 88-noe-umd-venv.sh.
# The cix-noe-umd wheels are tagged py3-none but ship CPython ABI objects for
# 3.11/3.12 only, and libnoe/__init__.py hard-raises on anything else. Debian
# forky ships python3.14, so the vendor's system-wide pip3 install can never
# succeed. Install into the NCZ venv instead, and never exit non-zero.
set -u
VENV=$VENV
UV=\$(command -v uv || echo /usr/local/bin/uv)
if [ -x "\$UV" ] && [ -x "\$VENV/bin/python" ]; then
    "\$UV" pip install --python "\$VENV/bin/python" \\
        /usr/share/cix/pypi/libnoe-*.whl \\
        /usr/share/cix/pypi/NOE_Engine-*.whl numpy >/dev/null 2>&1 \\
        || echo "cix-noe-umd: wheel install into \$VENV failed" >&2
else
    echo "cix-noe-umd: no venv/uv; NPU userspace not installed" >&2
fi
exit 0
EOF
        chmod 0755 "$PI"
        echo "[88] postinst rewritten (vendor copy preserved as ${PI}.ncz-orig)"
    fi
fi

if [ "$(dpkg -s cix-noe-umd 2>/dev/null | awk '/^Status:/{print $4}')" != "installed" ]; then
    echo "[88] completing cix-noe-umd configuration"
    dpkg --configure cix-noe-umd >/dev/null 2>&1 \
        && echo "[88] cix-noe-umd configured" \
        || echo "[88] WARNING: cix-noe-umd still not configured"
fi

# --- verify, and say plainly whether inference is actually possible ----------
if "$VENV/bin/python" -c "import libnoe, NOE_Engine, numpy" >/dev/null 2>&1; then
    echo "[88] verified: libnoe + NOE_Engine + numpy import cleanly"
else
    echo "[88] WARNING: the UMD stack does not import; NPU inference will not work"
fi

# --- pin the package at the validated version -------------------------------
# Applied here, AFTER install + rewrite + configure, so it runs on BOTH
# the already-present case (package in the OEM image / a previous hook
# pass) and the freshly-installed case (the install block above pulled
# the deb from the offline pool / network this run). The earlier "if
# dpkg -s" hold at the top of the hook was a no-op on fresh installs —
# this one covers both orderings.
if dpkg -s cix-noe-umd >/dev/null 2>&1; then
    HOLD_STATE=$(dpkg --get-selections cix-noe-umd 2>/dev/null | awk '{print $2}')
    if [ "$HOLD_STATE" = "hold" ]; then
        echo "[88] cix-noe-umd already on hold (rewrite protected)"
    else
        if apt-mark hold cix-noe-umd >/dev/null 2>&1; then
            echo "[88] cix-noe-umd put on hold (matched-stack 3.1.4-cixdeb13-260714 is validated; protects postinst rewrite)"
        else
            echo "[88] WARN: could not hold cix-noe-umd; rewrite above is still applied but is at risk from \`apt upgrade\`" >&2
        fi
    fi
fi

cat > /usr/local/bin/ncz-npu-python <<EOF
#!/bin/sh
# The interpreter that can drive the NPU. The system python is too new for the
# cix-noe-umd wheels (they pin >=3.11,<3.13).
exec $VENV/bin/python "\$@"
EOF
chmod 0755 /usr/local/bin/ncz-npu-python
echo "[88] wrapper: ncz-npu-python -> $VENV/bin/python"

exit 0
