#!/bin/bash
# test-check-metal-bundle.sh -- behavioural tests for build/check-metal-bundle.sh
#
# The tool exists because a bundle can reach an operator with the wrong architecture, a
# missing launcher, or the builder's home directory baked into it. Each test below is the
# BAD direction first: the tool has to fail on the bundles a hurry would ship.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TOOL="$HERE/check-metal-bundle.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0 out; shift 2
    out="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$out"; fi
    LAST="$out"
}

[ -x "$TOOL" ] || { echo "SKIP: $TOOL is not executable" >&2; exit 0; }
ELF=/bin/true
[ -f "$ELF" ] || { echo "SKIP: no /bin/true to use as a fixture ELF" >&2; exit 0; }

# a clean bundle: launcher + two savers + a data file
mkbundle() {  # out.tar
    local root="$T/root-$(basename "$1" .tar)"
    rm -rf "$root"; mkdir -p "$root/opt/bh-test/bin" "$root/opt/bh-test/lib/ncz-screensavers"
    printf '#!/bin/sh\necho launcher\n' > "$root/opt/bh-test/bin/ncz-screensaver"
    chmod +x "$root/opt/bh-test/bin/ncz-screensaver"
    cp "$ELF" "$root/opt/bh-test/lib/ncz-screensavers/alpha_gles3"
    cp "$ELF" "$root/opt/bh-test/lib/ncz-screensavers/beta_gles3"
    printf 'preset\n' > "$root/opt/bh-test/lib/ncz-screensavers/preset.conf"
    tar -C "$root" -czf "$1" opt
}

echo "=== 1. a clean bundle passes ==="
mkbundle "$T/good.tar"
expect_rc "clean bundle" 0 "$TOOL" "$T/good.tar" --prefix opt/bh-test --arch amd64 --min-savers 2
case "$LAST" in *"2 savers"*) ok "  reports the saver count" ;; *) bad "saver count missing" "$LAST" ;; esac
case "$LAST" in *sha256:*) ok "  prints the sha256 it is certifying" ;; *) bad "no sha256 line" "$LAST" ;; esac

echo "=== 2. the wrong architecture fails ==="
expect_rc "an amd64 bundle declared arm64" 1 "$TOOL" "$T/good.tar" --arch arm64 --min-savers 2
case "$LAST" in *"ELF machine 62, expected 183"*) ok "  names the machine mismatch" ;; *) bad "machine mismatch not named" "$LAST" ;; esac

echo "=== 3. a missing launcher fails ==="
root="$T/noboot"; rm -rf "$root"; mkdir -p "$root/opt/bh-test/lib/ncz-screensavers"
cp "$ELF" "$root/opt/bh-test/lib/ncz-screensavers/alpha_gles3"
tar -C "$root" -czf "$T/noboot.tar" opt
expect_rc "no bin/ncz-screensaver" 1 "$TOOL" "$T/noboot.tar" --min-savers 1
case "$LAST" in *"no opt/bh-test/bin/ncz-screensaver"*) ok "  names the missing launcher" ;; *) bad "launcher not named" "$LAST" ;; esac

echo "=== 4. too few savers fails ==="
expect_rc "two savers, four required" 1 "$TOOL" "$T/good.tar" --min-savers 4
case "$LAST" in *"only 2 saver"*) ok "  reports what it found" ;; *) bad "saver shortfall not reported" "$LAST" ;; esac

echo "=== 5. a build path in the payload fails, and --allow-build-path relaxes it ==="
root="$T/leaky"; rm -rf "$root"; mkdir -p "$root/opt/bh-test/bin" "$root/opt/bh-test/lib/ncz-screensavers"
printf '#!/bin/sh\n' > "$root/opt/bh-test/bin/ncz-screensaver"
cp "$ELF" "$root/opt/bh-test/lib/ncz-screensavers/alpha_gles3"
printf '/home/someone/build/tree\n' > "$root/opt/bh-test/lib/ncz-screensavers/notes.txt"
tar -C "$root" -czf "$T/leaky.tar" opt
expect_rc "leaked /home/ path" 1 "$TOOL" "$T/leaky.tar" --min-savers 1
case "$LAST" in *"carry a build path"*) ok "  names the leak" ;; *) bad "leak not named" "$LAST" ;; esac
expect_rc "--allow-build-path accepts it" 0 "$TOOL" "$T/leaky.tar" --min-savers 1 --allow-build-path

echo "=== 6. members outside the prefix, and escapes, fail ==="
root="$T/outside"; rm -rf "$root"; mkdir -p "$root/opt/bh-test/bin" "$root/opt/bh-test/lib/ncz-screensavers" "$root/usr/bin"
printf '#!/bin/sh\n' > "$root/opt/bh-test/bin/ncz-screensaver"
cp "$ELF" "$root/opt/bh-test/lib/ncz-screensavers/alpha_gles3"
printf 'stray\n' > "$root/usr/bin/stray"
tar -C "$root" -czf "$T/outside.tar" opt usr
expect_rc "a member outside opt/bh-test" 1 "$TOOL" "$T/outside.tar" --min-savers 1
case "$LAST" in *"outside opt/bh-test"*) ok "  names the stray member" ;; *) bad "stray member not named" "$LAST" ;; esac

python3 - "$T" <<'PY'
import sys, tarfile, io
T = sys.argv[1]
with tarfile.open(T + "/escape.tar", "w:gz") as tf:
    payload = b"#!/bin/sh\n"
    ti = tarfile.TarInfo("../escape.sh"); ti.size = len(payload)
    tf.addfile(ti, io.BytesIO(payload))
    ti2 = tarfile.TarInfo("opt/bh-test/bin/ncz-screensaver"); ti2.size = len(payload)
    tf.addfile(ti2, io.BytesIO(payload))
PY
expect_rc "a .. escape member" 1 "$TOOL" "$T/escape.tar" --min-savers 0
case "$LAST" in *"escapes the prefix"*) ok "  names the escape" ;; *) bad "escape not named" "$LAST" ;; esac

echo "=== 7. usage errors ==="
rc=0; "$TOOL" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "no arguments exits 2" || bad "no arguments rc=$rc, wanted 2"
rc=0; "$TOOL" "$T/good.tar" --arch riscv >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "an unsupported arch exits 2" || bad "unsupported arch rc=$rc, wanted 2"
rc=0; "$TOOL" "$T/does-not-exist.tar" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "a missing tarball exits 2" || bad "missing tarball rc=$rc, wanted 2"
printf 'not a tarball\n' > "$T/notatar.tar"
rc=0; "$TOOL" "$T/notatar.tar" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && ok "a corrupt tarball fails (rc=1), not a crash" || bad "corrupt tarball rc=$rc, wanted 1"

echo "test-check-metal-bundle: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
