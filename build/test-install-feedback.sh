#!/bin/bash
# test-install-feedback.sh -- long/visible post-install steps must say what they
# are doing (operator 2026-10-10: "we need more installation feedback").
#
#   1. lib/progress-msg.sh writes a correct INFO record into run-all.sh's
#      progress protocol (progress.state/progress.tsv) and mirrors the line to
#      the d-i log VT, in the same 10-field layout apt-progress-shim uses.
#   2. every milestone hook under test sources the helper and emits its line.
#   3. the emitted text is ASCII (newt draws anything else as <ERR>) and fits.
#   4. run-all.sh end to end: the milestone INFO rows appear in hook order.
#
# Scratch lives under $TMPDIR (local disk, never a tmpfs).
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/post-install/lib/progress-msg.sh"
RUNALL="$ROOT/post-install/run-all.sh"

W="$(mktemp -d "${TMPDIR:-/var/tmp}/install-feedback.XXXXXX")"
BGPIDS=""
SHIMDIR_PREEXISTED=0; [ -e /tmp/ncz-apt-shim ] && SHIMDIR_PREEXISTED=1
cleanup() {
    for p in $BGPIDS; do kill "$p" 2>/dev/null; done
    rm -rf "$W"
    [ "$SHIMDIR_PREEXISTED" = 1 ] || rmdir /tmp/ncz-apt-shim 2>/dev/null || true
}
trap cleanup EXIT

PASS=0; FAILS=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; FAILS=$((FAILS + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

[ -f "$LIB" ] || { echo "FAIL  $LIB is missing"; exit 1; }

# ------------------------------------------------------------ 1. helper protocol
S="$W/unit"; mkdir -p "$S"
(
    export NCZ_PROGRESS_FILE="$S/state" NCZ_PROGRESS_LOG="$S/tsv" \
           NCZ_PROGRESS_PHASE=optional NCZ_PROGRESS_INDEX=7 NCZ_PROGRESS_TOTAL=58 \
           NCZ_PROGRESS_HOOK=13-firmware-bom.sh NCZ_PROGRESS_STARTED=1700000000 \
           NCZ_TTY="$S/tty"
    # shellcheck source=/dev/null
    . "$LIB"
    ncz_msg "Firmware: installing 40 packages from the offline mirror (about 1 minute)"
)
check "ncz_msg writes an INFO record with the progress.tsv field layout" \
    grep -q '^1700000000|[0-9]*|INFO|optional|7|58|13-firmware-bom.sh|||Firmware: installing 40 packages from the offline mirror' "$S/tsv"
check "ncz_msg updates progress.state with the same record" \
    grep -q '|INFO|optional|7|58|13-firmware-bom.sh|' "$S/state"
check "ncz_msg mirrors the line to the d-i log VT with the hook name" \
    grep -q '\[13-firmware-bom.sh\] Firmware: installing 40 packages' "$S/tty"
check "ncz_msg is a silent no-op with no progress context (unit tests, first boot)" \
    sh -c 'env -i PATH="$PATH" bash -c ". \"$1\"; ncz_msg hi" >/dev/null 2>&1; exit $?' _ "$LIB"

# ------------------------------------------------ 2. milestone hooks emit a line
msg_of() {  # msg_of <hook-without-.sh>
    grep -hoE 'ncz_msg "[^"]+"' "$ROOT/post-install/$1.sh" | head -1
}
for spec in \
    "13-firmware-bom:Firmware: installing" \
    "10-amd64-kernel:Kernel: installing the NCZ amd64 kernel" \
    "10-our-kernel:Kernel: installing the NCZ kernel" \
    "20-desktop:Desktop: installing the desktop" \
    "45-wallpaper-rotator:Wallpapers: installing" \
    "60-boot-splash:Boot splash: removing Plymouth" \
    "70-bootloader:Bootloader: writing rEFInd" \
    "72-rescue-partition:Rescue: populating" \
    "97-firstboot-report:First boot: staging" ; do
    hook="${spec%%:*}"; want="${spec#*:}"
    f="$ROOT/post-install/$hook.sh"
    check "$hook.sh sources lib/progress-msg.sh" \
        grep -q 'lib/progress-msg.sh' "$f"
    check "$hook.sh emits a milestone line ($want)" \
        sh -c 'grep -q "ncz_msg \"$2" "$1"' _ "$f" "$want"
done

# non-ASCII anywhere in an emitted ncz_msg string would render as <ERR>
ascii_ok() {
    local f out
    for f in "$ROOT"/post-install/*.sh; do
        out=$(grep -hoE 'ncz_msg "[^"]+"' "$f" 2>/dev/null || true)
        [ -n "$out" ] || continue
        if printf '%s' "$out" | LC_ALL=C grep -q '[^ -~]'; then
            echo "  non-ASCII in $f: $out"; return 1
        fi
    done
    return 0
}
check "every emitted milestone message is ASCII" ascii_ok

# text reached through db_subst/tty is cut at 180 in the protocol; keep messages short
len_ok() {
    local f out n
    for f in "$ROOT"/post-install/*.sh; do
        while IFS= read -r out; do
            [ -n "$out" ] || continue
            n=${#out}
            [ "$n" -le 175 ] || { echo "  too long ($n): $out"; return 1; }
        done < <(grep -hoE 'ncz_msg "[^"]+"' "$f" 2>/dev/null || true)
    done
    return 0
}
check "milestone messages fit the 180-char protocol field" len_ok

# ------------------------------------------------------------ 3. run-all order
R="$W/runall"; mkdir -p "$R/hooks/lib" "$R/log"
cp "$LIB" "$R/hooks/lib/"
for pair in "20-desktop:Desktop: installing the desktop" \
            "45-wallpaper-rotator:Wallpapers: installing" \
            "60-boot-splash:Boot splash: removing Plymouth" ; do
    h="${pair%%:*}"; m="${pair#*:}"
    {
        echo '#!/bin/bash'
        echo '_pm="$(dirname "$0")/lib/progress-msg.sh"; [ -r "$_pm" ] && . "$_pm"'
        echo "command -v ncz_msg >/dev/null 2>&1 && ncz_msg \"$m now\""
        echo 'sleep 0.1'
    } > "$R/hooks/$h.sh"
done
(
    cd "$R/hooks" || exit 1
    env NCZ_LOGDIR="$R/log" NCZ_HOOK_DIR="$R/hooks" NCZ_TTY=/dev/null \
        NCZ_TARGET_ARCH=amd64 NCZ_DISABLE_APT_SHIM=1 \
        bash "$RUNALL" > "$R/runall.out" 2>&1
)
RT="$R/log/progress.tsv"
check "run-all: firmware/desktop/wallpaper/splash INFO rows are written" \
    sh -c 'grep -q "|INFO|optional|.*|20-desktop.sh|||Desktop: installing" "$1" && \
           grep -q "|INFO|optional|.*|45-wallpaper-rotator.sh|||Wallpapers: installing" "$1" && \
           grep -q "|INFO|optional|.*|60-boot-splash.sh|||Boot splash: removing Plymouth" "$1"' _ "$RT"
check "run-all: the milestone rows appear in hook order" \
    sh -c 'a=$(grep -n "Desktop: installing" "$1" | head -1 | cut -d: -f1); \
           b=$(grep -n "Wallpapers: installing" "$1" | head -1 | cut -d: -f1); \
           c=$(grep -n "Boot splash" "$1" | head -1 | cut -d: -f1); \
           [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]' _ "$RT"
check "run-all: milestone rows are INFO (never FAIL/WARN from a hook)" \
    sh -c 'awk -F"|" "\$3==\"INFO\" && (\$10 ~ /Desktop: installing/ || \$10 ~ /Wallpapers: installing/ || \$10 ~ /Boot splash/)" "$1" | grep -q . && \
           ! awk -F"|" "\$3==\"FAIL\"" "$1" | grep -q .' _ "$RT"

echo
echo "test-install-feedback: $PASS passed, $FAILS failed"
[ "$FAILS" = 0 ]
