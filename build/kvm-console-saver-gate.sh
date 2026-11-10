#!/usr/bin/env bash
# kvm-console-saver-gate.sh -- KVM behavioural gate for the Magnetar Server
# console saver. This is the 04:40Z console-saver order item 5's gate half
# (the unit-test half lives in tools/bh-console/saver/).
#
#   --static <server.img> [<desktop.img>]  debugfs checks: the saver ships and
#       is enabled on the server variant and is ABSENT from the desktop
#       variant. Covers "service enabled on server / absent on desktop".
#       Medium-layout images (installer media: dists/ncz-payload/pool at the
#       partition root) are checked at the right layer: the
#       ncz-payload/assets/console-saver/ staging bundle (server stages it,
#       desktop must not); installed layout + hook registration belong to the
#       --live gate on an installed system (hook 61 installs at post-install).
#   --live <server.img> --arch amd64|arm64 [--idle N] [--workdir DIR]
#       boots the server image under KVM and drives the saver live:
#       idle -> saver appears on a free VT, a real key -> VT restored,
#       no leftover processes, power budget (saver CPU <= 2% of one core,
#       RSS < 16 MB), daemon left running, no respawn loop.
#   --installed-evidence <target-logs-dir> --variant server|desktop
#       [--installed-disk <installed.img> --arch amd64|arm64]
#       asserts the post-install end state from a kvm-install-gate run's
#       evidence dir (target-logs/): hook 61 RAN (no ORPHAN), logged its
#       install, and (with --installed-disk) the installed layout paths are
#       present on the installed rootfs. No VM, no boot: this is the
#       deterministic half of the --live assertions (2026-11-10 c337: the
#       medium boots the interactive installer, so a serial-only live driver
#       cannot reach the installed system; the install gate already produces
#       the evidence).
#   --self-test   unit tests for the parsers/threshold helpers (fixtures
#       only, no VM) so this gate has a runnable green state on any host.
#
# Why serial+monitor: the installed system carries no authorized_keys and root
# login is off (preseed passwd/root-login false); the KVM-gate preseed makes
# the nczuser/nczpassword123 account whose login lands on the serial console.
# Input is injected with the qemu monitor's sendkey because the saver watches
# evdev keyboard events -- serial typing is a different tty and must NOT wake
# it (that is also asserted by design: serial input leaves the saver alone).
#
# Conventions mirrored from build/kvm-install-gate-gpt.sh: qemu args, the
# debugfs rootfs evidence style, and the KVM-gate preseed account.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEBUGFS="$(command -v debugfs || echo /sbin/debugfs)"
SGDISK="$(command -v sgdisk || echo /sbin/sgdisk)"
QEMU_IMG="$(command -v qemu-img || echo qemu-img)"

PASS=0
FAIL=0

die()  { echo "kvm-console-saver-gate: $*" >&2; exit 2; }
ok()   { PASS=$((PASS + 1)); echo "  PASS $*"; }
no()   { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
say()  { echo "  $*"; }

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# rootfs evidence (same extraction chain as kvm-install-gate-gpt.sh):
# sparse raw conversion -> last partition LBA span -> dd -> debugfs.
# ---------------------------------------------------------------------------
ncz_last_partnum() {
    "$SGDISK" -p "$1" 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {n=$1} END {print n}'
}

extract_rootfs() { # $1=disk.img $2=out.raw
    local disk="$1" out="$2" raw part lba end
    raw="$out.disk.raw"
    rm -f "$raw" "$out"
    "$QEMU_IMG" convert -S 4k -O raw "$disk" "$raw" >/dev/null 2>&1 \
        || die "qemu-img convert failed for $disk"
    part="$(ncz_last_partnum "$raw" || true)"
    [ -n "$part" ] || die "$disk has no partition table"
    lba=$("$SGDISK" -i "$part" "$raw" | sed -n 's/^First sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    end=$("$SGDISK" -i "$part" "$raw" | sed -n 's/^Last sector:[[:space:]]*\([0-9]\+\).*/\1/p')
    [ -n "$lba" ] && [ -n "$end" ] || die "sgdisk could not read partition $part of $disk"
    dd if="$raw" of="$out" bs=512 skip="$lba" count=$((end - lba + 1)) status=none \
        || die "dd of root partition $part failed"
    rm -f "$raw"
}

fs_has() { # $1=root.raw $2=path -- true when the path exists
    "$DEBUGFS" -R "stat $2" "$1" 2>/dev/null | grep -q 'Inode:'
}

fs_cat() { # $1=root.raw $2=path
    "$DEBUGFS" -R "cat $2" "$1" 2>/dev/null
}

fs_ls() { # $1=root.raw $2=dir
    "$DEBUGFS" -R "ls -p $2" "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# static phase: "service enabled on server / absent on desktop"
# ---------------------------------------------------------------------------
check_variant() { # $1=root.raw $2=label $3=present|absent
    local root="$1" label="$2" want="$3"
    local bits="/usr/local/bin/ncz-console-saver /usr/local/bin/ncz-bh-console \
/etc/ncz/console-saver.conf /etc/systemd/system/ncz-console-saver.service \
/etc/systemd/system/multi-user.target.wants/ncz-console-saver.service"
    local p have
    for p in $bits; do
        have=no
        fs_has "$root" "$p" && have=yes
        if [ "$want" = present ] && [ "$have" = yes ]; then
            ok "$label has $p"
        elif [ "$want" = present ]; then
            no "$label is missing $p"
        elif [ "$have" = yes ]; then
            no "$label must NOT ship $p"
        else
            ok "$label correctly lacks $p"
        fi
    done
    if [ "$want" = present ]; then
        if fs_cat "$root" /etc/ncz/console-saver.conf | grep -q '^enabled=1'; then
            ok "$label conf has enabled=1"
        else
            no "$label conf lacks enabled=1"
        fi
    fi
}

# A server *medium* (installer image) has the offline-medium layout
# (dists/ncz-payload/pool at the partition root); installed-layout paths are
# absent there BY DESIGN -- hook 61-ncz-console-saver.sh installs them onto the
# installed system at post-install. For mediums the static assertions are the
# payload staging bundle (stage_console_saver(), server-variant guard); the
# installed layout + hook registration (hooks.list.*, run-all.sh
# MACHINE_HOOKS_RE) are the live gate's assertions on an installed system.
check_medium_staging() { # $1=root.raw $2=label $3=present|absent
    local root="$1" label="$2" want="$3" p have
    local bundle="/ncz-payload/assets/console-saver/ncz-console-saver \
/ncz-payload/assets/console-saver/ncz-bh-console \
/ncz-payload/assets/console-saver/console-saver.conf \
/ncz-payload/assets/console-saver/ncz-console-saver.service \
/ncz-payload/assets/console-saver/README.md"
    for p in $bundle; do
        have=no
        fs_has "$root" "$p" && have=yes
        if [ "$want" = present ] && [ "$have" = yes ]; then
            ok "$label stages $p"
        elif [ "$want" = present ]; then
            no "$label is missing staged $p"
        elif [ "$have" = yes ]; then
            no "$label must NOT stage $p"
        else
            ok "$label correctly does not stage $p"
        fi
    done
    say "$label is a medium layout: installed layout + hook registration are asserted by the live gate on an installed system"
}

is_medium() { # $1=root.raw -- true when the partition root is an offline medium
    fs_has "$1" "/ncz-payload" && fs_has "$1" "/pool"
}

cmd_static() {
    local srv="${1:-}" desk="${2:-}"
    [ -n "$srv" ] || die "--static needs <server.img>"
    local work root
    work="$(mktemp -d "${TMPDIR:-/tmp}/ncz-cs-gate.XXXXXX")"
    echo "[static] server image: $srv"
    extract_rootfs "$srv" "$work/server.root.raw"
    root="$work/server.root.raw"
    if is_medium "$root"; then
        echo "[static] server image is a medium layout (dists/ncz-payload/pool): asserting payload staging"
        check_medium_staging "$root" "server" present
    else
        check_variant "$root" "server" present
    fi
    if [ -n "$desk" ]; then
        echo "[static] desktop image: $desk (must not carry the saver)"
        extract_rootfs "$desk" "$work/desktop.root.raw"
        if is_medium "$work/desktop.root.raw"; then
            check_medium_staging "$work/desktop.root.raw" "desktop" absent
        else
            check_variant "$work/desktop.root.raw" "desktop" absent
        fi
    else
        say "no desktop image given; the absent side is unchecked"
    fi
    rm -rf "$work"
    verdict
}

# ---------------------------------------------------------------------------
# live phase: delegated to the serial/monitor driver
# ---------------------------------------------------------------------------
cmd_live() {
    local disk="" arch="amd64" idle=10 work=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --arch) arch="$2"; shift 2 ;;
            --idle) idle="$2"; shift 2 ;;
            --workdir) work="$2"; shift 2 ;;
            --) shift; break ;;
            -*) die "unknown live option $1" ;;
            *) [ -z "$disk" ] || die "extra argument $1"; disk="$1"; shift ;;
        esac
    done
    [ -n "$disk" ] || die "--live needs <server.img>"
    python3 "$SCRIPT_DIR/kvm-console-saver-live.py" \
        --disk "$disk" --arch "$arch" --idle "$idle" ${work:+--workdir "$work"}
    verdict
}

# ---------------------------------------------------------------------------
# installed-evidence phase: the deterministic half of --live. Consumes a
# kvm-install-gate run's target-logs/ dir (cix-installer-late.log is the
# post-install hook journal) and, optionally, the installed disk image.
# ---------------------------------------------------------------------------
hook_ran() { # stdin: cix-installer-late.log -- true when hook 61 ran (not ORPHAN)
    grep -q '\[61-ncz-console-saver\]' && ! grep -q 'ORPHAN: 61-ncz-console-saver'
}
hook_logged_install() { # stdin: late.log, $1=variant -- true on its install line
    case "$1" in
        server)  grep -q '\[61-ncz-console-saver\] ncz-console-saver.service enabled (server variant)' ;;
        desktop) grep -q '\[61-ncz-console-saver\] BUILD_VARIANT=desktop -- desktop SKU; skipping' ;;
        *) return 1 ;;
    esac
}

cmd_evidence() {
    local logs="" variant="" disk="" arch="amd64"
    while [ $# -gt 0 ]; do
        case "$1" in
            --variant) variant="$2"; shift 2 ;;
            --installed-disk) disk="$2"; shift 2 ;;
            --arch) arch="$2"; shift 2 ;;
            --) shift; break ;;
            -*) die "unknown installed-evidence option $1" ;;
            *) [ -z "$logs" ] || die "extra argument $1"; logs="$1"; shift ;;
        esac
    done
    [ -d "$logs" ] || die "--installed-evidence needs a target-logs dir"
    case "$variant" in server|desktop) : ;; *) die "--variant server|desktop required" ;; esac
    local late="$logs/cix-installer-late.log"
    [ -f "$late" ] || die "$late missing (not a kvm-install-gate evidence dir?)"
    if grep -q 'ORPHAN: 61-ncz-console-saver' "$late"; then
        no "$late: ORPHAN: 61-ncz-console-saver -- hook 61 never ran on the installed system"
    elif grep -q '\[61-ncz-console-saver\]' "$late"; then
        ok "$late: hook 61 ran (no ORPHAN)"
    else
        no "$late: no [61-ncz-console-saver] journal lines at all"
    fi
    if hook_logged_install "$variant" < "$late"; then
        ok "$late: hook 61 logged its $variant install decision"
    else
        no "$late: hook 61 install line for variant=$variant missing"
    fi
    if [ -n "$disk" ]; then
        local root="$logs/.cs-evidence-root.raw"
        say "installed-disk: extracting rootfs of $disk ($arch)"
        extract_rootfs "$disk" "$root"
        check_variant "$root" "installed($variant)" \
            "$([ "$variant" = server ] && echo present || echo absent)"
        rm -f "$root"
    else
        say "no --installed-disk: installed-layout file assertions skipped (journal evidence only)"
    fi
    verdict
}

# ---------------------------------------------------------------------------
# self-test: the gate's pure logic against fixtures (no VM, any host)
# ---------------------------------------------------------------------------
conf_apply_idle() { # stdin: conf, $1: idle -- the live phase's edit, pure
    sed -e "s/^idle_seconds=.*/idle_seconds=$1/" \
        -e 's/^enabled=.*/enabled=1/'
}

budget_ok() { # $1: %cpu (float), $2: RSS kB -- PASS when within budget
    # CPU <= 2% of one core (inclusive); RSS strictly below 16 MB.
    awk -v c="$1" -v r="$2" 'BEGIN{exit !((c+0)<=2.0 && (r+0)<16384)}'
}

vt_is_free() { # $1: baseline active VT, $2: current active VT
    [ "$1" != "$2" ] && case "$2" in tty[2-9]|tty[1-9][0-9]) return 0 ;; *) return 1 ;; esac
}

wants_link_present() { # stdin: `ls -p` of multi-user.target.wants
    # debugfs `ls -p` entries are name/inode/mode/...; accept a bare name too.
    grep -qE '^ncz-console-saver\.service(/|$)'
}

cmd_self_test() {
    echo "[self-test] conf_apply_idle"
    printf 'enabled=0\nidle_seconds=3600\nscene=grid\n' | conf_apply_idle 10 > /tmp/cs-gate.$$.conf
    grep -qx 'idle_seconds=10' /tmp/cs-gate.$$.conf && ok "idle_seconds rewritten to 10" || no "idle_seconds rewrite"
    grep -qx 'enabled=1' /tmp/cs-gate.$$.conf && ok "forced enabled=1" || no "enabled rewrite"
    grep -qx 'scene=grid' /tmp/cs-gate.$$.conf && ok "unrelated keys untouched" || no "unrelated keys clobbered"
    rm -f /tmp/cs-gate.$$.conf

    echo "[self-test] budget_ok thresholds (CPU <= 2.0% of a core, RSS < 16 MB)"
    budget_ok 1.9 16383 && ok "at budget passes" || no "at budget passes"
    budget_ok 0.0 1024 && ok "idle footprint passes" || no "idle footprint passes"
    budget_ok 2.1 1024 && no "over CPU must fail" || ok "over CPU fails"
    budget_ok 0.5 16384 && no "at RSS limit must fail (strict <)" || ok "at RSS limit fails"
    budget_ok 48.0 99999 && no "runaway saver must fail" || ok "runaway saver fails"

    echo "[self-test] vt_is_free (baseline tty1)"
    vt_is_free tty1 tty2 && ok "tty2 is a free VT" || no "tty2 is a free VT"
    vt_is_free tty1 tty6 && ok "tty6 is a free VT" || no "tty6 is a free VT"
    vt_is_free tty1 tty1 && no "baseline itself must not count" || ok "baseline itself does not count"
    vt_is_free tty1 tty0 && no "tty0 (fg console alias) must not count" || ok "tty0 does not count"
    vt_is_free tty1 ttyS0 && no "serial is not a VT" || ok "serial is not a VT"

    echo "[self-test] wants_link_present"
    printf 'foo.service\nncz-console-saver.service\nbar.service/\n' | wants_link_present \
        && ok "enabled link detected" || no "enabled link detected"
    printf 'foo.service\nbar.service/\n' | wants_link_present \
        && no "absent link must not match" || ok "absent link correctly not matched"

    echo "[self-test] hook_ran / hook_logged_install (late.log journal fixtures)"
    printf '[cix-installer] running 61-ncz-console-saver.sh\n[61-ncz-console-saver] enforcing console-saver install on server variants\n[61-ncz-console-saver] ncz-console-saver.service enabled (server variant)\n' \
        | hook_ran && ok "journal with hook output: ran" || no "journal with hook output: ran"
    printf '[cix-installer]   ORPHAN: 61-ncz-console-saver.sh\n[cix-installer] nothing else\n' \
        | hook_ran && no "ORPHAN journal must not count as ran" || ok "ORPHAN journal correctly not ran"
    printf '[cix-installer] unrelated lines only\n' \
        | hook_ran && no "journal without hook lines must not count" || ok "journal without hook lines correctly not ran"
    printf '[61-ncz-console-saver] enforcing console-saver install on server variants\n[61-ncz-console-saver] ncz-console-saver.service enabled (server variant)\n' \
        | hook_logged_install server && ok "server install line detected" || no "server install line detected"
    printf '[61-ncz-console-saver] BUILD_VARIANT=desktop -- desktop SKU; skipping\n' \
        | hook_logged_install desktop && ok "desktop skip line detected" || no "desktop skip line detected"
    printf '[61-ncz-console-saver] ncz-console-saver.service enabled (server variant)\n' \
        | hook_logged_install desktop && no "server line must not satisfy desktop" || ok "server line correctly not desktop"
    printf '[61-ncz-console-saver] FATAL: assets missing\n' \
        | hook_logged_install server && no "FATAL-only journal must not count as install" || ok "FATAL-only journal correctly not an install"

    verdict
}

verdict() {
    echo
    echo "kvm-console-saver-gate: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    --static) shift; cmd_static "$@" ;;
    --live) shift; cmd_live "$@" ;;
    --installed-evidence) shift; cmd_evidence "$@" ;;
    --self-test) cmd_self_test ;;
    -h|--help) usage 0 ;;
    *) usage 2 ;;
esac
