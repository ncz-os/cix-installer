#!/bin/bash
# test-nvidia-dkms-patch-build.sh -- build-level test for the local NVIDIA DKMS
# patches in assets/nvidia/dkms/: the real `ncz-cuda-setup dkms-stage` decides
# by content which patch sets the given driver source needs (fix absent, applies
# with fuzz 0) and stages them, then the real dkms builds the full NVIDIA module
# set against real kernel headers in a Debian forky container. The driver
# version does not matter: any unpacked nvidia-<ver> source works.
#
#   unpatched  the stock source against headers with CONFIG_CGROUP_DMEM=y must
#              FAIL at os-interface.c (dmem_cgroup_register_region, the 7.3 API)
#   patched    the staged patch set must build nvidia, nvidia-modeset,
#              nvidia-drm, nvidia-uvm and nvidia-peermem
#
# Needs podman or docker, kernel headers and the NVIDIA DKMS source; SKIPs
# (exit 0) when any of them is missing, so it is safe in `make test` on hosts
# without a container runtime. Heavy (two full module builds): run it on a
# build host, never on the macOS orchestration workstation.
#
#   NCZ_KHDR_DIR   directory holding linux-headers-$NCZ_KVER (required); the
#                  second header set (NCZ_KHDR_DIR_2 / NCZ_KVER_2) may live in
#                  the same directory or another one
#   NCZ_KVER       kernel release of those headers (required)
#   NCZ_KHDR_DIR_2 second header set (the task this test exists for needs the
#                  patched case built against BOTH a 7.4 and a 7.3.x tree: a
#                  probe that was true on 7.3.x once selected a 7.4-only
#                  helper and was only caught by building 7.3.4. Without it the
#                  run still passes but reports SKIP=1, i.e. incomplete)
#   NCZ_KVER_2     kernel release of the second header set (optional)
#   NCZ_NV_SRC     unpacked DKMS source dir nvidia-<ver> (required; e.g. copied
#                  from /usr/src of a machine with nvidia-kernel-open-dkms)
#   NCZ_CTR_IMAGE  build image (default docker.io/library/debian:forky; the
#                  packages below are installed when missing)
#   NCZ_TEST_MODES "unpatched patched" (default both)
#   TMPDIR         scratch for the container copy (must not be a tmpfs)
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
skip() { echo "SKIP: $*"; exit 0; }

RT=""
for c in podman docker; do command -v "$c" >/dev/null 2>&1 && { RT=$c; break; }; done
[ -n "$RT" ] || skip "no podman/docker"
[ -n "${NCZ_KVER:-}" ] && [ -d "${NCZ_KHDR_DIR:-/nonexistent}/linux-headers-${NCZ_KVER:-x}" ] \
    || skip "set NCZ_KHDR_DIR and NCZ_KVER (headers dir linux-headers-\$NCZ_KVER)"
# second header set: optional, but the patched case must build against both when given
KHDR2_DIR=""; KVER2=""
if [ -n "${NCZ_KVER_2:-}" ]; then
    KHDR2_DIR=${NCZ_KHDR_DIR_2:-$NCZ_KHDR_DIR}
    [ -d "$KHDR2_DIR/linux-headers-$NCZ_KVER_2" ] \
        || skip "NCZ_KVER_2=$NCZ_KVER_2 set but $KHDR2_DIR/linux-headers-$NCZ_KVER_2 is missing"
    KVER2=$NCZ_KVER_2
fi
[ -r "${NCZ_NV_SRC:-/nonexistent}/dkms.conf" ] || skip "set NCZ_NV_SRC to an unpacked nvidia-<ver> DKMS source"
NVMV=$(basename "$NCZ_NV_SRC")
case "$(findmnt -no FSTYPE -T "${TMPDIR:-/tmp}" 2>/dev/null)" in
    tmpfs|ramfs) echo "ERROR: TMPDIR ${TMPDIR:-/tmp} is a tmpfs; point it at local disk" >&2; exit 2 ;;
esac
IMAGE=${NCZ_CTR_IMAGE:-docker.io/library/debian:forky}
MODES=${NCZ_TEST_MODES:-unpatched patched}
W=$(mktemp -d "${TMPDIR:-/tmp}/nvdkms.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fn"
# the real tool, not a copy of its functions
install -m0755 "$ROOT/assets/nvidia/ncz-cuda-setup" "$W/fn/ncz-cuda-setup"

cat > "$W/fn/inner.sh" <<'EOF'
#!/bin/bash
# runs in the container: $1 = mode, $2 = kernel release, $3 = module-version
set -u
mode=$1 kv=$2 mv=$3
pkgs="gcc g++ make dkms kmod xz-utils libc6-dev libelf-dev bc patch openssl"
if ! command -v dkms >/dev/null || ! command -v g++ >/dev/null; then
    apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -qq --no-install-recommends $pkgs >/dev/null 2>&1 || { echo "ERROR: package install failed"; exit 90; }
fi
ln -sfn "/hdr/linux-headers-$kv" "/usr/src/linux-headers-$kv"
mkdir -p "/lib/modules/$kv"; ln -sfn "/usr/src/linux-headers-$kv" "/lib/modules/$kv/build"
cp -a "/nvsrc" "/usr/src/$mv"
if [ "$mode" = patched ]; then
    NCZ_NV_DKMS_PATCHES=/patches NCZ_DKMS_ETC=/etc/dkms NCZ_SRC_ROOT=/usr/src /fn/ncz-cuda-setup dkms-stage "/usr/src/$mv"
    echo "--- /etc/dkms/$mv.conf"; cat "/etc/dkms/$mv.conf" 2>/dev/null || echo "(none)"
fi
m=${mv%-*}; v=${mv##*-}
dkms add "$m/$v" >/dev/null 2>&1
dkms build "$m/$v" -k "$kv" -j "$(nproc)" > /out/dkms.out 2>&1; rc=$?
# failure: the log stays in build/; success: dkms moves log and modules under <kver>/<arch>/
cp "/var/lib/dkms/$m/$v/build/make.log" /out/make.log 2>/dev/null \
    || cp "/var/lib/dkms/$m/$v/$kv/"*/log/make.log /out/make.log 2>/dev/null
ls "/var/lib/dkms/$m/$v/build/kernel-open/"*.ko "/var/lib/dkms/$m/$v/$kv/"*/module/*.ko* 2>/dev/null \
    | xargs -r -n1 basename | sed 's/\.ko\..*$/.ko/' | sort -u > /out/ko.txt
for k in "/var/lib/dkms/$m/$v/$kv/"*/module/*.ko*; do
    [ -e "$k" ] && modinfo -F vermagic "$k" 2>/dev/null | sed "s#^#$(basename "$k") vermagic: #"
done > /out/vermagic.txt
echo "$rc" > /out/rc
EOF
chmod +x "$W/fn/inner.sh"

PASS=0; FAILS=0; SKIPPED=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
nok() { FAILS=$((FAILS+1)); echo "FAIL $*"; }
run_case() { # run_case MODE KVER KHDR_DIR TAG : one container build, results in $W/out-$TAG
    local mode=$1 kver=$2 khdr=$3 tag=$4
    mkdir -p "$W/out-$tag"
    "$RT" run --rm --name "ncz-nvdkms-test-$$-${RANDOM}-$tag" \
        -v "$khdr:/hdr:ro" -v "$NCZ_NV_SRC:/nvsrc:ro" \
        -v "$ROOT/assets/nvidia/dkms:/patches:ro" -v "$W/fn:/fn:ro" -v "$W/out-$tag:/out" \
        "$IMAGE" /fn/inner.sh "$mode" "$kver" "$NVMV" > "$W/out-$tag/ctr.log" 2>&1
}
check_unpatched() { # check_unpatched KVER TAG KHDR_DIR
    local kver=$1 tag=$2 khdr=$3 hdr rc first_err
    # the config that decided the build is read from the headers the container actually used,
    # not from a copy: a kernel header tree is ~75 MB, so copying it into the result dir was
    # both wasteful and the only way the config could end up in the wrong place
    hdr="$khdr/linux-headers-$kver/include/config/auto.conf"
    rc=$(cat "$W/out-$tag/rc" 2>/dev/null || echo none)
    first_err=$(grep -m1 -E '(^|[[:space:]:])error:' "$W/out-$tag/make.log" 2>/dev/null)
    if [ "$rc" = none ]; then
        nok "unpatched [$kver]: the build recorded no result (see $W/out-$tag/ctr.log)"; tail -5 "$W/out-$tag/ctr.log" 2>/dev/null; return 0
    fi
    if [ ! -r "$hdr" ]; then
        nok "unpatched [$kver]: cannot read $hdr to decide what the build should have done"; return 0
    fi
    if grep -qx 'CONFIG_CGROUP_DMEM=y' "$hdr"; then
        [ "$rc" != 0 ] && ok "unpatched $NVMV fails against $kver CGROUP_DMEM=y headers (rc=$rc)" \
            || nok "unpatched $NVMV did not fail against $kver (rc=$rc)"
        case "$first_err" in
            *os-interface.c*dmem_cgroup_register_region*|*uvm_hmm.c*) ok "unpatched: first error at the expected file ($kver: $first_err)" ;;
            *) nok "unpatched: unexpected first error ($kver): ${first_err:-none}"; tail -5 "$W/out-$tag/ctr.log" 2>/dev/null ;;
        esac
    else
        echo "note: $kver headers have CGROUP_DMEM off; the unpatched build is expected to pass"
        [ "$rc" = 0 ] && ok "unpatched $NVMV builds ($kver, CGROUP_DMEM off)" || nok "unpatched failed ($kver, rc=$rc): ${first_err:-}"
    fi
}
check_patched() { # check_patched KVER TAG
    local kver=$1 tag=$2 rc first_err bad_vm ko
    rc=$(cat "$W/out-$tag/rc" 2>/dev/null || echo none)
    if [ "$rc" = none ]; then
        nok "patched [$kver]: the build recorded no result (see $W/out-$tag/ctr.log)"; tail -5 "$W/out-$tag/ctr.log" 2>/dev/null; return 0
    fi
    first_err=$(grep -m1 -E '(^|[[:space:]:])error:' "$W/out-$tag/make.log" 2>/dev/null)
    if grep -q 'already carries the fix' "$W/out-$tag/ctr.log" 2>/dev/null; then
        ok "patched [$kver]: $NVMV carries the fix upstream; no local patch staged (content check)"
    else
        grep -q '^PATCH\[' "$W/out-$tag/ctr.log" 2>/dev/null && ok "patched [$kver]: /etc/dkms/$NVMV.conf lists the patches" \
            || nok "patched [$kver]: no PATCH[] in /etc/dkms/$NVMV.conf"
        # the patch may be reported by dkms in either file; only judge once one of them exists
        if [ -s "$W/out-$tag/dkms.out" ] || [ -s "$W/out-$tag/make.log" ]; then
            grep -q 'Applying patch' "$W/out-$tag/dkms.out" "$W/out-$tag/make.log" 2>/dev/null \
                && ok "patched [$kver]: dkms applied the local patch" || nok "patched [$kver]: dkms did not apply a patch"
        else
            nok "patched [$kver]: neither dkms.out nor make.log was recorded, so the patch application cannot be judged"
        fi
    fi
    # rc=0 only counts when the build also left evidence behind: a container that died
    # before writing ko.txt would otherwise be reported as a successful build
    if [ "$rc" = 0 ] && [ -s "$W/out-$tag/ko.txt" ]; then
        ok "patched [$kver] $NVMV builds (dkms rc=0)"
    elif [ "$rc" = 0 ]; then
        nok "patched [$kver]: rc=0 but no modules were recorded (ko.txt), so the build is not proven"
    else
        nok "patched [$kver] build failed (rc=$rc): ${first_err:-}"; tail -15 "$W/out-$tag/dkms.out" 2>/dev/null
    fi
    if [ ! -s "$W/out-$tag/ko.txt" ]; then
        return 0   # already reported above; the per-module checks below would all be noise
    fi
    for ko in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
        grep -qx "$ko.ko" "$W/out-$tag/ko.txt" && ok "patched [$kver]: $ko.ko built" || nok "patched [$kver]: $ko.ko missing"
    done
    if [ -s "$W/out-$tag/vermagic.txt" ]; then
        bad_vm=$(grep -vcF " vermagic: $kver " "$W/out-$tag/vermagic.txt")
        [ "$bad_vm" = 0 ] && ok "patched [$kver]: every module's vermagic names $kver" \
            || nok "patched [$kver]: vermagic mismatch: $(cat "$W/out-$tag/vermagic.txt")"
    else
        nok "patched [$kver]: no vermagic was recorded for the built modules"
    fi
}
for mode in $MODES; do
    case "$mode" in
    unpatched)
        # the defect is the 7.4-only helper; the unpatched source must fail there
        run_case unpatched "$NCZ_KVER" "$NCZ_KHDR_DIR" unpatched
        check_unpatched "$NCZ_KVER" unpatched "$NCZ_KHDR_DIR" ;;
    patched)
        # one real bug was only caught because 7.3.x was built as well: build BOTH
        run_case patched "$NCZ_KVER" "$NCZ_KHDR_DIR" patched
        check_patched "$NCZ_KVER" patched
        if [ -n "$KVER2" ]; then
            run_case patched "$KVER2" "$KHDR2_DIR" "patched-$KVER2"
            check_patched "$KVER2" "patched-$KVER2"
        else
            # counted, not just echoed: a run that only built the first header set has not
            # verified the case the task asks for, and the summary must say so
            SKIPPED=$((SKIPPED + 1))
            echo "note: no second header set (NCZ_KVER_2); the patched case was built against $NCZ_KVER only"
            echo "SKIP: patched build against a 7.3.x header set (set NCZ_KVER_2 and NCZ_KHDR_DIR_2)"
        fi ;;
    esac
done
echo "----"
echo "PASS=$PASS FAIL=$FAILS SKIP=$SKIPPED"
exit "$FAILS"
