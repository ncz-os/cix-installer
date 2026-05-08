#!/bin/bash
# di-diag.sh — drive d-i network-console past the curses menu and run
# diagnostic commands non-interactively.
#
# d-i's network-console wraps SSH in GNU screen, with window 1 hosting
# a curses dialog ("Start installer / Start shell / etc."). The dialog
# blocks normal `ssh host 'cmd'` automation.
#
# This utility uses `expect` to:
#   1. Connect with the preseeded password (Gumbo@Kona1b)
#   2. Navigate the curses menu (arrows + Enter) to "Start shell"
#   3. Run the requested diagnostic command(s) in the busybox shell
#   4. Exit cleanly
#
# Usage:
#   tools/di-diag.sh <host> [command|diag]
#
# Examples:
#   tools/di-diag.sh 192.168.207.66
#       (interactive shell)
#
#   tools/di-diag.sh 192.168.207.66 diag
#       (canned diagnostic dump — everything we usually want)
#
#   tools/di-diag.sh 192.168.207.66 'tail -50 /var/log/syslog'
#       (run a one-shot command)
#
# Operator workflow:
#   When d-i shows install failure, run:
#     tools/di-diag.sh 192.168.207.66 diag > /tmp/di-diag-$(date +%s).txt
#   Output captures syslog + /target state + early_command log + mounts.

set -u

HOST="${1:-}"
CMD="${2:-}"

if [ -z "$HOST" ]; then
    echo "Usage: $0 <host> [command|diag]" >&2
    exit 1
fi

PASSWORD="${DI_PASSWORD:-Gumbo@Kona1b}"

if [ "$CMD" = "diag" ]; then
    # shellcheck disable=SC2089
    CMD='echo DI_PHASE_UNAME; uname -a; echo DI_PHASE_CHROOT_ERRORS; grep -iE "fatal|fail|chroot|target|cdebootstrap" /var/log/syslog 2>/dev/null | tail -50; echo DI_PHASE_TARGET_TREE; ls -la /target 2>&1 | head -25; ls /target/bin /target/usr/bin 2>&1 | head -10; echo DI_PHASE_MOUNTS; mount | head -30; echo DI_PHASE_DF; df -h | head -15; echo DI_PHASE_EARLY_SENTINEL; cat /etc/early_command_ran.txt 2>&1; echo DI_PHASE_EARLY_LOG; tail -40 /var/log/early_command.log 2>&1; echo DI_PHASE_INSTALLER_LOG; tail -100 /var/log/installer/syslog 2>/dev/null; ls /var/log/installer/ 2>&1; echo DI_PHASE_SYSLOG; tail -80 /var/log/syslog; echo DI_PHASE_END'
fi

if [ -z "$CMD" ]; then
    INTERACTIVE=1
else
    INTERACTIVE=0
fi

ssh-keygen -R "$HOST" 2>/dev/null
ssh-keygen -R "[$HOST]:22" 2>/dev/null

# shellcheck disable=SC2090
export PASSWORD CMD INTERACTIVE HOST

exec expect -f - <<'EXPECT'
log_user 1
set timeout 30
set host    $env(HOST)
set passwd  $env(PASSWORD)
set cmd     $env(CMD)
set inter   $env(INTERACTIVE)

spawn ssh -tt \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=20 \
    -o ServerAliveCountMax=3 \
    installer@$host

expect {
    "password:" { send -- "$passwd\r" }
    "Permission denied" { send_user "\nauth failed\n"; exit 2 }
    timeout { send_user "\ntimeout waiting for password prompt\n"; exit 3 }
}

# After auth, network-console launches GNU screen with the curses
# dialog as window 1 (active). Wait for it to render, then drive:
#   Menu items:
#     Start installer
#     Start installer (expert mode)
#     Start shell
#   Send Down Down Enter to select "Start shell".
expect {
    -re "Start shell|Start installer" { }
    timeout { send_user "\nnetwork-console menu not seen\n"; exit 4 }
}

# arrow-down arrow-down enter — select "Start shell"
sleep 1
send -- "\x1b\[B\x1b\[B\r"

# Wait for busybox shell prompt. Its prompt typically is "~ # " or "/ # "
expect {
    -re "# +$" { }
    -re "\\\$ +$" { }
    timeout {
        send_user "\nshell prompt not seen after menu select\n"
        # try Ctrl-A 2 as fallback (switch to a pre-spawned shell window)
        send -- "\x012"
        sleep 1
        send -- "\r"
        expect {
            -re "# +$" { }
            -re "\\\$ +$" { }
            timeout { send_user "\nstill no shell prompt — exiting\n"; exit 5 }
        }
    }
}

if {$inter == 1} {
    send_user "\n--- d-i shell active. Ctrl-A then d detaches screen. ~. closes ssh. ---\n"
    interact
} else {
    set timeout 120
    set marker "MARK_END_RUN_[pid]_[clock seconds]"
    set remote_rc 0
    send -- "echo MARK_BEGIN_RUN\r"
    expect "MARK_BEGIN_RUN"
    expect {
        -re "# +$" { }
        -re "\\\$ +$" { }
    }
    send -- "$cmd\r"
    send -- "rc=\$?; echo $marker:\$rc\r"
    expect {
        -re "$marker:([0-9]+)" { set remote_rc $expect_out(1,string) }
        timeout {
            send_user "\ncommand timed out waiting for completion marker\n"
            set remote_rc 124
        }
        eof {
            send_user "\nssh closed before completion marker\n"
            exit 6
        }
    }
    # Detach screen + close ssh
    set timeout 10
    sleep 1
    send -- "\x01d"
    sleep 1
    send -- "~.\r"
    expect {
        eof { }
        timeout { send_user "\ntimeout waiting for ssh close\n" }
    }
    exit $remote_rc
}
EXPECT
