#!/bin/bash
# test-telnet-inetd.sh -- the LAN telnet recovery console on :23 must exec a
# telnetd that exists (r201).
#
# Every reflashed r200 machine (CHIMERA, PEGASUS, MS-R1, O6N) accepted on :23
# and inetd then logged "execv /usr/sbin/in.telnetd: No such file or
# directory": 36-telemetry.sh hardcoded in.telnetd while forky's
# inetutils-telnetd ships /usr/sbin/telnetd only. This test runs the shared
# helper (post-install/lib/telnet-inetd.sh) against fixture roots and checks,
# for every ACTIVE telnet line in the result, that the exec path (and the tcpd
# target, when wrapped) exists in that root. The same checker is run on the
# pre-fix line as a negative control, so it is proven to fail on a missing path.
#
# Run: bash build/test-telnet-inetd.sh     Exit 0 = pass, 1 = a case failed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
LIB="$ROOT/post-install/lib/telnet-inetd.sh"
[ -r "$LIB" ] || { echo "FATAL: $LIB missing" >&2; exit 2; }
W="$(mktemp -d -t telnet-inetd.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

# check_exec ROOT -> 0 when every active telnet line's server path exists in ROOT
check_exec() {
    local r="$1" n=0 line srv arg
    while IFS= read -r line; do
        n=$((n + 1))
        # shellcheck disable=SC2086
        set -- $line
        srv="${6:-}"; arg="${7:-}"
        [ -x "$r$srv" ] || { echo "missing exec path $srv"; return 1; }
        case "$srv" in */tcpd) [ -x "$r$arg" ] || { echo "tcpd target $arg missing"; return 1; } ;; esac
    done < <(grep -E '^[[:space:]]*telnet[[:space:]]' "$r/etc/inetd.conf" 2>/dev/null)
    [ "$n" -eq 1 ] || { echo "expected exactly 1 active telnet line, found $n"; return 1; }
    return 0
}
mkroot() {   # mkroot NAME BIN... -> fixture root with executable stubs
    local r="$W/$1"; shift
    mkdir -p "$r/etc" "$r/usr/sbin"
    for b in "$@"; do mkdir -p "$r$(dirname "$b")"; printf '#!/bin/sh\n' > "$r$b"; chmod 0755 "$r$b"; done
    echo "$r"
}
# POSIX sh, as late.sh runs it through `chroot /target sh -c` (dash on Debian)
fix() { sh -c '. "$1" && ncz_telnet_inetd_fix "$2"' fix "$LIB" "$1" >/dev/null 2>&1; }

echo "=== negative control: the checker fails on the pre-fix line ==="
r=$(mkroot ctl /usr/sbin/telnetd)
echo 'telnet stream tcp nowait root /usr/sbin/in.telnetd in.telnetd' > "$r/etc/inetd.conf"
out=$(check_exec "$r") && bad "checker accepted an exec path that does not exist" || ok "checker rejects the r200 line ($out)"

echo "=== forky layout: /usr/sbin/telnetd only, stale in.telnetd line ==="
r=$(mkroot forky /usr/sbin/telnetd)
printf '# comment\nfinger stream tcp nowait nobody /usr/sbin/in.fingerd in.fingerd\ntelnet stream tcp nowait root /usr/sbin/in.telnetd in.telnetd\n' > "$r/etc/inetd.conf"
fix "$r" && ok "helper returns 0" || bad "helper failed"
out=$(check_exec "$r") && ok "the active telnet line execs an existing binary" || bad "$out" "$(cat "$r/etc/inetd.conf")"
grep -qE '^telnet	stream	tcp	nowait	root	/usr/sbin/telnetd	telnetd$' "$r/etc/inetd.conf" && ok "line is: telnet ... root /usr/sbin/telnetd telnetd" || bad "unexpected line" "$(cat "$r/etc/inetd.conf")"
grep -q '^#<ncz-disabled># telnet .*in.telnetd' "$r/etc/inetd.conf" && ok "stale in.telnetd line kept, disabled" || bad "stale line not disabled" "$(cat "$r/etc/inetd.conf")"
grep -q '^finger stream' "$r/etc/inetd.conf" && grep -q '^# comment' "$r/etc/inetd.conf" && ok "other services and comments untouched" || bad "unrelated lines changed"
cp "$r/etc/inetd.conf" "$W/once"; fix "$r"; cmp -s "$W/once" "$r/etc/inetd.conf" && ok "idempotent (second run changes nothing)" || bad "second run changed the file" "$(diff "$W/once" "$r/etc/inetd.conf")"

echo "=== package default: tcpd-wrapped line, no tcpd installed ==="
r=$(mkroot tcpd /usr/sbin/telnetd)
printf 'telnet\tstream\ttcp\tnowait\troot\t/usr/sbin/tcpd\t/usr/sbin/telnetd\n' > "$r/etc/inetd.conf"
fix "$r"; out=$(check_exec "$r") && ok "tcpd-wrapped line replaced by a direct one" || bad "$out" "$(cat "$r/etc/inetd.conf")"

echo "=== no inetd.conf yet ==="
r=$(mkroot empty /usr/sbin/telnetd)
fix "$r"; out=$(check_exec "$r") && ok "line created from scratch" || bad "$out"

echo "=== a correct existing line is kept, duplicates disabled ==="
r=$(mkroot dup /usr/sbin/telnetd)
printf 'telnet stream tcp nowait root /usr/sbin/telnetd telnetd\ntelnet stream tcp nowait root /usr/sbin/telnetd telnetd\n' > "$r/etc/inetd.conf"
fix "$r"; out=$(check_exec "$r") && ok "exactly one active line after dedupe" || bad "$out" "$(cat "$r/etc/inetd.conf")"

echo "=== legacy layout: in.telnetd present ==="
r=$(mkroot legacy /usr/sbin/in.telnetd)
: > "$r/etc/inetd.conf"
fix "$r"; grep -qE '	/usr/sbin/in.telnetd	in.telnetd$' "$r/etc/inetd.conf" && ok "uses in.telnetd where it exists" || bad "did not pick in.telnetd" "$(cat "$r/etc/inetd.conf")"

echo "=== no telnetd at all ==="
r=$(mkroot none)
echo 'telnet stream tcp nowait root /usr/sbin/in.telnetd in.telnetd' > "$r/etc/inetd.conf"
cp "$r/etc/inetd.conf" "$W/before"
if fix "$r"; then bad "helper claimed success with no telnetd binary"; else ok "returns 1 so the caller uses its busybox fallback"; fi
cmp -s "$W/before" "$r/etc/inetd.conf" && ok "inetd.conf untouched when there is nothing to exec" || bad "inetd.conf modified"

echo "=== no shipped writer hardcodes an in.telnetd inetd line ==="
hits=$(grep -rnE 'nowait[[:space:]]+root[[:space:]]+/usr/sbin/in\.telnetd' "$ROOT/post-install" "$ROOT/preseed" "$ROOT/build" 2>/dev/null \
       | grep -v -e '/build/test-telnet-inetd.sh:' -e '/post-install/lib/telnet-inetd.sh:' || true)
[ -z "$hits" ] && ok "no hardcoded in.telnetd inetd line" || bad "hardcoded in.telnetd line(s) remain" "$hits"
for f in post-install/36-telemetry.sh preseed/late.sh build/build-rescue-rootfs.sh post-install/72-rescue-partition.sh; do
    grep -q 'ncz_telnet_inetd_fix' "$ROOT/$f" && ok "$f uses the shared helper" || bad "$f does not call ncz_telnet_inetd_fix"
done

echo "telnet inetd tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
