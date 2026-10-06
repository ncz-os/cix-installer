#!/bin/bash
# test-apt-sources-offline-canary.sh -- regression test for the ncz-screensavers
# live-update canary in post-install/24-apt-sources.sh.
#
# An offline install (NIC up, no internet) resolves ncz-screensavers only from
# the /cdrom pool. apt-cache policy prints that origin as "file:/cdrom" (one
# slash); the canary matched only "file:///cdrom", fell through to FATAL, and
# 10-our-kernel (which runs this hook) failed the whole install. Extracts the
# canary block, stubs apt-cache with recorded policy shapes, checks the verdicts.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOOK="$HERE/../post-install/24-apt-sources.sh"
W="$(mktemp -d -t apt-canary.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0

python3 - "$HOOK" > "$W/canary.sh" <<'EOF'
import sys
s = open(sys.argv[1]).read()
a = s.index('echo "[24] verifying NCZ-OS apt sources carry ncz-screensavers')
b = s.index("\nfi\n", s.index("apt-cache not on PATH", a)) + 4
print(s[a:b])
EOF

policy() {   # $1 case -> apt-cache policy ncz-screensavers output
    case "$1" in
        network) printf '%s\n' 'ncz-screensavers:' '  Installed: (none)' '  Candidate: 0.8.10' '  Version table:' \
                     '     0.8.10 500' '        500 https://packages.buildkite.com/ncz-os/ncz/any any/main arm64 Packages' \
                     '        500 file:/cdrom forky/main arm64 Packages' ;;
        offline) printf '%s\n' 'ncz-screensavers:' '  Installed: (none)' '  Candidate: 0.8.10' '  Version table:' \
                     '     0.8.10 500' '        500 file:/cdrom forky/main arm64 Packages' ;;
        foreign) printf '%s\n' 'ncz-screensavers:' '  Installed: (none)' '  Candidate: 0.8.10' '  Version table:' \
                     '     0.8.10 500' '        500 https://example.invalid/debian forky/main arm64 Packages' ;;
        none)    printf '%s\n' 'ncz-screensavers:' '  Installed: (none)' '  Candidate: (none)' ;;
    esac
}

run_case() {   # $1 case  $2 wanted rc  $3 wanted log pattern
    mkdir -p "$W/bin-$1"
    policy "$1" > "$W/policy-$1.txt"
    printf '#!/bin/sh\ncat "%s"\n' "$W/policy-$1.txt" > "$W/bin-$1/apt-cache"
    chmod +x "$W/bin-$1/apt-cache"
    local rc=0
    PATH="$W/bin-$1:$PATH" bash "$W/canary.sh" > "$W/out-$1.log" 2>&1 || rc=$?
    if [ "$rc" = "$2" ] && grep -q "$3" "$W/out-$1.log"; then
        pass=$((pass+1)); echo "PASS: $1 -> rc=$rc"
    else
        fail=$((fail+1)); echo "FAIL: $1 -> rc=$rc (want $2, log pattern '$3')"; sed 's/^/    /' "$W/out-$1.log"
    fi
}

run_case network 0 "OK: NCZ-OS apt sources carry"
run_case offline 0 "WARN: ncz-screensavers resolves only from the offline"
run_case foreign 1 "FATAL: ncz-screensavers candidate"
run_case none 1 "FATAL: no apt source"

echo "test-apt-sources-offline-canary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
