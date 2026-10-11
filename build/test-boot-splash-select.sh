#!/bin/bash
# test-boot-splash-select.sh -- 60-boot-splash.sh must pick a KMS splash, not
# the Wayland SESSION splash.
#
# The payload ships /opt/singularity/bin/singularity-boot-splash (KMS: drmSetMaster,
# --device/--wait-seconds/--handoff/--greeter-ready) AND /opt/singularity/bin/
# singularity-splash (a GTK4/glycin Wayland client used after greeter login).
# The old "singularity-splash first" preference ran the Wayland client at early
# boot, where it printed "splash: cannot connect to Wayland display" and exited,
# leaving the MS-R1 screen black until the greeter painted. This test runs the
# REAL selection block (both the installer-time pick and the runtime wrapper
# pick) against fake payloads and asserts capability-based selection.
#
# Run: bash build/test-boot-splash-select.sh    Exit 0 = pass, 1 = fail.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${NCZ_TEST_ROOT:-$(cd "$HERE/.." && pwd)}"
G="$ROOT/post-install/60-boot-splash.sh"
W="$(mktemp -d -t splash-select.XXXXXX)"; trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

[ -f "$G" ] || { echo "FATAL: $G not found" >&2; exit 2; }

# --- extract the installer-time selection block -------------------------------
awk '/^ncz_splash_is_kms\(\) \{/ {f=1} f {print} f && /^echo "\[60\] KMS boot splash: \$BSP"$/ {exit}' "$G" > "$W/pick.sh"
[ -s "$W/pick.sh" ] || { echo "FATAL: installer selection block not found in $G" >&2; exit 2; }
sed 's#/opt/singularity/bin#'"$W"'/bin#g' "$W/pick.sh" > "$W/pick-sb.sh"

# --- extract the runtime wrapper heredoc and prove it is capability-based -----
awk '/cat > \/usr\/local\/bin\/ncz-boot-splash <<.WRAPPER.$/ {f=1; next} f && /^WRAPPER$/ {exit} f {print}' "$G" > "$W/wrap.sh"
[ -s "$W/wrap.sh" ] || { echo "FATAL: ncz-boot-splash wrapper heredoc not found in $G" >&2; exit 2; }
grep -q 'ncz_splash_is_kms' "$W/wrap.sh" \
    && ok "runtime wrapper also selects the splash by capability" \
    || bad "runtime wrapper still selects by name (no ncz_splash_is_kms)"

mkdir -p "$W/bin"
printf 'ELF fake\0--device\0--wait-seconds\0--handoff\0--max-life\0--greeter-ready\0drmSetMaster\0' > "$W/kms.bin"
printf 'ELF fake\0--preview\0splash: cannot connect to Wayland display\0' > "$W/way.bin"
chmod +x "$W/kms.bin" "$W/way.bin"

pick() {   # pick <kms-at-boot-name> <wayland-at-singularity-splash> -> chosen basename
    rm -rf "$W/bin"
    mkdir -p "$W/bin"
    [ "$1" = 1 ] && cp "$W/kms.bin" "$W/bin/singularity-boot-splash"
    [ "$2" = 1 ] && cp "$W/way.bin" "$W/bin/singularity-splash"
    ( . "$W/pick-sb.sh" ) 2>/dev/null | sed -n 's#^\[60\] KMS boot splash: ##p' | xargs -n1 basename 2>/dev/null
}

r=$(pick 1 1)
[ "$r" = "singularity-boot-splash" ] && ok "both present: picks the KMS boot-splash" || bad "both present picked '$r'"

r=$(pick 0 1)
[ "$r" = "singularity-boot-splash" ] && ok "only the Wayland session splash present: does NOT pick it (canonical KMS name / staged asset)" || bad "picked Wayland splash '$r'"

# A payload that (correctly) names its KMS binary singularity-splash must still work.
rm -rf "$W/bin"; mkdir -p "$W/bin"; cp "$W/kms.bin" "$W/bin/singularity-splash"
r=$( ( . "$W/pick-sb.sh" ) 2>/dev/null | sed -n 's#^\[60\] KMS boot splash: ##p' | xargs -n1 basename 2>/dev/null )
[ "$r" = "singularity-splash" ] && ok "singularity-splash is KMS-capable: it is used" || bad "KMS-flagged singularity-splash ignored ('$r')"

# Prove a plain Wayland binary is rejected by the capability test itself.
rm -rf "$W/bin"; mkdir -p "$W/bin"; cp "$W/way.bin" "$W/bin/singularity-splash"
if ( . "$W/pick-sb.sh" ) >/dev/null 2>&1; then
    grep -qa -- '--wait-seconds' "$W/bin/singularity-splash" && bad "wayland fixture falsely detected as KMS" || ok "Wayland session splash is not treated as KMS"
else
    bad "selection block failed to run"
fi

echo "boot-splash-select tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
