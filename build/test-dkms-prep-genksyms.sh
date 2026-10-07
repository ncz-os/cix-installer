#!/bin/bash
# test-dkms-prep-genksyms.sh -- post-install/79-dkms-prep.sh must treat
# scripts/genksyms/genksyms as a host tool whose foreign (Yocto uninative)
# build triggers the native rebuild, like fixdep and modpost.
#
# r201 arm64 KVM gate (2026-10-07): fixdep and modpost were native, genksyms was
# not; the hook said "host tools already native", and the aipu DKMS build then
# died with "/bin/sh: .../scripts/genksyms/genksyms: not found" (exit 127).
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$HERE/../post-install/79-dkms-prep.sh}"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/dkms-prep-gk.XXXXXX")"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# 1. the real hook's decision: fixdep+modpost fine, genksyms foreign -> rebuild
mkdir -p "$W/scripts/basic" "$W/scripts/mod" "$W/scripts/genksyms"
printf '#!/bin/sh\nexit 0\n' > "$W/scripts/basic/fixdep"
printf '#!/bin/sh\nexit 0\n' > "$W/scripts/mod/modpost"
printf '#!/nonexistent/uninative/ld-linux\n' > "$W/scripts/genksyms/genksyms"
chmod +x "$W"/scripts/*/*
# the hook's own tool_usable + HOST_TOOLS + need_rebuild logic, extracted verbatim
{
  sed -n '/^tool_usable() {/,/^}/p' "$HOOK"
  grep '^HOST_TOOLS=' "$HOOK"
  echo 'B="$1"; need_rebuild=0'
  echo 'for tool in ${HOST_TOOLS:-scripts/basic/fixdep scripts/mod/modpost}; do tool_usable "$B/$tool" || need_rebuild=1; done'
  echo 'echo "$need_rebuild"'
} > "$W/decide.sh"
if [ "$(bash "$W/decide.sh" "$W")" = 1 ]; then ok "foreign genksyms alone triggers the native rebuild"
else bad "foreign genksyms alone does NOT trigger the native rebuild"; fi

printf '#!/bin/sh\nexit 0\n' > "$W/scripts/genksyms/genksyms"
if [ "$(bash "$W/decide.sh" "$W")" = 0 ]; then ok "all three native -> no rebuild"
else bad "all three native but a rebuild is requested"; fi

# 2. the post-rebuild report must cover the same set
if grep -q 'for tool in \$HOST_TOOLS; do' "$HOOK" && [ "$(grep -c 'for tool in \$HOST_TOOLS; do' "$HOOK")" = 2 ]; then
    ok "check loop and post-rebuild report both use HOST_TOOLS"
else bad "check loop / post-rebuild report do not both use HOST_TOOLS"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
