#!/bin/bash
# test-build-image-dev-bind.sh -- NG-NC-03: the host /dev must not leak into
# package-installing container stages.
#
# WHY.  Every container stage ran with `-v /dev:/dev`, so package postinsts
# (systemd-tmpfiles `z /dev/kvm 0660 - kvm -`) re-owned the HOST's /dev/kvm
# with the CONTAINER's kvm gid (container 994 vs host 992), leaving the node
# root:crontab / root:systemd-resolve and breaking the next preflight.  A
# plain container run with the same bind did not change the node -- only
# package-installing stages do.
#
# RULE (pinned here): only stages that need real devices (kvm-gate, anything
# running qemu or loop devices -- the image stage loop-mounts via losetup in
# build/iso/write-usb-image.py) get `-v /dev:/dev`; package/layer stages
# (offline-mirror) use the runtime's private /dev.  The mount list is built by
# one function, ncz_container_mounts_for_stage(), which this test calls per
# stage name WITHOUT starting any container and asserts the bind set on.
# The kvm-gate stage keeps its devices.
#
#   build/test-build-image-dev-bind.sh    exit 0 all pass, 1 any FAIL
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/build-image.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

# Extract the mount-builder block (never source build-image.sh: it runs the
# whole pipeline on source).  The block is self-contained by construction.
T="$(mktemp -d "${NCZ_TEST_SCRATCH:-/var/tmp}/devbind.XXXXXX")"
trap 'rm -rf "$T"' EXIT
if ! awk '/^# BEGIN_NCZ_CONTAINER_MOUNTS/{f=1;next} /^# END_NCZ_CONTAINER_MOUNTS/{f=0} f' \
        "$BIN" > "$T/mounts.sh" || [ ! -s "$T/mounts.sh" ]; then
    bad "could not extract the mount-builder block from build-image.sh"
    printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
    exit 1
fi
# shellcheck source=/dev/null
. "$T/mounts.sh"
for fn in ncz_container_mounts_for_stage ncz_container_dev_bind_for_stage; do
    if declare -F "$fn" >/dev/null; then
        ok "$fn is defined by the extracted block"
    else
        bad "$fn is NOT defined by the extracted block"
    fi
done
[ "$FAIL" != 0 ] && { printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"; exit 1; }

binds_for() { ncz_container_mounts_for_stage "$1"; }
# NOTE: never `binds_for ... | grep -q` here.  With `set -o pipefail`, grep -q
# exits as soon as it matches and closes the pipe, so the writer dies of
# SIGPIPE (exit 141) in a race -- a flaky FAIL on multi-line bind lists.
# Capture first, then grep the captured text via a herestring (no pipe).
has_dev() { grep -Fxq -- "/dev:/dev" <<<"$(binds_for "$1")"; }
has_worktree() { grep -Fxq -- "$ROOT:/work/cix-installer" <<<"$(binds_for "$1")"; }

# 1. the package-installing stage must NOT see the host /dev
if has_dev offline-mirror; then
    bad "offline-mirror binds the host /dev (postinsts would re-own /dev/kvm)"
else
    ok "offline-mirror uses the runtime private /dev (no /dev bind)"
fi

# 2. stages with real device needs keep the bind
for s in kvm-gate image; do
    if has_dev "$s"; then
        ok "$s keeps -v /dev:/dev"
    else
        bad "$s lost -v /dev:/dev (it needs real devices)"
    fi
done

# 3. unknown / future stages default to the safe side (no host /dev)
if has_dev "some-future-stage"; then
    bad "unknown stage binds the host /dev (default must be private /dev)"
else
    ok "unknown stage defaults to private /dev"
fi

# 4. the work-tree bind is always present (the container must see the repo)
for s in offline-mirror image kvm-gate; do
    if has_worktree "$s"; then
        ok "$s still binds the work tree"
    else
        bad "$s lost the work-tree bind"
    fi
done

# 5. the live helper routes through the same builder (no second mount list):
# extract ncz_container_run's body and require the builder call inside it.
T2_RUN="$(awk '/^ncz_container_run\(\)/{f=1} f{print} f&&/^\}/{c++; if(c==1)exit}' "$BIN")"
if grep -q 'ncz_container_mounts_for_stage' <<<"$T2_RUN"; then
    ok "ncz_container_run builds its mounts via ncz_container_mounts_for_stage"
else
    bad "ncz_container_run does not use ncz_container_mounts_for_stage (two mount lists would drift)"
fi
if grep -n '\-v /dev:/dev' "$BIN" | grep -vq 'ncz_container_dev_bind_for_stage\|test-build-image-dev-bind'; then
    bad "a raw '-v /dev:/dev' survives outside ncz_container_dev_bind_for_stage"
else
    ok "no raw '-v /dev:/dev' outside the single gate function"
fi

printf 'RESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
