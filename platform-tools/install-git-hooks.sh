#!/bin/bash
# install-git-hooks.sh -- refresh the flat build view after every checkout/merge/rebase.
#
# The view is hard links to the source files; git replaces a file's inode when it updates
# it, which leaves a stale link until the next assemble. `make` always re-assembles first,
# but a script run directly (bash build/foo.sh) does not. These hooks close that gap.
# Idempotent; safe to re-run. Uses the repository's own hooks directory.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HOOKS="$(git rev-parse --git-path hooks)"
mkdir -p "$HOOKS"
for h in post-checkout post-merge post-rewrite; do
    f="$HOOKS/$h"
    if [ -e "$f" ] && ! grep -q 'platform-assemble' "$f"; then
        echo "install-git-hooks: $f exists and is not ours; add this line to it by hand:" >&2
        echo "  python3 \"\$(git rev-parse --show-toplevel)/platform-tools/platform-assemble.py\" --quiet || true" >&2
        continue
    fi
    printf '#!/bin/sh\n# installed by platform-tools/install-git-hooks.sh\n[ -f "$(git rev-parse --show-toplevel)/platform-tools/platform-assemble.py" ] && python3 "$(git rev-parse --show-toplevel)/platform-tools/platform-assemble.py" --quiet || true\n' > "$f"
    chmod +x "$f"
    echo "install-git-hooks: installed $f"
done
