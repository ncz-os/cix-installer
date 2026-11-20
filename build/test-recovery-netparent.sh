#!/bin/bash
# test-recovery-netparent.sh — the ncz-recovery MACVLAN parent resolver must
# survive a fast boot: settle udev, wait for a default route, and never prefer a
# renameable eth* name while a predictable en* one exists.
#
# Extracts the resolver body from the installer that writes it, so the test
# exercises the shipped text rather than a copy.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/post-install/38-recovery-container.sh"
fails=0
ok()  { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails+1)); }

[ -f "$GEN" ] || { echo "FATAL: $GEN missing"; exit 2; }

# 1. the generated script and unit must carry the fast-boot guards
grep -q 'udevadm settle' "$GEN" && ok "resolver settles udev" || bad "resolver does not settle udev"
grep -q 'systemd-udev-settle.service' "$GEN" && ok "unit orders after udev-settle" || bad "unit does not order after udev-settle"
grep -q 'NCZ_ROUTE_WAIT_S' "$GEN" && ok "route wait is bounded and overridable" || bad "no bounded route wait"

# 2. extract the resolver body exactly as it is written
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
awk "/cat > \/usr\/local\/sbin\/ncz-recovery-netparent <<'EOF'/{f=1;next} f&&/^EOF\$/{exit} f{print}" "$GEN" > "$W/netparent"
[ -s "$W/netparent" ] || { echo "FATAL: could not extract the resolver"; exit 2; }
chmod +x "$W/netparent"

mkdir -p "$W/bin"
cat > "$W/bin/ip" <<'EOS'
#!/bin/sh
# stub: whatever NET_IP_ROUTE says, default empty
[ -n "${NET_IP_ROUTE:-}" ] && printf '%s\n' "$NET_IP_ROUTE"
exit 0
EOS
cat > "$W/bin/udevadm" <<'EOS'
#!/bin/sh
echo "$*" >> "${NET_UDEVADM_LOG:-/dev/null}"
exit 0
EOS
cat > "$W/bin/modprobe" <<'EOS'
#!/bin/sh
exit 0
EOS
chmod +x "$W/bin/"*

run_case() { # name, sys names, route, expected
    name=$1; names=$2; route=$3; want=$4
    rm -rf "$W/sys"; mkdir -p "$W/sys"
    for n in $names; do mkdir -p "$W/sys/$n"; done
    printf 'MACVLAN=old0\n' > "$W/nspawn"
    : > "$W/udevadm.log"
    PATH="$W/bin:$PATH" NCZ_SYS_CLASS_NET="$W/sys" NCZ_NSPAWN="$W/nspawn" \
        NCZ_ROUTE_WAIT_S=2 NET_IP_ROUTE="$route" NET_UDEVADM_LOG="$W/udevadm.log" \
        "$W/netparent" >/dev/null 2>&1
    got=$(sed -n 's/^MACVLAN=//p' "$W/nspawn" | head -1)
    if [ "$got" = "$want" ]; then ok "$name -> $got"; else bad "$name -> $got (want $want)"; fi
}

run_case "default route wins"            "eth0 enp1s0" "default via 10.0.0.1 dev enp1s0" "enp1s0"
run_case "no route: predictable name"    "eth0 enp1s0" ""                               "enp1s0"
run_case "no route, only eth0 left"      "eth0"        ""                               "eth0"
run_case "route on eth (still correct)"  "eth0"        "default via 10.0.0.1 dev eth0"   "eth0"

# 3. the resolver must actually have called udevadm settle
grep -q 'settle' "$W/udevadm.log" && ok "resolver invoked udevadm settle" || bad "resolver never called udevadm settle"

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
