#!/bin/bash
# test-singularity-pins.sh -- offline tests for the Singularity upstream pins
# (assets/singularity/upstream-pins.tsv, build/singularity-pins.sh) and their
# wiring into build-singularity.sh, preflight-freshness-gate.sh and
# singularity-patch-reconcile.py.
#
# The regression this guards (2026-10-06): the payload build re-pinned every
# submodule to its branch head, upstream pushed libsingularity f3d0f49, and
# the respin's stage 1 died on "ncz patch does not apply". The fixture below
# reproduces that exact shape with local repositories -- a patch that applies
# to the pinned commit, and an upstream head that no longer takes it -- so
# nothing here touches the network.
#
# Run: bash build/test-singularity-pins.sh   (exit 0 = all pass)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINS_SH="$ROOT/build/singularity-pins.sh"
PASS=0; FAIL=0
ok()  { echo "  ok   $*"; PASS=$((PASS + 1)); }
nok() { echo "  FAIL $*"; FAIL=$((FAIL + 1)); }

[ -r "$PINS_SH" ] || { echo "FAIL: $PINS_SH is missing -- the Singularity payload has no upstream pins"; exit 1; }

T="$(mktemp -d "${TMPDIR:-/tmp}/ncz-pins-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
       GIT_CONFIG_KEY_1=init.defaultBranch GIT_CONFIG_VALUE_1=main
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export NCZ_SINGULARITY_PIN_CACHE="$T/cache" NCZ_SINGULARITY_GIT_TIMEOUT=30
q() { "$@" >/dev/null 2>&1; }

echo "== committed pin file =="
out="$(bash "$PINS_SH" validate 2>&1)" && ok "validate: $out" || nok "validate on the committed pin file: $out"
for p in . subprojects/libsingularity subprojects/singularity-shell vetro singularity-boot-splash; do
    s="$(bash "$PINS_SH" sha "$p" 2>/dev/null)"
    grep -qE '^[0-9a-f]{40}$' <<<"$s" && ok "pinned: $p @ ${s:0:12}" || nok "no 40-hex pin for $p"
done

echo "== wiring (fails on a tree that still builds from branch heads) =="
B="$ROOT/build/build-singularity.sh"
grep -q 'singularity-pins.sh checkout-tree singularity-desktop' "$B" && ok "build-singularity: submodules checked out at their pins" || nok "build-singularity does not call checkout-tree"
grep -q 'singularity-pins.sh clone \. singularity-desktop' "$B" && ok "build-singularity: superproject cloned at its pin" || nok "superproject not cloned at its pin"
grep -q 'singularity-pins.sh clone vetro vetro' "$B" && ok "build-singularity: vetro pinned" || nok "vetro not pinned"
grep -q 'singularity-pins.sh clone singularity-boot-splash singularity-boot-splash' "$B" && ok "build-singularity: boot splash pinned" || nok "boot splash not pinned"
grep -q 'SINGULARITY_SOURCE_DIR:-}" \] && \[ "\$NCZ_SINGULARITY_TRACK_HEAD" = 1 \]' "$B" \
    && ok "build-singularity: branch-head re-pin only under NCZ_SINGULARITY_TRACK_HEAD=1" || nok "branch-head re-pin is still the default"
grep -q 'singularity-opt.tgz.sources' "$B" && ok "build-singularity: writes the upstream provenance sidecar" || nok "no provenance sidecar"
G="$ROOT/build/preflight-freshness-gate.sh"
grep -q 'singularity-pins.sh" check-patches' "$G" && ok "preflight [2]: patches checked against the pins" || nok "preflight [2] does not check the pins"
grep -q 'against real current upstream default branch' "$G" && nok "preflight [2] still applies patches to the upstream default branch" || ok "preflight [2]: no default-branch apply left"
grep -q 'def pin_contains' "$ROOT/build/singularity-patch-reconcile.py" && ok "reconcile: retires a merged patch only once the pin contains the merge" || nok "reconcile can retire a patch the pinned build still needs"

echo "== build-singularity.sh refuses before any container =="
# Stub container engines: if a regression let the script reach "docker run",
# the stub fails at once instead of starting a real payload build.
mkdir -p "$T/bin"
for ce in docker podman; do printf '#!/bin/sh\necho "STUB $0 $*" >&2\nexit 97\n' > "$T/bin/$ce"; chmod +x "$T/bin/$ce"; done
out="$(PATH="$T/bin:$PATH" OUT="$T/sinty-out" NCZ_SINGULARITY_PINS="$T/absent.tsv" bash "$B" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'pin file not found' <<<"$out" \
    && ok "missing pin file -> exit $rc: $(grep -m1 'pin file not found' <<<"$out")" || nok "missing pin file not refused (rc=$rc): $out"
out="$(PATH="$T/bin:$PATH" OUT="$T/sinty-out" SINGULARITY_REF=master bash "$B" 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'not honoured in a pinned build' <<<"$out" \
    && ok "SINGULARITY_REF in a pinned build -> refused" || nok "SINGULARITY_REF silently honoured (rc=$rc)"

echo "== fixture: upstream repositories =="
U="$T/up"; mkdir -p "$U"
mkrepo() { git init -q "$U/$1" && printf '%s\n' "${@:2}" > "$U/$1/file.txt" && git -C "$U/$1" add -A && git -C "$U/$1" commit -qm init; }
mkrepo lib "a {" "  color: red;" "}" "b {" "  color: blue;" "}"
mkrepo loginui "splash 16%" "bar 220"
mkrepo vetro "vetro"
mkrepo shell "shell"
LIB1="$(git -C "$U/lib" rev-parse HEAD)"
LOG1="$(git -C "$U/loginui" rev-parse HEAD)"
git init -q "$U/boot-splash" && echo bs > "$U/boot-splash/f" && git -C "$U/boot-splash" add -A
q git -C "$U/boot-splash" submodule add "file://$U/loginui" subprojects/singularity-loginui
git -C "$U/boot-splash" commit -qm init
git init -q "$U/sd" && echo sd > "$U/sd/f" && git -C "$U/sd" add -A
q git -C "$U/sd" submodule add -b main "file://$U/lib" subprojects/lib
q git -C "$U/sd" submodule add -b main "file://$U/shell" subprojects/shell
q git -C "$U/sd" submodule add "file://$U/loginui" subprojects/singularity-loginui
git -C "$U/sd" commit -qm init
SD1="$(git -C "$U/sd" rev-parse HEAD)"
SH1="$(git -C "$U/shell" rev-parse HEAD)"
BS1="$(git -C "$U/boot-splash" rev-parse HEAD)"
VE1="$(git -C "$U/vetro" rev-parse HEAD)"
# Upstream moves on AFTER the pin: the f3d0f49 shape -- the lines our patch
# touches are rewritten on the branch head.
sed -i.bak 's/color: red;/color: var(--accent);/' "$U/lib/file.txt" && rm -f "$U/lib/file.txt.bak"
git -C "$U/lib" commit -qam "upstream feature drop"
LIB2="$(git -C "$U/lib" rev-parse HEAD)"

P="$T/patches"; mkdir -p "$P/lib" "$P/singularity-loginui"
( cd "$T" && rm -rf w && git clone -q "$U/lib" w && git -C w checkout -q "$LIB1" \
  && sed -i.bak 's/color: red;/color: red;\n  border: 1px solid;/' w/file.txt && rm -f w/file.txt.bak \
  && git -C w diff > "$P/lib/0001-outline.patch" && rm -rf w )
( cd "$T" && rm -rf w && git clone -q "$U/loginui" w \
  && sed -i.bak 's/splash 16%/splash fit/' w/file.txt && rm -f w/file.txt.bak \
  && git -C w diff > "$P/singularity-loginui/0001-fit.patch" && rm -rf w )
[ -s "$P/lib/0001-outline.patch" ] && [ -s "$P/singularity-loginui/0001-fit.patch" ] || { echo "fixture patch generation failed"; exit 1; }

writepins() {  # writepins <lib-sha> [extra rows...]
    {
        echo "# fixture"
        printf '.\tfile://%s\tmain\t%s\n' "$U/sd" "$SD1"
        printf 'subprojects/lib\tfile://%s\tmain\t%s\n' "$U/lib" "$1"
        printf 'subprojects/shell\tfile://%s\tmain\t%s\n' "$U/shell" "$SH1"
        printf 'subprojects/singularity-loginui\tfile://%s\t-\t%s\n' "$U/loginui" "$LOG1"
        printf 'vetro\tfile://%s\tmain\t%s\n' "$U/vetro" "$VE1"
        printf 'singularity-boot-splash\tfile://%s\tmain\t%s\n' "$U/boot-splash" "$BS1"
        shift; for r in "$@"; do printf '%s\n' "$r"; done
    } > "$T/pins.tsv"
}
export NCZ_SINGULARITY_PINS="$T/pins.tsv" NCZ_SINGULARITY_PATCHES="$P"
pins() { bash "$PINS_SH" "$@"; }

echo "== check-patches =="
writepins "$LIB1"
out="$(pins check-patches 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "patches apply to the pinned commit although upstream head moved (rc=0)" || nok "pinned check failed (rc=$rc): $out"
grep -q 'OK: singularity-loginui(boot-splash@' <<<"$out" && ok "loginui queue also checked against the boot splash's bundled copy" || nok "boot splash loginui copy not checked: $out"
( cd "$T" && rm -rf h && git clone -q "$U/lib" h && ! git -C h apply --check "$P/lib/0001-outline.patch" 2>/dev/null ) \
    && ok "control: the same patch does NOT apply to the upstream head (the old build's input)" || nok "fixture does not reproduce the drift"
writepins "$LIB2"
out="$(pins check-patches 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'FAIL: lib/0001-outline.patch does NOT apply' <<<"$out" \
    && ok "pin moved onto the drifted head -> rc=1, patch named" || nok "drifted pin not caught (rc=$rc): $out"
writepins 0123456789abcdef0123456789abcdef01234567
out="$(pins check-patches 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q 'does not exist' <<<"$out" && ok "nonexistent pinned commit -> rc=1" || nok "nonexistent pin not caught (rc=$rc): $out"

echo "== offline =="
writepins "$LIB1"
q pins fetch-cache && ok "fetch-cache mirrored every pinned repo" || nok "fetch-cache failed"
mv "$U" "$T/up.away"
out="$(pins check-patches 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "check-patches works offline from the pin cache" || nok "offline check failed (rc=$rc): $out"
rm -rf "$T/cache"
out="$(pins check-patches 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'WARN: cannot verify' <<<"$out" && ok "offline and uncached -> rc=2 (WARN, not a false OK)" || nok "uncached offline not reported (rc=$rc): $out"
mv "$T/up.away" "$U"

echo "== checkout-tree / clone =="
writepins "$LIB1"
W="$T/work"; mkdir -p "$W"
( cd "$W" && pins clone . sd >/dev/null 2>&1 && pins checkout-tree sd >/dev/null 2>&1 ) && ok "superproject cloned and tree checked out at pins" || nok "pinned checkout failed"
[ "$(git -C "$W/sd/subprojects/lib" rev-parse HEAD 2>/dev/null)" = "$LIB1" ] && ok "submodule at its pin, not its branch head" || nok "submodule not at pin"
out="$(pins provenance "$W/sd" 2>&1)"
grep -qx "subprojects/lib $LIB1" <<<"$out" && ok "provenance records the pinned commit" || nok "provenance wrong: $out"
( cd "$W" && pins clone singularity-boot-splash bs >/dev/null 2>&1 ) && [ -f "$W/bs/subprojects/singularity-loginui/file.txt" ] \
    && ok "boot splash cloned at its pin with its bundled loginui" || nok "boot splash pinned clone failed"
# Upstream adds a submodule; the pin file is not updated.
git init -q "$U/newsub" && echo n > "$U/newsub/f" && git -C "$U/newsub" add -A && git -C "$U/newsub" commit -qm init
q git -C "$U/sd" submodule add -b main "file://$U/newsub" subprojects/singularity-accounts
git -C "$U/sd" commit -qm "add accounts"
SD2="$(git -C "$U/sd" rev-parse HEAD)"
sed "s/$SD1/$SD2/" "$T/pins.tsv" > "$T/pins2.tsv"
rm -rf "$W"; mkdir -p "$W"
out="$(cd "$W" && NCZ_SINGULARITY_PINS="$T/pins2.tsv" bash "$PINS_SH" clone . sd >/dev/null 2>&1 && NCZ_SINGULARITY_PINS="$T/pins2.tsv" bash "$PINS_SH" checkout-tree sd 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q "upstream pin missing: 'subprojects/singularity-accounts'" <<<"$out" \
    && ok "unpinned new submodule -> build fails naming it" || nok "unpinned submodule not refused (rc=$rc): $out"
writepins "$LIB1" "$(printf 'subprojects/gone\tfile:///nowhere\tmain\t%s' "$LIB1")"
rm -rf "$W"; mkdir -p "$W"
out="$(cd "$W" && pins clone . sd >/dev/null 2>&1 && pins checkout-tree sd 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q "pins 'subprojects/gone' but" <<<"$out" && ok "stale pin row -> refused" || nok "stale pin not refused (rc=$rc): $out"
writepins "$LIB1"
sed -i.bak "s/\t-\t$LOG1/\t-\t$LIB1/" "$T/pins.tsv" && rm -f "$T/pins.tsv.bak"
rm -rf "$W"; mkdir -p "$W"
out="$(cd "$W" && pins clone . sd >/dev/null 2>&1 && pins checkout-tree sd 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'gitlink' <<<"$out" && ok "branchless pin disagreeing with the superproject gitlink -> refused" || nok "gitlink mismatch not refused (rc=$rc): $out"

echo "== validate =="
writepins "$LIB1"
mkdir -p "$P/orphan" && echo x > "$P/orphan/0001-x.patch"
out="$(pins validate 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q "patches exist for 'orphan'" <<<"$out" && ok "patch queue without a pin -> refused" || nok "unpinned patch queue accepted (rc=$rc): $out"
rm -rf "$P/orphan"
grep -v '^vetro' "$T/pins.tsv" > "$T/p3" && mv "$T/p3" "$T/pins.tsv"
out="$(pins validate 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q "no upstream pin for 'vetro'" <<<"$out" && ok "missing vetro pin -> refused" || nok "missing vetro pin accepted (rc=$rc)"
printf 'subprojects/x\tfile:///x\tmain\tabc123\n' >> "$T/pins.tsv"
out="$(pins validate 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'not a full 40-hex commit' <<<"$out" && ok "abbreviated sha -> refused" || nok "abbreviated sha accepted (rc=$rc)"

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
