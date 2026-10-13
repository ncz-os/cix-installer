# telnet-inetd.sh -- POSIX-sh helper: make the inetd telnet line on :23 exec a
# telnetd binary that actually exists on the target.
#
# Why (r201, all four reflashed machines, 2026-10-07): post-install/36-telemetry.sh
# appended `telnet stream tcp nowait root /usr/sbin/in.telnetd in.telnetd`, but
# Debian forky's inetutils-telnetd ships /usr/sbin/telnetd only. inetd accepted
# the connection on :23 and the journal then logged
#     execv /usr/sbin/in.telnetd: No such file or directory
# so the LAN-only recovery console (project policy #9) was dead on every install.
# A tcpd-wrapped line has the same failure when tcp-wrappers is absent.
#
# ncz_telnet_inetd_fix [ROOT]
#   ROOT defaults to "" (the running system / chroot). Finds the real telnetd
#   (in.telnetd or telnetd, /usr/sbin then /usr/libexec), comments out every
#   active telnet line whose exec path does not exist under ROOT (or that routes
#   through a missing /usr/sbin/tcpd), and leaves exactly one active line that
#   execs the binary directly. Returns 0 when a working line is in place, 1 when
#   no telnetd binary exists (the caller picks its fallback).
# Sourced by post-install/36-telemetry.sh, preseed/late.sh (via chroot) and
# build/build-rescue-rootfs.sh; tested by build/test-telnet-inetd.sh.

ncz_telnetd_binary() {
    _nt_root="${1:-}"
    for _nt_b in /usr/sbin/in.telnetd /usr/sbin/telnetd /usr/libexec/telnetd /usr/lib/telnetd/telnetd; do
        if [ -x "$_nt_root$_nt_b" ] && [ ! -d "$_nt_root$_nt_b" ]; then
            echo "$_nt_b"
            return 0
        fi
    done
    return 1
}

ncz_telnet_inetd_fix() {
    _nt_root="${1:-}"
    _nt_conf="$_nt_root/etc/inetd.conf"
    _nt_bin=$(ncz_telnetd_binary "$_nt_root") || {
        echo "telnet-inetd: no telnetd binary under ${_nt_root:-/} (looked for in.telnetd/telnetd)" >&2
        return 1
    }
    _nt_want="telnet	stream	tcp	nowait	root	$_nt_bin	${_nt_bin##*/}"
    [ -f "$_nt_conf" ] || : > "$_nt_conf"
    _nt_tmp="$_nt_conf.ncz-telnet.$$"
    # Executable paths named by the active telnet lines (server + tcpd target),
    # tested here in the shell so awk never builds a command from file content.
    _nt_ok=$(grep -E '^[[:space:]]*telnet[[:space:]]' "$_nt_conf" 2>/dev/null | awk '{print $6; print $7}' |
        while IFS= read -r _nt_p; do
            case "$_nt_p" in /*) [ -x "$_nt_root$_nt_p" ] && [ ! -d "$_nt_root$_nt_p" ] && printf '%s\n' "$_nt_p" ;; esac
        done)
    # Keep a line only if it is the wanted one; disable every other ACTIVE telnet
    # line (wrong path, missing tcpd wrapper, duplicate) so inetd never binds :23
    # to something that cannot exec. Commented lines and other services pass through.
    NCZ_NT_OK="$_nt_ok" awk -v want="$_nt_want" '
        function exists(p) { return (p != "" && (p in OK)) }
        BEGIN { kept = 0; n = split(ENVIRON["NCZ_NT_OK"], L, "\n"); for (i = 1; i <= n; i++) if (L[i] != "") OK[L[i]] = 1 }
        /^[[:space:]]*telnet[[:space:]]/ {
            n = split($0, f, /[[:space:]]+/)
            # f[1] may be empty when the line starts with blanks
            o = (f[1] == "") ? 1 : 0
            server = f[6 + o]
            ok = exists(server)
            if (ok && server ~ /\/tcpd$/) ok = exists(f[7 + o])
            line = $0
            gsub(/[[:space:]]+/, "\t", line)
            sub(/^\t/, "", line)
            if (ok && !kept && line == want) { print want; kept = 1; next }
            print "#<ncz-disabled># " $0
            next
        }
        { print }
        END { if (!kept) print want }
    ' "$_nt_conf" > "$_nt_tmp" || { rm -f "$_nt_tmp"; return 1; }
    if ! cmp -s "$_nt_tmp" "$_nt_conf"; then
        cat "$_nt_tmp" > "$_nt_conf"
        echo "telnet-inetd: $_nt_conf now execs $_nt_bin (stale/broken telnet lines disabled)"
    fi
    rm -f "$_nt_tmp"
    return 0
}
