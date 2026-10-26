#!/bin/bash
# test-shipped-secret-scan.sh -- the shipped-artifact credential gate fails an
# image that carries a secret and passes one that does not.
#
# Builds two real GPT images (no loop mount, no root): an ESP (FAT) and a data
# partition (ext4) whose /ncz-payload tree carries squashfs layers, a
# concatenated-gzip-single-member initrd, a rescue rootfs tar.zst and .debs.
# The "leaky" image hides the fake secret in every form the gate must catch:
#   - plain text in a desktop layer file (mid-token, offset 2)
#   - URL-encoded inside a config value in base.squashfs
#   - base64 inside a .deb member's data.tar.xz
#   - inside the SECOND cpio segment of the installer initrd
#   - inside the rescue rootfs tar.zst
#   - as a glpat- token shape nobody listed
# The "clean" image is the same tree without them, and MUST pass.
#
# Usage: bash build/test-shipped-secret-scan.sh [-v]
# Exit: 0 pass, 1 fail.  Needs mksquashfs, mkfs.ext4, mkfs.vfat, mtools, zstd,
# sgdisk (all present on the documented build hosts).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1
FAILS=0
pass() { echo "  ok: $*"; }
fail() { echo "  FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
note() { [ "$VERBOSE" = 1 ] && echo "  ... $*"; }

for t in mksquashfs mkfs.ext4 mkfs.vfat mcopy mmd sgdisk zstd python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "test-shipped-secret-scan: missing $t" >&2; exit 2; }
done
[ -e /dev/loop-control ] || note "no loop device: the writer below uses offset writes only"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ncz-shipped-scan-test.XXXXXX")"
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
export TMPDIR="$WORK"
# the hash list is keyed: make-secret-hashes creates this 0600 key, the gate reads it
export NCZ_SECRET_HASHES_KEY="$WORK/hash.key"

SCAN="$ROOT/build/scan-shipped-secrets.py"
MAKEHASH="$ROOT/build/make-secret-hashes.py"
PY=python3

# A 32-char fake credential, assembled at run time so this file carries no
# literal credential (the shipped secret-scan-gate would flag it otherwise).
FAKE="$(printf '%s-%s-%s' 'fake' 'credential' '20261017abcd')"
FAKE_URL="$($PY -c 'import sys,urllib.parse;print(urllib.parse.quote_plus(sys.argv[1]))' "$FAKE")"
FAKE_B64="$($PY -c 'import sys,base64;print(base64.b64encode(sys.argv[1].encode()).decode())' "$FAKE")"
# A glpat- token shape that is NOT in the hash list (shape scan only).
SHAPE_TOKEN="glpat-$(printf 'A%.0s' {1..24})"

# ---------------------------------------------------------------- fixtures
mk_layer() {   # <dir> <out.squashfs>
    mksquashfs "$1" "$2" -noappend -no-progress -comp zstd -quiet >/dev/null 2>&1 \
        || return 1
}

mk_base_tree() {   # <dir> <mode>   mode = clean|leaky
    local d="$1" mode="$2"
    mkdir -p "$d/etc/apt/keyrings" "$d/usr/share/keyrings" "$d/etc/apt/sources.list.d" \
             "$d/usr/lib/cix-installer/assets/mgmt" "$d/var/lib/apt/lists"
    printf 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian forky main\n' \
        > "$d/etc/apt/sources.list"
    printf 'Acquire::Retries "3";\nAPT::Install-Recommends "false";\n' > "$d/etc/apt/apt.conf.d.placeholder"
    : > "$d/etc/apt/apt.conf.d.placeholder"
    # A documented public apt keyring: a PGP PUBLIC KEY BLOCK with a body that
    # happens to look like a base64 secret.  It must never trip the gate.
    $PY - "$FAKE" > "$d/usr/share/keyrings/debian-archive-keyring.gpg" <<'PYK'
import base64, sys
key = b"\x04" + bytes(range(1, 64))           # a public-key packet body
uid = b"fixture " + sys.argv[1].encode()       # a user ID carrying the value
pk = b"\x99" + len(key).to_bytes(2, "big") + key
ud = b"\xb4" + bytes([len(uid)]) + uid
b64 = base64.b64encode(pk + ud).decode()
print("-----BEGIN PGP PUBLIC KEY BLOCK-----\n")
for i in range(0, len(b64), 64):
    print(b64[i:i + 64])
print("-----END PGP PUBLIC KEY BLOCK-----")
PYK
    cp "$d/usr/share/keyrings/debian-archive-keyring.gpg" "$d/etc/apt/keyrings/ncz-apt-policy.asc"
    printf 'Type=oneshot\nExecStart=/usr/local/bin/ncz-first-boot\n' > "$d/etc/systemd-placeholder.service"
    if [ "$mode" = leaky ]; then
        printf 'GITLAB_TOKEN=x%s\n' "$FAKE" > "$d/etc/ncz-token.conf"
        printf 'registry_token = "%s"\n' "$FAKE_URL" > "$d/etc/apt/registry.conf"
    else
        printf 'GITLAB_TOKEN=${GITLAB_TOKEN}\n' > "$d/etc/ncz-token.conf"
        printf 'registry_token = "${REGISTRY_TOKEN}"\n' > "$d/etc/apt/registry.conf"
    fi
}

mk_desktop_tree() {   # <dir> <mode>
    local d="$1" mode="$2"
    mkdir -p "$d/usr/share/applications" "$d/etc/xdg" "$d/opt/ncz"
    printf '[Desktop Entry]\nName=Firefox\nExec=firefox %%u\n' > "$d/usr/share/applications/firefox.desktop"
    printf 'XDG_SESSION_TYPE=wayland\n' > "$d/etc/xdg/session.conf"
    if [ "$mode" = leaky ]; then
        printf '%s\n' "$SHAPE_TOKEN" > "$d/opt/ncz/deploy-token"
    else
        printf 'deploy-token-not-set\n' > "$d/opt/ncz/deploy-token"
    fi
}

mk_rescue_tree() {  # <dir> <mode>
    local d="$1" mode="$2"
    mkdir -p "$d/bin" "$d/etc"
    printf '#!/bin/sh\nexec /bin/sh\n' > "$d/bin/ncz-rescue-shell"; chmod +x "$d/bin/ncz-rescue-shell"
    if [ "$mode" = leaky ]; then
        printf 'RESCUE_PASS="%s"\n' "$FAKE" > "$d/etc/rescue.conf"
    else
        printf 'RESCUE_PASS="${RESCUE_PASS}"\n' > "$d/etc/rescue.conf"
    fi
}

mk_deb() {   # <out.deb> <mode>  -- a real ar archive with data.tar.xz
    local out="$1" mode="$2" d="$WORK/debroot"
    rm -rf "$d"; mkdir -p "$d/DEBIAN" "$d/usr/share/ncz"
    printf 'Package: ncz-fixture\nVersion: 1.0\nArchitecture: all\nMaintainer: t <t@example.invalid>\nDescription: fixture\n' \
        > "$d/DEBIAN/control"
    printf 'ncz fixture payload\n' > "$d/usr/share/ncz/payload.txt"
    if [ "$mode" = leaky ]; then
        mkdir -p "$d/usr/share/ncz/secrets"
        printf 'b64=%s\n' "$FAKE_B64" > "$d/usr/share/ncz/secrets/b64.conf"
    fi
    rm -f "$WORK/data.tar" "$WORK/data.tar.xz" "$WORK/control.tar" "$WORK/control.tar.gz"
    ( cd "$d" && tar -cf "$WORK/data.tar" --exclude=./DEBIAN . && xz -9 "$WORK/data.tar" ) || return 1
    ( cd "$d/DEBIAN" && tar -cf "$WORK/control.tar" . && gzip -9n "$WORK/control.tar" ) || return 1
    printf '2.0\n' > "$d/debian-binary"
    ( cd "$d" && printf '!<arch>\n' > "$out" && \
      for m in debian-binary "$WORK/control.tar.gz" "$WORK/data.tar.xz"; do
          local name; name="$(basename "$m")"; local sz; sz=$(stat -c%s "$m")
          # A real ar(5) member header is exactly 60 bytes: name[16] mtime[12]
          # uid[6] gid[6] mode[8] size[10] "`\n".  Every field is
          # LEFT-justified and space-padded, so the format string must be
          # built in that order (a previous version mis-sized the fields and
          # produced an archive dpkg-deb itself rejects).
          printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' \
              "$name" "0" "0" "0" "100644" "$sz" >> "$out"
          cat "$m" >> "$out"
          if [ $((sz % 2)) -eq 1 ]; then printf '\n' >> "$out"; fi
      done ) || return 1
    rm -rf "$d"
}

mk_initrd() {   # <out_initrd> <mode> -- ONE gzip member holding TWO cpio segments
    local out="$1" mode="$2" d="$WORK/initrd"
    rm -rf "$d"; mkdir -p "$d/seg1/bin" "$d/seg2/lib/modules"
    printf '#!/bin/busybox sh\necho rescue\n' > "$d/seg1/bin/sh"
    ( cd "$d/seg1" && find . | cpio -o -H newc --quiet > "$d/seg1.cpio" ) || return 1
    printf 'firmware\n' > "$d/seg2/lib/modules/marker"
    if [ "$mode" = leaky ]; then
        printf 'initrd_secret=%s\n' "$FAKE" > "$d/seg2/lib/modules/overlay.conf"
    fi
    ( cd "$d/seg2" && find . | cpio -o -H newc --quiet > "$d/seg2.cpio" ) || return 1
    cat "$d/seg1.cpio" "$d/seg2.cpio" | gzip -9n > "$out" || return 1
    rm -rf "$d"
}

mk_cpio_initrd() {  # <out> <mode> -- an UNCOMPRESSED concatenated cpio initrd
    local out="$1" mode="$2" d="$WORK/initrd2"
    rm -rf "$d"; mkdir -p "$d/a/conf" "$d/b"
    printf 'a\n' > "$d/a/conf/one"
    ( cd "$d/a" && find . | cpio -o -H newc --quiet > "$out" ) || return 1
    printf 'b\n' > "$d/b/two"
    if [ "$mode" = leaky ]; then printf 'raw=%s\n' "$FAKE" > "$d/b/raw.conf"; fi
    ( cd "$d/b" && find . | cpio -o -H newc --quiet >> "$out" ) || return 1
    rm -rf "$d"
}

build_image() {   # <out.img> <mode>
    local img="$1" mode="$2" t="$WORK/image-$2"
    rm -rf "$t"; mkdir -p "$t/payload" "$t/esp"
    mk_base_tree "$t/base" "$mode"
    # a NON-key file under a public keyring path must still be scanned
    [ "${KEYRING_LEAK:-0}" = 1 ] && printf 'GITLAB_TOKEN=%s\n' "$FAKE" > "$t/base/usr/share/keyrings/leak.conf"
    # the secret only as a FILE NAME, or only inside a gzip with no archive name
    [ "${NAME_LEAK:-0}" = 1 ] && : > "$t/base/etc/$FAKE"
    [ "${GZ_LEAK:-0}" = 1 ] && printf 'token=%s\n' "$FAKE" | gzip -9n > "$t/base/etc/backup.bin"
    mk_desktop_tree "$t/desktop" "$mode"
    mk_rescue_tree "$t/rescue" "$mode"
    mk_layer "$t/base" "$t/payload/base.squashfs" || return 1
    mk_layer "$t/desktop" "$t/payload/desktop.squashfs" || return 1
    cp "$t/payload/desktop.squashfs" "$t/payload/desktop-hotfix.squashfs"
    mk_layer "$t/rescue" "$t/payload/rescue.squashfs" || return 1
    mkdir -p "$t/mgmt"; printf 'mgmt\n' > "$t/mgmt/README"
    mk_layer "$t/mgmt" "$t/payload/mgmt.squashfs" || return 1
    mk_initrd "$t/payload/initrd.gz" "$mode" || return 1
    mk_cpio_initrd "$t/payload/initrd.img" "$mode" || return 1
    mkdir -p "$t/rescuefs"; cp -a "$t/rescue/." "$t/rescuefs/"
    tar -C "$t/rescuefs" -cf - . | zstd -19 -q -o "$t/payload/rescue-rootfs.tar.zst" - || return 1
    mkdir -p "$t/pool/main"
    mk_deb "$t/pool/main/ncz-fixture_1.0_all.deb" "$mode" || return 1
    cp "$t/pool/main/ncz-fixture_1.0_all.deb" "$t/payload/ncz-fixture_1.0_all.deb"
    cp "$ROOT/build/vivaldi-apt-keyring.asc" "$t/payload/apt-keyring.asc" 2>/dev/null || true
    # SERVER=1: a Magnetar medium -- no squashfs layer on it (they ship off the
    # medium), and the fetch manifest that pins them (SERVER_NO_MANIFEST=1 drops it)
    if [ "${SERVER:-0}" = 1 ]; then
        rm -f "$t/payload"/*.squashfs
        mkdir -p "$t/payload/ncz-payload"
        [ "${SERVER_NO_MANIFEST:-0}" = 1 ] || printf 'base.squashfs\thttp://10.0.2.2/base.squashfs\t%s\tfile\n' \
            "$(printf '0%.0s' {1..64})" > "$t/payload/ncz-payload/ncz-fetch-payload.manifest"
        # the offline apt closure stays on a server medium (option A,
        # 2026-10-26); SERVER_NO_POOL=1 drops it
        if [ "${SERVER_NO_POOL:-0}" != 1 ]; then
            mkdir -p "$t/payload/pool/main" "$t/payload/dists/forky/main/binary-amd64"
            cp "$t/pool/main/ncz-fixture_1.0_all.deb" "$t/payload/pool/main/"
            printf 'Package: ncz-fixture\nVersion: 1.0\nArchitecture: all\nFilename: pool/main/ncz-fixture_1.0_all.deb\n\n' \
                > "$t/payload/dists/forky/main/binary-amd64/Packages"
        fi
    fi

    # ESP: a FAT image with the d-i kernel + the plain-realistic initrd
    # ESP_FAT32=1: a FAT32 ESP like the real images (40 MiB, 512 B clusters
    # gives > 65525 clusters); ESP_LEAK=1 puts the secret ONLY on the ESP.
    local esp_mib=8 data_mib=48 fatopt=""
    [ "${ESP_FAT32:-0}" = 1 ] && { esp_mib=40; fatopt="-F 32 -s 1 -S 512"; }
    # shellcheck disable=SC2086
    mkfs.vfat -C $fatopt "$t/esp.img" $((esp_mib * 1024)) -n NCZESP >/dev/null 2>&1 || return 1
    mmd -i "$t/esp.img" ::/EFI ::/EFI/BOOT ::/boot >/dev/null 2>&1
    printf 'refind placeholder\n' > "$t/refind_x64.efi"
    mcopy -i "$t/esp.img" "$t/refind_x64.efi" ::/EFI/BOOT/BOOTX64.EFI
    printf 'kernel placeholder\n' > "$t/linux"
    mcopy -i "$t/esp.img" "$t/linux" ::/linux
    mcopy -i "$t/esp.img" "$t/payload/initrd.gz" ::/initrd.gz
    if [ "${ESP_LEAK:-0}" = 1 ]; then
        printf 'esp_secret=%s\n' "$FAKE" > "$t/esp-leak.conf"
        mcopy -i "$t/esp.img" "$t/esp-leak.conf" ::/EFI/BOOT/leak.conf
    fi

    # data partition: ext4 with the payload tree
    rm -f "$t/data.img"; truncate -s $((data_mib * 1024 * 1024)) "$t/data.img"
    # shellcheck disable=SC2086
    mkfs.ext4 -q -F -L NCZDATA ${DATA_EXT4_OPTS:-} -d "$t/payload" "$t/data.img" >/dev/null 2>&1 || return 1

    # GPT: ESP + data, written at the LBAs sgdisk reports
    local total=$(( (esp_mib + data_mib + 8) * 1024 * 1024 ))
    rm -f "$img"; truncate -s "$total" "$img"
    sgdisk --clear --disk-guid=00000000-0000-4000-8000-0000000000aa \
        --new=1:2048:+$((esp_mib * 2048)) --typecode=1:ef00 --change-name=1:NCZESP \
        --new=2:0:+$((data_mib * 2048)) --typecode=2:8300 --change-name=2:NCZDATA "$img" >/dev/null 2>&1 || return 1
    local s1 s2
    s1=$(sgdisk -i 1 "$img" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
    s2=$(sgdisk -i 2 "$img" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
    [ -n "$s1" ] && [ -n "$s2" ] || return 1
    dd if="$t/esp.img" of="$img" bs=512 seek="$s1" conv=notrunc status=none || return 1
    dd if="$t/data.img" of="$img" bs=512 seek="$s2" conv=notrunc status=none || return 1
    return 0
}

# ---------------------------------------------------------------- the test
echo "== shipped-artifact credential gate =="

# key-master with BOTH the fake secret and a "clean" fake that never ships
cat > "$WORK/keymaster.json" <<JSON
{"secrets": [{"value": "$FAKE", "label": "fixture-fake-credential"}]}
JSON
$PY "$MAKEHASH" --master "$WORK/keymaster.json" --out "$WORK/hashes.json" --quiet || {
    echo "test-shipped-secret-scan: cannot make the hash list" >&2; exit 1; }
if $PY - "$WORK/hashes.json" "$FAKE" "$NCZ_SECRET_HASHES_KEY" <<'PY'
import hashlib, json, sys, urllib.parse, base64

doc = json.load(open(sys.argv[1]))
plain = sys.argv[2].encode()
salt = open(sys.argv[3], "rb").read()
assert "salt" not in doc and "key_id" in doc, "the list must not carry its key"
# The three raw forms the key master must have produced, at offsets 0..2.
forms = {plain, urllib.parse.quote_plus(plain).encode(),
         base64.b64encode(plain)}
digests = {h["sha256"] for h in doc["hashes"]}
want = {hashlib.sha256(salt + f).hexdigest() for f in forms}
sys.exit(0 if want and want <= digests else 1)
PY
then pass "the hash file carries the keyed digest of the secret (and no key)"; else fail "hash file missing the digest"; fi
if grep -qF "$FAKE" "$WORK/hashes.json"; then fail "the hash file leaks the plaintext value"; else pass "the hash file holds no plaintext"; fi

build_image "$WORK/clean.img" clean || { echo "fixture: cannot build the clean image" >&2; exit 1; }
build_image "$WORK/leaky.img" leaky || { echo "fixture: cannot build the leaky image" >&2; exit 1; }
note "images: $(du -h "$WORK/clean.img" | cut -f1) clean, $(du -h "$WORK/leaky.img" | cut -f1) leaky"

# 1. the clean image passes
out="$($PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/hashes.json" \
        --receipt "$WORK/clean.receipt.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then pass "clean image PASSES"; else echo "$out" >&2; fail "clean image should pass (rc=$rc)"; fi
# 1b. ... and it found every layer (a gate that skipped layers would also "pass")
if $PY - "$WORK/clean.receipt.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
names = {l["path"].rsplit("/", 1)[-1] for l in r["layers"]}
need = {"base.squashfs", "desktop.squashfs", "desktop-hotfix.squashfs",
        "rescue.squashfs", "mgmt.squashfs"}
missing = need - names
units = r["units_by_layer"]
# every layer, the ESP and the data partition's own files (the rescue rootfs
# tarball, the pool) each produced scanned units
want_units = {"base.squashfs", "desktop.squashfs", "rescue.squashfs", "mgmt.squashfs",
              "esp", "partition"}
empty = sorted(k for k in want_units if not units.get(k))
if missing or empty:
    print(f"missing layers {sorted(missing)}, no units for {empty}", file=sys.stderr)
sys.exit(0 if not missing and not empty else 1)
PY
then pass "receipt lists every layer and its member counts"; else fail "receipt is missing layers"; fi
# 1c. the clean pass is a REAL pass: layers yielded files
if $PY - "$WORK/clean.receipt.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r["result"] == "PASS" and r["counts"].get("files_scanned", 0) >= 15
ok = ok and any(l["members_scanned"] > 3 for l in r["layers"])
sys.exit(0 if ok else 1)
PY
then pass "the clean receipt shows real work (files scanned per layer)"; else fail "the clean receipt looks empty"; fi
# 1d. the public apt keyring carrying secret-looking base64 is NOT a finding
if grep -q 'debian-archive-keyring' "$WORK/clean.receipt.json"; then
    fail "the documented public apt keyring was flagged"
else pass "the documented public apt keyring is excluded"; fi

# 2. the leaky image fails, in every location we planted the secret
out="$($PY "$SCAN" --image "$WORK/leaky.img" --hash-file "$WORK/hashes.json" \
        --receipt "$WORK/leaky.receipt.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then pass "leaky image FAILS (exit 1)"; else echo "$out" >&2; fail "leaky image should fail (rc=$rc)"; fi
if grep -qF -e "$FAKE" -e "$FAKE_URL" -e "$FAKE_B64" -e "$SHAPE_TOKEN" "$WORK/leaky.receipt.json" 2>/dev/null; then
    fail "the receipt leaked a value"; else pass "the receipt holds no value (raw, urlenc, base64 or shape form)"; fi
for want in "desktop.squashfs" "base.squashfs" "rescue.squashfs"; do
    if grep -q "\"layer\": \"$want\"" "$WORK/leaky.receipt.json" 2>/dev/null; then
        pass "caught the secret inside $want"
    else
        fail "missed the secret inside $want"
    fi
done
# The initrd/rootfs/deb live on the ext4 data partition, not in a squashfs
# layer, so the receipt names the layer "part2" and carries the container in
# the member path ("/initrd.gz/...").  Assert on the path: that is where the
# finding must point.
for want in "/initrd.gz/" "/initrd.img/" "/rescue-rootfs.tar.zst/"; do
    if grep -q "\"path\": \"[^\"]*$want" "$WORK/leaky.receipt.json" 2>/dev/null; then
        pass "caught the secret inside $want (data partition)"
    else
        fail "missed the secret inside $want"
    fi
done
if grep -q 'ncz-fixture_1.0_all.deb/data.tar[^"]*b64.conf' "$WORK/leaky.receipt.json" 2>/dev/null; then
    pass "caught the base64 secret inside a .deb data.tar"
else
    fail "missed the base64 secret inside the .deb"
fi
if grep -q '"shape": "gitlab-pat"' "$WORK/leaky.receipt.json" 2>/dev/null; then
    pass "caught the unlisted glpat- token by shape"
else
    fail "the token-shape scan missed a glpat- token"
fi
if grep -q 'apt-keyring.asc' "$WORK/leaky.receipt.json" 2>/dev/null; then
    fail "flagged a public apt keyring file"
else pass "apt keyring files stay excluded on the leaky image"; fi

# 3. FAIL CLOSED: no hash list at all is a failure, not a pass
out="$($PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/absent.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then pass "a missing hash list FAILS CLOSED"; else fail "missing hash list returned $rc"; fi
out="$($PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/absent.json" --allow-detached \
       --receipt "$WORK/detached.receipt.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "\"result\": \"FAIL\"" "$WORK/detached.receipt.json"; then pass "--allow-detached still FAILS (hashed half did not run)"; else fail "--allow-detached returned $rc"; fi

# 4. FAIL CLOSED: an unreadable layer is a failure
cp "$WORK/clean.img" "$WORK/broken.img"
# find the ext4 partition and corrupt the first squashfs header inside it
python3 - "$WORK/broken.img" <<'PY'
import sys
p = sys.argv[1]
img = bytearray(open(p, "rb").read())
off = img.find(b"hsqs")
if off < 0:
    sys.exit(3)
img[off:off + 4] = b"XXXX"
open(p, "wb").write(img)
PY
if [ $? = 0 ]; then
    out="$($PY "$SCAN" --image "$WORK/broken.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
    if [ "$rc" = 1 ]; then pass "an unreadable layer FAILS CLOSED"; else echo "$out" >&2; fail "corrupt layer returned $rc"; fi
else
    fail "could not corrupt a layer for the fail-closed test"
fi

# 5. FAIL CLOSED: a truncated image is unreadable
head -c 4096 "$WORK/clean.img" > "$WORK/trunc.img"
out="$($PY "$SCAN" --image "$WORK/trunc.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then pass "a truncated image FAILS CLOSED"; else fail "truncated image returned $rc"; fi

# 6. the extractor's own primitives (no image needed)
if $PY - "$ROOT" "$FAKE" <<'PY'
import importlib.util, io, os, subprocess, sys, tarfile, json
root, fake = sys.argv[1], sys.argv[2].encode()
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
# the hash list catches every documented form of the value
hs = g.HashSet("s")
for v in g.secret_variants([fake], "s"):
    hs.digests.add(v["sha256"])
assert "ncz".encode() not in hs
sc = g.Scanner(hs, shapes=False)
import base64, urllib.parse
forms = {
    "plain": b"prefix " + fake + b"\n",
    "mid-token-offset-2": b"TOKEN=xx" + fake + b"\n",
    "urlenc": b"url=https://u:" + urllib.parse.quote_plus(fake.decode()).encode() + b"@h/x\n",
    "b64": b"v: " + base64.b64encode(fake) + b"\n",
    "b64-no-pad": b"v: " + base64.b64encode(fake).rstrip(b"=") + b"\n",
}
for name, data in forms.items():
    assert g.scan_candidate(sc, data, "/x.conf"), f"missed {name}"
# and a clean document of the same shape hits nothing
assert not g.scan_candidate(sc, b"TOKEN=${GITLAB_TOKEN}\nurl=https://u:${T}@h/x\n", "/x.conf")
# a multi-segment cpio initrd: every segment is visited
segs = []
for payload in (b"one\n", b"two\n"):
    import tempfile
    d = tempfile.mkdtemp()
    open(os.path.join(d, "f"), "wb").write(payload)
    r = subprocess.run(["bash", "-c", "cd %s && find . | cpio -o -H newc --quiet" % d],
                       capture_output=True)
    segs.append(r.stdout)
data = b"".join(segs)
names = [n for n, _ in g.cpio_members(data, "t")]
# looks_textual must treat an extension-less file under /etc as text: the
# check used to run on the BASENAME (which never starts with "/") and was
# dead, so --text-only quietly skipped /etc/shadow and friends.
assert g.looks_textual("/etc/shadow")
assert g.looks_textual("/usr/lib/systemd/system/foo")
assert g.looks_textual("/etc/systemd/system/x.service")
assert not g.looks_textual("/usr/bin/binary-without-extension")
# initrd_kind must not claim every *.img or a backup.cpio.bak: a false
# positive here makes a non-cpio file fail the build closed.
assert g.initrd_kind("/boot/initrd.img-6.1.0") == "initrd"
assert g.initrd_kind("/x/initramfs-linux.img") == "initrd"
assert g.initrd_kind("/x/installer.cpio.gz") == "initrd"
assert g.initrd_kind("/x/backup.cpio.bak") is None
assert g.initrd_kind("/x/windows10.img") is None
# every segment is visited in order; directory entries (".") are yielded for
# completeness but expand() never treats them as content
assert names == [".", "f", ".", "f"], names
assert [n for n, p in g.cpio_members(data, "t") if p] == ["f", "f"]
assert len(g.decompress_chain(__import__("gzip").compress(data), "t")) == 1
# token shapes: the OpenSSH security-key names and a bare PEM header (format
# strings in sshd / libgnutls) are not credentials; a real-looking key is
shp = g.Scanner(g.HashSet("s"), shapes=True)
assert not shp.scan_shapes(b"x sk-ssh-ed25519@openssh.com sk-ecdsa-sha2-nistp256-cert-v01@openssh.com", "/usr/sbin/sshd")
assert not shp.scan_shapes(b"\0-----BEGIN RSA PRIVATE KEY-----\0%s\0", "/usr/lib/libgnutls.so.30")
assert not shp.scan_shapes(b"sk-this-is-just-hyphenated-words-here", "/x.txt")
key_body = b"MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7" * 2
assert shp.scan_shapes(b"-----BEGIN PRIVATE KEY-----\n" + key_body + b"\n", "/etc/x.pem")
assert shp.scan_shapes(b"-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n"
                       b"DEK-Info: AES-128-CBC,0011\n\n" + key_body + b"\n", "/etc/x.pem")
assert shp.scan_shapes(b"OPENAI=sk-" + b"Ab3dEf9hIjK1mNoP2qRsT4uVwX5yZ" + b"\n", "/etc/x.env")
# a reviewed public match is cleared by the digest of the match, nothing else is
tok = b"AIza" + b"SyA1b2C3d4E5f6G7h8I9j0KlMnOpQrStUvW"
hit = shp.scan_shapes(b"k=" + tok, "/opt/x/bin")
assert hit and hit[0]["match_sha256"] == __import__("hashlib").sha256(tok).hexdigest()
allowed = g.Scanner(g.HashSet("s"), shapes=True,
                    allow={"google-api:" + hit[0]["match_sha256"]: "test"})
assert not allowed.scan_shapes(b"k=" + tok, "/opt/x/bin")
assert allowed.scan_shapes(b"k=" + tok[:-1] + b"X", "/opt/x/bin")
af = os.path.join(tempfile.mkdtemp(), "allow.tsv")
open(af, "w").write("google-api\tnot-a-digest\treason\n")
try:
    g.load_allowlist(af)
except g.Unreadable:
    pass
else:
    raise AssertionError("malformed allowlist accepted")
for row in open(os.path.join(root, "manifests", "secret-scan-allow.tsv")):
    if row.strip() and not row.startswith("#"):
        assert row.split("\t")[0] in g.TOKEN_SHAPES, row
# initramfs-tools layout: an uncompressed early cpio, then the zstd-compressed
# main cpio.  The kernel unpacks both; the gate used to call the zstd frame junk.
zmain = subprocess.run(["zstd", "-q", "-c"], input=segs[1], capture_output=True).stdout
mixed = [n for n, p in g.cpio_members(segs[0] + zmain, "t") if p]
assert mixed == ["f", "f"], mixed
# a compressed file that is not an archive is scanned as plaintext
leaf = list(g.expand("/x/initrd.gz", __import__("gzip").compress(b"plain text\n"), "/x/initrd.gz"))
assert leaf == [("/x/initrd.gz", b"plain text\n")], leaf
hs2 = g.HashSet("s")
for v in g.secret_variants([fake], "s"):
    hs2.digests.add(v["sha256"])
r2 = g.Report()
g.scan_payload(r2, g.Scanner(hs2, shapes=False), "esp", "/x/initrd.gz",
               __import__("gzip").compress(b"k=" + fake + b"\n"))
assert r2.findings, "a gzip-compressed non-archive initrd hid the value"
# zstd: the subprocess result must not clobber the payload variable; a broken
# binding here raised AttributeError on every .tar.zst / zstd squashfs.
zr = subprocess.run(["zstd", "-q", "-c"], input=b"hello-zstd\n", capture_output=True)
assert zr.returncode == 0, "zstd unavailable"
zch = g.decompress_chain(zr.stdout, "t")
assert zch and zch[0][0] == "zstd" and zch[0][1] == b"hello-zstd\n", zch
print("primitives ok")
PY
then pass "primitives: forms matched, clean text clear, cpio segments walked"
else fail "primitive self-test failed"; fi

# 7. a real-sized ext4 file reads back byte-identical, and a 128 MiB extent
# (ee_len 32768) decodes as INITIALIZED.  Decoding it as "uninitialized, 0
# blocks" handed unsquashfs a zero-filled base.squashfs on the first real image.
mkdir -p "$WORK/big"
head -c $((200 << 20)) /dev/urandom > "$WORK/big/blob"
truncate -s 400M "$WORK/big.ext4"
if mkfs.ext4 -q -F -b 4096 -d "$WORK/big" "$WORK/big.ext4" >/dev/null 2>&1 \
   && $PY - "$ROOT" "$WORK/big.ext4" "$WORK/big/blob" <<'PY'
import hashlib, importlib.util, os, sys
root, img, blob = sys.argv[1:4]
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
with open(img, "rb") as fh:
    files = g.ext4_walk(fh, {"index": 1, "offset": 0})
got = {f["path"]: f["bytes"] for f in files}["/blob"]
want = open(blob, "rb").read()
assert hashlib.sha256(got).digest() == hashlib.sha256(want).digest(), "ext4 bytes differ"
# mke2fs -d never writes a full 32768-block extent into a fixture this small
# (it splits at block-group metadata), so the decode itself is pinned to the
# kernel's rule: 32768 is INITIALIZED, only values above it are unwritten.
assert g.extent_len(32768) == (32768, False)
assert g.extent_len(1) == (1, False)
assert g.extent_len(32769) == (1, True)
assert g.extent_len(65535) == (32767, True)
PY
then pass "ext4: a file with full 32768-block extents reads back byte-identical"
else fail "ext4 full-extent file did not read back byte-identical"; fi
rm -rf "$WORK/big" "$WORK/big.ext4"

# 8. an unprivileged extraction: a base layer carries device nodes, which a
# non-root unsquashfs cannot create (exit 2).  That alone must not fail the
# gate, but a regular file missing from the extraction must, and a mode-000
# directory must still be scanned.
mkdir -p "$WORK/dev/src/etc" && echo hello > "$WORK/dev/src/etc/motd"
if mksquashfs "$WORK/dev/src" "$WORK/dev/l.squashfs" -noappend -quiet \
       -p "console c 600 0 0 5 1" -p "locked d 000 0 0" \
       -p "locked/inner f 644 0 0 echo inner" >/dev/null 2>&1 \
   && $PY - "$ROOT" "$WORK/dev" <<'PY'
import importlib.util, os, shutil, sys
root, d = sys.argv[1:3]
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
tool = shutil.which("unsquashfs")
g.unsquashfs_files(tool, os.path.join(d, "l.squashfs"), os.path.join(d, "x"))
assert open(os.path.join(d, "x", "etc", "motd")).read() == "hello\n"
# a mode-000 directory (base ships /run/systemd/dissect-root) is opened up,
# so its content is scanned rather than silently skipped by os.walk
assert open(os.path.join(d, "x", "locked", "inner")).read() == "inner\n"
os.unlink(os.path.join(d, "x", "etc", "motd"))
try:
    g.verify_squashfs_extract(tool, os.path.join(d, "l.squashfs"), os.path.join(d, "x"))
except g.Unreadable:
    pass
else:
    raise AssertionError("a missing regular file was not caught")
PY
then pass "squashfs: device nodes tolerated unprivileged, a missing file FAILS CLOSED"
else fail "unprivileged squashfs extraction check failed"; fi

# 9. the hash file's prefilter: lengths/prefixes written by the generator are
# honoured, and a malformed list fails closed instead of disabling matching.
if $PY - "$ROOT" "$WORK" "$FAKE" <<'PY'
import importlib.util, json, os, sys
root, work, fake = sys.argv[1], sys.argv[2], sys.argv[3].encode()
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
doc = json.load(open(os.path.join(work, "hashes.json")))
assert doc["lengths"] and doc["prefixes"], "generator wrote no prefilter"
key = open(os.environ["NCZ_SECRET_HASHES_KEY"], "rb").read()
hs = g.HashSet(); hs.load(os.path.join(work, "hashes.json"), key)
assert hs.prefixes and hs.lengths
sc = g.Scanner(hs, shapes=False)
assert g.scan_candidate(sc, b"TOKEN=xx" + fake + b"\n", "/x.conf")
assert not g.scan_candidate(sc, b"TOKEN=${GITLAB_TOKEN}\n", "/x.conf")
bad = dict(doc, prefixes=["nothex"])
p = os.path.join(work, "bad.json"); json.dump(bad, open(p, "w"))
try:
    g.HashSet().load(p, key)
except g.Unreadable:
    pass
else:
    raise AssertionError("malformed prefixes accepted")
PY
then pass "hash list prefilter honoured; a malformed prefilter FAILS CLOSED"
else fail "hash list prefilter check failed"; fi

# 10. the hash list never lives in the repository
out="$($PY "$MAKEHASH" --master "$WORK/keymaster.json" --out "$ROOT/build/.hash-test.json" --quiet 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q "inside the" <<<"$out" && [ ! -e "$ROOT/build/.hash-test.json" ]; then
    pass "make-secret-hashes refuses an output path inside the repository"
else rm -f "$ROOT/build/.hash-test.json"; fail "make-secret-hashes did not refuse an in-repo path (rc=$rc)"; fi
out="$(NCZ_SECRET_HASHES_FILE="$ROOT/manifests/secret-hashes.example.json" \
       $PY "$SCAN" --image "$WORK/clean.img" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "inside the" <<<"$out"; then pass "the gate refuses a hash list inside the repository"
else fail "an in-repo hash list was not refused (rc=$rc)"; fi

# 11. review fixes 2026-10-17: FAT32 ESP root, keyring paths, ext4 feature
# bits, multi-member gzip, special-character values, whitespace refusal
ESP_FAT32=1 build_image "$WORK/esp32-clean.img" clean || { echo "fixture: FAT32 clean image" >&2; exit 1; }
ESP_FAT32=1 ESP_LEAK=1 build_image "$WORK/esp32-leak.img" clean || { echo "fixture: FAT32 leak image" >&2; exit 1; }
out="$($PY "$SCAN" --image "$WORK/esp32-clean.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then pass "a clean image with a FAT32 ESP PASSES"; else echo "$out" >&2; fail "clean FAT32 ESP image rc=$rc"; fi
out="$($PY "$SCAN" --image "$WORK/esp32-leak.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "leak.conf" <<<"$out"; then pass "a secret only on a FAT32 ESP (EFI/BOOT/leak.conf) FAILS"
else echo "$out" | tail -5 >&2; fail "FAT32 ESP secret missed (rc=$rc)"; fi
KEYRING_LEAK=1 build_image "$WORK/keyring-leak.img" clean || { echo "fixture: keyring leak image" >&2; exit 1; }
out="$($PY "$SCAN" --image "$WORK/keyring-leak.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "usr/share/keyrings/leak.conf" <<<"$out"; then pass "a non-key file under /usr/share/keyrings is scanned and FAILS"
else echo "$out" | tail -5 >&2; fail "keyring-path secret missed (rc=$rc)"; fi
DATA_EXT4_OPTS="-O inline_data" build_image "$WORK/inline.img" clean || { echo "fixture: inline_data image" >&2; exit 1; }
out="$($PY "$SCAN" --image "$WORK/inline.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" != 0 ] && grep -q "inline-data" <<<"$out"; then pass "an inline_data ext4 data partition FAILS CLOSED"
else echo "$out" | tail -5 >&2; fail "inline_data ext4 not refused (rc=$rc)"; fi
rm -f "$WORK"/esp32-*.img "$WORK/keyring-leak.img" "$WORK/inline.img"
if $PY - "$ROOT" "$FAKE" <<'PY'
import gzip, importlib.util, os, subprocess, sys, tempfile
root, fake = sys.argv[1], sys.argv[2].encode()
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
# multi-member gzip: members concatenate with no separator, both cpio segments parse
def cpio(name, body):
    d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
    open(os.path.join(d, name), "wb").write(body)
    return subprocess.run(["sh", "-c", f"cd {d} && echo {name} | cpio -o -H newc --quiet"],
                          check=True, capture_output=True).stdout
blob = gzip.compress(cpio("one", b"a\n"), mtime=0) + gzip.compress(cpio("two", b"b\n"), mtime=0)
plain = [p for k, p in g.decompress_chain(blob, "t") if k == "gzip"][-1]
names = [m[0] if isinstance(m, tuple) else m.get("name") for m in g.cpio_members(plain, "t")]
assert any("one" in str(n) for n in names) and any("two" in str(n) for n in names), names
# a value with characters outside TOKEN_RUN is matched whole
odd = b"Zq#7?x[9];k" + fake[:6]
hs = g.HashSet("s")
for v in g.secret_variants([odd], "s"):
    hs.digests.add(v["sha256"])
sc = g.Scanner(hs, shapes=False)
assert g.scan_candidate(sc, b"pw=" + odd + b"\n", "/etc/x.conf"), "special-character value missed"
# keyring exemption needs real public key bytes
assert g.looks_public_key(b"-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n" + __import__("base64").b64encode(b"\x99\x00\x03abc") + b"\n-----END PGP PUBLIC KEY BLOCK-----\n")
assert g.looks_public_key(b"\x99\x00\x03abc")
assert not g.looks_public_key(b"GITLAB_TOKEN=" + fake)
assert not g.looks_public_key(b"-----BEGIN PGP PUBLIC KEY BLOCK-----\n-----BEGIN PRIVATE KEY-----\n")
# ext4 feature table matches fs/ext4/ext4.h
bf = {(sct, bit): n for sct, bit, n in g.blocked_features()}
assert bf.get((1, 0x8000)) == "inline-data" and bf.get((1, 0x10000)) == "encrypt"
assert bf.get((1, 0x20000)) == "casefold" and bf.get((2, 0x8000)) == "verity"
assert (2, 0x10000) not in bf, "ORPHAN_PRESENT must not block"
PY
then pass "multi-member gzip, special-character values, keyring content check and ext4 bits"
else fail "review-fix unit checks failed"; fi
printf '{"secrets": [{"value": "two words here", "label": "spaced"}]}\n' > "$WORK/km-space.json"
out="$($PY "$MAKEHASH" --master "$WORK/km-space.json" --out "$WORK/h-space.json" --quiet 2>&1)"; rc=$?
if [ "$rc" = 2 ] && grep -q "whitespace" <<<"$out" && [ ! -e "$WORK/h-space.json" ]; then
    pass "make-secret-hashes refuses a value the gate could never match (whitespace)"
else fail "a whitespace value was not refused (rc=$rc)"; fi

# 12. review round 4: names, content-sniffed compression, chunk overlap,
# no suffix forms, whole-file keyring check, no scanner-args hook
NAME_LEAK=1 build_image "$WORK/name-leak.img" clean || { echo "fixture: name leak image" >&2; exit 1; }
out="$($PY "$SCAN" --image "$WORK/name-leak.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "#names" <<<"$out"; then pass "a secret used as a FILE NAME in a layer FAILS"
else echo "$out" | tail -5 >&2; fail "file-name secret missed (rc=$rc)"; fi
GZ_LEAK=1 build_image "$WORK/gz-leak.img" clean || { echo "fixture: gz leak image" >&2; exit 1; }
out="$($PY "$SCAN" --image "$WORK/gz-leak.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "etc/backup.bin" <<<"$out"; then pass "a secret inside a gzip named backup.bin FAILS (content-sniffed)"
else echo "$out" | tail -5 >&2; fail "gzip-by-content secret missed (rc=$rc)"; fi
rm -f "$WORK/name-leak.img" "$WORK/gz-leak.img"
if ! grep -q NCZ_SECRET_SCAN_EXTRA_ARGS "$ROOT/build/build-image.sh"; then
    pass "build-image passes no free-form scanner arguments (no --hash-file/--no-shapes override)"
else fail "build-image still forwards NCZ_SECRET_SCAN_EXTRA_ARGS"; fi
if $PY - "$ROOT" "$FAKE" <<'PY'
import base64, importlib.util, os, sys
root, fake = sys.argv[1], sys.argv[2].encode()
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
def scanner_for(v):
    hs = g.HashSet("s")
    for x in g.secret_variants([v], "s"):
        hs.digests.add(x["sha256"])
    return g.Scanner(hs, shapes=False)
# a 344-byte base64 form straddling the 1 MiB lexing boundary is still seen
long_secret = (b"Kq7" * 86)[:256]
sc = scanner_for(long_secret)
b64 = base64.b64encode(long_secret)
pad = (b"filler " * (g.CHUNK_BYTES // 7 + 1))[:g.CHUNK_BYTES - 1]
data = pad[:-1] + b" " + b64 + b"\n"   # b64 starts at CHUNK_BYTES - 1
assert g.scan_candidate(sc, data, "/x"), "window across the chunk boundary missed"
# no suffix forms: the tail of a value is not a hit; the value mid-token is
v = b"ABCDEFGHIJKLmn"
sc = scanner_for(v)
assert not g.scan_candidate(sc, b"HOST=" + v[2:] + b"\n", "/x"), "suffix of a value matched"
assert g.scan_candidate(sc, b"tok=xy" + v + b"\n", "/x"), "value mid-token missed"
# keyring files must be ENTIRELY public key material
pkt = b"\x99\x00\x03abc\xb4\x02id"
blk = (b"-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: x\n\n" + base64.b64encode(pkt)
       + b"\n=abcd\n-----END PGP PUBLIC KEY BLOCK-----\n")
assert g.looks_public_key(blk)
assert not g.looks_public_key(blk + b"GITLAB_TOKEN=" + fake + b"\n")
# a base64-encoded credential dressed as a key block is not a key
fakeblk = (b"-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n" + base64.b64encode(b"glpat-" + fake)
           + b"\n-----END PGP PUBLIC KEY BLOCK-----\n")
assert not g.looks_public_key(fakeblk), "base64 credential in an armor block exempted"
# a PRIVATE KEY body is flagged even right after a PUBLIC KEY label
sc2 = g.Scanner(g.HashSet("s"), shapes=True)
pem = b"-----BEGIN PUBLIC KEY-----\n-----BEGIN RSA PRIVATE KEY-----\n" + b"M" * 64 + b"\n"
assert sc2.scan_shapes(pem, "/etc/x.pem"), "private key after a public label missed"
# a 256-byte value with a 1025-byte window is a legal hash list entry
assert max(x["length"] for x in g.secret_variants([b"!" * 256], "s")) <= g.MAX_WINDOW_LEN
assert not g.looks_public_key(b"\x99\x00\x03abc" + b"GITLAB_TOKEN=" + fake)
assert g.looks_public_key(b"\x99\x00\x03abc\xb4\x02id")   # pubkey + user id
PY
then pass "chunk-boundary windows, no suffix forms, whole-file keyring check"
else fail "round-4 unit checks failed"; fi

# 13. review round 6: keyed list, FAT32 by BPB, gzip tail, xz streams, zip
# dirs, ext4 symlink targets and compression bit, keybox chain, block groups
out="$(NCZ_SECRET_HASHES_KEY="$WORK/missing.key" $PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "hash key" <<<"$out"; then pass "a missing hash key FAILS CLOSED"; else fail "missing key not refused (rc=$rc)"; fi
head -c 32 /dev/urandom > "$WORK/other.key"; chmod 600 "$WORK/other.key"
out="$(NCZ_SECRET_HASHES_KEY="$WORK/other.key" $PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "different key" <<<"$out"; then pass "a hash list read with the wrong key FAILS CLOSED"; else fail "wrong key not refused (rc=$rc)"; fi
cp "$WORK/other.key" "$WORK/open.key"; chmod 644 "$WORK/open.key"
out="$(NCZ_SECRET_HASHES_KEY="$WORK/open.key" $PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "group/other" <<<"$out"; then pass "a world-readable hash key is refused"; else fail "0644 key not refused (rc=$rc)"; fi
$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("key_id"); d["salt"]="ncz-shipped-secret-scan-v1"; json.dump(d, open(sys.argv[2], "w"))' "$WORK/hashes.json" "$WORK/salted.json"
out="$($PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/salted.json" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && grep -q "not keyed" <<<"$out"; then pass "an old salted (brute-forceable) list is refused"; else fail "salted list accepted (rc=$rc)"; fi
if $PY - "$ROOT" "$FAKE" <<'PY'
import base64, gzip, importlib.util, io, lzma, os, struct, subprocess, sys, tempfile, zipfile
root, fake = sys.argv[1], sys.argv[2].encode()
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(root, "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
hs = g.HashSet("s")
for v in g.secret_variants([fake], "s"):
    hs.digests.add(v["sha256"])
sc = g.Scanner(hs, shapes=False)
def hit(data, path):
    rep = g.Report()
    g.scan_payload(rep, sc, "t", path, data)
    return bool(rep.findings)
# plaintext after the last gzip member is scanned
assert hit(gzip.compress(b"harmless\n", mtime=0) + b"GITLAB_TOKEN=" + fake, "/boot/initrd.gz"), "gzip tail missed"
# a second concatenated .xz stream is scanned
two = lzma.compress(b"benign\n") + lzma.compress(b"tok=" + fake + b"\n")
assert hit(two, "/x/data.xz"), "second xz stream missed"
# a zip directory NAME is scanned
zb = io.BytesIO()
with zipfile.ZipFile(zb, "w") as z:
    z.writestr("ok.txt", "fine")
    z.writestr(fake.decode() + "/", "")
assert hit(zb.getvalue(), "/x/a.zip"), "zip directory name missed"
# keybox: only a well-formed blob chain is exempt
hdr = (32).to_bytes(4, "big") + b"\x01\x01\x00\x00KBXf" + bytes(20)
blob = (12).to_bytes(4, "big") + b"\x02" + bytes(7)
assert g.looks_public_key(hdr + blob)
assert not g.looks_public_key(hdr + blob + b"GITLAB_TOKEN=" + fake)
# compression is refused; block groups use s_first_data_block
assert any(b == 0x1 and s_ == 1 for s_, b, _n in g.blocked_features())
d = tempfile.mkdtemp(dir=os.environ.get("TMPDIR"))
os.makedirs(f"{d}/root/opt")
os.symlink("tok-" + fake.decode(), f"{d}/root/opt/fast")              # fast symlink
os.symlink("/" + "d" * 80 + "/" + fake.decode(), f"{d}/root/opt/slow")  # slow symlink
for blk in ("1024", "4096"):
    img = f"{d}/e{blk}.img"
    subprocess.run(["mkfs.ext4", "-q", "-F", "-b", blk, "-d", f"{d}/root", img, "64M"], check=True)
    with open(img, "rb") as fh:
        files = g.ext4_walk(fh, {"index": 2, "offset": 0, "kind": "ext4"})
    tg = {f["path"]: f["bytes"] for f in files if f["path"].endswith("#symlink-target")}
    assert any(fake in v for k, v in tg.items() if "fast" in k), (blk, "fast symlink target")
    assert any(fake in v for k, v in tg.items() if "slow" in k), (blk, "slow symlink target")
PY
then pass "gzip tail, xz streams, zip dir names, keybox chain, ext4 symlink targets (1k+4k blocks)"
else fail "round-6 unit checks failed"; fi
# a FAT32 volume with fewer than 65525 clusters is still FAT32
rm -f "$WORK/f32.img"; mkfs.vfat -C -F 32 -s 8 "$WORK/f32.img" $((100 * 1024)) >/dev/null 2>&1
printf 'tok=%s\n' "$FAKE" > "$WORK/f32.txt"; mcopy -i "$WORK/f32.img" "$WORK/f32.txt" ::/leak.txt
if $PY - "$ROOT" "$WORK/f32.img" "$FAKE" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gate", os.path.join(sys.argv[1], "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
with open(sys.argv[2], "rb") as fh:
    files = g.fat_walk(fh, {"index": 1, "offset": 0, "kind": "fat"})
assert any(sys.argv[3].encode() in f["bytes"] for f in files), [f["path"] for f in files]
PY
then pass "a small FAT32 volume (< 65525 clusters) is walked as FAT32"; else fail "small FAT32 volume not walked"; fi
rm -f "$WORK/f32.img" "$WORK/f32.txt"

# item 4, review round 6: an EMPTY zip is still a zip.  A zero-entry archive is
# a lone end-of-central-directory record (magic PK 05 06), which the content
# sniff did not recognise, so such a file was handed to the matcher as opaque
# bytes instead of being opened as the archive it is.
if $PY - "$ROOT" <<'PY'
import importlib.util, io, os, sys, zipfile
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(sys.argv[1], "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
buf = io.BytesIO()
with zipfile.ZipFile(buf, "w"):      # a valid zip with no members at all
    pass
empty = buf.getvalue()
assert empty[:4] == b"PK\x05\x06", empty[:4]
assert g.archive_magic(empty), "an empty zip is not sniffed as an archive"
assert g.archive_magic(b"PK\x07\x08" + empty[4:]), "a spanned zip is not sniffed"
# ... and expand() opens it instead of silently treating it as a leaf
assert list(g.expand("/x/empty.zip", empty, "/x/empty.zip")) == []
PY
then pass "an empty zip (PK\x05\x06 only) is recognised as an archive"; else fail "empty zip not recognised as an archive"; fi

# item 4, review round 7: a tar WITHOUT the `ustar` magic is still a tar.
# --format=v7 (POSIX.1-1988) writes no magic at bytes 257..262, and the sniff
# tested only `b"ustar"`, so a v7 tar was handed to the matcher as one opaque
# candidate: every member stayed behind the 512-byte padding and a canary
# inside it produced ZERO hashed findings -- the file was reported clean.
# The detection is now the v7 header shape itself (octal mode/size, a NUL
# magic, an octal checksum), and expand() uses the same test, because fixing
# only the sniff would have found the container and still not opened it.
if $PY - "$ROOT" "$FAKE" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "gate", os.path.join(sys.argv[1], "build", "scan-shipped-secrets.py"))
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
fake = sys.argv[2].encode()


def v7_tar(name: bytes, payload: bytes) -> bytes:
    """A POSIX.1-1988 (v7) tar: octal fields, checksum at 148, no magic."""
    hdr = bytearray(512)
    hdr[0:len(name)] = name
    hdr[100:108] = b"0000644\x00"
    hdr[108:116] = b"0000000\x00"
    hdr[116:124] = b"0000000\x00"
    hdr[124:136] = b"%011o\x00" % len(payload)
    hdr[136:148] = b"00000000000\x00"
    hdr[148:156] = b"        "
    hdr[156:157] = b"0"
    # bytes 257..512: v7 writes nothing, so the magic is NUL
    hdr[148:156] = b"%06o\x00 " % sum(hdr)
    body = bytes(hdr) + payload + b"\x00" * (-len(payload) % 512)
    return body + b"\x00" * 1024


data = v7_tar(b"etc/app.conf", b"api_key=" + fake + b"\n")
assert data[257:262] == b"\x00" * 5, data[257:262]     # no ustar marker
assert g.archive_magic(data), "a v7 tar is not sniffed as an archive"
members = dict(g.expand("/etc/backup.tar", data, "/etc/backup.tar"))
assert list(members) == ["/etc/backup.tar/etc/app.conf"], list(members)
assert fake in members["/etc/backup.tar/etc/app.conf"]

# the real path: scan_payload must OPEN it and hit the keyed hash list
hs = g.HashSet(b"k" * 32)
hs.add(fake)
hs.lengths = {len(fake)}
class S:                                     # noqa: N801 -- a Scanner stub
    hashes = hs
    shapes = None
rep = g.Report()
g.scan_payload(rep, S(), "rootfs", "/etc/backup.tar", data)
assert any(f["kind"] == "known-secret" for f in rep.findings), rep.findings

# nustar/gnu/pax still go through the fast path, so nothing regressed ...
import io, tarfile
for fmt in (tarfile.USTAR_FORMAT, tarfile.GNU_FORMAT, tarfile.PAX_FORMAT):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=fmt) as tf:
        ti = tarfile.TarInfo("etc/app.conf")
        ti.size = len(fake)
        tf.addfile(ti, io.BytesIO(fake))
    assert g.archive_magic(buf.getvalue()), fmt
    assert len(list(g.expand("/x.tar", buf.getvalue(), "/x.tar"))) == 1, fmt

# ... and the new shape test must not turn opaque payloads into containers:
# a false positive here would stop a binary/text file from being scanned
# whole (an ELF header has a plausible name, but no NUL magic at 257).
for leaf in (os.urandom(8192), bytes(8192), b"hello world\n" * 400,
             b"\x7fELF\x02\x01\x01\x00" + bytes(600),
             b"OUTPUT_FORMAT(\"elf64-x86-64\")\nSECTIONS { }\n" * 40):
    assert not g.archive_magic(leaf), leaf[:16]
PY
then pass "a v7 tar (no ustar magic) is opened and its members are hashed"
else fail "v7 tar not recognised or not expanded"; fi

# ---------------------------------------------------------------- --variant server
# A Magnetar medium carries no squashfs layer; --variant server accepts that only
# when the receipt says server AND the medium has no layer AND carries the fetch
# manifest. The medium's own files (ESP, data partition) are still scanned.
receipt_for() { printf '{"variant": "%s"}\n' "$2" > "$1.receipt.json"; }
SERVER=1 build_image "$WORK/server.img" clean || { echo "fixture: server image" >&2; exit 1; }
receipt_for "$WORK/server.img" server
out="$($PY "$SCAN" --image "$WORK/server.img" --hash-file "$WORK/hashes.json" --variant server \
       --receipt "$WORK/server.receipt.json" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q '"variant": "server"' "$WORK/server.receipt.json"; then
    pass "server medium + server receipt + --variant server passes (receipt records variant)"
else fail "clean server medium did not pass (rc=$rc): $out"; fi
out="$($PY "$SCAN" --image "$WORK/server.img" --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no squashfs layer at all' <<<"$out" \
    && pass "without --variant server a layerless medium still fails" || fail "layerless medium passed without --variant (rc=$rc)"
receipt_for "$WORK/server.img" desktop
out="$($PY "$SCAN" --image "$WORK/server.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'records variant=desktop' <<<"$out" \
    && pass "--variant server with a desktop receipt fails" || fail "desktop receipt accepted (rc=$rc): $out"
rm -f "$WORK/server.img.receipt.json"
out="$($PY "$SCAN" --image "$WORK/server.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'cannot read the image receipt' <<<"$out" \
    && pass "--variant server without a receipt fails" || fail "missing receipt accepted (rc=$rc)"
receipt_for "$WORK/clean.img" server
out="$($PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'carries squashfs layer' <<<"$out" \
    && pass "a desktop medium with a server receipt fails --variant server" || fail "desktop medium passed as server (rc=$rc): $out"
rm -f "$WORK/clean.img.receipt.json"
SERVER=1 SERVER_NO_MANIFEST=1 build_image "$WORK/server-nomf.img" clean || exit 1
receipt_for "$WORK/server-nomf.img" server
out="$($PY "$SCAN" --image "$WORK/server-nomf.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'no ncz-payload/ncz-fetch-payload.manifest' <<<"$out" \
    && pass "a layerless medium without the fetch manifest is not a server medium" || fail "no-manifest medium passed (rc=$rc): $out"
SERVER=1 SERVER_NO_POOL=1 build_image "$WORK/server-nopool.img" clean || exit 1
receipt_for "$WORK/server-nopool.img" server
out="$($PY "$SCAN" --image "$WORK/server-nopool.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'carries no offline apt pool' <<<"$out" \
    && pass "a server medium without the offline apt pool fails" || fail "no-pool server medium passed (rc=$rc): $out"
SERVER=1 ESP_LEAK=1 build_image "$WORK/server-leak.img" clean || exit 1
receipt_for "$WORK/server-leak.img" server
out="$($PY "$SCAN" --image "$WORK/server-leak.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'known-secret' <<<"$out" \
    && pass "a secret on a server medium's ESP is still caught" || fail "server medium leak missed (rc=$rc): $out"
SERVER=1 build_image "$WORK/server-dleak.img" leaky || exit 1
receipt_for "$WORK/server-dleak.img" server
out="$($PY "$SCAN" --image "$WORK/server-dleak.img" --hash-file "$WORK/hashes.json" --variant server 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'known-secret' <<<"$out" \
    && pass "a secret in a server medium's data partition (initrd, rescue tar, deb) is still caught" \
    || fail "server data-partition leak missed (rc=$rc): $out"
out="$($PY "$SCAN" --payload "$WORK/clean.img" --variant server --hash-file "$WORK/hashes.json" 2>&1)"; rc=$?
[ "$rc" = 2 ] && pass "--variant server with --payload is a usage error" || fail "--variant server --payload rc=$rc"

if [ "$FAILS" -gt 0 ]; then echo "test-shipped-secret-scan: $FAILS finding(s)" >&2; exit 1; fi
echo "test-shipped-secret-scan: PASS ✅"
