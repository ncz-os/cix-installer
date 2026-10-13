#!/bin/sh
# ssh-keys.sh -- early_command marker helper (installs NO SSH keys).
#
# Baked into the initrd at /ncz/ssh-keys.sh by build/iso/patch-initrd-t2-kernel.py
# (see BAKED_HELPERS) and called from preseed/early_command. It used to write
# project-owned public keys into the installer's /root/.ssh/authorized_keys;
# that was removed so a public installer image trusts no vendor key. Installer
# SSH access is password-based (preseed/diag-console.sh). The name is kept
# because the initrd helper list and early_command reference it.
#
# FAIL-CLOSED: this script NEVER aborts the installer.
#
# Side effects:
#   - /etc/early_command_ran.txt (sentinel)
#   - /var/log/early_command.log
set +e

date -u +"early_command-fired %FT%TZ" > /etc/early_command_ran.txt
ls -la /etc/early_command_ran.txt > /var/log/early_command.log 2>&1
