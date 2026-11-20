#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checker="$repo/tools/check-internal-refs.py"

diff_fixture() {
    printf '%s\n' 'diff --git a/example b/example' '--- a/example' '+++ b/example' \
        '@@ -1,2 +1,3 @@' "-$1" " $1" '+Use a build host.' "+$2"
}

term='Hyd'
term+='ra'
model='De'
model+='ll Latitude 7440'
diff_fixture "$term" "$model" | python3 "$checker"
if result=$(diff_fixture "$term" "Use ${term}_01." | python3 "$checker"); then
    echo 'FAIL: added host name was accepted'
    exit 1
fi
[[ $result == *'example:3: internal reference'* ]]
printf '%s\n' 'diff --git a/example b/example' '--- /dev/null' \
    '+++ b/assets/kernel/mali/example' '@@ -0,0 +1 @@' "+$term" | python3 "$checker"
echo 'PASS: internal-reference diff filtering, hardware and third-party exceptions'
