#!/bin/bash
# test-hooks-fail-loudly.sh -- round-2 review fixes (r201): failures that used to end in a quiet exit 0.
#  * 86-cix-dkms-register.sh: a failed aipu dkms build must exit non-zero (real hook, sandboxed, fake dkms)
#  * 36-telemetry.sh rsyslog block and 55-t2-firmware.sh package block: the apt status behind `| tail` is
#    really read (PIPESTATUS), so the WARN / failure fires (real blocks, extracted by marker)
#  * build/lib/deb-version-gate.sh fails CLOSED when the published index is unreachable, unless
#    NCZ_VERSION_GATE_STRICT=0 is set explicitly
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/failloud.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# ---------- 86: aipu build failure ----------
HOOK86="${NCZ_HOOK86_UNDER_TEST:-$ROOT/post-install/86-cix-dkms-register.sh}"
KV=7.3.0-rc6-sky1-ncz
mk86() {  # <name> <headers: yes|no> <dkms build rc>
    local b="$T/$1"
    mkdir -p "$b/bin" "$b/usr/local/lib/cix-installer" "$b/usr/src/aipu-6.2.0" "$b/lib/modules/$KV"
    echo "$KV" > "$b/usr/local/lib/cix-installer/KVER_NEXT"; echo x > "$b/usr/src/aipu-6.2.0/dkms.conf"
    [ "$2" = yes ] && { mkdir -p "$b/lib/modules/$KV/build"; echo x > "$b/lib/modules/$KV/build/Makefile"; }
    printf '#!/bin/sh\ncase "$1" in --print-architecture) echo arm64 ;; *) exit 0 ;; esac\n' > "$b/bin/dpkg"
    cat > "$b/bin/dkms" <<SH
#!/bin/sh
case "\$1" in build) exit $3 ;; *) exit 0 ;; esac
SH
    chmod +x "$b/bin/"*
    sed -E "s#(^|[^A-Za-z0-9_./\$-])/(etc|usr|var|lib)/#\1$b/\2/#g" "$HOOK86" > "$b/hook.sh"
    env -i PATH="$b/bin:/usr/bin:/bin" bash "$b/hook.sh" >"$b/out" 2>&1; echo $? > "$b/rc"
}
mk86 fail yes 2
if [ "$(cat "$T/fail/rc")" != 0 ] && grep -q 'FAILED: aipu/6.2.0 did not build' "$T/fail/out"; then ok "86: a failed aipu build exits non-zero and says so"
else bad "86: failed aipu build still exits $(cat "$T/fail/rc")"; tail -5 "$T/fail/out"; fi
mk86 good yes 0
[ "$(cat "$T/good/rc")" = 0 ] && grep -q 'dkms built+installed aipu/6.2.0' "$T/good/out" && ok "86: a successful build exits 0" || { bad "86: good build rc $(cat "$T/good/rc")"; tail -5 "$T/good/out"; }
mk86 nohdr no 2
[ "$(cat "$T/nohdr/rc")" = 0 ] && grep -q 'no kernel headers' "$T/nohdr/out" && ok "86: no headers (deferred to a kernel upgrade) is not a failure" || { bad "86: no-headers case rc $(cat "$T/nohdr/rc")"; tail -3 "$T/nohdr/out"; }

# ---------- 36 / 55: apt status behind | tail ----------
mkdir -p "$T/bin"
cat > "$T/bin/apt-get" <<'SH'
#!/bin/sh
echo "E: Unable to locate package x" >&2; exit 100
SH
printf '#!/bin/sh\nexit 1\n' > "$T/bin/dpkg-query"; chmod +x "$T/bin/"*
run_block() {  # <hook> <marker> <prelude>
    sed -n "/^[[:space:]]*# BEGIN $2\$/,/^[[:space:]]*# END $2\$/p" "$1" > "$T/blk.sh"
    [ -s "$T/blk.sh" ] || { echo "NOBLOCK"; return 1; }
    env -i PATH="$T/bin:/usr/bin:/bin" bash -c "set +e; $3; . '$T/blk.sh'; echo \"T2_PKG_FAIL=\${T2_PKG_FAIL:-}\"" 2>&1
}
o="$(run_block "$ROOT/post-install/36-telemetry.sh" rsyslog-status 'true')"
echo "$o" | grep -q 'WARN: rsyslog install failed (rc=100)' && ok "36: a failed rsyslog install now prints its WARN" || { bad "36: WARN did not fire"; echo "$o"; }
o="$(run_block "$ROOT/post-install/55-t2-firmware.sh" t2-pkg-status 'true')"
echo "$o" | grep -q 'ERROR: /usr/bin/get-apple-firmware is not installed' && echo "$o" | grep -q 'T2_PKG_FAIL=1' && ok "55: missing T2 native assets are detected (flag set, error printed)" || { bad "55: failure not detected"; echo "$o"; }
grep -q 'exit 1' <(sed -n '/T2_PKG_FAIL" = 1/,/^fi$/p' "$ROOT/post-install/55-t2-firmware.sh") && ok "55: the hook exits 1 when the flag is set" || bad "55: no exit 1 on T2_PKG_FAIL"
# control: the old shape really could not fire
printf '#!/bin/bash\nset +e\napt-get install x 2>&1 | tail -3 || echo OLDWARN\n' > "$T/old.sh"
env -i PATH="$T/bin:/usr/bin:/bin" bash "$T/old.sh" 2>&1 | grep -q OLDWARN && bad "control: old shape fired" || ok "control: the old '| tail || echo WARN' shape never fires (why it was wrong)"

# ---------- version gate fails closed ----------
if command -v dpkg-deb >/dev/null; then
    mkdir -p "$T/d/DEBIAN"; printf 'Package: gt\nVersion: 1\nArchitecture: all\nMaintainer: t <t@t>\nDescription: t\n' > "$T/d/DEBIAN/control"
    dpkg-deb -b "$T/d" "$T/gt_1_all.deb" >/dev/null 2>&1
    gate() { env -i PATH=/usr/bin:/bin NCZ_PUBLISHED_INDEX="$T/does-not-exist" "$@" bash -c ". '$ROOT/build/lib/deb-version-gate.sh'; ncz_deb_version_gate '$T/gt_1_all.deb'" 2>&1; }
    out="$(gate)"; rc=$?
    if [ $rc != 0 ] && echo "$out" | grep -q 'FAIL cannot read the published index'; then ok "version gate: unreachable index fails closed by default"; else bad "version gate did not fail closed (rc=$rc)"; echo "$out"; fi
    out="$(gate NCZ_VERSION_GATE_STRICT=0)"; rc=$?
    if [ $rc = 0 ] && echo "$out" | grep -q 'WARN published index unreachable'; then ok "version gate: NCZ_VERSION_GATE_STRICT=0 is the explicit offline override (WARN)"; else bad "override did not downgrade to WARN (rc=$rc)"; echo "$out"; fi
else echo "SKIP: dpkg-deb unavailable for the gate cases"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
