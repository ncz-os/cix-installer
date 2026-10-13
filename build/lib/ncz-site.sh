# shellcheck shell=bash
# ncz-site.sh -- per-site (per-build-host) settings for the project's own
# infrastructure: artifact store mount points, build hosts, push targets.
#
# Nothing site-specific is hardcoded in the build tooling. A value comes from
#   1. its environment variable, when set and non-empty, else
#   2. the first line of "${XDG_CONFIG_HOME:-$HOME/.config}/ncz/<name>", else
#   3. nothing (empty) -- the caller decides whether that is fatal or a skip.
#
# Settings used by the tooling (env var -> file name under ~/.config/ncz/):
#   NCZ_YOCTO_SHARED_DIR       yocto-shared-dir        shared Yocto export root
#                                                      (downloads/, sstate-cache/,
#                                                      kernel-staging/)
#   NCZ_BUILD_INPUTS_DIR       build-inputs-dir        pinned build-inputs store
#   NCZ_SUBSTRATE_CACHE_DIRS   substrate-cache-dir     pinned netinst ISO cache
#   NCZ_IMAGE_ARCHIVE          image-archive-dir       gated image archive
#   NCZ_SSPLUGIN_SRC_ROOT      projects-dir            store "projects" root
#   NCZ_VENDOR_ARCHIVE_DIR     vendor-archive-dir      vendor SDK / bake-asset archive
#   NCZ_AMD64_HOST             amd64-build-host        ssh host for --arch both
#   NCZ_ARM64_HOST             arm64-build-host        ssh host for --arch both
#   NCZ_STORE_SSH_COMMAND      store-ssh-command       GIT_SSH_COMMAND for the
#                                                      store's git remotes
#
# Usage: . build/lib/ncz-site.sh; dir="$(ncz_site_value NCZ_IMAGE_ARCHIVE image-archive-dir)"

ncz_site_value() {
    local var="$1" name="$2" v="" f
    v="${!var:-}"
    if [ -z "$v" ]; then
        f="${XDG_CONFIG_HOME:-${HOME:-}/.config}/ncz/$name"
        if [ -r "$f" ]; then
            IFS= read -r v < "$f" || true
        fi
    fi
    printf '%s' "$v"
}

# ncz_kernel_pool_alt PATH -- PATH points into a kernel-staging pool under some
# host's mount spelling (e.g. a committed assets/kernel/mainline symlink). Print
# the same entry under this host's NCZ_YOCTO_SHARED_DIR, or nothing.
ncz_kernel_pool_alt() {
    local p="$1" root
    root="$(ncz_site_value NCZ_YOCTO_SHARED_DIR yocto-shared-dir)"
    [ -n "$root" ] || return 0
    case "$p" in
        */kernel-staging/*) printf '%s/kernel-staging/%s' "${root%/}" "${p#*/kernel-staging/}" ;;
        */kernel-staging) printf '%s/kernel-staging' "${root%/}" ;;
    esac
}
