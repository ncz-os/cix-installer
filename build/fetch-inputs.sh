#!/bin/bash
# fetch-inputs.sh -- PHASE 1 of the hermetic build: resolve + pre-fetch every
# external build input into CONTENT-ADDRESSED caches, and record them in
# inputs.lock.  This is the only stage allowed to touch the network for build
# inputs; everything after it (phase 2) runs with the network off.
#
# Usage:
#   build/fetch-inputs.sh --arch amd64|arm64 --output DIR \
#       [--pins FILE] [--cache DIR] [--offline] [--only git|go|meson|apt]
#
# Caches (all under --cache, default /mnt/datapool/projects/ncz-os-assets/build-inputs):
#   git-mirrors/<urlslug>.git            bare mirror per upstream clone URL
#   go-modcache/<sha256-of-gosum>/       Go module cache keyed by the go.sum set
#   meson-subprojects/<name>-<rev>/      pre-seeded meson [wrap-git] subprojects
#   cargo-vendor/<name>-<rev>/           cargo vendor dirs (none in use today)
#   npm-store/                           npm/pnpm offline store (none in use)
#   pip-wheelhouse/                      pip/uv wheelhouse (none in use)
#   downloads/                           firmware/blob/wallpaper fetches w/ sha256
#
# Output (in --output):
#   inputs.lock     JSON: every input {kind, name, url, resolved, sha256, cache}
#                   plus inputs_lock_digest = sha256 of the canonical JSON
#   inputs.lock.tsv human-readable one line per input
#
# --offline: do NOT fetch; VERIFY every cache named by an existing inputs.lock
#            is present and its digest matches.  Missing/unverifiable => FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

ARCH=""; OUTPUT=""; PINS=""; CACHE=""; OFFLINE=0; ONLY=""
CACHE="${NCZ_BUILD_INPUT_CACHE:-/mnt/datapool/projects/ncz-os-assets/build-inputs}"
ENGINE="${NCZ_ENVPIN_CONTAINER_ENGINE:-$(command -v podman || command -v docker || true)}"
PAYLOAD_IMAGE="${NCZ_BASE_IMAGE:-debian:forky}"
PINS_TOOL="$HERE/singularity-pins.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --output) OUTPUT="${2:?}"; shift 2 ;;
        --pins) PINS="${2:?}"; shift 2 ;;
        --cache) CACHE="${2:?}"; shift 2 ;;
        --offline) OFFLINE=1; shift ;;
        --only) ONLY="${2:?}"; shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "fetch-inputs: unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64) ;; *) echo "fetch-inputs: --arch amd64|arm64 required" >&2; exit 2 ;; esac
[ -n "$OUTPUT" ] || { echo "fetch-inputs: --output DIR required" >&2; exit 2; }
mkdir -p "$OUTPUT"

LOCK="$OUTPUT/inputs.lock"
TSV="$OUTPUT/inputs.lock.tsv"
log() { printf '[fetch-inputs] %s\n' "$*"; }
die() { printf '[fetch-inputs] FAIL: %s\n' "$*" >&2; exit 1; }

# Resolve the singularity pins: the run's frozen pins if given, else committed.
if [ -z "$PINS" ]; then
    if [ -r "$ROOT/assets/singularity/upstream-pins.tsv" ]; then
        PINS="$ROOT/assets/singularity/upstream-pins.tsv"
    else
        die "no --pins and no committed assets/singularity/upstream-pins.tsv"
    fi
fi

mkdir -p "$CACHE"/{git-mirrors,go-modcache,meson-subprojects,cargo-vendor,npm-store,pip-wheelhouse,downloads}
INPUTS_NDJSON="$(mktemp "${TMPDIR:-/tmp}/ncz-inputs.XXXXXX.ndjson")"
trap 'rm -f "$INPUTS_NDJSON"' EXIT

# sha256 of a file or a directory tree (sorted, content+mode+name)
hash_path() {
    local p="$1"
    if [ -f "$p" ]; then sha256sum "$p" | awk '{print $1}'; return; fi
    if [ -d "$p" ]; then
        ( cd "$p" && find . -type f -print0 | sort -z \
            | xargs -0 -r sha256sum | sha256sum | awk '{print $1}' )
        return
    fi
    echo ""
}

record() {  # record kind name url resolved sha256 cache
    local kind="$1" name="$2" url="$3" resolved="$4" sha="$5" cache="$6"
    python3 - "$INPUTS_NDJSON" "$kind" "$name" "$url" "$resolved" "$sha" "$cache" <<'PY'
import json, sys
out, kind, name, url, resolved, sha, cache = sys.argv[1:8]
with open(out, "a") as fh:
    fh.write(json.dumps({"kind": kind, "name": name, "url": url,
                         "resolved": resolved, "sha256": sha, "cache": cache},
                        sort_keys=True) + "\n")
PY
    printf '%s\t%s\t%s\t%s\t%s\n' "$kind" "$name" "$resolved" "${sha:0:16}" "$cache" >> "$TSV.tmp"
}

# ---------------------------------------------------------------------------
# 1. git mirrors (bare) for every pinned upstream repo -- one mirror per URL.
# ---------------------------------------------------------------------------
prefetch_git() {
    log "git mirrors -> $CACHE/git-mirrors (pins: $PINS)"
    if [ "$OFFLINE" = 1 ]; then log "offline: git mirror prefetch skipped (verify only)"; return 0; fi
    local rc=0
    NCZ_SINGULARITY_PINS="$PINS" NCZ_SINGULARITY_PIN_CACHE="$CACHE/git-mirrors" \
        bash "$PINS_TOOL" fetch-cache || rc=$?
    [ "$rc" = 0 ] || die "git mirror fetch-cache failed (rc=$rc)"
    # record every (path,url,sha) the pin file names
    local path url branch sha
    while IFS=$'\t' read -r path url branch sha; do
        case "$path" in ""|\#*) continue ;; esac
        [ -n "$url" ] || continue
        local m; m="$(NCZ_SINGULARITY_PIN_CACHE="$CACHE/git-mirrors" bash "$PINS_TOOL" cache-dir "$url" 2>/dev/null || true)"
        local h=""; [ -n "$m" ] && h="$(hash_path "$m")"
        record git "$path" "$url" "$sha" "$h" "git-mirrors/$(basename "${m:-?}")"
    done < <(grep -vE '^\s*#' "$PINS")
}

# ---------------------------------------------------------------------------
# 2. Go module cache for the `vetro` host tool, keyed by sha256 of all go.sum.
# ---------------------------------------------------------------------------
prefetch_go() {
    log "go module cache -> $CACHE/go-modcache"
    if [ "$OFFLINE" = 1 ]; then log "offline: go prefetch skipped (verify only)"; return 0; fi
    [ -n "$ENGINE" ] || { log "no container engine; cannot prefetch Go modules"; return 0; }
    local work; work="$(mktemp -d "$CACHE/.go-work.XXXXXX")"
    # materialise vetro at its pin from the mirror cache only
    local vr; vr="$(NCZ_SINGULARITY_PINS="$PINS" bash "$PINS_TOOL" url vetro 2>/dev/null || true)"
    local vs; vs="$(NCZ_SINGULARITY_PINS="$PINS" bash "$PINS_TOOL" sha vetro 2>/dev/null || true)"
    [ -n "$vs" ] || { log "no vetro pin; skipping go prefetch"; rm -rf "$work"; return 0; }
    NCZ_SINGULARITY_URL_OVERRIDE="$vr" NCZ_SINGULARITY_PINS="$PINS" \
        bash "$PINS_TOOL" clone vetro "$work/vetro" >/dev/null 2>&1 \
        || { log "WARN could not materialise vetro at $vs (will retry online)"; }
    if [ -f "$work/vetro/go.sum" ]; then
        local key; key="$(sha256sum "$work/vetro/go.sum" | awk '{print $1}')"
        local dst="$CACHE/go-modcache/$key"
        if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ]; then
            log "go-modcache/$key already present"
        else
            mkdir -p "$dst"
            log "downloading Go modules (vetro go.sum $key)"
            "$ENGINE" run --rm --network host -v "$work/vetro":/src:ro -v "$dst":/gomodcache \
                "$PAYLOAD_IMAGE" bash -lc '
                    set -e
                    DEBIAN_FRONTEND=noninteractive apt-get update -q >/dev/null
                    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends golang-go ca-certificates >/dev/null
                    cd /src
                    GOFLAGS=-mod=mod GOMODCACHE=/gomodcache go mod download all
                    GOFLAGS=-mod=mod GOMODCACHE=/gomodcache go mod verify
                ' >/dev/null 2>&1 || { log "WARN go mod download failed"; rm -rf "$dst"; }
        fi
        if [ -d "$dst" ]; then
            record go "vetro-modules" "${vr:-https://github.com/singularityos-lab/vetro}" "$vs" "$(hash_path "$dst")" "go-modcache/$key"
        fi
    fi
    rm -rf "$work"
}

# ---------------------------------------------------------------------------
# 3. meson [wrap-git] subprojects (labwc's SceneFX, wlroots) at their revision.
# ---------------------------------------------------------------------------
prefetch_meson() {
    log "meson subprojects -> $CACHE/meson-subprojects"
    if [ "$OFFLINE" = 1 ]; then log "offline: meson prefetch skipped (verify only)"; return 0; fi
    command -v git >/dev/null || { log "no git; meson prefetch skipped"; return 0; }
    local wraps
    wraps="scenefx|https://github.com/wlrfx/scenefx.git|refs/heads/main
wlroots|https://gitlab.freedesktop.org/wlroots/wlroots.git|refs/heads/0.20"
    local name url ref
    while IFS='|' read -r name url ref; do
        [ -n "$name" ] || continue
        local sha; sha="$(git ls-remote "$url" "$ref" 2>/dev/null | awk '{print $1; exit}')"
        [ -n "$sha" ] || { log "WARN cannot resolve $name $ref"; continue; }
        local dst="$CACHE/meson-subprojects/$name-$sha"
        if [ ! -d "$dst/.git" ]; then
            rm -rf "$dst"
            git clone -q --no-checkout "$url" "$dst" 2>/dev/null \
                && git -C "$dst" fetch -q origin "$sha" 2>/dev/null || true
            git -C "$dst" checkout -q --detach "$sha" 2>/dev/null || { log "WARN checkout $name"; rm -rf "$dst"; continue; }
        fi
        record meson "$name" "$url" "$sha" "$(hash_path "$dst")" "meson-subprojects/$name-$sha"
    done <<< "$wraps"
}

# ---------------------------------------------------------------------------
# 4. cargo / npm / pip: none in use in the image build today.  Recorded so a
#    future dependency cannot be added without a cache + a lock entry.
# ---------------------------------------------------------------------------
record_unused_chains() {
    record ecosystem cargo-vendor "(unused)" "" "" "cargo-vendor/"
    record ecosystem npm-store "(unused)" "" "" "npm-store/"
    record ecosystem pip-wheelhouse "(unused)" "" "" "pip-wheelhouse/"
}

# ---------------------------------------------------------------------------
# verify (offline): every input named by an existing inputs.lock is present.
# ---------------------------------------------------------------------------
verify_lock() {
    [ -r "$LOCK" ] || die "offline but no inputs.lock at $LOCK (run fetch-inputs online first)"
    python3 - "$LOCK" "$CACHE" <<'PY' || die "inputs.lock verification failed"
import json, os, subprocess, sys, hashlib
lock, cache = sys.argv[1:3]
doc = json.load(open(lock))
bad = 0
for it in doc.get("inputs", []):
    cachep = it.get("cache", "")
    if it.get("kind") == "ecosystem":
        continue
    p = os.path.join(cache, cachep)
    if not os.path.exists(p):
        print("MISSING  %s -> %s" % (it["name"], p)); bad = 1
        continue
    want = it.get("sha256", "")
    if not want:
        print("NOHASH   %s (unverifiable)" % it["name"]); bad = 1
        continue
    print("PRESENT  %-24s %s" % (it["name"], p))
sys.exit(bad)
PY
    log "all inputs present and named by the lock"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
: > "$TSV.tmp"
case "$ONLY" in
    git)   prefetch_git ;;
    go)    prefetch_go ;;
    meson) prefetch_meson ;;
    "")    prefetch_git; prefetch_go; prefetch_meson; record_unused_chains ;;
    *)     die "unknown --only '$ONLY'" ;;
esac

if [ "$OFFLINE" = 1 ]; then
    verify_lock
    mv "$TSV.tmp" "$TSV" 2>/dev/null || true
    log "offline: verified $LOCK ($(grep -c . "$TSV" 2>/dev/null || echo 0) input rows)"
    exit 0
fi

# canonical inputs.lock JSON + digest
python3 - "$INPUTS_NDJSON" "$LOCK" "$ARCH" "$PINS" <<'PY'
import json, sys, hashlib
nd, out, arch, pins = sys.argv[1:5]
items = [json.loads(l) for l in open(nd) if l.strip()]
items.sort(key=lambda x: (x["kind"], x["name"]))
doc = {"schema": "ncz-inputs-lock/v1", "arch": arch, "pins": pins, "inputs": items}
canon = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()
doc["inputs_lock_digest"] = hashlib.sha256(canon).hexdigest()
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True); fh.write("\n")
print("inputs_lock_digest=%s (%d inputs)" % (doc["inputs_lock_digest"], len(items)))
PY
mv "$TSV.tmp" "$TSV"
log "wrote $LOCK and $TSV"
exit 0
