#!/bin/bash
# tests/extract-renamer.sh — extract the embedded Python renamer heredoc
# from the packaged helper, fail-closed if the block is missing or malformed.
#
# Usage: tests/extract-renamer.sh <path-to-helper>
# Prints the Python source to stdout. Exits non-zero on any problem.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <path-to-helper>" >&2
    exit 2
fi

helper=$1
if [ ! -f "$helper" ]; then
    echo "extract-renamer: helper not found: $helper" >&2
    exit 2
fi

# The renamer is the first `python3 - "$@" <<'EOF'` heredoc in the file.
# Extract lines strictly between the opening marker and the matching EOF.
awk '
  /^python3 - "\$@" <<.EOF.$/ { inblock=1; next }
  inblock && /^EOF$/ { inblock=0; done=1; exit }
  inblock { print }
  END { if (!done) exit 1 }
' "$helper"

# awk exits 1 if the closing EOF was never seen; set -e propagates that.
