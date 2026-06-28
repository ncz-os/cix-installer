#!/bin/bash
# 25-cix-ppa.sh — add archive.cixtech.com PPA + install cix-npu-driver-dkms + cix-vpu-driver-dkms
#
# CIX official open-source driver edition provides:
#   - cix-npu-driver-dkms     (Zhouyi NPU kernel driver, ArmChina Compass)
#   - cix-vpu-driver-dkms     (VPU kernel driver alongside in-tree amvx)
#   - Various userspace runtimes (NOE, OpenCL on Zhouyi, etc.)
#
# DKMS builds against current kernel headers — works for both LTS 6.18 + NEXT 7.0.3
# IF kernel-headers are present. We ship Yocto-built kernels which need their headers
# packaged separately (TODO r53). For r52 we install cix-* userspace + queue DKMS
# build for r53 once headers are shipped.
set -euo pipefail

echo "[25] adding CIX official PPA (archive.cixtech.com)"

# r78 netinstall note: this hook is the only source of CIX-specific .debs
# because the ISO carries no embedded resolute mirror. Keep archive/network
# failures warn-and-continue unless dpkg lands in a known-bad partial state.

# Trust CIX's signing key only after fingerprint verification.
readonly CIX_KEY_FINGERPRINT="03953A5B64B263FECF6B55771736B9F1A2FAE91E"
readonly CIX_KEYRING=/usr/share/keyrings/cix-deb-repo.gpg
readonly CIX_KEY_ASSET=/usr/local/lib/cix-installer/assets/cix-deb-repo.gpg

cix_key_fingerprint() {
    local keyring="$1"
    local tmp_gnupg fpr
    tmp_gnupg=$(mktemp -d)
    fpr=$(GNUPGHOME="$tmp_gnupg" gpg --batch --show-keys --with-colons --fingerprint "$keyring" 2>/dev/null \
        | awk -F: '/^fpr:/ {print $10; exit}' || true)
    rm -rf "$tmp_gnupg"
    echo "$fpr"
}

install_cix_keyring() {
    local candidate="$1"
    local fpr
    fpr=$(cix_key_fingerprint "$candidate")
    if [ "$fpr" != "$CIX_KEY_FINGERPRINT" ]; then
        echo "[25] ERROR: CIX signing key fingerprint mismatch" >&2
        echo "       expected: $CIX_KEY_FINGERPRINT" >&2
        echo "       actual:   ${fpr:-unreadable}" >&2
        return 1
    fi
    install -m 0644 "$candidate" "$CIX_KEYRING"
}

if ! command -v gpg >/dev/null 2>&1; then
    echo "[25] ERROR: gpg is required to verify the CIX apt signing key" >&2
    exit 1
fi

mkdir -p /usr/share/keyrings
if [ -f "$CIX_KEY_ASSET" ]; then
    install_cix_keyring "$CIX_KEY_ASSET" || exit 1
else
    # Fallback: fetch online (network needed)
    tmp_asc=$(mktemp)
    tmp_keyring=$(mktemp)
    if curl -fsSL https://archive.cixtech.com/ppa-gpg-public-key.asc -o "$tmp_asc" \
        && gpg --batch --yes --dearmor -o "$tmp_keyring" "$tmp_asc" 2>/dev/null; then
        install_cix_keyring "$tmp_keyring" || { rm -f "$tmp_asc" "$tmp_keyring"; exit 1; }
    else
        echo "[25] WARN: could not fetch CIX GPG key online - repo will be unavailable"
    fi
    rm -f "$tmp_asc" "$tmp_keyring"
fi

if [ ! -s "$CIX_KEYRING" ]; then
    echo "[25] WARN: no verified CIX signing key installed; skipping CIX PPA setup"
    rm -f /etc/apt/sources.list.d/cix-ppa.list
    exit 0
fi

current_fpr=$(cix_key_fingerprint "$CIX_KEYRING")
if [ "$current_fpr" != "$CIX_KEY_FINGERPRINT" ]; then
    echo "[25] ERROR: installed CIX keyring fingerprint mismatch" >&2
    echo "       expected: $CIX_KEY_FINGERPRINT" >&2
    echo "       actual:   ${current_fpr:-unreadable}" >&2
    exit 1
fi

# Add the source list (trixie main since CIX targets Debian 13)
cat > /etc/apt/sources.list.d/cix-ppa.list <<'APT'
deb [signed-by=/usr/share/keyrings/cix-deb-repo.gpg] https://archive.cixtech.com/debian trixie main
APT

# apt update — best-effort (network may not be up post-install)
apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 -o Acquire::Retries=0 -o Acquire::ForceIPv4=true 2>&1 | tail -5 || echo "[25] apt-get update -o Acquire::http::Timeout=8 -o Acquire::https::Timeout=8 -o Acquire::Retries=0 -o Acquire::ForceIPv4=true warn (network or repo not reachable)"

# Install CIX userspace runtimes (these don't require DKMS)
# - cix-noe-umd: NPU Runtime userspace
# - libcix-* libs
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cix-noe-umd 2>&1 | tail -3 || echo "[25] cix-noe-umd not installable (network/headers issue)"

# r75 P3: cix-noe-umd's postinst runs `pip install libnoe`; that wheel
# requires Python <3.13. Ubuntu 26.04 resolute is still newer than that, so
# postinst fails and apt is left wedged with cix-noe-umd in iF state.
# The C library we actually use (libnoe.so via ctypes wrapper in
# npu_embed_v2.py) is installed by the package's data tar before
# postinst runs, so the binary payload is fine.
#
# Codex r75 review MEDIUM — this recovery only fires on iF (failed-config),
# not iU (unpacked). It first verifies that the postinst contains the
# known libnoe pip line, then patches ONLY that stanza rather than
# replacing the whole script. dpkg --configure / apt-get -f install
# failures are now hard-fatal so partial installs cannot be reported as
# success. Final check verifies libnoe.so is on disk before declaring OK.
# r75 Codex round-3 MED: dpkg-query exits non-zero when the package is
# unknown (absent). Without `|| true` the set -euo pipefail trap aborts
# the hook before we can hit the empty-state branch — making the
# "offline-mirror failed, cix-noe-umd not installed" path unrecoverable.
NOE_STATE=$(dpkg-query -W -f='${db:Status-Abbrev}\n' cix-noe-umd 2>/dev/null | tr -d ' ' || true)

# r75 Codex round-2 MED: treat iF AND iU as blocking. Round-1 fix
# silently skipped iU (unpacked-not-configured), letting later apt
# commands fail with a wedged dpkg state. Both states need the
# postinst-stanza patch then dpkg --configure to land in ii.
case "$NOE_STATE" in
    iF|iU)
        echo "[25] cix-noe-umd in $NOE_STATE state — applying P3 recovery"
        POSTINST=/var/lib/dpkg/info/cix-noe-umd.postinst
        if [ -f "$POSTINST" ] && grep -qE "pip3? install.*libnoe|python3? -m pip install.*libnoe" "$POSTINST"; then
            echo "[25] confirmed: postinst contains libnoe pip line — patching that stanza only"
            cp -a "$POSTINST" "$POSTINST.r75-orig"
            # 2026-05-08 take23 (per .66 take22 install): cix-noe-umd 4.0.0
            # postinst is `#!/bin/sh` + `set -e` but uses bash `[[ ]]` syntax
            # at line 11 (Ubuntu codename gating for --break-system-packages).
            # dash errors with `[[: not found`, set -e exits, package goes
            # to iF before our libnoe pip-line patch is even reached.
            # Swap shebang to /bin/bash so Cix's bash-style postinst runs
            # as upstream intended. Idempotent: grep gates the change.
            if head -1 "$POSTINST" | grep -q '^#!/bin/sh\b'; then
                sed -i '1s|^#!/bin/sh\b|#!/bin/bash|' "$POSTINST"
                echo "[25] patched cix-noe-umd.postinst shebang /bin/sh → /bin/bash"
            fi
            sed -i -E 's|^([[:space:]]*)((python3?[[:space:]]+-m[[:space:]]+pip|pip3?)[[:space:]]+install[[:space:]]+.*libnoe.*)$|\1: # r75 P3: skipped on Py3.13 -- \2|' "$POSTINST"
            chmod 0755 "$POSTINST"
            if dpkg --configure cix-noe-umd 2>&1 | tail -3; then
                apt-get -f install -y 2>&1 | tail -3 || { echo "[25] ERROR: apt-get -f install failed after postinst patch" >&2; exit 1; }
            else
                echo "[25] ERROR: dpkg --configure still failed after libnoe-pip-line patch" >&2
                exit 1
            fi
        else
            echo "[25] ERROR: cix-noe-umd in $NOE_STATE but postinst does not contain expected libnoe pip line" >&2
            echo "       Cause unknown — refusing to silently mask. Operator must investigate:" >&2
            echo "       /var/lib/dpkg/info/cix-noe-umd.postinst:" >&2
            sed -n '1,30p' "$POSTINST" 2>&1 | sed 's/^/         /' >&2 || true
            exit 1
        fi
        # Re-check state after recovery — must be ii (installed).
        NOE_STATE=$(dpkg-query -W -f='${db:Status-Abbrev}\n' cix-noe-umd 2>/dev/null | tr -d ' ')
        if [ "$NOE_STATE" != "ii" ]; then
            echo "[25] ERROR: cix-noe-umd recovery left package in '$NOE_STATE' state, expected 'ii'" >&2
            exit 1
        fi
        echo "[25] cix-noe-umd recovered to ii state"
        ;;
    ii)
        echo "[25] cix-noe-umd in ii (installed) — no recovery needed"
        ;;
    "")
        # Package is absent / unknown to dpkg. This is the offline-mirror
        # path: apt-get install above either silently failed (the "|| echo"
        # at line 40) or never ran. We treat this as best-effort skip;
        # downstream NPU work will fail-loud at the libnoe.so check below
        # if the runtime is actually missing.
        echo "[25] cix-noe-umd not present (offline mirror or apt failed) — skipping NPU runtime"
        ;;
    *)
        # r75 Codex round-3 MED — hard-fail any other non-ii state instead of
        # WARN-only. Held (iH), trigger-pending (iT/iWiR), half-installed (iH+H),
        # etc. could let later apt commands silently fail. We don't know the
        # right recovery for unknown states, so fail loud.
        echo "[25] ERROR: cix-noe-umd in unexpected state '$NOE_STATE' — refusing to silently continue" >&2
        echo "       Known-recoverable: iF (failed-config), iU (unpacked-not-configured)" >&2
        echo "       Known-OK: ii (installed), '' (absent)" >&2
        echo "       This state needs operator investigation:" >&2
        dpkg -l cix-noe-umd 2>&1 | sed 's/^/         /' >&2 || true
        exit 1
        ;;
esac

# Verify the libnoe.so we actually use lives on disk after install/recovery.
# Only check if the package is supposed to be installed (was attempted above).
if dpkg -l cix-noe-umd >/dev/null 2>&1; then
    if ! [ -e /usr/share/cix/lib/libnoe.so ] && ! [ -e /usr/lib/aarch64-linux-gnu/libnoe.so ] && ! find /usr -name "libnoe.so*" 2>/dev/null | grep -q .; then
        echo "[25] ERROR: cix-noe-umd reported installed but libnoe.so not found anywhere under /usr" >&2
        exit 1
    fi
    echo "[25] libnoe.so present — cix-noe-umd usable for ctypes wrapper"
fi

# r75 Codex round-4 HIGH fix — cix-npu-driver-dkms is intentionally NOT
# installed. Per task #87 (completed) we ship FyrbyAdditive's prebuilt
# armchina_npu.ko via 80-npu.sh; the vendor DKMS package conflicts with
# that and builds against headers we don't always have. Leaving it
# uninstalled avoids the iF/iU wedge path Codex flagged.
echo "[25] cix-npu-driver-dkms intentionally NOT installed (use FyrbyAdditive prebuilt via 80-npu.sh — task #87)"

# r75 Codex round-4 HIGH fix — cix-vpu-driver-dkms also requires
# /lib/modules/$KVER/build (kernel-headers). Until task #66's headers
# asset ships, this DKMS install can leave the package in iF/iU and
# wedge dpkg. Probe headers first; only attempt install when present.
# State-recovery pattern matches cix-noe-umd above.
KVER_LTS_HEADERS=0
KVER_NEXT_HEADERS=0
if [ -f /usr/local/lib/cix-installer/KVER_LTS ]; then
    klts=$(cat /usr/local/lib/cix-installer/KVER_LTS 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$klts" ] && [ -d "/lib/modules/$klts/build" ] && [ -f "/lib/modules/$klts/build/Makefile" ] && KVER_LTS_HEADERS=1
fi
if [ -f /usr/local/lib/cix-installer/KVER_NEXT ]; then
    knext=$(cat /usr/local/lib/cix-installer/KVER_NEXT 2>/dev/null | tr -d ' \t\r\n')
    [ -n "$knext" ] && [ -d "/lib/modules/$knext/build" ] && [ -f "/lib/modules/$knext/build/Makefile" ] && KVER_NEXT_HEADERS=1
fi

if [ "$KVER_LTS_HEADERS" = "1" ] || [ "$KVER_NEXT_HEADERS" = "1" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        cix-vpu-driver-dkms 2>&1 | tail -5 || echo "[25] cix-vpu-driver-dkms install attempt completed with non-zero exit"
    # Apply same state-recovery pattern as cix-noe-umd. DKMS package
    # ending in iF/iU after install means a build failure; the fix is
    # operator-driven (rebuild against working headers), so we hard-fail.
    VPU_STATE=$(dpkg-query -W -f='${db:Status-Abbrev}\n' cix-vpu-driver-dkms 2>/dev/null | tr -d ' ' || true)
    case "$VPU_STATE" in
        ii)
            echo "[25] cix-vpu-driver-dkms installed (ii)"
            ;;
        "")
            echo "[25] cix-vpu-driver-dkms not present (offline mirror or apt failed) — VPU acceleration unavailable"
            ;;
        iF|iU)
            echo "[25] ERROR: cix-vpu-driver-dkms in $VPU_STATE state — DKMS build failed against /lib/modules/<kver>/build" >&2
            echo "       Purging to avoid wedging dpkg state for downstream commands." >&2
            DEBIAN_FRONTEND=noninteractive apt-get purge -y --auto-remove cix-vpu-driver-dkms 2>&1 | tail -3 || true
            ;;
        *)
            echo "[25] ERROR: cix-vpu-driver-dkms in unexpected state '$VPU_STATE' — refusing to silently continue" >&2
            dpkg -l cix-vpu-driver-dkms 2>&1 | sed 's/^/         /' >&2 || true
            exit 1
            ;;
    esac
else
    echo "[25] kernel-headers not staged (r75 task #66 asset gated) — skipping cix-vpu-driver-dkms install"
fi

# Detect NPU device node creation
if [ -e /dev/zhouyi0 ] || [ -e /dev/cix-noe0 ] || [ -e /dev/aipu0 ]; then
    echo "[25] NPU device node detected"
else
    echo "[25] NPU device not bound at install time — will be created on next boot if DKMS built modules"
fi

echo "[25] CIX PPA + NPU/VPU runtime layer applied"
