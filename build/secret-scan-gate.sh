#!/bin/bash
# secret-scan-gate.sh — refuse to ship an artifact containing a credential.
#
# Operator constraint (2026-08-14): build hosts may hold credentials; the
# DEPLOYED PRODUCT may not. This gate enforces exactly that boundary.
#
# It exists because ~/zoder-work/singularity-desktop has a GitLab PAT embedded
# in its remote URL in .git/config -- deliberate and fine on the build host, but
# one stray `cp -r` of a source tree into a payload would put it in every ISO we
# ship. The payload IS assembled from that checkout, so the distance between
# "fine" and "shipped credential" is a single glob.
#
# Scans, in order of what actually ships:
#   1. the ISO itself (uncompressed regions: ISO9660 stores pool debs, scripts
#      and preseeds uncompressed, so a plain byte scan finds them)
#   2. the ISO staging tree, before it is packed
#   3. every .deb that goes into the mirrors or the ISO
#   4. payload tarballs
#   5. any .git directory that reached a staging or payload tree at all --
#      a .git is a credential leak waiting to happen even if today's config
#      has no token in it
#
# Compressed squashfs content is NOT byte-scannable, which is why the debs that
# populate it are scanned individually instead: everything inside base/desktop
# squashfs got there from one of those debs.
#
# Usage: build/secret-scan-gate.sh [path ...]
#        with no arguments it scans the standard build outputs.
# Extra patterns: SECRET_SCAN_EXTRA='pattern1|pattern2' (use for host passwords;
# do NOT hardcode a real secret into this file).
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# Credential shapes, not literal secrets.
# NOTE on the AWS pattern boundaries: a bare AKIA[0-9A-Z]{16} false-positived
# on the r238 ISO against the PCI vendor-name table, where KAWASAKI and
# APPLICOM run together as ...KAWAS|AKIAPPLICOMS|UNDANCE... A real access key
# id is delimited; that vendor blob has alphanumerics on both sides, so
# requiring non-alphanumeric boundaries keeps the detection and drops the
# noise. Re-verified after the change: AKIAIOSFODNN7EXAMPLE still trips it.
PATTERNS='glpat-[A-Za-z0-9_.-]{20}|glrt-[A-Za-z0-9_-]{20}|gldt-[A-Za-z0-9_-]{20}|ghp_[A-Za-z0-9]{30}|github_pat_[A-Za-z0-9_]{30}|(^|[^A-Za-z0-9])AKIA[0-9A-Z]{16}([^A-Za-z0-9]|$)|https://[^/@[:space:]$]+:[^/@[:space:]$]+@|(PASS|PASSWD|PASSWORD|SECRET)[A-Z_]*[[:space:]]*=[[:space:]]*"[^"$[:space:]]{6,}"|BEGIN OPENSSH PRIVATE KEY|BEGIN RSA PRIVATE KEY|PRIVATE-TOKEN:[[:space:]]*[A-Za-z0-9_-]{20}'
# Two lessons from this gate's first real use, both encoded above:
#
#   1. The basic-auth URI pattern excludes $ so that
#      https://oauth2:${GITLAB_TOKEN}@gitlab.com -- a variable reference, not a
#      secret -- no longer trips it. A gate that cries wolf gets ignored.
#
#   2. A hardcoded password assignment IS matched now. The gate's first run
#      against tools/nightly flagged the harmless ${GITLAB_TOKEN} URI and said
#      nothing about ARGONAS_PASS="<the fleet password>" three lines above it.
#      Catching the shape of "quoted literal assigned to a *PASS*/SECRET
#      variable" costs nothing and covers the case that actually mattered.
#      The literal itself is deliberately NOT written here; use
#      SECRET_SCAN_EXTRA for site-specific values.
#      NOTE: this alternative matches DOUBLE-quoted values only. PATTERNS is a
#      single-quoted shell string, so a literal ' inside it terminates the
#      assignment -- which is exactly what happened on the first attempt and
#      silently disabled the ENTIRE gate (PATTERNS: unbound variable, every
#      control returning 0). Caught only by re-running the positive controls
#      after the edit. If single-quoted secrets need covering later, build
#      PATTERNS by concatenation rather than embedding a quote here.
# A literal DEFAULT inside a parameter expansion is a credential too:
#     FS_PASS="${SOME_VAR:-hunter2}"
# The quoted-literal alternative above cannot see it, because that alternative
# excludes $ in order to let ${VAR} references through. The two shapes need
# separate patterns: one for "no $ anywhere", one for "$ only as the expansion
# wrapper, with a literal in the :- default".
PATTERNS="$PATTERNS"'|(PASS|PASSWD|PASSWORD|PW|SECRET|TOKEN)[A-Z_]*[[:space:]]*=[[:space:]]*"?\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}"[:space:]]{6,}\}'

# Documented product defaults are not leaks. These ship on purpose and are
# published in docs/REMOTE-ACCESS.md; flagging them would train us to ignore
# this gate. Site values still go in SECRET_SCAN_EXTRA.
ALLOW="${SECRET_SCAN_ALLOW:-failsafe|recovery|rescue|diags}"

[ -n "${SECRET_SCAN_EXTRA:-}" ] && PATTERNS="$PATTERNS|$SECRET_SCAN_EXTRA"

rc=0
hit() { echo "  LEAK: $*" >&2; rc=1; }

scan_bytes() {   # <file> <label>
    local f="$1" label="$2"
    [ -f "$f" ] || return 0
    local n
    n=$(LC_ALL=C grep -aoE "$PATTERNS" "$f" 2>/dev/null | grep -avE "$ALLOW" \
        | sort -u | head -5 | wc -l)
    if [ "$n" -gt 0 ]; then
        hit "$label ($f)"
        LC_ALL=C grep -aoE "$PATTERNS" "$f" 2>/dev/null | grep -avE "$ALLOW" \
            | sort -u | head -5 \
            | sed -E 's/(.{12}).*/\1…<redacted>/' | sed 's/^/        /' >&2
    else
        echo "  ok: $label"
    fi
}

scan_tree() {    # <dir> <label>
    local d="$1" label="$2"
    [ -d "$d" ] || return 0
    local found
    found=$(sudo -n grep -rlE "$PATTERNS" "$d" 2>/dev/null | while read -r _f; do
        LC_ALL=C grep -aoE "$PATTERNS" "$_f" 2>/dev/null | grep -qavE "$ALLOW" && echo "$_f"
    done | head -5)
    if [ -n "$found" ]; then
        hit "$label — files: $(echo "$found" | tr '\n' ' ')"
    else
        echo "  ok: $label"
    fi
    local gits
    gits=$(sudo -n find "$d" -name .git -maxdepth 6 2>/dev/null | head -5)
    if [ -n "$gits" ]; then
        hit "$label contains a .git directory: $(echo "$gits" | tr '\n' ' ')"
    fi
}

echo "=== secret-scan-gate ==="
if [ $# -gt 0 ]; then
    for t in "$@"; do
        if [ -d "$t" ]; then scan_tree "$t" "$(basename "$t")"; else scan_bytes "$t" "$(basename "$t")"; fi
    done
else
    for iso in build/*.iso; do scan_bytes "$iso" "ISO $(basename "$iso")"; done
    scan_tree build/iso-staging-di "iso staging"
    for d in build/kernel-debs/*.deb build/sinty-out/*.deb; do scan_bytes "$d" "deb $(basename "$d")"; done
    for m in forky-mirror forky-vendor-mirror; do
        for d in build/$m/pool/main/*.deb; do scan_bytes "$d" "$m/$(basename "$d")"; done
    done
    for t in build/sinty-out/*.tgz; do scan_bytes "$t" "payload $(basename "$t")"; done
fi

if [ "$rc" -ne 0 ]; then
    echo "GATE: FAIL — a credential reached a shippable artifact" >&2
    exit 1
fi
echo "GATE: PASS ✅  no credentials in shippable artifacts"
exit 0
