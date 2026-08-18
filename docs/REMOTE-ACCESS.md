# Remote access and recovery — what is enabled, and how to turn it off

> **Read this before putting an NCZ-OS machine on an untrusted network.**

NCZ-OS ships with several remote-access paths enabled by default, including
**telnet**. This is a deliberate choice for the hardware this distribution
targets, and it is the wrong default for some deployments. This page states
exactly what is enabled, why, and how to disable each part.

---

## What is enabled by default

| Service | Port | Auth | Notes |
|---|---|---|---|
| **OpenSSH** | 22 | password **and** key | `PermitRootLogin yes`, `PasswordAuthentication yes` |
| **telnetd** | 23 | password | via `openbsd-inetd`, runs as root, **plaintext** |
| **ncz-failsafe** | 2323 | none by default | static busybox telnetd → root recovery shell |
| **ncz-recovery** container | 22 *(its own IP)* | password | `systemd-nspawn`, MACVLAN — appears as a **separate host** on your LAN |

### Be clear about what this means

- **Telnet is unencrypted.** Credentials and session content cross the network
  in cleartext. Anyone who can see your traffic can read them.
- **`ncz-failsafe` on :2323 is a root shell.** It exists to survive a system
  broken badly enough that SSH cannot start, which means it deliberately does
  not depend on the things that usually protect it.
- **The recovery container takes its own DHCP lease.** With `MACVLAN` it is a
  second machine on your network with its own IP and its own SSH daemon. It
  runs with `PrivateUsers=no`, so there is no user-namespace isolation between
  it and the host.

**On a trusted, isolated lab network this is a reasonable engineering trade.
On a shared office network, a VPS, or anything internet-facing, it is not.**

## Why it ships this way

These boards are frequently headless, and several models have **no usable
serial console** — on Sky1, `ttyAMA2` is the board's port, and it is not
present on every model or reachable on every chassis. A kernel or driver
change that breaks the display or the network stack can leave a machine with
no way in at all, and this distribution changes kernels and GPU drivers
often.

Telnet and the failsafe console exist as a lockout-recovery path of last
resort: they depend on almost nothing, so they keep working when the parts
that SSH depends on are broken. That is the entire justification. It is a
development-hardware decision, not a security posture.

---

## Turning it off

### Everything at once

```bash
sudo systemctl disable --now openbsd-inetd ncz-failsafe.service \
                              systemd-nspawn@ncz-recovery.service
sudo systemctl mask ncz-failsafe.service systemd-nspawn@ncz-recovery.service
```

Then harden SSH (see below). Verify with the checks at the end of this page.

### Telnet only

```bash
sudo systemctl disable --now openbsd-inetd
# and remove it entirely if you prefer:
sudo apt-get purge -y inetutils-telnetd openbsd-inetd
```

### The failsafe console (:2323)

```bash
sudo systemctl disable --now ncz-failsafe.service
sudo systemctl mask ncz-failsafe.service     # prevents re-enable by an update
```

`mask` matters here: this unit is intended to be hard to lose, so a plain
`disable` may not be enough if a later package update re-enables it.

### The recovery container

```bash
sudo systemctl disable --now systemd-nspawn@ncz-recovery.service
sudo systemctl mask systemd-nspawn@ncz-recovery.service
```

To remove it entirely and free the disk it occupies:

```bash
sudo machinectl remove ncz-recovery
```

### Harden SSH

The defaults permit root login and password authentication. To require keys
and forbid direct root login:

```bash
sudo tee /etc/ssh/sshd_config.d/99-harden.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sudo systemctl restart ssh
```

> **Install your SSH key first and confirm it works in a second session.**
> Applying this with no working key is exactly the lockout these recovery
> paths exist for — and you may have just disabled them.

---

## Verifying

```bash
# Nothing should be listening on 23 or 2323
sudo ss -tlnp | grep -E ':(23|2323)\b' || echo "telnet paths closed"

# The recovery container should be gone from the machine list
machinectl list

# Confirm the SSH policy actually in effect
sudo sshd -T | grep -iE '^(permitrootlogin|passwordauthentication)'
```

Check from **another machine** as well — a service can be bound to an
interface you did not expect:

```bash
nmap -p 22,23,2323 <the-machine-ip>
```

---

## If you lock yourself out anyway

That is what the rescue partition is for, and it is independent of everything
above. Select **NCZRESCUE** from the boot menu: it carries a full toolset and
self-configuring networking, and it is validated as a release gate on every
build. Mount the root filesystem from there and undo whatever went wrong.

## See also

- [`docs/releases/`](releases/) — per-release notes
- [`DESIGN-RATIONALE.md`](DESIGN-RATIONALE.md) — the reasoning behind
  distribution-level choices, tagged MEASURED / DECIDED / OPEN
