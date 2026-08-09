#!/bin/bash
# Deploy zoder + zeroclaw to a Sky1 host so agents can work ON the hardware.
#
#   usage: deploy-agents.sh <target>        target: o6n | cixmini | <user@host>
#
# Why this exists: a zoder run dispatched from TYDEUS to diagnose a GStreamer
# failure on the O6 could not reach the board - no credential - so it fell back
# to reading driver source statically and produced a confident, precisely
# cited, WRONG root cause (it quoted two mvx_clear_bit() lines without noticing
# the `} else {` that scopes them to JPEG sessions). The actual answer took
# four commands run ON the board. An agent that cannot touch the hardware it is
# reasoning about will invent; give it the hardware.
#
# The binaries are built on TYDEUS (glibc 2.39). Both Sky1 targets run newer
# glibc (2.42 board, 2.43 cixmini), and glibc is forward compatible, so they
# run as-is. The reverse would not work, so the check below is not decoration:
# a binary built on cixmini will NOT run on the board.
set -u

SRCHOST="jasonperlow@192.168.207.73"          # TYDEUS: where the binaries live
case "${1:-}" in
    o6n)     TARGET="root@192.168.207.3" ;;
    cixmini) TARGET="jasonperlow@192.168.207.66" ;;
    "")      echo "usage: $0 <o6n|cixmini|user@host>"; exit 1 ;;
    *)       TARGET="$1" ;;
esac
echo "  source: $SRCHOST"
echo "  target: $TARGET"

# --- glibc gate -------------------------------------------------------------
need=$(ssh "$SRCHOST" 'objdump -T ~/.local/bin/zoder 2>/dev/null | grep -oE "GLIBC_2\.[0-9]+" | sort -uV | tail -1 | cut -d_ -f2')
have=$(ssh "$TARGET" 'ldd --version | head -1 | grep -oE "[0-9]+\.[0-9]+$"')
echo "  zoder needs glibc $need; target has $have"
if [ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | tail -1)" != "$have" ]; then
    echo "  REFUSING: target glibc $have is older than the $need the binary needs."
    echo "  Rebuild on a host with glibc <= $have, or the binary will not load."
    exit 2
fi

# --- ship -------------------------------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for b in zoder zeroclaw; do
    if ssh "$SRCHOST" "test -x ~/.local/bin/$b"; then
        scp -q "$SRCHOST:~/.local/bin/$b" "$TMP/$b"
        echo "  fetched $b ($(du -h "$TMP/$b" | cut -f1))"
    else
        echo "  skip $b (not present on source)"
    fi
done

scp -q "$SRCHOST:~/.zoder/config.toml" "$TMP/config.toml" 2>/dev/null && echo "  fetched zoder config"

# Install to /usr/local/bin so root and the desktop user both get it, and keep
# the config per-user because it can hold credentials.
TUSER="${TARGET%@*}"
ssh "$TARGET" 'mkdir -p ~/.zoder' 2>/dev/null
for b in zoder zeroclaw; do
    [ -f "$TMP/$b" ] || continue
    scp -q "$TMP/$b" "$TARGET:/tmp/$b.new"
    if [ "$TUSER" = "root" ]; then
        ssh "$TARGET" "install -m755 /tmp/$b.new /usr/local/bin/$b && rm -f /tmp/$b.new"
    else
        ssh "$TARGET" "sudo install -m755 /tmp/$b.new /usr/local/bin/$b && rm -f /tmp/$b.new" 2>/dev/null \
          || ssh "$TARGET" "mkdir -p ~/.local/bin && install -m755 /tmp/$b.new ~/.local/bin/$b && rm -f /tmp/$b.new"
    fi
    echo "  installed $b"
done
[ -f "$TMP/config.toml" ] && scp -q "$TMP/config.toml" "$TARGET:~/.zoder/config.toml" && echo "  installed zoder config"

# --- prove it actually runs -------------------------------------------------
# Copying a binary is not deploying it. A version string that comes back is the
# only evidence the loader accepted it on this glibc.
echo "=== verification ==="
for b in zoder zeroclaw; do
    v=$(ssh "$TARGET" "PATH=/usr/local/bin:\$HOME/.local/bin:\$PATH command -v $b >/dev/null 2>&1 && PATH=/usr/local/bin:\$HOME/.local/bin:\$PATH $b --version 2>&1 | head -1")
    if [ -n "$v" ]; then
        echo "  $b: $v"
    else
        echo "  $b: NOT RUNNABLE on target"
    fi
done
