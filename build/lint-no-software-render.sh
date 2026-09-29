#!/bin/bash
# lint-no-software-render.sh -- grep-deny for anything that forces software rendering.
#
# NEVER-SOFTWARE-RENDER policy (operator, 2026-09-29): a machine with a GPU must not render in software. This lint
# fails on tracked shell/config/service files that set a software renderer or disable the GPU, unless the line's file
# is listed in build/software-render-allowlist.tsv (file <TAB> reason). Each allowlisted use must be guarded by
# ncz-gpu-hw-present / NCZ_ALLOW_SOFTWARE_FALLBACK, or be a machine with no GPU by construction.
# It also checks that every bootloader entry that turns the GPU off (sky1.gpu=none) is a console-only entry.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="${LINT_ROOT:-$(cd "$HERE/.." && pwd)}"
ALLOW="${LINT_ALLOWLIST:-$ROOT/build/software-render-allowlist.tsv}"
DENY='LIBGL_ALWAYS_SOFTWARE=[^0[:space:]"]|WLR_RENDERER=pixman|WLR_RENDERER_ALLOW_SOFTWARE=[^0[:space:]"]|GSK_RENDERER=cairo|GALLIUM_DRIVER=(llvmpipe|softpipe|swrast)|MESA_LOADER_DRIVER_OVERRIDE=(swrast|llvmpipe|softpipe|kms_swrast)|LIBGL_ALWAYS_SOFTWARE=1|--use-gl=(swiftshader|angle)|--use-angle=swiftshader|--disable-gpu|--enable-unsafe-swiftshader|--disable-gpu-compositing|hwdec=no|--hwdec=no'
FAIL=0
if [ -n "${LINT_FILES:-}" ]; then files=$LINT_FILES
else files=$(git -C "$ROOT" ls-files -- post-install assets build preseed manifests 2>/dev/null | grep -Ev '\.(md|tsv|patch|deb|bin|png|jpg|svg|squashfs)$|/test-|^build/lint-no-software-render.sh$|^build/iso-cache|^build/\.sqfs-work' )
fi
for f in $files; do
    p="$ROOT/$f"; [ -f "$p" ] || continue
    hits=$(grep -nE "$DENY" "$p" 2>/dev/null | grep -Ev '^[0-9]+:[[:space:]]*#|^[0-9]+:[[:space:]]*(unset|echo|log|err|msg)[[:space:]]' || true)
    [ -n "$hits" ] || continue
    if [ -f "$ALLOW" ] && awk -F'\t' -v f="$f" '$1==f && $2!="" {ok=1} END{exit(ok?0:1)}' "$ALLOW"; then continue; fi
    echo "LINT FAIL: $f forces or allows software rendering (never-software-render policy):" >&2
    printf '%s\n' "$hits" | head -5 | sed 's/^/    /' >&2
    echo "  guard it with ncz-gpu-hw-present / NCZ_ALLOW_SOFTWARE_FALLBACK and add it to build/software-render-allowlist.tsv with a reason," >&2
    echo "  or remove it." >&2
    FAIL=1
done
# allowlist rows must name files that still exist (the list only shrinks)
if [ -f "$ALLOW" ] && [ -z "${LINT_FILES:-}" ]; then
    while IFS=$'\t' read -r f why; do
        case "$f" in ''|'#'*) continue ;; esac
        [ -f "$ROOT/$f" ] || { echo "LINT FAIL: allowlist row '$f' has no such file" >&2; FAIL=1; }
    done < "$ALLOW"
fi
# bootloader: an entry that disables the GPU must be console-only (no graphical software session)
for f in $(git -C "$ROOT" ls-files -- assets/refind post-install build/iso 2>/dev/null); do
    [ -f "$ROOT/$f" ] || continue
    case "$f" in *.md|*.tsv) continue ;; esac
    while IFS= read -r l; do
        echo "LINT FAIL: $f: a sky1.gpu=none boot entry must be console-only (systemd.unit=multi-user.target): $l" >&2; FAIL=1
    done < <(grep -nE 'sky1\.gpu=none' "$ROOT/$f" 2>/dev/null | grep -Ev '^[0-9]+:[[:space:]]*#' | grep -Ev 'systemd\.unit=(multi-user|rescue|emergency)\.target' | grep -E '(OPTIONS|options)=' || true)
done
[ "$FAIL" = 0 ] && echo "lint-no-software-render: OK"
exit "$FAIL"
