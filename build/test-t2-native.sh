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
for pat in 'adityagarg8' 't2-ubuntu-repo' 'apt-get' 'sources.list.d/t2' 'KEY.gpg' 'get_from_online' 'dmg2img'; do
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
