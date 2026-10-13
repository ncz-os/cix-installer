#!/bin/bash
# test-overview-dock-clearance.sh -- the app overview keeps its grid clear of
# the dock (assets/singularity/patches/singularity-shell/0021-*).
#
# The overview is a full-output layer surface that ignores exclusive zones, and
# the dock stays above it, shown while the overview is open even in autohide.
# Without the patch the dock covers the bottom row of app icons. This test
# FAILS when the patch is gone, no longer applies the inset on the dock edge,
# or stops sizing the grid from the area left above the dock. When a patched
# singularity-shell tree is given (NCZ_SHELL_SRC=<dir>), it checks that tree.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCH="$ROOT/assets/singularity/patches/singularity-shell/0021-overview-keep-the-app-grid-clear-of-the-dock.patch"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

if [ -f "$PATCH" ]; then ok "patch carried in the singularity-shell queue"; else bad "patch missing: $PATCH"; fi
has "$PATCH" '+        public int shown_extent() {' && ok "Dock exposes shown_extent()" || bad "Dock.shown_extent() missing"
has "$PATCH" '+                content_stack.margin_bottom = dock_extent;' && ok "bottom dock insets the overview content" || bad "bottom inset missing"
has "$PATCH" '+                if (dock_pos == "left") content_stack.margin_start = dock_extent;' && ok "left dock insets the overview content" || bad "left inset missing"
has "$PATCH" '+                else content_stack.margin_end = dock_extent;' && ok "right dock insets the overview content" || bad "right inset missing"
has "$PATCH" '+            launcher_grid.viewport_hint = avail_h;' && ok "grid viewport hint uses the height left above the dock" || bad "viewport hint still the full output height"
has "$PATCH" '+        overview.dock = dock;' && ok "primary overview is given the primary dock" || bad "overview never learns the dock"
has "$PATCH" '+        if (overview != null) overview.dock = dock;' && ok "overview follows a recreated dock" || bad "overview keeps a destroyed dock"

if [ -n "${NCZ_SHELL_SRC:-}" ]; then
    O="$NCZ_SHELL_SRC/src/components/overview/overview.vala"
    D="$NCZ_SHELL_SRC/src/components/dock/dock.vala"
    has "$O" 'content_stack.margin_bottom = dock_extent;' && ok "tree: overview inset present" || bad "tree: overview inset absent in $O"
    has "$D" 'public int shown_extent()' && ok "tree: Dock.shown_extent present" || bad "tree: Dock.shown_extent absent in $D"
fi

echo "overview-dock-clearance tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
