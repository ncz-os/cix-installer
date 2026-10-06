#!/bin/bash
# singularity-pins.sh -- the one reader of assets/singularity/upstream-pins.tsv.
#
# WHY (2026-10-06): the Singularity payload used to be built from the
# superproject's master head with every submodule re-pinned to its tracked
# branch head, on every stage-1 run. Upstream pushed a feature drop at
# 15:01Z that day (libsingularity f3d0f49, singularity-shell 1da3224, ...) and
# stage 1 broke within the hour: libsingularity/0001 and singularity-shell/
# 0002+0003 (and singularity-session/0002, which the old preflight never
# checked) no longer applied. The r199 images had been built from the same
# scripts six hours earlier. A build whose inputs move under it cannot be
# respun. Every upstream repository the payload build clones is now pinned
# to an exact commit, and nothing falls back to a branch head.
#
# Usage: build/singularity-pins.sh <command> [args]
#   validate              offline: the pin file is well formed, names the
#                         superproject, vetro and the boot splash, and every
#                         patch directory has a pinned repository
#   sha <path>            print the pinned commit for <path> (or fail)
#   url <path>            print the pinned clone URL for <path> (or fail)
#   clone <path> <dest>   clone <path>'s repository at its pinned commit
#                         (submodules initialised from that commit's gitlinks)
#   checkout-tree <dir>   in a superproject clone: require HEAD == the "."
#                         pin, require a pin for every .gitmodules path (and
#                         no pin for a path .gitmodules lacks), check every
#                         submodule out at its pin, then print the provenance
#   provenance <dir> [vetro-dir] [boot-splash-dir]
#                         print "<path> <commit>" for every checked-out repo
#   check-patches         apply each assets/singularity/patches/<sub>/ queue,
#                         in order, to <sub>'s pinned commit (singularity-
#                         loginui also to the boot splash's bundled copy).
#                         Uses the bare mirrors in the pin cache first, then
#                         the network. Exit 0 all apply, 1 a patch does not
#                         apply or a pinned commit does not exist, 2 nothing
#                         failed but something could not be checked (offline
#                         and not cached)
#   fetch-cache           mirror every pinned repository into the pin cache
#                         so check-patches works offline
#   propose               print the CURRENT upstream heads as pin rows (for a
#                         deliberate bump; writes nothing)
#
# Environment:
#   NCZ_SINGULARITY_PINS       pin file (default assets/singularity/upstream-pins.tsv)
#   NCZ_SINGULARITY_PATCHES    patch root (default assets/singularity/patches)
#   NCZ_SINGULARITY_PIN_CACHE  bare-mirror cache (default build/.singularity-pin-cache)
#   NCZ_SINGULARITY_GIT_TIMEOUT  seconds per network git operation (default 120)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
PINS="${NCZ_SINGULARITY_PINS:-$REPO_ROOT/assets/singularity/upstream-pins.tsv}"
PATCH_ROOT="${NCZ_SINGULARITY_PATCHES:-$REPO_ROOT/assets/singularity/patches}"
CACHE="${NCZ_SINGULARITY_PIN_CACHE:-$REPO_ROOT/build/.singularity-pin-cache}"
GIT_TIMEOUT="${NCZ_SINGULARITY_GIT_TIMEOUT:-120}"
REQUIRED_PATHS=". vetro singularity-boot-splash"

die() { echo "ERROR: $*" >&2; exit 1; }

# Rows as "path<TAB>url<TAB>branch<TAB>sha", comments and blanks dropped.
rows() {
    [ -r "$PINS" ] || die "Singularity upstream pin file not found: $PINS
       Every upstream repository the payload build clones must be pinned there
       (build/singularity-pins.sh propose prints rows for the current heads)."
    grep -vE '^[[:space:]]*(#|$)' "$PINS"
}

field() {  # field <path> <column 2..4>
    local want="$1" col="$2"
    rows | awk -F'\t' -v p="$want" -v c="$col" '$1 == p { print $c; found=1 } END { exit !found }'
}

pin_sha() {
    local s
    s="$(field "$1" 4)" || die "no upstream pin for '$1' in $PINS
       Add a row: $1<TAB><clone url><TAB><branch or -><TAB><40-hex commit>
       (build/singularity-pins.sh propose prints the current upstream heads)."
    echo "$s"
}

pin_url() {
    local u
    u="$(field "$1" 2)" || die "no upstream pin for '$1' in $PINS"
    echo "$u"
}

# Patch directory name -> pinned path. The root repo's own queue applies at
# the top level ("."), matching build-singularity.sh.
patch_dir_path() {
    if [ "$1" = singularity-desktop ]; then echo "."; else echo "subprojects/$1"; fi
}

cmd_validate() {
    local bad=0 line n path url branch sha seen=""
    while IFS= read -r line; do
        n="$(printf '%s\n' "$line" | awk -F'\t' '{print NF}')"
        IFS=$'\t' read -r path url branch sha <<<"$line"
        if [ "$n" != 4 ]; then
            echo "ERROR: $PINS: row has $n TAB-separated fields, want 4: $line" >&2
            bad=1; continue
        fi
        if ! grep -qE '^[0-9a-f]{40}$' <<<"$sha"; then
            echo "ERROR: $PINS: '$path' pin '$sha' is not a full 40-hex commit" >&2
            bad=1
        fi
        case "$url" in
            https://*|http://*|git://*|ssh://*|file://*|/*) ;;
            *) echo "ERROR: $PINS: '$path' url '$url' is not a clone URL" >&2; bad=1 ;;
        esac
        [ -n "$branch" ] || { echo "ERROR: $PINS: '$path' has an empty branch column (use - for none)" >&2; bad=1; }
        case "$path" in
            *[[:space:]]*|"") echo "ERROR: $PINS: path '$path' is empty or contains whitespace" >&2; bad=1 ;;
        esac
        case " $seen " in
            *" $path "*) echo "ERROR: $PINS: '$path' is pinned twice" >&2; bad=1 ;;
        esac
        seen="$seen $path"
    done < <(rows)
    for path in $REQUIRED_PATHS; do
        case " $seen " in
            *" $path "*) ;;
            *) echo "ERROR: $PINS: no upstream pin for '$path' (build-singularity.sh clones it)" >&2; bad=1 ;;
        esac
    done
    local d sub
    if [ -d "$PATCH_ROOT" ]; then
        for d in "$PATCH_ROOT"/*/; do
            [ -d "$d" ] || continue
            ls "$d"*.patch >/dev/null 2>&1 || continue
            sub="$(basename "$d")"
            path="$(patch_dir_path "$sub")"
            case " $seen " in
                *" $path "*) ;;
                *) echo "ERROR: patches exist for '$sub' but $PINS has no upstream pin for '$path'" >&2; bad=1 ;;
            esac
        done
    fi
    [ "$bad" = 0 ] || return 1
    echo "[pins] OK: $(rows | wc -l | tr -d ' ') upstream pins in $(basename "$PINS") are well formed and cover every patch queue"
}

# git with a wall-clock bound: a network fetch that hangs must not stall a
# build for an hour (preflight-freshness-gate.sh check [1] has the incident).
tgit() { timeout "$GIT_TIMEOUT" git "$@"; }

# Make <sha> present in repository <dir>, fetching from <url> only if needed.
ensure_commit() {
    local dir="$1" url="$2" sha="$3"
    git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null && return 0
    tgit -C "$dir" fetch -q --depth 1 "$url" "$sha" 2>/dev/null \
        || tgit -C "$dir" fetch -q "$url" "$sha" 2>/dev/null \
        || tgit -C "$dir" fetch -q --tags "$url" '+refs/heads/*:refs/ncz-pin/*' 2>/dev/null \
        || true
    git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null
}

cmd_clone() {
    local path="$1" dest="$2" sha url
    sha="$(pin_sha "$path")" || exit 1
    url="${NCZ_SINGULARITY_URL_OVERRIDE:-$(pin_url "$path")}" || exit 1
    [ ! -e "$dest" ] || die "clone destination already exists: $dest"
    git init -q "$dest" || die "git init $dest failed"
    git -C "$dest" remote add origin "$url" || die "cannot add remote $url in $dest"
    ensure_commit "$dest" "$url" "$sha" \
        || die "pinned upstream commit $sha for '$path' was not found at $url
       (force-pushed away, wrong URL, or no network). Fix the pin in $PINS."
    git -C "$dest" checkout -q --detach "$sha" || die "checkout $sha in $dest failed"
    if [ -f "$dest/.gitmodules" ] && [ "$path" != . ]; then
        tgit -C "$dest" submodule update -q --init --recursive \
            || die "submodules of '$path' at $sha could not be initialised"
    fi
    echo "    pinned clone: $path @ $sha"
}

cmd_checkout_tree() {
    local dir="$1" top sha want subs p url branch gitlink bad=0
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || die "$dir is not a git checkout"
    want="$(pin_sha .)" || exit 1
    top="$(git -C "$dir" rev-parse HEAD)" || die "cannot read HEAD of $dir"
    [ "$top" = "$want" ] || die "superproject $dir is at $top but the pin for '.' is $want"
    subs="$(git -C "$dir" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')"
    # Paths are word-split below; upstream has never used whitespace in one,
    # and a path that has some must stop the build rather than mis-split.
    if git -C "$dir" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk 'NF != 2 { bad=1 } END { exit !bad }'; then
        die "singularity-desktop $top has a submodule path containing whitespace; singularity-pins.sh cannot pin it"
    fi
    # Coverage, both ways, before touching anything.
    for p in $subs; do
        field "$p" 4 >/dev/null || {
            echo "ERROR: upstream pin missing: '$p' is a submodule of singularity-desktop $top" >&2
            echo "       ($(git -C "$dir" config -f .gitmodules --get "submodule.$p.url" 2>/dev/null || true)) but $PINS has no row for it." >&2
            echo "       Pin it (build/singularity-pins.sh propose), check the patches, then rebuild." >&2
            bad=1
        }
    done
    while IFS=$'\t' read -r p _ _ _; do
        case "$p" in subprojects/*) ;; *) continue ;; esac
        # Here-string, not a pipe: under pipefail a grep -q that exits early
        # can SIGPIPE the producer and report a false "stale pin".
        grep -qxF "$p" <<<"$subs" || {
            echo "ERROR: $PINS pins '$p' but singularity-desktop $top has no such submodule (stale pin)" >&2
            bad=1
        }
    done < <(rows)
    [ "$bad" = 0 ] || exit 1
    for p in $subs; do
        sha="$(pin_sha "$p")"
        url="$(pin_url "$p")"
        branch="$(field "$p" 3)"
        gitlink="$(git -C "$dir" ls-tree HEAD "$p" | awk '{print $3}')"
        if [ "$branch" = "-" ] && [ "$gitlink" != "$sha" ]; then
            die "'$p' has no tracked branch, so the superproject gitlink ($gitlink) is authoritative, but $PINS pins $sha"
        fi
        if [ ! -e "$dir/$p/.git" ]; then
            tgit -C "$dir" submodule update -q --init "$p" 2>/dev/null || true
        fi
        [ -e "$dir/$p/.git" ] || die "submodule '$p' could not be initialised in $dir"
        ensure_commit "$dir/$p" "$url" "$sha" \
            || die "pinned upstream commit $sha for '$p' was not found at $url"
        git -C "$dir/$p" checkout -q --detach "$sha" || die "checkout $sha in $dir/$p failed"
        if [ -f "$dir/$p/.gitmodules" ]; then
            tgit -C "$dir/$p" submodule update -q --init --recursive \
                || die "nested submodules of '$p' at $sha could not be initialised"
        fi
        [ "$(git -C "$dir/$p" rev-parse HEAD)" = "$sha" ] || die "'$p' is not at its pin $sha after checkout"
    done
    echo "    pinned tree: singularity-desktop @ $top, $(printf '%s\n' "$subs" | grep -c .) submodules at their pins"
}

cmd_provenance() {
    local dir="$1" p
    echo ". $(git -C "$dir" rev-parse HEAD)"
    for p in $(git -C "$dir" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}'); do
        [ -e "$dir/$p/.git" ] && echo "$p $(git -C "$dir/$p" rev-parse HEAD)"
    done
    [ -n "${2:-}" ] && [ -e "$2/.git" ] && echo "vetro $(git -C "$2" rev-parse HEAD)"
    [ -n "${3:-}" ] && [ -e "$3/.git" ] && echo "singularity-boot-splash $(git -C "$3" rev-parse HEAD)"
    return 0
}

cache_dir_for() {  # one bare mirror per clone URL (host and path, not just the basename)
    local name="${1%.git}"
    name="${name#*://}"
    name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
    echo "$CACHE/$name.git"
}

cmd_fetch_cache() {
    local path url branch sha m bad=0
    mkdir -p "$CACHE" || die "cannot create $CACHE"
    while IFS=$'\t' read -r path url branch sha; do
        m="$(cache_dir_for "$url")"
        if [ ! -d "$m" ]; then
            tgit clone -q --mirror "$url" "$m" || { echo "ERROR: could not mirror $url" >&2; bad=1; continue; }
        else
            tgit -C "$m" fetch -q --prune origin || echo "WARN: could not refresh $m" >&2
        fi
        git -C "$m" cat-file -e "$sha^{commit}" 2>/dev/null \
            || { echo "ERROR: pinned commit $sha for '$path' is not in $url" >&2; bad=1; continue; }
        echo "[pins] cached: $path @ ${sha:0:12} ($m)"
    done < <(rows)
    return "$bad"
}

# Materialise <url>@<sha> as a disposable worktree at <dest>, from the cache
# if it has the commit, else the network. 0 ok, 1 commit does not exist
# upstream, 2 could not reach anything that would know.
materialise() {
    local url="$1" sha="$2" dest="$3" m
    m="$(cache_dir_for "$url")"
    git init -q "$dest" || return 2
    if [ -d "$m" ] && git -C "$m" cat-file -e "$sha^{commit}" 2>/dev/null; then
        git -C "$dest" fetch -q "$m" "$sha" 2>/dev/null || return 2
    else
        if ! tgit ls-remote "$url" HEAD >/dev/null 2>&1; then
            return 2
        fi
        ensure_commit "$dest" "$url" "$sha" || return 1
    fi
    git -C "$dest" checkout -q --detach "$sha" 2>/dev/null || return 1
}

apply_queue() {  # apply_queue <label> <tree> <patch>...
    local label="$1" tree="$2" p rc=0
    shift 2
    for p in "$@"; do
        # In sequence and for real: a later patch may depend on an earlier one.
        if git -C "$tree" apply "$p" 2>/dev/null; then
            echo "[pins] OK: $label/$(basename "$p") applies to its pinned upstream commit"
        else
            echo "[pins] FAIL: $label/$(basename "$p") does NOT apply to its pinned upstream commit"
            git -C "$tree" apply --check "$p" 2>&1 | sed -n '1,3s/^/          /p'
            rc=1
        fi
    done
    return "$rc"
}

cmd_check_patches() {
    cmd_validate >/dev/null || return 1
    local rc
    CHECK_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-pin-check.XXXXXX")" || return 2
    trap 'rm -rf "$CHECK_WORK"; exit 130' INT TERM
    check_patches_in "$CHECK_WORK"; rc=$?
    rm -rf "$CHECK_WORK"
    trap - INT TERM
    return "$rc"
}

check_patches_in() {
    local work="$1" fail=0 warn=0 d sub path url sha patches tree rc bs_sha bs_url lg
    for d in "$PATCH_ROOT"/*/; do
        [ -d "$d" ] || continue
        patches=("$d"*.patch)
        [ -e "${patches[0]}" ] || continue
        sub="$(basename "$d")"
        path="$(patch_dir_path "$sub")"
        sha="$(pin_sha "$path")"; url="$(pin_url "$path")"
        tree="$work/$sub"
        materialise "$url" "$sha" "$tree"; rc=$?
        if [ "$rc" = 1 ]; then
            echo "[pins] FAIL: pinned commit $sha for '$path' does not exist at $url"
            fail=1; continue
        elif [ "$rc" != 0 ]; then
            echo "[pins] WARN: cannot verify $sub patches: $url unreachable and $sha not in $CACHE (run: build/singularity-pins.sh fetch-cache)"
            warn=1; continue
        fi
        apply_queue "$sub" "$tree" "${patches[@]}" || fail=1
        # build-singularity.sh applies the loginui queue a second time, to the
        # copy the boot splash bundles. Check that copy at the commit the
        # pinned boot splash's gitlink names.
        if [ "$sub" = singularity-loginui ]; then
            bs_sha="$(pin_sha singularity-boot-splash)"; bs_url="$(pin_url singularity-boot-splash)"
            materialise "$bs_url" "$bs_sha" "$work/boot-splash"; rc=$?
            if [ "$rc" = 0 ]; then
                lg="$(git -C "$work/boot-splash" ls-tree HEAD subprojects/singularity-loginui | awk '{print $3}')"
                if [ -z "$lg" ]; then
                    echo "[pins] FAIL: boot splash $bs_sha no longer bundles subprojects/singularity-loginui"
                    fail=1
                else
                    materialise "$url" "$lg" "$work/boot-splash-loginui"; rc=$?
                    if [ "$rc" = 0 ]; then
                        apply_queue "singularity-loginui(boot-splash@${lg:0:12})" "$work/boot-splash-loginui" "${patches[@]}" || fail=1
                    elif [ "$rc" = 1 ]; then
                        echo "[pins] FAIL: boot splash's loginui gitlink $lg does not exist at $url"; fail=1
                    else
                        echo "[pins] WARN: cannot verify the boot splash's loginui copy (offline, not cached)"; warn=1
                    fi
                fi
            elif [ "$rc" = 1 ]; then
                echo "[pins] FAIL: pinned commit $bs_sha for singularity-boot-splash does not exist at $bs_url"; fail=1
            else
                echo "[pins] WARN: cannot verify the boot splash's loginui copy (offline, not cached)"; warn=1
            fi
        fi
    done
    [ "$fail" = 0 ] || return 1
    [ "$warn" = 0 ] || return 2
    return 0
}

cmd_propose() {
    local path url branch sha head gl unresolved=0
    # Global, not local: the EXIT trap runs after this function's locals are
    # gone, and under set -u a local name there is an unbound-variable error.
    PROPOSE_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-pin-propose.XXXXXX")" || exit 1
    trap 'rm -rf "$PROPOSE_WORK"' EXIT
    local work="$PROPOSE_WORK"
    url="$(pin_url .)"; branch="$(field . 3)"
    head="$(tgit ls-remote "$url" "refs/heads/$branch" | awk '{print $1}')"
    [ -n "$head" ] || die "cannot resolve $url $branch"
    git init -q "$work/sd" && ensure_commit "$work/sd" "$url" "$head" && git -C "$work/sd" checkout -q --detach "$head" \
        || die "cannot fetch $url $head"
    printf '.\t%s\t%s\t%s\n' "$url" "$branch" "$head"
    while read -r key path; do
        local name="${key#submodule.}"; name="${name%.path}"
        url="$(git -C "$work/sd" config -f .gitmodules --get "submodule.$name.url")"
        branch="$(git -C "$work/sd" config -f .gitmodules --get "submodule.$name.branch" || echo -)"
        gl="$(git -C "$work/sd" ls-tree HEAD "$path" | awk '{print $3}')"
        if [ "$branch" = "-" ]; then
            sha="$gl"
        else
            sha="$(tgit ls-remote "$url" "refs/heads/$branch" | awk '{print $1}')"
        fi
        [ -n "$sha" ] || unresolved=1
        printf '%s\t%s\t%s\t%s\n' "$path" "$url" "$branch" "${sha:-UNRESOLVED}"
    done < <(git -C "$work/sd" config -f .gitmodules --get-regexp '^submodule\..*\.path$')
    for path in vetro singularity-boot-splash; do
        url="$(pin_url "$path")"; branch="$(field "$path" 3)"
        sha="$(tgit ls-remote "$url" "refs/heads/$branch" | awk '{print $1}')"
        [ -n "$sha" ] || unresolved=1
        printf '%s\t%s\t%s\t%s\n' "$path" "$url" "$branch" "${sha:-UNRESOLVED}"
    done
    if [ "$unresolved" = 1 ]; then
        echo "ERROR: some rows are UNRESOLVED (branch missing or unreachable); do not commit this proposal" >&2
        return 1
    fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
    validate)       cmd_validate ;;
    sha)            [ $# = 1 ] || die "usage: $0 sha <path>"; pin_sha "$1" ;;
    url)            [ $# = 1 ] || die "usage: $0 url <path>"; pin_url "$1" ;;
    clone)          [ $# = 2 ] || die "usage: $0 clone <path> <dest>"; cmd_clone "$1" "$2" ;;
    checkout-tree)  [ $# = 1 ] || die "usage: $0 checkout-tree <superproject-dir>"; cmd_checkout_tree "$1" ;;
    provenance)     [ $# -ge 1 ] || die "usage: $0 provenance <dir> [vetro-dir] [boot-splash-dir]"; cmd_provenance "$@" ;;
    check-patches)  cmd_check_patches ;;
    fetch-cache)    cmd_fetch_cache ;;
    propose)        cmd_propose ;;
    *) sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; [ -z "$cmd" ] || exit 1 ;;
esac
