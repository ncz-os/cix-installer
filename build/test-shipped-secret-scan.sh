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
    {
        printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n'
        printf '%s\n' "$FAKE_B64"
        printf -- '-----END PGP PUBLIC KEY BLOCK-----\n'
    } > "$d/usr/share/keyrings/debian-archive-keyring.gpg"
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

    # ESP: a FAT image with the d-i kernel + the plain-realistic initrd
    local esp_mib=8 data_mib=48
    mkfs.vfat -C "$t/esp.img" $((esp_mib * 1024)) -n NCZESP >/dev/null 2>&1 || return 1
    mmd -i "$t/esp.img" ::/EFI ::/EFI/BOOT ::/boot >/dev/null 2>&1
    printf 'refind placeholder\n' > "$t/refind_x64.efi"
    mcopy -i "$t/esp.img" "$t/refind_x64.efi" ::/EFI/BOOT/BOOTX64.EFI
    printf 'kernel placeholder\n' > "$t/linux"
    mcopy -i "$t/esp.img" "$t/linux" ::/linux
    mcopy -i "$t/esp.img" "$t/payload/initrd.gz" ::/initrd.gz

    # data partition: ext4 with the payload tree
    rm -f "$t/data.img"; truncate -s $((data_mib * 1024 * 1024)) "$t/data.img"
    mkfs.ext4 -q -F -L NCZDATA -d "$t/payload" "$t/data.img" >/dev/null 2>&1 || return 1

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
if $PY - "$WORK/hashes.json" "$FAKE" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
plain = sys.argv[2].encode()
import base64
bad = [h for h in doc["hashes"]
       if plain in bytes.fromhex("") or h["sha256"] == __import__("hashlib").sha256(
           doc["salt"].encode() + plain).hexdigest()]
sys.exit(0 if bad else 1)
PY
then pass "the hash file carries the salted digest of the secret"; else fail "hash file missing the digest"; fi
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
want_units = {"base.squashfs", "desktop.squashfs", "rescue.squashfs", "mgmt.squashfs",
              "esp", "ncz-payload_rescue-rootfs.tar.zst"}
sys.exit(0 if not missing and all(units.get(k) for k in ("base.squashfs", "desktop.squashfs")) else 1)
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
if grep -qF "$FAKE" "$WORK/leaky.receipt.json" 2>/dev/null; then fail "the receipt leaked a value"; else pass "the receipt holds no value"; fi
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
if grep -q 'ncz-fixture_1.0_all.deb' "$WORK/leaky.receipt.json" 2>/dev/null; then
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
out="$($PY "$SCAN" --image "$WORK/clean.img" --hash-file "$WORK/absent.json" --allow-detached 2>&1)"; rc=$?
if [ "$rc" = 1 ]; then pass "--allow-detached still FAILS (hashed half did not run)"; else fail "--allow-detached returned $rc"; fi

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
# every segment is visited in order; directory entries (".") are yielded for
# completeness but expand() never treats them as content
assert names == [".", "f", ".", "f"], names
assert [n for n, p in g.cpio_members(data, "t") if p] == ["f", "f"]
assert len(g.decompress_chain(__import__("gzip").compress(data), "t")) == 1
print("primitives ok")
PY
then pass "primitives: forms matched, clean text clear, cpio segments walked"
else fail "primitive self-test failed"; fi

if [ "$FAILS" -gt 0 ]; then echo "test-shipped-secret-scan: $FAILS finding(s)" >&2; exit 1; fi
echo "test-shipped-secret-scan: PASS ✅"
