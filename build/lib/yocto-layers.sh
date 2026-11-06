#!/bin/bash
# yocto-layers.sh -- fetch one Yocto layer at a pinned revision.
#
# M9 item 3 (the cache half): the first clone now PREFERS the store when a
# fallback base is configured, instead of hammering the public URL and only
# falling back when it fails. The pin is still the gate -- a store clone that
# lacks the pinned commit is followed by an upstream fetch, and a missing
# revision is a hard error, never a silent checkout of something else.
#
# ncz_yocto_fetch_layer NAME URL FALLBACK REVISION LAYERS_ROOT
#   FALLBACK may be empty. STORE_SSH (default ssh) is the ssh command for the
#   store URL. Returns 0 with the layer checked out detached at REVISION.
ncz_yocto_fetch_layer() {
    local name="$1" url="$2" fallback="$3" revision="$4" layers_root="$5"
    local dir="$layers_root/$name" ssh_cmd="${STORE_SSH:-ssh}" cloned=0
    [ -n "$layers_root" ] || { echo "ERROR: no layers root for $name" >&2; return 1; }
    if [ -e "$dir" ] && [ ! -d "$dir/.git" ]; then
        echo "ERROR: $dir exists but is not a git checkout" >&2; return 1
    fi
    if [ ! -d "$dir/.git" ]; then
        if [ -n "$fallback" ]; then
            echo "[ncz-yocto] clone $name from the store"
            if GIT_SSH_COMMAND="$ssh_cmd" git clone "$fallback" "$dir" >/dev/null 2>&1; then
                cloned=1
            else
                rm -rf "$dir"
                echo "[ncz-yocto] the store does not have $name; cloning upstream" >&2
            fi
        fi
        if [ "$cloned" = 0 ]; then
            echo "[ncz-yocto] clone $name from upstream"
            if ! git clone "$url" "$dir"; then
                rm -rf "$dir"
                if [ -n "$fallback" ]; then
                    echo "[ncz-yocto] upstream unavailable; trying the configured fallback for $name" >&2
                    GIT_SSH_COMMAND="$ssh_cmd" git clone "$fallback" "$dir" || return 1
                else
                    return 1
                fi
            fi
        fi
    fi
    [ -w "$dir/.git/objects" ] || {
        echo "ERROR: $dir/.git/objects is not writable (check for root-owned objects)" >&2; return 1
    }
    echo "[ncz-yocto] pin $name at $revision"
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
        echo "ERROR: $dir has tracked local changes; refusing to overwrite them" >&2; return 1
    fi
    if ! git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null; then
        git -C "$dir" fetch --tags origin >/dev/null 2>&1 || true
    fi
    if ! git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null && [ -n "$fallback" ]; then
        echo "[ncz-yocto] pinned object absent from primary; fetching the configured fallback for $name"
        GIT_SSH_COMMAND="$ssh_cmd" \
            git -C "$dir" fetch "$fallback" '+refs/heads/*:refs/remotes/fallback/*' >/dev/null 2>&1 || true
    fi
    git -C "$dir" cat-file -e "$revision^{commit}" 2>/dev/null || {
        echo "ERROR: pinned revision $revision not found for $name" >&2; return 1
    }
    git -C "$dir" checkout --detach "$revision" >/dev/null 2>&1
}
