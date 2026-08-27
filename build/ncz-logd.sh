#!/bin/bash
# ncz-logd.sh — remote syslog collector for NCZ installer diagnostics.
# Listens on UDP :5514 and appends raw syslog datagrams to
# ~/cixmini-install-logs/install-<date>.log. Idempotent.
set -uo pipefail
PORT="${1:-5514}"
DIR="$HOME/cixmini-install-logs"
mkdir -p "$DIR"
LOG="$DIR/install-$(date +%Y%m%d).log"
PIDF="$DIR/ncz-logd.pid"

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; then
    echo "ncz-logd already running (pid $(cat "$PIDF")) -> $LOG"
    exit 0
fi

nohup socat -u UDP-RECV:"$PORT",reuseaddr OPEN:"$LOG",creat,append >/dev/null 2>&1 &
echo $! > "$PIDF"
sleep 1
if kill -0 "$(cat "$PIDF")" 2>/dev/null; then
    echo "ncz-logd started pid $(cat "$PIDF") on UDP :$PORT -> $LOG"
else
    echo "ncz-logd FAILED to start" >&2; exit 1
fi
