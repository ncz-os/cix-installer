#!/bin/bash
# test-kernel-debs-arch-policy.sh -- the kernel-debs gate must verify the TARGET
# arch, not always arm64: the arm64 7.3.3 pin is an explicitly unapplied template
# (operator order) while amd64 is on 7.3.3, so an unconditional arm64 check blocks
# every amd64 image build.
set -u
M="$(cd "$(dirname "$0")/.." && pwd)/Makefile"
[ -f "$M" ] || { echo "FAIL: no Makefile"; exit 1; }
line=$(grep -n 'verify-kernel-default-policy.sh --root' "$M" | head -1 | cut -d: -f1)
[ -n "$line" ] || { echo "FAIL: no policy invocation"; exit 1; }
text=$(sed -n "${line}p" "$M")
case "$text" in
    *'--arch $(ARCH)'*) echo "PASS: kernel-debs policy uses the target arch"; exit 0 ;;
    *'--arch arm64'*) echo "FAIL: kernel-debs policy is hard-coded to arm64"; exit 1 ;;
    *) echo "FAIL: unexpected policy arch"; exit 1 ;;
esac
