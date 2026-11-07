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

# This suite builds .deb fixtures. If the host cannot, say so once instead of
# letting every assertion fail on an empty archive (build/lib/deb-fixture.sh).
# shellcheck source=lib/deb-fixture.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/deb-fixture.sh"
ncz_deb_fixture_check || { echo "test-provenance-predict: ENVIRONMENT: this host cannot build deb fixtures; not a code failure" >&2; exit 3; }

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
echo "== 3. the A2 (2026-10-29 amd64) findings, replayed: parity with the final gate =="
# docs/BUILD-STABILITY.md section 4, definition of done: "Every finding that
# stage_provenance_gate() reports on an image is also reported by stage 25 or 50
# on the same inputs.  Test: the 71 A2 findings, replayed against fixture
# inputs, are all caught by build/check-inputs-provenance.sh."
#
# "The 71" is not a magic constant to assert: 71 is what the late gate counted
# on the REAL inputs of that run, which this fixture is not.  What has to hold
# is the PARITY -- for the same bytes, every finding class the late gate emits
# is emitted by the early gate.  Each class below is one of the three the run
# recorded (docs/BUILD-STABILITY.md C3): an old-snapshot rootfs tarball, an NCZ
# deb with no ledger row, and a substrate udeb with no reviewed origin.  The
# late gate is driven by calling the SAME helper it calls (scan_rootfs_tar /
# scan_debs / scan_substrate_iso, via --rootfs / --substrate-iso), so a
# divergence means the two paths stopped sharing code, which is the risk in
# section 5.
# Parity is about WHICH defect is reported, not the source label: the final gate
# labels a finding by its position in the image ([image:assets/...]) while stage
# 25 labels it by the input path ([input:rescue.tar.zst]), and those must differ.
# So compare on the "package :: reason" pair, which both gates take from the
# same classify()/audit helper -- that is exactly the thing that must agree.
pi_find() {
    # The shell gate prefixes each verifier line with its section
    # ("[staged debs (2 dir(s))] FAIL ..."); the direct invocation does not.
    # Drop that prefix, the "[src]" label and the ":: why" tail, so the two
    # sides compare on the defect itself -- which both take from the same
    # helper, so a diff here means they stopped sharing code.
    grep -E '^(\[[^]]*\] )*FAIL ' <<<"${1:-}" \
        | sed -e 's/^\[[^]]*\] //' \
              -e 's/^FAIL *\[[^]]*\] *//' \
              -e 's/ :: .*//' | sort -u
}

# 3a. class 1: the prebuilt rootfs tarballs carried the OLD snapshot.  The late
#     gate never sees a tarball: it extracts one and scans the DIRECTORY
#     (scan_image -> safe_extract_zst -> scan_rootfs), so the parity reference is
#     --rootfs DIR over the unpacked bytes, not --rootfs TARBALL.
mkrootfs "$T/a2/rescue.tar.zst" "$OLD_SRC" base-files 1.0 all libc6 2.41-7 amd64
mkdir -p "$T/a2/rescue.d"
zstd -dc "$T/a2/rescue.tar.zst" | tar -C "$T/a2/rescue.d" -xf - \
    || bad "replay/rescue-rootfs: could not unpack the fixture" ""
rc=0; LATE="$(python3 -I "$PY" --rootfs "$T/a2/rescue.d" --root-dir "$TR" \
    --index-dir "$IDX" 2>&1)" || rc=$?
early_rc=0
EARLY="$(python3 -I "$PY" --rootfs-tar "$T/a2/rescue.tar.zst" --work "$WF" \
    --root-dir "$TR" --index-dir "$IDX" 2>&1)" || early_rc=$?
lf="$(pi_find "$LATE")"; ef="$(pi_find "$EARLY")"
[ -n "$lf" ] && ok "replay/rescue-rootfs: the final gate reports findings" \
             || bad "replay/rescue-rootfs: the final gate reported nothing" "$LATE"
missing="$(comm -23 <(printf '%s\n' "$lf") <(printf '%s\n' "$ef"))"
[ -z "$missing" ] && ok "replay/rescue-rootfs: stage 25 reports every final-gate finding" \
                  || bad "replay/rescue-rootfs: stage 25 MISSED findings the final gate reports:
$missing" "$EARLY"
[ "$early_rc" = 1 ] && ok "replay/rescue-rootfs: stage 25 fails the input (rc=1)" \
                    || bad "replay/rescue-rootfs: stage 25 rc=$early_rc, wanted 1" "$EARLY"
grep -q "$OLD_SNAP" <<<"$EARLY" && ok "replay/rescue-rootfs: the old snapshot is named" \
                                 || bad "replay/rescue-rootfs: snapshot $OLD_SNAP not named" "$EARLY"

# 3b. class 2: an NCZ deb the ledger does not review (0.8.19 vs a 0.8.18 row).
rm -rf "$T/a2/tr"; cp -a "$TR" "$T/a2/tr"; rm -rf "$T/a2/tr/assets"
mkdir -p "$T/a2/tr/assets/screensaver/amd64"
cp "$T/debs/ncz-screensavers_0.8.19_amd64.deb" "$T/a2/tr/assets/screensaver/amd64/"
awk -F'\t' '!($1=="ncz-screensavers" && $2=="0.8.19")' \
    "$T/a2/tr/manifests/ncz-packages.tsv" > "$T/a2/t.tsv"
mv "$T/a2/t.tsv" "$T/a2/tr/manifests/ncz-packages.tsv"
# --debs takes a DIRECTORY (the late gate scans the image's deb tree), so both
# sides are pointed at the same directory of identical bytes.
DEBDIR="$T/a2/tr/assets/screensaver/amd64"
rc=0; LATE="$(python3 -I "$PY" --debs "$DEBDIR" --root-dir "$T/a2/tr" \
    --index-dir "$IDX" 2>&1)" || rc=$?
early_rc=0
EARLY="$(bash "$CHK" --root "$T/a2/tr" --work "$WF" --index-dir "$IDX" \
    --arch amd64 --no-substrate 2>&1)" || early_rc=$?
lf="$(pi_find "$LATE")"; ef="$(pi_find "$EARLY")"
[ -n "$lf" ] && ok "replay/screensavers: the final gate reports findings" \
             || bad "replay/screensavers: the final gate reported nothing" "$LATE"
missing="$(comm -23 <(printf '%s\n' "$lf") <(printf '%s\n' "$ef"))"
[ -z "$missing" ] && ok "replay/screensavers: stage 25 reports every final-gate finding" \
                  || bad "replay/screensavers: stage 25 MISSED findings the final gate reports:
$missing" "$EARLY"
[ "$early_rc" = 1 ] && ok "replay/screensavers: stage 25 fails the input (rc=1)" \
                    || bad "replay/screensavers: stage 25 rc=$early_rc, wanted 1" "$EARLY"
grep -q 'not in the reviewed NCZ ledger' <<<"$EARLY" \
    && ok "replay/screensavers: the ledger finding is named" \
    || bad "replay/screensavers: no ledger finding" "$EARLY"

# 3c. class 3: a substrate pool udeb with no reviewed origin.
mkiso "$T/a2/rogue.iso" --bad-udeb
rc=0; LATE="$(python3 -I "$PY" --substrate-iso "$T/a2/rogue.iso" \
    --root-dir "$TR" --index-dir "$IDX" --work "$WF" 2>&1)" || rc=$?
early_rc=0
mkdir -p "$T/a2/empty"
EARLY="$(gate --arch amd64 --substrate-iso "$T/a2/rogue.iso" --no-rootfs \
    --deb-dir "$T/a2/empty" --exclude "$T/a2/empty" 2>&1)" || early_rc=$?
lf="$(pi_find "$LATE")"; ef="$(pi_find "$EARLY")"
[ -n "$lf" ] && ok "replay/substrate: the final gate reports findings" \
             || bad "replay/substrate: the final gate reported nothing" "$LATE"
missing="$(comm -23 <(printf '%s\n' "$lf") <(printf '%s\n' "$ef"))"
[ -z "$missing" ] && ok "replay/substrate: stage 25 reports every final-gate finding" \
                  || bad "replay/substrate: stage 25 MISSED findings the final gate reports:
$missing" "$EARLY"
[ "$early_rc" = 1 ] && ok "replay/substrate: stage 25 fails the input (rc=1)" \
                    || bad "replay/substrate: stage 25 rc=$early_rc, wanted 1" "$EARLY"

# 3d. all three classes at once, exactly as they coexisted in the A2 image: the
#     union of the classes must all surface from ONE stage-25 run, because a
#     gate that stops at the first bad input would let the rest ship.
rm -rf "$T/a2/all"; mkdir -p "$T/a2/all"
cp -a "$T/a2/tr/." "$T/a2/all/"
mkdir -p "$T/a2/all/assets/rescue"
# the gate looks for assets/rescue/rescue-rootfs-$ARCH.tar.zst
cp "$T/a2/rescue.tar.zst" "$T/a2/all/assets/rescue/rescue-rootfs-amd64.tar.zst"
early_rc=0
EARLY="$(bash "$CHK" --root "$T/a2/all" --work "$WF" --index-dir "$IDX" \
    --arch amd64 --substrate-iso "$T/a2/rogue.iso" 2>&1)" || early_rc=$?
[ "$early_rc" = 1 ] && ok "replay/all: the combined A2 input set fails (rc=1)" \
                    || bad "replay/all: rc=$early_rc, wanted 1" "$EARLY"
n="$(grep -c '^\[provenance-predict\] FAIL' <<<"$EARLY")"
[ "${n:-0}" -ge 3 ] && ok "replay/all: all three classes are reported together (${n} findings)" \
                    || bad "replay/all: only ${n:-0} finding(s); a class was dropped" "$EARLY"
for cls in "$OLD_SNAP" 'not in the reviewed NCZ ledger' 'has no reviewed origin'; do
    grep -q "$cls" <<<"$EARLY" && ok "replay/all: class present: $cls" \
                              || bad "replay/all: class MISSING: $cls" "$EARLY"
done


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

# 2f0. the evidence-only run is not a verdict, so it must leave NO trace in
#      --report either.  run_scan() appends its FAIL rows to $REPORT on rc!=0,
#      and the wrapper restores FAILS around the evidence run but used to leave
#      those rows behind: the report listed a finding the returned verdict never
#      counted, which contradicts the comment that the evidence run produces no
#      verdict.  Force the evidence run to fail (a truncated ISO makes xorriso's
#      -ls exit non-zero) and assert the substrate finding is reported while the
#      evidence row is not.
if command -v xorriso >/dev/null 2>&1; then
    head -c 40000 "$T/fix/substrate.iso" > "$T/trunc.iso"
    rc=0; LAST="$(bash "$CHK" --root "$TR" --work "$WF" --index-dir "$IDX" \
        --arch amd64 --no-rootfs --substrate-iso "$T/trunc.iso" \
        --iso-evidence "$T/evr" --report "$T/rep.txt" 2>&1)" || rc=$?
    # The evidence writer reports as [iso]; the verdict scan of the same file
    # reports as [input:trunc.iso] and MUST stay (checked just below).
    if [ -f "$T/rep.txt" ] && ! grep -q '\[iso\] .*trunc.iso ::' "$T/rep.txt"; then
        ok "--iso-evidence: the evidence-only run leaves no finding in --report"
    else
        bad "--iso-evidence leaked its own FAIL row into --report" "$(cat "$T/rep.txt" 2>/dev/null)"
    fi
    if grep -q 'substrate ISO' <<<"$LAST" && grep -q '^FAIL' "$T/rep.txt" 2>/dev/null; then
        ok "  --report still carries the findings of the verdict-producing runs"
    else
        bad "  --report lost the verdict-producing runs' findings" "$(cat "$T/rep.txt" 2>/dev/null)"
    fi
else
    ok "--iso-evidence: --report leak check skipped (no xorriso to fail the evidence run)"
fi

# 2f. the --iso-evidence run writes a manifest, it is NOT a verdict.  Its exit
#     status must not move the failure count either way: a decrement on success
#     drives FAILS negative (run_scan bumps it only on failure) and would mask a
#     real finding.  Driven through a stub xorriso so the branch is reachable.
mkdir -p "$T/evbin"
printf '#!/bin/sh\ncase "$*" in *-ls*) echo total 0;; esac\nexit 0\n' > "$T/evbin/xorriso"
chmod +x "$T/evbin/xorriso"
mkdir -p "$T/evtrust" "$T/evdebs"
printf 'NCZ_BASE_MIRROR_SNAPSHOT="%s"\n' "$SNAP" > "$T/evtrust/release.conf"
rc=0; LAST="$(PATH="$T/evbin:$PATH" bash "$CHK" --root "$T/evtrust" --work "$WF" \
    --index-dir "$T/ev-index" --arch amd64 --no-rootfs --deb-dir "$T/evdebs" \
    --substrate-iso "$T/bad/rogue.iso" --iso-evidence "$T/ev" 2>&1)" || rc=$?
n="$(grep -oE '[0-9]+ input check\(s\) FAILED' <<<"$LAST" | awk '{print $1; exit}')"
[ "$rc" != 0 ] && ok "--iso-evidence: a failing input still fails the gate (rc=$rc)" \
               || bad "--iso-evidence masked a failing input (rc=$rc)" "$LAST"
[ "${n:-0}" -ge 1 ] && ok "--iso-evidence: the evidence run is not counted as a verdict (${n} finding(s))" \
                    || bad "--iso-evidence corrupted the failure count (n=${n:-unset})" "$LAST"

# 2g. the evidence mode itself.  The stub above returns before the listing
#     writer, so it never exercises it.  TOOL_PATH is deliberately fixed (a
#     shipping scan must not be steered by the caller's PATH), so this host
#     either HAS xorriso -- then the manifest is written and the mode exits 0
#     (0 = success here, NOT a finding count: an earlier revision returned 1
#     and drove FAILS negative) -- or it does not, and the mode must fail CLOSED
#     with the env finding rather than write a half manifest and report a pass.
mkdir -p "$T/ev2"
rc=0; LAST="$(python3 -I "$PY" --ubuntu-only --work "$WF" \
    --iso-evidence "$T/ev2" --substrate-iso "$T/fix/substrate.iso" 2>&1)" || rc=$?
if [ -s "$T/ev2/iso-listing.txt" ]; then
    [ "$rc" = 0 ] && ok "--iso-evidence: writes the manifest and exits 0 (rc=$rc)" \
                  || bad "--iso-evidence: wrote a manifest but exited $rc, wanted 0" "$LAST"
    grep -q '^ISO-EVIDENCE' <<<"$LAST" && ok "--iso-evidence: reports the manifest it wrote" \
                                       || bad "--iso-evidence: no ISO-EVIDENCE line" "$LAST"
else
    [ "$rc" = 1 ] && ok "--iso-evidence: no xorriso fails closed, no partial manifest (rc=$rc)" \
                  || bad "--iso-evidence: exited $rc with no manifest, wanted 1" "$LAST"
    grep -q 'xorriso' <<<"$LAST" && ok "--iso-evidence: the failure names the missing tool" \
                                 || bad "--iso-evidence: failure does not name xorriso" "$LAST"
fi

# 2h. the CALL SITES match the writer's signature, pinned without the tool.
#     scan_input_evidence() renders no verdict (its docstring says so and every
#     return is 0), so a FAILS delta can never pin its arity: a correct 2-arg
#     call on a tool-present host returns 0 with a delta of 0, and a wrong call
#     raises TypeError.  Pin exactly that: every in-tree call must bind, and a
#     call with an extra/renamed keyword must raise TypeError (which main()'s
#     `except Exception` turns into a deterministic non-zero exit, so a bad
#     call can never read as success).
rc=0; LAST="$(python3 -I - "$PY" "$ROOT/build/forky-provenance.py" \
    "$ROOT/build/check-inputs-provenance.sh" <<'PYEOF' 2>&1
import importlib.util, inspect, os, sys, tempfile
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
fp = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(fp)
except SystemExit:
    sys.exit(3)
sig = inspect.signature(fp.scan_input_evidence)
params = list(sig.parameters)
print("PARAMS", ",".join(params))
# (a) the documented call shape binds without TypeError
d = tempfile.mkdtemp()
iso = os.path.join(d, "x.iso")
open(iso, "wb").close()
try:
    sig.bind(d, iso)
    print("BIND ok")
except TypeError as e:
    print("BIND TypeError:", e)
# (b) a mismatched call must raise TypeError, never succeed silently
try:
    sig.bind(d, iso, unexpected_kw=1)
except TypeError as e:
    print("MISMATCH TypeError:", str(e)[:60])
else:
    print("MISMATCH accepted (arity is not pinned)")
# (c) the module entry point must not turn a TypeError into a zero exit: its
#     `except Exception` -> die() -> SystemExit(2).  Pin the handler in the
#     __main__ block (where it lives) and that die() exits non-zero.
with open(sys.argv[1]) as fh:
    modsrc = fh.read()
tail = modsrc.split('if __name__ == "__main__":', 1)
print("MAIN_GUARDS", len(tail) == 2 and "except Exception" in tail[1])
# die() must terminate non-zero, or a TypeError would read as a pass.  Call it
# in a subprocess so the SystemExit it raises is observable, not fatal here.
import subprocess
r = subprocess.run([sys.executable, "-I", "-c",
                    "import importlib.util,sys\n"
                    "s=importlib.util.spec_from_file_location('fp',sys.argv[1])\n"
                    "m=importlib.util.module_from_spec(s);s.loader.exec_module(m)\n"
                    "m.die('probe')", sys.argv[1]],
                   capture_output=True)
print("DIE_RC", r.returncode)
PYEOF
)" || rc=$?
bad2=""
grep -q '^PARAMS work,iso,src$' <<<"$LAST" || bad2="$bad2 signature-drifted"
grep -q '^BIND ok$' <<<"$LAST"          || bad2="$bad2 documented-call-does-not-bind"
grep -q '^MISMATCH TypeError' <<<"$LAST" || bad2="$bad2 mismatch-accepted"
grep -q '^MAIN_GUARDS True$' <<<"$LAST" || bad2="$bad2 main-has-no-Exception-guard"
grep -qE '^DIE_RC [1-9][0-9]*$' <<<"$LAST" || bad2="$bad2 die-does-not-exit-nonzero"
if [ -z "$bad2" ]; then
    ok "--iso-evidence: every call site matches the writer signature, and a mismatched call raises"
else
    bad "--iso-evidence: writer call/def arity mismatch ($bad2)" "$LAST"
fi

# 2i. --iso-evidence renders no verdict, so a bare (non --ubuntu-only) scan must
#     REFUSE it rather than silently ignore it and report a pass.
expect_rc "--iso-evidence without --ubuntu-only is refused" 2 \
    python3 -I "$PY" --iso-evidence "$T/ev2" --substrate-iso "$T/fix/substrate.iso" --work "$WF"

# 2j. the shared-helper contract the parity claim rests on.  Stage 25 and the
#     final gate "cannot disagree" because they call the SAME helpers; that only
#     holds while every call site still matches the helper's signature.  These
#     pin the three ways a refactor could silently split the two gates:
#       (a) a required parameter added to _scan_initrd, which would make the
#           image scan's 3-arg ESP call (scan_image) raise TypeError;
#       (b) 'src' dropped or renamed, which would turn every fail(src, ...)
#           inside it into a NameError;
#       (c) _ncz_build_context() no longer resolving release_conf() at call time
#           (a def moved below a call would only bite at runtime, not at import).
rc=0; LAST="$(python3 -I - "$PY" <<'PYEOF' 2>&1
import importlib.util, inspect, sys, tempfile, os
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)            # import-time: any bad def order surfaces here

sig = inspect.signature(fp._scan_initrd)
ps = sig.parameters
bad = []

# (a) the image scan calls it with three arguments; that must keep binding, and
#     every extra parameter must have a default so it stays optional.
try:
    sig.bind(None, "/p", "/o")
except TypeError as e:
    bad.append(f"3-arg call site no longer binds: {e}")
for name, p in ps.items():
    if name in ("ref", "path", "owned"):
        continue
    if p.default is inspect.Parameter.empty:
        bad.append(f"_scan_initrd parameter {name!r} is required; the ESP call "
                   "site passes 3 arguments and would raise TypeError")

# (b) 'src' must exist, and every fail() inside it must see it.
if "src" not in ps:
    bad.append("_scan_initrd has no 'src' parameter; fail(src, ...) would NameError")
elif ps["src"].default != "image":
    bad.append(f"_scan_initrd src default is {ps['src'].default!r}, expected 'image'")

# (c) the exemption helper must resolve release_conf() when CALLED, not at def
#     time (Python resolves globals lazily, so this holds unless something shadows
#     or rebinds it).
if not hasattr(fp, "release_conf"):
    bad.append("release_conf is not defined at module scope")
else:
    try:
        v = fp._ncz_build_context()
    except NameError as e:
        bad.append(f"_ncz_build_context raised NameError: {e}")
    except Exception:
        pass
    else:
        if not isinstance(v, bool):
            bad.append(f"_ncz_build_context returned {type(v).__name__}, expected bool")

for b in bad:
    print("CONTRACT", b)
print("OK" if not bad else "BROKEN")
PYEOF
)" || rc=$?
if grep -q '^OK$' <<<"$LAST"; then
    ok "shared-helper contract: _scan_initrd call sites and _ncz_build_context hold"
else
    bad "shared-helper contract broken (the two gates can now diverge)" "$LAST"
fi

# 2k. read_iso_records() must TERMINATE on a directory cycle.  A record whose
#     extent repeats an ancestor's under a new name (root/LOOP carrying root's
#     own extent) is a tree no real ISO contains, but the walk pushed every
#     child directory and deduped on (path, start) only, so LOOP, LOOP/LOOP,
#     ... each named a fresh path the seen set never held: the scan never
#     returned and out/stack grew without bound.  Build the image by hand (the
#     fixture writer cannot emit a cycle) and give the walk a hard timeout.
rc=0; LAST="$(FP_PATH="$PY" python3 -I - <<'PYEOF' 2>&1
import importlib.util, os, signal, sys, tempfile
spec = importlib.util.spec_from_file_location("fp", os.environ["FP_PATH"])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)
LBS, PVD = fp.ISO_LBS, fp.ISO_PVD_OFFSET

def rec(name, lba, size, isdir):
    nl = len(name); rl = 33 + nl; rl += rl % 2
    b = bytearray(rl); b[0] = rl
    b[2:6] = lba.to_bytes(4, "little"); b[6:10] = lba.to_bytes(4, "big")
    b[10:14] = size.to_bytes(4, "little"); b[14:18] = size.to_bytes(4, "big")
    b[25] = 0x02 if isdir else 0x00; b[32] = nl; b[33:33 + nl] = name
    return bytes(b)

root_lba = PVD // LBS + 1
size = LBS
data = bytearray((root_lba + 2) * LBS)
pvd = bytearray(LBS); pvd[0] = 1; pvd[1:6] = b"CD001"; pvd[6] = 1
pvd[156:156 + 34] = rec(b"\x00", root_lba, size, True)
data[PVD:PVD + LBS] = pvd
body = (rec(b"\x00", root_lba, size, True)      # .
        + rec(b"\x01", root_lba, size, True)    # ..
        + rec(b"LOOP", root_lba, size, True))   # a child with the ROOT's extent
data[root_lba * LBS:root_lba * LBS + len(body)] = body

class Timeout(Exception):
    pass

def _alarm(_s, _f):
    raise Timeout()

signal.signal(signal.SIGALRM, _alarm)
signal.alarm(10)
try:
    recs = fp.read_iso_records(bytes(data))
except Timeout:
    print("HUNG")
    sys.exit(0)
finally:
    signal.alarm(0)
print("RETURNED", len(recs))
print("LOOP_RECORDED", any(k[1] == "LOOP" for k in recs))
PYEOF
)" || rc=$?
if grep -q '^RETURNED ' <<<"$LAST"; then
    ok "read_iso_records terminates on a directory cycle ($(grep '^RETURNED' <<<"$LAST"))"
else
    bad "read_iso_records does not terminate on a directory cycle (unbounded walk)" "$LAST"
fi
grep -q '^LOOP_RECORDED True$' <<<"$LAST" \
    && ok "  the cyclic member is still recorded, just not descended" \
    || bad "  the cyclic member was dropped instead of recorded" "$LAST"

# 2l. the substrate scan must resolve /pool on a REAL ISO, whose ECMA-119
#     directory records store identifiers upper case (POOL, DISTS, INITRD.GZ).
#     The pool/initrd filters compared them case-sensitively against the
#     lower-case ls(1) spelling, so every xorriso-written substrate reported
#     'carries no /pool tree' -- including the canonical positive case.
expect_rc "substrate ISO: the uppercase-record fixture is found (pool+dists)" 0 \
    python3 -I "$PY" --substrate-iso "$T/fix/substrate.iso" --work "$WF" \
    --root-dir "$TR" --index-dir "$IDX"
grep -q '/cdrom pool authorized' <<<"$LAST" \
    && ok "  the scan reports the pool it authorized" \
    || bad "  the scan never authorized the pool" "$LAST"

# 2m. --iso-evidence describes exactly ONE ISO.  With two --substrate-iso the
#     evidence branch wrote only the first directory and exited 0, so every ISO
#     after it was silently unlisted while the caller read the run as complete.
expect_rc "--iso-evidence with two --substrate-iso is refused" 2 \
    python3 -I "$PY" --ubuntu-only --work "$WF" --iso-evidence "$T/ev3" \
    --substrate-iso "$T/fix/substrate.iso" --substrate-iso "$T/bad/rogue.iso"

# 2n. --iso-evidence without --substrate-iso must never be silently ignored: it
#     renders no verdict, so a run that dropped it would report a pass the
#     caller thinks covers an ISO that was never read.
expect_rc "--iso-evidence without --substrate-iso is refused" 2 \
    python3 -I "$PY" --ubuntu-only --work "$WF" --iso-evidence "$T/ev4"

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

# ===========================================================================
echo "== 5. the substrate's own kernel udebs and d-i build markers: scope =="
# docs/ONE-KERNEL.md ("Substrate input scan").  The
# one-kernel exemption clears ONLY d-i's installer-kernel udebs (a kernel-artifact
# name that ends in -di) and ONLY inside the substrate whose sha256 is pinned in
# manifests/base.pin.  The debian-installer build-marker records are cleared by
# identity alone, and only for the exact (name, version) that a
# manifests/di-build-markers.tsv row ties to that same pinned sha256.  Every
# other record still needs its hash or a reviewed row.
KMARK="cdrom-gtk-20300101-00:00:00"
mkiso_k() {  # out-iso [--rogue] [--non-di-kernel] [--marker-in-pool] [--marker-ver V] [--no-pool-kernel]
    local out="$1"; shift
    local rogue=0 nondi=0 mpool=0 nopk=0 mver="$KMARK"
    while [ $# -gt 0 ]; do
        case "$1" in
            --rogue) rogue=1 ;;
            --non-di-kernel) nondi=1 ;;
            --marker-in-pool) mpool=1 ;;
            --marker-ver) mver="$2"; shift ;;
            --no-pool-kernel) nopk=1 ;;
        esac
        shift
    done
    local s="$T/isoroot-k"; rm -rf "$s"; mkdir -p "$s/pool/main"
    cp "$REPO/pool/main/l/libc6/libc6_2.41-7_amd64.deb" "$s/pool/main/libc6.deb"
    # listed in the pool index: d-i's own kernel-module udeb (no other origin)
    [ "$nopk" = 1 ] || mkudeb "$s/pool/main/ext4k.udeb" ext4-modules-9-x-di 9-1 amd64
    # NOT listed anywhere: the orphan walk sees it by file name only
    [ "$nopk" = 1 ] || mkudeb "$s/pool/main/nic-modules-9-x-di_9_amd64.udeb" nic-modules-9-x-di 9 amd64
    local idx="$s/dists/$SNAP/main/debian-installer/binary-amd64"
    mkdir -p "$idx" "$s/dists/$SNAP/main/debian-installer/binary-all"
    {
        printf 'Package: libc6\nVersion: 2.41-7\nArchitecture: amd64\nFilename: pool/main/libc6.deb\nSize: %s\nSHA256: %s\n\n' \
            "$(stat -c%s "$s/pool/main/libc6.deb")" "$(sha "$s/pool/main/libc6.deb")"
        [ "$nopk" = 1 ] || printf 'Package: ext4-modules-9-x-di\nVersion: 9-1\nArchitecture: amd64\nFilename: pool/main/ext4k.udeb\nSize: %s\nSHA256: %s\n\n' \
            "$(stat -c%s "$s/pool/main/ext4k.udeb")" "$(sha "$s/pool/main/ext4k.udeb")"
        if [ "$nondi" = 1 ]; then
            # a kernel artifact that is NOT a d-i udeb: never exempt
            mkudeb "$s/pool/main/limg.udeb" linux-image-9-x 9-1 amd64
            printf 'Package: linux-image-9-x\nVersion: 9-1\nArchitecture: amd64\nFilename: pool/main/limg.udeb\nSize: %s\nSHA256: %s\n\n' \
                "$(stat -c%s "$s/pool/main/limg.udeb")" "$(sha "$s/pool/main/limg.udeb")"
        fi
        if [ "$mpool" = 1 ]; then
            # the marker identity on a HASHED record: identity-only must not reach it
            # (the bytes carry a plain version: dpkg-deb refuses the stamp's ':')
            mkudeb "$s/pool/main/dimark.udeb" debian-installer 1 amd64
            printf 'Package: debian-installer\nVersion: %s\nArchitecture: amd64\nFilename: pool/main/dimark.udeb\nSize: %s\nSHA256: %s\n\n' \
                "$KMARK" "$(stat -c%s "$s/pool/main/dimark.udeb")" "$(sha "$s/pool/main/dimark.udeb")"
        fi
    } > "$idx/Packages"
    cp "$idx/Packages" "$s/dists/$SNAP/main/debian-installer/binary-all/Packages"
    [ "$rogue" = 1 ] && mkudeb "$s/pool/main/rogue.udeb" rogue-udeb 9.9 amd64
    local ir; ir="$(mktemp -d "$T/initrd-k.XXXXXX")"
    mkdir -p "$ir/udebs" "$ir/var/lib/dpkg"
    cp "$T/debs/cdrom-checker-udeb_1.0_amd64.udeb" "$ir/udebs/cdromcheck.udeb"
    # the d-i udpkg status format: no Architecture on these records
    printf 'Package: ncz-installer\nStatus: install ok installed\nVersion: 7.3.0\nArchitecture: amd64\n\nPackage: fat-modules-9-x-di\nStatus: install ok installed\nVersion: 9-0\n\nPackage: debian-installer\nStatus: install ok installed\nVersion: %s\n' \
        "$mver" > "$ir/var/lib/dpkg/status"
    ( cd "$ir" && find . -mindepth 1 | sort | cpio -o -H newc --quiet ) | gzip -n -9 > "$s/initrd.gz"
    rm -rf "$ir"
    mkdir -p "$(dirname "$out")"
    if command -v xorriso >/dev/null 2>&1; then
        xorriso -as mkisofs -quiet -o "$out" -R -J -joliet-long -iso-level 3 \
            -V NCZFIX "$s" >/dev/null 2>&1
    else
        xorriso_fallback "$s" "$out"
    fi || { echo "FAIL: could not build fixture ISO $out" >&2; exit 1; }
}
# TRK: the fixture trust root that opts in (release.conf) and pins its substrate
TRK="$T/trust-k"; rm -rf "$TRK"; cp -a "$TR" "$TRK"
printf 'NCZ_ONE_KERNEL_SUBSTRATE_UDEBS=exempt\n' >> "$TRK/release.conf"
pin_k() {  # iso [marker-row-substrate-sha]  -- base.pin pins THIS iso's bytes
    local s; s="$(sha "$1")"
    printf '# fixture\namd64\t%s\tThu, 01 Jan 2030 00:00:00 UTC\t%s\t100.0\thttps://example.invalid/netinst.iso\n' \
        "$s" "$SNAP" > "$TRK/manifests/base.pin"
    printf '# fixture\ndebian-installer\t%s\tamd64\t%s\tfixture: d-i build marker\n' \
        "$KMARK" "${2:-$s}" > "$TRK/manifests/di-build-markers.tsv"
}
scan_k() {  # iso [root]
    python3 -I "$PY" --substrate-iso "$1" --work "$WF" --root-dir "${2:-$TRK}" --index-dir "$IDX"
}
has()   { grep -qE -- "$2" <<<"$LAST" && ok "  $1" || bad "  $1" "$LAST"; }
hasnt() { grep -qE -- "$2" <<<"$LAST" && bad "  $1" "$LAST" || ok "  $1"; }

mkiso_k "$T/fix/k.iso"; pin_k "$T/fix/k.iso"
expect_rc "pinned substrate + opt-in: d-i kernel udebs and the build marker clear" 0 \
    scan_k "$T/fix/k.iso"
has "the pool record is exempt by name" '^NOTE .*ext4-modules-9-x-di 9-1 amd64 :: one-kernel-exempt'
has "the pool orphan is exempt by name" '^NOTE .*nic-modules-9-x-di_9_amd64.udeb :: one-kernel-exempt'
has "the initrd status record is exempt by name" '^NOTE .*fat-modules-9-x-di 9-0 :: one-kernel-exempt'
has "the build marker clears by identity" "^NOTE .*debian-installer $KMARK :: d-i build marker"

expect_rc "no opt-in (release.conf): the same substrate's kernel udebs and marker FAIL" 1 \
    scan_k "$T/fix/k.iso" "$TR"
has "the pool record needs an origin" '^FAIL .*ext4-modules-9-x-di 9-1 amd64 :: not authorized'
has "the pool orphan needs an origin" '^FAIL .*nic-modules-9-x-di_9_amd64.udeb :: orphan pool file'
has "the substrate is refused as a whole" ':: the substrate.s /cdrom pool is not fully authorized'

pin_k "$T/fix/k.iso"
sed -i "s/^amd64\t[0-9a-f]\{64\}/amd64\t$(printf 'e%.0s' {1..64})/" "$TRK/manifests/base.pin"
expect_rc "opt-in but the ISO is NOT the sha256-pinned substrate: nothing is exempt" 1 \
    scan_k "$T/fix/k.iso"
has "the pool record FAILS off the pin" '^FAIL .*ext4-modules-9-x-di 9-1 amd64 :: not authorized'
has "the pool orphan FAILS off the pin" '^FAIL .*nic-modules-9-x-di_9_amd64.udeb :: orphan pool file'
has "the scan says why" 'not the sha256-pinned substrate'
# the initrd half, with a pool that needs no exemption so the scan reaches it
mkiso_k "$T/fix/k-nopk.iso" --no-pool-kernel; pin_k "$T/fix/k-nopk.iso"
expect_rc "  (control) the same initrd on the pinned substrate passes" 0 scan_k "$T/fix/k-nopk.iso"
sed -i "s/^amd64\t[0-9a-f]\{64\}/amd64\t$(printf 'e%.0s' {1..64})/" "$TRK/manifests/base.pin"
expect_rc "  off the pin, the initrd's kernel record and the marker FAIL" 1 scan_k "$T/fix/k-nopk.iso"
has "the initrd status record FAILS off the pin" '^FAIL .*fat-modules-9-x-di 9-0'
has "the marker FAILS off the pin" "^FAIL .*debian-installer $KMARK"

mkiso_k "$T/fix/k-rogue.iso" --rogue; pin_k "$T/fix/k-rogue.iso"
expect_rc "a NON-kernel unknown udeb in the pinned substrate still FAILS" 1 \
    scan_k "$T/fix/k-rogue.iso"
has "the rogue orphan is reported" '^FAIL .*rogue.udeb :: orphan pool file'
hasnt "the rogue udeb is never exempt" 'rogue\.udeb :: one-kernel-exempt'

mkiso_k "$T/fix/k-nondi.iso" --non-di-kernel; pin_k "$T/fix/k-nondi.iso"
expect_rc "a kernel artifact that is not a d-i udeb still FAILS" 1 \
    scan_k "$T/fix/k-nondi.iso"
has "linux-image-* is not the installer's kernel udeb" '^FAIL .*linux-image-9-x 9-1 amd64 :: not authorized'

mkiso_k "$T/fix/k-ver.iso" --marker-ver "cdrom-gtk-20300101-00:00:01"; pin_k "$T/fix/k-ver.iso"
expect_rc "a changed marker version FAILS (identity is exact, not a pattern)" 1 \
    scan_k "$T/fix/k-ver.iso"
has "the changed marker is reported" '^FAIL .*debian-installer cdrom-gtk-20300101-00:00:01'

pin_k "$T/fix/k.iso" "$(printf 'a%.0s' {1..64})"
expect_rc "a marker row tied to ANOTHER substrate sha256 does not clear this one" 1 \
    scan_k "$T/fix/k.iso"
has "the marker is reported" "^FAIL .*debian-installer $KMARK"

mkiso_k "$T/fix/k-mpool.iso" --marker-in-pool; pin_k "$T/fix/k-mpool.iso"
expect_rc "the marker identity on a hashed pool record still needs its hash" 1 \
    scan_k "$T/fix/k-mpool.iso"
has "the hashed record is reported" "^FAIL .*debian-installer $KMARK amd64 :: not authorized"

pin_k "$T/fix/k.iso"
printf 'busybox-udeb\t1.0\tamd64\t%s\tnot a marker\n' "$(sha "$T/fix/k.iso")" \
    >> "$TRK/manifests/di-build-markers.tsv"
expect_rc "the marker ledger refuses a row that is not debian-installer" 2 \
    scan_k "$T/fix/k.iso"
pin_k "$T/fix/k.iso"

# the finished-image path never gets either allowance, even with the opt-in:
# a rootfs whose dpkg status carries the same no-Architecture records FAILS.
rk="$(mktemp -d "$T/rootfs-k.XXXXXX")"; mkdir -p "$rk/var/lib/dpkg" "$rk/etc/apt" "$rk/usr/lib"
printf 'Package: fat-modules-9-x-di\nStatus: install ok installed\nVersion: 9-0\n\nPackage: debian-installer\nStatus: install ok installed\nVersion: %s\n' \
    "$KMARK" > "$rk/var/lib/dpkg/status"
printf 'ID=ncz-os\nNAME="NCZ OS"\nVERSION_ID="4"\n' > "$rk/usr/lib/os-release"
printf '%s\n' "$PIN_SRC" > "$rk/etc/apt/sources.list"
tar -C "$rk" -cf - . | zstd -q -19 -o "$T/fix/k-rootfs.tar.zst" -f; rm -rf "$rk"
expect_rc "outside the substrate scan neither allowance applies" 1 \
    python3 -I "$PY" --rootfs-tar "$T/fix/k-rootfs.tar.zst" --work "$WF" \
    --root-dir "$TRK" --index-dir "$IDX"
has "the kernel record FAILS in a rootfs" '^FAIL .*fat-modules-9-x-di 9-0'
has "the marker FAILS in a rootfs" "^FAIL .*debian-installer $KMARK"

# ===========================================================================
echo "== 6. the pinned payload record authorizes a payload deb staged before refresh-sources =="
# Measured on ULTRA, 2026-11-07 (arm64): a CI re-run in a clone whose earlier
# run had reached refresh-sources.  assets/cix-debs is gitignored, so the pinned
# payload deb that run staged was still there when stage 25 ran again; stage 25
# runs BEFORE refresh-sources writes the run receipt, so the deb (sha256 equal to
# manifests/singularity-payload.tsv) failed "not recorded in the image receipt".
# The amd64 run on HYDRA passed only because its clone was fresh (no payload deb
# at stage 25).  --payload-pin lets stage 25 read the REVIEWED pin row as the
# record; bytes that row does not pin still fail closed.
TRP="$T/trust-pin"; rm -rf "$TRP"; cp -a "$TR" "$TRP"; rm -rf "$TRP/assets"
# no static ledger row for the payload: only the timestamped rule can apply
sed -i '/^ncz-singularity-desktop\t/d' "$TRP/manifests/ncz-packages.tsv"
printf 'ncz-singularity-desktop\t^[0-9]{14}\\+bk[0-9]+\\+(git|tgz)[0-9a-f]{8}$\tarm64\tbuild/build-singularity-deb.sh\tsingularity\tpayload\n' \
    >> "$TRP/manifests/ncz-timestamped.tsv"
PV=20261106222540+bk0+git6427e9c4
PF="ncz-singularity-desktop_${PV}_arm64.deb"
mkdir -p "$TRP/assets/cix-debs"
mkdeb "$TRP/assets/cix-debs/$PF" ncz-singularity-desktop "$PV" arm64
H_PAY="$(sha "$TRP/assets/cix-debs/$PF")"
PIN="$T/pin"; mkdir -p "$PIN"
pinrow() {  # out arch sha file
    { printf '# fixture singularity-payload.tsv\n'; printf '%s\t%s\t%s\n' "$2" "$3" "$4"; } > "$1"
}
pinrow "$PIN/good.tsv" arm64 "$H_PAY" "$PF"
gate_p() { bash "$CHK" --root "$TRP" --work "$WF" --index-dir "$IDX" --arch arm64 \
    --no-substrate --no-rootfs "$@"; }

expect_rc "6a. repro: the staged pinned payload with no receipt and no pin FAILS" 1 gate_p
lastfind "not recorded in the image receipt"
expect_rc "6b. the same deb passes when stage 25 reads the reviewed pin row" 0 \
    gate_p --payload-pin "$PIN/good.tsv"
pinrow "$PIN/othersha.tsv" arm64 "$(printf 'a%.0s' {1..64})" "$PF"
expect_rc "6c. a deb whose sha256 the pin does NOT record still FAILS" 1 \
    gate_p --payload-pin "$PIN/othersha.tsv"
lastfind "does not match the image receipt"
pinrow "$PIN/otherver.tsv" arm64 "$H_PAY" "ncz-singularity-desktop_20261013150000+bk0+tgz0badf00d_arm64.deb"
expect_rc "6d. a staged deb of another version than the pin FAILS (stale leftover)" 1 \
    gate_p --payload-pin "$PIN/otherver.tsv"
lastfind "not recorded in the image receipt"
pinrow "$PIN/amd64only.tsv" amd64 "$H_PAY" "ncz-singularity-desktop_${PV}_amd64.deb"
expect_rc "6e. a pin with no row for this arch authorizes nothing" 1 \
    gate_p --payload-pin "$PIN/amd64only.tsv"
lastfind "not recorded in the image receipt"
pinrow "$PIN/badsha.tsv" arm64 "NOTHEX" "$PF"
expect_rc "6f. a malformed pin sha256 is refused (fail closed, rc 2)" 2 \
    gate_p --payload-pin "$PIN/badsha.tsv"
pinrow "$PIN/badname.tsv" arm64 "$H_PAY" "ncz-kernel_7.3.0+r293_arm64.deb"
expect_rc "6g. a pin row naming another package is refused (rc 2)" 2 \
    gate_p --payload-pin "$PIN/badname.tsv"
expect_rc "6h. a missing pin file is refused (rc 2)" 2 \
    gate_p --payload-pin "$PIN/nonexistent.tsv"
# the pin is a record for the payload only: a different package with the same
# timestamped shape and no reviewed row is still refused.
mkdeb "$TRP/assets/cix-debs/ncz-rogue_${PV}_arm64.deb" ncz-rogue "$PV" arm64
expect_rc "6i. the pin authorizes nothing but the payload deb it names" 1 \
    gate_p --payload-pin "$PIN/good.tsv"
lastfind "ncz-rogue"
rm -f "$TRP/assets/cix-debs/ncz-rogue_${PV}_arm64.deb"
# the run receipt (resume) and the pin can both be passed
mkreceipt "$T/pay-arm64-receipt.json" ncz-singularity-desktop "$PV" arm64 "$H_PAY"
expect_rc "6j. the run receipt alone authorizes it too (resume after refresh-sources)" 0 \
    gate_p --receipt "$T/pay-arm64-receipt.json"
expect_rc "6k. pin + run receipt together pass" 0 \
    gate_p --payload-pin "$PIN/good.tsv" --receipt "$T/pay-arm64-receipt.json"

printf '\n== provenance-predict tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
if [ "$FAIL" = 0 ]; then exit 0; else exit 1; fi
