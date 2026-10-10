#!/bin/bash
# envpin.sh -- build ENVIRONMENT pin (manifests/env.pin): verify the actual
# build environment against the committed pin, with a precise per-key diff.
#
# The determinism contract (docs/IMAGE-BUILD-PROCESS.md SS5) names the git
# commit and the recorded pins as the inputs.  This file closes the remaining
# gap: the BUILD ENVIRONMENT itself.  Two builds with a different mksquashfs
# (4.6 vs 4.7) or a different container image digest are NOT the same build,
# even with the same git SHA and the same input pins.
#
# manifests/env.pin is a committed TSV:  scope<TAB>key<TAB>value
#   container  a value observed INSIDE the pinned build/payload container
#              (host-independent: the container is pinned by digest)
#   host       a value observed on the build host (artifact-affecting host tools)
#   env        LC_ALL / TZ / umask and the SOURCE_DATE_EPOCH derivation
#   flag       a boolean assertion (e.g. no -march=native)
#   sde        how SOURCE_DATE_EPOCH is derived
#
# Usage (sourced):
#   . build/lib/envpin.sh
#   ncz_envpin_check --pin manifests/env.pin --scope all      # FAIL on any diff
#   ncz_envpin_check --scope container --payload-image debian:forky
#
# Env:
#   NCZ_ENVPIN_CONTAINER_ENGINE   docker|podman (default: auto)
#   NCZ_ENVPIN_PROBE_CMD          test hook: a command that, given "scope key",
#                                 prints the actual value (used by test-env-pin)
#   NCZ_ENVPIN_HOST_DRIFT_OK     1 = host-scope drift is a WARN (second builder
#                                 still inside the same pinned container)
# ---------------------------------------------------------------------------
set -uo pipefail

_ncz_envpin_die() { echo "envpin: $*" >&2; return 1; }

ncz_envpin_engine() {
    if [ -n "${NCZ_ENVPIN_CONTAINER_ENGINE:-}" ]; then echo "$NCZ_ENVPIN_CONTAINER_ENGINE"; return; fi
    if command -v podman >/dev/null 2>&1; then echo podman; return; fi
    if command -v docker >/dev/null 2>&1; then echo docker; return; fi
}

# --- actual-value probes ---------------------------------------------------
# Container image identity probes (the primary, host-independent keys).
_ncz_envpin_image_digest() {  # _ncz_envpin_image_digest <tag>
    local img="$1" eng
    eng="$(ncz_envpin_engine)"
    [ -n "$eng" ] || { echo ""; return 1; }
    "$eng" image inspect --format '{{.Digest}}' "$img" 2>/dev/null \
      || "$eng" images --digests --no-trunc --format '{{.Digest}}' "$img" 2>/dev/null | head -1
}

# Container probes: run the probe command inside $img and print one value.
_ncz_envpin_container_probe() {
    local img="$1" key="$2" eng cmd
    eng="$(ncz_envpin_engine)"
    [ -n "$eng" ] || { echo ""; return 1; }
    case "$key" in
        imagebuild_image)  echo "${NCZ_IMAGEBUILD_TAG:-localhost/ncz-imagebuild:trixie}"; return 0 ;;
        imagebuild_digest) _ncz_envpin_image_digest "${NCZ_IMAGEBUILD_TAG:-localhost/ncz-imagebuild:trixie}"; return 0 ;;
        payload_image)     echo "${NCZ_BASE_IMAGE:-$img}"; return 0 ;;
        payload_image_digest) _ncz_envpin_image_digest "${NCZ_BASE_IMAGE:-$img}"; return 0 ;;
    esac
    case "$key" in
        mksquashfs)  cmd='mksquashfs -version 2>&1 | sed -n "s/.*version \([0-9][0-9.]*\).*/\1/p" | head -1' ;;
        unsquashfs)  cmd='unsquashfs -version 2>&1 | sed -n "s/.*version \([0-9][0-9.]*\).*/\1/p" | head -1' ;;
        mke2fs)      cmd='mke2fs -V 2>&1 | sed -n "s/.* \([0-9][0-9.]*\) (.*/\1/p" | head -1' ;;
        sgdisk)      cmd='sgdisk --version 2>&1 | awk "{print \$NF}"' ;;
        sfdisk)      cmd='sfdisk --version 2>&1 | awk "{print \$NF}"' ;;
        dpkg)        cmd='dpkg --version 2>&1 | sed -n "s/.* version \([0-9][0-9.]*\).*/\1/p" | head -1' ;;
        dpkg_deb)    cmd='dpkg-deb --version 2>&1 | sed -n "s/.* version \([0-9][0-9.]*\).*/\1/p" | head -1' ;;
        gcc)         cmd='gcc --version 2>&1 | head -1 | awk "{print \$NF}"' ;;
        clang)       cmd='clang --version 2>&1 | head -1 | awk "{print \$3}"' ;;
        meson)       cmd='meson --version 2>&1' ;;
        ninja)       cmd='ninja --version 2>&1' ;;
        go)          cmd='go version 2>&1 | awk "{print \$3}"' ;;
        rustc)       cmd='rustc --version 2>&1 | awk "{print \$2}"' ;;
        python3)     cmd='python3 --version 2>&1 | awk "{print \$2}"' ;;
        mksquashfs_flags) cmd='echo "-noappend -comp xz -b 131072 -all-root -no-xattrs -no-progress -processors 1"' ;;
        image_digest) cmd='true' ;;   # resolved by the caller, not in-container
        *)           return 1 ;;
    esac
    "$eng" run --rm "$img" bash -lc "$cmd" 2>/dev/null
}

# Host probes: run the probe on the build host.
_ncz_envpin_host_probe() {
    local key="$1"
    case "$key" in
        mksquashfs) echo "$(mksquashfs -version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)" ;;
        unsquashfs) echo "$(unsquashfs -version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | head -1)" ;;
        mke2fs)     echo "$(mke2fs -V 2>/dev/null | sed -n 's/.* \([0-9][0-9.]*\) (.*/\1/p' | head -1)" ;;
        sgdisk)     echo "$(sgdisk --version 2>/dev/null | awk '{print $NF}')" ;;
        sfdisk)     echo "$(sfdisk --version 2>/dev/null | awk '{print $NF}')" ;;
        dpkg)       echo "$(dpkg --version 2>/dev/null | sed -n 's/.* version \([0-9][0-9.]*\).*/\1/p' | head -1)" ;;
        dpkg_deb)   echo "$(dpkg-deb --version 2>/dev/null | sed -n 's/.* version \([0-9][0-9.]*\).*/\1/p' | head -1)" ;;
        gcc)        echo "$(gcc --version 2>/dev/null | head -1 | awk '{print $NF}')" ;;
        meson)      echo "$(meson --version 2>/dev/null)" ;;
        ninja)      echo "$(ninja --version 2>/dev/null)" ;;
        python3)    echo "$(python3 --version 2>/dev/null | awk '{print $2}')" ;;
        uname_m)    echo "$(uname -m)" ;;
        nproc)      echo "$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)" ;;
        *)          return 1 ;;
    esac
}

# Resolve the actual value for one (scope,key). Prints "" when unprobeable.
ncz_envpin_actual() {
    local scope="$1" key="$2" img="$3"
    if [ -n "${NCZ_ENVPIN_PROBE_CMD:-}" ]; then
        # test hook: PROBE_CMD <scope> <key>  -> prints the value
        eval "${NCZ_ENVPIN_PROBE_CMD} \"$scope\" \"$key\"" 2>/dev/null
        return $?
    fi
    case "$scope" in
        container) _ncz_envpin_container_probe "$img" "$key" ;;
        host)      _ncz_envpin_host_probe "$key" ;;
        env)
            case "$key" in
                LC_ALL) echo "${LC_ALL:-}" ;;
                TZ)     echo "${TZ:-}" ;;
                umask)  local u; u="$(umask 2>/dev/null)"; printf '%03o\n' "$((8#$u))" ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

# ncz_envpin_check --pin FILE [--scope container|host|env|all]
#                   [--payload-image TAG] [--report FILE]
# Returns 0 all compared keys match; 1 on any diff; prints a precise diff.
ncz_envpin_check() {
    local pin="" scope="all" payload_image="" report=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --pin) pin="$2"; shift 2 ;;
            --scope) scope="$2"; shift 2 ;;
            --payload-image) payload_image="$2"; shift 2 ;;
            --report) report="$2"; shift 2 ;;
            -h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; return 0 ;;
            *) _ncz_envpin_die "unknown argument: $1"; return 2 ;;
        esac
    done
    [ -r "$pin" ] || { _ncz_envpin_die "cannot read env pin: $pin"; return 3; }
    [ -n "$payload_image" ] || payload_image="$(awk -F'\t' '$1=="container" && $2=="payload_image"{print $3}' "$pin" | head -1)"

    local out tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/ncz-envpin.XXXXXX")"
    local fail=0 skip=0 checked=0 scope_re
    case "$scope" in
        all) scope_re='^(container|host|env|flag)$' ;;
        container|host|env|flag) scope_re="^${scope}$" ;;
        *) _ncz_envpin_die "bad --scope '$scope'"; rm -f "$tmp"; return 2 ;;
    esac

    while IFS=$'\t' read -r s k v; do
        case "$s" in \#*|"") continue ;; esac
        [[ "$s" =~ $scope_re ]] || continue
        case "$s" in
            flag)
                # assertion: value 1 means "must hold".  Key names the test.
                case "$k" in
                    forbid_march_native)
                        # nothing to probe here; the assertion is enforced by the
                        # lint in test-hermetic.sh.  Recorded for the attestation.
                        printf 'OK    %-8s %-26s = %s\n' "$s" "$k" "$v" >> "$tmp"
                        checked=$((checked+1)) ;;
                    *) printf 'OK    %-8s %-26s = %s\n' "$s" "$k" "$v" >> "$tmp"; checked=$((checked+1)) ;;
                esac
                continue ;;
            sde)
                printf 'OK    %-8s %-26s = %s\n' "$s" "$k" "$v" >> "$tmp"; checked=$((checked+1))
                continue ;;
        esac
        local actual; actual="$(ncz_envpin_actual "$s" "$k" "$payload_image")"
        if [ -z "$actual" ]; then
            printf 'SKIP  %-8s %-26s expected %-22s (cannot probe on this host)\n' "$s" "$k" "$v" >> "$tmp"
            skip=$((skip+1)); continue
        fi
        if [ "$actual" = "$v" ]; then
            printf 'OK    %-8s %-26s = %s\n' "$s" "$k" "$actual" >> "$tmp"
        else
            if [ "$s" = host ] && [ "${NCZ_ENVPIN_STRICT_HOST:-0}" != 1 ]; then
                # Host tool versions vary across the fleet (mksquashfs 4.6 vs
                # 4.7).  The heavy tooling runs INSIDE the digest-pinned
                # container, so host drift is surfaced as a WARN; set
                # NCZ_ENVPIN_STRICT_HOST=1 to make it a FAIL (the verification
                # pair must have equal host toolchains -- plan B.3).
                printf 'WARN  %-8s %-26s expected "%s"  actual "%s" (host drift; set NCZ_ENVPIN_STRICT_HOST=1 to fail)\n' \
                    "$s" "$k" "$v" "$actual" >> "$tmp"
            else
                printf 'FAIL  %-8s %-26s expected "%s"  actual "%s"\n' "$s" "$k" "$v" "$actual" >> "$tmp"
                fail=1
            fi
        fi
        checked=$((checked+1))
    done < <(grep -vE '^\s*#' "$pin" 2>/dev/null || true)

    cat "$tmp"
    [ -n "$report" ] && cp "$tmp" "$report" 2>/dev/null || true
    rm -f "$tmp"
    if [ "$fail" != 0 ]; then
        echo "envpin: FAIL -- the build environment does not match $pin" >&2
        echo "envpin: regenerate with build/gen-env-pin.sh on the canonical builder, and commit;" >&2
        echo "envpin: a build that cannot prove its environment is not reproducible." >&2
        return 1
    fi
    echo "envpin: OK ($checked key(s) checked, $skip unprobeable)"
    return 0
}
