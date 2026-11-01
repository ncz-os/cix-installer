#!/bin/bash
# test-provenance-predict.sh -- the stage-25 PREDICTIVE provenance gate
# (docs/BUILD-STABILITY.md M1) and the parity between it and the final gate.
#
# The gate is build/check-inputs-provenance.sh over build/forky-provenance.py.
# Because both gates call the SAME verifier helpers (safe_extract_zst +
# scan_rootfs, authorize_pool + _scan_initrd, scan_debs), "the two cannot
# disagree" is not a promise here, it is asserted:
#
#   1. positives  a fixture rootfs tarball and a fixture substrate ISO whose
#                 packages and sources match the fixture snapshot/ledgers pass
#                 (rc 0), and so does the checkout's own input set.
#   2. negatives  one per class the late gate found in the 2026-10-29 amd64 run
#                 (C3, docs/BUILD-STABILITY.md section 1): a rootfs tarball
#                 whose etc/apt/sources.list names another snapshot, a substrate
#                 udeb missing from the ledger, an ncz-screensavers 0.8.19 deb
#                 with only a 0.8.18 row, a +r292 kernel deb under a +r293
#                 manifest -- each fails with rc 1 and names the finding.
#   3. the 71 findings of that run, replayed against fixture inputs: every
#      finding line the finished-image scan prints for the same bytes is also
#      printed by stage 25's check (definition of done, section 4).
#   4. the ISO manifest  a wrong --iso-listing is refused, never trusted.
#   5. stage order  with the predict stage failing, stages.tsv has no
#      offline-mirror row (in build/test-build-image.sh; see section 6 there).
#
# The trust root is an isolated fixture repository with a THROWAWAY keyring and
# a SYNTHETIC snapshot id, so nothing here depends on the real pin.  Every
# fixture lives under mktemp -d in $TMPDIR (never /tmp, never tmpfs) and is
# removed on exit.
#
# Usage: build/test-provenance-predict.sh [--keep]
# Exit 0 = every case passed.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CHK="$ROOT/build/check-inputs-provenance.sh"
PY="$ROOT/build/forky-provenance.py"
KEEP=0; [ "${1:-}" = --keep ] && KEEP=1
T="$(mktemp -d "${TMPDIR:-$HOME}/ncz-predict-test.XXXXXX")" || exit 1
cleanup() { [ "$KEEP" = 1 ] && { echo "kept: $T"; return; }; rm -rf "$T"; }
trap cleanup EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /' | head -40; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0; shift 2
    LAST="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$LAST"; fi
}

required=(git python3 sha256sum dpkg-deb gpg gpgv xz gzip zstd cpio)
for t in "${required[@]}"; do
    command -v "$t" >/dev/null 2>&1 || { echo "FAIL: required test tool not available: $t" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# fixtures: an isolated trust root with a throwaway keyring
# ---------------------------------------------------------------------------
SNAP=20300101T000000Z          # synthetic pin; never the real one
sha() { sha256sum "$1" | awk '{print $1}'; }
mkdeb() {  # out-path name version arch [maintainer] -- a minimal real .deb
    local out="$1" name="$2" ver="$3" arch="$4" maint="${5:-NCZ Builder <build@ncz-os.invalid>}"
    local d; d="$(mktemp -d "$T/deb.XXXXXX")"
    mkdir -p "$d/DEBIAN" "$d/usr/share/doc/$name"
    printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: %s\n' \
        "$name" "$ver" "$arch" "$maint" > "$d/DEBIAN/control"
    printf '%s %s\n' "$name" "$ver" > "$d/usr/share/doc/$name/PKG"
    mkdir -p "$(dirname "$out")"
    dpkg-deb --root-owner-group -Zgzip --build "$d" "$out" >/dev/null 2>&1 || {
        echo "FAIL: could not build fixture deb $out" >&2; rm -rf "$d"; exit 1; }
    rm -rf "$d"
}
mkudeb() { mkdeb "$@"; }   # a udeb is a deb with the d-i control fields set

mkdir -p "$T/gnupg"; chmod 700 "$T/gnupg"
export GNUPGHOME="$T/gnupg"
printf '%%no-protection\nKey-Type: RSA\nKey-Length: 2048\nName-Real: NCZ Predict Fixture\nName-Email: predict@ncz.invalid\nExpire-Date: 0\n%%commit\n' > "$T/kp"
gpg --batch --gen-key "$T/kp" >/dev/null 2>&1 || { echo "FAIL: gpg key generation failed" >&2; exit 1; }
FPR="$(gpg --with-colons --fingerprint predict@ncz.invalid 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
[ -n "$FPR" ] || { echo "FAIL: no fixture signing key" >&2; exit 1; }

# TR: the fixture trust root (what --root points at)
TR="$T/trust"; IR="$T/trust/debian"; IDX="$T/index"
mkdir -p "$TR/manifests/keys" "$IR" "$IDX/dists"

# the fixture packages, built once and reused by every rule
mkdeb "$T/debs/base-files_1.0_all.deb"        base-files    1.0     all
mkdeb "$T/debs/libc6_2.41-7_amd64.deb"        libc6         2.41-7  amd64
mkdeb "$T/debs/ncz-kernel_7.3.0+r293_amd64.deb" ncz-kernel 7.3.0     amd64
mkdeb "$T/debs/ncz-screensavers_0.8.19_amd64.deb" ncz-screensavers 0.8.19 amd64
mkdeb "$T/debs/ncz-singularity-desktop_20261029040608+bk0+tgzdeadbeef_amd64.deb" \
      ncz-singularity-desktop 20261029040608+bk0+tgzdeadbeef amd64
mkudeb "$T/debs/ncz-installer-udeb_7.3.0+r293_amd64.udeb" ncz-installer 7.3.0 amd64
mkudeb "$T/debs/cdrom-checker-udeb_1.0_amd64.udeb" cdrom-checker 1.0 amd64

# hash everything once
H_BASE="$(sha "$T/debs/base-files_1.0_all.deb")"
H_LIBC="$(sha "$T/debs/libc6_2.41-7_amd64.deb")"
H_KERN="$(sha "$T/debs/ncz-kernel_7.3.0+r293_amd64.deb")"
H_SS="$(sha "$T/debs/ncz-screensavers_0.8.19_amd64.deb")"
H_SING="$(sha "$T/debs/ncz-singularity-desktop_20261029040608+bk0+tgzdeadbeef_amd64.deb")"
H_UD="$(sha "$T/debs/ncz-installer-udeb_7.3.0+r293_amd64.udeb")"
H_CDR="$(sha "$T/debs/cdrom-checker-udeb_1.0_amd64.udeb")"

# --- the debian/ archive fixture: Release files, Packages, repo pool --------
# A repo root holding the "debian archive" (what the ISO's /cdrom pool is
# authorized against) and the sid d-i suite.
REPO="$T/repo"
mkdir -p "$REPO/pool/main/b/base-files" "$REPO/pool/main/l/libc6" "$REPO/pool/ncz" \
         "$REPO/dists/forky/main/binary-amd64" "$REPO/dists/forky/main/binary-all" \
         "$REPO/dists/forky/main/debian-installer/binary-amd64" \
         "$REPO/dists/forky/main/debian-installer/binary-all" \
         "$REPO/dists/sid/main/debian-installer/binary-amd64" \
         "$REPO/dists/sid/main/debian-installer/binary-all"
mv "$T/debs/base-files_1.0_all.deb" "$REPO/pool/main/b/base-files/"
mv "$T/debs/libc6_2.41-7_amd64.deb" "$REPO/pool/main/l/libc6/"
cat > "$REPO/dists/forky/main/binary-amd64/Packages" <<EOF
Package: libc6
Version: 2.41-7
Architecture: amd64
Filename: pool/main/l/libc6/libc6_2.41-7_amd64.deb
Size: $(stat -c%s "$REPO/pool/main/l/libc6/libc6_2.41-7_amd64.deb")
SHA256: $H_LIBC

EOF
cat > "$REPO/dists/forky/main/binary-all/Packages" <<EOF
Package: base-files
Version: 1.0
Architecture: all
Filename: pool/main/b/base-files/base-files_1.0_all.deb
Size: $(stat -c%s "$REPO/pool/main/b/base-files/base-files_1.0_all.deb")
SHA256: $H_BASE

EOF
# sid (the pinned snapshot's d-i development suite) also needs its d-i indexes
# signed, and an index with zero stanzas is a hard failure ("Packages index has
# no records") by design -- so the fixture carries the one udeb it ships.
# Architecture must be amd64: the sid ledger row is looked up as
# (name, version, arch-in-trust), so an "all" stanza would never match it.
{ printf 'Package: cdrom-checker\nVersion: 1.0\nArchitecture: amd64\nFilename: pool/main/c/cdrom-checker/cdrom-checker_1.0_amd64.udeb\nSize: %s\nSHA256: %s\n\n' \
    "$(stat -c%s "$T/debs/cdrom-checker-udeb_1.0_amd64.udeb")" "$H_CDR"
} > "$REPO/dists/sid/main/debian-installer/binary-amd64/Packages"
cp "$REPO/dists/sid/main/debian-installer/binary-amd64/Packages" \
   "$REPO/dists/sid/main/debian-installer/binary-all/Packages"
# codename_need() also requires the forky debian-installer indexes (including
# binary-all, where Architecture:all udebs live), so the signed Release must
# cover them too.  They must be NON-EMPTY (an empty index is a hard "Packages
# index has no records" failure) but must NOT list cdrom-checker: that udeb is
# a reviewed sid exception below, and a forky index carrying it would make the
# verifier report it GRADUATED (forky now provides it -> drop the sid row).
{ printf 'Package: ncz-forky-d-i\nVersion: 1.0\nArchitecture: all\nFilename: pool/main/n/ncz-forky-d-i/ncz-forky-d-i_1.0_all.udeb\nSize: 1024\nSHA256: %s\n\n' \
    "$(printf 'd%.0s' {1..64})"
} > "$REPO/dists/forky/main/debian-installer/binary-amd64/Packages"
cp "$REPO/dists/forky/main/debian-installer/binary-amd64/Packages" \
   "$REPO/dists/forky/main/debian-installer/binary-all/Packages"

# A signed InRelease per suite from the committed Packages indexes.  The
# fixture indexes are xz-compressed, like Debian's: the verifier looks for
# "<relpath>.xz" in the signed Release for every index it was asked for.
# NOTE: this must run AFTER every Packages file under dists/ is final -- the
# release index is synthesized from them, so a later `find -name Packages`
# (e.g. mkiso's "$s/dists/Packages") must not touch this tree.
for f in $(cd "$REPO/dists" && find . -name Packages | sed 's|^\./||'); do
    xz -q -9 -k "$REPO/dists/$f"
done
mk_inrelease() {  # suite out-dir
    local suite="$1" outd="$2" body="$2/Release"
    {
        printf 'Origin: Debian\nLabel: Debian\nSuite: %s\nCodename: %s\nDate: Thu, 01 Jan 2030 00:00:00 UTC\nSHA256:\n' \
            "$suite" "$([ "$suite" = sid ] && echo sid || echo forky)"
        local rel f
        for rel in $(cd "$REPO/dists/$suite" && find . -name 'Packages*' | sed 's|^\./||' | sort); do
            f="$REPO/dists/$suite/$rel"
            printf ' %s %s %s\n' "$(sha "$f")" "$(stat -c%s "$f")" "$rel"
        done
    } > "$body"
    gpg --batch --yes --local-user "$FPR" --clearsign -o "$outd/InRelease" "$body" >/dev/null 2>&1
    rm -f "$body"
}
mkdir -p "$T/inrel/forky" "$T/inrel/sid"
mk_inrelease forky "$T/inrel/forky"
mk_inrelease sid   "$T/inrel/sid"
gpg --batch --export "$FPR" > "$TR/manifests/keys/fixture-keyring.gpg"

# the verified-index directory the trusted root resolves (same shape verify_index reads)
mkdir -p "$IDX/dists"
cp -a "$REPO/dists/forky/." "$IDX/dists/forky/"
cp -a "$REPO/dists/sid/."   "$IDX/dists/sid/"
# The InRelease lands AFTER the dists tree: `cp -a` of the repo tree would
# otherwise be the last write into dists/, and a stale/absent InRelease there
# makes every check fail closed with "no valid signed InRelease".
cp "$T/inrel/forky/InRelease" "$IDX/dists/forky/InRelease"
cp "$T/inrel/sid/InRelease"   "$IDX/dists/sid/InRelease"

mkrelease_conf() {  # root
    printf '# fixture (test-provenance-predict.sh)\nNCZ_BASE_NAME="Debian"\nNCZ_BASE_CODENAME="forky"\nNCZ_BASE_MIRROR_SNAPSHOT="%s"\n' \
        "$SNAP" > "$1/release.conf"
}
mkrelease_conf "$TR"
printf 'snapshot\t%s\ncodename\tforky\ncomponents\tmain\narchitectures\tamd64 all\ninrelease_path\tdists/forky/InRelease\ninrelease_sha256\t%s\ninrelease_size\t%s\nkeyring\tmanifests/keys/fixture-keyring.gpg\nkeyring_sha256\t%s\nsigner_keys\t%s\ndi_suite\tsid\ndi_inrelease_path\tdists/sid/InRelease\ndi_inrelease_sha256\t%s\ndi_inrelease_size\t%s\n' \
    "$SNAP" "$(sha "$T/inrel/forky/InRelease")" "$(stat -c%s "$T/inrel/forky/InRelease")" \
    "$(sha "$TR/manifests/keys/fixture-keyring.gpg")" "$FPR" \
    "$(sha "$T/inrel/sid/InRelease")" "$(stat -c%s "$T/inrel/sid/InRelease")" \
    > "$TR/manifests/forky-snapshot.tsv"

# ledgers.  ncz-packages.tsv rows are exact (name, version, arch, sha256);
# sid-exceptions.tsv rows carry the review_by/snapshot columns.
mkledgers() {  # root [extra...]
    local d="$1"
    printf '# fixture ledger\n' > "$d/manifests/ncz-packages.tsv"
    printf 'ncz-kernel\t7.3.0\tamd64\t%s\tbuild/build-kernel-debs.sh\tmainline\tr293\n' "$H_KERN" \
        >> "$d/manifests/ncz-packages.tsv"
    printf 'ncz-installer\t7.3.0\tamd64\t%s\tbuild/build-kernel-debs.sh\tmainline\tr293\n' "$H_UD" \
        >> "$d/manifests/ncz-packages.tsv"
    printf 'ncz-singularity-desktop\t20261029040608+bk0+tgzdeadbeef\tamd64\t%s\tbuild/build-singularity-deb.sh\tsingularity\tpayload\n' "$H_SING" \
        >> "$d/manifests/ncz-packages.tsv"
    : > "$d/manifests/vendor-debs.tsv"
    printf '# fixture\n' > "$d/manifests/vendor-repos.tsv"
    printf 'debian-pin\thttps\tsnapshot.debian.org\t/archive/debian/<pin>\tforky\tyes\tDebian\tpinned snapshot\n' >> "$d/manifests/vendor-repos.tsv"
    ncz="${ncz:-1}"
    printf '# fixture\n' > "$d/manifests/ncz-timestamped.tsv"
    printf 'ncz-singularity-desktop\t^[0-9]{14}\\+bk0\\+tgz[0-9a-f]+$\tamd64\tbuild/build-singularity-deb.sh\tsingularity\tpayload\n' \
        >> "$d/manifests/ncz-timestamped.tsv"
    printf '# fixture\n' > "$d/manifests/overlay-layers.tsv"
    printf '# fixture\n' > "$d/manifests/sid-exceptions.tsv"
    printf 'ncz-installer\t7.3.0\tamd64\t%s\tB\t0.9\tfixture\tfixture\t2029-12-01\t%s\trebuild\t2030-02-01\thttps://example.invalid/1\n' \
        "$H_UD" "$SNAP" >> "$d/manifests/sid-exceptions.tsv"
    # the fixture initrd's own udeb: reviewed here so the substrate positive
    # case authorizes every initrd member (the negative cases stay negative
    # because they ship a udeb that is deliberately absent from these ledgers).
    printf 'cdrom-checker\t1.0\tamd64\t%s\tB\t0.9\tfixture\tfixture\t2029-12-01\t%s\trebuild\t2030-02-01\thttps://example.invalid/2\n' \
        "$H_CDR" "$SNAP" >> "$d/manifests/sid-exceptions.tsv"
}
mkledgers "$TR"
# the "0.8.18 only" ledger state of the 2026-10-29 tree: a row for the previous
# screensavers version, whose sha256 is a placeholder (the bytes are not it).
printf 'ncz-screensavers\t0.8.18\tamd64\t%s\tbuild/build-screensavers.sh\tscreensavers\t0.8.18\n' \
    "$(printf 'c%.0s' {1..64})" >> "$TR/manifests/ncz-packages.tsv"

# the payload receipt refresh-sources writes (authorizes the timestamped deb)
mkreceipt() {  # out [name version arch sha]
    cat > "$1" <<EOF
{"ncz_timestamped_debs": [{"name": "${2:-ncz-singularity-desktop}",
  "version": "${3:-20261029040608+bk0+tgzdeadbeef}", "arch": "${4:-amd64}",
  "sha256": "${5:-$H_SING}"}]}
EOF
}
mkreceipt "$T/payload-receipt.json"

# --- rootfs tarball fixture --------------------------------------------------
# var/lib/dpkg/status + etc/apt/sources.list (+ os-release), packed as .tar.zst.
mkrootfs() {  # out-tarball ["sources.list" content] [pkg name version arch]...
    local out="$1" srcs="${2:-}"; shift 2
    local d; d="$(mktemp -d "$T/rootfs.XXXXXX")"
    mkdir -p "$d/var/lib/dpkg" "$d/etc/apt" "$d/usr/lib"
    : > "$d/var/lib/dpkg/status"
    local name ver arch
    while [ $# -ge 3 ]; do
        name="$1"; ver="$2"; arch="$3"; shift 3
        printf 'Package: %s\nStatus: install ok installed\nPriority: optional\nVersion: %s\nArchitecture: %s\n' \
            "$name" "$ver" "$arch" >> "$d/var/lib/dpkg/status"
    done
    printf 'ID=ncz-os\nNAME="NCZ OS"\nVERSION_ID="4"\n' > "$d/usr/lib/os-release"
    printf '%s\n' "$srcs" > "$d/etc/apt/sources.list"
    mkdir -p "$(dirname "$out")"
    tar -C "$d" -cf - . | zstd -q -19 -o "$out" -f || { echo "FAIL: could not build $out" >&2; exit 1; }
    rm -rf "$d"
}
PIN_SRC="deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] https://snapshot.debian.org/archive/debian/$SNAP/ forky main"
OLD_SNAP=20291201T000000Z
OLD_SRC="deb https://snapshot.debian.org/archive/debian/$OLD_SNAP/ forky main"

# --- substrate ISO fixture ---------------------------------------------------
# A real ISO9660 image: RELAXED filenames so a bare name maps to a NAME;1
# record and directory names are 8.3-safe, exactly like a d-i netinst.
mkiso() {  # out-iso [--no-pool] [--bad-udeb]
    local out="$1"; shift
    local flags=" $* "
    local s="$T/isoroot"; rm -rf "$s"; mkdir -p "$s"
    if [[ "$flags" != *" --no-pool "* ]]; then
        mkdir -p "$s/pool/main"
        cp "$REPO/pool/main/l/libc6/libc6_2.41-7_amd64.deb" "$s/pool/main/libc6.deb"
        local poolidx=''
        if [[ "$flags" == *" --bad-udeb "* ]]; then
            # a udeb the ledger does NOT review and the snapshot does not carry,
            # and that the pool's own index does NOT list: the orphan case.
            mkudeb "$s/pool/main/rogue.udeb" rogue-udeb 9.9 amd64
        else
            cp "$T/debs/ncz-installer-udeb_7.3.0+r293_amd64.udeb" "$s/pool/main/nczinst.udeb"
            # A real d-i netinst lists every file in its pool, so the packaged
            # udeb must appear in the index too (an unlisted pool file is an
            # orphan and is correctly refused).
            poolidx="$(printf 'Package: ncz-installer\nVersion: 7.3.0\nArchitecture: amd64\nFilename: pool/main/nczinst.udeb\nSize: %s\nSHA256: %s\n\n' \
                "$(stat -c%s "$s/pool/main/nczinst.udeb")" "$H_UD")"
        fi
        # a fixture installer initrd: one newc archive holding the udeb + status
        local ir; ir="$(mktemp -d "$T/initrd.XXXXXX")"
        mkdir -p "$ir/udebs" "$ir/var/lib/dpkg"
        cp "$T/debs/cdrom-checker-udeb_1.0_amd64.udeb" "$ir/udebs/cdromcheck.udeb"
        printf 'Package: ncz-installer\nStatus: install ok installed\nVersion: 7.3.0\nArchitecture: amd64\n' \
            > "$ir/var/lib/dpkg/status"
        ( cd "$ir" && find . -mindepth 1 | sort | cpio -o -H newc --quiet ) | gzip -n -9 \
            > "$s/initrd.gz"
        rm -rf "$ir"
        # the pool's own Packages index (authorized against the pinned snapshot).
        # A real d-i netinst keeps it under dists/<suite>/main/debian-installer/
        # and scan_substrate_iso() reads ONLY dists/ paths naming
        # "debian-installer" (the runtime closure is the mirror's job) -- a flat
        # dists/Packages would be filtered out and the pool unauthorized.
        mkdir -p "$s/dists/$SNAP/main/debian-installer/binary-amd64" \
                 "$s/dists/$SNAP/main/debian-installer/binary-all"
        {
            printf 'Package: libc6\nVersion: 2.41-7\nArchitecture: amd64\nFilename: pool/main/libc6.deb\nSize: %s\nSHA256: %s\n\n' \
                "$(stat -c%s "$s/pool/main/libc6.deb")" "$H_LIBC"
            printf '%s' "$poolidx"
        } > "$s/dists/$SNAP/main/debian-installer/binary-amd64/Packages"
        cp "$s/dists/$SNAP/main/debian-installer/binary-amd64/Packages" \
           "$s/dists/$SNAP/main/debian-installer/binary-all/Packages"
    fi
    mkdir -p "$(dirname "$out")"
    # xorriso is the reference writer (the hosts that build the real substrate
    # have it).  Without it, a deterministic mkisofs-compatible writer is used.
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -quiet -o "$out" -R -J -joliet-long -iso-level 3 \
            -V NCZFIX "$s" >/dev/null 2>&1
    else
        xorriso_fallback "$s" "$out"
    fi || { echo "FAIL: could not build fixture ISO $out" >&2; exit 1; }
}

# A minimal ISO9660 writer (ECMA-119 level 2-ish: 31-char names, both-endian
# fields, sector-padded records) used only when xorriso is absent.
xorriso_fallback() {  # src-dir out-iso  (minimal ECMA-119 writer, xorriso absent)
    python3 - "$1" "$2" <<'PY'
import os, struct, sys

src, out = sys.argv[1], sys.argv[2]
LBS = 2048


def b16(v):
    return struct.pack("<H", v) + struct.pack(">H", v)


def b32(v):
    return struct.pack("<I", v) + struct.pack(">I", v)


def rec_len(nl):
    return 33 + nl + (1 if nl % 2 == 0 else 0)


dirs, files = [], []


def walk(d, parent):
    i = len(dirs)
    dirs.append({"parent": parent, "children": [], "path": d})
    for n in sorted(os.listdir(d)):
        p = os.path.join(d, n)
        if os.path.isdir(p):
            dirs[i]["children"].append(("d", n, walk(p, i)))
        else:
            dirs[i]["children"].append(("f", n, len(files)))
            files.append({"name": n, "path": p, "size": os.path.getsize(p)})
    return i


walk(src, -1)


def dir_size(i):
    sz = rec_len(1) * 2
    for kind, name, _ in dirs[i]["children"]:
        sz += rec_len(len(name.encode("latin-1")) + (0 if kind == "d" else 2))
    return ((sz + LBS - 1) // LBS) * LBS


dir_lba, file_lba = {}, {}
lba = 16 + 3
for i in range(len(dirs)):
    dir_lba[i] = lba
    lba += dir_size(i) // LBS
for f in files:
    file_lba[id(f)] = lba
    lba += (f["size"] + LBS - 1) // LBS
img = bytearray(lba * LBS)


def make_rec(name, lba_, size, isdir, dot=None):
    if dot == "dot":
        nb = b"\x00"
    elif dot == "dotdot":
        nb = b"\x01"
    else:
        nb = name.encode("latin-1") + (b"" if isdir else b";1")
    r = bytearray(rec_len(len(nb)))
    r[0] = len(r)
    r[2:10] = b32(lba_)
    r[10:18] = b32(size)
    r[18:25] = bytes([126, 1, 1, 0, 0, 0, 0])
    r[25] = 0x02 if isdir else 0x00
    r[28:32] = b16(1)
    r[32] = len(nb)
    r[33:33 + len(nb)] = nb
    return bytes(r)


for i, d in enumerate(dirs):
    sz = dir_size(i)
    body = bytearray(make_rec("", dir_lba[i], sz, True, dot="dot"))
    p = d["parent"] if d["parent"] >= 0 else 0
    body += make_rec("", dir_lba[p], dir_size(p), True, dot="dotdot")
    for kind, name, idx in d["children"]:
        if kind == "d":
            body += make_rec(name, dir_lba[idx], dir_size(idx), True)
        else:
            f = files[idx]
            body += make_rec(name, file_lba[id(f)], f["size"], False)
    off = dir_lba[i] * LBS
    img[off:off + sz] = body + b"\x00" * (sz - len(body))
for f in files:
    off = file_lba[id(f)] * LBS
    with open(f["path"], "rb") as fh:
        img[off:off + f["size"]] = fh.read()


def vd(kind, root_rec=None):
    v = bytearray(LBS)
    v[0] = kind
    v[1:6] = b"CD001"
    v[6] = 1
    if kind == 1:
        v[40:48] = b"NCZFIX  "
        v[80:88] = b32(len(img) // LBS)
        v[120:124] = b16(1)
        v[124:128] = b16(1)
        v[128:132] = b16(LBS)
        v[156:156 + len(root_rec)] = root_rec
    return bytes(v)


off = 16 * LBS
img[off:off + LBS] = vd(1, make_rec("", dir_lba[0], dir_size(0), True, dot="dot"))
img[off + LBS:off + 2 * LBS] = vd(2)
img[off + 2 * LBS:off + 3 * LBS] = b"\xff" + b"CD001" + bytes([1]) + b"\x00" * (LBS - 7)
with open(out, "wb") as fh:
    fh.write(bytes(img))
PY
}

# ---------------------------------------------------------------------------
# helpers for running the gate
# ---------------------------------------------------------------------------
WF="$T/work"
TR2="$T/trust2"; TR3="$T/trust3"   # per-case trust-root copies (declared: set -u)
lastfind() {  # needle -- the last run's output must contain it
    if grep -qF -- "$1" <<<"$LAST"; then ok "  finding names: $1"; else bad "  finding '$1' missing" "$LAST"; fi
}
# gate ARGS... -- run the check against the fixture trust root
gate() {
    bash "$CHK" --root "$TR" --work "$WF" --index-dir "$IDX" "$@"
}

# ===========================================================================
echo "== 1. positives =="
# 1a. a rootfs tarball whose packages + sources match the fixture snapshot
mkrootfs "$T/fix/mgmt.tar.zst" "$PIN_SRC" base-files 1.0 all libc6 2.41-7 amd64
expect_rc "rootfs tarball: a matching tarball passes" 0 \
    python3 -I "$PY" --rootfs-tar "$T/fix/mgmt.tar.zst" --work "$WF" \
         --root-dir "$TR" --index-dir "$IDX"
expect_rc "rootfs tarball: no finding is printed" 0 \
    bash -c '! grep -q "^FAIL" <<<"$0"' "$LAST"

# 1b. the gate's standard input set: a reviewed NCZ deb, a matching rootfs
#     tarball, a substrate ISO whose pool + initrd udebs are all reviewed
rm -rf "$TR/assets"; mkdir -p "$TR/assets/mgmt" "$TR/assets/cix-debs"
cp "$T/fix/mgmt.tar.zst" "$TR/assets/mgmt/ncz-mgmt-rootfs.tar.zst"
cp "$T/debs/ncz-screensavers_0.8.19_amd64.deb" "$TR/assets/cix-debs/"
printf 'ncz-screensavers\t0.8.19\tamd64\t%s\tbuild/build-screensavers.sh\tscreensavers\t0.8.19\n' "$H_SS" \
    >> "$TR/manifests/ncz-packages.tsv"
mkiso "$T/fix/substrate.iso"
expect_rc "substrate ISO: a pool+initrd whose udebs are reviewed passes" 0 \
    gate --arch amd64 --substrate-iso "$T/fix/substrate.iso" \
         --receipt "$T/payload-receipt.json"
expect_rc "the whole staging set (debs + tarball + ISO) passes" 0 \
    gate --arch amd64 --receipt "$T/payload-receipt.json"

# 1c. the checkout's own inputs, if they are present on this host.  That is the
#     one case that runs on the real trust root; it needs a verified index, so
#     it is skipped unless one is already staged (--offline hosts still pass).
REAL_IDX="${NCZ_INPUTS_INDEX_DIR:-$ROOT/ncz-inputs-index}"
if ls "$REAL_IDX"/dists/*/InRelease >/dev/null 2>&1; then
    rc=0; LAST="$(bash "$CHK" --arch amd64 --index-dir "$REAL_IDX" \
        --work "$T/realwork" --no-substrate 2>&1)" || rc=$?
    [ "$rc" = 0 ] && ok "checkout: its staged inputs pass the predictive gate" \
                  || bad "checkout: staged inputs fail the predictive gate" "$LAST"
else
    echo "  SKIP  checkout: no verified index staged at $REAL_IDX"
fi

# ===========================================================================
echo "== 2. negatives (one per class the late gate found in the 2026-10-29 run) =="
# 2a. a rootfs tarball built at ANOTHER snapshot
mkrootfs "$T/bad/old.tar.zst" "$OLD_SRC" base-files 1.0 all libc6 2.41-7 amd64
expect_rc "rootfs tarball at another snapshot FAILS" 1 \
    python3 -I "$PY" --rootfs-tar "$T/bad/old.tar.zst" --work "$WF" \
         --root-dir "$TR" --index-dir "$IDX"
lastfind "is not a reviewed"
lastfind "$OLD_SNAP"
# and through the gate, by staging it as the mgmt rootfs
rm -rf "$TR/assets/mgmt"; mkdir -p "$TR/assets/mgmt"
cp "$T/bad/old.tar.zst" "$TR/assets/mgmt/ncz-mgmt-rootfs.tar.zst"
expect_rc "stale mgmt rootfs tarball FAILS the staged-input check" 1 \
    gate --arch amd64 --no-substrate --receipt "$T/payload-receipt.json"
lastfind "ncz-mgmt-rootfs.tar.zst"

# 2b. a substrate pool udeb missing from the ledger
mkiso "$T/bad/rogue.iso" --bad-udeb
mkdir -p "$T/empty"
expect_rc "a substrate pool udeb missing from the ledger FAILS" 1 \
    gate --arch amd64 --substrate-iso "$T/bad/rogue.iso" --no-rootfs \
         --deb-dir "$T/empty" --exclude "$T/empty"
rmdir "$T/empty" 2>/dev/null || true
lastfind "pool/main/rogue.udeb"
lastfind "has no reviewed origin"

# 2c. ncz-screensavers 0.8.19 with only a 0.8.18 ledger row
rm -rf "$TR2"; cp -a "$TR" "$TR2"; rm -rf "$TR2/assets"
awk -F'\t' '!($1=="ncz-screensavers" && $2=="0.8.19")' "$TR2/manifests/ncz-packages.tsv" > "$TR2/m.tmp"
mv "$TR2/m.tmp" "$TR2/manifests/ncz-packages.tsv"
mkdir -p "$TR2/assets/cix-debs"
cp "$T/debs/ncz-screensavers_0.8.19_amd64.deb" "$TR2/assets/cix-debs/"
expect_rc "ncz-screensavers 0.8.19 with only a 0.8.18 row FAILS" 1 \
    bash "$CHK" --root "$TR2" --work "$WF" --index-dir "$IDX" --arch amd64 --no-substrate
lastfind "ncz-screensavers_0.8.19_amd64.deb"
lastfind "not in the reviewed NCZ ledger"

# 2d. a +r292 kernel deb under a +r293 manifest
rm -rf "$TR3"; cp -a "$TR" "$TR3"; rm -rf "$TR3/assets"; mkdir -p "$TR3/assets/cix-debs"
mkdeb "$TR3/assets/cix-debs/ncz-kernel_7.3.0+r292_amd64.deb" ncz-kernel 7.3.0 amd64
expect_rc "a +r292 kernel deb under a +r293 manifest FAILS" 1 \
    bash "$CHK" --root "$TR3" --work "$WF" --index-dir "$IDX" --arch amd64 --no-substrate
lastfind "ncz-kernel 7.3.0 amd64"

# 2e. fail closed: an index directory that holds nothing.  The gate must exit
#     non-zero (it cannot verify anything) and must never print the "all input
#     provenance checks passed" line -- a missing index is not a pass.
rc=0; LAST="$(bash "$CHK" --root "$TR" --work "$WF" \
    --index-dir "$T/nonexistent-index" --arch amd64 --no-substrate 2>&1)" || rc=$?
if [ "$rc" != 0 ] && ! grep -q "all input provenance checks passed" <<<"$LAST"; then
    ok "no verified snapshot index FAILS closed (rc=$rc)"
else
    bad "no verified snapshot index must fail closed: rc=$rc" "$LAST"
fi

printf '\n== provenance-predict tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
