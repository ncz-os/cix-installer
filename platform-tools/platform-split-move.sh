#!/bin/bash
# Re-runnable physical split; see platform-split-move.py and docs/PLATFORM-SPLIT.md.
exec python3 "$(dirname "$(readlink -f "$0")")/platform-split-move.py" "$@"
