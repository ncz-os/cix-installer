#!/bin/bash
# test-ncz-cli-models-catalog.sh -- pinned catalog pulls by name (NG-NC-30).
#
# `ncz models` could only pull one hard-coded GGUF (nomic-embed-text-v1.5
# Q8_0). The catalog adds pinned pulls by name:
#   - `ncz models pull` (no name) keeps today's behaviour (default GGUF)
#   - `ncz models pull <name>` reads a catalog.tsv shipped with the CLI
#     (name, url, sha256, size, licence) and reuses the pinned-hash /
#     retry / idempotency path
#   - unknown names list the catalog and exit non-zero
#
# Fixtures are served over file:// (no network needed). The CLI honours
# NCZ_MODELS_DIR and NCZ_MODELS_CATALOG env overrides so the test runs
# unprivileged in a temp dir.
#
# Runs on Linux and macOS hosts.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/post-install/46-ncz-cli.sh"
CATALOG="$ROOT/assets/models/catalog.tsv"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

T="$(mktemp -d "${TMPDIR:-/var/tmp}/ncz-models-catalog-test.XXXXXX")"; trap 'rm -rf "$T"' EXIT

# --- extract the embedded ncz CLI (same technique as test-ncz-cli-basics.sh)
start_line=$(grep -n "^install -D -m 0755 /dev/stdin /usr/local/bin/ncz <<'NCZ'$" "$HOOK" | head -1 | cut -d: -f1)
end_line=$(grep -n '^NCZ$' "$HOOK" | head -1 | cut -d: -f1)
if [ -z "$start_line" ] || [ -z "$end_line" ]; then
    bad "could not locate the embedded ncz heredoc (start=$start_line end=$end_line)"
    echo "--- $pass passed, $fail failed"; exit 1
fi
sed -n "$((start_line + 1)),$((end_line - 1))p" "$HOOK" | grep -v '^NCZ$' > "$T/ncz-body"
{
    printf '#!/bin/bash\n'
    printf "exec bash -s -- \"\$@\" <<'__NCZ_BODY__'\n"
    cat "$T/ncz-body"
    printf "__NCZ_BODY__\n"
} > "$T/ncz"
chmod +x "$T/ncz"
bash -n "$T/ncz" 2>"$T/ncz-syntax" \
    && ok "extracted ncz CLI parses (bash -n)" \
    || { bad "extracted ncz CLI has syntax errors"; cat "$T/ncz-syntax"; }

# --- repo catalog file ----------------------------------------------------
[ -f "$CATALOG" ] \
    && ok "assets/models/catalog.tsv is shipped" \
    || { bad "assets/models/catalog.tsv missing"; echo "--- $pass passed, $fail failed"; exit 1; }

nrows=$(grep -vc '^#' "$CATALOG" || true)
[ "$nrows" -ge 3 ] \
    && ok "catalog lists >= 3 models ($nrows rows)" \
    || bad "catalog has only $nrows model rows (want >= 3)"
badrow=0
while IFS= read -r line; do
    case "$line" in ''|\#*) continue;; esac
    nfields=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
    [ "$nfields" = "5" ] || { badrow=1; bad "catalog row does not have 5 tab fields: $line"; break; }
    sha=$(printf '%s' "$line" | cut -f3)
    case "$sha" in
        *[!0-9a-f]*|?????????????????????????????????????????????????????????????) : ;;
        *)
            if [ "${#sha}" != "64" ]; then
                badrow=1; bad "catalog row sha256 is not 64 hex chars: $line"; break
            fi
            ;;
    esac
    url=$(printf '%s' "$line" | cut -f2)
    case "$url" in http://*|https://*|file://*) : ;; *) badrow=1; bad "catalog row url is not http(s)/file: $line"; break;; esac
done < "$CATALOG"
[ "$badrow" = "0" ] && ok "every catalog row is name/url/sha256/size/licence with a valid sha256"

# The catalog's default entry must match the hash the hook has always pinned
# (the file baked into the mnemos-enterprise image).
grep -q "sha256='3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7'" "$HOOK" \
    && ok "hook still pins the default nomic sha256" \
    || bad "hook no longer pins the default nomic sha256"
grep -q '3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7' "$CATALOG" \
    && ok "catalog carries the same default nomic sha256" \
    || bad "catalog default nomic sha256 diverges from the hook pin"

# The hook must stage the catalog onto the installed system.
grep -q 'catalog.tsv' "$HOOK" \
    && ok "hook references catalog.tsv (staging)" \
    || bad "hook does not stage catalog.tsv"

# --- fixture library over file:// -----------------------------------------
export NCZ_MODELS_DIR="$T/models"
mkdir -p "$NCZ_MODELS_DIR"
printf 'fixture-gguf-bytes-0123456789' > "$T/fixture.gguf"
printf 'tampered-bytes-xxxxxxxxxxxxxxxx' > "$T/tampered.gguf"
fsha=$(sha256sum "$T/fixture.gguf" | awk '{print $1}')
fsize=$(wc -c < "$T/fixture.gguf")
printf 'fixture.gguf\tfile://%s\t%s\t%s\tMIT\n' "$T/fixture.gguf" "$fsha" "$fsize" > "$T/catalog.tsv"
printf 'tampered.gguf\tfile://%s\t%s\t%s\tMIT\n' \
    "$T/tampered.gguf" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "$fsize" >> "$T/catalog.tsv"
export NCZ_MODELS_CATALOG="$T/catalog.tsv"

# Fixtures for the user-supplied-model path (`ncz models add`, NG-NC-36).
printf 'user-supplied-model-bytes-0123456789' > "$T/user.gguf"
printf 'other-model-bytes-0987654321' > "$T/other.gguf"
user_sha=$(sha256sum "$T/user.gguf" | awk '{print $1}')
other_sha=$(sha256sum "$T/other.gguf" | awk '{print $1}')
# A wrong-but-well-formed pin for the user model (64 hex chars, not its hash).
wrong_sha=$(printf '%s' "$other_sha" | tr '0-9a-f' '1-9a-f0')

# --- pull by name installs a sha256-verified file --------------------------
out=$("$T/ncz" models pull fixture.gguf 2>&1); rc=$?
[ "$rc" = "0" ] \
    && ok "models pull <name> exits 0 (rc=$rc)" \
    || bad "models pull <name> exit=$rc (expected 0): $out"
[ -f "$NCZ_MODELS_DIR/fixture.gguf" ] \
    && ok "catalog pull installs \$NCZ_MODELS_DIR/fixture.gguf" \
    || bad "catalog pull did not install \$NCZ_MODELS_DIR/fixture.gguf"
have=$(sha256sum "$NCZ_MODELS_DIR/fixture.gguf" 2>/dev/null | awk '{print $1}')
[ "$have" = "$fsha" ] \
    && ok "installed file sha256 matches the catalog pin" \
    || bad "installed file sha256 mismatch (have=$have want=$fsha)"
echo "$out" | grep -q "sha256 verified" \
    && ok "catalog pull reports sha256 verification" \
    || bad "catalog pull did not report sha256 verification: $out"

# --- idempotency: second pull skips when the hash matches -------------------
out=$("$T/ncz" models pull fixture.gguf 2>&1); rc=$?
[ "$rc" = "0" ] \
    && ok "second pull <name> exits 0 (rc=$rc)" \
    || bad "second pull <name> exit=$rc (expected 0): $out"
echo "$out" | grep -q "already present, sha256 matches" \
    && ok "second pull <name> is idempotent (skips on matching hash)" \
    || bad "second pull <name> was not idempotent: $out"

# --- sha256 mismatch refuses to install ------------------------------------
out=$("$T/ncz" models pull tampered.gguf 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "pull with wrong pin exits non-zero (rc=$rc)" \
    || bad "pull with wrong pin exit=$rc (expected non-zero)"
[ ! -f "$NCZ_MODELS_DIR/tampered.gguf" ] \
    && ok "mismatched download is refused (not installed)" \
    || bad "mismatched download was installed despite sha256 mismatch"
echo "$out" | grep -qi "mismatch" \
    && ok "mismatch prints a sha256 diagnostic" \
    || bad "mismatch printed no sha256 diagnostic: $out"

# --- unknown names list the catalog ----------------------------------------
out=$("$T/ncz" models pull no-such-model 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "pull <unknown> exits non-zero (rc=$rc)" \
    || bad "pull <unknown> exit=$rc (expected non-zero)"
echo "$out" | grep -q "no-such-model" \
    && ok "unknown-name error names the bad model" \
    || bad "unknown-name error did not name the model: $out"
echo "$out" | grep -q "fixture.gguf" \
    && ok "unknown-name error lists the catalog" \
    || bad "unknown-name error did not list the catalog: $out"

# --- catalog path, URL and checksum checks ---------
DOT=$(printf '\x2e')
DD="$DOT$DOT"
printf '%s\n' "${DD}/evil.gguf"$'\t'"file:///etc/passwd"$'\t'"3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7"$'\t'"1"$'\t'"MIT" >> "$T/catalog.tsv"
printf '%s\n' "badurl.gguf"$'\t'"ftp://example.com/x"$'\t'"3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7"$'\t'"1"$'\t'"MIT" >> "$T/catalog.tsv"
printf '%s\n' "badsha.gguf"$'\t'"file://$T/fixture.gguf"$'\t'"ZZZ"$'\t'"1"$'\t'"MIT" >> "$T/catalog.tsv"
out=$("$T/ncz" models pull "${DD}/evil.gguf" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "path outside the models directory is refused (rc=$rc)" \
    || bad "path outside the models directory exit=$rc (expected non-zero)"
echo "$out" | grep -qi "unsafe filename" \
    && ok "diagnostic identifies the filename" \
    || bad "missing filename diagnostic: $out"
[ ! -e "$T/evil.gguf" ] \
    && ok "no file was written outside the models directory" \
    || bad "a file was written outside the models directory"
out=$("$T/ncz" models pull badurl.gguf 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "non-http(s)/file catalog URL exits non-zero (rc=$rc)" \
    || bad "non-http(s)/file catalog URL exit=$rc (expected non-zero)"
echo "$out" | grep -qi "unsafe URL" \
    && ok "bad-URL refusal names the unsafe URL" \
    || bad "bad-URL refusal gave no unsafe-URL diagnostic: $out"
out=$("$T/ncz" models pull badsha.gguf 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "malformed catalog pin exits non-zero (rc=$rc)" \
    || bad "malformed catalog pin exit=$rc (expected non-zero)"
echo "$out" | grep -qi "sha256 pin" \
    && ok "bad-pin refusal names the sha256 pin" \
    || bad "bad-pin refusal gave no sha256 diagnostic: $out"

# --- no-name pull keeps today's behaviour (static: must not hit network) ----
grep -q "nomic-embed-text-v1.5.Q8_0.gguf" "$HOOK" \
    && ok "no-name pull still targets the default nomic GGUF" \
    || bad "no-name pull no longer targets the default nomic GGUF"
grep -q 'attempt in 1 2 3' "$HOOK" \
    && ok "pull path still retries 3 times" \
    || bad "pull path lost its 3 retries"
grep -q 'this system is offline' "$HOOK" \
    && ok "pull path still prints the offline diagnostic" \
    || bad "pull path lost the offline diagnostic"

# =====================================================================
# NG-NC-36: `ncz models add <url> --sha256 <hex>` for user-supplied
# models that are NOT in the catalog.
#
# `ncz models pull <name>` (NG-NC-30) can only reach rows in the
# shipped catalog.tsv. A user with their own artifact had no supported
# path. Manually copying the file into the models directory leaves it
# unchecked. The catalog is maintained by the project.
#
# The supported path pins the SAME verification the catalog pull does:
#   - `add` REQUIRES --sha256; without it, nothing is installed
#   - the download goes through the shared fetch helper (pinned-hash
#     verify, 3 retries, offline diagnostic, idempotency)
#   - the installed file carries the same META-INF provenance pull
#     writes, so `ncz models list` can surface where it came from
#   - a file already present with a DIFFERENT hash is refused, never
#     silently overwritten
#
# Fixtures are served over file:// (no network needed).
# =====================================================================

# --- add requires --sha256 ----------------------------------------------
out=$("$T/ncz" models add "file://$T/user.gguf" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "models add without --sha256 exits non-zero (rc=$rc)" \
    || bad "models add without --sha256 exit=$rc (expected non-zero)"
echo "$out" | grep -qi "sha256" \
    && ok "missing --sha256 diagnostic names sha256" \
    || bad "missing --sha256 diagnostic does not mention sha256: $out"
[ ! -f "$NCZ_MODELS_DIR/user.gguf" ] \
    && ok "models add without --sha256 installs nothing" \
    || bad "models add without --sha256 installed a file anyway"

# --- add installs a sha256-verified user model ----------------------------
out=$("$T/ncz" models add "file://$T/user.gguf" --sha256 "$user_sha" 2>&1); rc=$?
[ "$rc" = "0" ] \
    && ok "models add <url> --sha256 exits 0 (rc=$rc)" \
    || bad "models add <url> --sha256 exit=$rc (expected 0): $out"
[ -f "$NCZ_MODELS_DIR/user.gguf" ] \
    && ok "models add installs \$NCZ_MODELS_DIR/user.gguf" \
    || bad "models add did not install \$NCZ_MODELS_DIR/user.gguf: $out"
have=$(sha256sum "$NCZ_MODELS_DIR/user.gguf" 2>/dev/null | awk '{print $1}')
[ "$have" = "$user_sha" ] \
    && ok "added file sha256 matches the supplied pin" \
    || bad "added file sha256 mismatch (have=$have want=$user_sha)"
echo "$out" | grep -q "sha256 verified" \
    && ok "models add reports sha256 verification" \
    || bad "models add did not report sha256 verification: $out"

# --- the added model is visible to `ncz models list` ----------------------
out=$("$T/ncz" models list 2>&1); rc=$?
[ "$rc" = "0" ] \
    && ok "models list exits 0 after an add (rc=$rc)" \
    || bad "models list exit=$rc (expected 0): $out"
echo "$out" | grep -q "user.gguf" \
    && ok "models list shows the added model" \
    || bad "models list does not show the added model: $out"
echo "$out" | grep -q "file://$T/user.gguf" \
    && ok "models list surfaces the model's provenance source" \
    || bad "models list does not surface the provenance source: $out"

# --- the added model carries the same META-INF provenance pull writes -----
meta="$NCZ_MODELS_DIR/META-INF/user.gguf.provenance"
[ -f "$meta" ] \
    && ok "models add writes the META-INF provenance sidecar" \
    || bad "models add wrote no META-INF provenance sidecar (want $meta)"
if [ -f "$meta" ]; then
    grep -q "$user_sha" "$meta" \
        && ok "provenance records the verified sha256" \
        || bad "provenance does not record the sha256: $(cat "$meta")"
    grep -q "file://$T/user.gguf" "$meta" \
        && ok "provenance records the source URL" \
        || bad "provenance does not record the source URL: $(cat "$meta")"
fi

# --- idempotency: a second add of the same hash skips -------------------
out=$("$T/ncz" models add "file://$T/user.gguf" --sha256 "$user_sha" 2>&1); rc=$?
[ "$rc" = "0" ] \
    && ok "second models add exits 0 (rc=$rc)" \
    || bad "second models add exit=$rc (expected 0): $out"
echo "$out" | grep -q "already present, sha256 matches" \
    && ok "second models add is idempotent (skips on matching hash)" \
    || bad "second models add was not idempotent: $out"

# --- a different hash for an existing file is refused ---------------------
# Plant a file under the name the add would use, holding DIFFERENT content
# than the pin the operator supplies. The add must refuse to overwrite it.
printf 'pre-existing-different-content' > "$NCZ_MODELS_DIR/other.gguf"
pre_sha=$(sha256sum "$NCZ_MODELS_DIR/other.gguf" | awk '{print $1}')
out=$("$T/ncz" models add "file://$T/other.gguf" --sha256 "$wrong_sha" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "models add refusing to overwrite a different-hash file exits non-zero (rc=$rc)" \
    || bad "models add overwrote a different-hash file (exit=$rc)"
now_sha=$(sha256sum "$NCZ_MODELS_DIR/other.gguf" 2>/dev/null | awk '{print $1}')
[ "$now_sha" = "$pre_sha" ] \
    && ok "the different-hash file was left untouched" \
    || bad "the different-hash file was overwritten (have=$now_sha want=$pre_sha)"

# --- a mismatching pin is refused and installs nothing -------------------
out=$("$T/ncz" models add "file://$T/other.gguf" --sha256 "$wrong_sha" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "models add with a wrong pin exits non-zero (rc=$rc)" \
    || bad "models add with a wrong pin exit=$rc (expected non-zero)"
echo "$out" | grep -qi "mismatch" \
    && ok "wrong-pin refusal prints a sha256 diagnostic" \
    || bad "wrong-pin refusal printed no sha256 diagnostic: $out"

# --- a malformed pin is refused -------------------------------------------
out=$("$T/ncz" models add "file://$T/other.gguf" --sha256 "not-a-hash" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "models add with a malformed pin exits non-zero (rc=$rc)" \
    || bad "models add with a malformed pin exit=$rc (expected non-zero)"

# --- an unsafe destination filename is refused ---------------------------
# The install name comes from the URL basename. Refuse paths outside
# the models directory.
DOT=$(printf '\x2e')
DD="$DOT$DOT"
out=$("$T/ncz" models add "file://$T/$DD/evil.gguf" --sha256 "$user_sha" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "models add with an unsafe basename exits non-zero (rc=$rc)" \
    || bad "models add with an unsafe basename exit=$rc (expected non-zero)"
[ ! -e "$T/evil.gguf" ] \
    && ok "models add stayed inside the models directory" \
    || bad "models add wrote outside the models directory"

# --- the URL is required --------------------------------------------------
out=$("$T/ncz" models add --sha256 "$user_sha" 2>&1); rc=$?
[ "$rc" != "0" ] \
    && ok "models add without a URL exits non-zero (rc=$rc)" \
    || bad "models add without a URL exit=$rc (expected non-zero)"

# --- the help text documents the new subcommand -------------------------
out=$("$T/ncz" models help 2>&1); rc=$?
[ "$rc" = "0" ] \
    && ok "models help exits 0 (rc=$rc)" \
    || bad "models help exit=$rc (expected 0)"
echo "$out" | grep -q "add <url>" \
    && ok "models help documents 'add <url>'" \
    || bad "models help does not document 'add <url>': $out"
echo "$out" | grep -q -- "--sha256" \
    && ok "models help documents the required --sha256 flag" \
    || bad "models help does not document --sha256: $out"

echo "--- $pass passed, $fail failed"
[ "$fail" = "0" ]
