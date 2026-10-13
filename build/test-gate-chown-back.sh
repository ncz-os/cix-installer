#!/bin/bash
# test-gate-chown-back.sh -- the privileged build gates must hand their run-dir
# scratch back to the invoking user on every exit path.
#
# operator 2026-10-11 "fix open items": the KVM install gate and the provenance
# gate run under ncz_sudo (as root). Everything they wrote under the run dir
# (kvm-gate/ui-check/, kvm-gate/target-logs/, prov-index/) was root-owned, so
# the build user could not `rm -rf` a finished run dir (36G stranded on a build host;
# same class as the arm64 .kdebs-tmp stray logs). build/lib/priv.sh now provides
# ncz_chown_back / ncz_trap_chown_back and each privileged script installs the
# trap. This test pins the behaviour and the wiring.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIV="$ROOT/build/lib/priv.sh"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/chownback.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# a stub chown on PATH that records its argv, so we never need real root
mkdir -p "$T/bin"
cat > "$T/bin/chown" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CHOWN_LOG"
STUB
chmod +x "$T/bin/chown"
export PATH="$T/bin:$PATH"
export CHOWN_LOG="$T/chown.log"

# shellcheck source=lib/priv.sh
. "$PRIV"
if declare -F ncz_chown_target >/dev/null && declare -F ncz_chown_back >/dev/null && declare -F ncz_trap_chown_back >/dev/null; then
    ok "priv.sh defines ncz_chown_target/ncz_chown_back/ncz_trap_chown_back"
else bad "priv.sh does not define the chown-back helpers"; fi

# 1. target resolution: explicit NCZ_CHOWN_BACK wins; SUDO_UID/SUDO_GID is next
t="$(NCZ_CHOWN_BACK=4242:4343 ncz_chown_target)"
[ "$t" = "4242:4343" ] && ok "NCZ_CHOWN_BACK sets the target" || bad "NCZ_CHOWN_BACK ignored (got '$t')"
t="$(env -u NCZ_CHOWN_BACK SUDO_UID=4242 SUDO_GID=4343 bash -c '. "'"$PRIV"'"; ncz_chown_target')"
[ "$t" = "4242:4343" ] && ok "SUDO_UID/SUDO_GID is the fallback" || bad "SUDO_UID fallback broken (got '$t')"
t="$(env -u NCZ_CHOWN_BACK -u SUDO_UID bash -c '. "'"$PRIV"'"; ncz_chown_target || echo NONE')"
[ "$t" = "NONE" ] && ok "no invoker info -> no target (a root login stays root)" || bad "chown target invented without SUDO_UID (got '$t')"

# 2. ncz_chown_back chowns -R to the target (forced as a normal user)
mkdir -p "$T/d1/sub"; : > "$T/d1/sub/f"
: > "$CHOWN_LOG"
NCZ_CHOWN_BACK_FORCE=1 NCZ_CHOWN_BACK=4242:4343 ncz_chown_back "$T/d1"
grep -Fxq -- "-R 4242:4343 $T/d1" "$CHOWN_LOG" \
    && ok "ncz_chown_back runs chown -R <target> <dir>" \
    || { bad "ncz_chown_back did not chown -R"; cat "$CHOWN_LOG"; }
: > "$CHOWN_LOG"
NCZ_CHOWN_BACK_FORCE=1 NCZ_CHOWN_BACK=4242:4343 ncz_chown_back "$T/does-not-exist"
[ ! -s "$CHOWN_LOG" ] && ok "a missing dir is skipped, never an error" || { bad "chown attempted on a missing dir"; cat "$CHOWN_LOG"; }

# 3. the EXIT trap fires on every exit path AND preserves the exit status
for spec in "0:clean exit" "7:explicit failure"; do
    rc_want="${spec%%:*}"; label="${spec#*:}"
    mkdir -p "$T/d2"; : > "$CHOWN_LOG"
    NCZ_CHOWN_BACK_FORCE=1 NCZ_CHOWN_BACK=4242:4343 bash -c '
        . "'"$PRIV"'"
        ncz_trap_chown_back "'"$T/d2"'"
        mkdir -p "'"$T/d2"'/x"; : > "'"$T/d2"'/x/f"
        exit '"$rc_want"'
    ' >/dev/null 2>&1; rc=$?
    if [ "$rc" = "$rc_want" ] && grep -Fq -- "$T/d2" "$CHOWN_LOG"; then
        ok "trap chowns and preserves the exit status ($label -> rc=$rc)"
    else bad "trap did not chown/preserve on $label (rc=$rc, want $rc_want)"; cat "$CHOWN_LOG"; fi
done

# 3b. a pre-existing EXIT trap is chained, not dropped, and the status survives
mkdir -p "$T/d3"; : > "$CHOWN_LOG"
NCZ_CHOWN_BACK_FORCE=1 NCZ_CHOWN_BACK=4242:4343 bash -c '
    . "'"$PRIV"'"
    trap "echo PREV_EXIT >> $CHOWN_LOG" EXIT
    ncz_trap_chown_back "'"$T/d3"'"
    mkdir -p "'"$T/d3"'"; : > "'"$T/d3"'/f"
    exit 5
' >/dev/null 2>&1; rc=$?
if [ "$rc" = 5 ] && grep -q PREV_EXIT "$CHOWN_LOG" && grep -Fq -- "$T/d3" "$CHOWN_LOG"; then
    ok "a pre-existing EXIT trap is chained (both run) and the status is preserved"
else bad "pre-existing EXIT trap dropped or status lost (rc=$rc)"; cat "$CHOWN_LOG"; fi

# 4. wiring: each privileged script sources the library and installs the trap
for f in build/kvm-install-gate-gpt.sh build/kvm-installer-ui-check.sh build/check-forky-provenance.sh; do
    if grep -q 'lib/priv.sh' "$ROOT/$f" && grep -q 'ncz_trap_chown_back' "$ROOT/$f"; then
        ok "$f sources priv.sh and installs the chown-back trap"
    else bad "$f does not install the chown-back trap"; fi
done
grep -q 'ncz_trap_chown_back "\$WORK"' "$ROOT/build/kvm-install-gate-gpt.sh" \
    && ok "kvm-install-gate-gpt.sh chowns its whole \$WORK (ui-check/ + target-logs/)" \
    || bad "kvm gate does not chown \$WORK"
grep -q 'CHOWN_DIRS+=' "$ROOT/build/check-forky-provenance.sh" \
    && grep -q 'ncz_trap_chown_back "${CHOWN_DIRS\[@\]}"' "$ROOT/build/check-forky-provenance.sh" \
    && ok "check-forky-provenance.sh chowns --work and --index-dir" \
    || bad "provenance wrapper does not collect/chown its dirs"
if [ "$(grep -c "NCZ_CHOWN_BACK='\$invoker'" "$ROOT/build/build-image.sh")" -ge 2 ]; then
    ok "build-image.sh passes the invoking user to both sudo'd gates"
else bad "build-image.sh does not pass NCZ_CHOWN_BACK to both gates"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
