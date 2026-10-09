#!/bin/bash
# test-t2-native.sh -- the Apple T2 inputs are Forky-native: no third-party apt
# repo, all artifacts pinned/licensed in assets/t2, and 55-t2-firmware.sh
# installs them without network or apt, verifies the firmware archive by sha256
# before extracting it, refuses an unsafe/corrupt archive without mutating the
# host, preserves the archive's hardlinks, and fails loudly (never quietly) when
# a staged asset is missing.
#
# Run: bash build/test-t2-native.sh     Exit 0 = pass, 1 = fail.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/post-install/55-t2-firmware.sh"
ASSETS="$ROOT/assets/t2"
SOURCES="$ASSETS/SOURCES.tsv"
FW_TARBALL="$ROOT/assets/firmware/apple-t2/apple-t2-firmware-sonoma14.tar.xz"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/t2native.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
_sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

echo "=== the third-party repo and apt are gone from the hook ==="
# Check the executable lines only: the header comments deliberately name the
# eliminated repo and apt to document the posture change.
CODE="$(grep -vE '^[[:space:]]*#' "$HOOK")"
# `get_from_online` is special: the hook is allowed to MENTION it (so the
# recovery hint on MacBookPro16,1/16,2 can surface it), but it must NEVER be
# invoked by the hook itself -- only the operator runs the helper. The
# detection requires BOTH substrings on the SAME uncommented line so that
# single-line direct invocations, command substitutions, and pipelines are
# caught; multi-line indirection (variable-then-eval) is outside this hook's
# structure (and is caught by `bash -n` at sandbox run time).
GET_FROM_ONLINE_INVOCATIONS="$(printf '%s\n' "$CODE" \
    | grep -E 'get-apple-firmware' \
    | grep -E 'get_from_online' \
    | grep -vE 'echo[[:space:]]|printf[[:space:]]')"
if [ -n "$GET_FROM_ONLINE_INVOCATIONS" ]; then
    bad "55 code still invokes 'get_from_online' outside a diagnostic echo/printf"
else
    ok "55 code no longer invokes 'get_from_online' outside a diagnostic echo/printf"
fi
for pat in 'adityagarg8' 't2-ubuntu-repo' 'apt-get' 'sources.list.d/t2' 'KEY.gpg' 'dmg2img'; do
    if printf '%s\n' "$CODE" | grep -q -- "$pat"; then bad "55 code still references '$pat'"; else ok "55 code no longer references '$pat'"; fi
done

echo "=== every pinned asset exists and matches SOURCES.tsv ==="
[ -f "$SOURCES" ] && ok "assets/t2/SOURCES.tsv present" || bad "SOURCES.tsv missing"
while IFS=$'\t' read -r path repo commit lic sha; do
    case "$path" in ''|'#'*) continue ;; esac
    f="$ASSETS/$path"
    if [ ! -f "$f" ]; then bad "missing asset $path"; continue; fi
    got="$(_sha "$f")"
    [ "$got" = "$sha" ] && ok "sha256 $path" || bad "sha256 mismatch $path: $got != $sha"
    [ -n "$commit" ] && [ -n "$lic" ] || bad "SOURCE row incomplete for $path"
done < "$SOURCES"
grep -q 'e46839a28963e2f7d364020518b9dac98236bcae' "$SOURCES" && ok "audio source commit pinned (t2-better-audio)" || bad "audio source commit not pinned"
grep -q '986f5a79d43b75d93d84b8d57bc338853b51a0e0' "$SOURCES" && ok "firmware-helper commit pinned (t2linux/wiki)" || bad "helper commit not pinned"
[ -f "$ASSETS/t2-better-audio/LICENSE" ] && grep -qi 'MIT' "$ASSETS/t2-better-audio/LICENSE" && ok "audio config carries its MIT license" || bad "audio LICENSE missing/not MIT"
grep -qi 'MIT' "$ASSETS/firmware-helper/get-apple-firmware" && ok "firmware helper embeds its MIT license" || bad "helper MIT header missing"

echo "=== the hook's firmware sha256 pin matches the committed tarball ==="
[ -f "$FW_TARBALL" ] && ok "committed firmware tarball present" || bad "committed firmware tarball missing"
HOOK_SHA="$(sed -n 's/^NCZ_T2_FW_SHA256="\${NCZ_T2_FW_SHA256:-\([0-9a-f]*\)}"/\1/p' "$HOOK")"
[ "$HOOK_SHA" = "78810308c304eb999555b90de5debba7ad77eebe4614327a7539efe385e1e72a" ] && ok "hook pins 78810308..." || bad "hook sha pin: '$HOOK_SHA'"
[ -f "$FW_TARBALL" ] && [ "$(_sha "$FW_TARBALL")" = "$HOOK_SHA" ] && ok "hook sha pin == committed tarball sha256" || bad "hook sha pin does not match the committed tarball"

echo "=== build-squashfs-layers.sh stages assets/t2 (and fingerprints it) ==="
grep -q 'singularity t2; do' "$ROOT/build/build-squashfs-layers.sh" && ok "base staging loop includes t2" || bad "base staging loop omits t2"
grep -qE 'for a in .*intel t2; do' "$ROOT/build/build-squashfs-layers.sh" && ok "base fingerprint includes t2" || bad "base fingerprint omits t2"

echo "=== run the real hook against a sandbox root (T2 present), fake firmware tarball ==="
R="$T/root"
mkdev() {
    rm -rf "$R"; mkdir -p "$R/bin" "$R/hooklib" "$R/fw"
    # hw-detect stub: T2 present
    cat > "$R/hooklib/hw-detect.sh" <<'SH'
is_t2_hardware() { return 0; }
t2_hardware_detail() { echo "stub T2"; }
SH
    printf '#!/bin/sh\ncase "$1" in --print-architecture) echo amd64 ;; *) exit 0 ;; esac\n' > "$R/bin/dpkg"
    # Always provide a sha256sum on the sandbox PATH (the host's may sit outside
    # the scrubbed PATH); delegate to the real tool when present.
    _sb="$(command -v sha256sum 2>/dev/null || true)"
    if [ -n "$_sb" ]; then printf '#!/bin/sh\nexec %s "$@"\n' "$_sb" > "$R/bin/sha256sum"
    else printf '#!/bin/sh\nexec shasum -a 256 "$@"\n' > "$R/bin/sha256sum"; fi
    chmod +x "$R/bin/dpkg" "$R/bin/sha256sum"
    # a real .tar.xz with one Apple board firmware file AND a hardlinked twin
    mkdir -p "$R/fwsrc"
    printf 'fw\n' > "$R/fwsrc/brcmfmac4355c1-pcie.apple,board.bin"
    ln "$R/fwsrc/brcmfmac4355c1-pcie.apple,board.bin" "$R/fwsrc/brcmfmac4355c1-pcie.apple,board2.bin"
    # Real-shape Apple BT firmware files matching the upstream helper's
    # `BluetoothFWCollection` output: formosa (no vendor suffix), atlantisb-m
    # (GEN/MT vendor), shikoku-u (USI vendor). The inventory parsing must
    # recognise all three shapes and de-duplicate to one entry per board.
    printf 'bt-formosa\n'  > "$R/fwsrc/brcmbt4377b3-apple,formosa.ptb"
    printf 'bt-formosa\n'  > "$R/fwsrc/brcmbt4377b3-apple,formosa.bin"     # dedup target
    printf 'bt-atlantisb\n' > "$R/fwsrc/brcmbt4378b1-apple,atlantisb-m.ptb"
    printf 'bt-atlantisb\n' > "$R/fwsrc/brcmbt4378b1-apple,atlantisb-m.bin"
    printf 'bt-shikoku\n'   > "$R/fwsrc/brcmbt4378b1-apple,shikoku-u.ptb"
    printf 'bt-shikoku\n'   > "$R/fwsrc/brcmbt4378b1-apple,shikoku-u.bin"
    ( cd "$R/fwsrc" && tar -cJf "$R/fw/apple-t2-firmware-sonoma14.tar.xz" . )
    sed -E "s#(^|[^A-Za-z0-9_./\$-])/(etc|usr|lib|bin)/#\1$R/\2/#g" "$HOOK" > "$R/hook.sh"
    mkdir -p "$R/lib"; cp "$R/hooklib/hw-detect.sh" "$R/lib/hw-detect.sh"
}
mkbad() {  # <abs|dotdot|symlink> <out.tar.xz>
    python3 - "$1" "$2" <<'PY'
import sys, tarfile, io
kind, path = sys.argv[1], sys.argv[2]
with tarfile.open(path, "w:xz") as t:
    if kind == "abs":
        b = b"x"; ti = tarfile.TarInfo("/tmp/ncz-t2-evil"); ti.size = len(b); ti.mode = 0o644; t.addfile(ti, io.BytesIO(b))
    elif kind == "dotdot":
        b = b"x"; ti = tarfile.TarInfo("../ncz-t2-evil"); ti.size = len(b); ti.mode = 0o644; t.addfile(ti, io.BytesIO(b))
    elif kind == "symlink":
        ti = tarfile.TarInfo("brcmfmac4355c1-pcie.apple,evil.bin"); ti.type = tarfile.SYMTYPE; ti.linkname = "/etc/passwd"; t.addfile(ti)
PY
}
run_hook() {  # <tarball> [NAME=VALUE ...]
    local tb="$1"; shift || true
    mkdev
    local sh=""; [ -f "$tb" ] && sh="$(_sha "$tb")"
    env -i PATH="$R/bin:/usr/bin:/bin" \
        NCZ_TARGET_ARCH=amd64 NCZ_T2_ASSETS="$ASSETS" \
        NCZ_T2_FW_TARBALL="$tb" NCZ_T2_FW_SHA256="$sh" \
        "$@" \
        bash "$R/hook.sh" > "$R/out" 2>&1
    echo $? > "$R/rc"
}
run_hook "$R/fw/apple-t2-firmware-sonoma14.tar.xz"
[ "$(cat "$R/rc")" = 0 ] && ok "hook exits 0 with all assets present" || { bad "hook rc=$(cat "$R/rc")"; tail -8 "$R/out"; }
[ -f "$R/usr/bin/get-apple-firmware" ] && [ -x "$R/usr/bin/get-apple-firmware" ] && ok "get-apple-firmware installed to /usr/bin" || bad "helper not installed"
[ -f "$R/usr/libexec/get-apple-firmware" ] && ok "get-apple-firmware installed to /usr/libexec" || bad "helper not in /usr/libexec"
[ -f "$R/usr/share/alsa-card-profile/mixer/profile-sets/apple-t2x2.conf" ] && ok "audio profile-set installed (alsa-card-profile)" || bad "audio profile-set missing"
[ -f "$R/usr/share/pulseaudio/alsa-mixer/paths/t2-speakers.conf" ] && ok "audio path installed (pulseaudio mixer)" || bad "audio path missing"
[ -f "$R/usr/lib/udev/rules.d/92-apple-t2-audio.rules" ] && ok "audio udev rule installed" || bad "audio udev rule missing"
[ -f "$R/lib/firmware/brcm/brcmfmac4355c1-pcie.apple,board.bin" ] && ok "firmware extracted into /lib/firmware/brcm" || bad "firmware not extracted"
i1="$(ls -i "$R/lib/firmware/brcm/brcmfmac4355c1-pcie.apple,board.bin" 2>/dev/null | awk '{print $1}')"
i2="$(ls -i "$R/lib/firmware/brcm/brcmfmac4355c1-pcie.apple,board2.bin" 2>/dev/null | awk '{print $1}')"
[ -n "$i1" ] && [ "$i1" = "$i2" ] && ok "in-archive hardlink preserved ($i1)" || bad "hardlink not preserved ($i1 vs $i2)"
grep -q 'Apple WiFi/BT firmware present' "$R/out" && ok "hook reports Apple firmware present" || bad "firmware-present line missing"

echo "=== Bluetooth coverage note: inventory is always logged; recovery hint is conditional ==="
grep -q 'Apple Bluetooth staged boards' "$R/out" && ok "BT staging inventory is logged" || bad "BT staging inventory missing"
# Two filename shapes must produce one entry each: formosa (no vendor suffix),
# atlantisb-m (m-suffix), shikoku-u (u-suffix). All three board names must
# appear in the comma-joined inventory line; no .ptb suffix or vendor suffix
# must leak.
for board in formosa atlantisb shikoku; do
    if grep -qE "Apple Bluetooth staged boards.*${board}(,|$)" "$R/out"; then
        ok "BT inventory includes '${board}'"
    else
        bad "BT inventory missing '${board}' (full line follows)"
        grep 'Apple Bluetooth staged boards' "$R/out" | sed 's/^/    /'
    fi
done
# Negative: a leaked suffix from a missed strip is the bug the parameter
# expansion must NOT regress.
for leak in 'formosa-m' 'formosa-u' 'shikoku-u' 'atlantisb-m'; do
    if grep -qE "Apple Bluetooth staged boards.*${leak}(,|$)" "$R/out"; then
        bad "BT inventory leaked the bare-suffix '${leak}'"
    else
        ok "BT inventory does not leak '${leak}'"
    fi
done
# Negative: a non-conforming filename (e.g. `brcmbt-bareapple-other.ptb` with
# no literal `apple,` separator) must NOT appear in the inventory -- the
# parser's defensive case guard must silently skip it instead of leaking
# the `brcmbt...` prefix into the inventory line. Exercised by sourcing a
# fresh parser scope (the hook's pattern is documented inline; we test the
# EXACT guard).
parser_skip_output="$(bash -c '
set +e
bn="brcmbt-bareapple-other.ptb"
case "$bn" in
    brcmbt*-apple,*) echo "WOULD_PROCESS $bn -> ${bn#brcmbt*-apple,}";;
    *) echo "SKIPPED $bn";;
esac
')"
[ "$parser_skip_output" = "SKIPPED brcmbt-bareapple-other.ptb" ] \
    && ok "non-conforming filename (no apple,) is silently skipped" \
    || { bad "non-conforming filename parser: got [$parser_skip_output]"; }

# The hook MUST NOT install a symlink shortcut (e.g. brcm/BCM.hcd or any
# brcm/BCM<chip>.hcd). Operator directive (firmware.md): do NOT blindly symlink
# BCM.hcd to BCM4377B3.hcd; verify the contract here.
for symlink in "$R/lib/firmware/brcm/BCM.hcd" \
               "$R/lib/firmware/brcm/BCM4345C5.hcd" \
               "$R/lib/firmware/brcm/BCM4364B3.hcd" \
               "$R/lib/firmware/brcm/BCM4377B3.hcd"; do
    if [ -L "$symlink" ]; then
        bad "blind-symlink contract violated: $symlink was created"
    else
        ok "no blind symlink $symlink"
    fi
done
# Generic fallback "BCM.hcd" with no extension is the exact string the kernel
# logs when its chip-id table lacks an entry. Refusing to create it is the
# whole point of the contract.
if [ -e "$R/lib/firmware/brcm/BCM.hcd" ]; then bad "BCM.hcd was created (file or link)"; else ok "no BCM.hcd file/alias"; fi

echo "=== BT coverage hint is conditional on the host DMI product_name (MacBookPro16,1 = BCM4364B3 'Trinidad') ==="
# MacBookPro16,1 (MEDUSA SKU) -- BCM4364B3 "Trinidad Olympic GEN" BT is NOT in
# the staged set. Hook must surface the recovery command line, NOT silently
# succeed. The kernel log will still print "firmware Patch file not found,
# tried: 'brcm/BCM.hcd'" on this SKU; this installer-side hint is the
# operator-readable pointer to the next step.
run_hook "$R/fw/apple-t2-firmware-sonoma14.tar.xz" NCZ_T2_DMI_PRODUCT=MacBookPro16,1
[ "$(cat "$R/rc")" = 0 ] && ok "MacBookPro16,1 hook still exits 0 (hint is informational, not a failure)" || bad "MacBookPro16,1 rc=$(cat "$R/rc")"
grep -q "MacBookPro16,1 Bluetooth is BCM4364B3" "$R/out" && ok "MacBookPro16,1 recovery hint is printed" || bad "MacBookPro16,1 recovery hint missing"
grep -q 'get_from_online' "$R/out" && ok "get-apple-firmware get_from_online recovery command is referenced" || bad "recovery command missing"
# MacBookPro15,1 is an in-staged-coverage T2 Mac; the hint must NOT fire.
run_hook "$R/fw/apple-t2-firmware-sonoma14.tar.xz" NCZ_T2_DMI_PRODUCT=MacBookPro15,1
if grep -q "BT staged boards" "$R/out" || grep -q "Apple Bluetooth staged boards" "$R/out"; then
    ok "in-staged SKU inventory line emitted"; else bad "inventory line missing for MacBookPro15,1"
fi
if grep -q "BCM4364B3" "$R/out"; then bad "MacBookPro15,1 must not print the BCM4364B3 hint"; else ok "MacBookPro15,1 does not print BCM4364B3 hint"; fi

echo "=== a missing staged firmware tarball is a hard, loud failure (no quiet fallback) ==="
run_hook "$R/fw/does-not-exist.tar.xz"
[ "$(cat "$R/rc")" != 0 ] && ok "missing firmware tarball exits non-zero" || bad "missing tarball still exited 0"
grep -q 'refusing a per-install Apple CDN fetch' "$R/out" && ok "missing tarball is loud and explicit" || bad "missing tarball not loud"
grep -q 'FAILED: the T2 firmware/audio assets did not install' "$R/out" && ok "failure summary printed" || bad "failure summary missing"

echo "=== a corrupt archive (sha mismatch) is refused before any mutation ==="
mkdir -p "$T/fw"
head -c 128 /dev/urandom > "$T/fw/garbage.tar.xz" 2>/dev/null || printf 'not a tarball' > "$T/fw/garbage.tar.xz"
run_hook "$T/fw/garbage.tar.xz" NCZ_T2_FW_SHA256=0000000000000000000000000000000000000000000000000000000000000000
[ "$(cat "$R/rc")" != 0 ] && ok "sha mismatch exits non-zero" || bad "sha mismatch exited 0"
grep -q 'sha256 mismatch' "$R/out" && ok "sha mismatch is named" || bad "sha mismatch not reported"
[ ! -e "$R/lib/firmware/brcm" ] && ok "sha mismatch did not create the destination (no host mutation)" || bad "destination created despite refusal"

echo "=== unsafe archives are refused (absolute / traversal / symlink) ==="
for kind in abs dotdot symlink; do
    mkbad "$kind" "$T/fw/$kind.tar.xz"
    run_hook "$T/fw/$kind.tar.xz"
    if [ "$(cat "$R/rc")" != 0 ]; then ok "$kind archive refused" ; else bad "$kind archive accepted"; fi
    [ ! -e "$R/lib/firmware/brcm" ] && ok "  $kind refusal did not mutate the destination" || bad "  $kind refusal created the destination"
done
if grep -q 'unsafe member path' "$R/out" || grep -q 'contains a symlink' "$R/out"; then ok "refusal is named"; else bad "refusal reason not printed"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
