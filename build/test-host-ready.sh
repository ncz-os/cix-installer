#!/bin/bash
# test-host-ready.sh -- both-direction tests for build/host-ready.sh, the M5
# builder-host readiness gate (docs/BUILD-STABILITY.md, section 4 order item 6).
#
# Every case runs the REAL script against a throwaway fixture host assembled
# under "${TMPDIR:-$HOME}"; nothing reads the real site configuration, so a
# developer machine with an odd /dev/kvm or a dirty checkout cannot make the
# suite lie.  The positive case must pass with zero findings; each negative
# case breaks exactly ONE thing and must fail, naming that check.
#
#   build/test-host-ready.sh      exit 0 all pass, 1 any FAIL

set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
HR="$ROOT/build/host-ready.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1" >&2; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /' >&2; }
expect_rc() {  # label want-rc cmd...
    local label="$1" want="$2" rc=0; shift 2
    LAST="$("$@" 2>&1)" || rc=$?
    if [ "$rc" = "$want" ]; then ok "$label (rc=$rc)"; else bad "$label: rc=$rc, wanted $want" "$LAST"; fi
}

W="$(mktemp -d "${TMPDIR:-$HOME}/ncz-hostready.XXXXXX")"
trap 'rm -rf "$W"' EXIT

if [ ! -f "$HR" ]; then
    echo "FAIL: $HR is missing" >&2
    exit 1
fi

# --- a fixture host: one clone, one healthy environment ---------------------
# The fixture clone is a real git repo with a clean tree, so the dirty-tree
# check reads it exactly as it reads the real clone.
mkhost() {
    local H="$1"
    mkdir -p "$H/clone" "$H/cache" "$H/staging" "$H/run" \
             "$H/clone/build" "$H/clone/manifests" "$H/clone/assets/kernel" \
             "$H/clone/assets/inputs"
    git -C "$H/clone" init -q >/dev/null 2>&1
    git -C "$H/clone" -c user.name=t -c user.email=t@t config user.name t
    git -C "$H/clone" -c user.name=t -c user.email=t@t config user.email t@t
    printf 'fixture\n' > "$H/clone/README"
    git -C "$H/clone" add README >/dev/null 2>&1
    git -C "$H/clone" -c user.name=t -c user.email=t@t commit -qm fixture >/dev/null 2>&1

    # The kernel-staging pool holds the pinned release with the pinned bytes.
    printf 'r292-7.3.0-sky1-ncz-20261023\n' > "$H/clone/assets/kernel/mainline.release"
    local rel; rel="$(tr -d '[:space:]' < "$H/clone/assets/kernel/mainline.release")"
    mkdir -p "$H/staging/$rel"
    local f
    for f in Image-cixmini.bin modules-cixmini.tgz config-7.3.0-sky1-ncz; do
        printf 'fixture bytes for %s\n' "$f" > "$H/staging/$rel/$f"
    done
    _vman "$H" > "$H/clone/assets/kernel-manifest.json"
    # No assets/kernel/mainline symlink: the pool is named explicitly.
    rm -f "$H/clone/assets/kernel/mainline"

    # base.pin: a well-formed row per arch.  amd64's real hash is filled in by
    # _pin_cache, which also names the cached ISO the way
    # build/stage-substrate.sh looks for it.
    {
        printf '# arch\tsubstrate_sha256\n'
        printf 'amd64\t%s\n' "$(printf 'placeholder' | sha256sum | cut -d' ' -f1)"
        printf 'arm64\t%s\n' "$(printf 'arm64-substrate' | sha256sum | cut -d' ' -f1)"
    } > "$H/clone/manifests/base.pin"

    # build-inputs.tsv: one amd64 row whose bytes are staged in the clone.
    printf 'fixture input\n' > "$H/clone/assets/inputs/blob.bin"
    {
        printf '# arch\tdest\tsha256\tsize\tnote\n'
        printf 'amd64\tassets/inputs/blob.bin\t%s\t%s\tfixture\n' \
            "$(sha_of "$H/clone/assets/inputs/blob.bin")" "$(stat -c %s "$H/clone/assets/inputs/blob.bin")"
    } > "$H/clone/manifests/build-inputs.tsv"

    # A no-op stage-build-inputs.sh --check: the real script is exercised by
    # its own suite; here the gate's use of it (arg passing, rc, message) is
    # what is under test.
    cat > "$H/clone/build/stage-build-inputs.sh" <<'EOS'
#!/bin/bash
ARCH=""
while [ "$#" -gt 0 ]; do case "$1" in --arch) ARCH="${2:-}"; shift 2 ;; --check) shift ;; *) shift ;; esac; done
[ -n "$ARCH" ] || { echo "no arch" >&2; exit 2; }
exit 0
EOS
    chmod +x "$H/clone/build/stage-build-inputs.sh"
    # amd64 answers the pool question with assets/kernel/amd64-stable/KVER
    # (check_kernel_staging_amd64), so pin one and stage a matching build.
    mkdir -p "$H/clone/assets/kernel/amd64-stable" "$H/staging/amd64-stable-6.16.1"
    printf '6.16.1\n' > "$H/clone/assets/kernel/amd64-stable/KVER"
    printf '6.16.1\n' > "$H/staging/amd64-stable-6.16.1/KVER"

    # A privilege model that answers "root", so the fixture host is READY.
    # Section 11 replaces this stub with one that answers "none".
    mkdir -p "$H/clone/build/lib"
    cat > "$H/clone/build/lib/priv.sh" <<'EOP'
ncz_priv_model() { printf 'root\n'; return 0; }
EOP

    # An rw file standing in for /dev/kvm, so the fixture host is ready for a
    # run that executes the kvm gate (the default).  Section 12 points --kvm
    # at an absent path instead.
    : > "$H/kvm"
    chmod 0666 "$H/kvm"

    _pin_cache "$H"
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# The pinned ISO is named <name>-<yyyymmdd>-<sha8>.iso, the lookup
# build/stage-substrate.sh uses.
_pin_cache() {
    local H="$1" iso_sha iso
    printf 'fixture netinst substrate\n' > "$H/cache/iso.raw"
    iso_sha="$(sha_of "$H/cache/iso.raw")"
    iso="$H/cache/debian-testing-amd64-netinst-20261026-${iso_sha:0:8}.iso"
    mv "$H/cache/iso.raw" "$iso"
    awk -F'\t' -v s="$iso_sha" '$1=="amd64"{$2=s} {print}' OFS='\t' \
        "$H/clone/manifests/base.pin" > "$H/clone/manifests/base.pin.new"
    mv "$H/clone/manifests/base.pin.new" "$H/clone/manifests/base.pin"
}

# The manifest names, for each pinned file, the sha256 of the fixture bytes.
_vman() {
    local H="$1" rel img mod cfg
    rel="$(tr -d '[:space:]' < "$H/clone/assets/kernel/mainline.release")"
    img="$(sha_of "$H/staging/$rel/Image-cixmini.bin")"
    mod="$(sha_of "$H/staging/$rel/modules-cixmini.tgz")"
    cfg="$(sha_of "$H/staging/$rel/config-7.3.0-sky1-ncz")"
    printf '{"variants":{"mainline":{"image":{"sha256":"%s"},"modules":{"sha256":"%s"},"config":{"sha256":"%s"}}}}\n' \
        "$img" "$mod" "$cfg"
}

# Stub the host tools the gate requires, so the test does not need xorriso,
# mmdebstrap and friends installed; --tools is then given this directory.
mktools() {
    local H="$1" t
    mkdir -p "$H/bin"
    for t in xorriso cpio zstd unsquashfs mmdebstrap; do
        printf '#!/bin/sh\nexit 0\n' > "$H/bin/$t"
        chmod +x "$H/bin/$t"
    done
}

# df -Pk fixture: enough free space for the fixture clone and run dir.
mkdf() {
    local H="$1" kb="${2:-999999999}"
    {
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
        printf '/dev/fixture 999999999 1 %s 1%% %s\n' "$kb" "$H/clone"
    } > "$H/df.txt"
}

# rm -rf fixture: is the scratch on a real disk (not tmpfs)?
mkfs() {
    local H="$1" type="${2:-ext4}"
    : > "$H/fs.txt"
    [ -n "$H_RUN" ] && printf '%s\t%s\n' "$H_RUN" "$type" >> "$H/fs.txt"
    printf '%s\t%s\n' "$H/clone" "$type" >> "$H/fs.txt"
    printf '%s\t%s\n' "$H/clone" "$type" >> "$H/fs.txt"
}

# run host arch [extra args...] -- the gate, against one fixture host.
run() {
    local H="$1" arch="$2"; shift 2
    env -u NCZ_YOCTO_SHARED_DIR -u NCZ_SUBSTRATE_CACHE_DIRS -u NCZ_KERNEL_STAGING_DIR \
        -u NCZ_SUDO_PASS_FILE -u NCZ_IMAGEBUILD_TAG -u TMPDIR \
        HOME="$H/nohome" XDG_CONFIG_HOME="$H/nohome/.config" \
        PATH="$H/bin:$PATH" \
        bash "$HR" --arch "$arch" --root "$H/clone" --run-dir "$H/run" \
            --staging-dir "$H/staging" \
            --substrate-cache "$H/cache" \
            --df-fixture "$H/df.txt" --fs-fixture "$H/fs.txt" \
            --tools "xorriso cpio zstd unsquashfs mmdebstrap" \
            --kvm "$H/kvm" \
            --no-container \
            "$@" 2>&1
}

fails_of() { printf '%s\n' "$1" | grep '^\[host-ready\] FAIL' | awk '{print $3}' | tr '\n' ' '; }

# ===========================================================================
echo "== 0. the script parses =="
expect_rc "bash -n build/host-ready.sh" 0 bash -n "$HR"
bash -n "$HR" >/dev/null 2>&1 \
    && ok "the script parses (the regression that made every check unreachable)" \
    || bad "the script does not parse; every check below is unreachable"

# ===========================================================================
echo "== 1. positive: a fully populated fixture host is READY =="
H="$W/h1"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
out="$(run "$H" amd64 --no-publish)"; rc=$?
if [ "$rc" = 0 ]; then
    ok "positive fixture host: rc=0"
else
    bad "positive fixture host: rc=$rc, wanted 0 (failing: $(fails_of "$out"))" "$out"
fi
grep -q 'READY: 0 failing check' <<<"$out" \
    && ok "positive: the summary says READY with 0 failures" \
    || bad "positive: no READY summary" "$out"
for c in dirty-tree kvm root-owned tools disk kernel-staging tmpfs \
         substrate build-inputs sudo-model stdout container-image; do
    if grep -qE "^\[host-ready\] (OK|WARN) +$c " <<<"$out"; then
        ok "positive: $c ran and did not fail"
    else
        bad "positive: $c did not report OK/WARN" "$out"
    fi
done

# ===========================================================================
echo "== 2. negative: the staging pool holds a different release =="
# The manifest wants r293; the pool holds r292 only (docs M5 test, item 1).
# kernel-staging answers per arch: arm64 compares the release name in
# assets/kernel/mainline.release, amd64 compares assets/kernel/amd64-stable/KVER.
# Both directions are covered; the arm64 host has no amd64 KVER by design.
H="$W/h2"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
printf 'r293-7.3.0-sky1-ncz-20261030\n' > "$H/clone/assets/kernel/mainline.release"
out="$(run "$H" arm64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "staging pool holds r292, pin wants r293: the gate fails (rc=$rc)" \
    || bad "stale pool: rc=$rc, wanted 1 (failing: $(fails_of "$out"))" "$out"
grep -q '^\[host-ready\] FAIL kernel-staging ' <<<"$out" \
    && ok "stale pool: the failure is named kernel-staging" \
    || bad "stale pool: kernel-staging not named in $(fails_of "$out")" "$out"
grep -qi 'r293' <<<"$(grep 'FAIL kernel-staging' <<<"$out")" \
    && ok "stale pool: the message names the pinned release" \
    || bad "stale pool: the message does not name r293" "$out"
# amd64: the pool holds no build with the pinned KVER.  The positive host
# staged 6.16.1; pin 6.17.0 and the pool is stale.
H2="$W/h2b"; H_RUN="$H2/run"; mkhost "$H2"; mktools "$H2"; mkdf "$H2"; mkfs "$H2"
printf '6.17.0\n' > "$H2/clone/assets/kernel/amd64-stable/KVER"
out="$(run "$H2" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "amd64 pool has no build with the pinned KVER: the gate fails (rc=$rc)" \
    || bad "amd64 stale KVER: rc=$rc, wanted 1 (failing: $(fails_of "$out"))" "$out"
grep -q '^\[host-ready\] FAIL kernel-staging ' <<<"$out" \
    && ok "amd64 stale KVER: the failure is named kernel-staging" \
    || bad "amd64 stale KVER: kernel-staging not named ($(fails_of "$out"))" "$out"
grep -q '6.17.0' <<<"$(grep 'FAIL kernel-staging' <<<"$out")" \
    && ok "amd64 stale KVER: the message names the pinned KVER" \
    || bad "amd64 stale KVER: the message does not name 6.17.0" "$out"

# ===========================================================================
echo "== 3. negative: the substrate cache does not resolve =="
H="$W/h3"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
rm -f "$H"/cache/*.iso
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "empty cache: the gate fails (rc=$rc)" || bad "empty cache: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL substrate ' <<<"$out" \
    && ok "empty cache: the failure is named substrate" || bad "empty cache: substrate not named ($(fails_of "$out"))" "$out"
# the same host with the ISO removed is the only difference -- prove the
# positive host passes with the ISO present
H9="$W/h3ok"; H_RUN="$H9/run"; mkhost "$H9"; mktools "$H9"; mkdf "$H9"; mkfs "$H9"
expect_rc "the cache-control host (ISO present) passes" 0 run "$H9" amd64 --no-publish

# ===========================================================================
echo "== 4. negative: an ISO with the wrong bytes is not accepted =="
H="$W/h4"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
# keep the pinned NAME but replace the bytes: only the sha256 can catch this.
iso="$(ls "$H"/cache/*-*.iso | head -1)"
printf 'rotated substrate\n' > "$iso"
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "wrong-bytes ISO: the gate fails (rc=$rc)" || bad "wrong-bytes ISO: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL substrate ' <<<"$out" \
    && ok "wrong-bytes ISO: the failure is named substrate" || bad "wrong-bytes ISO: substrate not named ($(fails_of "$out"))" "$out"

# ===========================================================================
echo "== 5. negative: one build-inputs row is missing =="
H="$W/h5"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
cat > "$H/clone/build/stage-build-inputs.sh" <<'EOS'
#!/bin/bash
echo "[build-inputs] MISSING/BAD: assets/inputs/blob.bin not staged (run build/stage-build-inputs.sh --arch amd64)" >&2
exit 1
EOS
chmod +x "$H/clone/build/stage-build-inputs.sh"
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "missing input row: the gate fails (rc=$rc)" || bad "missing input row: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL build-inputs ' <<<"$out" \
    && ok "missing input row: the failure is named build-inputs" || bad "missing input row: build-inputs not named ($(fails_of "$out"))" "$out"
grep -q 'blob.bin' <<<"$out" \
    && ok "missing input row: the message names the offending path" || bad "missing input row: no path in the message" "$out"

# ===========================================================================
echo "== 6. negative: an inputs file has the wrong sha256 =="
H="$W/h6"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
printf 'tampered input\n' > "$H/clone/assets/inputs/blob.bin"
cat > "$H/clone/build/stage-build-inputs.sh" <<'EOS'
#!/bin/bash
echo "[build-inputs] MISSING/BAD: assets/inputs/blob.bin sha256 differs from the pin (deadbeef)" >&2
exit 1
EOS
chmod +x "$H/clone/build/stage-build-inputs.sh"
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "wrong input sha: the gate fails (rc=$rc)" || bad "wrong input sha: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL build-inputs ' <<<"$out" \
    && ok "wrong input sha: the failure is named build-inputs" || bad "wrong input sha: build-inputs not named ($(fails_of "$out"))" "$out"

# ===========================================================================
echo "== 7. negative: the tree is dirty =="
H="$W/h7"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
printf 'uncommitted\n' >> "$H/clone/README"
out="$(run "$H" amd64)"; rc=$?
[ "$rc" = 1 ] && ok "dirty tree, publishable build: the gate fails (rc=$rc)" || bad "dirty tree: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL dirty-tree ' <<<"$out" \
    && ok "dirty tree: the failure is named dirty-tree" || bad "dirty tree: dirty-tree not named ($(fails_of "$out"))" "$out"
# --no-publish keeps the historic WARN: the same host is READY
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 0 ] && ok "dirty tree, --no-publish: still READY (WARN only, rc=$rc)" \
    || bad "dirty tree, --no-publish: rc=$rc, wanted 0" "$out"
grep -q '^\[host-ready\] WARN dirty-tree ' <<<"$out" \
    && ok "dirty tree, --no-publish: reported as WARN" || bad "--no-publish: dirty tree not a WARN" "$out"

# ===========================================================================
echo "== 8. negative: stdout is redirected inside the clone =="
H="$W/h8"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
out="$(run "$H" amd64 --no-publish >"$H/clone/build.log" 2>&1; echo "rc=$?")"
rc="${out#rc=}"
[ "$rc" = 1 ] && ok "stdout inside the clone: the gate fails (rc=$rc)" || bad "stdout inside the clone: rc=$rc, wanted 1"
outfile="$(cat "$H/clone/build.log" 2>/dev/null)"
grep -q '^\[host-ready\] FAIL stdout ' <<<"$outfile" \
    && ok "stdout inside the clone: the failure is named stdout" || bad "stdout inside the clone: stdout not named ($(fails_of "$outfile"))" "$outfile"
rm -f "$H/clone/build.log"

# ===========================================================================
echo "== 9. negative: the df fixture is below the threshold =="
H="$W/h9"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H" 1024; mkfs "$H"
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "low free space: the gate fails (rc=$rc)" || bad "low free space: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL disk ' <<<"$out" \
    && ok "low free space: the failure is named disk" || bad "low free space: disk not named ($(fails_of "$out"))" "$out"

# ===========================================================================
echo "== 10. negative: the scratch is on tmpfs =="
H="$W/h10"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H" tmpfs
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "tmpfs scratch: the gate fails (rc=$rc)" || bad "tmpfs scratch: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL tmpfs ' <<<"$out" \
    && ok "tmpfs scratch: the failure is named tmpfs" || bad "tmpfs scratch: tmpfs not named ($(fails_of "$out"))" "$out"

# ===========================================================================
echo "== 11. negative: no usable privilege model =="
H="$W/h11"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
# The gate sources build/lib/priv.sh from the fixture clone.  A stub that
# reports "none" is the one difference; NCZ_SUDO=0 would report "direct".
mkdir -p "$H/clone/build/lib"
cat > "$H/clone/build/lib/priv.sh" <<'EOP'
ncz_priv_model() { printf 'none\n'; return 1; }
EOP
out="$(run "$H" amd64 --no-publish)"; rc=$?
[ "$rc" = 1 ] && ok "no sudo model: the gate fails (rc=$rc)" || bad "no sudo model: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL sudo-model ' <<<"$out" \
    && ok "no sudo model: the failure is named sudo-model" || bad "no sudo model: sudo-model not named ($(fails_of "$out"))" "$out"
# the positive control: a stub that reports root makes the same host READY
cat > "$H/clone/build/lib/priv.sh" <<'EOP'
ncz_priv_model() { printf 'root\n'; return 0; }
EOP
expect_rc "the same host with a root model passes" 0 run "$H" amd64 --no-publish

# ===========================================================================
echo "== 12. negative: the /dev/kvm the kvm gate needs is unusable =="
H="$W/h12"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
out="$(run "$H" amd64 --no-publish --kvm "$H/no-such-kvm")"; rc=$?
[ "$rc" = 1 ] && ok "absent kvm device: the gate fails under the kvm gate (rc=$rc)" || bad "absent kvm: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL kvm ' <<<"$out" \
    && ok "absent kvm: the failure is named kvm" || bad "absent kvm: kvm not named ($(fails_of "$out"))" "$out"
# without the kvm gate the same host is READY
out="$(run "$H" amd64 --no-publish --kvm "$H/no-such-kvm" --gates provenance)"; rc=$?
[ "$rc" = 0 ] && ok "absent kvm, no kvm gate: READY (rc=$rc)" || bad "absent kvm without the gate: rc=$rc, wanted 0" "$out"

# ===========================================================================
echo "== 13. negative: the container image is absent =="
H="$W/h13"; H_RUN="$H/run"; mkhost "$H"; mktools "$H"; mkdf "$H"; mkfs "$H"
# a podman stub whose "image exists" always fails
mkdir -p "$H/bin2"
printf '#!/bin/sh\n[ "$1 $2" = "image exists" ] && exit 1\nexit 0\n' > "$H/bin2/podman"
chmod +x "$H/bin2/podman"
out="$(env -u NCZ_YOCTO_SHARED_DIR -u NCZ_SUBSTRATE_CACHE_DIRS -u NCZ_KERNEL_STAGING_DIR \
    -u NCZ_SUDO_PASS_FILE -u TMPDIR HOME="$H/nohome" XDG_CONFIG_HOME="$H/nohome/.config" \
    PATH="$H/bin2:$H/bin:$PATH" bash "$HR" --arch amd64 --root "$H/clone" --run-dir "$H/run" \
    --staging-dir "$H/staging" --substrate-cache "$H/cache" \
    --df-fixture "$H/df.txt" --fs-fixture "$H/fs.txt" \
    --tools "xorriso cpio zstd unsquashfs mmdebstrap" \
    --container-image localhost/ncz-imagebuild:trixie --no-publish 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "absent container image: the gate fails (rc=$rc)" || bad "absent container image: rc=$rc, wanted 1" "$out"
grep -q '^\[host-ready\] FAIL container-image ' <<<"$out" \
    && ok "absent container image: the failure is named container-image" || bad "absent container image: not named ($(fails_of "$out"))" "$out"

# ===========================================================================
echo "== 14. usage errors =="
expect_rc "no --arch is a usage error" 2 bash "$HR" --root "$W/h1/clone"
expect_rc "a bad --arch is a usage error" 2 bash "$HR" --arch riscv64 --root "$W/h1/clone"
expect_rc "an unknown option is a usage error" 2 bash "$HR" --arch amd64 --nope
expect_rc "--help exits 0" 0 bash "$HR" --help

# ===========================================================================
printf '\n== host-ready tests: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
