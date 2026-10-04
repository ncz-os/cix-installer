#!/bin/bash
# hotfix-overlay-manifest.sh -- overlay-manifest generation for the
# desktop-hotfix layer, in one testable place.
#
# The desktop-hotfix layer re-applies the Singularity payload over the desktop
# layer at install time. The installer applies the manifest BEFORE unsquashfs
# (preseed/extract-rootfs.sh), so the manifest is how stale files are removed.
#
# It must NOT be `opaque opt/singularity`: an opaque entry rm -rf's the whole
# tree, dropping files that other dpkg packages own under /opt/singularity
# (ncz-screensavers-plugin, every ncz-wallpapers-* collection). Those are not
# in the payload, so nothing restores them (O6N 2026-10-04). Instead we emit a
# file-level `whiteout` for each file the PREVIOUS hotfix payload had and the
# new payload does not. The previous hotfix holds only payload files, so this
# is safe; a non-opaque overlay leaves package-owned files alone.
#
# Self-test: build/test-hotfix-whiteouts.sh
set -u

# hotfix_capture_prev_files <prev_squashfs> <out_list>
# Writes the previous layer's NON-DIRECTORY paths (opt/singularity/...), sorted.
# Directories are excluded on purpose: whiteouting a directory would rm -rf
# everything below it (including files another package owns).
hotfix_capture_prev_files() {
    local img="${1:?prev squashfs}" out="${2:?out list}"
    command -v unsquashfs >/dev/null 2>&1 || { : > "$out"; return 0; }
    unsquashfs -no-progress -ll "$img" 2>/dev/null \
        | awk '$1 !~ /^d/ {print $6}' \
        | sed -n 's#^squashfs-root/##p' \
        | LC_ALL=C sort -u > "$out" || true
}

# hotfix_overlay_manifest <prev_list|""> <new_tree_dir> <out_manifest>
hotfix_overlay_manifest() {
    local prev_list="${1:-}" new_tree="${2:?new tree}" out="${3:?out manifest}"
    local _new_list _stale _p
    {
        echo "# NCZ overlay manifest v1"
        if [ -n "$prev_list" ] && [ -s "$prev_list" ]; then
            _new_list="$(mktemp "${TMPDIR:-/tmp}/hotfix-new.XXXXXX")"
            ( cd "$new_tree" && find opt/singularity -mindepth 1 \( -type f -o -type l \) 2>/dev/null ) \
                | LC_ALL=C sort -u > "$_new_list"
            _stale="$(comm -23 "$prev_list" "$_new_list" | grep -E '^opt/singularity/.+' || true)"
            if [ -n "$_stale" ]; then
                while IFS= read -r _p; do
                    [ -n "$_p" ] && printf 'whiteout\t%s\n' "$_p"
                done <<< "$_stale"
            else
                echo "# no stale payload files removed by this rebuild"
            fi
            rm -f "$_new_list"
        else
            echo "# no previous hotfix layer; nothing stale to white out"
        fi
    } > "$out"
}
