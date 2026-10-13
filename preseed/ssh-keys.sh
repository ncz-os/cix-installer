#!/bin/sh
# ssh-keys.sh -- inject the NCZ fleet diagnostic SSH authorized_keys.
#
# Baked into the initrd at /ncz/ssh-keys.sh by build/iso/patch-initrd-t2-kernel.py
# (see BAKED_HELPERS). Called from preseed/early_command so Jason + the
# backup key can ssh in once sshd is running. Used to be inline in
# early_command; extracted to keep early_command under its hard 13 000-byte
# budget (check-early-command-size.sh).
#
# FAIL-CLOSED: this script NEVER aborts the installer. Missing /root/.ssh is
# the only way to fail; missing directories are auto-created.
#
# Side effects:
#   - /root/.ssh (mkdir -p, 0700)
#   - /root/.ssh/authorized_keys (0600, contains 2 ed25519 public keys)
set +e

mkdir -p /root/.ssh && chmod 0700 /root/.ssh
cat > /root/.ssh/authorized_keys <<'NCZ_KEYS'
# nclawzero fleet diag keys (auto-injected by preseed early_command)
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBJ3z+8UX2oPt3cmN1X9XU8RWrgp7VvdHPd0vW+m/AoR jperlow@work-laptop
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHKCDT5Busd1J+j4kpzkZ/jT/GtUQylaZCUCTftY2sYk argos-backup
NCZ_KEYS
chmod 0600 /root/.ssh/authorized_keys
date -u +"early_command-fired %FT%TZ" > /etc/early_command_ran.txt
ls -la /root/.ssh /etc/early_command_ran.txt > /var/log/early_command.log 2>&1
