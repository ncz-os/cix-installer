#!/bin/bash
# refresh-google-chrome.sh -- move the pinned Google Chrome to Google's current stable.
#
# Verifies the whole chain before anything is pinned: InRelease signature
# (build/google-chrome-apt-keyring.asc, gpgv) -> the per-arch Packages sha256
# listed in that InRelease -> the deb sha256 listed in Packages. Writes the debs
# to assets/google-chrome/, rewrites the google-chrome-stable rows of
# manifests/vendor-debs.tsv, then publishes them to the build-inputs store
# (build/stage-build-inputs.sh --publish rewrites manifests/build-inputs.tsv).
#
# Usage: build/refresh-google-chrome.sh [--no-publish]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
URL="${GOOGLE_CHROME_URL:-https://dl.google.com/linux/chrome/deb}"
PUBLISH=1; [ "${1:-}" = --no-publish ] && PUBLISH=0
for t in curl gpg gpgv sha256sum dpkg-deb; do command -v "$t" >/dev/null || { echo "ERROR: missing $t" >&2; exit 1; }; done
W="$(mktemp -d "${TMPDIR:-/var/tmp}/chrome-refresh.XXXXXX")"; trap 'rm -rf "$W"' EXIT
gpg --dearmor < "$ROOT/build/google-chrome-apt-keyring.asc" > "$W/key.gpg"
curl -fsSL -m 60 -o "$W/InRelease" "$URL/dists/stable/InRelease"
gpgv --keyring "$W/key.gpg" "$W/InRelease" 2>"$W/gpgv.log" || { cat "$W/gpgv.log" >&2; echo "ERROR: InRelease signature" >&2; exit 1; }
mkdir -p "$ROOT/assets/google-chrome"
for a in amd64 arm64; do
    curl -fsSL -m 60 -o "$W/Packages-$a" "$URL/dists/stable/main/binary-$a/Packages"
    want="$(awk -v p="main/binary-$a/Packages" '/^SHA256:/{s=1;next} /^[A-Za-z]/{s=0} s && $3==p {print $1}' "$W/InRelease")"
    [ "$want" = "$(sha256sum "$W/Packages-$a" | awk '{print $1}')" ] || { echo "ERROR: $a Packages does not match the signed InRelease" >&2; exit 1; }
    entry="$(awk '/^Package: google-chrome-stable$/{f=1} f{print} f&&/^$/{exit}' "$W/Packages-$a")"
    ver="$(printf '%s\n' "$entry" | sed -n 's/^Version: //p')"; file="$(printf '%s\n' "$entry" | sed -n 's/^Filename: //p')"
    sha="$(printf '%s\n' "$entry" | sed -n 's/^SHA256: //p')"
    [ -n "$ver" ] && [ -n "$file" ] && [ -n "$sha" ] || { echo "ERROR: no google-chrome-stable/$a in the signed index" >&2; exit 1; }
    out="$ROOT/assets/google-chrome/google-chrome-stable_${ver}_$a.deb"
    curl -fsSL -m 600 -o "$out.part" "$URL/$file"
    [ "$(sha256sum "$out.part" | awk '{print $1}')" = "$sha" ] || { rm -f "$out.part"; echo "ERROR: $a deb sha256 mismatch" >&2; exit 1; }
    mv -f "$out.part" "$out"
    python3 -I - "$ROOT/manifests/vendor-debs.tsv" "$ROOT/manifests/build-inputs.tsv" "$a" "$ver" "$sha" "$URL/$file" "$(stat -c %s "$out")" <<'PY'
import sys
vf, bf, arch, ver, sha, url, size = sys.argv[1:]
L = open(vf).read().split("\n"); hit = 0
for i, l in enumerate(L):
    p = l.split("\t")
    if len(p) >= 7 and p[0] == "google-chrome-stable" and p[2] == arch:
        p[1], p[4], p[5] = ver, url, sha; L[i] = "\t".join(p); hit += 1
assert hit == 1, f"expected one google-chrome-stable/{arch} row, found {hit}"
open(vf, "w").write("\n".join(L))
# build-inputs: exactly one row per arch for the staged Chrome deb
B = [l for l in open(bf).read().split("\n")
     if not (l.startswith(arch + "\tassets/google-chrome/google-chrome-stable_"))]
while B and B[-1] == "": B.pop()
B.append("\t".join([arch, f"assets/google-chrome/google-chrome-stable_{ver}_{arch}.deb", sha, size,
                    f"Google Chrome stable {ver} (signed chain verified by build/refresh-google-chrome.sh; same bytes as manifests/vendor-debs.tsv)"]))
open(bf, "w").write("\n".join(B) + "\n")
PY
    echo "google-chrome-stable $ver $a $sha (signed chain verified)"
done
if [ "$PUBLISH" = 1 ]; then
    for a in amd64 arm64; do bash "$ROOT/build/stage-build-inputs.sh" --arch "$a" --publish --only assets/google-chrome/; done
fi
echo "next: regenerate manifests/determinism.pin (build/gen-base-pin.sh) and commit vendor-debs.tsv + build-inputs.tsv"
