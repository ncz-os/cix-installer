#!/bin/sh
# ncz-fetch-payload.sh -- Magnetar (NCZ_VARIANT=server) ONLINE payload fetch.
#
# Operator directive 2026-10-16: the Magnetar installer medium carries no
# multi-gigabyte payload. Everything that used to be baked onto the medium is
# pulled over the network at install time and sha256-verified before a single
# byte of it is used. The debootstrap stub (the r159 stub that replaces
# /usr/sbin/debootstrap) calls this script BEFORE it extracts anything, so the
# contract "anything needed during boot is on the medium or fetched BEFORE the
# stub runs" holds.
#
# What is fetched is driven by a MANIFEST the build wrote next to this script:
#
#     <name>\t<url>\t<sha256>\t<mode>        # mode: file | untar
#
# so adding or removing an online artifact is a build-side change, not a change
# to this script. When no manifest is present the script falls back to the
# original single-artifact contract (NCZ_PAYLOAD_URL / NCZ_PAYLOAD_SHA256 /
# NCZ_PAYLOAD_NAME), which is still what the base.squashfs-only media uses.
#
# Design constraints (all verified against the tree, none assumed):
#  - busybox on the medium ships the wget applet; no new client is added.
#  - the payload read path in the stub probes several dirs, so writing the
#    fetched tree into one of them is additive.
#
# SAFETY: this is the stage that decides whether a rootfs is trustworthy, so it
#  - verifies sha256 BEFORE handing the file on. A truncated or tampered
#    download must fail, never install.
#  - fails LOUDLY and BOUNDED. On a headless box there is nobody watching the
#    screen, so a silent hang is the worst possible outcome. Every failure path
#    writes to the serial console and exits non-zero.
#  - resumes with HTTP Range so a dropped link does not restart the fetch.
#  - is idempotent: an artifact already present with the pinned digest is
#    skipped, so a re-run of the install does not re-download gigabytes.
#  - every destination is checked to be writable BEFORE anything is fetched.
#    The medium is mounted read-only; a fetch into it would fail halfway and
#    leave a half-written tree that the next run would trust.

set -u

# Serial failure visibility on BOTH arm64 (Sky1 / O6N / cixmini / MS-R1:
# the PL011 debug UART is ttyAMA0) and amd64 (T2: the on-screen console
# tty0; d-i's own serial sidecar is diag-console.sh, not this script).
# The server medium is headless, so a failure that lands on only one of the
# two consoles is a silent box. /dev/console is intentionally NOT written:
# on arm64 it is ttyAMA0 (duplicated), and on a d-i that reopened console
# the write would disturb the installer's console device.
SER=/dev/ttyAMA0
SER2=/dev/tty0
DEST_DIR="${NCZ_PAYLOAD_DIR:-/cdrom/ncz-payload}"
MANIFEST="${NCZ_FETCH_MANIFEST:-$DEST_DIR/ncz-fetch-payload.manifest}"
MAX_TRIES="${NCZ_FETCH_MAX_TRIES:-10}"
CONNECT_TIMEOUT="${NCZ_FETCH_CONNECT_TIMEOUT:-10}"
OVERALL_TIMEOUT="${NCZ_FETCH_OVERALL_TIMEOUT:-1800}"
TMPDIR_FETCH="${NCZ_FETCH_TMPDIR:-/tmp}"

# Every line goes to stderr (the r159 stub forwards it to the installer log
# and tells the operator to "see the [FETCH] lines above") and to each console
# that exists. Writes are independent: a console that exists but is not
# writable must not silence the other one or the log.
say() {
    _line="$*"
    printf '%s\n' "$_line" >&2 2>/dev/null || true
    for _c in "$SER" "$SER2"; do
        [ -c "$_c" ] || continue
        printf '%s\n' "$_line" 2>/dev/null >>"$_c" || true
    done
}

start=$(date +%s 2>/dev/null || echo 0)
elapsed() { echo $(($(date +%s 2>/dev/null || echo 0) - start)); }

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" 2>/dev/null | cut -d" " -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" 2>/dev/null | cut -d" " -f1
    else
        echo ""
    fi
}

verify() {
    got=$(sha_of "$1")
    [ -n "$got" ] || { say "[FETCH] FAIL: no sha256 tool available; refusing to use an unverified payload"; return 1; }
    if [ "$got" != "$2" ]; then
        say "[FETCH] FAIL: sha256 mismatch for $3"
        say "[FETCH]   expected $2"
        say "[FETCH]   got      $got"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- one artifact
# fetch_one <name> <url> <sha256> <mode>
#   mode=file  -> $DEST_DIR/<name> is the downloaded file
#   mode=untar -> $DEST_DIR/<name> is downloaded and unpacked into $DEST_DIR
fetch_one() {
    _name="$1"; _url="$2"; _sha="$3"; _mode="${4:-file}"
    _dest="$DEST_DIR/$_name"
    _stamp="$DEST_DIR/.ncz-fetched-$_name.ok"

    if [ "$_mode" = untar ]; then
        if [ -f "$_stamp" ] && [ "$(cat "$_stamp" 2>/dev/null)" = "$_sha" ]; then
            say "[FETCH] skip $_name: already fetched and unpacked (sha256=$_sha)"
            return 0
        fi
    elif [ -f "$_dest" ] && verify "$_dest" "$_sha" "$_name"; then
        say "[FETCH] skip $_name: already present and verified"
        return 0
    fi

    # The staging dir must exist BEFORE any fetch: the r159 stub creates
    # $NCZ_FETCH_TMPDIR as a sibling of the writable staging root, but a
    # direct invocation (tests, manual re-runs) may point it at a path that
    # does not exist yet. mkdir -p is a no-op when it already does.
    mkdir -p "$TMPDIR_FETCH" 2>/dev/null || true
    _part="$TMPDIR_FETCH/ncz-fetch.$$.part"
    _got_sz=""
    _attempt=1
    while [ "$_attempt" -le "$MAX_TRIES" ]; do
        if [ "$(elapsed)" -gt "$OVERALL_TIMEOUT" ]; then
            say "[FETCH] FAIL: $_name -- overall timeout ${OVERALL_TIMEOUT}s exceeded after ${_attempt} attempt(s)"
            break
        fi
        if [ -s "$_part" ]; then
            _got_sz=$(wc -c < "$_part" 2>/dev/null | tr -d " ")
            say "[FETCH] $_name attempt $_attempt: resuming from ${_got_sz} bytes"
            busybox wget -q -c --timeout="$CONNECT_TIMEOUT" -O "$_part" "$_url" 2>/dev/null
        else
            say "[FETCH] $_name attempt $_attempt: starting fresh"
            busybox wget -q --timeout="$CONNECT_TIMEOUT" -O "$_part" "$_url" 2>/dev/null
        fi
        _rc=$?

        if [ -s "$_part" ] && verify "$_part" "$_sha" "$_name"; then
            say "[FETCH] $_name verified sha256=$_sha ($(elapsed)s)"
            if [ "$_mode" = untar ]; then
                say "[FETCH] $_name: unpacking into $DEST_DIR"
                if ! tar -xzf "$_part" -C "$DEST_DIR"; then
                    say "[FETCH] FAIL: could not unpack $_name into $DEST_DIR"
                    rm -f "$_part" 2>/dev/null
                    return 1
                fi
                printf '%s\n' "$_sha" > "$_stamp"
                rm -f "$_part" 2>/dev/null
            else
                mkdir -p "$(dirname "$_dest")" 2>/dev/null
                if ! mv "$_part" "$_dest" 2>/dev/null; then
                    say "[FETCH] FAIL: could not place $_name at $_dest (is $DEST_DIR writable?)"
                    rm -f "$_part" 2>/dev/null
                    return 1
                fi
                sync
            fi
            say "[FETCH] OK: $_name"
            return 0
        fi

        say "[FETCH] $_name attempt $_attempt failed (rc=$_rc), backing off"
        _attempt=$((_attempt + 1))
        sleep $((_attempt * 5 > 30 ? 30 : _attempt * 5))
    done

    _sz=""
    [ -f "$_part" ] && _sz=$(wc -c < "$_part" 2>/dev/null | tr -d " ")
    say "[FETCH] HARD FAIL: could not fetch a verified $_name after ${_attempt} attempt(s) in $(elapsed)s"
    [ -n "$_sz" ] && say "[FETCH]   partial: ${_sz} bytes (discarded, never installed)"
    say "[FETCH]   url: $_url"
    rm -f "$_part" 2>/dev/null
    return 1
}

# ------------------------------------------------------------------ readiness --
# Probe each resolver separately so a failure says WHICH resolver is broken
# instead of a generic "network error".
ready=0
for h in $(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | head -3); do
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w "$CONNECT_TIMEOUT" "$h" 53 2>/dev/null; then ready=1; break; fi
    fi
done
[ "$ready" = 1 ] || say "[FETCH] WARN: no DNS resolver answered on port 53 within ${CONNECT_TIMEOUT}s"

# -------------------------------------------------------------------- manifest --
# Refuse to start writing into a destination we cannot write. The install
# medium is mounted read-only; finding that out after a multi-GB download is
# the worst possible time to find out.
mkdir -p "$DEST_DIR" 2>/dev/null
if [ ! -d "$DEST_DIR" ] || [ ! -w "$DEST_DIR" ]; then
    say "[FETCH] FATAL: payload destination $DEST_DIR is not writable -- cannot fetch the Magnetar payload"
    say "[FETCH] No root filesystem was installed."
    exit 1
fi

if [ -f "$MANIFEST" ]; then
    say "[FETCH] manifest $MANIFEST (dest=$DEST_DIR tries=$MAX_TRIES overall=${OVERALL_TIMEOUT}s)"
    _n=0
    # TAB-separated; blank lines and #-comments ignored. IFS is set per-field so
    # the read does not word-split a URL that legitimately contains spaces.
    while IFS="$(printf '\t')" read -r _name _url _sha _mode; do
        case "$_name" in ''|\#*) continue ;; esac
        [ -n "$_url" ] && [ -n "$_sha" ] || {
            say "[FETCH] FATAL: malformed manifest line for '$_name' (need name<TAB>url<TAB>sha256<TAB>mode)"
            exit 1
        }
        _n=$((_n + 1))
        say "[FETCH] artifact $_n: $_name"
        fetch_one "$_name" "$_url" "$_sha" "$_mode" || {
            say "[FETCH] FATAL: required online artifact $_name could not be fetched and verified."
            say "[FETCH] No root filesystem was installed."
            exit 1
        }
    done < "$MANIFEST"
    say "[FETCH] all manifest artifacts fetched and verified ($(elapsed)s)"
    exit 0
fi

# ------------------------------------------------- single-artifact fallback --
: "${NCZ_PAYLOAD_URL:?NCZ_PAYLOAD_URL required (no manifest at $MANIFEST)}"
: "${NCZ_PAYLOAD_SHA256:?NCZ_PAYLOAD_SHA256 required (no manifest at $MANIFEST)}"
: "${NCZ_PAYLOAD_NAME:=base.squashfs}"
say "[FETCH] start url=$NCZ_PAYLOAD_URL dest=$DEST_DIR tries=$MAX_TRIES overall=${OVERALL_TIMEOUT}s"
if ! fetch_one "$NCZ_PAYLOAD_NAME" "$NCZ_PAYLOAD_URL" "$NCZ_PAYLOAD_SHA256" file; then
    say "[FETCH] This install needs the network for the Magnetar payload."
    say "[FETCH] No root filesystem was installed."
    exit 1
fi
exit 0