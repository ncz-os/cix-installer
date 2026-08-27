# Remote access and recovery — what is enabled, and how to turn it off

NCZ-OS is built for **home users, hobbyists and lab benches** — single-board
machines on a home LAN behind a router. The defaults are set for that: several
remote-access paths are enabled, including **telnet**, so that a board you have
just broken is still reachable.

On a home network behind NAT, telnet is a convenience rather than a meaningful
exposure, and we treat it as such. **In an enterprise, on a shared network, on
a VPS, or on anything with a routable address, turn it off.** This page says
exactly what is enabled, why, and how to disable each part.

---

## What is enabled by default

| Service | Port | Auth | Notes |
|---|---|---|---|
| **OpenSSH** | 22 | password **and** key | `PermitRootLogin yes`, `PasswordAuthentication yes` |
| **telnetd** | 23 | password | via `openbsd-inetd`, runs as root, **plaintext** |
| **ncz-failsafe** | 2323 | password — default `failsafe`, **change it** | static busybox telnetd → root recovery shell |
| **ncz-recovery** container | 22 *(its own IP)* | password — default `recovery`, **change it** | `systemd-nspawn`, MACVLAN — appears as a **separate host** on your LAN |

### About the default passwords

`failsafe` and `recovery` are **published defaults**, documented here on
purpose. That is the same choice already made for the installer diagnostics
account (`diags`) and the rescue partition (`rescue`): a home-hobbyist image
that cannot be recovered is worse than one with a known break-glass credential
on a LAN with no public route.

Change them on any network you do not control. To bake a different one:

```bash
NCZ_FAILSAFE_PASS='<your passphrase>' make iso     # fixed passphrase
NCZ_FAILSAFE_PASS=random             make iso     # unique per install
NCZ_MGMT_PASS='<your passphrase>'    make iso     # recovery container
```

With `NCZ_FAILSAFE_PASS=random` the generated value is written to
`/etc/ncz/failsafe-password` (0600) and printed in the install log.

### What each one actually is

- **Telnet is unencrypted.** Credentials and session content cross the wire in
  cleartext, so anyone who can observe your traffic can read them. On a home
  LAN that means someone already inside your network; that is the risk you are
  accepting, and for most home setups it is a small one.
- **`ncz-failsafe` on :2323 is a root shell.** It exists to survive a system
  broken badly enough that SSH will not start, so it deliberately depends on
  almost nothing.
- **The recovery container takes its own DHCP lease.** With `MACVLAN` it is a
  second machine on your network, with its own IP and its own SSH daemon, and
  it runs `PrivateUsers=no` so there is no user-namespace isolation from the
  host. Worth knowing if you are counting devices on your LAN.

**Rule of thumb:** home LAN behind a router — fine, leave it. Anything an
employer, a customer, or the public internet can reach — disable it.

## Why it ships this way

These boards are frequently headless, and several models have **no usable
serial console** — on Sky1, `ttyAMA2` is the board's port, and it is neither
present on every model nor reachable on every chassis. A kernel or driver
change that breaks the display or the network stack can otherwise leave a
machine with no way in at all, and this distribution changes kernels and GPU
drivers often.

Telnet and the failsafe console are the lockout path of last resort: they
depend on almost nothing, so they keep working when the things SSH needs are
broken. For a hobbyist with one board on a desk and no serial adapter, that is
the difference between a five-minute fix and a reflash.

It is an availability decision for home and lab hardware. It is not a security
posture, and we do not pretend otherwise.

---

## Turning it off

### Everything at once

```bash
sudo systemctl disable --now openbsd-inetd telnetd.socket ncz-failsafe.service \
                              systemd-nspawn@ncz-recovery.service
sudo systemctl mask telnetd.socket ncz-failsafe.service \
                    systemd-nspawn@ncz-recovery.service
```

`telnetd.socket` is in that list because telnet on :23 ships two ways. If
`inetutils-telnetd` / `openbsd-inetd` were unavailable at install time, the
installer falls back to a busybox `telnetd.socket` unit instead
(`post-install/36-telemetry.sh`). Disabling only `openbsd-inetd` on such an
image leaves a plaintext root telnet running. Do not trust either command to
have worked -- confirm with the `ss` check at the end of this page, which is
the authoritative test.

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
