#!/bin/bash
# test-diag-busybox.sh -- the installer's diagnostic busybox is the pinned
# Debian forky build and the diagnostic console works with it.
#
#   * build/stage-diag-busybox.sh --check passes on the tree, and fails on a
#     copy whose binary differs from the pin (tamper control);
#   * the host-arch binary (and the other arch when qemu-user is available)
#     provides every applet preseed/diag-console.sh requires;
#   * diag-console.sh's ncz_diag_set_root_pw sets root's sha512-crypt password
#     with that binary, in /etc/shadow when shadow has root (passwd field "x")
#     and in /etc/passwd otherwise, verified with openssl passwd -6; it fails
#     cleanly when there is no root entry;
#   * control: Debian's busybox has no chpasswd applet, which is why the
#     console no longer uses it.
#
# Usage: bash build/test-diag-busybox.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ncz-diagbb.XXXXXX")"
trap 'rm -rf "$W"' EXIT
DIAG="$ROOT/preseed/diag-console.sh"

out="$(bash "$ROOT/build/stage-diag-busybox.sh" --check 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "stage-diag-busybox.sh --check passes" || bad "stage-diag-busybox.sh --check rc=$rc: $(echo "$out" | grep FAIL | head -3)"

# tamper control on an isolated copy
mkdir -p "$W/repo/manifests" "$W/repo/assets/diag" "$W/repo/build"
cp "$ROOT/manifests/diag-busybox.tsv" "$ROOT/manifests/forky-snapshot.tsv" "$W/repo/manifests/"
cp "$ROOT"/assets/diag/busybox-* "$W/repo/assets/diag/"
printf 'x' >> "$W/repo/assets/diag/busybox-arm64"
out="$(NCZ_DIAG_BB_ROOT="$W/repo" bash "$ROOT/build/stage-diag-busybox.sh" --check 2>&1)"; rc=$?
if [ "$rc" = 1 ] && echo "$out" | grep -q 'arm64: assets/diag/busybox-arm64 sha256'; then ok "control: a modified binary fails the pin check"; else bad "control: tampered binary not detected (rc=$rc)"; fi
printf '\177ELF fake (Ubuntu 1:1.36.1-6ubuntu3.1)' > "$W/repo/assets/diag/busybox-amd64"
out="$(NCZ_DIAG_BB_ROOT="$W/repo" bash "$ROOT/build/stage-diag-busybox.sh" --check --arch amd64 2>&1)"
echo "$out" | grep -q 'amd64: binary carries an Ubuntu build identity' && ok "control: an Ubuntu banner is reported" || bad "control: Ubuntu banner not reported"

# --- applets diag-console.sh requires --------------------------------------------------------
REQ="$(sed -n 's/^for _applet in \(.*\); do$/\1/p' "$DIAG" | tail -1)"
[ -n "$REQ" ] && ok "diag-console.sh required applets: $REQ" || bad "cannot read the required applet list from diag-console.sh"
case " $REQ " in *" chpasswd "*) bad "diag-console.sh still requires chpasswd" ;; *) ok "diag-console.sh does not require chpasswd" ;; esac
case "$(uname -m)" in x86_64) HOST=amd64; OTHER=arm64; QEMU=qemu-aarch64-static ;; aarch64) HOST=arm64; OTHER=amd64; QEMU=qemu-x86_64-static ;; *) HOST=""; OTHER=""; QEMU="" ;; esac
BB=""
if [ -n "$HOST" ]; then
    BB="$ROOT/assets/diag/busybox-$HOST"
    "$BB" true 2>/dev/null || { bad "busybox-$HOST does not run on this host"; BB=""; }
fi
check_applets() {   # check_applets <label> <cmd...>
    local label="$1" list miss="" a; shift
    list="$("$@" --list 2>/dev/null)"
    for a in $REQ; do printf '%s\n' "$list" | grep -qx "$a" || miss="$miss $a"; done
    [ -z "$miss" ] && ok "$label provides every required applet" || bad "$label lacks:$miss"
    if printf '%s\n' "$list" | grep -qx chpasswd; then
        echo "note $label has chpasswd"
    else
        ok "control: $label has no chpasswd applet (why the console hashes with mkpasswd)"
    fi
}
[ -n "$BB" ] && check_applets "busybox-$HOST" "$BB"
if [ -n "$QEMU" ] && command -v "$QEMU" >/dev/null 2>&1; then
    check_applets "busybox-$OTHER (via $QEMU)" "$QEMU" "$ROOT/assets/diag/busybox-$OTHER"
else
    echo "skip busybox-$OTHER applet list (no $QEMU)"
fi

# --- root password function ------------------------------------------------------------------
fn="$(python3 - "$DIAG" <<'PY'
import sys
s = open(sys.argv[1]).read()
a = s.index("ncz_diag_set_root_pw() {")
b = s.index("\n}\n", a) + 3
print(s[a:b])
PY
)"
if [ -z "$fn" ] || [ -z "$BB" ]; then
    bad "cannot run ncz_diag_set_root_pw (function or host busybox missing)"
else
    run_pw() {   # run_pw <etc dir> <password>
        NCZ_DIAG_ETC="$1" BB="$BB" sh -c "$fn"'
ncz_diag_set_root_pw "$1"' _ "$2"
    }
    verify() {   # verify <file> <password> -> field 2 is a sha512 crypt of the password
        local h salt
        h="$(awk -F: '$1=="root"{print $2}' "$1")"
        salt="$(printf '%s' "$h" | cut -d'$' -f3)"
        [ -n "$salt" ] && [ "$(openssl passwd -6 -salt "$salt" "$2")" = "$h" ]
    }
    PW='diag pw:with$chars'
    E="$W/etc-shadow"; mkdir -p "$E"
    printf 'root:x:0:0:root:/:/bin/sh\nsshd:x:100:65534::/run/sshd:/bin/false\n' > "$E/passwd"
    printf 'root:*:19000:0:99999:7:::\n' > "$E/shadow"; chmod 600 "$E/shadow"
    if run_pw "$E" "$PW"; then
        verify "$E/shadow" "$PW" && ok "shadow present: root hash written to shadow" || bad "shadow hash does not verify"
        [ "$(awk -F: '$1=="root"{print $2}' "$E/passwd")" = x ] && ok "shadow present: passwd field is x" || bad "passwd field not x"
        grep -q '^sshd:x:100:' "$E/passwd" && ok "other passwd entries kept" || bad "other passwd entries changed"
        [ "$(stat -c %a "$E/shadow")" = 600 ] && ok "shadow mode kept (0600)" || bad "shadow mode changed"
        if [ -e "$E/shadow.ncz-new" ] || [ -e "$E/passwd.ncz-new" ]; then bad "temporary file left behind"; else ok "no temporary file left behind"; fi
    else
        bad "ncz_diag_set_root_pw failed with shadow present"
    fi
    E="$W/etc-passwd"; mkdir -p "$E"
    printf 'root:*:0:0:root:/:/bin/sh\n' > "$E/passwd"
    if run_pw "$E" "$PW"; then
        verify "$E/passwd" "$PW" && ok "no shadow: root hash written to passwd" || bad "passwd hash does not verify"
    else
        bad "ncz_diag_set_root_pw failed without shadow"
    fi
    E="$W/etc-noroot"; mkdir -p "$E"
    printf 'daemon:x:1:1::/:/bin/false\n' > "$E/passwd"
    if run_pw "$E" "$PW"; then bad "no root entry reported success"; else ok "no root entry: returns failure"; fi
    grep -qx 'daemon:x:1:1::/:/bin/false' "$E/passwd" && ok "no root entry: passwd unchanged" || bad "no root entry: passwd changed"
fi

echo "# test-diag-busybox: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
