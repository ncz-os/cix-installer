#!/bin/sh
# kvm-gate-dead-manifest.sh RAW_EXT4_IMG [DEAD_BASE] -- rewrite
# ncz-payload/ncz-fetch-payload.manifest inside a RAW EXT4 IMAGE so every
# artifact URL points at DEAD_BASE (default http://10.0.2.2:1: the QEMU
# user-net gateway on a port nothing listens on). Names, sha256s and fetch
# modes are preserved; only the URL's scheme://authority is replaced.
#
# Why: the server-offline-negative gate set must exercise "the pinned payload
# source is DEAD" (the fetcher gives up loud and bounded, nothing installed).
# In shadow-server mode the pin points at the gate's own server which the
# negative run simply does not start. In online mode the medium pins a LIVE
# published URL (the "KVM after upload" release path), so "the server is off"
# alone cannot make the guest fail -- measured 2026-11-09: the negative run
# fetched all three artifacts from the live bucket and the loud-failure
# contract was never exercised. Rewriting the manifest on the run's image COPY
# (the shipped image is never modified) makes both modes behave the same.
#
# The gate carves the NCZDATA partition to a raw image, runs this script and
# writes the raw back (see ncz_gate_srv_dead_manifest in
# build/kvm-install-gate-gpt.sh). Test: build/test-kvm-gate-dead-manifest.sh.
set -eu

IMG="${1:?usage: kvm-gate-dead-manifest.sh RAW_EXT4_IMG [DEAD_BASE]}"
DEAD="${2:-http://10.0.2.2:1}"
DEBUGFS="${DEBUGFS:-$(command -v debugfs 2>/dev/null || echo /usr/sbin/debugfs)}"
[ -f "$IMG" ] || { echo "kvm-gate-dead-manifest: no such image: $IMG" >&2; exit 2; }
[ -x "$DEBUGFS" ] || { echo "kvm-gate-dead-manifest: no debugfs" >&2; exit 2; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ncz-dead-manifest.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT INT TERM

"$DEBUGFS" -R "dump ncz-payload/ncz-fetch-payload.manifest $TMPD/manifest" "$IMG" >/dev/null 2>&1 \
    || { echo "kvm-gate-dead-manifest: no ncz-payload/ncz-fetch-payload.manifest in $IMG" >&2; exit 1; }
[ -s "$TMPD/manifest" ] || { echo "kvm-gate-dead-manifest: empty manifest in $IMG" >&2; exit 1; }

# Manifest rows are name<TAB>url<TAB>sha256<TAB>mode. Replace only the URL
# field's scheme://authority; keep its path (and any URL without a path).
awk -F'\t' -v dead="$DEAD" 'BEGIN { OFS = "\t" }
{
    if (NF >= 2 && $2 ~ /^https?:\/\//) {
        rest = $2
        sub(/^https?:\/\/[^\/]*/, "", rest)
        $2 = dead rest
    }
    print
}' "$TMPD/manifest" > "$TMPD/manifest.dead"

"$DEBUGFS" -w -R "rm ncz-payload/ncz-fetch-payload.manifest" "$IMG" >/dev/null 2>&1 || true
"$DEBUGFS" -w -R "write $TMPD/manifest.dead ncz-payload/ncz-fetch-payload.manifest" "$IMG" >/dev/null 2>&1 \
    || { echo "kvm-gate-dead-manifest: could not write the manifest back into $IMG" >&2; exit 1; }

# read back: the write must be what the guest will read
"$DEBUGFS" -R "dump ncz-payload/ncz-fetch-payload.manifest $TMPD/verify" "$IMG" >/dev/null 2>&1 \
    || { echo "kvm-gate-dead-manifest: the rewritten manifest is not readable back" >&2; exit 1; }
cmp -s "$TMPD/manifest.dead" "$TMPD/verify" \
    || { echo "kvm-gate-dead-manifest: read-back mismatch" >&2; exit 1; }
echo "kvm-gate-dead-manifest: pins rewritten to $DEAD in $IMG"
