#!/bin/bash
# kernel-head-check.sh -- the nightly canary's KERNEL step (cheap: no build).
#
# Nightly: resolve the HEAD of each NCZ kernel tree and run `git apply --check`
# of every carried patch against that HEAD (and the latest stable tag when one is
# given), reporting conflicts -- never a full kernel build.  Weekly: the canary
# runs the real kernel/modules/DKMS builds instead (see build/nightly-canary.sh).
#
# Usage:
#   build/nightly/kernel-head-check.sh --arch amd64|arm64|both --out DIR \
#       [--tree-amd64 DIR] [--tree-arm64 DIR] \
#       [--patches-amd64 DIR] [--patches-arm64 DIR] \
#       [--remote-amd64 URL] [--remote-arm64 URL]
#
# Tree resolution (first that applies):
#   --tree-<arch> DIR, else $NCZ_<ARCH>_KERNEL_TREE, else SKIPPED(reason).
# With a tree: HEAD sha + latest tag + per-patch `git apply --check`.
# Without a tree but with --remote-<arch> URL (or the registry default): resolve
# HEAD sha via `git ls-remote` (no clone) and report patch applicability as
# NOT-CHECKED (needs a tree); a patch check is never faked.
#
# Writes $OUT/kernel-heads.json.  Exit 0 even with conflicts (a red nightly is the
# point: the conflicts are the signal and the caller records them in status.json);
# exit 2 on usage/tooling error.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

ARCH=""; OUT=""
TREE_AMD64="${NCZ_AMD64_KERNEL_TREE:-}"; TREE_ARM64="${NCZ_ARM64_KERNEL_TREE:-}"
PATCHES_AMD64=""; PATCHES_ARM64=""
REMOTE_AMD64="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
REMOTE_ARM64="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
BASE_REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --out) OUT="${2:?}"; shift 2 ;;
        --tree-amd64) TREE_AMD64="${2:?}"; shift 2 ;;
        --tree-arm64) TREE_ARM64="${2:?}"; shift 2 ;;
        --patches-amd64) PATCHES_AMD64="${2:?}"; shift 2 ;;
        --patches-arm64) PATCHES_ARM64="${2:?}"; shift 2 ;;
        --remote-amd64) REMOTE_AMD64="${2:?}"; shift 2 ;;
        --remote-arm64) REMOTE_ARM64="${2:?}"; shift 2 ;;

        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "kernel-head-check: unknown arg: $1" >&2; exit 2 ;;
    esac
done
case "$ARCH" in amd64|arm64|both) ;; *) echo "kernel-head-check: --arch amd64|arm64|both required" >&2; exit 2 ;; esac
[ -n "$OUT" ] || { echo "kernel-head-check: --out required" >&2; exit 2; }
mkdir -p "$OUT"
command -v git >/dev/null 2>&1 || { echo "kernel-head-check: git not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "kernel-head-check: python3 not found" >&2; exit 2; }

# default patch dirs
default_patches() {
    case "$1" in
        amd64) [ -d "$ROOT/assets/kernel/patches" ] && printf '%s\n' "$ROOT/assets/kernel/patches" ;;
        arm64) for d in "$ROOT/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.2/patches-7.2" \
                        "$ROOT/kernel-source/linux-cix-sky1-ncz/linux-cix-sky1-ncz-7.1.1/patches-7.1"; do
                   [ -d "$d" ] && { printf '%s\n' "$d"; break; }
               done ;;
    esac
}
[ -n "$PATCHES_AMD64" ] || PATCHES_AMD64="$(default_patches amd64)"
[ -n "$PATCHES_ARM64" ] || PATCHES_ARM64="$(default_patches arm64)"

check_one() { # arch tree patches remote outfile -> writes a JSON object, echoes status
    local arch="$1" tree="$2" patches="$3" remote="$4" jf="$5"
    local head="" tag="" n=0 ok=0 conflict=0 err=0 status reason=""
    local -a conflicts=()
    if [ -n "$tree" ] && [ -d "$tree/.git" ]; then
        head="$(git -C "$tree" rev-parse HEAD 2>/dev/null || true)"
        tag="$(git -C "$tree" describe --tags --abbrev=0 2>/dev/null || true)"
        if [ -n "$head" ]; then
            # patch applicability is checked against the work tree's HEAD (the
            # caller points --tree-<arch> at a clone already at the ref to test).
            if [ -n "$patches" ] && [ -d "$patches" ]; then
                local p
                while IFS= read -r p; do
                    n=$((n + 1))
                    if git -C "$tree" apply --check --whitespace=nowarn "$p" >/dev/null 2>&1; then
                        ok=$((ok + 1))
                    else
                        conflict=$((conflict + 1)); conflicts+=("$(basename "$p")")
                    fi
                done < <(find "$patches" -maxdepth 1 -type f -name '*.patch' | sort)
                if [ "$conflict" != 0 ]; then status="CONFLICT"; reason="$conflict of $n patch(es) do not apply to $head"
                else status="OK"; reason="$n patch(es) apply cleanly to $head"; fi
            else
                status="OK"; reason="HEAD resolved; no patch dir found ($patches)"
            fi
        else
            status="SKIPPED"; reason="tree $tree is not a readable git work tree"
        fi
    elif [ -n "$remote" ]; then
        head="$(git ls-remote "$remote" HEAD 2>/dev/null | awk '$2=="HEAD"{print $1; exit}')"
        if [ -n "$head" ]; then
            status="HEAD-ONLY"; reason="remote HEAD $head resolved via ls-remote; no local tree so patch applicability NOT checked"
        else
            status="SKIPPED"; reason="could not resolve remote HEAD ($remote)"
        fi
    else
        UACH="$(printf '%s' "$arch" | tr '[:lower:]' '[:upper:]')"
        status="SKIPPED"; reason="no kernel tree (set NCZ_${UACH}_KERNEL_TREE or --tree-$arch) and no remote"
    fi
    local cjson="[]"
    if [ "${#conflicts[@]}" -gt 0 ]; then
        cjson="$(printf '%s\n' "${conflicts[@]}" | python3 -c 'import json,sys;print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    fi
    python3 - "$jf" "$arch" "$tree" "$patches" "$head" "$tag" "$n" "$ok" "$conflict" "$err" "$status" "$reason" "$cjson" <<'PYEOF'
import json, sys
(jf, arch, tree, patches, head, tag, n, ok, conflict, err, status, reason, cjson) = sys.argv[1:14]
obj = {"arch": arch, "tree": tree, "patches_dir": patches, "head": head,
       "latest_tag": tag, "n_patches": int(n), "n_applied": int(ok),
       "n_conflict": int(conflict), "n_error": int(err), "status": status,
       "reason": reason, "conflicts": json.loads(cjson)}
open(jf, "w").write(json.dumps(obj, indent=2, sort_keys=True) + "\n")
PYEOF
    printf '%s\n' "$status"
}

ARGS_ARCH=()
case "$ARCH" in amd64) ARGS_ARCH=(amd64) ;; arm64) ARGS_ARCH=(arm64) ;; both) ARGS_ARCH=(amd64 arm64) ;; esac
STATUSES=""
for a in "${ARGS_ARCH[@]}"; do
    if [ "$a" = amd64 ]; then t="$TREE_AMD64"; p="$PATCHES_AMD64"; r="$REMOTE_AMD64"; else t="$TREE_ARM64"; p="$PATCHES_ARM64"; r="$REMOTE_ARM64"; fi
    s="$(check_one "$a" "$t" "$p" "$r" "$OUT/kernel-head-$a.json")"
    echo "kernel-head-check: $a -> $s"; STATUSES="$STATUSES $a=$s"
done

python3 - "$OUT/kernel-heads.json" "$ARCH" "$OUT" "${ARGS_ARCH[@]}" <<'PYEOF'
import json, os, sys
out, arch, d = sys.argv[1], sys.argv[2], sys.argv[3]
archs = sys.argv[4:]
res = {}
for a in archs:
    p = os.path.join(d, f"kernel-head-{a}.json")
    if os.path.isfile(p):
        res[a] = json.load(open(p))
open(out, "w").write(json.dumps({"arch": arch, "kernels": res}, indent=2, sort_keys=True) + "\n")
PYEOF
echo "kernel-head-check: wrote $OUT/kernel-heads.json ($STATUSES)"
exit 0
