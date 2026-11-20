#!/bin/bash
# test-bootsplash-patch-queue.sh — the boot splash must keep its OWN patch queue.
#
# Two separate things carry patches for that repository and both must exist:
#   1. patch_dir_path() maps the standalone pins (vetro, singularity-boot-splash)
#      to their own rows, otherwise check-patches looks under subprojects/ and a
#      boot-splash patch can never be verified;
#   2. build-singularity.sh applies that queue to the boot-splash clone itself,
#      separate from the singularity-loginui queue it applies inside the bundled
#      renderer copy.
# A static gate is the right shape here: the alternative is a 20-minute payload
# build to discover that a loop was dropped.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$ROOT/build/singularity-pins.sh"
BUILD="$ROOT/build/build-singularity.sh"
QDIR="$ROOT/assets/singularity/patches/singularity-boot-splash"
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails+1)); }

for f in "$PINS" "$BUILD"; do
    [ -f "$f" ] || { echo "FATAL: $f missing"; exit 2; }
done

# 1. the mapping
if grep -q 'vetro|singularity-boot-splash) echo "\$1"' "$PINS"; then
    ok "patch_dir_path maps the standalone pins to their own rows"
else
    bad "patch_dir_path no longer maps vetro/singularity-boot-splash to \$1"
fi
if grep -q 'singularity-desktop) echo "\."' "$PINS"; then
    ok "patch_dir_path still maps singularity-desktop to ."
else
    bad "patch_dir_path lost the singularity-desktop arm"
fi
if grep -q 'subprojects/\$1' "$PINS"; then
    ok "patch_dir_path still defaults to subprojects/<name>"
else
    bad "patch_dir_path lost its submodule default"
fi

# 2. the build applies the queue to the clone (not only to the bundled loginui)
if grep -q '/ncz-patches/singularity-boot-splash' "$BUILD"; then
    ok "build-singularity.sh applies the boot-splash queue"
else
    bad "build-singularity.sh no longer applies the boot-splash queue"
fi
if grep -q 'ncz patch does not apply to singularity-boot-splash' "$BUILD"; then
    ok "a patch that does not apply fails the build"
else
    bad "the boot-splash apply loop has no failure path"
fi
if grep -q 'cd singularity-boot-splash' "$BUILD"; then
    ok "the loop runs inside the boot-splash clone"
else
    bad "cd singularity-boot-splash is gone; the loop would apply to the wrong tree"
fi

# 3. the queue exists and is not empty
if [ -d "$QDIR" ] && compgen -G "$QDIR/*.patch" >/dev/null; then
    ok "the queue directory holds at least one patch"
else
    bad "the queue directory is missing or empty"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "  all checks passed"
