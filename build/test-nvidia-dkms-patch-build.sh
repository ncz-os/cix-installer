#!/bin/bash
# test-nvidia-dkms-patch-build.sh -- build-level test for the local NVIDIA DKMS
# patches in assets/nvidia/dkms/: the real stage_dkms_patches() from
# assets/nvidia/ncz-cuda-setup stages them, then the real dkms builds the full
# NVIDIA module set against real kernel headers in a Debian forky container.
#
#   unpatched  the stock source against headers with CONFIG_CGROUP_DMEM=y must
#              FAIL at os-interface.c (dmem_cgroup_register_region, the 7.3 API)
#   patched    the staged patch set must build nvidia, nvidia-modeset,
#              nvidia-drm, nvidia-uvm and nvidia-peermem
#
# Needs podman or docker, kernel headers and the NVIDIA DKMS source; SKIPs
# (exit 0) when any of them is missing, so it is safe in `make test` on hosts
# without a container runtime. Heavy (two full module builds): run it on a
# build host, never on STUDIO.
#
#   NCZ_KHDR_DIR   directory holding linux-headers-$NCZ_KVER (required)
#   NCZ_KVER       kernel release of those headers (required)
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
[ -r "${NCZ_NV_SRC:-/nonexistent}/dkms.conf" ] || skip "set NCZ_NV_SRC to an unpacked nvidia-<ver> DKMS source"
NVMV=$(basename "$NCZ_NV_SRC")
[ -d "$ROOT/assets/nvidia/dkms/$NVMV" ] || skip "no local patch set for $NVMV in assets/nvidia/dkms"
case "$(findmnt -no FSTYPE -T "${TMPDIR:-/tmp}" 2>/dev/null)" in
    tmpfs|ramfs) echo "ERROR: TMPDIR ${TMPDIR:-/tmp} is a tmpfs; point it at local disk" >&2; exit 2 ;;
esac
IMAGE=${NCZ_CTR_IMAGE:-docker.io/library/debian:forky}
MODES=${NCZ_TEST_MODES:-unpatched patched}
W=$(mktemp -d "${TMPDIR:-/tmp}/nvdkms.XXXXXX"); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/fn"
# the real functions, not a copy: log, sum_of, stage_dkms_patches
sed -n '/^log() /p; /^sum_of() {/,/^}/p; /^stage_dkms_patches() {/,/^}/p' \
    "$ROOT/assets/nvidia/ncz-cuda-setup" > "$W/fn/stage.sh"
grep -q '^stage_dkms_patches()' "$W/fn/stage.sh" || { echo "FAIL: stage_dkms_patches not found in ncz-cuda-setup"; exit 1; }

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
    LOG=/dev/null NV_DKMS_PATCHES=/patches DKMS_ETC=/etc/dkms SRC_ROOT=/usr/src
    # shellcheck disable=SC1091
    . /fn/stage.sh
    stage_dkms_patches
    echo "--- /etc/dkms/$mv.conf"; cat "/etc/dkms/$mv.conf"
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

PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); echo "ok   $*"; }
nok() { FAILS=$((FAILS+1)); echo "FAIL $*"; }
for mode in $MODES; do
    mkdir -p "$W/out-$mode"
    "$RT" run --rm --name "ncz-nvdkms-test-$$-$mode" \
        -v "$NCZ_KHDR_DIR:/hdr:ro" -v "$NCZ_NV_SRC:/nvsrc:ro" \
        -v "$ROOT/assets/nvidia/dkms:/patches:ro" -v "$W/fn:/fn:ro" -v "$W/out-$mode:/out" \
        "$IMAGE" /fn/inner.sh "$mode" "$NCZ_KVER" "$NVMV" > "$W/out-$mode/ctr.log" 2>&1
    rc=$(cat "$W/out-$mode/rc" 2>/dev/null || echo none)
    first_err=$(grep -m1 -E '(^|[[:space:]:])error:' "$W/out-$mode/make.log" 2>/dev/null)
    case "$mode" in
    unpatched)
        if grep -qx 'CONFIG_CGROUP_DMEM=y' "$NCZ_KHDR_DIR/linux-headers-$NCZ_KVER/include/config/auto.conf" 2>/dev/null; then
            [ "$rc" != 0 ] && [ "$rc" != none ] && ok "unpatched $NVMV fails against CGROUP_DMEM=y headers (rc=$rc)" \
                || nok "unpatched $NVMV did not fail (rc=$rc)"
            case "$first_err" in
                *os-interface.c*dmem_cgroup_register_region*) ok "unpatched: first error is the dmem API ($first_err)" ;;
                *) nok "unpatched: unexpected first error: ${first_err:-none}"; tail -5 "$W/out-$mode/ctr.log" ;;
            esac
        else
            echo "note: headers have CGROUP_DMEM off; the unpatched build is expected to pass"
            [ "$rc" = 0 ] && ok "unpatched $NVMV builds (CGROUP_DMEM off)" || nok "unpatched failed (rc=$rc): ${first_err:-}"
        fi ;;
    patched)
        grep -q '^PATCH\[' "$W/out-$mode/ctr.log" && ok "patched: /etc/dkms/$NVMV.conf lists the patches" \
            || nok "patched: no PATCH[] in /etc/dkms/$NVMV.conf"
        grep -q 'Applying patch' "$W/out-$mode/dkms.out" "$W/out-$mode/make.log" 2>/dev/null \
            && ok "patched: dkms applied the local patch" || nok "patched: dkms did not apply a patch"
        [ "$rc" = 0 ] && ok "patched $NVMV builds (dkms rc=0)" || { nok "patched build failed (rc=$rc): ${first_err:-}"; tail -15 "$W/out-$mode/dkms.out"; }
        for ko in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
            grep -qx "$ko.ko" "$W/out-$mode/ko.txt" 2>/dev/null && ok "patched: $ko.ko built" || nok "patched: $ko.ko missing"
        done
        if [ -s "$W/out-$mode/vermagic.txt" ]; then
            bad_vm=$(grep -vc " vermagic: $NCZ_KVER " "$W/out-$mode/vermagic.txt")
            [ "$bad_vm" = 0 ] && ok "patched: every module's vermagic names $NCZ_KVER" || nok "patched: vermagic mismatch: $(cat "$W/out-$mode/vermagic.txt")"
        fi ;;
    esac
done
echo "----"
echo "PASS=$PASS FAIL=$FAILS"
exit "$FAILS"
