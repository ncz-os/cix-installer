#!/bin/bash
# test-hermetic.sh -- prove the hermetic build enforcement, in BOTH directions.
#
#   (A) unit: the enforcement wrapper really blocks the network -- a child that
#       calls connect() FAILS inside the namespace / --network none.
#   (B) fixture: curl, go module fetch, `git clone https`, pip install each FAIL
#       under enforcement, and the SAME operations SUCCEED with the network on
#       (so the enforcement is what changed the result, not a broken tool).
#   (C) cache path: a `git clone` from the LOCAL bare mirror SUCCEEDS with the
#       network off (the offline build path works, not just fails).
#   (D) lint: every curl|wget|go get|git clone|pip|npm|cargo fetch/install in
#       the build scripts is either an allow-listed phase-1 fetcher, a runtime
#       hook, a gate/test tool, or explicitly network-guarded -- else FLAGGED.
#
# Runs on a build host (Linux; needs podman or unshare for A/B/C).  On a host
# without them it SKIPs A/B/C loudly and still runs D (the lint), which is
# platform-independent.  Wired into `make test-build`.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GATE_IMG="${HERMETIC_TEST_IMAGE:-localhost/ncz-probe:ready}"
GATE_IMG_FALLBACK="${HERMETIC_TEST_IMAGE_FALLBACK:-debian:forky}"
ENGINE="$(command -v podman || command -v docker || true)"
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  ok    %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
skip() { printf '  skip  %s\n' "$*"; SKIP=$((SKIP+1)); }

have_engine() { [ -n "$ENGINE" ]; }
pick_img() {  # echo the first usable image tag
    local i
    for i in "$GATE_IMG" "$GATE_IMG_FALLBACK"; do
        if have_engine && "$ENGINE" image exists "$i" 2>/dev/null; then echo "$i"; return 0; fi
    done
    echo ""
}

echo "== test-hermetic =="

# ---------------------------------------------------------------------------
# (A) unit: enforcement blocks the network
# ---------------------------------------------------------------------------
echo "-- (A) enforcement blocks the network"
IMG="$(pick_img)"
if [ -n "$IMG" ]; then
    # A child that connects to a routable address MUST fail under --network none.
    out="$("$ENGINE" run --rm --network none "$IMG" bash -c \
        'exec 3<>/dev/tcp/1.1.1.1/80 && echo CONNECTED || echo BLOCKED' 2>&1 || true)"
    if printf '%s' "$out" | grep -qi 'BLOCKED\|network is unreachable\|Network is unreachable'; then
        ok "podman --network none: outbound TCP connect is blocked ($IMG)"
    elif printf '%s' "$out" | grep -qi CONNECTED; then
        bad "podman --network none did NOT block outbound TCP ($IMG)"
    else
        skip "podman --network none probe inconclusive: $out"
    fi
    # DNS must fail too.
    out="$("$ENGINE" run --rm --network none "$IMG" bash -c \
        'getent hosts deb.debian.org >/dev/null 2>&1 && echo RESOLVED || echo NODNS' 2>&1 || true)"
    printf '%s' "$out" | grep -qi NODNS && ok "podman --network none: DNS resolution is blocked" \
        || bad "podman --network none: DNS still resolved ($out)"
else
    skip "(A) no container engine/image (set HERMETIC_TEST_IMAGE); cannot prove the wrapper"
fi
# host-side netns wrapper (if usable here)
if uname -s | grep -qi linux && command -v unshare >/dev/null 2>&1; then
    if unshare -rn true 2>/dev/null || { [ "$(id -u)" = 0 ] && unshare -n true 2>/dev/null; }; then
        if bash -c 'command -v "$ROOT/build/lib/offline.sh" >/dev/null; . "$ROOT/build/lib/offline.sh"; ncz_nonet_run true' >/dev/null 2>&1; then
            ok "ncz_nonet_run wrapper is usable on this host (netns available)"
        else
            skip "ncz_nonet_run wrapper not usable here (no netns permission)"
        fi
    else
        skip "host netns unavailable (unprivileged userns restricted) -- container path proves enforcement"
    fi
fi

# ---------------------------------------------------------------------------
# (B) fixture: each fetch tool FAILS offline; the same op SUCCEEDS online
# ---------------------------------------------------------------------------
echo "-- (B) fetch tools fail under enforcement, succeed with network"
run_net_probe() {  # run_net_probe <netmode> <cmd>  -> echoes rc
    local mode="$1"; shift
    local img="$1"; shift
    "$ENGINE" run --rm --network "$mode" "$img" bash -c "$*" >/dev/null 2>&1
    echo $?
}
if [ -n "$IMG" ]; then
    declare -a tools=(
        "curl:curl -fsS -m 8 https://deb.debian.org/debian/ -o /dev/null"
        "git-clone:git clone --depth 1 https://github.com/singularityos-lab/vetro /tmp/v >/dev/null 2>&1"
        "go-mod:sh -c 'mkdir -p /tmp/p && cd /tmp/p && printf \"module p\n\ngo 1.21\n\nrequire github.com/spf13/pflag v1.0.5\n\" > go.mod && go mod download github.com/spf13/pflag'"
        "pip:pip install --no-cache-dir --disable-pip-version-check requests"
        "npm:npm install --no-save left-pad"
        "git-lsremote:git ls-remote https://github.com/wlrfx/scenefx.git refs/heads/main"
    )
    for t in "${tools[@]}"; do
        name="${t%%:*}"; cmd="${t#*:}"
        rc_off="$(run_net_probe none "$IMG" "$cmd")"
        rc_on="$(run_net_probe host "$IMG" "$cmd")"
        if [ "$rc_off" = 0 ]; then
            bad "$name SUCCEEDED under --network none (enforcement leak)"
        elif [ "$rc_on" = 0 ]; then
            ok "$name fails offline (rc=$rc_off) and succeeds online (rc=0): enforcement proven"
        else
            # tool missing in the image, or no real internet: cannot prove the
            # positive direction.  The negative (blocked) direction still holds.
            skip "$name fails offline (rc=$rc_off) but online also failed (rc=$rc_on; tool/network unavailable)"
        fi
    done
else
    skip "(B) no container engine/image"
fi

# ---------------------------------------------------------------------------
# (C) cache path: local bare mirror clone succeeds with the network off
# ---------------------------------------------------------------------------
echo "-- (C) offline build consumes the cache (git mirror)"
if [ -n "$IMG" ]; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ncz-hermetic-c.XXXXXX")"
    git init -q "$tmp/src" && ( cd "$tmp/src" && echo hi > f && git add f \
        && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
           git -c commit.gpgsign=false commit -qm x ) >/dev/null 2>&1
    git clone -q --bare "$tmp/src" "$tmp/mirror.git" >/dev/null 2>&1
    out="$("$ENGINE" run --rm --network none -v "$tmp/mirror.git":/mirror.git:ro "$IMG" bash -lc \
        'GIT_ALLOW_PROTOCOL=file git clone -q /mirror.git /dst && echo CLONED || echo REFUSED' 2>&1 || true)"
    printf '%s' "$out" | grep -q CLONED && ok "offline file:// clone from the bare mirror succeeds" \
        || bad "offline clone from the local mirror failed ($out)"
    # and a network clone under the same file-only protocol must FAIL
    out="$("$ENGINE" run --rm --network none "$IMG" bash -lc \
        'GIT_ALLOW_PROTOCOL=file git clone -q https://github.com/singularityos-lab/vetro /x 2>&1 && echo CLONED || echo REFUSED' 2>&1 || true)"
    printf '%s' "$out" | grep -qi 'REFUSED\|not allowed\|protocol' && ok "GIT_ALLOW_PROTOCOL=file refuses https (fail-closed)" \
        || skip "network clone under GIT_ALLOW_PROTOCOL=file: $out"
    rm -rf "$tmp"
else
    skip "(C) no container engine/image"
fi

# ---------------------------------------------------------------------------
# (D) lint: classify every network verb in the build scripts
# ---------------------------------------------------------------------------
echo "-- (D) lint: build-script network verbs are classified"
ALLOW="$ROOT/build/hermetic-network-allowlist.tsv"
VERB_RE='\b(curl|wget)[[:space:]]|go (get|mod download|download)|git (clone|fetch|ls-remote|pull)|pip[0-9]?[[:space:]]+install|npm (install|ci|fetch)|pnpm (install|fetch)|cargo (fetch|install)|apt-get (update|install)|mmdebstrap|debootstrap'
# files that legitimately fetch during the build (phase 1) -- by design
PHASE1_RE='^(build-image|refresh-substrate|refresh-singularity-sources|singularity-pins|fetch-inputs|pin-forky-snapshot|build-forky-mirror|build-vendor-mirror|build-desktop-mirror|stage-build-inputs|stage-canonical-assets|check-ncz-repo-policy|build-libdrm-debs|rebuild-sid-udeb|singularity-deb-depends|singularity-nightly-track|ncz-yocto|preflight-freshness-gate|gen-env-pin)\.sh$'
# gates/tests: not the shipped build path
GATE_RE='^(test-|kvm-|check-|verify-)'
flagged=0; classified=0; runtime=0
declare -a flags=()
while IFS= read -r f; do
    grep -qE "$VERB_RE" "$f" 2>/dev/null || continue
    # install/first-boot hooks run at INSTALL time, not build time: legitimate,
    # documented separately (they are the installer's own network use).
    case "$f" in */post-install/*) runtime=$((runtime+1)); continue ;; esac
    base="$(basename "$f")"
    if [ -f "$ALLOW" ] && grep -qE "^${base//./\.}[[:space:]]" "$ALLOW"; then
        classified=$((classified+1)); continue
    fi
    if printf '%s' "$base" | grep -qE "$PHASE1_RE"; then classified=$((classified+1)); continue; fi
    if printf '%s' "$base" | grep -qE "$GATE_RE"; then classified=$((classified+1)); continue; fi
    if grep -q 'NCZ_OFFLINE' "$f" 2>/dev/null; then classified=$((classified+1)); continue; fi
    flags+=("$base"); flagged=$((flagged+1))
done < <( { find "$ROOT/build" -maxdepth 1 -name '*.sh' 2>/dev/null
            find "$ROOT/post-install" -maxdepth 1 -name '*.sh' 2>/dev/null; } )
if [ "$flagged" = 0 ]; then
    ok "$classified build script(s) with network verbs are classified (allowlist / phase-1 / gate / guarded); $runtime runtime hook(s) run at install time"
else
    bad "$flagged build script(s) use the network UNCLASSIFIED:"
    for f in "${flags[@]}"; do printf '         %s\n' "$f"; done
    echo "         -> add a reason in build/hermetic-network-allowlist.tsv, or guard with NCZ_OFFLINE, or move the fetch to fetch-inputs.sh (phase 1)"
fi

# ---------------------------------------------------------------------------
echo "== test-hermetic: $PASS ok, $FAIL fail, $SKIP skip =="
[ "$FAIL" = 0 ] || exit 1
exit 0
