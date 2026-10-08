#!/bin/bash
# test-desktop-apt-require.sh -- post-install/20-desktop.sh must not report a
# package as installed when apt-get failed (r201: `apt-get install
# systemd-coredump | tail -3 || true` hid "E: Unable to locate package" rc=100
# and the hook printed "systemd-coredump installed"). Extracts the real
# ncz_apt_require function from the hook and drives it with fake apt-get /
# dpkg-query, plus static guards: the diagnostics package is seeded in both
# desktop manifests and no `apt-get install ... | tail || true` is left.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/20-desktop.sh}"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/aptreq.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkdir -p "$T/bin" "$T/state"
sed -n '/^ncz_apt_require() {/,/^}/p' "$HOOK" > "$T/fn.sh"
if [ ! -s "$T/fn.sh" ]; then bad "ncz_apt_require not found in the hook"; echo "--- $pass passed, $fail failed"; exit 1; fi
cat > "$T/bin/apt-get" <<SH
#!/bin/bash
# fake: "ghost" cannot be located (rc 100); "halfway" exits 0 but is not installed
rc=0
for a in "\$@"; do
    case "\$a" in -*|install) continue ;; esac
    case "\$a" in
        ghost) echo "E: Unable to locate package ghost" >&2; rc=100 ;;
        halfway) echo "install ok not-installed" > "$T/state/\$a" ;;
        *) echo "install ok installed" > "$T/state/\$a" ;;
    esac
done
exit \$rc
SH
cat > "$T/bin/dpkg-query" <<SH
#!/bin/bash
pkg="\${@: -1}"; [ -f "$T/state/\$pkg" ] || exit 1; printf '%s' "\$(cat "$T/state/\$pkg")"
SH
chmod +x "$T/bin/"*
call() { env -i PATH="$T/bin:/usr/bin:/bin" bash -c ". '$T/fn.sh'; ncz_apt_require $*" >"$T/out" 2>&1; }

call --no-install-recommends mpv fonts-x && ok "installed packages: rc 0" || bad "installed packages rejected"
call systemd-coredump ghost; rc=$?
if [ $rc -ne 0 ] && grep -q 'ERROR: apt-get install' "$T/out"; then ok "apt failure (unable to locate) propagates"; else bad "apt failure swallowed (rc=$rc)"; fi
call halfway; rc=$?
if [ $rc -ne 0 ] && grep -q 'not installed after apt-get: halfway' "$T/out"; then ok "rc 0 but not 'install ok installed' is caught"; else bad "half-installed package not caught (rc=$rc)"; fi

# static guards
for m in desktop.pkgs desktop-amd64.pkgs; do
    grep -qx systemd-coredump "$ROOT/manifests/$m" && ok "systemd-coredump seeded in $m" || bad "systemd-coredump missing from $m"
done
# every apt install in the hook (apt or apt-get, any leading options, continuation lines joined) must not
# swallow its failure: no `|| true`, `|| :`, `|| echo`, and no bare `| tail` outside an if/elif condition.
scan_swallow() {  # <hook file> -> prints offending logical lines
    awk '{ line = $0; while (line ~ /\\$/ && (getline nxt) > 0) { sub(/\\$/, " ", line); line = line nxt }
           if (line ~ /(^|[^[:alnum:]_-])apt(-get)?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*install/ && line !~ /^[[:space:]]*#/) print NR ": " line }' "$1" \
      | awk '/\|\|[[:space:]]*(true|:|echo)([[:space:];|&)]|$)/ { print; next }
             /\| *tail/ && $0 !~ /^[0-9]+: *(if|elif) / { print }'
}
swallowed="$(scan_swallow "$HOOK")"
if [ -z "$swallowed" ]; then ok "no apt/apt-get install in the hook swallows its failure (|| true / || : / || echo / bare | tail)"
else bad "swallowed apt install in the hook"; printf '%s\n' "$swallowed"; fi
# the guard itself, proven by mutations of a copy of the hook: each must be flagged
mutant() {  # <name> <sed expr>
    sed -E "$2" "$HOOK" > "$T/mut.sh"
    if [ -n "$(scan_swallow "$T/mut.sh")" ]; then ok "guard catches mutation: $1"; else bad "guard MISSED mutation: $1"; fi
}
mutant '|| true after ncz install line'      's#^(ncz_apt_require systemd-coredump) \|\| exit 1#DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-coredump >/dev/null 2>\&1 || true#'
mutant '|| : after apt-get install'          's#^(ncz_apt_require systemd-coredump) \|\| exit 1#DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-coredump >/dev/null 2>\&1 || :#'
mutant 'apt install (no -get) || true'       's#^(ncz_apt_require systemd-coredump) \|\| exit 1#apt install -y systemd-coredump || true#'
mutant 'apt -y install || :'                 's#^(ncz_apt_require systemd-coredump) \|\| exit 1#apt -y install systemd-coredump \|\| :#'
mutant 'bare | tail'                         's#^(ncz_apt_require systemd-coredump) \|\| exit 1#apt-get install -y systemd-coredump 2>\&1 | tail -3#'
mutant '|| echo WARN'                        's#^(ncz_apt_require systemd-coredump) \|\| exit 1#apt-get install -y systemd-coredump || echo WARN#'
# the required package groups all go through ncz_apt_require
awk '{ line = $0; while (line ~ /\\$/ && (getline nxt) > 0) { sub(/\\$/, " ", line); line = line nxt }
       if (line ~ /^[[:space:]]*ncz_apt_require /) print line }' "$HOOK" > "$T/required.txt"
for p in pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol pulseaudio-utils alsa-utils gvfs gvfs-backends udisks2 bluez blueman \
         fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji fonts-liberation mpv systemd-coredump; do
    grep -qw -- "$p" "$T/required.txt" || bad "$p is not installed through ncz_apt_require"
done
[ "$fail" = 0 ] && ok "all required desktop packages go through ncz_apt_require"

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
