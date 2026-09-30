#!/bin/bash
# resolve-sky1-kernel-inputs.sh -- dry-run: print which Sky1 kernel every
# arm64 image-build consumer would pick up from a checkout, WITHOUT building.
#
# It evaluates the real resolution lines out of the scripts themselves
# (not a re-implementation), so it can be run against an older checkout too:
#
#   build/resolve-sky1-kernel-inputs.sh [<checkout-root>]
#
# Used on 2026-09-29 to prove the edge -> mainline channel rename left the
# shipping kernel (r277 7.2.8) byte-identical for every consumer: run it on the
# pre-rename tree and on the renamed tree and diff the output.
set -uo pipefail
ROOT="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
# REPO and ASSETS are read by the eval'd script lines below.
# shellcheck disable=SC2034
REPO="$ROOT"

say() { printf '%-44s %s\n' "$1" "$2"; }
describe() {   # label path
    local p="$2" real
    if [ -e "$p" ]; then
        real="$(readlink -f "$p")"
        say "$1" "$real sha256=$(sha256sum "$p" | cut -c1-16)"
    else
        say "$1" "MISSING ($p)"
    fi
}

cd "$ROOT" || exit 2

# 1. build-iso-di.sh: installer + staged shipping kernel
eval "$(grep -E '^(NEXT_KERN|NEXT_TGZ|NEXT_KVER_FILE)=' build/build-iso-di.sh)"
describe "build-iso-di NEXT_KERN" "$NEXT_KERN"
describe "build-iso-di NEXT_TGZ" "$NEXT_TGZ"
say "build-iso-di KVER_NEXT" "$(cat "$NEXT_KVER_FILE" 2>/dev/null || echo MISSING)"

# 2. build-kernel-debs.sh: package revision + KVER + gate image
rev_block="$(awk '/^_[A-Z]+_LINK="\$\(readlink/{f=1} f{print} /^BUILD_REV=/{exit}' build/build-kernel-debs.sh)"
kver_fn="$(awk '/^resolve_kver\(\) \{/{f=1} f{print} f&&/^}/{exit}' build/build-kernel-debs.sh)"
kver_line="$(grep -E '^KVER_NEXT="\$\{KVER_NEXT:-\$\(resolve_kver ' build/build-kernel-debs.sh)"
( unset BUILD_REV KVER_NEXT
  eval "$rev_block"
  eval "$kver_fn"
  eval "$kver_line"
  say "build-kernel-debs BUILD_REV" "$BUILD_REV"
  say "build-kernel-debs KVER_NEXT" "$KVER_NEXT"
  say "build-kernel-debs channel arg" "$(echo "$kver_line" | sed -E 's/.*resolve_kver ([a-z-]+) .*/\1/')" )
gate_img="$(grep -oE '"\$ASSETS/[a-z-]+/Image-cixmini.bin"' build/build-kernel-debs.sh | head -1)"
# shellcheck disable=SC2034
ASSETS="$ROOT/assets/kernel"
eval "gate_img=$gate_img"
describe "build-kernel-debs KVM-gated Image" "$gate_img"

# 3. build-squashfs-layers.sh: the KVER_NEXT sidecar source
side_src="$(grep -E 'sudo cp .*KVER_NEXT"' build/build-squashfs-layers.sh | grep -oE '"\$ROOT/assets/kernel/[a-z-]+/KVER"' | head -1)"
eval "side_src=$side_src"
say "squashfs KVER_NEXT sidecar source" "$side_src -> $(cat "$side_src" 2>/dev/null || echo MISSING)"
edge_src="$(grep -E 'KVER_EDGE"' build/build-squashfs-layers.sh | grep -oE '"\$ROOT/assets/kernel/[a-z-]+/KVER"' | head -1)"
if [ -n "$edge_src" ]; then
    eval "edge_src=$edge_src"
    say "squashfs KVER_EDGE (test) source" "$edge_src -> $(cat "$edge_src" 2>/dev/null || echo MISSING)"
fi

# 4. Makefile kernel-debs freshness key
mk_kver="$(grep -oE '"\$\(ROOT\)/assets/kernel/[a-z-]+/KVER"' Makefile | head -1 | sed 's/\$(ROOT)/$ROOT/')"
eval "mk_kver=$mk_kver"
say "Makefile kernel-debs freshness KVER" "$mk_kver -> $(cat "$mk_kver" 2>/dev/null || echo MISSING)"

# 5. build-installer-image.sh (incremental assembler) kernel
inst_img="$(grep -oE '"\$ROOT/assets/kernel/[a-z-]+/Image-cixmini.bin"' build/build-installer-image.sh | head -1)"
eval "inst_img=$inst_img"
describe "build-installer-image kernel" "$inst_img"

# 6. vendor-mirror pin (absent before 2026-09-29)
if grep -q 'check-kernel-deb-pin.sh' build/build-vendor-mirror.sh 2>/dev/null; then
    pin="$(grep -oE 'SKY1_KVER_FILE:-[^}]+' build/build-vendor-mirror.sh | head -1 | sed 's/^SKY1_KVER_FILE:-//; s/\$REPO/$ROOT/')"
    eval "pin=$pin"
    say "vendor-mirror kernel pin" "$pin -> $(cat "$pin" 2>/dev/null || echo MISSING)"
else
    say "vendor-mirror kernel pin" "NONE (publishes every deb in build/kernel-debs)"
fi
