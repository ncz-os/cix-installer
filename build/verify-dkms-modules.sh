#!/usr/bin/env bash
# Verify declared DKMS package/module coverage, and optionally verify a target
# kernel's installed DKMS modules are loadable.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/sbom/expected-dkms-modules.txt"
KVER=""
ROOT="/"
LIVE_LOAD=0
FAILED=0

usage() {
    cat >&2 <<'EOF'
Usage:
  build/verify-dkms-modules.sh [--manifest FILE]
  build/verify-dkms-modules.sh --kver KVER [--root ROOT] [--live-load]

Without --kver, performs the static SBOM check wired into preflight.
With --kver, verifies DKMS status, module presence, vermagic and modprobe dry-run
for that kernel. --live-load must run on the target kernel and performs real
modprobe insert/remove attempts, which is the check that catches MODVERSIONS
symbol-CRC rejects.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --manifest) MANIFEST="${2:-}"; shift 2 ;;
        --kver) KVER="${2:-}"; shift 2 ;;
        --root) ROOT="${2:-}"; shift 2 ;;
        --live-load) LIVE_LOAD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "verify-dkms-modules: ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

die() { echo "verify-dkms-modules: FAIL: $*" >&2; exit 1; }
fail() { echo "$*" >&2; FAILED=1; }
ok() { echo "verify-dkms-modules: ok: $*"; }

[ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"

strip_root() {
    local p="$1"
    case "$ROOT" in
        /) printf '%s\n' "$p" ;;
        *) printf '%s\n' "$ROOT/${p#/}" ;;
    esac
}

manifest_lines() {
    grep -vE '^[[:space:]]*(#|$)' "$MANIFEST"
}

conf_field() {
    local conf="$1" key="$2"
    sed -n "s/^[[:space:]]*$key=\"\\{0,1\\}\\([^\"]*\\)\"\\{0,1\\}[[:space:]]*$/\\1/p" "$conf" | head -1
}

conf_modules() {
    sed -n 's/^[[:space:]]*BUILT_MODULE_NAME\[[0-9][0-9]*\]="\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' "$1" \
        | awk 'NF { printf "%s%s", sep, $1; sep=" " } END { print "" }'
}

expected_line() {
    local pkg="$1" ver="$2" mods="$3"
    printf '%s/%s %s\n' "$pkg" "$ver" "$mods"
}

static_check() {
    local expected actual conf

    expected="$(manifest_lines | sort)"

    conf="$REPO/assets/kernel/mali/dkms.conf"
    [ -f "$conf" ] || fail "MISSING DKMS CONF: assets/kernel/mali/dkms.conf"
    actual="$(
        if [ -f "$conf" ]; then expected_line "$(conf_field "$conf" PACKAGE_NAME)" "$(conf_field "$conf" PACKAGE_VERSION)" "$(conf_modules "$conf")"; fi
        expected_line aipu 6.2.0 aipu
        conf="$REPO/assets/kernel/vpu/dkms.conf"
        if [ -f "$conf" ]; then expected_line "$(conf_field "$conf" PACKAGE_NAME)" "$(conf_field "$conf" PACKAGE_VERSION)" "$(conf_modules "$conf")"; else echo "missing-vpu/0 missing"; fi
        conf="$REPO/assets/kernel/panthor/dkms.conf"
        if [ -f "$conf" ]; then expected_line "$(conf_field "$conf" PACKAGE_NAME)" "$(conf_field "$conf" PACKAGE_VERSION)" "$(conf_modules "$conf")"; else echo "missing-panthor/0 missing"; fi
    )"

    if [ "$(printf '%s\n' "$actual" | sort)" != "$expected" ]; then
        fail "DKMS MANIFEST MISMATCH"
        echo "Expected:" >&2
        printf '%s\n' "$expected" | sed 's/^/  /' >&2
        echo "Actual from registration sources:" >&2
        printf '%s\n' "$actual" | sort | sed 's/^/  /' >&2
    fi

    grep -Eq 'dkms add -m cix-gpu-kmd -v "\$DKMS_VER"' "$REPO/post-install/82-mali-gpu.sh" \
        || fail "MISSING REGISTRATION: post-install/82-mali-gpu.sh:cix-gpu-kmd"
    grep -Eq 'PKG_NAME=panthor-cix' "$REPO/post-install/83-panthor-gpu.sh" \
        || fail "MISSING REGISTRATION: post-install/83-panthor-gpu.sh:panthor-cix"
    grep -Eq 'dkms add -m aipu -v 6\.2\.0' "$REPO/post-install/86-cix-dkms-register.sh" \
        || fail "MISSING REGISTRATION: post-install/86-cix-dkms-register.sh:aipu/6.2.0"
    grep -Eq 'register "VPU" vpu cix-vpu-driver' "$REPO/post-install/86-cix-dkms-register.sh" \
        || fail "MISSING REGISTRATION: post-install/86-cix-dkms-register.sh:cix-vpu-driver"

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        pkgver="${line%%[[:space:]]*}"
        mods="${line#*[[:space:]]}"
        case "$pkgver" in
            */*) ;;
            *) fail "MALFORMED DKMS PACKAGE/VERSION: $line"; continue ;;
        esac
        [ -n "$mods" ] && [ "$mods" != "$line" ] || fail "MISSING MODULE LIST: $line"
    done < <(manifest_lines)
}

module_path() {
    local mod="$1"
    if [ "$ROOT" = "/" ]; then
        modinfo -k "$KVER" -n "$mod" 2>/dev/null || true
    else
        modinfo -b "$ROOT" -k "$KVER" -n "$mod" 2>/dev/null || \
            find "$(strip_root "/lib/modules/$KVER")" "$(strip_root "/usr/lib/modules/$KVER")" \
                -type f \( -name "$mod.ko" -o -name "$mod.ko.xz" -o -name "$mod.ko.zst" -o -name "$mod.ko.gz" \) \
                2>/dev/null | head -1 || true
    fi
}

assert_dkms_module_path() {
    local mod="$1" path="$2" context="$3"
    case "$path" in
        */updates/dkms/*)
            ok "$context $mod resolves to DKMS path $path"
            ;;
        */kernel/drivers/media/platform/cix/amvx.ko*)
            fail "$context $mod RESOLVES TO UNVALIDATED IN-TREE FALLBACK: $path (expected updates/dkms/amvx.ko*)"
            ;;
        *)
            fail "$context $mod NOT FROM DKMS for $KVER: $path"
            ;;
    esac
}

is_loaded() {
    local mod="$1"
    lsmod | awk '{print $1}' | grep -qxF "$mod"
}

cmdline_blacklists_module() {
    local mod="$1" token value item old_ifs
    for token in $(cat /proc/cmdline 2>/dev/null || true); do
        case "$token" in
            module_blacklist=*)
                value="${token#module_blacklist=}"
                old_ifs="$IFS"
                IFS=,
                for item in $value; do
                    if [ "$item" = "$mod" ]; then
                        IFS="$old_ifs"
                        return 0
                    fi
                done
                IFS="$old_ifs"
                ;;
        esac
    done
    return 1
}

dkms_status_for() {
    local pkg="$1" ver="$2"
    if [ "$ROOT" = "/" ]; then
        dkms status -m "$pkg" -v "$ver" 2>/dev/null || true
    elif [ -x "$ROOT/usr/sbin/dkms" ] || [ -x "$ROOT/usr/bin/dkms" ]; then
        chroot "$ROOT" dkms status -m "$pkg" -v "$ver" 2>/dev/null || true
    else
        find "$(strip_root "/var/lib/dkms/$pkg/$ver")" -mindepth 1 -maxdepth 2 \
            -type d -path "*/$KVER/*" -printf "$pkg/$ver, $KVER: built\n" 2>/dev/null || true
    fi
}

runtime_check() {
    if [ "$ROOT" = "/" ]; then
        command -v dkms >/dev/null 2>&1 || die "dkms binary not found"
    fi
    command -v modinfo >/dev/null 2>&1 || die "modinfo binary not found"
    command -v modprobe >/dev/null 2>&1 || die "modprobe binary not found"
    [ -d "$(strip_root "/lib/modules/$KVER")" ] || [ -d "$(strip_root "/usr/lib/modules/$KVER")" ] \
        || die "module tree not found for $KVER under $ROOT"

    if [ "$LIVE_LOAD" = 1 ] && [ "$KVER" != "$(uname -r)" ]; then
        die "--live-load can only run against the running kernel ($(uname -r)), not $KVER"
    fi

    newly_loaded=""
    temporarily_unloaded=""
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        pkgver="${line%%[[:space:]]*}"
        pkg="${pkgver%/*}"
        ver="${pkgver#*/}"
        mods="${line#*[[:space:]]}"

        if ! dkms_status_for "$pkg" "$ver" | grep -F "$KVER" | grep -Eq 'installed|built'; then
            fail "DKMS NOT BUILT FOR $KVER: $pkg/$ver"
        else
            ok "dkms has $pkg/$ver for $KVER"
        fi

        for mod in $mods; do
            path="$(module_path "$mod")"
            if [ -z "$path" ] || [ ! -e "$path" ]; then
                fail "MODULE NOT FOUND for $KVER: $mod ($pkg/$ver)"
                continue
            fi
            assert_dkms_module_path "$mod" "$path" "modinfo"
            vm="$(modinfo -F vermagic "$path" 2>/dev/null | awk '{print $1}')"
            if [ "$vm" != "$KVER" ]; then
                fail "VERMAGIC MISMATCH: $mod ($path) has '${vm:-<empty>}' expected '$KVER'"
            else
                ok "$mod vermagic matches $KVER"
            fi
            modprobe_args=(-S "$KVER" -n -v "$mod")
            [ "$ROOT" = "/" ] || modprobe_args=(-d "$ROOT" "${modprobe_args[@]}")
            if ! modprobe "${modprobe_args[@]}" >/dev/null 2>&1; then
                fail "MODPROBE DRY-RUN FAIL: $mod for $KVER"
            fi
            if [ "$LIVE_LOAD" = 1 ]; then
                if cmdline_blacklists_module "$mod"; then
                    fail "LIVE MODPROBE BLOCKED: $mod is present in kernel cmdline module_blacklist; boot an entry that permits $mod before --live-load"
                fi
                # DKMS source order is the static manifest contract. The live
                # Mali probe order is different: kbase expects both helpers.
                if [ "$pkg" = "cix-gpu-kmd" ] && [ "$mod" = "mali_kbase" ]; then
                    for helper in memory_group_manager protected_memory_allocator; do
                        if is_loaded "$helper"; then
                            :
                        elif modprobe "$helper" >/dev/null 2>&1; then
                            newly_loaded="$helper $newly_loaded"
                        fi
                    done
                fi
                if [ "$mod" = "panthor" ]; then
                    # The default vendor-GPU boot may already have the mutually
                    # exclusive Mali stack loaded. Remove zero-use Mali modules
                    # before the panthor insertion test; if removal fails, the
                    # panthor live-load must fail rather than being masked.
                    for gpu_mod in mali_kbase protected_memory_allocator memory_group_manager; do
                        if is_loaded "$gpu_mod"; then
                            if modprobe -r "$gpu_mod" >/tmp/verify-dkms-modules.$mod.unload-$gpu_mod.log 2>&1; then
                                temporarily_unloaded="$gpu_mod $temporarily_unloaded"
                            else
                                fail "LIVE MODPROBE BLOCKED: $mod cannot unload conflicting $gpu_mod (see /tmp/verify-dkms-modules.$mod.unload-$gpu_mod.log)"
                            fi
                        fi
                    done
                fi
                if is_loaded "$mod"; then
                    ok "$mod already loaded"
                elif modprobe --first-time "$mod" >/tmp/verify-dkms-modules.$mod.log 2>&1; then
                    ok "$mod live-load succeeded"
                    newly_loaded="$mod $newly_loaded"
                else
                    fail "LIVE MODPROBE FAIL: $mod (see /tmp/verify-dkms-modules.$mod.log)"
                fi
                live_path="$(modinfo -k "$KVER" -n "$mod" 2>/dev/null || true)"
                if [ -z "$live_path" ]; then
                    fail "LIVELOAD SOURCE UNKNOWN: $mod (modinfo -n returned empty)"
                else
                    assert_dkms_module_path "$mod" "$live_path" "LIVELOAD source"
                fi
            fi
        done
    done < <(manifest_lines)

    for mod in $newly_loaded; do
        modprobe -r "$mod" >/dev/null 2>&1 || true
    done
    for mod in $temporarily_unloaded; do
        modprobe "$mod" >/dev/null 2>&1 || true
    done
}

static_check
if [ -n "$KVER" ]; then
    runtime_check
fi

if [ "$FAILED" -ne 0 ]; then
    echo "verify-dkms-modules: FAIL" >&2
    exit 1
fi

echo "verify-dkms-modules: PASS"
