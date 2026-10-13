#!/bin/bash
# test-image-assets.sh -- no project-owned SSH key, and no private-LAN rescue
# address, may ship in a public image.
#
# Public NCZ-OS images used to write two project-owned ed25519 public keys into
# authorized_keys on the installed system (post-install/35-ssh.sh), in the
# ncz-recovery container (post-install/38-recovery-container.sh) and in the
# installer ramdisk (preseed/ssh-keys.sh), and the rescue partition assigned a
# fixed private /24 address when DHCP failed. This test scans every tracked
# image-bound file and fails if any of that comes back:
#
#   1. an SSH public key body (ssh-ed25519/ssh-rsa/ecdsa-sha2-*/sk-* AAAA...)
#   2. the retired key comments (argos-backup, work-laptop)
#   3. code that writes or copies an authorized_keys file
#      (sshd "AuthorizedKeysFile" directives and comments are allowed)
#   4. a 192.168.x.y address in executable (non-comment) lines
#   5. the rescue static-address fallback being created by the rescue builder,
#      or 72-rescue-partition.sh no longer stripping it from older archives
#
# The scanner is also run against planted fixtures so each rule is proven to
# fire (both directions), not just to stay quiet on a clean tree.
#
# Usage: build/test-image-assets.sh
# Exit 0 = all PASS, 1 = one or more FAIL, 2 = harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# Image-bound paths: everything that is copied into an image, an installer
# ramdisk, the rescue partition or the recovery container. Hash-bound GPL
# kernel source trees are excluded (assets/kernel/*/src, kernel-source/).
SHIPPED_DIRS="post-install preseed packages packaging assets branding build/iso"
SHIPPED_FILES="build/build-rescue-rootfs.sh build/build-mgmt-rootfs.sh build/build-base-rootfs.sh build/build-baked-rootfs.sh"

KEY_RE='(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+AAAA[0-9A-Za-z+/]{16,}'
NAME_RE='argos-backup|work-laptop'
AK_WRITE_RE='(>>?|\btee\b|\binstall\b|\bcp\b|\bmv\b|\bln\b|\bcat\b|\becho\b|\bprintf\b|ssh-copy-id|write_text|open\()[^#]*authorized_keys|authorized_keys[^#]*(>>?|\btee\b)'
LAN_RE='192\.168\.[0-9]{1,3}\.[0-9]{1,3}'

# list_files <root>: tracked image-bound text files under <root>, one per line.
list_files() {
    local root="$1"
    (
        cd "$root" || exit 2
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            git ls-files -- $SHIPPED_DIRS $SHIPPED_FILES 2>/dev/null
        else
            # shellcheck disable=SC2086
            for p in $SHIPPED_DIRS $SHIPPED_FILES; do
                [ -e "$p" ] && find "$p" -type f
            done
        fi
    ) | grep -v -E '^assets/kernel/[^/]+/src/|^kernel-source/|^build/iso/tests/' || true
}

# non_comment <file>: print "lineno:text" for lines that are not shell/python
# comments (leading '#').
non_comment() {
    awk '!/^[[:space:]]*#/ { printf "%d:%s\n", NR, $0 }' "$1"
}

# scan <root>: print one finding per line, "rule<TAB>path:line". Never prints
# the matched text (it may be key material).
scan() {
    local root="$1" f path hits
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        path="$root/$f"
        [ -f "$path" ] || continue
        grep -Iq . "$path" 2>/dev/null || continue   # skip binaries / empty
        hits=$(grep -n -E "$KEY_RE" "$path" 2>/dev/null | cut -d: -f1)
        for l in $hits; do printf 'ssh-key-body\t%s:%s\n' "$f" "$l"; done
        hits=$(grep -n -E "$NAME_RE" "$path" 2>/dev/null | cut -d: -f1)
        for l in $hits; do printf 'retired-key-comment\t%s:%s\n' "$f" "$l"; done
        hits=$(non_comment "$path" | grep -v 'AuthorizedKeysFile' \
               | grep -E "$AK_WRITE_RE" | cut -d: -f1)
        for l in $hits; do printf 'authorized_keys-write\t%s:%s\n' "$f" "$l"; done
        hits=$(non_comment "$path" | grep -E "$LAN_RE" | cut -d: -f1)
        for l in $hits; do printf 'private-lan-address\t%s:%s\n' "$f" "$l"; done
    done < <(list_files "$root")
    # Rule 5: the rescue fallback must not be created, and must be stripped.
    local rr="$root/build/build-rescue-rootfs.sh" rp="$root/post-install/72-rescue-partition.sh"
    if [ -f "$rr" ] && non_comment "$rr" | grep -q 'ncz-rescue-net-fallback'; then
        printf 'rescue-static-fallback\t%s\n' "build/build-rescue-rootfs.sh"
    fi
    if [ -f "$rp" ] && ! non_comment "$rp" | grep -q 'rm -f .*ncz-rescue-net-fallback'; then
        printf 'rescue-fallback-not-stripped\t%s\n' "post-install/72-rescue-partition.sh"
    fi
    return 0
}

echo "[image-assets] real tree: $REPO"
NFILES=$(list_files "$REPO" | wc -l | tr -d ' ')
if [ "$NFILES" -lt 50 ]; then
    echo "EXTRACT FAILED: only $NFILES image-bound files found under $REPO" >&2
    exit 2
fi
FINDINGS=$(scan "$REPO")
if [ -z "$FINDINGS" ]; then
    ok "no SSH key material, authorized_keys writers, private LAN addresses or rescue static fallback in $NFILES image-bound files"
else
    bad "image-bound files carry SSH key material or fixed-address network defaults:"
    printf '%s\n' "$FINDINGS" | sed 's/^/        /'
fi

# ---- fixtures: prove every rule fires --------------------------------------
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkfix() {   # mkfix <name>: a minimal clean tree (no git) with a compliant rescue pair
    local d="$T/$1"
    mkdir -p "$d/post-install" "$d/preseed" "$d/build" "$d/assets/x"
    for i in $(seq 1 60); do echo "echo clean $i" > "$d/assets/x/f$i.sh"; done
    printf '#!/bin/sh\n# ncz-rescue-net-fallback was removed\necho dhcp\n' > "$d/build/build-rescue-rootfs.sh"
    printf '#!/bin/sh\nrm -f "$MNT/usr/local/sbin/ncz-rescue-net-fallback"\n' > "$d/post-install/72-rescue-partition.sh"
    printf '%s\n' "$d"
}
# expect_rule <label> <rule> <fixture-root>
expect_rule() {
    local out; out=$(scan "$3")
    if printf '%s\n' "$out" | grep -q "^$2	"; then ok "$1"; else bad "$1 (rule $2 did not fire)"; fi
}

d=$(mkfix clean)
printf '#!/bin/sh\n# write the owner keys to ~/.ssh/authorized_keys yourself\n' > "$d/post-install/35-ssh.sh"
printf 'AuthorizedKeysFile .ssh/authorized_keys\n' > "$d/preseed/sshd.conf"
if [ -z "$(scan "$d")" ]; then ok "clean fixture (comment + AuthorizedKeysFile) passes"; else bad "clean fixture flagged: $(scan "$d" | tr '\n' ' ')"; fi

# Key material is assembled at run time so this file itself carries none.
FAKE_BODY="AAAA$(printf 'C3NzaC1lZDI1NTE5AAAAIFAKEFAKEFAKEFAKEFAKEFAKE')"
d=$(mkfix key);  printf 'K="ssh-ed25519 %s someone"\n' "$FAKE_BODY" > "$d/preseed/k.sh"
expect_rule "planted ed25519 key body is caught" ssh-key-body "$d"
d=$(mkfix rsa);  printf '# ssh-rsa %s old\n' "$FAKE_BODY" > "$d/post-install/k.sh"
expect_rule "planted ssh-rsa key body is caught even in a comment" ssh-key-body "$d"
d=$(mkfix name); printf 'echo "%s"\n' "argos""-backup" > "$d/post-install/n.sh"
expect_rule "retired key comment is caught" retired-key-comment "$d"
d=$(mkfix ak1);  printf 'cat > /root/.ssh/authorized_keys <<EOF\nEOF\n' > "$d/post-install/a.sh"
expect_rule "cat > authorized_keys is caught" authorized_keys-write "$d"
d=$(mkfix ak2);  printf 'echo "$KEYS" >> "$home/.ssh/authorized_keys"\n' > "$d/preseed/a.sh"
expect_rule "echo >> authorized_keys is caught" authorized_keys-write "$d"
d=$(mkfix ak3);  printf 'install -m 0600 keys "$MNT/root/.ssh/authorized_keys"\n' > "$d/post-install/a.sh"
expect_rule "install ... authorized_keys is caught" authorized_keys-write "$d"
d=$(mkfix lan);  printf 'ip addr add %s/24 dev eth0\n' "192.168.""1.50" > "$d/build/build-rescue-rootfs.sh"
printf '#!/bin/sh\nrm -f "$MNT/usr/local/sbin/ncz-rescue-net-fallback"\n' > "$d/post-install/72-rescue-partition.sh"
expect_rule "private LAN address in executable code is caught" private-lan-address "$d"
d=$(mkfix fb);   printf 'cat > "$CHROOT/usr/local/sbin/ncz-rescue-net-fallback" <<EOF\nEOF\n' > "$d/build/build-rescue-rootfs.sh"
expect_rule "rescue builder creating the static fallback is caught" rescue-static-fallback "$d"
d=$(mkfix strip); printf '#!/bin/sh\necho no strip\n' > "$d/post-install/72-rescue-partition.sh"
expect_rule "rescue hook that stops stripping the fallback is caught" rescue-fallback-not-stripped "$d"

echo ""
echo "[image-assets] $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
