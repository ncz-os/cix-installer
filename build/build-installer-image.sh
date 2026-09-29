#!/bin/bash
# Shared raw-GPT installer-image orchestration for amd64 and arm64.
# Mechanics are identical; only kernel packaging and architecture assets differ.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ARCH=${ARCH:-$(dpkg --print-architecture 2>/dev/null || uname -m)}
case "$ARCH" in aarch64) ARCH=arm64 ;; x86_64) ARCH=amd64 ;; esac
case "$ARCH" in amd64|arm64) ;; *) echo "FATAL: unsupported ARCH=$ARCH" >&2; exit 2 ;; esac

SUBSTRATE_ISO=${SUBSTRATE_ISO:?set SUBSTRATE_ISO to a Debian installer ISO}
SUBSTRATE_URL=${SUBSTRATE_URL:-file://$SUBSTRATE_ISO}
OUTPUT=${OUTPUT:?set OUTPUT to the final .img path}
WORK_DIR=${WORK_DIR:-$HOME/build-tmp/cix-installer-$ARCH}

# BUILD_VERSION / BUILD_SHA -- directive 10 requires the commit SHA be
# stamped into every produced artifact. The caller (Makefile, dispatch
# host, CI) is the AUTHORITATIVE source: if it set BUILD_VERSION and/or
# BUILD_SHA in its environment, use those verbatim. Only fall back to git
# if neither was given. Inside the rootful ncz-imagebuild container git
# can't read the host checkout because of dubious-ownership (the host UID
# is not the container UID), so add the canonical safe-directory escape
# hatch BEFORE invoking git -- this is the same fleet-standard fix the
# kernel-build checklist §0f and preflight-freshness-gate.sh already use,
# just applied one step earlier so the in-container default works
# without manual intervention. If git STILL fails after that, error out
# loudly rather than silently producing a `ncz-os-arm64-<date>-.img`
# with an empty sha component (the 2026-09-28 arm64 stage-2 incident:
# the operator got an unstamped artifact and the entire nightly ISO
# pipeline stalled because nobody could tell which build was which).
if [ -z "${BUILD_VERSION:-}" ]; then
    git config --global --add safe.directory '*' 2>/dev/null || true
    if command -v git >/dev/null 2>&1 && [ -d "$ROOT/.git" ]; then
        _sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)
        if [ -n "$_sha" ]; then
            BUILD_VERSION="$(date -u +%Y.%m.%d)-${_sha}"
        fi
    fi
    if [ -z "${BUILD_VERSION:-}" ]; then
        echo "FATAL: BUILD_VERSION/BUILD_SHA unresolved." >&2
        echo "       Either pass BUILD_VERSION=\$(date -u +%Y.%m.%d)-<sha> or" >&2
        echo "       BUILD_SHA=<sha> in the environment, or fix git ownership" >&2
        echo "       in the container (git config --global --add safe.directory '*')." >&2
        echo "       An unstamped 'ncz-os-<arch>-<date>-.img' is not a valid artifact." >&2
        exit 3
    fi
fi
# Build the canonical "<version>-<sha>" string BUILD_VERSION from a
# caller-supplied BUILD_SHA if necessary, so the rest of the pipeline
# (which reads BUILD_VERSION as a single string) gets a consistent shape.
if [ -z "${BUILD_VERSION:-}" ] && [ -n "${BUILD_SHA:-}" ]; then
    BUILD_VERSION="$(date -u +%Y.%m.%d)-${BUILD_SHA}"
fi
# Final guard -- this should be unreachable, but a defense-in-depth
# refuse-to-ship-empty-sha guard here means a regression in the
# caller-supplied path ALSO can't slip an empty sha past us.
case "$BUILD_VERSION" in
    *-) echo "FATAL: BUILD_VERSION ends in '-' (empty sha component): $BUILD_VERSION" >&2
         echo "       an unstamped artifact is not a valid artifact." >&2
         exit 3 ;;
esac
echo "[build-installer-image] BUILD_VERSION=$BUILD_VERSION"
CACHE_ROOT=${CACHE_ROOT:-$ROOT/build/iso-cache/v1}
export TMPDIR=${TMPDIR:-$HOME/build-tmp}
mkdir -p "$TMPDIR" "$WORK_DIR" "$(dirname "$OUTPUT")"

run_capture() { local log=$1; shift; "$@" 2>&1 | tee "$log"; }

echo "[1/6] importing $ARCH substrate"
run_capture "$WORK_DIR/import.log" python3 "$ROOT/build/iso/import-substrate.py" \
  --iso "$SUBSTRATE_ISO" --iso-url "$SUBSTRATE_URL" --arch "$ARCH"
SUBSTRATE_NODE=$(sed -n -e 's/^node_dir: //p' -e 's/^node exists: //p' \
  "$WORK_DIR/import.log" | tail -1)
[ -d "$SUBSTRATE_NODE/extract/d-i" ] || { echo "FATAL: imported substrate has no extract/d-i" >&2; exit 1; }

echo "[2/6] staging architecture-matched squashfs payload"
run_capture "$WORK_DIR/payload.log" python3 "$ROOT/build/iso/stage-ncz-payload.py" --arch "$ARCH"
PAYLOAD_NODE=$(sed -n -e 's/^node_dir: //p' -e 's/^node exists: //p' \
  -e 's/^OK: staged payload at //p' "$WORK_DIR/payload.log" | tail -1)
[ -d "$PAYLOAD_NODE" ] || { echo "FATAL: payload node not reported" >&2; exit 1; }

echo "[3/6] patching debootstrap installer stub"
UDEB_ARGS=()
if [ ! -d "$SUBSTRATE_NODE/extract/pool" ]; then
  DEBOOTSTRAP_UDEB=${DEBOOTSTRAP_UDEB:-$(find "$ROOT/build/iso-cache/v1/nodes/$ARCH/substrate" \
    -path '*/extract/pool/*' -type f -name 'debootstrap-udeb_*_all.udeb' | head -1)}
  if [ ! -f "${DEBOOTSTRAP_UDEB:-}" ]; then
    echo "    no cached debootstrap udeb; resolving the real forky package"
    UDEB_INDEX="$WORK_DIR/Packages-debian-installer.xz"
    curl -fL -o "$UDEB_INDEX" \
      "https://deb.debian.org/debian/dists/forky/main/debian-installer/binary-$ARCH/Packages.xz"
    # Consume the complete index instead of exiting awk on the first match.
    # With pipefail enabled, an early awk exit closes the pipe while xz is
    # still writing, so xz receives SIGPIPE and the whole substitution exits
    # 141 even though the requested Filename was found successfully.
    UDEB_REL=$(xz -dc "$UDEB_INDEX" | awk '
      $1 == "Package:" { pkg=$2 }
      !found && pkg == "debootstrap-udeb" && $1 == "Filename:" {
        print $2
        found=1
      }
    ')
    [ -n "$UDEB_REL" ] || { echo "FATAL: debootstrap-udeb absent from forky installer index" >&2; exit 1; }
    DEBOOTSTRAP_UDEB="$WORK_DIR/$(basename "$UDEB_REL")"
    curl -fL -o "$DEBOOTSTRAP_UDEB" "https://deb.debian.org/debian/$UDEB_REL"
  fi
  UDEB_ARGS+=(--source-udeb "$DEBOOTSTRAP_UDEB")
fi
python3 "$ROOT/build/iso/patch-debootstrap-stub.py" \
  --substrate-node-dir "$SUBSTRATE_NODE" --arch "$ARCH" "${UDEB_ARGS[@]}" \
  --report "$WORK_DIR/debootstrap-receipt.json"
PATCHED_UDEB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["staged_udeb_path"])' "$WORK_DIR/debootstrap-receipt.json")

echo "[4/6] preparing architecture kernel/initrd"
INITRD_ARGS=(--base-initrd "$SUBSTRATE_NODE/extract/d-i/initrd.gz" --arch "$ARCH")
if [ "$ARCH" = arm64 ]; then
  INITRD_ARGS+=(--kernel-image "$ROOT/assets/kernel/edge/Image-cixmini.bin"
                --modules-tar "$ROOT/assets/kernel/edge/modules-cixmini.tgz")
else
  KERNEL_DEB=${KERNEL_DEB:-$(find "$ROOT/assets/kernel/amd64-stable" -maxdepth 1 -type f -name 'linux-image-*.deb' | sort -V | tail -1)}
  [ -f "$KERNEL_DEB" ] || { echo "FATAL: set KERNEL_DEB to the amd64 installer kernel package" >&2; exit 1; }
  INITRD_ARGS+=(--kernel-deb "$KERNEL_DEB")
fi
run_capture "$WORK_DIR/initrd.log" python3 "$ROOT/build/iso/patch-initrd-t2-kernel.py" "${INITRD_ARGS[@]}"
LINUX=$(tail -2 "$WORK_DIR/initrd.log" | head -1)
INITRD=$(tail -1 "$WORK_DIR/initrd.log")
[ -f "$LINUX" ] && [ -f "$INITRD" ] || { echo "FATAL: kernel patcher outputs not found" >&2; exit 1; }

echo "[5/6] building rEFInd ESP"
rm -rf "$WORK_DIR/esp"
python3 "$ROOT/build/iso/build-refind-esp.py" --arch "$ARCH" \
  --out-dir "$WORK_DIR/esp" --size-mib 256 --d-i-kernel "$LINUX" --d-i-initrd "$INITRD"

echo "[6/6] writing and independently verifying raw GPT image"
python3 "$ROOT/build/iso/write-usb-image.py" --arch "$ARCH" \
  --esp-img "$WORK_DIR/esp/esp.img" --ncz-payload-dir "$PAYLOAD_NODE" \
  --installer-pool "$SUBSTRATE_NODE/extract/pool" \
  --patched-udeb "$PATCHED_UDEB" --build-version "$BUILD_VERSION" \
  --out "$OUTPUT" --work-dir "$WORK_DIR/writer"
sha256sum "$OUTPUT" > "$OUTPUT.sha256"
echo "OK: $OUTPUT"
