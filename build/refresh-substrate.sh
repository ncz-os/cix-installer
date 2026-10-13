#!/bin/bash
# refresh-substrate.sh -- fetch the NEWEST Debian testing netinst for an arch,
# verify it (SHA256SUMS + the GPG signature of SHA256SUMS.sign against the
# committed Debian CD signing key), cache it in the substrate cache (keeping the last two),
# and (re)write manifests/base.pin: the substrate sha256 + archive date AND the
# snapshot.debian.org timestamp DERIVED from it by measurement.
#
# The three-origin policy is preserved: the substrate and the snapshot are the
# SAME Debian archive state, so the substrate's content is authorized by the
# pinned snapshot.  There is deliberately NO fourth origin.
#
# Usage: build/refresh-substrate.sh --arch amd64|arm64 [--iso FILE] [--no-fetch]
# Exit: 0 ok; 2 usage/fetch/signature error (fails closed); 3 the derived
#       snapshot authorizes <99% of the substrate (the netinst is stale -- a
#       newer weekly is needed; the missing identities are printed).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ARCH=""; ISO=""; FETCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --iso) ISO="${2:-}"; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$ARCH" in amd64|arm64) ;; *) echo "usage: $0 --arch amd64|arm64 [--iso FILE]" >&2; exit 2 ;; esac

# The reviewed Debian CD signing key.  Committed; the fingerprint is asserted.
CD_KEY="$ROOT/manifests/keys/debian-testing-cd-signing.gpg"
CD_KEY_FPR="F41D30342F3546695F65C66942468F4009EA8AC3"
MAX_AGE_DAYS="${NCZ_SUBSTRATE_MAX_AGE_DAYS:-8}"
BASE_URL="https://cdimage.debian.org/cdimage/weekly-builds/$ARCH/iso-cd"
ISO_NAME="debian-testing-$ARCH-netinst.iso"
# Substrate cache: NCZ_SUBSTRATE_CACHE_DIR, else the first entry of
# NCZ_SUBSTRATE_CACHE_DIRS / ~/.config/ncz/substrate-cache-dir (build/lib/ncz-site.sh).
. "$ROOT/build/lib/ncz-site.sh"
CACHE_DIR="${NCZ_SUBSTRATE_CACHE_DIR:-}"
[ -n "$CACHE_DIR" ] || { _cd="$(ncz_site_value NCZ_SUBSTRATE_CACHE_DIRS substrate-cache-dir)"; CACHE_DIR="${_cd%% *}"; }

die() { echo "refresh-substrate: ERROR: $*" >&2; exit 2; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool missing: $1"; }
for t in curl gpgv sha256sum xorriso python3 sort; do need "$t"; done
[ -s "$CD_KEY" ] || die "committed Debian CD signing key missing: $CD_KEY"
fpr="$(gpg --with-colons --import-options show-only --import "$CD_KEY" 2>/dev/null \
        | awk -F: '/^fpr/{print $10; exit}')"
[ "$fpr" = "$CD_KEY_FPR" ] || die "committed CD key fingerprint '$fpr' != reviewed '$CD_KEY_FPR'"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-substrate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- 1. fetch + verify SHA256SUMS and its signature -------------------------
curl -fsSL "$BASE_URL/SHA256SUMS" -o "$WORK/SHA256SUMS" || die "fetch SHA256SUMS failed"
curl -fsSL "$BASE_URL/SHA256SUMS.sign" -o "$WORK/SHA256SUMS.sign" || die "fetch SHA256SUMS.sign failed"
gpgv --keyring "$CD_KEY" "$WORK/SHA256SUMS.sign" "$WORK/SHA256SUMS" >/dev/null 2>&1 \
  || die "SHA256SUMS.sign does not verify against the committed Debian CD key"
want_sha="$(awk -v n="$ISO_NAME" '$2==n{print $1}' "$WORK/SHA256SUMS")"
[ -n "$want_sha" ] || die "SHA256SUMS does not list $ISO_NAME"

# --- 2. obtain the ISO and verify it ----------------------------------------
if [ -z "$ISO" ] && [ "$FETCH" = 1 ]; then
  ISO="$WORK/$ISO_NAME"
  echo "[substrate] fetching $BASE_URL/$ISO_NAME"
  curl -fsSL "$BASE_URL/$ISO_NAME" -o "$ISO" || die "ISO download failed"
fi
[ -n "$ISO" ] && [ -f "$ISO" ] || die "no ISO given and --no-fetch set"
have_sha="$(sha256sum "$ISO" | awk '{print $1}')"
[ "$have_sha" = "$want_sha" ] || die "ISO sha256 $have_sha != signed $want_sha (rotated/corrupt)"

# --- 3. derive base.pin (substrate -> snapshot by measurement) --------------
echo "[substrate] deriving base.pin for $ARCH from $(basename "$ISO")"
python3 -I "$HERE/derive-base-pin.py" --arch "$ARCH" --iso "$ISO" \
  --scratch "$WORK/scratch" --min-coverage "${NCZ_SUBSTRATE_MIN_COVERAGE:-99}"
rc=$?

# --- 4. cache the verified ISO in the substrate cache (keep the last two per arch)
if [ -n "$CACHE_DIR" ] && [ -d "$CACHE_DIR" ] && [ -w "$CACHE_DIR" ]; then
  short="${have_sha:0:8}"
  date_tag="$(date -u +%Y%m%d)"
  dest="$CACHE_DIR/${ISO_NAME%.iso}-${date_tag}-${short}.iso"
  if [ ! -f "$dest" ]; then cp -f "$ISO" "$dest"; echo "[substrate] cached $dest"; fi
  # keep the newest two for this arch
  ls -1t "$CACHE_DIR/${ISO_NAME%.iso}-"*.iso 2>/dev/null | tail -n +3 | while read -r old; do
    echo "[substrate] pruning old cache $old"; rm -f "$old"
  done
elif [ "$FETCH" = 1 ]; then
  echo "[substrate] WARN: cache dir $CACHE_DIR not writable; ISO not cached" >&2
fi

# --- 4b. sync the pin into release.conf AND the multi-suite trust digests ---
# The snapshot is DERIVED from the substrate, and the substrate's d-i udebs are
# built from the same snapshot's development suite (sid).  So a successful
# refresh must move release.conf's snapshot AND record BOTH suites' signed
# InRelease digests in manifests/forky-snapshot.tsv, in lockstep -- otherwise the
# build fails closed in check-substrate-pin.sh / the provenance gate.  Never runs
# when the measurement failed (rc != 0): a substrate the snapshot cannot
# authorize must not be pinned.
if [ "$rc" = 0 ]; then
  pin_snap="$(awk -F'\t' -v a="$ARCH" '$1==a{print $4}' "$ROOT/manifests/base.pin" 2>/dev/null)"
  if [ -n "$pin_snap" ]; then
    if grep -q '^NCZ_BASE_MIRROR_SNAPSHOT=' "$ROOT/release.conf"; then
      sed -i.ncz "s|^NCZ_BASE_MIRROR_SNAPSHOT=.*|NCZ_BASE_MIRROR_SNAPSHOT=\"$pin_snap\"|" "$ROOT/release.conf"
      rm -f "$ROOT/release.conf.ncz"
      echo "[substrate] release.conf NCZ_BASE_MIRROR_SNAPSHOT -> $pin_snap"
    fi
    echo "[substrate] recording signed InRelease digests for the pinned snapshot $pin_snap"
    python3 -I "$HERE/pin-snapshot-suites.py" --snapshot "$pin_snap" \
      || { echo "refresh-substrate: ERROR: could not record the snapshot's suite digests" >&2; exit 2; }
  fi
  # The local determinism aggregate (manifests/determinism.pin) records the
  # substrate sha per arch, so it must be regenerated in lockstep with base.pin.
  # `make gen-base-pin` is safe here: it reads the sha from Makefile
  # print-substrate-sha, which reads the base.pin we just wrote.
  if [ -x "$HERE/gen-base-pin.sh" ]; then
    echo "[substrate] regenerating manifests/determinism.pin (substrate sha changed)"
    bash "$HERE/gen-base-pin.sh" || \
      echo "[substrate] WARN: gen-base-pin.sh failed; determinism.pin may be stale" >&2
  fi
fi

# --- 5. staleness gate ------------------------------------------------------
sub_date="$(awk -F'\t' -v a="$ARCH" '$1==a{print $3}' "$ROOT/manifests/base.pin" 2>/dev/null)"
if [ -n "$sub_date" ]; then
  sub_epoch="$(date -u -d "$sub_date" +%s 2>/dev/null || echo 0)"
  now="$(date -u +%s)"
  if [ "$sub_epoch" -gt 0 ]; then
    age_days=$(( (now - sub_epoch) / 86400 ))
    echo "[substrate] substrate archive date $sub_date = ${age_days}d old (max ${MAX_AGE_DAYS}d)"
    if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
      echo "refresh-substrate: ERROR: substrate is ${age_days}d old (> ${MAX_AGE_DAYS}d); refresh required" >&2
      exit 3
    fi
  fi
fi
exit "$rc"
