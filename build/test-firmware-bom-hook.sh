#!/bin/bash
# test-firmware-bom-hook.sh -- post-install/13-firmware-bom.sh (r201 defect).
#
# Two defects in one hook:
#  (a) firmware-ipw2x00 / firmware-ivtv ask a critical debconf licence question
#      that cannot be answered under DEBIAN_FRONTEND=noninteractive, so their
#      preinst fails and dpkg leaves "install ok not-installed". The hook must
#      preseed the acceptance BEFORE apt runs.
#  (b) the follow-up check used `dpkg -s`, which exits 0 for "install ok
#      not-installed", so the hook printed "0 of 40 missing" with two packages
#      absent. The check must read the real Status and the hook must FAIL
#      (rc != 0) when anything in the BOM is not "install ok installed".
#
# Runs the real hook against fake apt-get / dpkg-query / debconf-set-selections.
# NCZ_HOOK_UNDER_TEST points at another copy of the hook (used to prove the
# test fails on the old code).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${NCZ_HOOK_UNDER_TEST:-$ROOT/post-install/13-firmware-bom.sh}"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/fwbom.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# mkbox <name> <apt-mode: honour-preseed|ignore-preseed> <apt-rc-on-failure>
#  honour-preseed: licence packages install only if their question was preseeded
#  (models real preinst); ignore-preseed: they never install (a hard failure).
mkbox() {
    local b="$T/$1" mode="$2"
    mkdir -p "$b/bin" "$b/state"
    printf '# BOM\nfirmware-linux\nfirmware-ipw2x00\nfirmware-ivtv\n\nfirmware-realtek extra-col\n' > "$b/firmware.pkgs"
    : > "$b/state/preseed"
    cat > "$b/bin/debconf-set-selections" <<SH
#!/bin/sh
cat >> "$b/state/preseed"
SH
    cat > "$b/bin/apt-get" <<SH
#!/bin/bash
# fake: every package installs, except a licence-gated one without preseed
rc=0
for a in "\$@"; do
    case "\$a" in -*|install) continue ;; esac
    case "\$a" in
        firmware-ipw2x00|firmware-ivtv)
            if [ "$mode" = honour-preseed ] && grep -q "\$a/license/accepted boolean true" "$b/state/preseed"; then
                echo "install ok installed" > "$b/state/\$a"
            else
                echo "install ok not-installed" > "$b/state/\$a"; rc=100
            fi ;;
        *) echo "install ok installed" > "$b/state/\$a" ;;
    esac
done
exit \$rc
SH
    # dpkg -s semantics of the real tool: exit 0 while a status record exists.
    cat > "$b/bin/dpkg" <<SH
#!/bin/bash
[ "\$1" = -s ] && { [ -f "$b/state/\$2" ] && exit 0 || exit 1; }
exit 0
SH
    cat > "$b/bin/dpkg-query" <<SH
#!/bin/bash
# dpkg-query -W -f='\${Status}' PKG
pkg="\${@: -1}"
[ -f "$b/state/\$pkg" ] || exit 1
printf '%s' "\$(cat "$b/state/\$pkg")"
SH
    chmod +x "$b/bin/"*
}
run() { env -i PATH="$T/$1/bin:/usr/bin:/bin" NCZ_FW_BOM="$T/$1/firmware.pkgs" bash "$HOOK" >"$T/$1/out" 2>&1; echo $? > "$T/$1/rc"; }

# 1. licence preseeded, all install -> rc 0 and both questions seeded
mkbox a honour-preseed; run a
if [ "$(cat "$T/a/rc")" = 0 ] \
   && grep -q 'firmware-ipw2x00/license/accepted boolean true' "$T/a/state/preseed" \
   && grep -q 'firmware-ivtv/license/accepted boolean true' "$T/a/state/preseed" \
   && grep -q 'all 4 packages' "$T/a/out"; then ok "licence questions preseeded, BOM installs, rc 0"
else bad "preseed/clean path (rc=$(cat "$T/a/rc"))"; cat "$T/a/out"; fi

# 2. a package stays not-installed (preinst failed): dpkg -s would say present;
#    the hook must see it missing, name it, and exit non-zero.
mkbox b ignore-preseed; run b
if [ "$(cat "$T/b/rc")" != 0 ] \
   && grep -q 'MISSING: firmware-ipw2x00' "$T/b/out" \
   && grep -q 'MISSING: firmware-ivtv' "$T/b/out" \
   && grep -q 'FAILED: 2 of 4' "$T/b/out" \
   && ! grep -q '0 of 4' "$T/b/out"; then ok "not-installed packages are reported and fail the hook"
else bad "not-installed packages not caught (rc=$(cat "$T/b/rc"))"; cat "$T/b/out"; fi

# 3. package record entirely absent -> also missing
mkbox c honour-preseed; run c
rm -f "$T/c/state/firmware-realtek"
sed -i 's/^firmware-realtek.*/firmware-realtek/' "$T/c/firmware.pkgs"
# apt fake would recreate it, so replace apt with one that installs nothing new
printf '#!/bin/sh\nexit 0\n' > "$T/c/bin/apt-get"
rm -f "$T/c/state/"firmware-*
run c
if [ "$(cat "$T/c/rc")" != 0 ] && grep -q 'FAILED: 4 of 4' "$T/c/out"; then ok "absent packages fail the hook"
else bad "absent packages not caught"; cat "$T/c/out"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
