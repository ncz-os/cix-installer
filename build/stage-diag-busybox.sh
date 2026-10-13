#!/bin/bash
# stage-diag-busybox.sh -- the installer's diagnostic static busybox
# (assets/diag/busybox-<arch>) is Debian forky busybox-static, pinned in
# manifests/diag-busybox.tsv.
#
# Modes (default --check):
#   --check            offline: each committed binary has the pinned sha256 and
#                      size, is an ELF for its arch, names "(Debian <version>)" in
#                      its BusyBox banner and carries no Ubuntu build identity.
#   --fetch            download the pinned busybox-static deb for each arch from
#                      snapshot.debian.org at the pinned snapshot, verify its
#                      sha256 and size, extract usr/bin/busybox, verify the
#                      binary pin and install it as the dest (mode 0755).
#   --repin            read the busybox-static record for each arch from a
#                      VERIFIED snapshot index (--index-dir, required), fetch and
#                      extract as --fetch does, and rewrite the manifest rows.
#   --index-dir DIR    with --fetch/--repin: also require the downloaded debs to
#                      pass build/check-forky-provenance.sh against DIR, i.e. be
#                      byte-identical to the signed pinned snapshot. Fill DIR
#                      with: python3 -I build/forky-provenance.py --fetch-index
#                      --index-dir DIR --debs <any deb dir>
#   --arch amd64|arm64 limit to one arch (default: both)
# Scratch lives under $TMPDIR (default: the repository root) and is removed.
# NCZ_DIAG_BB_ROOT overrides the repository root (build/test-diag-busybox.sh).
# Exit: 0 ok, 1 verification failed, 2 usage/environment.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${NCZ_DIAG_BB_ROOT:-$(cd "$HERE/.." && pwd)}"
PIN="$ROOT/manifests/diag-busybox.tsv"
SNAPSHOT_BASE="${NCZ_DIAG_BB_SNAPSHOT_BASE:-https://snapshot.debian.org/archive/debian}"
MODE=check; ARCHES="amd64 arm64"; INDEX_DIR=""
die() { echo "stage-diag-busybox: $*" >&2; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --fetch) MODE=fetch ;;
        --repin) MODE=repin ;;
        --index-dir) INDEX_DIR="${2:-}"; shift ;;
        --index-dir=*) INDEX_DIR="${1#--index-dir=}" ;;
        --arch) ARCHES="${2:-}"; shift ;;
        --arch=*) ARCHES="${1#--arch=}" ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done
for a in $ARCHES; do case "$a" in amd64|arm64) ;; *) die "unsupported arch: $a" ;; esac; done
[ -f "$PIN" ] || die "pin file missing: $PIN"
[ "$MODE" != repin ] || [ -n "$INDEX_DIR" ] || die "--repin needs --index-dir (a verified snapshot index)"

BAD=0
fail() { echo "FAIL  $*"; BAD=$((BAD + 1)); }
okm()  { echo "ok    $*"; }
sha()  { sha256sum "$1" | awk '{print $1}'; }
size() { wc -c < "$1" | tr -d ' '; }
pin_row() { awk -F'\t' -v a="$1" '!/^#/ && $1 == a' "$PIN"; }
elf_machine() {   # x86-64 / aarch64 from the ELF header, no file(1) needed
    python3 -I - "$1" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    h = f.read(20)
if h[:4] != b"\x7fELF":
    print("not-elf"); sys.exit(0)
m = int.from_bytes(h[18:20], "little" if h[5] == 1 else "big")
print({62: "amd64", 183: "arm64"}.get(m, f"machine-{m}"))
PY
}

check_binary() {   # check_binary <arch> <file> <want_sha> <want_size> <version>
    local a="$1" f="$2" ws="$3" wz="$4" ver="$5" got m
    [ -f "$f" ] || { fail "$a: ${f#"$ROOT"/} missing"; return; }
    got="$(sha "$f")"
    [ "$got" = "$ws" ] && okm "$a: ${f#"$ROOT"/} sha256 matches the pin" \
        || fail "$a: ${f#"$ROOT"/} sha256 $got != pinned $ws"
    [ "$(size "$f")" = "$wz" ] || fail "$a: ${f#"$ROOT"/} size $(size "$f") != pinned $wz"
    m="$(elf_machine "$f")"
    [ "$m" = "$a" ] && okm "$a: ELF machine $m" || fail "$a: ELF machine is $m, want $a"
    if LC_ALL=C grep -a -q -F "(Debian $ver)" "$f"; then okm "$a: banner names Debian $ver"
    else fail "$a: BusyBox banner does not name (Debian $ver)"; fi
    if LC_ALL=C grep -a -q -E '"os":"ubuntu"|\(Ubuntu [0-9][^)]*ubuntu' "$f"; then
        fail "$a: binary carries an Ubuntu build identity"
    else
        okm "$a: no Ubuntu build identity"
    fi
}

W=""
cleanup() { [ -n "$W" ] && rm -rf "$W"; }
trap cleanup EXIT
scratch() {
    [ -n "$W" ] && return
    W="$(mktemp -d "${TMPDIR:-$ROOT}/.diag-busybox.XXXXXX")" || die "cannot create scratch dir"
}

fetch_one() {   # fetch_one <arch> <version> <deb_sha> <deb_size> <snapshot> <dest> -> sets FETCHED_BIN
    local a="$1" ver="$2" dsha="$3" dsz="$4" snap="$5" dest="$6" debv deb url
    debv="${ver#*:}"
    deb="busybox-static_${debv}_${a}.deb"
    url="$SNAPSHOT_BASE/$snap/pool/main/b/busybox/$deb"
    scratch; mkdir -p "$W/debs-$a" "$W/x-$a"
    curl -fsSL --retry 3 -o "$W/debs-$a/$deb" "$url" || { fail "$a: download failed: $url"; return 1; }
    [ "$(sha "$W/debs-$a/$deb")" = "$dsha" ] || { fail "$a: $deb sha256 $(sha "$W/debs-$a/$deb") != pinned $dsha"; return 1; }
    [ "$(size "$W/debs-$a/$deb")" = "$dsz" ] || { fail "$a: $deb size != pinned $dsz"; return 1; }
    okm "$a: $deb matches the pinned sha256"
    if [ -n "$INDEX_DIR" ]; then
        if bash "$HERE/check-forky-provenance.sh" --index-dir "$INDEX_DIR" --debs "$W/debs-$a" >"$W/prov-$a.log" 2>&1; then
            okm "$a: $deb is byte-identical to the signed pinned snapshot"
        else
            fail "$a: provenance check failed: $(tail -3 "$W/prov-$a.log" | tr '\n' ' ')"; return 1
        fi
    fi
    dpkg-deb -x "$W/debs-$a/$deb" "$W/x-$a" || { fail "$a: cannot extract $deb"; return 1; }
    [ -f "$W/x-$a/usr/bin/busybox" ] || { fail "$a: $deb has no usr/bin/busybox"; return 1; }
    FETCHED_BIN="$W/x-$a/usr/bin/busybox"
    return 0
}

if [ "$MODE" = repin ]; then
    [ -f "$INDEX_DIR/dists/forky/main/binary-amd64/Packages.xz" ] || die "no forky index under $INDEX_DIR"
    SNAP="$(awk -F'\t' '$1=="snapshot"{print $2}' "$ROOT/manifests/forky-snapshot.tsv")"
    [ -n "$SNAP" ] || die "no snapshot in manifests/forky-snapshot.tsv"
    NEWPIN="$(mktemp "${TMPDIR:-$ROOT}/.diag-busybox-pin.XXXXXX")"
    grep '^#' "$PIN" > "$NEWPIN"
    for a in amd64 arm64; do
        if ! printf '%s\n' $ARCHES | grep -qx "$a"; then pin_row "$a" >> "$NEWPIN"; continue; fi
        rec="$(xz -dc "$INDEX_DIR/dists/forky/main/binary-$a/Packages.xz" | python3 -I -c '
import sys
for st in sys.stdin.read().split("\n\n"):
    d = dict(l.split(": ", 1) for l in st.splitlines() if ": " in l and not l.startswith(" "))
    if d.get("Package") == "busybox-static":
        print(d["Version"], d["SHA256"], d["Size"]); break
')"
        [ -n "$rec" ] || { fail "$a: busybox-static not in the forky index"; continue; }
        read -r ver dsha dsz <<< "$rec"
        dest="assets/diag/busybox-$a"
        fetch_one "$a" "$ver" "$dsha" "$dsz" "$SNAP" "$dest" || continue
        install -m 0755 "$FETCHED_BIN" "$ROOT/$dest"
        printf '%s\tbusybox-static\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$ver" "$dsha" "$dsz" "$SNAP" "$dest" \
            "$(sha "$ROOT/$dest")" "$(size "$ROOT/$dest")" >> "$NEWPIN"
        okm "$a: repinned to busybox-static $ver at $SNAP"
    done
    if [ "$BAD" -eq 0 ]; then mv "$NEWPIN" "$PIN"; else rm -f "$NEWPIN"; fi
    MODE=check
fi

for a in $ARCHES; do
    row="$(pin_row "$a")"
    [ -n "$row" ] || { fail "$a: no row in ${PIN#"$ROOT"/}"; continue; }
    IFS=$'\t' read -r _arch pkg ver dsha dsz snap dest bsha bsz <<< "$row"
    [ "$pkg" = busybox-static ] || fail "$a: pinned package is $pkg, want busybox-static"
    if [ "$MODE" = fetch ]; then
        fetch_one "$a" "$ver" "$dsha" "$dsz" "$snap" "$dest" || continue
        check_binary "$a" "$FETCHED_BIN" "$bsha" "$bsz" "$ver"
        [ "$BAD" -eq 0 ] && install -m 0755 "$FETCHED_BIN" "$ROOT/$dest" && okm "$a: installed $dest"
    fi
    check_binary "$a" "$ROOT/$dest" "$bsha" "$bsz" "$ver"
done

FS="$(awk -F'\t' '$1=="snapshot"{print $2}' "$ROOT/manifests/forky-snapshot.tsv" 2>/dev/null)"
for a in $ARCHES; do
    snap="$(pin_row "$a" | cut -f6)"
    [ -z "$FS" ] || [ "$snap" = "$FS" ] || echo "NOTE  $a: pinned at snapshot $snap; the build snapshot is $FS (refresh with --repin)"
done

if [ "$BAD" -gt 0 ]; then echo "stage-diag-busybox: FAIL ($BAD)"; exit 1; fi
echo "stage-diag-busybox: OK"
