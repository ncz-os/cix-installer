#!/bin/bash
# layers-preflight.sh -- cheap, fail-fast pre-checks for the (long, expensive)
# `layers` stage.  OPERATOR RULING 2026-10-10: "We need to harden the layer
# checks."  Run this at the START of the layers stage, BEFORE any expensive
# work.  It validates everything the layer build needs, reports EVERY finding at
# once (not one by one), and exits non-zero if anything is wrong so the pipeline
# stops before hours of layers/image work.
#
# It shares code with the `provenance-inputs` stage (same tool modes) instead of
# forking the provenance logic: the deb/ledger checks call
# build/check-forky-provenance.sh exactly as that stage does.
#
# Checks (each writes a structured row to the layer-checks TSV):
#   clean-tree        run-owned scratch is fresh/clean; stale singularity trees
#                     or half-checkouts are detected (and moved to quarantine
#                     with --quarantine; never a broad rm)
#   frozen-deb        when a payload deb is handed over (run-metadata/result.env
#                     or env), verify sha256 + arch + version + receipt/ledger
#                     row, and that the layer build will CONSUME it, not rebuild
#   inputs-unique     exactly ONE version of each NCZ/vendor/cix deb per arch, no
#                     wrong-arch deb, every staged deb ledger-authorized with a
#                     matching sha256
#   resources         >= NCZ_LAYERS_MIN_FREE_GB free (default 60) on the build fs,
#                     not a tmpfs, tool presence, kernel-staging mount, usable
#                     privilege model, no other build holding the lock, SDE set
#   pins              base.pin / determinism.pin / run.pin agree and are fresh;
#                     the layer fingerprints are RECOMPUTED (never trusted)
#
# Exit: 0 all PASS (WARN allowed unless --strict), 1 any FAIL, 2 usage.
#
# Usage:
#   build/layers-preflight.sh --arch amd64 --run-dir DIR [options]
# Options:
#   --root DIR            repo root (default: parent of this script)
#   --layers-dir DIR      squashfs output dir (default $root/assets/squashfs)
#   --checks-out FILE     layer-checks TSV (default $RUN_DIR/layer-checks.tsv,
#                         else stdout)
#   --payload-deb FILE    explicit frozen payload deb (else env / result.env)
#   --no-payload          the mode does not need a payload deb (server/only-image)
#   --quarantine          move detected stale run-owned scratch to $RUN_DIR/quarantine
#   --strict              treat WARN as FAIL
#   --json                also print a JSON summary
set -uo pipefail
export LC_ALL=C

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/build/lib/priv.sh"
# shellcheck source=/dev/null
. "$ROOT/build/lib/reproducible.sh"

ARCH=""
RUN_DIR="${RUN_DIR:-}"
LAYERS_DIR=""
CHECKS_OUT=""
PAYLOAD_DEB=""
NEED_PAYLOAD=1
QUARANTINE=0
STRICT=0
JSON=0
FREE_GB_MIN="${NCZ_LAYERS_MIN_FREE_GB:-60}"
LOCK_FILE="${NCZ_BUILD_LOCK:-}"
LOCK_OWNER="${NCZ_BUILD_LOCK_OWNER:-}"
DRY_DF=""
DEB_DIRS=()
SCRATCH_ROOTS=()      # override the run-owned scratch roots (tests)
PROV_CHECK=""         # override build/check-forky-provenance.sh (tests)
PROV_INDEX=""         # override the provenance index dir (tests)

usage() {
    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)        ARCH="${2:-}"; shift 2 ;;
        --root)        ROOT="${2:-}"; shift 2 ;;
        --run-dir)     RUN_DIR="${2:-}"; shift 2 ;;
        --layers-dir)  LAYERS_DIR="${2:-}"; shift 2 ;;
        --checks-out)  CHECKS_OUT="${2:-}"; shift 2 ;;
        --payload-deb) PAYLOAD_DEB="${2:-}"; shift 2 ;;
        --no-payload)  NEED_PAYLOAD=0; shift ;;
        --quarantine)  QUARANTINE=1; shift ;;
        --strict)      STRICT=1; shift ;;
        --json)        JSON=1; shift ;;
        --lock-file)   LOCK_FILE="${2:-}"; shift 2 ;;
        --lock-owner)  LOCK_OWNER="${2:-}"; shift 2 ;;
        --df-fixture)  DRY_DF="${2:-}"; shift 2 ;;   # test hook: file with `df -Pk` output
        --deb-dir)     DEB_DIRS+=("${2:-}"); shift 2 ;;      # override scanned deb dirs (tests)
        --scratch)     SCRATCH_ROOTS+=("${2:-}"); shift 2 ;;  # override scratch roots (tests)
        --prov-check)  PROV_CHECK="${2:-}"; shift 2 ;;        # override the provenance tool (tests)
        --prov-index)  PROV_INDEX="${2:-}"; shift 2 ;;        # override the provenance index (tests)
        -h|--help)     usage 0 ;;
        *) echo "layers-preflight.sh: unknown arg '$1'" >&2; usage 2 ;;
    esac
done

[ -n "$ARCH" ] || { echo "layers-preflight.sh: --arch is required" >&2; usage 2; }
case "$ARCH" in amd64|arm64) ;; *) echo "layers-preflight.sh: bad arch '$ARCH'" >&2; exit 2 ;; esac

ncz_repro_init "$ROOT" || exit 2
[ -n "$LAYERS_DIR" ] || LAYERS_DIR="$ROOT/assets/squashfs"
[ -n "$RUN_DIR" ] || RUN_DIR="${RUN_DIR:-}"
[ -n "$CHECKS_OUT" ] || CHECKS_OUT="${RUN_DIR:+$RUN_DIR/layer-checks.tsv}"

# ---------------------------------------------------------------------------
# check recorder
# ---------------------------------------------------------------------------
FAILS=0
WARNS=0
_fail() { FAILS=$((FAILS+1)); }
_warn() { WARNS=$((WARNS+1)); }
_rec() {  # check result evidence
    local check="$1" result="$2" ev="$3"
    local line="layers-preflight\t-\t${check}\t${result}\t${ev}"
    if [ -n "$CHECKS_OUT" ]; then
        printf '%b\n' "$line" >> "$CHECKS_OUT"
        _last_row="$line"
    else
        printf '%b\n' "$line"
    fi
    case "$result" in
        FAIL) _fail ;;
        WARN) _warn ;;
    esac
}
ok()   { _rec "$1" PASS "$2"; printf '[layers-preflight] OK   %-16s %s\n' "$1" "$2"; }
bad()  { _rec "$1" FAIL "$2"; printf '[layers-preflight] FAIL %-16s %s\n' "$1" "$2" >&2; }
warn() { _rec "$1" WARN "$2"; printf '[layers-preflight] WARN %-16s %s\n' "$1" "$2" >&2; }

# helper: sha256 of a file (portable)
_sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Is pid $1 an ancestor of this process (i.e. our own build tree)?
_is_ancestor() {
    local want="$1" p=$$ pp
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        [ "$p" = "$want" ] && return 0
        pp="$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | awk '{print $2}')"
        [ -z "$pp" ] && break
        p="$pp"
    done
    return 1
}
# helper: dpkg-deb field
_dfield() { dpkg-deb -f "$1" "$2" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# 1. clean-tree
# ---------------------------------------------------------------------------
# Run-owned scratch roots.  Only these exact subtrees are inspected; a finding
# is a stale singularity checkout / half-built tree / partial temp under them.
# Nothing outside them is ever touched (never a broad rm).
check_clean_tree() {
    local problems=() roots=()
    if [ "${#SCRATCH_ROOTS[@]}" -gt 0 ]; then
        roots=("${SCRATCH_ROOTS[@]}")
    else
        [ -n "$RUN_DIR" ] && roots+=("$RUN_DIR/tmp" "$RUN_DIR/singularity-sources/out")
        roots+=("$ROOT/build/sinty-out" "$ROOT/build/.ncz-tmp")
    fi
    local r
    for r in "${roots[@]}"; do
        [ -d "$r" ] || continue
        # a stray git checkout / subprojects tree / partial temp under run scratch
        while IFS= read -r d; do
            [ -n "$d" ] && problems+=("$d")
        done < <(find "$r" -maxdepth 3 \( -name .git -o -name subprojects \) -print 2>/dev/null \
                 | sed -e 's#/.git$##' -e 's#/subprojects$##' | sort -u)
        # half-written temp files from an interrupted prebuilt repack
        while IFS= read -r f; do
            [ -n "$f" ] && problems+=("$f")
        done < <(find "$r" -maxdepth 2 -name '.singularity-opt.tgz.*' -type f -print 2>/dev/null)
        # a stale singularity-desktop tree anywhere under run scratch
        while IFS= read -r d; do
            [ -n "$d" ] && problems+=("$d")
        done < <(find "$r" -maxdepth 2 -type d -name 'singularity-desktop' -print 2>/dev/null)
    done
    # de-dup
    if [ "${#problems[@]}" -gt 0 ]; then
        local uniq; uniq="$(printf '%s\n' "${problems[@]}" | sort -u)"
        if [ "$QUARANTINE" = 1 ] && [ -n "$RUN_DIR" ]; then
            local qdir="$RUN_DIR/quarantine/$(date -u +%Y%m%d-%H%M%S)"
            mkdir -p "$qdir"
            local p
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                local dest="$qdir/$(printf '%s' "$p" | tr '/' '_')"
                if mv -f "$p" "$dest" 2>/dev/null; then
                    printf '[layers-preflight] quarantined %s -> %s\n' "$p" "$dest"
                else
                    bad clean-tree "could not quarantine leftover: $p"
                fi
            done <<< "$uniq"
            ok clean-tree "quarantined $(printf '%s\n' "$uniq" | wc -l | tr -d ' ') stale run-owned path(s) -> $qdir"
        else
            bad clean-tree "stale run-owned scratch from an earlier run: $(printf '%s' "$uniq" | tr '\n' ' ')"
        fi
        return
    fi
    ok clean-tree "no stale singularity trees / partial checkouts under run scratch"
}

# ---------------------------------------------------------------------------
# 2. frozen-deb handshake
# ---------------------------------------------------------------------------
# Resolve the frozen payload deb: explicit flag > env > result.env.
resolve_payload_deb() {
    if [ -n "$PAYLOAD_DEB" ]; then return 0; fi
    if [ -n "${NCZ_SINGULARITY_PREBUILT_DEB:-}" ]; then PAYLOAD_DEB="$NCZ_SINGULARITY_PREBUILT_DEB"; return 0; fi
    local envf="$RUN_DIR/singularity-sources/result.env"
    if [ -n "$RUN_DIR" ] && [ -f "$envf" ]; then
        PAYLOAD_DEB="$(sed -n 's/^NCZ_SINGULARITY_PREBUILT_DEB=//p' "$envf" | tail -1)"
        [ -n "${NCZ_SINGULARITY_PREBUILT_SHA256:-}" ] || \
            NCZ_SINGULARITY_PREBUILT_SHA256="$(sed -n 's/^NCZ_SINGULARITY_PREBUILT_SHA256=//p' "$envf" | tail -1)"
    fi
    [ -n "$PAYLOAD_DEB" ]
}

check_frozen_deb() {
    if [ "$NEED_PAYLOAD" = 0 ]; then
        ok frozen-deb "mode does not require a payload deb (--no-payload)"
        return
    fi
    if ! resolve_payload_deb; then
        bad frozen-deb "no frozen payload deb (refresh-sources produced none and none was passed); the layers stage would have to REBUILD singularity -- refusing"
        return
    fi
    if [ ! -s "$PAYLOAD_DEB" ]; then
        bad frozen-deb "payload deb missing/empty: $PAYLOAD_DEB"
        return
    fi
    local got want; got="$(_sha "$PAYLOAD_DEB")"
    want="${NCZ_SINGULARITY_PREBUILT_SHA256:-}"
    if [ -z "$want" ]; then
        # fall back to the receipt / result.env
        local envf="$RUN_DIR/singularity-sources/result.env"
        [ -n "$RUN_DIR" ] && [ -f "$envf" ] && want="$(sed -n 's/^NCZ_SINGULARITY_PREBUILT_SHA256=//p' "$envf" | tail -1)"
    fi
    if [ -z "$want" ]; then
        bad frozen-deb "payload deb has no recorded sha256 (result.env/receipt); cannot prove the layer build consumes THESE bytes"
        return
    fi
    if [ "$got" != "$want" ]; then
        bad frozen-deb "payload deb sha256 mismatch (got $got want $want) -- the layers stage must consume the refresh-sources artifact"
        return
    fi
    # arch + version + receipt/ledger row
    local darch dver dname rec
    darch="$(_dfield "$PAYLOAD_DEB" Architecture)"
    dname="$(_dfield "$PAYLOAD_DEB" Package)"
    dver="$(_dfield "$PAYLOAD_DEB" Version)"
    case "$darch" in
        "$ARCH"|all) : ;;
        *) bad frozen-deb "payload deb arch '$darch' != target '$ARCH' ($PAYLOAD_DEB)"; return ;;
    esac
    [ -n "$dname" ] && [ -n "$dver" ] || { bad frozen-deb "payload deb has empty Package/Version field"; return; }
    # authorize via the pre-build receipt (same shape as provenance-inputs)
    local recf="$RUN_DIR/singularity-sources/payload-receipt.json"
    if [ -n "$RUN_DIR" ] && [ -f "$recf" ]; then
        if python3 -I - "$recf" "$dname" "$dver" "$darch" "$got" <<'PYEOF'
import json, sys
rec, name, ver, arch, sha = sys.argv[1:6]
try:
    d = json.load(open(rec))
except Exception:
    sys.exit(2)
for row in d.get("ncz_timestamped_debs", []):
    if row.get("name") == name and row.get("version") == ver and row.get("sha256") == sha:
        sys.exit(0)
sys.exit(1)
PYEOF
        then
            ok frozen-deb "payload deb $(basename "$PAYLOAD_DEB") sha256=$got arch=$darch ver=$dver authorized by receipt"
        else
            bad frozen-deb "payload deb $(basename "$PAYLOAD_DEB") is not in the pre-build receipt (name=$dname ver=$dver sha=$got)"
        fi
    else
        warn frozen-deb "no pre-build receipt; payload deb sha/arch/version verified but not ledger-authorized ($PAYLOAD_DEB)"
    fi
    # assert the layer build will CONSUME it (env must reach build-squashfs-layers.sh)
    if [ "${NCZ_LAYERS_WILL_REBUILD_PAYLOAD:-0}" = 1 ]; then
        bad frozen-deb "the layer build is configured to rebuild the payload (NCZ_SINGULARITY_PREBUILT_DEB not exported into the layers env)"
    fi
}

# ---------------------------------------------------------------------------
# 3. no stale/duplicate inputs (shared with provenance-inputs)
# ---------------------------------------------------------------------------
check_inputs_unique() {
    local dirs=() d
    if [ "${#DEB_DIRS[@]}" -gt 0 ]; then
        dirs=("${DEB_DIRS[@]}")
    else
        for d in "$ROOT/assets/cix-debs" "$ROOT/assets/vendor-debs" "$ROOT/assets/ncz-debs" \
                 "$ROOT/downloads/vendor-debs"; do
            [ -d "$d" ] && dirs+=("$d")
        done
    fi
    if [ "${#dirs[@]}" = 0 ]; then
        bad inputs-unique "no staged deb directory (assets/cix-debs, assets/{vendor,ncz}-debs, downloads/vendor-debs)"
        return
    fi
    local dargs=() any=0
    for d in "${dirs[@]}"; do
        # NB: `ls "$d"/*.deb "$d"/*.udeb` fails when EITHER glob is empty, which
        # would silently skip a dir that has only .deb (a real bug); test each.
        ls "$d"/*.deb >/dev/null 2>&1 || ls "$d"/*.udeb >/dev/null 2>&1 || continue
        any=1; dargs+=(--debs "$d")
    done
    if [ "$any" = 0 ]; then
        bad inputs-unique "staged deb directories exist but contain no .deb/.udeb"
        return
    fi

    # (a) exactly one version of each package name per arch; no wrong-arch deb
    local dup=0 wrong=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        local a; a="$(_dfield "$f" Architecture)"
        case "$a" in
            "$ARCH"|all) : ;;
            *) wrong=1; printf '[layers-preflight]   wrong-arch deb: %s (Architecture=%s, target=%s)\n' "$f" "${a:-?}" "$ARCH" >&2 ;;
        esac
    done < <(printf '%s\n' "${dirs[@]}" | while read -r dd; do ls "$dd"/*.deb "$dd"/*.udeb 2>/dev/null; done)
    # duplicate (name,arch) with >1 version
    local dups
    dups="$(printf '%s\n' "${dirs[@]}" | while read -r dd; do ls "$dd"/*.deb 2>/dev/null; done | \
        while read -r f; do [ -n "$f" ] || continue; printf '%s\t%s\n' "$(_dfield "$f" Package)" "$f"; done | \
        sort | awk -F'\t' '{n[$1]=n[$1]" "$2; c[$1]++} END{for(k in c) if(c[k]>1) print k": "n[k]}')"
    if [ -n "$dups" ]; then
        dup=1
        printf '[layers-preflight]   duplicate package versions:\n%s\n' "$dups" >&2
    fi
    if [ "$wrong" = 1 ]; then
        bad inputs-unique "a staged deb has Architecture != $ARCH (see list)"
    elif [ "$dup" = 1 ]; then
        bad inputs-unique "more than one version of a staged package in the same arch (see list)"
    else
        ok inputs-unique "one version per staged package, all matching arch $ARCH"
    fi

    # (b) every staged deb ledger-authorized with a matching sha256 (shared tool)
    local receipt="" idx
    idx="${PROV_INDEX:-${NCZ_LAYERS_INDEX_DIR:-${RUN_DIR:+$RUN_DIR/prov-input-index}}}"
    [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/singularity-sources/payload-receipt.json" ] && \
        receipt="$RUN_DIR/singularity-sources/payload-receipt.json"
    [ -n "$idx" ] && mkdir -p "$idx"
    local prov="${PROV_CHECK:-$ROOT/build/check-forky-provenance.sh}"
    local -a rargs=() fargs=()
    [ -n "$receipt" ] && rargs=(--receipt "$receipt")
    [ -n "$idx" ] && fargs=(--index-dir "$idx")
    local provlog="${RUN_DIR:+$RUN_DIR/layers-preflight-provenance.log}"; provlog="${provlog:-/dev/null}"
    if [ ! -x "$prov" ] && [ ! -f "$prov" ]; then
        warn inputs-ledger "provenance tool absent ($prov); cannot ledger-authorize the staged debs"
        return
    fi
    if ( cd "$ROOT" && bash "$prov" "${dargs[@]}" "${rargs[@]}" "${fargs[@]}" ) >>"$provlog" 2>&1; then
        ok inputs-ledger "every staged deb is ledger/receipt-authorized with a matching sha256"
    else
        bad inputs-ledger "a staged deb is not ledger-authorized (see $(basename "$provlog"))"
    fi
}

# ---------------------------------------------------------------------------
# 4. resources / placement
# ---------------------------------------------------------------------------
check_resources() {
    # disk free on the run dir's filesystem (or ROOT if no run dir)
    local probe="${RUN_DIR:-$ROOT}"
    local free_kb
    if [ -n "$DRY_DF" ] && [ -f "$DRY_DF" ]; then
        free_kb="$(awk 'NR==2{print $4}' "$DRY_DF")"
    else
        free_kb="$(df -Pk "$probe" 2>/dev/null | awk 'NR==2{print $4}')"
    fi
    local need_kb=$(( FREE_GB_MIN * 1024 * 1024 ))
    if [ -z "$free_kb" ]; then
        warn resources "could not measure free space for $probe"
    elif [ "$free_kb" -lt "$need_kb" ]; then
        bad resources "only $(( free_kb / 1024 / 1024 )) GiB free at $probe (< ${FREE_GB_MIN} GiB required)"
    else
        ok resources "$(( free_kb / 1024 / 1024 )) GiB free at $probe (>= ${FREE_GB_MIN} GiB)"
    fi

    # not a tmpfs
    if command -v findmnt >/dev/null 2>&1; then
        local fst; fst="$(findmnt -no FSTYPE -T "$probe" 2>/dev/null || true)"
        if [ "$fst" = tmpfs ] || [ "$fst" = ramfs ]; then
            bad resources "build scratch is on a $fst (must be a real disk): $probe"
        else
            ok resources "run dir fs=$fst (not tmpfs)"
        fi
    else
        warn resources "findmnt unavailable; could not confirm the run dir is not a tmpfs"
    fi

    # toolchain presence
    local missing=() t
    for t in mksquashfs unsquashfs python3 dpkg-deb; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    # one of debootstrap/mmdebstrap
    command -v debootstrap >/dev/null 2>&1 || command -v mmdebstrap >/dev/null 2>&1 || missing+=("debootstrap|mmdebstrap")
    command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || missing+=("podman|docker")
    command -v qemu-img >/dev/null 2>&1 || missing+=("qemu-img")
    if [ "${#missing[@]}" -gt 0 ]; then
        bad resources "missing required tools: ${missing[*]}"
    else
        ok resources "toolchain present (mksquashfs unsquashfs debootstrap/mmdebstrap podman qemu-img)"
    fi

    # kernel staging visible (only enforced when the symlink exists in the tree)
    if [ -L "$ROOT/assets/kernel/mainline" ] || [ -d "$ROOT/assets/kernel/mainline" ]; then
        if [ -d "$ROOT/assets/kernel/mainline" ]; then
            ok resources "kernel staging visible: $ROOT/assets/kernel/mainline"
        else
            bad resources "kernel staging symlink is dangling: $ROOT/assets/kernel/mainline"
        fi
    else
        warn resources "assets/kernel/mainline absent; skipping kernel-staging mount check"
    fi

    # privilege model usable
    local pm; pm="$(ncz_priv_model 2>/dev/null || echo none)"
    if [ "$pm" = none ]; then
        bad resources "no usable privilege model (need root, passwordless sudo, or NCZ_SUDO_PASS_FILE)"
    else
        ok resources "privilege model: $pm"
    fi

    # no OTHER build holding the lock (our own build's lock is expected here)
    if [ -n "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ]; then
        local holder; holder="$(cat "$LOCK_FILE" 2>/dev/null | tr -dc '0-9' | head -c 12)"
        if [ -z "$holder" ]; then
            ok resources "build lock present but empty/stale"
        elif [ "$holder" = "$$" ] || { [ -n "$LOCK_OWNER" ] && [ "$holder" = "$LOCK_OWNER" ]; } || _is_ancestor "$holder"; then
            ok resources "this build holds the lock (pid $holder)"
        elif kill -0 "$holder" 2>/dev/null; then
            bad resources "another build holds the lock ($LOCK_FILE, pid $holder)"
        else
            ok resources "build lock present but stale (pid $holder not alive)"
        fi
    else
        ok resources "no other build holding the lock"
    fi

    # SOURCE_DATE_EPOCH set + usable
    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        ok resources "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    else
        bad resources "SOURCE_DATE_EPOCH is not set (the determinism contract requires it)"
    fi
}

# ---------------------------------------------------------------------------
# 5. pin consistency (fingerprints recomputed, never trusted)
# ---------------------------------------------------------------------------
check_pins() {
    # base.pin freshness/coverage
    if [ -x "$ROOT/build/check-substrate-pin.sh" ]; then
        if bash "$ROOT/build/check-substrate-pin.sh" "$ARCH" >>"${RUN_DIR:+$RUN_DIR/layers-preflight-pins.log}" 2>&1; then
            ok pins "base.pin fresh + snapshot coverage OK ($ARCH)"
        else
            bad pins "base.pin stale or snapshot coverage < required; run build/refresh-substrate.sh --arch $ARCH"
        fi
    fi
    # determinism.pin freshness
    if [ -x "$ROOT/build/gen-base-pin.sh" ]; then
        if bash "$ROOT/build/gen-base-pin.sh" --check >>"${RUN_DIR:+$RUN_DIR/layers-preflight-pins.log}" 2>&1; then
            ok pins "determinism.pin matches the authoritative pins"
        else
            bad pins "manifests/determinism.pin is stale; run build/gen-base-pin.sh and commit it"
        fi
    fi
    # run.pin agrees with the live pin files + git HEAD
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.pin" ]; then
        local want now
        want="$(ncz_pin_digest 2>/dev/null || true)"
        # run.pin records substrate/kver; the digest seeds from base.pin
        local r_arch r_sub r_kver
        r_arch="$(awk -F'\t' '$1=="arch"{print $2}' "$RUN_DIR/run.pin" | head -1)"
        r_sub="$(awk -F'\t' '$1=="substrate_sha256"{print $2}' "$RUN_DIR/run.pin" | head -1)"
        r_kver="$(awk -F'\t' '$1=="kernel_kver"{print $2}' "$RUN_DIR/run.pin" | head -1)"
        local b_sub now_kver
        b_sub="$(awk -F'\t' -v a="$ARCH" '$1==a{print $2}' "$ROOT/manifests/base.pin" | head -1)"
        now_kver="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/KVER" 2>/dev/null || true)"
        [ -n "$now_kver" ] || now_kver="$(tr -d '[:space:]' < "$ROOT/assets/kernel/mainline/KVER" 2>/dev/null || true)"
        local pin_ok=1
        [ -z "$r_arch" ] || [ "$r_arch" = "$ARCH" ] || { pin_ok=0; printf '[layers-preflight]   run.pin arch %s != %s\n' "$r_arch" "$ARCH" >&2; }
        [ -z "$r_sub" ] || [ -z "$b_sub" ] || [ "$r_sub" = "$b_sub" ] || { pin_ok=0; printf '[layers-preflight]   run.pin substrate != base.pin\n' >&2; }
        [ -z "$r_kver" ] || [ -z "$now_kver" ] || [ "$r_kver" = "$now_kver" ] || { pin_ok=0; printf '[layers-preflight]   run.pin kver %s != %s\n' "$r_kver" "$now_kver" >&2; }
        if [ "$pin_ok" = 1 ]; then ok pins "run.pin agrees with base.pin/kernel assets"; else bad pins "run.pin is inconsistent with the live pins"; fi
    fi
    # recompute layer fingerprints (never trust a stale stamp)
    if [ -f "$ROOT/build/lib/layerplan.py" ]; then
        local m; m="$( [ -n "${NCZ_LAYER_PLAN:-}" ] && echo "" || echo full )"
        if python3 -I "$ROOT/build/lib/layerplan.py" plan --arch "$ARCH" --mode "${SCOPE:-full}" \
             --components "${COMPONENTS:-}" --layers-dir "$LAYERS_DIR" --root "$ROOT" \
             --pin "$NCZ_PIN_FILE" >/dev/null 2>&1; then
            ok pins "layer fingerprints recomputed for $ARCH (plan)"
        else
            bad pins "layerplan could not recompute fingerprints (bad pin input?)"
        fi
    fi
}

main() {
    if [ -n "$CHECKS_OUT" ]; then
        : > "$CHECKS_OUT"
    fi
    printf '[layers-preflight] arch=%s root=%s run=%s\n' "$ARCH" "$ROOT" "${RUN_DIR:-<none>}"
    check_clean_tree
    check_frozen_deb
    check_inputs_unique
    check_resources
    check_pins
    printf '[layers-preflight] %s: fails=%d warns=%d\n' \
        "$([ "$FAILS" = 0 ] && echo PASS || echo FAIL)" "$FAILS" "$WARNS"
    if [ -n "$RUN_DIR" ]; then
        if [ "$FAILS" = 0 ] && { [ "$STRICT" != 1 ] || [ "$WARNS" = 0 ]; }; then
            printf 'gate=layers-preflight\nresult=PASS\narch=%s\nat=%s\n' "$ARCH" "$(date -u +%s)" \
                > "$RUN_DIR/layers-preflight.result"
        else
            printf 'gate=layers-preflight\nresult=FAIL\narch=%s\nat=%s\nfails=%s\n' "$ARCH" "$(date -u +%s)" "$FAILS" \
                > "$RUN_DIR/layers-preflight.result"
        fi
    fi
    if [ "$JSON" = 1 ]; then
        printf '{"stage":"layers-preflight","arch":"%s","fails":%d,"warns":%d,"result":"%s"}\n' \
            "$ARCH" "$FAILS" "$WARNS" "$([ "$FAILS" = 0 ] && echo PASS || echo FAIL)"
    fi
    local rc=0
    [ "$FAILS" != 0 ] && rc=1
    [ "$STRICT" = 1 ] && [ "$WARNS" != 0 ] && rc=1
    return "$rc"
}

main
