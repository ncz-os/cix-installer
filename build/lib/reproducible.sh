#!/bin/bash
# reproducible.sh -- shell surface of the NCZ-OS determinism contract.
#
# Source this, then call `ncz_repro_env` before any tool that writes bytes into
# an artifact.  Every derived value comes from build/lib/reproducible.py, so the
# rule lives in exactly one place (see build/test-build-determinism.sh).
#
#   . build/lib/reproducible.sh
#   ncz_repro_init "$ROOT"                 # locate ROOT + the pinned python
#   ncz_repro_env                          # LC_ALL/TZ/umask/SOURCE_DATE_EPOCH
#   ncz_pin_digest                         # sha256 of the canonical base.pin
#   ncz_uuid ext4 amd64                    # stable, pin-derived UUID
#   ncz_tar_repro -c -f out.tar -C dir .   # sorted, fixed-owner/mtime tar
#   ncz_mksquashfs src dst [extra...]      # fixed-flags squashfs packer
#
# The environment this exports is the determinism contract:
#   LC_ALL=C LANG=C LANGUAGE=C TZ=UTC
#   umask 022
#   SOURCE_DATE_EPOCH=<git commit time, else snapshot_epoch>
# Anything that reads the wall clock or the locale and ends up in an artifact is
# a bug; the wrappers exist so the correct invocation is the easy one.

# ---------------------------------------------------------------------------
# init
# ---------------------------------------------------------------------------
ncz_repro_init() {
    local root="${1:-}"
    if [ -z "$root" ]; then
        # resolve from this file's location: <root>/build/lib/reproducible.sh
        local self
        self="$(readlink -f "${BASH_SOURCE[0]}")"
        root="$(cd "$(dirname "$self")/../.." && pwd)"
    fi
    NCZ_REPRO_ROOT="$root"
    NCZ_REPRO_PY="$root/build/lib/reproducible.py"
    NCZ_PIN_FILE="${NCZ_PIN_FILE:-$root/manifests/base.pin}"
    export NCZ_REPRO_ROOT NCZ_REPRO_PY NCZ_PIN_FILE
    if [ ! -f "$NCZ_REPRO_PY" ]; then
        echo "reproducible.sh: missing $NCZ_REPRO_PY" >&2
        return 1
    fi
}

_ncz_repro_py() { python3 -I "$NCZ_REPRO_PY" "$@" ; }

# ---------------------------------------------------------------------------
# environment
# ---------------------------------------------------------------------------
ncz_repro_env() {
    export LC_ALL=C LANG=C LANGUAGE=C TZ=UTC
    umask 022
    ncz_repro_sde >/dev/null || return 1
}

# Print (do not export) the resolved SOURCE_DATE_EPOCH; exports it as a side
# effect.  Precedence lives in reproducible.py; here we only pass the repo.
ncz_repro_sde() {
    [ -n "${NCZ_REPRO_ROOT:-}" ] || { echo "ncz_repro_env before ncz_repro_init" >&2; return 1; }
    local args=(sde --pin "$NCZ_PIN_FILE")
    if [ -d "$NCZ_REPRO_ROOT/.git" ]; then args+=(--repo "$NCZ_REPRO_ROOT"); fi
    local sde
    if ! sde="$(_ncz_repro_py "${args[@]}")"; then
        echo "reproducible.sh: cannot derive SOURCE_DATE_EPOCH from $NCZ_PIN_FILE" >&2
        return 1
    fi
    export SOURCE_DATE_EPOCH="$sde"
    printf '%s\n' "$sde"
}

# ---------------------------------------------------------------------------
# pin accessors
# ---------------------------------------------------------------------------
ncz_pin_ready() { [ -f "${NCZ_PIN_FILE:-}" ]; }

ncz_pin_digest() { _ncz_repro_py pin-digest "$NCZ_PIN_FILE"; }

# value of a pin key (empty + rc 1 when absent)
ncz_pin_get() {
    local key="$1" line
    line="$(awk -F'\t' -v k="$key" '$1==k {print $2; found=1} END{exit !found}' "$NCZ_PIN_FILE")"
    printf '%s\n' "$line"
}

# merged per-run pin (adds the resolved arch rows); writes to $1
ncz_pin_arch_file() {
    local out="$1" arch="$2" sub_sha="$3" sub_name="$4" kver="$5" sing="$6"
    _ncz_repro_py arch-pin --pin "$NCZ_PIN_FILE" --arch "$arch" \
        --substrate-sha "$sub_sha" --substrate-name "$sub_name" \
        --kernel-kver "$kver" --singularity-sha256 "$sing" > "$out"
}

ncz_uuid() { _ncz_repro_py uuid --kind "$1" --pin "$NCZ_PIN_FILE" --arch "${2:-}"; }

# ---------------------------------------------------------------------------
# byte-writing wrappers
# ---------------------------------------------------------------------------
# Deterministic tar.  `--sort=name` is create-only, so this is for creating.
# `--mtime=@$SOURCE_DATE_EPOCH` pins every member mtime; --owner/--group 0 with
# --numeric-owner drops the build user; --format=gnu is the widest-supported
# stable format.  Callers still choose -C/--exclude.
ncz_tar_repro() {
    : "${SOURCE_DATE_EPOCH:?ncz_repro_env must run before ncz_tar_repro}"
    # GNU tar sorts members deterministically and is what every Linux build
    # host ships.  BSD tar (macOS dev boxes) lacks --sort/--format=gnu; detect
    # it and fall back to plain tar so the helper still works there (the
    # determinism test skips on non-GNU tar rather than false-passing).
    if tar --version 2>/dev/null | grep -qi 'GNU tar'; then
        tar --sort=name --format=gnu \
            --mtime="@${SOURCE_DATE_EPOCH}" \
            --owner=0 --group=0 --numeric-owner \
            "$@"
    else
        tar "$@"
    fi
}

# Deterministic squashfs.  The flags mirror what build-squashfs-layers.sh
# already uses (verified): zstd level 15, all file times 0, fs time 0, one
# processor (so the thread count can never change the byte stream), and the
# SELinux xattr excluded.  -noappend makes a fresh archive; -no-progress keeps
# logs stable.  Extra args are appended.
ncz_mksquashfs() {
    local src="$1" dst="$2"; shift 2
    # mksquashfs >= 4.7 REFUSES to run when SOURCE_DATE_EPOCH is set AND an
    # explicit timestamp option (-all-time/-fstime) is given: "SOURCE_DATE_EPOCH
    # and command line options can't be used at the same time".  We want the
    # explicit, epoch-0 form (it matches what build-squashfs-layers.sh uses and
    # is independent of the environment), so drop SOURCE_DATE_EPOCH for this
    # invocation only.  Determinism is unchanged: -all-time 0 -fstime 0 pins
    # every timestamp to 0.
    env -u SOURCE_DATE_EPOCH mksquashfs "$src" "$dst" \
        -comp zstd -Xcompression-level 15 \
        -all-time 0 -fstime 0 -processors "${NCZ_SQUASHFS_PROCESSORS:-1}" \
        -xattrs-exclude '^security\.selinux' \
        -noappend -no-progress "$@"
}

# Deterministic ext4 filesystem creation.  -U pins the UUID, -E hash_seed
# pins the directory hash seed (otherwise it is random per mke2fs and changes
# every directory entry ordering), and the creation time is set from
# SOURCE_DATE_EPOCH via -E no_copy_xattrs + e2fsprogs' honouring of
# SOURCE_DATE_EPOCH for the superblock mkfs time (e2fsprogs >= 1.47).
# usage: ncz_mke2fs <image> [mke2fs trailing args, e.g. a block count]
ncz_mke2fs() {
    : "${SOURCE_DATE_EPOCH:?ncz_repro_env must run before ncz_mke2fs}"
    # mke2fs syntax is `mke2fs [opts] device [blocks]`, so the caller-supplied
    # device/block arguments go LAST, after the pinned -U/-E options.
    mke2fs -q -F -t ext4 \
        -U "$(ncz_uuid ext4 "${NCZ_REPRO_ARCH:-}")" \
        -E "hash_seed=$(ncz_uuid ext4-hashseed "${NCZ_REPRO_ARCH:-}")" \
        "$@"
}

# Deterministic vfat (mtools mformat): fixed serial (volume id).
ncz_mformat() {
    local img="$1"; shift
    mformat -i "$img" -N "$(ncz_uuid vfat "${NCZ_REPRO_ARCH:-}" | tr -d '-' | cut -c1-8)" "$@"
}

# ---------------------------------------------------------------------------
# guidance
# ---------------------------------------------------------------------------
# Echo the fixed UUIDs for a given arch as shell assignments (for callers that
# cannot source this, e.g. write-usb-image.py reading the environment).
ncz_repro_env_assignments() {
    local arch="${1:-}"
    printf 'NCZ_REPRO_UUID_EXT4=%s\n' "$(ncz_uuid ext4 "$arch")"
    printf 'NCZ_REPRO_UUID_EXT4_DATA=%s\n' "$(ncz_uuid ext4-data "$arch")"
    printf 'NCZ_REPRO_UUID_DISK=%s\n' "$(ncz_uuid gpt-disk "$arch")"
    printf 'NCZ_REPRO_UUID_ESP=%s\n' "$(ncz_uuid gpt-esp "$arch")"
    printf 'NCZ_REPRO_UUID_DATA=%s\n' "$(ncz_uuid gpt-data "$arch")"
    printf 'NCZ_REPRO_VFAT_SERIAL=0x%s\n' "$(ncz_uuid vfat "$arch" | tr -d '-' | cut -c1-8)"
}
