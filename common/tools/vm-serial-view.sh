#!/bin/bash
# Clean view of the install VM serial log: strip ANSI, show key install milestones.
L="${1:-/var/tmp/install-server.serial.log}"
echo "=== qemu running: $(pgrep -c qemu-system-aarch64) ($(pgrep -fa qemu-system-aarch64 | grep -o 'ncz_variant=[a-z]*' | head -1)) ==="
sed -r 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b[()][AB0]//g; s/\x1b[=>]//g' "$L" 2>/dev/null \
  | tr -d '\r' \
  | grep -aiE 'detect|mount|partman|partition|debootstrap|nvme|finish|late_command|run-all|cix-installer|\[[0-9]{2}\]|prompt|reboot|error|fail|warn|overlay|armchina|arch12' \
  | tail -40
