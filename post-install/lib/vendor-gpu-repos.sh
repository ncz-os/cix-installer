#!/bin/bash
# vendor-gpu-repos.sh -- the "pull GPU/NPU drivers from each vendor's own apt
# repository at install time" layer for AMD64. SOURCE this file; it defines
# functions and constants only (no side effects at source time), so
# build/test-gpu-vendor-repos.sh can exercise every row with sysfs fixtures
# and a stubbed apt.
#
# WHY THIS FILE EXISTS (operator 2026-10-29): "the GPU driver stuff should be
# dynamically pulled from nvidia, amd, and intel", "NPU as well", "most of
# this should already be built in". Most of it was: NVIDIA's dynamic driver +
# CUDA path (assets/nvidia/ncz-cuda-setup + lib/cuda-select.sh), the Intel
# NPU/OpenVINO set from the NCZ R2 repo (lib/intel-accel.sh), the AMD XDNA
# NPU from the NCZ suite (lib/amd-accel.sh) and the 7.3 DKMS patch all
# existed. The real gaps this file closes:
#
#   1. AMD's ROCm userspace had no vendor-repo path at all. 54-gpu-accel.sh
#      installed Debian-native ROCm packages and actively DELETED any
#      repo.radeon.com source ("no AMD Ubuntu repository"), so a ROCm-
#      capable GPU got no AMD-published userspace. AMD publishes no Debian
#      suite, so this file pins the vendor's Ubuntu-suite repo as a THIRD
#      origin that only supplies ROCm package NAMES, never Ubuntu-built
#      Debian-named packages (the provenance gate stays green -- see
#      NCZ_APT_ROCM_HOST in lib/apt-separation.sh and the -
#      1 pin row this file's contract requires).
#   2. Vendor source + key selection was inlined per vendor. This file is the
#      single answer to "which repo, which key, which packages, for the GPUs
#      actually present", so the desktop and server paths cannot drift.
#   3. There was no shared, tested "vendor step is non-fatal but loud"
#      primitive: every vendor block rolled its own rc handling.
#
# CONTRACT (what the caller and the tests rely on):
#   * Nothing here is fatal. Every entry point returns 0 on success and 0 on
#     a vendor outage too -- a failed step records a status line under
#     /var/lib/ncz/gpu-vendor.status and prints a "VENDOR-... :" line on
#     stderr, then returns. The caller decides whether a status is
#     transient (retry) or terminal. This is what "an outage leaves a
#     working console system" means.
#   * A source is only ever written with `signed-by=<keyring>` and only for
#     an exact (host, path, suite) row in manifests/vendor-repos.tsv
#     (approved=yes). ncz_gpu_vendor_repo_row() is the single chooser; the
#     test asserts its output against the committed allowlist.
#   * Never amdgpu-dkms. Our kernel is 7.3 and ships amdgpu in-tree; a
#     vendor DKMS build would replace a working in-tree driver with one that
#     may not build. ncz_gpu_amd_rocm_pkgs() filters it out by name, and the
#     test asserts it.
#   * Ubuntu-suite vendor repos (amd) may only supply ROCm names. The
#     apt-separation pin gives the AMD vendor host Pin-Priority -1 so no
#     Ubuntu-built Debian-named package can win, and the provenance gate
#     rejects the image if it does. ncz_gpu_vendor_is_ubuntu_suite() tells
#     the caller which repos are in that class.
#
# Detection is delegated to lib/pci-sysfs.sh (never lspci: a config-space
# read of a wedged GPU blocks in D state -- the GU502LV hang, 2026-10-06)
# and lib/npu-detect.sh. Fixtures are plain sysfs trees, which is what the
# unit test builds.
#
# Test seams: NCZ_GPU_VENDOR_ROOT (prefix for every file path this lib
# writes), NCZ_PCI_DEVICES_ROOT / NCZ_ACCEL_ROOT / NCZ_DRM_ROOT (detection
# fixtures), NCZ_GPU_VENDOR_APT_GET / _APT_KEY / _DPKG (command stand-ins),
# NCZ_GPU_VENDOR_NET (0 = pretend the vendor host is unreachable).

# ---------------------------------------------------------------------------
# Vendor repository catalogue. One row per published source this installer
# may write. These MUST match manifests/vendor-repos.tsv exactly (the test
# cross-checks); the allowlist there is the reviewed decision, this is the
# executable copy.
#
# Columns (TAB): vendor, id, scheme, host, path, suite, keyring, key-source
#   keyring    where the Signed-By keyring lives on the target
#   key-source "nvidia-keyring-deb" (NVIDIA's own cuda-keyring package),
#              "asset:<name>" (a key committed under assets/), or
#              "fetch:<url>" (the vendor's published key, fetched at install)
# ---------------------------------------------------------------------------
NCZ_GPU_VENDOR_CATALOGUE='
nvidia	deb13	https	developer.download.nvidia.com	/compute/cuda/repos/debian13/x86_64/	/	/usr/share/keyrings/ncz-nvidia-cuda.gpg	nvidia-keyring-deb
nvidia	deb12	https	developer.download.nvidia.com	/compute/cuda/repos/debian12/x86_64/	/	/usr/share/keyrings/ncz-nvidia-cuda-debian12.gpg	asset:cuda-archive-keyring-debian12.gpg
amd	rocm	https	repo.radeon.com	/rocm/apt/7.2/	noble	/etc/apt/keyrings/ncz-amd-rocm.gpg	fetch:https://repo.radeon.com/rocm/rocm.gpg
'

# Suites that are Ubuntu-named and may therefore only supply the vendor's
# own package names (never a Debian-named package). Checked by
# ncz_gpu_vendor_is_ubuntu_suite and by the apt-separation pin.
NCZ_GPU_VENDOR_UBUNTU_SUITES='noble jammy focal bionic'

_ngv_r()  { printf '%s' "${NCZ_GPU_VENDOR_ROOT:-}"; }
_ngv_state() { printf '%s/var/lib/ncz' "$(_ngv_r)"; }
ngv_status_file() { printf '%s/gpu-vendor.status' "$(_ngv_state)"; }

ncz_gpu_vendor_log() { echo "[gpu-vendor] $*"; }
# Loud, never fatal: one line on stderr and one recorded status line. The
# status file keeps the LAST outcome per vendor so a later
# `ncz-gpu-status`/support call can answer "did the AMD repo work?".
ncz_gpu_vendor_warn() {  # warn VENDOR REASON
    echo "VENDOR-${1^^}: $2" >&2
    ncz_gpu_vendor_record "$1" "warn:$2"
    return 0
}
ncz_gpu_vendor_record() {  # record VENDOR STATUS
    local d; d=$(_ngv_state)
    mkdir -p "$d" 2>/dev/null || return 0
    # Rewrite the vendor's line, preserving the others (no temp file, no
    # shared /tmp; the file is small and single-writer per install).
    local f; f=$(ngv_status_file)
    if [ -f "$f" ]; then
        grep -v "^$1	" "$f" > "$f.ncz" 2>/dev/null && mv "$f.ncz" "$f" 2>/dev/null || rm -f "$f.ncz"
    fi
    printf '%s\t%s\t%s\n' "$1" "$2" "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" >> "$f" 2>/dev/null || true
    return 0
}

# ncz_gpu_vendor_apt() -- the apt front end, overridable for tests.
ncz_gpu_vendor_apt_get() { "${NCZ_GPU_VENDOR_APT_GET:-apt-get}" "$@"; }

# ---------------------------------------------------------------------------
# Catalogue queries
# ---------------------------------------------------------------------------

# ncz_gpu_vendor_row VENDOR ID -> the catalogue row's fields, TAB separated, on
# stdout. Returns 1 when the vendor/id is unknown (never guesses a repo).
# The loop runs in THIS shell (no subshell) so `return` gives the real status.
ncz_gpu_vendor_row() {
    local want_v="$1" want_i="$2" line v i scheme host path suite keyring ksrc
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS="$(printf '\t')" read -r v i scheme host path suite keyring ksrc <<EOF
$line
EOF
        [ -n "${v:-}" ] || continue
        if [ "$v" = "$want_v" ] && [ "$i" = "$want_i" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$v" "$i" "$scheme" "$host" "$path" "$suite" "$keyring" "$ksrc"
            return 0
        fi
    done <<EOF
$NCZ_GPU_VENDOR_CATALOGUE
EOF
    return 1
}

# ncz_gpu_vendor_is_ubuntu_suite SUITE -> 0 when the suite is one of the
# vendor's Ubuntu labels. Such a repo may supply only ROCm-named packages.
ncz_gpu_vendor_is_ubuntu_suite() {
    case " $NCZ_GPU_VENDOR_UBUNTU_SUITES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# ncz_gpu_vendor_source_line VENDOR ID -> the exact deb line to write
# (Signed-By always present). Returns 1 for an unknown row.
ncz_gpu_vendor_source_line() {
    local row; row=$(ncz_gpu_vendor_row "$1" "$2") || return 1
    local scheme host path suite keyring
    IFS="$(printf '\t')" read -r _ _ scheme host path suite keyring _ <<EOF
$row
EOF
    [ -n "$keyring" ] || return 1
    printf 'deb [arch=amd64 signed-by=%s] %s://%s%s %s\n' "$keyring" "$scheme" "$host" "$path" "$suite"
}

# ncz_gpu_vendor_sources_file VENDOR ID -> the target path the deb line is
# written to under /etc/apt/sources.list.d.
ncz_gpu_vendor_sources_file() {
    printf '%s/etc/apt/sources.list.d/ncz-vendor-%s-%s.list' "$(_ngv_r)" "$1" "$2"
}

# ncz_gpu_vendor_repo_row VENDOR ID -> the matching manifests/vendor-repos.tsv
# row (TAB separated) from the committed allowlist, or nothing when it is not
# approved. This is the "is this source reviewed?" answer; the caller must
# refuse to write a line without it. Test seam: NCZ_GPU_VENDOR_MANIFESTS_DIR
# (the unit test points it at a fixture when it wants to prove refusal).
ncz_gpu_vendor_repo_row() {
    local dir="${NCZ_GPU_VENDOR_MANIFESTS_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../manifests}"
    local f="$dir/vendor-repos.tsv"
    [ -r "$f" ] || return 1
    local row; row=$(ncz_gpu_vendor_row "$1" "$2") || return 1
    local scheme host path suite
    IFS="$(printf '\t')" read -r _ _ scheme host path suite _ _ <<EOF
$row
EOF
    # manifests/vendor-repos.tsv columns are exactly:
    #   kind scheme host path suite approved vendor note
    # (there is no `id` column -- the id lives only in the catalogue).
    # So the matched fields are $2..$5 and approved is $6.
    awk -F'\t' -v s="$scheme" -v h="$host" -v p="$path" -v u="$suite" '
        /^#/ || NF < 7 { next }
        $2 == s && $3 == h && $4 == p && $5 == u && $6 == "yes" { print; found=1 }
        END { exit(found ? 0 : 1) }
    ' "$f"
}

# ---------------------------------------------------------------------------
# Key material
# ---------------------------------------------------------------------------

# ncz_gpu_vendor_install_key VENDOR ID -> 0 when the keyring for the row now
# exists, 1 otherwise. Never prints a secret; the vendor key is public.
ncz_gpu_vendor_install_key() {
    local row; row=$(ncz_gpu_vendor_row "$1" "$2") || return 1
    local v i scheme host path suite keyring ksrc
    IFS="$(printf '\t')" read -r v i scheme host path suite keyring ksrc <<EOF
$row
EOF
    # `keyring` is an absolute install path (/usr/share/keyrings/...,
    # /etc/apt/keyrings/...). It must NOT be prefixed with the vendor root:
    # NCZ_GPU_VENDOR_ROOT is a staging prefix for the apt/sources files, but
    # the keyring is where apt will look at run time. A non-empty root would
    # otherwise produce nonsense such as /opt/stage/usr/share/keyrings/...
    local dest="$keyring"
    case "$ksrc" in
        nvidia-keyring-deb)
            # NVIDIA ships its own keyring PACKAGE, pre-staged in the asset
            # bundle. Installing it also writes the vendor's own
            # /usr/share/keyrings/cuda-archive-keyring.gpg, which the deb
            # line's Signed-By points at in the vendor's preferred shape; we
            # additionally copy it to our own path so a later `apt purge
            # cuda-keyring` cannot leave a dangling Signed-By.
            local deb="${NCZ_GPU_VENDOR_ASSETS:-$(_ngv_r)/usr/local/lib/cix-installer/assets/nvidia}/cuda-keyring_1.1-1_all.deb"
            [ -f "$deb" ] || { ncz_gpu_vendor_warn "$v" "keyring package $deb is not staged"; return 1; }
            "${NCZ_GPU_VENDOR_DPKG:-dpkg}" -i "$deb" >/dev/null 2>&1 || true
            local src
            src="$(_ngv_r)/usr/share/keyrings/cuda-archive-keyring.gpg"
            if [ -r "$src" ]; then
                mkdir -p "$(dirname "$dest")" 2>/dev/null || true
                cp -f "$src" "$dest" 2>/dev/null || true
            fi
            ;;
        asset:*)
            local name="${ksrc#asset:}"
            local asset="${NCZ_GPU_VENDOR_ASSETS:-$(_ngv_r)/usr/local/lib/cix-installer/assets/nvidia}/$name"
            [ -f "$asset" ] || { ncz_gpu_vendor_warn "$v" "key $asset is not staged"; return 1; }
            mkdir -p "$(dirname "$dest")" 2>/dev/null || true
            cp -f "$asset" "$dest" 2>/dev/null || true
            ;;
        fetch:*)
            local url="${ksrc#fetch:}"
            mkdir -p "$(dirname "$dest")" 2>/dev/null || true
            if ! _ncz_gpu_vendor_fetch "$url" "$dest.tmp"; then
                rm -f "$dest.tmp" 2>/dev/null || true
                ncz_gpu_vendor_warn "$v" "key could not be fetched from $url"; return 1
            fi
            # A key that does not parse is worse than no key: apt would then
            # reject every index for the repo and the operator would read it
            # as "the vendor repo is broken".
            local gpgbin; gpgbin=$(command -v gpg 2>/dev/null || true)
            if [ -n "$gpgbin" ] && ! "$gpgbin" --show-keys "$dest.tmp" >/dev/null 2>&1; then
                rm -f "$dest.tmp" 2>/dev/null || true
                ncz_gpu_vendor_warn "$v" "fetched key from $url does not parse"; return 1
            fi
            mv -f "$dest.tmp" "$dest" 2>/dev/null || { ncz_gpu_vendor_warn "$v" "could not install $dest"; return 1; }
            ;;
        *)
            ncz_gpu_vendor_warn "$v" "unknown key source '$ksrc'"; return 1
            ;;
    esac
    [ -s "$dest" ] || { ncz_gpu_vendor_warn "$v" "keyring $dest is missing after install"; return 1; }
    return 0
}

# _ncz_gpu_vendor_fetch URL DEST -> 0 on success. Overridable command
# (NCZ_GPU_VENDOR_CURL) so tests never touch the network; NCZ_GPU_VENDOR_NET=0
# models "the vendor host is down".
_ncz_gpu_vendor_fetch() {
    [ "${NCZ_GPU_VENDOR_NET:-1}" = 1 ] || return 1
    local curl; curl="${NCZ_GPU_VENDOR_CURL:-$(command -v curl 2>/dev/null || true)}"
    [ -n "$curl" ] || return 1
    "$curl" -fsSL --max-time "${NCZ_GPU_VENDOR_FETCH_TIMEOUT:-30}" -o "$2" "$1" 2>/dev/null
}

# ncz_gpu_vendor_write_source VENDOR ID -> 0 when the deb line is in place.
# Refuses (loudly, non-fatally) when the row is not in the reviewed allowlist
# or the key is absent: an unverified source must never be written.
ncz_gpu_vendor_write_source() {
    local v="$1" i="$2" line f
    if ! ncz_gpu_vendor_repo_row "$v" "$i" >/dev/null; then
        ncz_gpu_vendor_warn "$v" "source $v/$i is not an approved row in manifests/vendor-repos.tsv; not written"
        return 1
    fi
    line=$(ncz_gpu_vendor_source_line "$v" "$i") || { ncz_gpu_vendor_warn "$v" "no catalogue row"; return 1; }
    ncz_gpu_vendor_install_key "$v" "$i" || return 1
    f=$(ncz_gpu_vendor_sources_file "$v" "$i")
    mkdir -p "$(dirname "$f")" 2>/dev/null || true
    printf '%s\n' "$line" > "$f" 2>/dev/null || { ncz_gpu_vendor_warn "$v" "cannot write $f"; return 1; }
    ncz_gpu_vendor_log "$v: source $f = $line"
    return 0
}

# ---------------------------------------------------------------------------
# AMD: which GPUs are ROCm-capable, and which ROCm packages to install
# ---------------------------------------------------------------------------

# ROCm-capable AMD GPU device IDs (1002:xxxx) -- the gfx targets ROCm's
# official support matrix lists, by PCI device id, verified against AMD's
# "ROCm compatibility matrix" and the amdgpu driver's pci table. This is a
# SUPPORT decision, not a detection: an AMD GPU absent from this list still
# gets in-kernel amdgpu + Debian forky Mesa/firmware, it just does not get
# AMD's ROCm userspace. Keep it small and justified; never add an id "to be
# safe" (an unsupported ROCm install is a broken compute stack).
#   Navi 31/32/33 (RDNA3)  744c 73bf 73df 73ef 73ff 7470 747e 7480 7483 749f (workstation 74a0 74a1)
#   Navi 21/22/23 (RDNA2)  73a0 73a2 73a3 73a5 73af 73bf 73c0 73c1 73c3 73cf 73d0 73d1 73e0 73ff
#   Navi 10/12/14 (RDNA1)  7310 7312 731f 7340 7341 7347 734f 7360 7362 7367
#   Vega 20 (MI50/60)      66a0 66a1 66a2 66a3 66a7 66af
#   MI100/MI200/MI300       738c 738e 7408 740c 740f 74a0 74a1 74a2 74a5 74a9 74b5 74bd
NCZ_GPU_AMD_ROCM_IDS='
744c 73bf 73df 73ef 73ff 7470 747e 7480 7483 749f 74a0 74a1
73a0 73a2 73a3 73a5 73af 73c0 73c1 73c3 73cf 73d0 73d1 73e0
7310 7312 731f 7340 7341 7347 734f 7360 7362 7367
66a0 66a1 66a2 66a3 66a7 66af
738c 738e 7408 740c 740f 74a2 74a5 74a9 74b5 74bd
'

# ncz_gpu_amd_rocm_capable ID -> 0 when the 4-hex AMD device id is on the
# ROCm support list.
ncz_gpu_amd_rocm_capable() {
    local id="${1,,}"
    case "$id" in
        [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac
    printf '%s\n' $NCZ_GPU_AMD_ROCM_IDS | grep -qx "$id"
}

# ncz_gpu_amd_rocm_ids [DEVICE-LIST-FILE] -> the ROCm-capable AMD device ids
# present on this machine (one per line, sorted, unique). Reads the
# pci-sysfs device list, so it works from a fixture directory too.
ncz_gpu_amd_rocm_ids() {
    local devs id
    devs=$(ncz_gpu_vendor_pci_devices "${1:-}") || return 1
    for id in $(printf '%s\n' "$devs" | awk '$2 ~ /^03/ && $3 == "1002" { print $4 }' | sort -u); do
        ncz_gpu_amd_rocm_capable "$id" && printf '%s\n' "$id"
    done
}

# The ROCm userspace this installer requests from AMD's repo. Deliberately
# NOT: amdgpu-dkms (our 7.3 kernel ships amdgpu in-tree; the vendor DKMS
# would replace a working driver), rocm (the full meta, pulls amdgpu-dkms),
# and any library the in-kernel driver already provides.
NCZ_GPU_AMD_ROCM_PKGS='rocm-hip-runtime rocm-opencl-runtime rocminfo rocm-smi-lib'
# Names that must NEVER be installed from the AMD repo even though it offers
# them. Filtered by name in ncz_gpu_amd_rocm_pkgs; asserted by the test.
NCZ_GPU_AMD_ROCM_DENY='amdgpu-dkms amdgpu-dkms-firmware rocm rocm-dev rocm-libs'

# ncz_gpu_amd_rocm_pkgs -> the package list to request, with every denied
# name filtered out. Returns 0 and prints a possibly-empty list (an empty
# list is a valid "nothing to do", never an error).
ncz_gpu_amd_rocm_pkgs() {
    local p out=""
    for p in $NCZ_GPU_AMD_ROCM_PKGS; do
        case " $NCZ_GPU_AMD_ROCM_DENY " in *" $p "*) continue ;; esac
        out="$out $p"
    done
    printf '%s\n' $out
}

# ncz_gpu_amd_rocm_removals PKGS... -> prints one line per package name the
# transaction would violate (`Remv ` lines that touch a packaged driver),
# which is the refusal condition. Two rules:
#   * any `Remv amdgpu-dkms`-class package is a refusal (we must never
#     replace the in-tree driver);
#   * more than NCZ_GPU_AMD_ROCM_MAX_REMOVALS removals overall is a refusal
#     (the AMD repo must not reshuffle the base system).
# Input is `apt-get install -s` output on stdin.
NCZ_GPU_AMD_ROCM_MAX_REMOVALS=${NCZ_GPU_AMD_ROCM_MAX_REMOVALS:-0}
ncz_gpu_amd_rocm_removals() {
    local n; n=$(grep -c '^Remv ' 2>/dev/null || true)
    n=${n:-0}
    if [ "$n" -gt "${NCZ_GPU_AMD_ROCM_MAX_REMOVALS}" ]; then
        grep '^Remv ' | head -5
        return 1
    fi
    return 0
}

# ncz_gpu_vendor_add_amd_rocm -> 0 when AMD's ROCm repo was added AND its
# userspace installed (or was already), 1 on any vendor-side failure. NEVER
# fatal: the caller keeps the Debian forky stack either way. Also refuses
# when the GPU set contains no ROCm-capable id (writing the source for a
# machine that cannot use it would pollute apt on every AMD box).
ncz_gpu_vendor_add_amd_rocm() {
    local ids pkgs sim rc
    ids=$(ncz_gpu_amd_rocm_ids) || ids=""
    if [ -z "$ids" ]; then
        ncz_gpu_vendor_record amd "skipped:no-rocm-capable-gpu"
        return 1
    fi
    ncz_gpu_vendor_log "ROCm-capable AMD GPU(s): $(printf '%s ' $ids)"
    if ! ncz_gpu_vendor_write_source amd rocm; then
        ncz_gpu_vendor_record amd "warn:repo-not-writable"
        return 1
    fi
    ncz_gpu_vendor_record amd "repo-added"
    # Refresh ONLY to learn the new index; a failure here is an outage, and
    # the Debian stack stays as-is.
    if ! ncz_gpu_vendor_apt_get update >/dev/null 2>&1; then
        ncz_gpu_vendor_warn amd "apt-get update failed after adding repo.radeon.com; keeping the Debian stack"
        return 1
    fi
    pkgs=$(ncz_gpu_amd_rocm_pkgs)
    [ -n "$pkgs" ] || { ncz_gpu_vendor_record amd "skipped:no-packages"; return 0; }
    # Simulation first: refuse any transaction that would remove packages,
    # above all anything in the amdgpu-dkms class.
    # shellcheck disable=SC2086
    sim=$(ncz_gpu_vendor_apt_get install -s -y --no-install-recommends $pkgs 2>&1) || {
        printf '%s\n' "$sim" | tail -5 >&2
        ncz_gpu_vendor_warn amd "the ROCm set is not installable from the vendor repo"
        return 1
    }
    if ! printf '%s\n' "$sim" | ncz_gpu_amd_rocm_removals; then
        ncz_gpu_vendor_warn amd "the ROCm set would remove installed packages; refused"
        return 1
    fi
    # shellcheck disable=SC2086
    if ! ncz_gpu_vendor_apt_get install -y --no-install-recommends $pkgs >/dev/null 2>&1; then
        ncz_gpu_vendor_warn amd "the ROCm set failed to install; keeping the Debian stack"
        return 1
    fi
    ncz_gpu_vendor_record amd "installed:$pkgs"
    return 0
}

# ---------------------------------------------------------------------------
# Detection helpers shared with the NPU path
# ---------------------------------------------------------------------------

# ncz_gpu_vendor_pci_devices [FILE] -> "<bdf> <class 2 hex> <vendor> <device>"
# per display-class or accelerator device. FILE, when given, is in the
# `lspci -nn` line shape that lib/pci-sysfs.sh emits (used by the unit
# test); otherwise the sysfs tree is read directly.
ncz_gpu_vendor_pci_devices() {
    local out
    if [ -n "${1:-}" ]; then
        out=$(cat "$1" 2>/dev/null) || return 1
    else
        if ! command -v ncz_pci_lspci_nn >/dev/null 2>&1; then
            # shellcheck source=post-install/lib/pci-sysfs.sh
            . "$(dirname "${BASH_SOURCE[0]}")/pci-sysfs.sh" 2>/dev/null || return 1
        fi
        out=$(ncz_pci_lspci_nn) || return 1
    fi
    # Normalise to "<bdf> <class4> <vendor> <device>" for every 03xx display
    # controller and 1200 processing accelerator.
    printf '%s\n' "$out" | sed -nE 's/^([0-9a-f:.]+) Class \[(03[0-9a-f]{2}|1200)\]: Device \[([0-9a-f]{4}):([0-9a-f]{4})\]$/\1 \2 \3 \4/p'
}

# ncz_gpu_vendor_accel_devices -> the accelerator devices the kernel exposes
# under /sys/class/accel (accel0, accel1, ...). Prints "<name> <vendor>
# <device>" when the accel class entry resolves back to a PCI device, which
# is how amdxdna and the Intel VPU/NPU driver present themselves. Returns 1
# when the class is absent (a kernel without CONFIG_DRM_ACCEL, or a chroot
# without /sys).
ncz_gpu_vendor_accel_devices() {
    local root="${NCZ_ACCEL_ROOT:-$(_ngv_r)/sys/class/accel}" d real ven dev n=0
    for d in "$root"/accel*; do
        [ -e "$d" ] || continue
        real=$(readlink -f "$d/device" 2>/dev/null) || continue
        ven=$(_ncz_gpu_vendor_sysfs_hex "$real/vendor") || continue
        dev=$(_ncz_gpu_vendor_sysfs_hex "$real/device") || continue
        printf '%s %s %s\n' "${d##*/}" "$ven" "$dev"
        n=$((n + 1))
    done
    [ "$n" -gt 0 ]
}

_ncz_gpu_vendor_sysfs_hex() {
    local v
    [ -r "$1" ] || return 1
    IFS= read -r v < "$1" 2>/dev/null || [ -n "$v" ] || return 1
    v=${v#0x}; v=${v#0X}
    [ -n "$v" ] || return 1
    printf '%s' "$v" | tr 'A-F' 'a-f'
}

# ncz_gpu_vendor_summary -> one line per detected accelerator with its vendor
# label, reused by the installer's progress output and the tests:
#   "<kind> <vendor> <id>"  kind = gpu|npu
# `none` (lowercase) when nothing matched, which the caller treats as a
# normal no-op.
ncz_gpu_vendor_summary() {
    local devs line cls ven dev any=0 gpu_vendors="" npu_vendors=""
    devs=$(ncz_gpu_vendor_pci_devices) || devs=""
    while IFS=' ' read -r _bdf cls ven dev; do
        [ -n "${ven:-}" ] || continue
        case "$cls" in
            03*)
                case "$ven" in
                    10de) gpu_vendors="$gpu_vendors nvidia" ;;
                    1002) gpu_vendors="$gpu_vendors amd" ;;
                    8086) gpu_vendors="$gpu_vendors intel" ;;
                    *) continue ;;
                esac
                ;;
            1200)
                case "$ven" in
                    8086) npu_vendors="$npu_vendors intel" ;;
                    1022) npu_vendors="$npu_vendors amd" ;;
                    *) continue ;;
                esac
                ;;
        esac
        any=1
    done <<EOF
$devs
EOF
    # Vendor-free de-duplication, stable order.
    for line in nvidia amd intel; do
        case " $gpu_vendors " in *" $line "*) printf 'gpu %s\n' "$line" ;; esac
    done
    for line in amd intel; do
        case " $npu_vendors " in *" $line "*) printf 'npu %s\n' "$line" ;; esac
    done
    [ "$any" = 1 ] || printf 'none\n'
    return 0
}
