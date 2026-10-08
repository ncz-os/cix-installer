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
if grep -nE 'apt-get install.*(\\$|$)' "$HOOK" >/dev/null && ! grep -nE '^\s*(mpv|systemd-coredump|fonts-noto-core|pipewire|gvfs).*\| *tail.*\|\| *(true|echo)' "$HOOK" >/dev/null; then
    ok "no apt-get install | tail || true left for the diagnostics/media/font/audio groups"
else bad "an ignored-error apt install remains"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
