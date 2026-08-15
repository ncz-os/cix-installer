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
# Approach: build the venv, install the wheels into it, then run dpkg's own
# postinst with pip3 temporarily pointed at that venv so the package reaches a
# properly configured state instead of being force-marked. The shim is removed
# immediately afterwards -- a permanent /usr/local/bin/pip3 redirect would
# silently capture every other pip3 user on the box.
#
# Never fatal: the NPU kernel driver and /dev/aipu do not depend on any of this.
# Without it you lose Python inference, not the device.
set -uo pipefail

VENV=/opt/ncz/noe-venv
PYVER=3.12          # wheels accept 3.11 or 3.12; 3.12 is the newer supported one
WHEELDIR=/usr/share/cix/pypi

echo "[88] setting up the NPU userspace (cix-noe-umd) venv"

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
"$UV" pip install --python "$VENV/bin/python" \
    "$WHEELDIR"/libnoe-*.whl "$WHEELDIR"/NOE_Engine-*.whl numpy pip \
    >/dev/null 2>&1 \
    || echo "[88] WARNING: wheel install into $VENV failed"

# --- let the deb finish configuring, using the venv's pip --------------------
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
# So rewrite the postinst to target the venv directly. The original is kept as
# .ncz-orig for reference. This is idempotent: re-running rewrites the same
# content, and the replacement always exits 0 so a vendor userspace blob can
# never wedge apt again.
PI=/var/lib/dpkg/info/cix-noe-umd.postinst
if [ -f "$PI" ]; then
    [ -f "${PI}.ncz-orig" ] || cp "$PI" "${PI}.ncz-orig"
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

cat > /usr/local/bin/ncz-npu-python <<EOF
#!/bin/sh
# The interpreter that can drive the NPU. The system python is too new for the
# cix-noe-umd wheels (they pin >=3.11,<3.13).
exec $VENV/bin/python "\$@"
EOF
chmod 0755 /usr/local/bin/ncz-npu-python
echo "[88] wrapper: ncz-npu-python -> $VENV/bin/python"

exit 0
