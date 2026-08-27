#!/bin/bash
# verify-payload.sh — does this Singularity payload actually carry the
# layer-shell close-path fix?
#
# WHY: on 2026-08-10 the forky tree was staging an UNPATCHED payload while the
# fix sat on a test board, and nothing in the build would have caught it. A
# filename, a build log and a version string all looked fine. The only honest
# check is the binary itself.
#
# md5 does NOT discriminate: two independent builds of identical source differ,
# so this greps for the symbol the patch introduces instead.
#
# Usage: verify-payload.sh <singularity-opt.tgz | /opt/singularity dir>
set -uo pipefail

T="${1:?usage: verify-payload.sh <singularity-opt.tgz|/opt/singularity>}"
W=""; cleanup() { [ -n "$W" ] && rm -rf "$W"; }; trap cleanup EXIT

if [ -d "$T" ]; then
    ROOT="$T"
else
    W="$(mktemp -d)"
    tar xzf "$T" -C "$W" 2>/dev/null || { echo "FATAL: cannot extract $T" >&2; exit 2; }
    ROOT="$W/opt/singularity"
fi

BIN="$ROOT/bin/singularity-desktop"
[ -s "$BIN" ] || { echo "FATAL: $BIN missing -- extraction failed, so any verdict below would be meaningless" >&2; exit 2; }

n=$(readelf --dyn-syms "$BIN" 2>/dev/null | grep -c gtk_widget_unrealize)
md5=$(md5sum "$BIN" | cut -d' ' -f1)

echo "payload : $T"
echo "binary  : $BIN"
echo "md5     : $md5"
echo "unrealize imports: $n"

if [ "$n" -ge 1 ]; then
    echo "RESULT: PATCHED — carries the close-path fix (PR #15)"
    exit 0
fi
echo "RESULT: UNPATCHED — this payload will reproduce the layer-shell crash" >&2
echo "        (known-unpatched build is md5 e23ebc08d41fba17981c6c9c30faef25)" >&2
exit 1
