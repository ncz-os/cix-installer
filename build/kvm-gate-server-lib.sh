# kvm-gate-server-lib.sh -- server-mode decisions for the KVM install gate
# (build/kvm-install-gate-gpt.sh). Sourced by the gate AND by
# build/test-kvm-gate-server.sh so the decision logic is one copy under test.
#
# NCZ_GATE_SERVER=1 (the gate hosts base.squashfs + the pinned asset bundle +
# the offline pool for the guest's fetcher) has two modes:
#
#   local   shadow-serve at the medium's pinned URL. The bind host is the pin
#           the guest will follow: 10.0.2.2 -> 127.0.0.1 (QEMU user-net maps
#           the gateway to the host's loopback); any other pin must be an
#           address of the gate host itself (NCZ_GATE_SERVER_HOST at build
#           time), reached through slirp's NAT.
#   online  the medium pins a PUBLISHED URL (the release payload on the
#           public R2 bucket). The gate must not bind it -- binding a remote
#           name is `[Errno 99] Cannot assign requested address` (measured
#           2026-11-09, run server-online-amd64-20261109) -- and must not
#           shadow-serve it: the "KVM after upload" run verifies the real
#           endpoint the release installs from. The gate only PREFLIGHTS the
#           pinned URLs at their own host before the guest starts; the guest
#           fetches through QEMU's NAT.
#
# NCZ_GATE_SERVER_ONLINE=1 forces online, 0 forces local; unset = auto.

ncz_gate_srv_mode() {
    # $1 = pinned host (the authority host of the manifest's base URL).
    # prints "local" or "online"; rc 0.
    local host="${1:-}" ip resolved local_addrs
    case "${NCZ_GATE_SERVER_ONLINE:-}" in
        1) echo online; return 0 ;;
        0) echo local;  return 0 ;;
    esac
    [ -n "$host" ] || host=10.0.2.2
    case "$host" in
        10.0.2.2|localhost|127.0.0.1|::1) echo local; return 0 ;;
    esac
    # A name/address that resolves to an address configured on THIS host is
    # bindable; anything else is a remote endpoint and goes online.
    resolved=$(getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    if [ -z "$resolved" ]; then
        # Unresolvable: the gate cannot shadow-serve a name it cannot even
        # resolve; online lets the preflight fail loudly at the network edge.
        echo online; return 0
    fi
    local_addrs=$( { hostname -I 2>/dev/null \
                     || ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1; } \
                   | tr ' \t' '\n' | sed '/^$/d' | sort -u )
    for ip in $resolved; do
        if printf '%s\n' "$local_addrs" | grep -qxF "$ip"; then
            echo local; return 0
        fi
    done
    echo online
}

ncz_gate_srv_preflight() {
    # $1 = full pinned URL (http or https). Proves the endpoint answers
    # 200/206 at header level before the guest is allowed to start (HEAD;
    # falls back to a 1-byte range GET where HEAD is refused). Prints the
    # HTTP status (or NO-RESPONSE); rc 0 iff 200/206.
    local url="$1" code
    code=$(curl -sSLI --max-time 30 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || true
    case "$code" in
        405|501)
            code=$(curl -sSL --max-time 30 -r 0-0 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) || true ;;
    esac
    case "$code" in ''|000) code=NO-RESPONSE ;; esac
    printf '%s\n' "$code"
    case "$code" in 200|206) return 0 ;; *) return 1 ;; esac
}
