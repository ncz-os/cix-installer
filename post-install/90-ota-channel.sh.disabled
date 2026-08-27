#!/bin/bash
# 90-ota-channel.sh — install the NCZ OTA client (ghcr.io container -> ephemeral APT repo).
#
# Strategy: the OTA payload (kernel + CIX drivers, as an APT repo) is shipped as
# a squashfs inside a public OCI image at ghcr.io/ncz-os/cix-repo. `ncz-update`
# pulls the image, extracts + loop-mounts the squashfs *only for the duration of
# the apt transaction*, then fully unloads it (unmount, detach loop, delete the
# squashfs, prune the pulled image, drop the temp apt source). Nothing about the
# 2.1GB+ repo is left mounted, cached, or on disk after the upgrade completes.
#
# WHY ephemeral (not a persistent fstab loop mount):
#   - Footprint: a persistent loop mount keeps the squashfs backing file (2.1GB+)
#     on disk forever and lets its decompressed pages accumulate in the page
#     cache. On an appliance with modest storage/RAM we only want it resident
#     while apt is actually reading debs.
#   - Hygiene: leaving a signed file:// source mounted permanently widens the
#     trust window and makes every later `apt update` depend on the mount.
#
# Authenticity: the repo's Release is GPG-signed by the NCZ OTA archive key; the
# device pins the matching public keyring via signed-by (no trusted=yes), so apt
# rejects any unsigned or foreign-signed repo even if the OCI image is swapped.
#   - Determinism: the repo is a transient build input, not part of the running
#     system. Pull -> use -> discard keeps the installed system reproducible.
#
# This hook only installs the client + scaffolding (offline-safe). No network
# pull happens at install time.
set -euo pipefail

echo "[90] installing NCZ OTA channel client (ncz-update)"

OTA_IMG_DEFAULT="ghcr.io/ncz-os/cix-repo:26.6"

# ----------------------------------------------------------------------
# /usr/local/sbin/ncz-update — the ephemeral OTA client
# ----------------------------------------------------------------------
install -d /usr/local/sbin
cat > /usr/local/sbin/ncz-update <<'NCZUPDATE'
#!/bin/bash
# ncz-update — pull the NCZ OTA APT repo from its ghcr.io container, use it for
# a single apt transaction, then UNLOAD it completely.
#
#   ncz-update [--image REF] [--apply] [--status]
#
#   (default)  pull + mount + list available cix/kernel upgrades, then unload.
#   --apply    additionally apt-install --only-upgrade the cix/kernel packages.
#   --status   show configured image + currently-installed versions (no pull).
#
# The repo is EPHEMERAL by design: it is loop-mounted read-only only while apt
# reads from it, and a teardown trap guarantees it is unmounted, its loop device
# detached, its squashfs deleted, the pulled OCI image pruned, and the temporary
# apt source removed — even if the run fails partway. See README "OTA channel".
set -uo pipefail

CONF=/etc/ncz-ota.conf
IMG="ghcr.io/ncz-os/cix-repo:26.6"
KEYRING=/usr/share/keyrings/ncz-ota-archive-keyring.gpg
COSIGN_PUB=/usr/share/keyrings/ncz-ota-cosign.pub
COSIGN_VER=v2.4.3
COSIGN_ARM64_SHA=bd0f9763bca54de88699c3656ade2f39c9a1c7a2916ff35601caf23a79be0629
[ -f "$CONF" ] && . "$CONF"

SUITE=ncz
WORK=/var/cache/ncz-ota               # transient, on-disk staging (deleted on exit)
SQUASH="$WORK/cix-repo.squashfs"
MNT=/run/ncz-ota/repo                 # transient mountpoint (tmpfs dir; data is the file)
APT_LIST=/etc/apt/sources.list.d/ncz-ota.list
STATE=/var/lib/cixmini/ota-last       # breadcrumb of last successful apply
PRUNE_IMG=0                           # set once we pull, so teardown prunes it

die(){ echo "ncz-update: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "must run as root"

APPLY=0; STATUS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --image) IMG="$2"; shift 2;;
        --apply) APPLY=1; shift;;
        --status) STATUS=1; shift;;
        *) die "unknown arg: $1";;
    esac
done

if [ "$STATUS" = 1 ]; then
    echo "image:     $IMG"
    echo "mode:      ephemeral (repo is never left mounted)"
    [ -f "$STATE" ] && { echo "last apply:"; sed 's/^/  /' "$STATE"; } || echo "last apply: (none recorded)"
    echo "installed cix/kernel packages:"
    dpkg-query -W -f='  ${Package} ${Version}\n' \
        'linux-image-cixmini-*' 'cixmini-*' 'cix-*' 2>/dev/null | grep -v ' $' || echo "  (none)"
    exit 0
fi

# ----------------------------------------------------------------------
# teardown — ALWAYS runs (EXIT trap). Unload everything OTA-related.
# ----------------------------------------------------------------------
teardown() {
    set +e
    # 1. drop the transient apt source + its cached index so later `apt update`
    #    does not depend on (or warn about) the now-gone file:// repo.
    rm -f "$APT_LIST"
    rm -f /var/lib/apt/lists/*ncz-ota* /var/lib/apt/lists/_run_ncz-ota* 2>/dev/null

    # 2. unmount the repo (lazy if apt or a shell is still holding it busy).
    if mountpoint -q "$MNT"; then
        umount "$MNT" 2>/dev/null || umount -l "$MNT" 2>/dev/null
    fi
    rmdir "$MNT" 2>/dev/null; rmdir "$(dirname "$MNT")" 2>/dev/null

    # 3. detach any loop device still backed by our squashfs file.
    if [ -e "$SQUASH" ]; then
        for ld in $(losetup -j "$SQUASH" 2>/dev/null | cut -d: -f1); do
            losetup -d "$ld" 2>/dev/null
        done
    fi

    # 4. delete the on-disk squashfs + staging dir (frees the 2.1GB backing
    #    file; its decompressed page-cache pages become reclaimable once the
    #    file is gone and the mount is dropped).
    rm -rf "$WORK"

    # 5. prune the pulled OCI image so it does not sit in container storage.
    if [ "$PRUNE_IMG" = 1 ]; then
        if command -v podman >/dev/null 2>&1; then podman rmi -f "$IMG" >/dev/null 2>&1; fi
        if command -v docker >/dev/null 2>&1; then docker rmi -f "$IMG" >/dev/null 2>&1; fi
    fi
    sync
}
trap teardown EXIT

# ----------------------------------------------------------------------
# ensure_cosign — print a usable cosign path, fetching the pinned arm64
# binary (sha256-checked) if none is installed. Returns nonzero if unavailable.
# ----------------------------------------------------------------------
ensure_cosign() {
    command -v cosign >/dev/null 2>&1 && { command -v cosign; return 0; }
    [ -x /usr/local/bin/cosign ] && { echo /usr/local/bin/cosign; return 0; }
    case "$(uname -m)" in aarch64|arm64) ;; *) return 1 ;; esac
    local tmp; tmp=$(mktemp)
    echo "ncz-update: fetching cosign $COSIGN_VER (arm64)..." >&2
    curl -fsSL -o "$tmp" \
        "https://github.com/sigstore/cosign/releases/download/$COSIGN_VER/cosign-linux-arm64" \
        || { rm -f "$tmp"; return 1; }
    local got; got=$(sha256sum "$tmp" | cut -d' ' -f1)
    [ "$got" = "$COSIGN_ARM64_SHA" ] || {
        echo "ncz-update: cosign sha256 mismatch (got=$got want=$COSIGN_ARM64_SHA)" >&2
        rm -f "$tmp"; return 1; }
    install -m 0755 "$tmp" /usr/local/bin/cosign; rm -f "$tmp"
    echo /usr/local/bin/cosign
}

# ----------------------------------------------------------------------
# verify-before-mount: cosign-verify the OCI image signature against the
# pinned NCZ OTA cosign public key, then pin IMG to the EXACT digest that
# was verified (avoids tag TOCTOU). This is the transport-layer gate; the
# GPG-signed apt Release inside the squashfs is verified again below.
# ----------------------------------------------------------------------
if [ -s "$COSIGN_PUB" ]; then
    CB=$(ensure_cosign) || die "cosign required (pubkey present at $COSIGN_PUB) but unavailable — refusing"
    echo "ncz-update: cosign-verifying $IMG"
    VOUT=$("$CB" verify --insecure-ignore-tlog --key "$COSIGN_PUB" "$IMG" 2>/dev/null) \
        || die "cosign verification FAILED for $IMG — refusing"
    VDIG=$(printf '%s' "$VOUT" | grep -oE 'sha256:[a-f0-9]{64}' | head -1)
    if [ -n "$VDIG" ]; then
        base=${IMG%@*}; base=${base%:*}
        IMG="$base@$VDIG"
        echo "ncz-update: cosign OK — pinned to $VDIG"
    fi
else
    echo "ncz-update: WARN no cosign pubkey ($COSIGN_PUB); skipping image-signature check (GPG repo signature still enforced)" >&2
fi

# ----------------------------------------------------------------------
# pull + extract the squashfs (prefer a daemonless tool).
# ----------------------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK" "$MNT"
WANT=""
if command -v podman >/dev/null 2>&1; then
    echo "ncz-update: pulling $IMG (podman)"
    podman pull "$IMG" || die "podman pull failed"; PRUNE_IMG=1
    pm=$(podman image mount "$IMG") || die "podman image mount failed"
    cp "$pm/cix-repo.squashfs" "$SQUASH"
    WANT=$(podman inspect "$IMG" --format '{{ index .Labels "dev.nclawzero.repo.squashfs.sha256" }}' 2>/dev/null)
    podman image unmount "$IMG" >/dev/null 2>&1
elif command -v skopeo >/dev/null 2>&1; then
    echo "ncz-update: pulling $IMG (skopeo)"
    mkdir -p "$WORK/oci"
    skopeo copy "docker://$IMG" "dir:$WORK/oci" || die "skopeo copy failed"
    layer=$(ls -S "$WORK/oci" | head -1)
    ( cd "$WORK" && tar xzf "oci/$layer" cix-repo.squashfs 2>/dev/null ) || \
        ( cd "$WORK" && tar xf "oci/$layer" cix-repo.squashfs ) || die "layer extract failed"
    rm -rf "$WORK/oci"
elif command -v docker >/dev/null 2>&1; then
    echo "ncz-update: pulling $IMG (docker)"
    docker pull "$IMG" || die "docker pull failed"; PRUNE_IMG=1
    cid=$(docker create "$IMG" 2>/dev/null || docker create "$IMG" /x 2>/dev/null)
    docker cp "$cid:/cix-repo.squashfs" "$SQUASH"
    docker rm "$cid" >/dev/null 2>&1
    WANT=$(docker inspect "$IMG" --format '{{ index .Config.Labels "dev.nclawzero.repo.squashfs.sha256" }}' 2>/dev/null)
else
    die "no container tool (podman/skopeo/docker) found"
fi
[ -f "$SQUASH" ] || die "failed to extract cix-repo.squashfs"

# Fast pre-mount integrity check against the image label. This is a cheap
# tamper/corruption tripwire; real *authenticity* is enforced by (1) the cosign
# image-signature verify-before-mount above (digest-pinned) and (2) apt verifying
# the GPG-signed Release against the pinned NCZ OTA keyring (signed-by) below.
GOT=$(sha256sum "$SQUASH" | cut -d' ' -f1)
if [ -n "$WANT" ] && [ "$WANT" != "$GOT" ]; then
    die "squashfs sha256 mismatch (label=$WANT got=$GOT) — refusing"
fi
echo "ncz-update: squashfs sha256=$GOT"

# ----------------------------------------------------------------------
# mount transiently + run the apt transaction.
# ----------------------------------------------------------------------
mount -o loop,ro "$SQUASH" "$MNT" || die "loop-mount failed"

# Authenticity comes from the GPG-signed Release inside the squashfs, verified
# against the NCZ OTA public keyring provisioned at install time. We pin that
# keyring with signed-by (NOT trusted=yes), so apt refuses any repo whose
# InRelease is not signed by the NCZ OTA archive key — even if the OCI image or
# squashfs is swapped at the registry.
[ -s "$KEYRING" ] || die "OTA keyring missing ($KEYRING) — cannot verify signed repo"
cat > "$APT_LIST" <<EOF
deb [signed-by=$KEYRING] file://$MNT $SUITE main
EOF

echo "ncz-update: indexing OTA repo (this source only)..."
apt-get update -o Dir::Etc::sourcelist="$APT_LIST" \
               -o Dir::Etc::sourceparts="-" \
               -o APT::Get::List-Cleanup="0" >/dev/null 2>&1 \
    || die "apt-get update failed for OTA source"

PKGS=$(grep -E '^Package: ' "$MNT/dists/$SUITE/main/binary-arm64/Packages" | awk '{print $2}' | sort -u)

echo ""
echo "NCZ OTA repo ($IMG) — available cix/kernel packages:"
echo "$PKGS" | sed 's/^/  /'

if [ "$APPLY" = 1 ]; then
    echo ""
    echo "ncz-update: applying upgrades..."
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $PKGS \
       || DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS; then
        mkdir -p "$(dirname "$STATE")"
        { echo "date=$(date -u +%FT%TZ)"; echo "image=$IMG"; echo "squashfs_sha256=$GOT"; } > "$STATE"
        echo "ncz-update: upgrade complete. New kernel entries (if any) are on the ESP; reboot to switch."
    else
        die "apt-get install failed"
    fi
else
    echo ""
    echo "Run 'ncz-update --apply' to install these upgrades."
fi

# EXIT trap performs the full unload here.
echo "ncz-update: unloading OTA repo (unmount + delete + prune image)..."
NCZUPDATE
chmod 0755 /usr/local/sbin/ncz-update

# ----------------------------------------------------------------------
# Default config (image ref overridable post-install)
# ----------------------------------------------------------------------
cat > /etc/ncz-ota.conf <<EOF
# NCZ OTA channel configuration.
# Override the OTA container image ref here (pin by digest for production).
IMG="$OTA_IMG_DEFAULT"
EOF

# No persistent mount, no persistent apt source: the repo is ephemeral.
rm -f /etc/apt/sources.list.d/ncz-ota.list 2>/dev/null || true

# ----------------------------------------------------------------------
# Provision the NCZ OTA public keyring so ncz-update can verify the
# GPG-signed Release via signed-by (no trusted=yes). The matching private
# key lives only on the build host (build/keys/, gitignored).
# ----------------------------------------------------------------------
KEYSRC=""
for c in /usr/local/lib/cix-installer/assets/keys/ncz-ota-archive-keyring.gpg \
         /cdrom/cixmini/assets/keys/ncz-ota-archive-keyring.gpg; do
    [ -f "$c" ] && { KEYSRC="$c"; break; }
done
if [ -n "$KEYSRC" ]; then
    install -d -m 0755 /usr/share/keyrings
    install -m 0644 "$KEYSRC" /usr/share/keyrings/ncz-ota-archive-keyring.gpg
    echo "[90] OTA archive keyring installed: /usr/share/keyrings/ncz-ota-archive-keyring.gpg"
else
    echo "[90] WARN: NCZ OTA public keyring not found in assets/keys — ncz-update will refuse to verify until it is provisioned" >&2
fi

# Provision the cosign IMAGE-signing public key so ncz-update can verify the OCI
# image signature before mounting (verify-before-mount). cosign itself is fetched
# on demand (pinned, sha256-checked) by ncz-update if not already present.
COSIGNSRC=""
for c in /usr/local/lib/cix-installer/assets/keys/ncz-ota-cosign.pub \
         /cdrom/cixmini/assets/keys/ncz-ota-cosign.pub; do
    [ -f "$c" ] && { COSIGNSRC="$c"; break; }
done
if [ -n "$COSIGNSRC" ]; then
    install -d -m 0755 /usr/share/keyrings
    install -m 0644 "$COSIGNSRC" /usr/share/keyrings/ncz-ota-cosign.pub
    echo "[90] OTA cosign public key installed: /usr/share/keyrings/ncz-ota-cosign.pub"
else
    echo "[90] WARN: NCZ OTA cosign public key not found in assets/keys — image-signature check disabled (GPG repo signature still enforced)" >&2
fi

# Best-effort: ensure a container client exists on the target.
if ! command -v podman >/dev/null 2>&1 && ! command -v skopeo >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends podman 2>/dev/null || \
        echo "[90] WARN: no podman/skopeo available; install one before using ncz-update online"
fi

echo "[90] OTA channel client installed:"
echo "      image   : $OTA_IMG_DEFAULT"
echo "      command : ncz-update [--apply] [--status]"
echo "      model   : ephemeral (repo pulled, used, then fully unloaded)"
echo "      trust   : cosign verify-before-mount + GPG signed-by repo (no trusted=yes)"
