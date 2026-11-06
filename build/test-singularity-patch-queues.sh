#!/usr/bin/env bash
# Every ncz patch queue must reach a tree, and a standalone queue must have a
# real application site.
#
# Why this exists: a queue for singularity-boot-splash was added on 2026-11-05
# while the generic loop demanded a subprojects/<name> tree for every directory
# it found. The payload build therefore failed on 2026-11-06 with "ncz patches
# exist for singularity-boot-splash but subprojects/singularity-boot-splash is
# not in this tree" -- on any arch, before a single target compiled. The loop
# now skips the queues that are applied at their own clone site, and this test
# is what keeps that list honest: a name in STANDALONE_QUEUES with no clone and
# no application site fails here instead of failing a 40-minute build.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BUILD="$REPO/build/build-singularity.sh"
PATCHES="$REPO/assets/singularity/patches"
PINS="$REPO/assets/singularity/upstream-pins.tsv"

pass=0
fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
nok() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

[ -f "$BUILD" ] || { echo "no build-singularity.sh"; exit 1; }
[ -d "$PATCHES" ] || { echo "no patch directory"; exit 1; }

# The standalone list, read from the script itself so the two cannot drift.
standalone="$(sed -n 's/^STANDALONE_QUEUES="\(.*\)"$/\1/p' "$BUILD")"
[ -n "${standalone+x}" ] || nok "STANDALONE_QUEUES is defined in build-singularity.sh"
ok "standalone list read: [${standalone:-}]"

queues=0
for dir in "$PATCHES"/*/; do
    [ -d "$dir" ] || continue
    name="$(basename "$dir")"
    queues=$((queues + 1))

    case " $standalone " in
        *" $name "*)
            # must be cloned by the pins helper and have its own patch site
            if grep -q "singularity-pins.sh clone $name " "$BUILD"; then
                ok "$name: cloned at its pinned commit"
            else
                nok "$name: listed standalone but build-singularity.sh never clones it"
            fi
            if grep -q "if \[ -d /ncz-patches/$name \]" "$BUILD"; then
                ok "$name: has its own application site"
            else
                nok "$name: listed standalone but no '/ncz-patches/$name' site applies it"
            fi
            ;;
        *)
            # otherwise it must be a pinned subproject, or the root repo itself
            if grep -qP "^subprojects/$name\t" "$PINS"; then
                ok "$name: pinned subproject"
            elif [ "$name" = "singularity-desktop" ]; then
                ok "$name: the root repository"
            else
                nok "$name: neither a standalone queue nor a pinned subproject"
            fi
            ;;
    esac
done

[ "$queues" -gt 0 ] || nok "found at least one patch queue"
echo "patch-queue map: $queues queue(s) checked"
echo "test-singularity-patch-queues: $pass passed, $fail failed"
[ "$fail" = 0 ]
