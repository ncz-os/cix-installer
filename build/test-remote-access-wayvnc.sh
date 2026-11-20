#!/bin/bash
# test-remote-access-wayvnc.sh -- contract test for post-install/31-remote-access.sh
# (NG-NC-28, Wayland remote desktop): desktop variants install wayvnc (forky)
# and ship a per-user ncz-wayvnc.service unit that is installed but DISABLED
# by default, bound to the Singularity session, listening on localhost only.
# Server/headless variants skip, as today.
#
# Runs the hook against a fake root with stubbed apt-get/systemctl and asserts
# files, unit content, and that nothing is enabled. Temp dirs stay inside the
# repo checkout (job-workspace rule: no /tmp).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HOOK="$ROOT/post-install/31-remote-access.sh"
T="$(mktemp -d "$ROOT/.tmp-test-remote-access-wayvnc.XXXXXX")"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $1"; }
bad() { fail=$((fail + 1)); echo "FAIL - $1"; }

mkroot() { # $1 root, $2 variant
    mkdir -p "$1/usr/local/lib/cix-installer"
    printf '%s\n' "$2" > "$1/usr/local/lib/cix-installer/BUILD_VARIANT"
}

mkstub() { # $1 dir; stub apt-get + systemctl that log their argv, do nothing
    mkdir -p "$1"
    cat > "$1/apt-get" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NCZ_RA_APT_LOG"
exit 0
EOF
    cat > "$1/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$NCZ_RA_SYSTEMCTL_LOG"
exit 0
EOF
    chmod +x "$1"/apt-get "$1"/systemctl
}

run_hook() { # $1 root, $2 stub; runs the hook, echoes rc
    export NCZ_RA_ROOT="$1" NCZ_RA_APT_LOG="$T/apt.log" NCZ_RA_SYSTEMCTL_LOG="$T/systemctl.log"
    : > "$T/apt.log"; : > "$T/systemctl.log"
    PATH="$2:$PATH" bash "$HOOK" > "$T/hook.out" 2>&1
    echo $?
}

STUB="$T/stub"; mkstub "$STUB"

# --- 1. desktop: wayvnc installed, user unit shipped disabled ----------------
R1="$T/r-desktop"; mkroot "$R1" desktop
rc=$(run_hook "$R1" "$STUB")
[ "$rc" = 0 ] && ok "hook: desktop exits 0" || bad "hook: desktop rc=$rc"
grep -q 'wayvnc' "$T/apt.log" \
    && ok "hook: desktop installs wayvnc via apt" || bad "hook: apt log lacks wayvnc"
UNIT="$R1/usr/lib/systemd/user/ncz-wayvnc.service"
[ -f "$UNIT" ] && ok "hook: ncz-wayvnc.service installed" || bad "hook: unit missing"
grep -q 'singularity-session\.target' "$UNIT" 2>/dev/null \
    && ok "unit: bound to the Singularity session" || bad "unit: no Singularity session binding"
grep -qE '^ExecStart=/usr/bin/wayvnc 127\.0\.0\.1$' "$UNIT" 2>/dev/null \
    && ok "unit: ExecStart runs wayvnc on localhost" || bad "unit: ExecStart is not wayvnc-on-localhost"
if grep -qE '0\.0\.0\.0|[^0-9]::' "$UNIT" 2>/dev/null; then
    bad "unit: listens beyond localhost"
else
    ok "unit: localhost-only (no wildcard bind)"
fi
if grep -q 'ncz-wayvnc' "$T/systemctl.log"; then
    bad "unit: hook enabled/started ncz-wayvnc (must ship disabled)"
else
    ok "unit: installed but disabled (no systemctl call for it)"
fi
if find "$R1" -path '*wants*ncz-wayvnc*' 2>/dev/null | grep -q .; then
    bad "unit: a wants symlink enables ncz-wayvnc"
else
    ok "unit: no wants symlink (disabled by default)"
fi
# idempotent re-run keeps it disabled
rc=$(run_hook "$R1" "$STUB")
[ "$rc" = 0 ] && ok "hook: desktop re-run exits 0" || bad "hook: desktop re-run rc=$rc"
grep -q 'ncz-wayvnc' "$T/systemctl.log" \
    && bad "unit: re-run enabled/started ncz-wayvnc" \
    || ok "unit: re-run keeps it disabled"

# --- 1b. stale xrdp config: disable runs under $ROOT, never the live host ---
RX="$T/r-stale-xrdp"; mkroot "$RX" desktop
mkdir -p "$RX/etc/xrdp"
printf '#!/bin/sh\nstartxfce4\n' > "$RX/etc/xrdp/startwm.sh"
rc=$(run_hook "$RX" "$STUB")
[ "$rc" = 0 ] && ok "hook: stale-xrdp desktop exits 0" || bad "hook: stale-xrdp desktop rc=$rc"
if grep -q -- "--root=$RX" "$T/systemctl.log" && grep -q 'disable.*xrdp' "$T/systemctl.log"; then
    ok "hook: stale xrdp disabled under the target root"
else
    bad "hook: stale xrdp disable not rooted under the target root"
fi
# no stale config -> no xrdp disable at all
rc=$(run_hook "$R1" "$STUB")
[ "$rc" = 0 ] && ok "hook: clean desktop exits 0" || bad "hook: clean desktop rc=$rc"
grep -q 'xrdp' "$T/systemctl.log" \
    && bad "hook: clean root wrongly touched xrdp" \
    || ok "hook: clean root leaves xrdp alone"

# --- 2. server/headless: skip, as today ---------------------------------------
for v in server headless; do
    R="$T/r-$v"; mkroot "$R" "$v"
    rc=$(run_hook "$R" "$STUB")
    [ "$rc" = 0 ] && ok "hook: $v exits 0" || bad "hook: $v rc=$rc"
    [ -s "$T/apt.log" ] && bad "hook: $v called apt-get" || ok "hook: $v installs nothing"
    [ -e "$R/usr/lib/systemd/user/ncz-wayvnc.service" ] \
        && bad "hook: $v shipped the unit" || ok "hook: $v ships no unit"
done

# --- 3. manifest + registry provenance gate -----------------------------------
grep -qx 'wayvnc' "$ROOT/manifests/desktop.pkgs" \
    && ok "manifest: desktop.pkgs seeds wayvnc" || bad "manifest: desktop.pkgs lacks wayvnc"
grep -qx 'wayvnc' "$ROOT/manifests/desktop-amd64.pkgs" \
    && ok "manifest: desktop-amd64.pkgs seeds wayvnc" || bad "manifest: desktop-amd64.pkgs lacks wayvnc"
grep -qx 'manifests/desktop.pkgs:wayvnc' "$ROOT/sbom/expected-packages.txt" \
    && ok "sbom: expected-packages.txt pins wayvnc" || bad "sbom: expected-packages.txt lacks wayvnc"
grep -qx 'manifests/desktop-amd64.pkgs:wayvnc' "$ROOT/sbom/expected-packages-amd64.txt" \
    && ok "sbom: expected-packages-amd64.txt pins wayvnc" || bad "sbom: expected-packages-amd64.txt lacks wayvnc"
for a in "arm64	manifests/desktop.pkgs" "amd64	manifests/desktop-amd64.pkgs"; do
    arch="${a%%	*}"; prov="${a#*	}"
    if grep -qP "^wayvnc\tdebian\tdebian-forky\t$arch\tdesktop\tyes\t\tmanifest\tbuild/verify-packages.sh\t$prov" \
        "$ROOT/manifests/components.tsv"; then
        ok "registry: wayvnc $arch row cites $prov"
    else
        bad "registry: wayvnc $arch row missing or wrong"
    fi
done
grep -qP '^build/test-remote-access-wayvnc\.sh\t' "$ROOT/docs/platform-inventory.tsv" \
    && ok "inventory: this test's row" || bad "inventory: this test's row missing"

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
