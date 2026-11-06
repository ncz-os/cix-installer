#!/bin/bash
# test-sinty-adopt.sh -- the small Singularity OS adoptions (2026-10-17):
#   * fonts-inter-variable + xdg-user-dirs in BOTH desktop manifests and installed by 20-desktop.sh
#   * 20-desktop.sh writes a well-formed fontconfig alias with Inter first and a Noto fallback
#   * 58-boot-hygiene.sh writes /etc/sysctl.d/90-ncz-hardening.conf with the intended keys, every key
#     "-"-prefixed, and never dmesg_restrict / kexec_load_disabled / rp_filter=1 / suid_dumpable
# Runs each hook's heredoc out of the source (no chroot) and parses what it would write.
set -u
cd "$(dirname "$0")/.."
pass=0; fail=0
ok()  { echo "ok   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
W=$(mktemp -d "${TMPDIR:-$PWD}/sinty-adopt.XXXXXX"); trap 'rm -rf "$W"' EXIT

for m in manifests/desktop.pkgs manifests/desktop-amd64.pkgs; do
    for p in fonts-inter-variable xdg-user-dirs; do
        grep -qx "$p" "$m" && ok "$m lists $p" || bad "$m does not list $p"
    done
done

D=post-install/20-desktop.sh
grep -Eq '^ncz_apt_require --no-install-recommends xdg-user-dirs \|\| exit 1$' "$D" \
    && ok "20-desktop installs xdg-user-dirs (fails the hook if it cannot)" || bad "20-desktop does not require xdg-user-dirs"
grep -Eq '^    fonts-inter-variable \|\| exit 1$' "$D" \
    && ok "20-desktop installs fonts-inter-variable with the other fonts" || bad "20-desktop does not require fonts-inter-variable"
sed -n "/<<'FONTCONF'/,/^FONTCONF\$/p" "$D" | sed '1d;$d' > "$W/inter.conf"
[ -s "$W/inter.conf" ] && ok "fontconfig alias heredoc present" || bad "fontconfig alias heredoc missing"
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$W/inter.conf" 2>/dev/null && ok "fontconfig alias is well-formed XML" || bad "fontconfig alias is not well-formed XML"
else
    python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$W/inter.conf" 2>/dev/null \
        && ok "fontconfig alias is well-formed XML" || bad "fontconfig alias is not well-formed XML"
fi
fams=$(python3 - "$W/inter.conf" 2>/dev/null <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
for a in r.findall("alias"):
    if a.findtext("family") == "sans-serif":
        print(",".join(f.text for f in a.find("prefer").findall("family")))
PY
)
[ "$fams" = "Inter,Noto Sans" ] && ok "sans-serif prefers Inter, then Noto Sans" || bad "sans-serif prefer list is '$fams'"
grep -q '/etc/fonts/conf.d/60-ncz-inter.conf' "$D" && ok "alias lands in /etc/fonts/conf.d" || bad "alias path wrong"

H=post-install/58-boot-hygiene.sh
sed -n "/90-ncz-hardening.conf <<'SYS'/,/^SYS\$/p" "$H" | sed '1d;$d' > "$W/hard.conf"
[ -s "$W/hard.conf" ] && ok "hardening sysctl heredoc present" || bad "hardening sysctl heredoc missing"
keys=$(grep -v -E '^\s*(#|$)' "$W/hard.conf")
echo "$keys" | grep -v -q '^-' && bad "a hardening key lacks the '-' (skip if absent) prefix" || ok "every hardening key is '-'-prefixed"
for kv in "kernel.kptr_restrict = 1" "kernel.unprivileged_bpf_disabled = 1" "net.core.bpf_jit_harden = 2" \
          "kernel.yama.ptrace_scope = 1" "net.ipv4.conf.all.accept_redirects = 0" "net.ipv4.conf.all.send_redirects = 0" \
          "net.ipv4.conf.all.accept_source_route = 0" "net.ipv6.conf.all.accept_redirects = 0"; do
    echo "$keys" | grep -qx -- "-$kv" && ok "sets $kv" || bad "missing $kv"
done
for k in kernel.dmesg_restrict kernel.kexec_load_disabled fs.suid_dumpable kernel.perf_event_paranoid; do
    echo "$keys" | grep -q -- "$k" && bad "must not set $k" || ok "does not set $k"
done
echo "$keys" | grep -E -q 'rp_filter *= *1' && bad "must not set strict rp_filter" || ok "does not set strict rp_filter"
# Every key must name a real sysctl (dots map to /proc/sys path components). Check the names
# the running kernel knows, when it is Linux; a key unknown here is reported, not failed.
if [ -d /proc/sys/kernel ]; then
    echo "$keys" | sed 's/^-//; s/ *=.*//' | while read -r k; do
        [ -e "/proc/sys/$(echo "$k" | tr . /)" ] || echo "note $k is not present on this build host's kernel"
    done
fi
# The hardening file must sort after systemd's defaults (50-*) so its values win.
case 90-ncz-hardening.conf in [6-9]*) ok "hardening file sorts after 50-default.conf" ;; *) bad "hardening file sorts too early" ;; esac

echo "test-sinty-adopt: $pass passed, $fail failed"
[ "$fail" = 0 ]
