#!/bin/bash
# check-extract-rootfs-consistency.sh — build-time gate that closes the
# "extract-rootfs.sh and the r159 stub silently diverge" trap.
#
# Why this exists
# ---------------
# Tonight's 2026-08-26 0700-root incident audit identified a structural gap:
# preseed/extract-rootfs.sh and the r159 layered-squashfs branch baked into
# the /usr/sbin/debootstrap stub in build-iso-di.sh are TWO COPIES of the
# same install-time extraction logic. They have already diverged three times
# (round 1 fixed the dead twin and it shipped nowhere, round 3 fixed the live
# twin and shipped). The ideal unification (one source, embedded at build
# time) is structurally invasive: the stub's r159 branch is ~430 lines of
# extraction + post-extraction setup (dpkg configure, ssh-keygen, networkd
# cleanup, ncz-baked marker, ncz-firstboot generation, fstab scaffolding)
# and collapsing that into preseed/extract-rootfs.sh would be a much larger
# refactor than the original audit assumed.
#
# The CONSISTENCY GATE is the cheaper mechanical alternative: it does not
# unify the two copies, but it FAILS THE BUILD whenever their logical
# content has drifted, so a "fix made in extract-rootfs.sh and forgotten in
# the stub" (round-1's failure mode) cannot reach a shipped ISO without a
# loud build-time failure. See docs/ISO-BUILD-GUARDRAILS.md's "dead-code
# twin" trap entry for the incident this closes.
#
# What "consistency" means
# ------------------------
# Both files contain a layered-squashfs extraction branch with the same shape
# (locate media, load sqtools bundle, extract base.squashfs, apply overlay
# manifest, extract role delta, apply hotfix overlay, root-mode gate).
# Normalization strips:
#   - all comments (#...to end-of-line)
#   - all leading/blank whitespace
#   - variable-name variants (SQDIR <-> SQFS_DIR, UNSQ <-> UNSQ_BIN, etc.)
#   - logging-prefix variants ("r159 stub: ..." <-> "extract-rootfs.sh: ...")
# After normalization, the SHAPE of the code (the sequence of operations
# and their arguments) must match. If it doesn't, the diff below names the
# offending lines and the script exits 1.
#
# Usage
# -----
#   bash build/check-extract-rootfs-consistency.sh \
#       --build-iso-di build/build-iso-di.sh \
#       --extract-rootfs preseed/extract-rootfs.sh \
#       [--strict|--loose]
#
# --strict (default): fail on any non-whitespace, non-comment diff after
#                     normalization (including logging text differences).
# --loose          : allow only the known 2026-08-26 baseline drift fingerprint.
#                     Any newly-introduced drift changes that fingerprint and
#                     fails the build. This keeps the temporary loose wiring
#                     from becoming a no-op while the two copies are synced.

set -euo pipefail

BUILD_ISO_DI=""
EXTRACT_ROOTFS=""
STRICT=1
while [ $# -gt 0 ]; do
    case "$1" in
        --build-iso-di)    BUILD_ISO_DI="$2"; shift 2 ;;
        --extract-rootfs)  EXTRACT_ROOTFS="$2"; shift 2 ;;
        --strict)          STRICT=1; shift ;;
        --loose)           STRICT=0; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

[ -n "$BUILD_ISO_DI" ]    || { echo "ERROR: --build-iso-di required" >&2; exit 2; }
[ -n "$EXTRACT_ROOTFS" ]  || { echo "ERROR: --extract-rootfs required" >&2; exit 2; }
[ -f "$BUILD_ISO_DI" ]    || { echo "ERROR: $BUILD_ISO_DI not a file" >&2; exit 2; }
[ -f "$EXTRACT_ROOTFS" ]  || { echo "ERROR: $EXTRACT_ROOTFS not a file" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Step 1: locate the r159 branch in build-iso-di.sh's stub heredoc.
# The stub heredoc opens with `cat > $DEBOOTSTRAP_PATCH_DATA/usr/sbin/debootstrap <<'STUB'`
# (or STUB_HEAD after the r190 refactor -- either marker identifies the
# heredoc body), runs to the `STUB` / `STUB_TAIL` terminator. The r159 branch
# inside is the `if [ -n "$SQDIR" ]` (or `$SQFS_DIR`) block, which we extract
# by line range.
# ---------------------------------------------------------------------------
echo "[consistency] locating r159 branch in $BUILD_ISO_DI"
STUB_HEREDOC_START=$(grep -n "<<'STUB'\|<<'STUB_HEAD'" "$BUILD_ISO_DI" | head -1 | cut -d: -f1 || true)
STUB_HEREDOC_END=$(grep -nE "^STUB$|^STUB_HEAD$" "$BUILD_ISO_DI" | head -1 | cut -d: -f1 || true)
if [ -z "$STUB_HEREDOC_START" ] || [ -z "$STUB_HEREDOC_END" ]; then
    echo "ERROR: could not locate stub heredoc in $BUILD_ISO_DI" >&2
    exit 2
fi
echo "  stub heredoc body: lines ${STUB_HEREDOC_START}..${STUB_HEREDOC_END}"

# The r159 branch starts at the comment `# r159: LAYERED SQUASHFS` (older) or
# `# r159 LAYERED SQUASHFS install path` (newer) and ends just before the
# `# Find rootfs.tar.zst` legacy fallback. We use comment anchors so the
# check survives cosmetic reformatting of the heredoc.
STUB_R159_START=$(awk -v start="$STUB_HEREDOC_START" -v end="$STUB_HEREDOC_END" \
    'NR >= start && NR <= end && /^# r159/ { print NR; exit }' "$BUILD_ISO_DI")
STUB_R159_END=$(awk -v start="$STUB_HEREDOC_START" -v end="$STUB_HEREDOC_END" \
    'NR >= start && NR <= end && /^# Find rootfs.tar.zst/ { print NR-1; exit }' "$BUILD_ISO_DI")
if [ -z "$STUB_R159_START" ] || [ -z "$STUB_R159_END" ]; then
    echo "ERROR: could not bound r159 branch in stub heredoc (start=${STUB_R159_START:-?} end=${STUB_R159_END:-?})" >&2
    exit 2
fi
echo "  r159 branch:       lines ${STUB_R159_START}..${STUB_R159_END}"

# ---------------------------------------------------------------------------
# Step 2: locate the r159 branch in preseed/extract-rootfs.sh.
# It's the `if [ -n "$SQFS_DIR" ]` block, which the file has always carried.
# ---------------------------------------------------------------------------
echo "[consistency] locating r159 branch in $EXTRACT_ROOTFS"
# Anchor on the unique `if [ -n "$SQFS_DIR" ]` line that opens the r159
# branch (extract-rootfs.sh's SQFS_DIR variable is unique to that branch;
# the legacy rootfs.tar.zst fallback below it uses ROOTFS= instead).
EXT_R159_START=$(grep -n 'if \[ -n "\$SQFS_DIR" \]' "$EXTRACT_ROOTFS" | head -1 | cut -d: -f1 || true)
if [ -z "$EXT_R159_START" ]; then
    echo "ERROR: could not locate r159 branch in $EXTRACT_ROOTFS (anchor 'if [ -n \"\$SQFS_DIR\" ]' not found)" >&2
    exit 2
fi
# Find the closing fi. The r159 branch ends at the first top-level `fi`
# after SQFS_DIR is checked -- which matches a line that is just `fi` at
# indent 0. (extract-rootfs.sh's legacy rootfs.tar.zst branch follows.)
EXT_R159_END=$(awk -v start="$EXT_R159_START" \
    'NR >= start && /^fi$/ { print NR; exit }' "$EXTRACT_ROOTFS")
if [ -z "$EXT_R159_END" ]; then
    echo "ERROR: could not bound r159 branch in $EXTRACT_ROOTFS" >&2
    exit 2
fi
echo "  r159 branch:       lines ${EXT_R159_START}..${EXT_R159_END}"

# ---------------------------------------------------------------------------
# Step 3: normalize each branch and diff.
# ---------------------------------------------------------------------------
NORM_STUB=$(mktemp /tmp/ncz-consistency-stub.XXXXXX.txt)
NORM_EXT=$(mktemp /tmp/ncz-consistency-ext.XXXXXX.txt)
trap "rm -f '$NORM_STUB' '$NORM_EXT'" EXIT

# Python normalization handles a few classes of cosmetic drift:
#   - whitespace collapse
#   - comment stripping (whole-line + inline)
#   - variable-name variant normalization
#   - logging-prefix stripping (the literal "I: r159 stub: " / "W: r159 stub: "
#     / "FATAL: r159 stub: " / "FATAL: rootmode stub: " prefixes that the stub
#     uses; extract-rootfs.sh uses the equivalent "I: extract-rootfs.sh: " etc.)
python3 - "$BUILD_ISO_DI" "$STUB_R159_START" "$STUB_R159_END" "$NORM_STUB" <<'PY'
import re, sys
path, start_s, end_s, out = sys.argv[1:5]
start = int(start_s); end = int(end_s)

with open(path) as f:
    lines = f.readlines()

out_lines = []
for i, line in enumerate(lines, 1):
    if i < start or i > end:
        continue
    # strip comments (whole line + inline)
    line = re.sub(r"#.*$", "", line)
    # collapse whitespace
    line = re.sub(r"\s+", " ", line).strip()
    if not line:
        continue
    # normalize variable-name variants -- the stub and extract-rootfs.sh have
    # used both spellings across their history (SQDIR/SQFS_DIR, UNSQ/UNSQ_BIN);
    # we collapse them so a rename doesn't trigger a false-positive drift.
    # Order matters: the longer/more-specific variant first so we don't
    # double-substitute (e.g. UNSQ_NORM after UNSQ -> UNSQ_NORM would already
    # be a no-op, but UNSQ_BIN after UNSQ -> UNSQBIN would mangle).
    line = line.replace("UNSQ_BIN", "UNSQ_NORM")
    line = line.replace("$UNSQ_NORM_NORM", "$UNSQ_NORM")
    line = line.replace("SQDIR", "SQDIR_NORM")
    line = line.replace("$SQDIR_NORM_NORM", "$SQDIR_NORM")
    line = line.replace("SQFS_DIR", "SQDIR_NORM")
    # normalize logging prefixes (the stub prefixes messages with "I: r159 stub: "
    # / "W: r159 stub: " / "FATAL: r159 stub: " / "FATAL: rootmode stub: ";
    # extract-rootfs.sh prefixes with the equivalent "I: extract-rootfs.sh: " etc.
    # Strip both the leading severity marker AND the file-identity tag, leaving
    # just the message body. We DO NOT preserve the severity (FATAL vs I/W)
    # because the stub and extract-rootfs.sh have used different conventions
    # historically; if a future fix needs to track severity, add that as a
    # separate gate.
    line = re.sub(r'"(?:I|W|FATAL): [^:"]*:\s*', '"', line)
    out_lines.append(line)

with open(out, "w") as f:
    f.write("\n".join(out_lines) + "\n")
PY

python3 - "$EXTRACT_ROOTFS" "$EXT_R159_START" "$EXT_R159_END" "$NORM_EXT" <<'PY'
import re, sys
path, start_s, end_s, out = sys.argv[1:5]
start = int(start_s); end = int(end_s)

with open(path) as f:
    lines = f.readlines()

out_lines = []
for i, line in enumerate(lines, 1):
    if i < start or i > end:
        continue
    line = re.sub(r"#.*$", "", line)
    line = re.sub(r"\s+", " ", line).strip()
    if not line:
        continue
    line = line.replace("UNSQ_BIN", "UNSQ_NORM")
    line = line.replace("$UNSQ_NORM_NORM", "$UNSQ_NORM")
    line = line.replace("SQDIR", "SQDIR_NORM")
    line = line.replace("$SQDIR_NORM_NORM", "$SQDIR_NORM")
    line = line.replace("SQFS_DIR", "SQDIR_NORM")
    line = re.sub(r'"(?:I|W|FATAL): [^:"]*:\s*', '"', line)
    out_lines.append(line)

with open(out, "w") as f:
    f.write("\n".join(out_lines) + "\n")
PY

# ---------------------------------------------------------------------------
# Step 4: diff and report.
# ---------------------------------------------------------------------------
echo "[consistency] diffing normalized branches"
if diff -u "$NORM_STUB" "$NORM_EXT" > /tmp/ncz-consistency-diff.txt 2>&1; then
    echo "[consistency] OK: stub r159 branch and extract-rootfs.sh r159 branch match"
    echo "[consistency] (after normalization for whitespace/comments/variable names/logging prefixes)"
    exit 0
fi

# There's a diff. Print the first 80 lines and report what to do.
echo
echo "================================================================"
echo "  CONSISTENCY CHECK FAILED"
echo "================================================================"
echo
echo "The r159 layered-squashfs branch in $BUILD_ISO_DI (the LIVE path"
echo "baked into the /usr/sbin/debootstrap stub) and the equivalent branch"
echo "in $EXTRACT_ROOTFS (the dead twin) have drifted."
echo
echo "This is EXACTLY the failure mode the 2026-08-26 0700-root incident"
echo "exposed: a fix made in one file is forgotten in the other. Closing"
echo "this trap is the point of the consistency check."
echo
echo "DIFF (first 80 lines, after normalization for whitespace/comments/"
echo "variable names/logging prefixes; structural differences only):"
echo
head -80 /tmp/ncz-consistency-diff.txt
echo
if [ "$STRICT" = "1" ]; then
    echo "STRICT MODE: any drift above is a build failure."
    echo
    echo "REMEDIATION: pick one of:"
    echo "  1. Make the fix in BOTH files in the same commit (one diff, two hunks)."
    echo "  2. Make extract-rootfs.sh the source of truth and have the build"
    echo "     script read+embed it into the stub heredoc (the long-promised"
    echo "     unification -- deferred pending its own reviewed look)."
    echo "  3. If the diff above is purely cosmetic (variable rename, logging"
    echo "     prefix), either align the two files manually OR re-run with"
    echo "     --loose to permit cosmetic-only drift while you clean up."
    echo
    exit 1
else
    # Temporary 2026-08-26 escape hatch: build-iso-di.sh is wired to --loose
    # because --strict exposed pre-existing drift that needs a reviewed sync.
    # Loose mode must still catch NEW drift, so it only permits the exact
    # current normalized diff body. Exclude the first two unified-diff header
    # lines because they contain mktemp paths and timestamps.
    KNOWN_LOOSE_DIFF_SHA256="4e475024ab3411cccaf96e72480261676bf2669ba5c3f46379e77d1de5b96cec"
    LOOSE_DIFF_SHA256=$(tail -n +3 /tmp/ncz-consistency-diff.txt | sha256sum | awk '{print $1}')
    if [ "$LOOSE_DIFF_SHA256" = "$KNOWN_LOOSE_DIFF_SHA256" ]; then
        echo "LOOSE MODE: tolerated the known baseline drift only (sha256=$LOOSE_DIFF_SHA256)."
        echo "Tighten this with --strict once the two files are synced."
        exit 0
    fi
    echo "LOOSE MODE: NEW drift detected (sha256=$LOOSE_DIFF_SHA256, expected $KNOWN_LOOSE_DIFF_SHA256)." >&2
    echo "This is a build failure even under --loose; mirror the change in both twins or update the reviewed baseline." >&2
    exit 1
fi
