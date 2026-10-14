#!/bin/bash
# check-layers.sh -- verify a produced squashfs/dir layer BEFORE it is accepted
# or consumed by the next stage.  DESIGN RULE 2026-10-10 ("harden the layer
# checks"): structural integrity, package state, the payload facts that bit us,
# the layer chain, and determinism hooks -- every check has an id, a severity,
# and a structured row in the layer-checks TSV; a FAIL stops the pipeline.
#
# Never falls back silently: a layer that fails a check is not "reused anyway".
#
# Usage:
#   build/check-layers.sh LAYER [LAYER...] --arch amd64 [OPTIONS]
#     LAYER is a .squashfs file, an unpacked directory, or an image file.
# Options:
#   --arch A                amd64|arm64 (default $NCZ_TARGET_ARCH)
#   --layer NAME            label (default: basename without extension)
#   --manifest FILE         expected package set+versions (TAB/space: name version)
#   --prev FILE             previous green layer of the same role (size bounds +
#                           determinism member-list compare)
#   --lower LAYER           a layer under this overlay delta (repeat, nearest
#                           first); content assertions may find unchanged files there
#   --partial-root REL      this is a partial overlay layer whose content must
#                           live under REL (e.g. opt/singularity)
#   --payload-deb FILE      frozen payload deb (singularity version + shader gate)
#   --run-dir DIR           run dir (layer-checks.tsv lives here)
#   --checks-out FILE       explicit TSV path
#   --stage NAME            TSV stage column (default layers-postcheck)
#   --root DIR              repo root
#   --chain FILE            layer-chain file (reads/writes the lower-layer sha256)
#   --expect-parent NAME:SHA  assert LAYER records this parent sha (chain)
#   --json --strict -h
# Exit: 0 PASS (WARN allowed unless --strict), 1 FAIL, 2 usage.
set -uo pipefail
export LC_ALL=C
# Force UTC so the mtime rendering (`unsquashfs -ll`) and its parsing (`date -d`)
# agree; epoch 0 is then always 1970-01-01 00:00 and the clamp check is exact.
export TZ=UTC

SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/build/lib/priv.sh"
# shellcheck source=/dev/null
. "$ROOT/build/lib/reproducible.sh"

ARCH="${NCZ_TARGET_ARCH:-}"
LAYER_LABEL=""
MANIFEST=""
PREV=""
PARTIAL_ROOT=""
PAYLOAD_DEB=""
RUN_DIR="${RUN_DIR:-}"
CHECKS_OUT=""
STAGE="layers-postcheck"
CHAIN=""
EXPECT_PARENT=""
JSON=0
STRICT=0
APPEND=0
LAYERS=()
LOWERS=()   # --lower: the layers under an overlay delta, nearest first

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --arch)          ARCH="${2:-}"; shift 2 ;;
        --layer)         LAYER_LABEL="${2:-}"; shift 2 ;;
        --manifest)      MANIFEST="${2:-}"; shift 2 ;;
        --prev)          PREV="${2:-}"; shift 2 ;;
        --lower)         LOWERS+=("${2:-}"); shift 2 ;;
        --partial-root)  PARTIAL_ROOT="${2:-}"; shift 2 ;;
        --payload-deb)   PAYLOAD_DEB="${2:-}"; shift 2 ;;
        --run-dir)       RUN_DIR="${2:-}"; shift 2 ;;
        --checks-out)    CHECKS_OUT="${2:-}"; shift 2 ;;
        --stage)         STAGE="${2:-}"; shift 2 ;;
        --chain)         CHAIN="${2:-}"; shift 2 ;;
        --expect-parent) EXPECT_PARENT="${2:-}"; shift 2 ;;
        --root)          ROOT="${2:-}"; shift 2 ;;
        --json)          JSON=1; shift ;;
        --strict)        STRICT=1; shift ;;
        --append)        APPEND=1; shift ;;
        -h|--help)       usage 0 ;;
        -*)              echo "check-layers.sh: unknown option '$1'" >&2; usage 2 ;;
        *)               LAYERS+=("$1"); shift ;;
    esac
done
[ "${#LAYERS[@]}" -gt 0 ] || { echo "check-layers.sh: at least one LAYER is required" >&2; usage 2; }
case "$ARCH" in amd64|arm64) ;; *) echo "check-layers.sh: bad/absent --arch '$ARCH'" >&2; exit 2 ;; esac
[ -n "$ROOT" ] && ncz_repro_init "$ROOT" >/dev/null 2>&1 || true
[ -n "$CHECKS_OUT" ] || CHECKS_OUT="${RUN_DIR:+$RUN_DIR/layer-checks.tsv}"

FAILS=0; WARNS=0
_rec() {
    local layer="$1" check="$2" result="$3" ev="$4"
    local line="${STAGE}\t${layer}\t${check}\t${result}\t${ev}"
    if [ -n "$CHECKS_OUT" ]; then printf '%b\n' "$line" >> "$CHECKS_OUT"; else printf '%b\n' "$line"; fi
    case "$result" in FAIL) FAILS=$((FAILS+1));; WARN) WARNS=$((WARNS+1));; esac
}

# ---------------------------------------------------------------------------
# layer access abstraction (squashfs file | directory | image)
# ---------------------------------------------------------------------------
_layer_kind() {
    local l="$1"
    if [ -d "$l" ]; then echo dir; return; fi
    case "$l" in
        *.squashfs|*.sqfs) echo sqfs ;;
        *) echo file ;;
    esac
}
# Per-layer listing/metadata cache: a layer can be hundreds of MB and the checks
# read the listing several times; run it once per layer per invocation.
_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/ncz-cl-cache.XXXXXX" 2>/dev/null || echo "")"
[ -n "$_CACHE" ] && trap 'rm -rf "$_CACHE"' EXIT
_cache_key() { printf '%s' "$1" | md5sum 2>/dev/null | awk '{print $1}'; }
_cached() {  # <kind> <layer> <producer...>
    local kind="$1" l="$2"; shift 2
    [ -n "$_CACHE" ] || { "$@"; return; }
    local f="$_CACHE/$(printf '%s' "$l" | md5sum | awk '{print $1}').$kind"
    [ -s "$f" ] && { cat "$f"; return; }
    "$@" | tee "$f"
}
_listing_raw() {  # normalized member paths, one per line (no leading ./ or squashfs-root/)
    local l="$1" k; k="$(_layer_kind "$l")"
    case "$k" in
        dir)  ( cd "$l" && find . -mindepth 1 -print 2>/dev/null | sed 's#^\./##' ) ;;
        # `unsquashfs -l` (no progress) prints one `squashfs-root/...` path per
        # line, NO header, NO blank line; the first line is the root itself.
        sqfs) unsquashfs -no-progress -l "$l" 2>/dev/null \
                  | sed 's#^squashfs-root/##; s#^squashfs-root$##' | grep -v '^$' ;;
        *)    return 1 ;;
    esac
}
_GNU_STAT=0; stat -c '%Y' /dev/null >/dev/null 2>&1 && _GNU_STAT=1
_meta_raw() {  # mode<TAB>owner/group<TAB>size<TAB>path<TAB>mtime  (best effort)
    local l="$1" k; k="$(_layer_kind "$l")"
    case "$k" in
        dir)
            ( cd "$l" && find . -mindepth 1 -print0 2>/dev/null | \
              while IFS= read -r -d '' p; do
                  rp="${p#./}"
                  if [ "$_GNU_STAT" = 1 ]; then
                      set -- $(stat -c '%a %U/%G %s %Y' "$p" 2>/dev/null)
                      [ -n "${1:-}" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$rp" "$4"
                  else
                      printf '%s\t%s\t%s\t%s\t%s\n' "$(stat -f '%Lp' "$p" 2>/dev/null)" \
                          "$(stat -f '%Su/%Sg' "$p" 2>/dev/null)" \
                          "$(stat -f '%z' "$p" 2>/dev/null)" "$rp" "$(stat -f '%m' "$p" 2>/dev/null)"
                  fi
              done ) ;;
        # `unsquashfs -ll`: mode owner/group size date time path [-> target].
        # Device nodes render size as "major, minor", which shifts the columns,
        # so locate the date token instead of assuming a fixed field position.
        sqfs) unsquashfs -no-progress -ll "$l" 2>/dev/null | awk '
                  { mode=$1; og=$2; size=$3;
                    di=0; for (i=3; i<=NF; i++) if ($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { di=i; break }
                    if (di==0) next;
                    dt=$di" "$(di+1); path="";
                    for (i=di+2; i<=NF; i++) path = path (i>di+2?" ":"") $i;
                    sub(/^squashfs-root\//,"",path); sub(/^squashfs-root$/,"",path);
                    sub(/ -> .*$/,"",path);
                    if (path != "") printf "%s\t%s\t%s\t%s\t%s\n", mode, og, size, path, dt }' ;;
    esac
}
_listing() { _cached listing "$1" _listing_raw "$1"; }
_meta()    { _cached meta    "$1" _meta_raw    "$1"; }
_has() { local l="$1" p="$2"; _listing "$l" | grep >/dev/null -x "$p"; }
# An overlay delta (desktop, desktop-hotfix) carries only what it changed; an
# unchanged file lives in a lower layer (--lower, nearest first).
_has_stack() {  # layer path
    local l="$1" p="$2" lw
    _has "$l" "$p" && return 0
    for lw in "${LOWERS[@]}"; do [ -e "$lw" ] && _has "$lw" "$p" && return 0; done
    return 1
}
_cat_stack() {  # layer path -> the member from the nearest layer that has it
    local l="$1" p="$2" lw
    _has "$l" "$p" && { _cat "$l" "$p"; return; }
    for lw in "${LOWERS[@]}"; do [ -e "$lw" ] && _has "$lw" "$p" && { _cat "$lw" "$p"; return; }; done
    return 1
}
_cat() {  # cat a member (best effort)
    local l="$1" p="$2" k; k="$(_layer_kind "$l")"
    case "$k" in
        dir)  cat "$l/$p" 2>/dev/null ;;
        sqfs) unsquashfs -no-progress -cat "$l" "$p" 2>/dev/null ;;
        *)    return 1 ;;
    esac
}
_sha_file() { local l="$1" k; k="$(_layer_kind "$l")"; [ "$k" = sqfs ] || [ "$k" = file ] || return 1; sha256sum "$l" 2>/dev/null | awk '{print $1}'; }

# ---------------------------------------------------------------------------
# checks
# ---------------------------------------------------------------------------
chk_integrity() {  # LAYER, label
    local l="$1" lbl="$2" k; k="$(_layer_kind "$l")"
    if [ "$k" != sqfs ]; then
        _rec "$lbl" sqfs-integrity SKIP "not a squashfs ($k)"; return
    fi
    if ! unsquashfs -no-progress -s "$l" >/dev/null 2>&1; then
        _rec "$lbl" sqfs-integrity FAIL "unsquashfs -s rejected $l (corrupt/truncated)"
        return
    fi
    local n; n="$(_listing "$l" | wc -l | tr -d ' ')"
    if [ "${n:-0}" -lt 10 ]; then
        _rec "$lbl" sqfs-integrity FAIL "squashfs member count suspiciously low ($n)"
        return
    fi
    _rec "$lbl" sqfs-integrity PASS "unsquashfs -s OK, $n members"
}

chk_size_bounds() {  # LAYER, label, prev
    local l="$1" lbl="$2" prev="$3"
    [ -n "$prev" ] && [ -e "$prev" ] || { _rec "$lbl" sqfs-size-bounds SKIP "no previous green layer"; return; }
    local a b; a="$(stat -c %s "$l" 2>/dev/null)"; b="$(stat -c %s "$prev" 2>/dev/null)"
    [ -n "$a" ] && [ -n "$b" ] && [ "$b" -gt 0 ] || { _rec "$lbl" sqfs-size-bounds SKIP "size unreadable"; return; }
    # allow +/-25%
    local lo=$(( b * 75 / 100 )) hi=$(( b * 125 / 100 ))
    if [ "$a" -lt "$lo" ] || [ "$a" -gt "$hi" ]; then
        _rec "$lbl" sqfs-size-bounds WARN "size $a outside +/-25% of prev $b (lo=$lo hi=$hi) -- review"
    else
        _rec "$lbl" sqfs-size-bounds PASS "size $a within +/-25% of prev $b"
    fi
}

chk_mtimes() {  # LAYER, label
    local l="$1" lbl="$2" k; k="$(_layer_kind "$l")"
    if [ "$k" != sqfs ]; then _rec "$lbl" sqfs-mtimes SKIP "not squashfs"; return; fi
    # mksquashfs is invoked with -all-time 0 -fstime 0 -> every member epoch 0.
    # TZ is forced to UTC for this script, so epoch 0 renders as the literal
    # "1970-01-01 00:00" -- a single string compare (no per-inode `date` fork).
    local bad
    bad="$(_meta "$l" | awk -F'\t' '$5!="1970-01-01 00:00"{print $5}' | sort -u | head -3)"
    if [ -n "$bad" ]; then
        _rec "$lbl" sqfs-mtimes WARN "member mtimes not clamped to epoch 0 (sample: $(printf '%s' "$bad" | tr '\n' ' '))"
    else
        _rec "$lbl" sqfs-mtimes PASS "all member mtimes clamped (epoch 0)"
    fi
}

chk_leftovers() {  # LAYER, label
    local l="$1" lbl="$2"
    local listing; listing="$(_listing "$l" | sed 's#^\./##')"
    local hits=""
    # unconditional builder leftovers (the standard X11/ICE/console socket dirs
    # under /tmp are created by tmpfiles and are NOT build leftovers)
    local h
    h="$(printf '%s\n' "$listing" | grep -E \
        '^work(/|$)|^tmp/|(^|/)\.git(/|$)|^root/\.bash_history$|^var/cache/apt/archives/.*\.deb$|^etc/ssh/ssh_host_[a-z0-9_]+(_key)?(\.pub)?$' \
        | grep -vE '^tmp/\.(X11-unix|ICE-unix|XIM-unix|font-unix)(/|$)' | head -20)"
    [ -n "$h" ] && hits="$hits $(printf '%s' "$h" | tr '\n' ' ')"
    # root's home: Debian's .bashrc/.profile and an empty .ssh only; anything
    # else (.config, .local, .cache ...) was written by a program the build ran
    h="$(printf '%s\n' "$listing" | grep -E '^root/[^/]+$' | grep -vxE 'root/\.(bashrc|profile|ssh)' | head -10)"
    [ -n "$h" ] && hits="$hits $(printf '%s' "$h" | tr '\n' ' ')"
    # object files ONLY under build-scratch prefixes (usr/lib/gcc ships legit .o)
    h="$(printf '%s\n' "$listing" | grep -E '^(work|tmp|root|build|var/tmp)/.*\.o$' | head -10)"
    [ -n "$h" ] && hits="$hits $(printf '%s' "$h" | tr '\n' ' ')"
    # /etc/machine-id must be empty (truncated) or absent; a populated one leaks identity
    if printf '%s\n' "$listing" | grep >/dev/null -x 'etc/machine-id'; then
        local mid; mid="$(_cat "$l" etc/machine-id 2>/dev/null | tr -d '[:space:]')"
        [ -n "$mid" ] && hits="$hits etc/machine-id(non-empty)"
    fi
    # /etc/resolv.conf: a builder nameserver/search is a leak; empty/localhost is fine
    if printf '%s\n' "$listing" | grep >/dev/null -x 'etc/resolv.conf'; then
        local rc; rc="$(_cat "$l" etc/resolv.conf 2>/dev/null)"
        if printf '%s' "$rc" | grep >/dev/null -E '^[[:space:]]*(nameserver|search|domain)[[:space:]]'; then
            hits="$hits etc/resolv.conf(builder)"
        fi
    fi
    # the rest of the build-host state build/build-squashfs-layers.sh
    # strip_build_host_state removes (keep the two lists in step)
    if printf '%s\n' "$listing" | grep >/dev/null -x 'etc/hostname'; then
        local hn; hn="$(_cat "$l" etc/hostname 2>/dev/null | tr -d '[:space:]')"
        [ -z "$hn" ] || [ "$hn" = localhost ] || hits="$hits etc/hostname($hn)"
    fi
    if printf '%s\n' "$listing" | grep >/dev/null -x 'etc/hosts'; then
        local hx; hx="$(_cat "$l" etc/hosts 2>/dev/null | awk '!/^[[:space:]]*#/ && NF>1 { for (i=2; i<=NF; i++) { if ($i ~ /^#/) break; print $i } }' \
            | grep -v -E '^(localhost|localhost\.localdomain|ip6-localhost|ip6-loopback|ip6-allnodes|ip6-allrouters|ip6-localnet|ip6-mcastprefix)$' | head -3 | tr '\n' ',')"
        [ -n "$hx" ] && hits="$hits etc/hosts(${hx%,})"
    fi
    if printf '%s\n' "$listing" | grep >/dev/null -x 'var/lib/dbus/machine-id'; then
        local dm; dm="$(_cat "$l" var/lib/dbus/machine-id 2>/dev/null | tr -d '[:space:]')"
        [ -n "$dm" ] && hits="$hits var/lib/dbus/machine-id(non-empty)"
    fi
    h="$(printf '%s\n' "$listing" | grep -E \
        '^var/lib/systemd/(random-seed|credential\.secret)$|^var/lib/(dhcp|dhclient|NetworkManager)/[^/]+\.leases?$|^var/log/journal/.+/[^/]+\.journal~?$|^var/cache/apt/[^/]+\.bin$|^var/lib/apt/lists/[^./][^/]*$|^root/\.ssh/.|^home/.|^var/opt/vivaldi/media-codecs-|^var/tmp/.' \
        | grep -vx 'var/lib/apt/lists/lock' | grep -vx 'var/lib/apt/lists/partial' | grep -vx 'var/lib/apt/lists/auxfiles' | head -20)"
    [ -n "$h" ] && hits="$hits $(printf '%s' "$h" | tr '\n' ' ')"
    if [ -n "$(printf '%s' "$hits" | tr -d ' ')" ]; then
        _rec "$lbl" no-build-leftovers FAIL "build leftovers present:$hits"
    else
        _rec "$lbl" no-build-leftovers PASS "no /work, /tmp contents, .git, scratch .o, apt cache/lists, non-empty machine-id, builder resolv.conf/hostname/hosts, random seed, leases, journal, ssh host keys, shell histories"
    fi
}

chk_dpkg_status() {  # LAYER, label
    local l="$1" lbl="$2"
    if ! _has "$l" "var/lib/dpkg/status"; then
        _rec "$lbl" dpkg-status SKIP "no var/lib/dpkg/status (partial/overlay layer)"
        return
    fi
    local st; st="$(_cat "$l" var/lib/dpkg/status 2>/dev/null)"
    local bad
    bad="$(printf '%s' "$st" | awk '/^Status:/{s=$0; sub(/^Status:[ \t]*/,"",s); if (s ~ /(half-installed|half-configured|unpacked|half-)/) print s}' | sort -u | head -10)"
    if [ -n "$bad" ]; then
        _rec "$lbl" dpkg-status FAIL "half-installed/unpacked packages: $(printf '%s' "$bad" | tr '\n' ';')"
    else
        local cfg
        cfg="$(printf '%s' "$st" | grep -c '^Status: deinstall ok config-files' || true)"
        if [ "${cfg:-0}" -gt 0 ]; then
            _rec "$lbl" dpkg-status WARN "$cfg package(s) in config-files state (removed, config kept)"
        else
            _rec "$lbl" dpkg-status PASS "var/lib/dpkg/status consistent (no half-installed/unpacked/config-files)"
        fi
    fi
}

chk_manifest() {  # LAYER, label, manifest
    local l="$1" lbl="$2" mf="$3"
    [ -n "$mf" ] && [ -f "$mf" ] || { _rec "$lbl" pkg-set-manifest SKIP "no --manifest given"; return; }
    if ! _has "$l" "var/lib/dpkg/status"; then _rec "$lbl" pkg-set-manifest SKIP "no dpkg status"; return; fi
    # The manifests/ *.pkgs files are SEED lists (package names, no versions):
    # the layer's closure installs far more than the seeds.  So: every seeded
    # package must be present (subset), and the full set+version equality is
    # only asserted when the manifest actually carries versions (a closure
    # manifest, e.g. a `name<TAB>version` file).
    local want_names have have_names missing with_ver
    want_names="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$mf" | awk '{print $1}' | sort -u)"
    with_ver="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$mf" | awk 'NF>=2{c++} END{print c+0}')"
    have="$(_cat "$l" var/lib/dpkg/status 2>/dev/null | awk '
        /^Package:/{p=$2} /^Version:/{v=$2; if(p!=""){print p"\t"v; p=""}}' | sort -u)"
    have_names="$(printf '%s\n' "$have" | awk -F'\t' 'NF{print $1}' | sort -u)"
    missing="$(comm -23 <(printf '%s\n' "$want_names") <(printf '%s\n' "$have_names") | head -20)"
    if [ -n "$missing" ]; then
        _rec "$lbl" pkg-set-manifest FAIL "expected package(s) missing from the layer: $(printf '%s' "$missing" | tr '\n' ' ')"
        return
    fi
    if [ "${with_ver:-0}" -gt 0 ]; then
        local want_ver extra
        want_ver="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$mf" | awk 'NF>=2{print $1"\t"$2}' | sort -u)"
        extra="$(comm -13 <(printf '%s\n' "$want_ver") <(printf '%s\n' "$have") | head -20)"
        if [ -n "$extra" ]; then
            _rec "$lbl" pkg-set-manifest FAIL "manifest diff (extra/version-mismatch): $(printf '%s' "$extra" | tr '\n' ' ')"
        else
            _rec "$lbl" pkg-set-manifest PASS "package set+versions == closure manifest ($(printf '%s\n' "$want_ver" | grep -c .) pkgs)"
        fi
    else
        _rec "$lbl" pkg-set-manifest PASS "all $(printf '%s\n' "$want_names" | grep -c .) seeded packages present (name-only seed list)"
    fi
}

chk_no_ubuntu() {  # LAYER, label
    local l="$1" lbl="$2"
    _has "$l" "var/lib/dpkg/status" || { _rec "$lbl" no-ubuntu SKIP "no dpkg status"; return; }
    local st hit; st="$(_cat "$l" var/lib/dpkg/status 2>/dev/null)"
    # An Ubuntu build shows as Origin: Ubuntu/Canonical, the Ubuntu Developers or
    # Canonical maintainer, or an Ubuntu version suffix (0ubuntu1, 3build1). A
    # Debian package whose Debian maintainer has an ubuntu.com address
    # (libeditorconfig0, libtss2-*) or whose name or homepage contains
    # "canonical" (node-unicode-canonical-property-names-ecmascript) is not.
    hit="$(printf '%s\n' "$st" | awk '
        /^Package:/ { p = $2 }
        /^Origin:[[:space:]]*(Ubuntu|Canonical)/ { print p; next }
        /^Maintainer:[[:space:]]*(Ubuntu (Core )?Developers|Canonical)/ { print p; next }
        /^Version:.*[0-9](ubuntu|build)[0-9]+/ { print p }' | sort -u | tr '\n' ' ')"
    if [ -n "${hit// /}" ]; then
        _rec "$lbl" no-ubuntu FAIL "Ubuntu-built package(s): $hit"
    elif _has "$l" "etc/apt/sources.list" && _cat "$l" etc/apt/sources.list 2>/dev/null | grep >/dev/null -i ubuntu; then
        _rec "$lbl" no-ubuntu FAIL "etc/apt/sources.list references ubuntu"
    else
        _rec "$lbl" no-ubuntu PASS "no Ubuntu/Canonical evidence in dpkg status or apt sources"
    fi
}

chk_one_kernel() {  # LAYER, label
    local l="$1" lbl="$2"
    local kver=""
    if [ -f "$ROOT/assets/kernel/mainline/KVER" ]; then kver="$(tr -d '[:space:]' < "$ROOT/assets/kernel/mainline/KVER")"; fi
    if [ "$ARCH" = amd64 ] && [ -f "$ROOT/assets/kernel/amd64-stable/KVER" ]; then
        kver="$(tr -d '[:space:]' < "$ROOT/assets/kernel/amd64-stable/KVER")"
    fi
    local vmlinuz modinit
    vmlinuz="$(_listing "$l" | grep -E '(^|/)boot/vmlinuz' | head -5)"
    modinit="$(_listing "$l" | grep -E '(^|/)lib/modules/[0-9]' | sed -E 's#.*lib/modules/([^/]+).*#\1#' | sort -u | head -5)"
    local debk
    debk="$(_listing "$l" | grep -E '(^|/)var/lib/dpkg/info/linux-image-7\.1' | head -3)"
    if [ -n "$debk" ]; then
        _rec "$lbl" one-kernel FAIL "Debian kernel dpkg info present (linux-image-7.1*)"
    elif [ -n "$modinit" ] && [ "$(printf '%s\n' "$modinit" | grep -c .)" -gt 1 ]; then
        _rec "$lbl" one-kernel FAIL "multiple kernel module trees: $(printf '%s' "$modinit" | tr '\n' ' ')"
    elif [ -n "$kver" ] && [ -n "$modinit" ] && ! printf '%s\n' "$modinit" | grep >/dev/null -x "$kver"; then
        _rec "$lbl" one-kernel FAIL "kernel modules '$modinit' != expected NCZ KVER '$kver'"
    else
        _rec "$lbl" one-kernel PASS "one kernel tree (${modinit:-none}), no Debian 7.1 kernel"
    fi
}

chk_labwc_shader() {  # LAYER, label
    local l="$1" lbl="$2"
    if ! _has "$l" "opt/singularity/bin/labwc"; then
        _rec "$lbl" labwc-shader-gate SKIP "no opt/singularity/bin/labwc in this layer"
        return
    fi
    local tmp; tmp="$(mktemp -d "${RUN_DIR:-/tmp}/.cl.XXXXXX" 2>/dev/null || mktemp -d)"
    _cat "$l" opt/singularity/bin/labwc > "$tmp/labwc" 2>/dev/null
    if [ ! -s "$tmp/labwc" ]; then rm -rf "$tmp"; _rec "$lbl" labwc-shader-gate FAIL "could not extract opt/singularity/bin/labwc"; return; fi
    if bash "$ROOT/build/check-singularity-shaders.sh" "$tmp/labwc" >/dev/null 2>&1; then
        _rec "$lbl" labwc-shader-gate PASS "labwc passes the static SceneFX shader gate (no quoted #error)"
    else
        _rec "$lbl" labwc-shader-gate FAIL "labwc FAILS the static SceneFX shader gate (quoted #error -> O6N black screen)"
    fi
    rm -rf "$tmp"
}

chk_singularity_version() {  # LAYER, label, payload_deb
    local l="$1" lbl="$2" deb="$3"
    local has_sing; has_sing=0
    _has "$l" "opt/singularity/bin/labwc" && has_sing=1
    [ "$has_sing" = 1 ] || { _rec "$lbl" singularity-version SKIP "no singularity payload in this layer"; return; }
    [ -n "$deb" ] && [ -f "$deb" ] || { _rec "$lbl" singularity-version SKIP "no --payload-deb"; return; }
    local dver lver
    dver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    lver="$(_cat "$l" opt/singularity/share/ncz-singularity-version 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$dver" ]; then _rec "$lbl" singularity-version SKIP "payload deb has no Version"; return; fi
    if [ -z "$lver" ]; then
        _rec "$lbl" singularity-version WARN "no embedded version stamp to compare against deb Version=$dver"
    elif [ "$lver" = "$dver" ]; then
        _rec "$lbl" singularity-version PASS "embedded singularity version == payload deb ($dver)"
    else
        _rec "$lbl" singularity-version FAIL "embedded '$lver' != payload deb '$dver'"
    fi
}

chk_content_assertions() {  # LAYER, label
    local l="$1" lbl="$2"
    # only meaningful on a layer that carries a real rootfs /usr tree; a payload
    # overlay (desktop-hotfix: opt/singularity only) is governed by its
    # allow-list root, not by the full-desktop content assertions.
    if ! _has "$l" usr; then
        _rec "$lbl" content-assertions SKIP "partial payload overlay (no /usr); allow-list root governs"
        return
    fi
    local checks=0 fails=""
    local -a need=(
        "opt/singularity/bin/singularity-desktop:synthetic desktop binary"
    )
    if _has "$l" "opt/singularity/bin/singularity-desktop"; then
        checks=$((checks+1))
        # the session the greeter offers; post-install/20-desktop.sh writes both.
        # (singularity-labwc-session.desktop, checked before, was never written.)
        { _has "$l" "usr/share/wayland-sessions/singularity.desktop" && _has "$l" "usr/local/bin/ncz-singularity"; } \
            || fails="$fails greeter-session-desktop"
    fi
    # greeter / gpu switcher / modprobe blacklists are base+desktop facts
    if _has "$l" "etc/modprobe.d" || _has "$l" "opt/singularity/bin/labwc"; then
        checks=$((checks+1))
        # both drivers blacklisted (design) is asserted only when the tree exists
        if _has "$l" "etc/modprobe.d/ncz-gpu.conf"; then
            local c; c="$(_cat "$l" etc/modprobe.d/ncz-gpu.conf 2>/dev/null)"
            printf '%s' "$c" | grep >/dev/null -i 'blacklist.*mali' || fails="$fails mali-blacklist"
            printf '%s' "$c" | grep >/dev/null -i 'blacklist.*panthor' || fails="$fails panthor-blacklist"
        fi
    fi
    # rEFInd default Mali entry (base layer)
    if _has "$l" "boot/efi/EFI/BOOT/refind.conf" || _has "$l" "EFI/BOOT/refind.conf"; then
        checks=$((checks+1))
        local rc; rc="$(_cat "$l" boot/efi/EFI/BOOT/refind.conf 2>/dev/null || _cat "$l" EFI/BOOT/refind.conf 2>/dev/null)"
        printf '%s' "$rc" | grep >/dev/null -iE 'default_selection.*(mali|sky1)' || fails="$fails refind-default-mali"
    fi
    # apt policy + forky-only rule
    if _has "$l" "etc/apt/apt.conf.d" || _has "$l" "etc/apt/sources.list.d"; then
        checks=$((checks+1))
        # usr/bin/ncz-apt-policy and etc/apt/apt.conf.d/99ncz-policy, checked
        # before, are produced by nothing in the tree. What ships:
        #   * a layer where the ncz-apt-policy package is installed carries its
        #     helper, its library and the pin its postinst writes;
        #   * otherwise the package is installed at install time (manifests/
        #     install-extra.pkgs + hook 24), so the layer carries the installer's
        #     hook, its library and that package list;
        #   * the base layer also carries the Debian kernel-purity pin.
        # In an overlay delta the files may sit unchanged in a lower layer.
        local _ip="usr/local/lib/cix-installer"
        if _cat "$l" var/lib/dpkg/status 2>/dev/null | awk '/^Package:/{p=$2} /^Status:/{ if (p=="ncz-apt-policy" && $0 ~ /install ok installed/) f=1 } END{exit !f}'; then
            { _has_stack "$l" "usr/sbin/ncz-apt-source" && _has_stack "$l" "usr/share/ncz-apt-policy/apt-separation.sh" \
              && _has_stack "$l" "etc/apt/preferences.d/10-ncz-origin-separation.pref"; } || fails="$fails ncz-apt-policy(package-files)"
        elif _has_stack "$l" "$_ip/post-install/24-apt-sources.sh" || _has_stack "$l" "$_ip/post-install/lib/apt-separation.sh"; then
            { _has_stack "$l" "$_ip/post-install/24-apt-sources.sh" && _has_stack "$l" "$_ip/post-install/lib/apt-separation.sh" \
              && _cat_stack "$l" "$_ip/manifests/install-extra.pkgs" 2>/dev/null | sed 's/#.*//' | grep >/dev/null -x '[[:space:]]*ncz-apt-policy[[:space:]]*'; } \
              || fails="$fails ncz-apt-policy(install-time)"
        else
            fails="$fails ncz-apt-policy(absent)"
        fi
        if [ "$lbl" = base ]; then
            _has "$l" "etc/apt/preferences.d/00-ncz-kernel-purity.pref" || fails="$fails ncz-kernel-purity-pin"
        fi
    fi
    if [ "$checks" = 0 ]; then _rec "$lbl" content-assertions SKIP "layer carries none of the checked desktop/base facts"; return; fi
    if [ -n "$fails" ]; then
        _rec "$lbl" content-assertions FAIL "missing/mismatched:$fails"
    else
        _rec "$lbl" content-assertions PASS "$checks content assertion group(s) OK"
    fi
}

chk_setuid_worldwritable() {  # LAYER, label
    local l="$1" lbl="$2"
    local meta; meta="$(_meta "$l")"
    [ -n "$meta" ] || { _rec "$lbl" perms-allowlist SKIP "no mode listing available"; return; }
    local allow="$ROOT/build/layer-perms-allowlist.tsv"
    local suid ww
    suid="$(printf '%s\n' "$meta" | awk -F'\t' '$1 !~ /^d/ && $1 ~ /[sS]/ {print $4}')"
    ww="$(printf '%s\n' "$meta" | awk -F'\t' '$1 ~ /^d......w.$/ {print $4}')"
    _allowed() {  # kind path -> 0 allowed
        local kind="$1" path="$2" pat
        [ -f "$allow" ] || return 1
        while IFS=$'\t' read -r k pat _reason; do
            case "$k" in ''|\#*) continue ;; esac
            [ "$k" = "$kind" ] || continue
            printf '%s' "$path" | grep >/dev/null -E "$pat" && return 0
        done < "$allow"
        return 1
    }
    local suid_bad="" ww_bad=""
    local mode path
    while read -r path; do
        [ -n "$path" ] || continue
        _allowed suid "$path" || suid_bad="$suid_bad $path"
    done <<< "$suid"
    while read -r path; do
        [ -n "$path" ] || continue
        _allowed ww "$path" || ww_bad="$ww_bad $path"
    done <<< "$ww"
    if [ -n "$suid_bad" ]; then
        _rec "$lbl" setuid-allowlist FAIL "setuid/setgid outside allow-list:$suid_bad"
    else
        _rec "$lbl" setuid-allowlist PASS "no unexpected setuid/setgid files"
    fi
    if [ -n "$ww_bad" ]; then
        _rec "$lbl" world-writable-allowlist WARN "world-writable dirs outside allow-list:$ww_bad"
    else
        _rec "$lbl" world-writable-allowlist PASS "no world-writable dirs outside allow-list"
    fi
}

# Owners: a layer is built as root from packages and from the project tree; no
# account exists yet, so an owner or group >= 1000 (other than nobody/nogroup
# 65534) is the build user leaking in through cp -a. Reviewed exceptions are
# 'owner' rows in build/layer-perms-allowlist.tsv (path regex).
_owners_raw() {  # uid<TAB>gid<TAB>path
    local l="$1" k; k="$(_layer_kind "$l")"
    case "$k" in
        dir)  ( cd "$l" && find . -mindepth 1 -printf '%U\t%G\t%P\n' 2>/dev/null ) ;;
        sqfs) unsquashfs -no-progress -lln "$l" 2>/dev/null | awk '
                  { og=$2; split(og, o, "/");
                    di=0; for (i=3; i<=NF; i++) if ($i ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { di=i; break }
                    if (di==0) next;
                    path=""; for (i=di+2; i<=NF; i++) path = path (i>di+2?" ":"") $i;
                    sub(/^squashfs-root\//,"",path); sub(/^squashfs-root$/,"",path); sub(/ -> .*$/,"",path);
                    if (path != "") printf "%s\t%s\t%s\n", o[1], o[2], path }' ;;
        *) return 1 ;;
    esac
}
chk_ownership() {  # LAYER, label
    local l="$1" lbl="$2" own
    own="$(_cached owners "$l" _owners_raw "$l")"
    [ -n "$own" ] || { _rec "$lbl" layer-ownership SKIP "no owner listing available"; return; }
    local allow="$ROOT/build/layer-perms-allowlist.tsv" pats=""
    [ -f "$allow" ] && pats="$(awk -F'\t' '$1=="owner"{print $2}' "$allow")"
    local badl
    badl="$(printf '%s\n' "$own" | awk -F'\t' '($1+0>=1000 && $1+0!=65534) || ($2+0>=1000 && $2+0!=65534) {print $1"/"$2" "$3}')"
    if [ -n "$pats" ] && [ -n "$badl" ]; then
        badl="$(printf '%s\n' "$badl" | while IFS= read -r line; do
            path="${line#* }"; printf '%s\n' "$pats" | while IFS= read -r pat; do { printf "%s" "$path" | grep >/dev/null -E "$pat" && echo hit; } || true; done | grep >/dev/null hit || printf '%s\n' "$line"; done)"
    fi
    if [ -n "$badl" ]; then
        _rec "$lbl" layer-ownership FAIL "$(printf '%s\n' "$badl" | grep -c .) member(s) owned by a non-system uid/gid (sample: $(printf '%s\n' "$badl" | head -3 | tr '\n' ';'))"
    else
        _rec "$lbl" layer-ownership PASS "no member owned by a non-system uid/gid"
    fi
}

chk_services() {  # LAYER, label
    local l="$1" lbl="$2"
    _has "$l" "etc/systemd/system" || { _rec "$lbl" systemd-services SKIP "no /etc/systemd/system (partial layer)"; return; }
    local enabled; enabled="$(_listing "$l" | grep -E '^etc/systemd/system/[^/]+\.(service|socket|target)$' | head -50)"
    _rec "$lbl" systemd-services PASS "$(printf '%s\n' "$enabled" | grep -c . ) enabled unit file(s) present"
}

chk_firstboot_exec() {  # LAYER, label
    local l="$1" lbl="$2"
    local hits; hits="$(_listing "$l" | grep -E '(^|/)first-?boot[^/]*\.sh$|/ncz-firstboot' | head -10)"
    [ -n "$hits" ] || { _rec "$lbl" firstboot-exec SKIP "no first-boot script in this layer"; return; }
    local meta; meta="$(_meta "$l")"
    local nexec=""
    while read -r p; do
        [ -n "$p" ] || continue
        local m; m="$(printf '%s\n' "$meta" | awk -F'\t' -v p="$p" '$4==p{print $1; exit}')"
        [ -n "$m" ] || continue
        case "$m" in ??????x*|????x?????|??x???????) : ;; *) nexec="$nexec $p" ;; esac
    done <<< "$hits"
    if [ -n "$nexec" ]; then _rec "$lbl" firstboot-exec WARN "first-boot script not executable:$nexec (OK if invoked via bash/systemd)"
    else _rec "$lbl" firstboot-exec PASS "first-boot scripts executable"; fi
}

chk_chain() {  # LAYER, label, chain_file, expect_parent
    local l="$1" lbl="$2" chain="$3" expect="$4"
    [ -n "$chain" ] || { _rec "$lbl" layer-chain SKIP "no --chain file"; return; }
    local sha; sha="$(_sha_file "$l" || true)"
    [ -n "$sha" ] || { _rec "$lbl" layer-chain SKIP "layer has no whole-file sha (dir layer)"; return; }
    if [ -n "$expect" ]; then
        local want_sha="${expect##*:}"
        if [ "$sha" != "$want_sha" ]; then
            _rec "$lbl" layer-chain FAIL "layer sha $sha != expected parent $expect"
            return
        fi
    fi
    _rec "$lbl" layer-chain PASS "layer sha256=$sha recorded${expect:+ (parent $expect verified)}"
}

chk_determinism_members() {  # LAYER, label, prev
    local l="$1" lbl="$2" prev="$3"
    [ -n "$prev" ] && [ -e "$prev" ] || { _rec "$lbl" member-list-determinism SKIP "no --prev"; return; }
    local a b
    a="$(_meta "$l" | sort)"
    b="$(_meta "$prev" | sort)"
    if [ -z "$a" ] || [ -z "$b" ]; then _rec "$lbl" member-list-determinism SKIP "no meta listing"; return; fi
    if [ "$a" = "$b" ]; then
        _rec "$lbl" member-list-determinism PASS "member list/mode/size identical to previous green layer"
    else
        local d; d="$(diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | head -5 | tr '\n' '|')"
        _rec "$lbl" member-list-determinism WARN "member list differs from prev (diff head: $d)"
    fi
}

# ---------------------------------------------------------------------------
main() {
    if [ -n "$CHECKS_OUT" ] && [ "$APPEND" != 1 ]; then : > "$CHECKS_OUT" 2>/dev/null || true; fi
    local l lbl
    for l in "${LAYERS[@]}"; do
        [ -e "$l" ] || { _rec "${l##*/}" layer-exists FAIL "layer not found: $l"; continue; }
        lbl="$LAYER_LABEL"; [ -n "$lbl" ] || lbl="$(basename "$l")"; lbl="${lbl%.squashfs}"; lbl="${lbl%.sqfs}"
        chk_integrity "$l" "$lbl"
        chk_size_bounds "$l" "$lbl" "$PREV"
        chk_mtimes "$l" "$lbl"
        chk_leftovers "$l" "$lbl"
        chk_dpkg_status "$l" "$lbl"
        chk_manifest "$l" "$lbl" "$MANIFEST"
        chk_no_ubuntu "$l" "$lbl"
        chk_one_kernel "$l" "$lbl"
        chk_labwc_shader "$l" "$lbl"
        chk_singularity_version "$l" "$lbl" "$PAYLOAD_DEB"
        chk_content_assertions "$l" "$lbl"
        chk_setuid_worldwritable "$l" "$lbl"
        chk_ownership "$l" "$lbl"
        chk_services "$l" "$lbl"
        chk_firstboot_exec "$l" "$lbl"
        chk_chain "$l" "$lbl" "$CHAIN" "$EXPECT_PARENT"
        chk_determinism_members "$l" "$lbl" "$PREV"
        if [ -n "$CHAIN" ] && [ -n "$( _sha_file "$l" || true )" ]; then
            printf '%s\t%s\n' "$lbl" "$(_sha_file "$l")" >> "$CHAIN"
        fi
    done
    printf '[check-layers] %s: fails=%d warns=%d\n' \
        "$([ "$FAILS" = 0 ] && echo PASS || echo FAIL)" "$FAILS" "$WARNS"
    [ "$JSON" = 1 ] && printf '{"stage":"%s","fails":%d,"warns":%d,"result":"%s"}\n' \
        "$STAGE" "$FAILS" "$WARNS" "$([ "$FAILS" = 0 ] && echo PASS || echo FAIL)"
    local rc=0
    [ "$FAILS" != 0 ] && rc=1
    [ "$STRICT" = 1 ] && [ "$WARNS" != 0 ] && rc=1
    return "$rc"
}
main
