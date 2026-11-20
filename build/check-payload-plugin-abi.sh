#!/bin/bash
# check-payload-plugin-abi.sh BASELINE_DEB CANDIDATE_DEB PLUGIN_DEB
#
# Answer the question the sha lock cannot: would a plugin built against one payload still
# resolve against another?
#
# The plugin lock (post-install/lib/ncz-screensavers-plugin.lock) enforces identity - the
# plugin must have been built against THIS payload's exact libsingularity. That is stricter
# than "the binary still works", and on 2026-11-06 the difference mattered: the pinned
# payload failed the identity rule while the shipped plugin's 30 libsingularity imports all
# resolved against it, because the library is a symbol superset with an unchanged SONAME.
# Neither answer alone is enough, so this checks the second one explicitly:
#
#   * the plugin still declares libsingularity.so.0 as NEEDED;
#   * the candidate library exports every symbol the baseline exported;
#   * every symbol the plugin took from the baseline is present in the candidate.
#
# Exit: 0 the plugin still resolves, 1 it does not (or the question cannot be answered),
# 2 usage/setup. Nothing here is a judgement about policy - the lock stays authoritative
# until someone decides otherwise.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PLUGIN_PATH=/opt/singularity/lib/singularity/plugins/screensaver/libscreensaver.so
LIB_GLOB='./opt/singularity/lib/libsingularity.so.0*'

die() { echo "check-payload-plugin-abi: $*" >&2; exit 2; }

BASE=${1:?usage: check-payload-plugin-abi.sh BASELINE_DEB CANDIDATE_DEB PLUGIN_DEB}
CAND=${2:?usage: check-payload-plugin-abi.sh BASELINE_DEB CANDIDATE_DEB PLUGIN_DEB}
PLUG=${3:?usage: check-payload-plugin-abi.sh BASELINE_DEB CANDIDATE_DEB PLUGIN_DEB}
for f in "$BASE" "$CAND" "$PLUG"; do [ -r "$f" ] || die "cannot read $f"; done
for t in dpkg-deb tar nm readelf python3; do command -v "$t" >/dev/null 2>&1 || die "$t is required"; done

T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-abisym.XXXXXX")" || die "cannot create a temp dir"
trap 'rm -rf "$T"' EXIT

extract() {  # deb out pattern
    dpkg-deb --fsys-tarfile "$1" 2>/dev/null | tar -xO "$3" > "$2" 2>/dev/null
    [ -s "$2" ] || return 1
    # a symlink extracts as nothing, so require an ELF header: an empty file here would
    # otherwise turn into "no symbols" and read like a clean comparison
    [ "$(head -c 4 "$2" | od -An -c | tr -d ' \n')" = '177ELF' ] || return 1
}
extract "$BASE" "$T/base.so" "./opt/singularity/lib/libsingularity.so.0.1.0" \
    || { echo "check-payload-plugin-abi: cannot extract libsingularity from $BASE" >&2; exit 1; }
extract "$CAND" "$T/cand.so" "./opt/singularity/lib/libsingularity.so.0.1.0" \
    || { echo "check-payload-plugin-abi: cannot extract libsingularity from $CAND" >&2; exit 1; }
extract "$PLUG" "$T/plug.so" ".$PLUGIN_PATH" \
    || { echo "check-payload-plugin-abi: cannot extract $PLUGIN_PATH from $PLUG" >&2; exit 1; }

nm -D --defined-only   "$T/base.so" | awk '{print $NF}' | LC_ALL=C sort -u > "$T/base.syms"
nm -D --defined-only   "$T/cand.so" | awk '{print $NF}' | LC_ALL=C sort -u > "$T/cand.syms"
nm -D --undefined-only "$T/plug.so" | awk '{print $NF}' | LC_ALL=C sort -u > "$T/plug.und"
readelf -d "$T/plug.so" 2>/dev/null | awk '/NEEDED/{gsub(/[]["]/,"",$NF); print $NF}' \
    | LC_ALL=C sort -u > "$T/plug.need"

echo "baseline $(basename "$BASE"): $(wc -l < "$T/base.syms") exported symbols"
echo "candidate $(basename "$CAND"): $(wc -l < "$T/cand.syms") exported symbols"
echo "plugin $(basename "$PLUG"): $(wc -l < "$T/plug.und") undefined symbols"
python3 -I "$HERE/substrate-ci.py" abi-symbols \
    --baseline "$T/base.syms" --candidate "$T/cand.syms" \
    --plugin "$T/plug.und" --needed "$T/plug.need"
