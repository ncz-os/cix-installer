#!/bin/bash
# test-build-inputs-public.sh -- build/stage-build-inputs.sh --public and
# manifests/build-inputs-public.tsv (offline: file:// URLs, no network).
#
#  * a public row is downloaded, sha256-checked against the pin and staged
#  * a tar member row extracts just that member (the uv binary case)
#  * a download whose bytes differ from the pin is refused, nothing staged
#  * a public row whose sha256 drifted from the pin is refused
#  * a row with no public source is reported INTERNAL-ONLY and fails the run
#  * --public never reads a store, even when NCZ_BUILD_INPUTS_DIR is set
#  * the real manifest: every public row matches a build-inputs.tsv pin exactly,
#    uses https, and names no internal host
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGER="$ROOT/build/stage-build-inputs.sh"
T="$(mktemp -d "${TMPDIR:-/var/tmp}/bip.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
sha() { sha256sum "$1" | awk '{print $1}'; }

mkdir -p "$T/pub/uv-x" "$T/store/amd64/assets/mgmt"
head -c 3000 /dev/urandom > "$T/pub/python.tar.gz"
head -c 2000 /dev/urandom > "$T/pub/uv-x/uv"; chmod 755 "$T/pub/uv-x/uv"
tar -C "$T/pub" -czf "$T/pub/uv.tar.gz" uv-x/uv
head -c 1000 /dev/urandom > "$T/pub/internal.bin"
cp "$T/pub/internal.bin" "$T/store/amd64/assets/mgmt/rootfs.tar.zst"
PY=$(sha "$T/pub/python.tar.gz"); UV=$(sha "$T/pub/uv-x/uv"); IN=$(sha "$T/pub/internal.bin")
printf "# pins\namd64\tassets/python311/python.tar.gz\t%s\t3000\tpy\namd64\tassets/python311/uv\t%s\t2000\tuv\n" "$PY" "$UV" > "$T/pins.tsv"
printf "# public\namd64\tassets/python311/python.tar.gz\t%s\tfile://%s/pub/python.tar.gz\t-\tpy\namd64\tassets/python311/uv\t%s\tfile://%s/pub/uv.tar.gz\tuv-x/uv\tuv\n" "$PY" "$T" "$UV" "$T" > "$T/public.tsv"
run() { NCZ_BUILD_INPUTS_TSV="$T/pins.tsv" NCZ_BUILD_INPUTS_PUBLIC_TSV="$T/public.tsv" NCZ_BUILD_INPUTS_TREE="$1" XDG_CONFIG_HOME="$T/xdg" bash "$STAGER" --arch amd64 "${@:2}"; }

# 1. all rows public: staged, verified, uv executable
run "$T/t1" --public >"$T/o1" 2>&1; rc=$?
if [ $rc = 0 ] && cmp -s "$T/pub/python.tar.gz" "$T/t1/assets/python311/python.tar.gz" && cmp -s "$T/pub/uv-x/uv" "$T/t1/assets/python311/uv" \
   && [ -x "$T/t1/assets/python311/uv" ] && grep -q "fetched assets/python311/uv from its public source" "$T/o1"; then ok "--public stages a plain download and a tar member, sha256-verified"
else bad "--public happy path (rc=$rc)"; cat "$T/o1"; fi

# 2. re-run is a no-op
run "$T/t1" --public >"$T/o2" 2>&1; rc=$?
[ $rc = 0 ] && grep -q "2 already staged, 0 copied" "$T/o2" && ok "--public re-run is a no-op" || { bad "--public re-run (rc=$rc)"; cat "$T/o2"; }

# 3. tampered public download is refused and nothing is staged
echo x >> "$T/pub/python.tar.gz"
run "$T/t3" --public >"$T/o3" 2>&1; rc=$?
if [ $rc != 0 ] && grep -q "refusing" "$T/o3" && [ ! -e "$T/t3/assets/python311/python.tar.gz" ] && [ ! -e "$T/t3/assets/python311/python.tar.gz.part" ]; then ok "a public download that does not match the pin is refused"
else bad "tampered public download accepted (rc=$rc)"; cat "$T/o3"; fi

# 4. a public row whose sha256 drifted from the pin is refused before download
sed -i "s/$UV/$(printf %064d 0)/" "$T/public.tsv"
run "$T/t4" --public --only assets/python311/uv >"$T/o4" 2>&1; rc=$?
[ $rc != 0 ] && grep -q "stale build-inputs-public.tsv row" "$T/o4" && ok "a drifted public-source sha256 is refused" || { bad "drifted public row (rc=$rc)"; cat "$T/o4"; }

# 5. internal-only row: reported by name, run fails, store ignored under --public
printf "amd64\tassets/mgmt/rootfs.tar.zst\t%s\t1000\trecovery rootfs\n" "$IN" >> "$T/pins.tsv"
NCZ_BUILD_INPUTS_DIR="$T/store" run "$T/t5" --public --only assets/mgmt >"$T/o5" 2>&1; rc=$?
if [ $rc != 0 ] && grep -q "INTERNAL-ONLY: assets/mgmt/rootfs.tar.zst" "$T/o5" && grep -q "internal-only and cannot be fetched publicly" "$T/o5" \
   && [ ! -e "$T/t5/assets/mgmt/rootfs.tar.zst" ]; then ok "an input with no public source is reported INTERNAL-ONLY and the store is not read"
else bad "internal-only row (rc=$rc)"; cat "$T/o5"; fi

# 6. the per-host store file is honoured when NCZ_BUILD_INPUTS_DIR is unset (non-public mode)
mkdir -p "$T/xdg/ncz"; echo "$T/store" > "$T/xdg/ncz/build-inputs-dir"
run "$T/t6" --only assets/mgmt >"$T/o6" 2>&1; rc=$?
[ $rc = 0 ] && cmp -s "$T/pub/internal.bin" "$T/t6/assets/mgmt/rootfs.tar.zst" && ok "the store is found through \$XDG_CONFIG_HOME/ncz/build-inputs-dir" || { bad "per-host store file (rc=$rc)"; cat "$T/o6"; }

# --- the real manifests ------------------------------------------------------------------------
PUB="$ROOT/manifests/build-inputs-public.tsv"; PINS="$ROOT/manifests/build-inputs.tsv"
if [ -f "$PUB" ]; then ok "manifests/build-inputs-public.tsv exists"; else bad "manifests/build-inputs-public.tsv missing"; fi
n=0; while IFS=$'\t' read -r a d s u m note; do
    case "$a" in ""|"#"*) continue ;; esac; n=$((n + 1))
    awk -F'\t' -v a="$a" -v d="$d" -v s="$s" '$1==a && $2==d && $3==s {f=1} END{exit !f}' "$PINS" || bad "public row $a $d does not match a build-inputs.tsv pin"
    case "$u" in https://*) ;; *) bad "public row $a $d is not https: $u" ;; esac
    [ -n "$m" ] || bad "public row $a $d has an empty member column (use -)"
done < "$PUB"
[ "$n" -gt 0 ] && ok "every public row ($n) matches a pin and uses https" || bad "no public rows"
if grep -Eiq "192\\.168\\.|/mnt/|argonas" "$PUB" "$STAGER"; then bad "an internal host or path appears in the public manifest or the stager"; else ok "no internal host or path in the public manifest or the stager"; fi

echo "test-build-inputs-public: $pass passed, $fail failed"
[ "$fail" = 0 ]
