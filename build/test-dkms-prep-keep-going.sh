#!/bin/bash
# test-dkms-prep-keep-going.sh -- regression test for post-install/79-dkms-prep.sh:
# its modules_prepare run must keep going past unrelated failures so that
# scripts/mod/modpost is still built.
#
# With pahole installed, modules_prepare on the shipped header tree also tries
# tools/bpf/resolve_btfids, which cannot build (no tools/ sources). Without -k a
# parallel make stopped starting new jobs at that failure and modpost was never
# built, so every DKMS build failed (2026-10-06 arm64 KVM gate, aipu).
#
# Runs the hook's own make command (extracted) against a fake kbuild tree in
# which one prerequisite fails immediately and modpost is built a moment later.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
HOOK="$HERE/../post-install/79-dkms-prep.sh"
W="$(mktemp -d -t dkms-prep.XXXXXX)"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0

# the make invocation exactly as the hook runs it (inside ncz_prepare_pristine,
# which snapshots and restores the kernel configuration around it)
CMD="$(python3 - "$HOOK" <<'EOF'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'\n\s*(make -k -C "\$_np_b" [^\n]*modules_prepare)', s)
print(m.group(1) if m else "")
EOF
)"
[ -n "$CMD" ] || { echo "FAIL: modules_prepare make command not found in $HOOK"; exit 1; }

mktree() {   # $1 dir: fake tree, resolve_btfids fails at once, modpost appears after 1s
    mkdir -p "$1/scripts/mod"
    cat > "$1/Makefile" <<'MK'
modules_prepare: resolve_btfids modpost
resolve_btfids:
	@echo "No rule to make target '../../scripts/utilities.mak'" >&2; false
modpost: slow_prereq
	@touch scripts/mod/modpost
slow_prereq:
	@sleep 1
MK
}

run() {   # $1 make command  $2 tree
    _np_b="$2" LOG="$2/make.log" bash -c "$1 >>\"\$LOG\" 2>&1" || true
}

mktree "$W/hook"
run "$CMD" "$W/hook"
if [ -f "$W/hook/scripts/mod/modpost" ]; then
    pass=$((pass+1)); echo "PASS: hook's modules_prepare builds modpost past a failing prerequisite"
else
    fail=$((fail+1)); echo "FAIL: hook's modules_prepare left modpost unbuilt ($CMD)"
fi

# control: the same command without -k must lose modpost, or this test proves nothing
mktree "$W/ctl"
run "${CMD/make -k /make }" "$W/ctl"
if [ ! -f "$W/ctl/scripts/mod/modpost" ]; then
    pass=$((pass+1)); echo "PASS: control without -k leaves modpost unbuilt"
else
    fail=$((fail+1)); echo "FAIL: control without -k built modpost anyway (fixture does not reproduce)"
fi

echo "test-dkms-prep-keep-going: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
