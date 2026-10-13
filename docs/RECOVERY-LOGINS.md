# Recovery and diagnostics logins

This page lists every login NCZ-OS gives you for getting into a machine when
something has gone wrong: the one the **installer** offers while it runs, and the
one the **rescue partition** offers after installation. Your installed system is
not covered here: its root account is locked, and you log in with the account
you created during installation.

**Threat model.** These logins are deliberately published so that a broken or
headless machine can always be reached from your LAN; anyone on the same network
can use them while an installer or a rescue system is running. Keep installers
and rescue sessions off untrusted networks, and change the rescue login if the
machine lives on a network you do not control.

## 1. Installer diagnostics login (installer only)

| | |
|---|---|
| User | `root` (and `installer` for the network-console menu) |
| Password | `rescue` — the same login as the rescue partition (section 2) |
| Where it exists | Only in the running installer. It disappears when the installer reboots into your new system; the installed system never carries it. |
| Set by | `preseed/diag-console.sh` (root for SSH, telnet and the Sky1 serial getty) and `preseed/preseed.cfg` (`network-console/password`) |

### Where it is shown

The installer prints the login on every console as soon as it starts, in the
same banner line that names the build:

```
[NCZ 12:34:56] ==== NCZ-OS INSTALLER <build> ==== diagnostics login: root / rescue
```

- **Screen (tty1), Alt+F3 (tty3) and the serial console** get the banner line
  at boot (`/dev/tty1`, `/dev/tty3`, `/dev/console`).
- **Every NCZ installer dialog** repeats it on its last line, next to the
  architecture and build id (`preseed/ncz-ui.sh`, `ncz_ui_diag_login`), so it
  stays visible when a dialog redraws the screen.
- **The post-install progress screen** repeats it while packages and drivers
  are installed (`preseed/late.sh`).
- **Alt+F3** shows the diagnostics summary with the machine's IP address once
  the network is up.
- **Sky1 boards** also print it on the diagnostics UART (`ttyAMA0`, 115200 baud)
  when the installer itself is not using that port.
- The installer log `/var/log/diag-console.log` records it as well.

### Connecting

```bash
ssh root@<installer-ip>              # password: rescue
telnet <installer-ip> 23             # busybox shell; log in as root
wget http://<installer-ip>:8080/var/log/syslog   # read-only file pull
```

On a headless machine, find the installer's address in your router's DHCP
lease list (the hostname is the one the installer suggested), or connect a
serial cable on Sky1 and read the banner there.

### Changing or disabling it

At the boot menu, edit the installer entry's command line:

- `ncz_diag_pw=<your password>` uses your own password for root and the
  network-console menu; the banner then says
  `diagnostics login: root / set by ncz_diag_pw` instead of printing it.
- `ncz_diag=0` turns the diagnostics module off: no SSH, telnet or file pull,
  and no login line in the banner.

## 2. Rescue partition login (after installation)

| | |
|---|---|
| User | `root` |
| Password | `rescue` (`RESCUE_ROOT_PW` in `build/build-rescue-rootfs.sh`) |
| Where it exists | Only inside the rescue partition (`NCZRESCUE`), which you boot from the rEFInd entry "Rescue Partition (Console)". Your installed system's own root account stays locked. |
| Ports | telnet **23**, OpenSSH **22**, dropbear **2222**, plus the local screen and the Sky1 serial console (`ttyAMA0` / `ttyAMA2`, 115200) |
| Network | DHCP only (`ncz-rescue-net`); no fixed address |

Connect from another machine on the LAN:

```bash
ssh root@<rescue-ip>                 # password: rescue
ssh -p 2222 root@<rescue-ip>         # dropbear, if OpenSSH misbehaves
telnet <rescue-ip> 23
```

**Change it** from inside the rescue system with `passwd`. The rescue partition
keeps that change across reboots; reinstalling the machine sets `rescue` again.

**Lost a changed rescue password?** Nothing needs to be wiped: boot your
installed system (or the installer's Rescue entry), mount the rescue partition
and reset root there:

```bash
sudo mkdir -p /mnt/ncz-rescue
sudo mount LABEL=NCZRESCUE /mnt/ncz-rescue
sudo chroot /mnt/ncz-rescue passwd root
sudo umount /mnt/ncz-rescue
```

The recovery container (`ncz-recovery`) and the failsafe console on port 2323
are described in [REMOTE-ACCESS.md](REMOTE-ACCESS.md); their logins are not
changed by anything on this page.

## Troubleshooting

| Symptom | Cause | What to do |
|---|---|---|
| `ssh root@<installer-ip>`: connection refused | The installer has not started sshd yet, or `ncz_diag=0` is on the boot line | Wait for the Alt+F3 summary that says sshd is listening; remove `ncz_diag=0` |
| Installer SSH rejects `rescue` | `ncz_diag_pw=` was set on the boot line | Use the password you set there (the banner says `set by ncz_diag_pw`) |
| No login line in the installer banner | `ncz_diag=0` on the boot line | Expected: diagnostics are off for this boot |
| Cannot find the installer's IP | Headless machine, no screen | Check the router's DHCP leases, or read Alt+F3 / the Sky1 serial console |
| Rescue SSH rejects `rescue` | The rescue password was changed with `passwd` | Reset it from the installed system as shown above |
| Rescue system has no network | No DHCP server on the wired port | Use the local screen or the serial console |
| `Host key verification failed` when reconnecting | Each install generates its own rescue SSH host keys | Remove the old entry: `ssh-keygen -R <rescue-ip>` |

## How the build checks this

- `build/test-recovery-logins.sh` checks that the installer's diagnostics login
  is the documented rescue login, that the banner, the dialogs and the progress
  screen show it, and that every path and command this page names exists.
- `build/test-ncz-ui.sh` checks the banner text, the `ncz_diag_pw` and the
  `ncz_diag=0` cases.
- The KVM install gate (`build/kvm-install-gate-gpt.sh`) fails when the boot
  banner on the serial console lacks the login line, and the installer UI
  check (`build/kvm-installer-ui-check.sh`, `--require-login-line`) fails when
  no captured screen shows it. Because the value is the published login, the
  saved gate logs and frames need no redaction.
