#!/bin/bash
# verify-installed-target-arm64.sh -- compatibility wrapper. The verifier is shared by both architectures now:
# build/verify-installed-target.sh <root.raw> <debugfs> [arm64|amd64].
exec "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/verify-installed-target.sh" "$1" "$2" arm64
