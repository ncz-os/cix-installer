# assets/sinty-nm — native Singularity network daemon

`sinty-nm` (github.com/singularityos-lab/sinty-nm) is the NATIVE network manager
for the Singularity Desktop. It is a static Go daemon (`/usr/bin/sinty-nmd`) that
**owns `org.freedesktop.NetworkManager`** on the system bus and serves the same
object tree, so `nmcli`, libnm, xdg portals, and the panel network indicator all
keep working unchanged. It is a full **NetworkManager REPLACEMENT** (not a
frontend):

- WiFi via **iwd** (`net.connman.iwd`)
- L2/L3 via **rtnetlink**
- IPv4 via a **built-in DHCP client**
- VPN via **WireGuard** (`wireguard-tools`)

NCZ-OS 26.7 ships this in place of NetworkManager. `post-install/19-sinty-nm.sh`
installs the daemon in the base layer, purges + masks NetworkManager (two
daemons cannot own the name), installs the backends (iwd, wireguard-tools), and
enables `sinty-nm.service`.

## Files

| File | Installed to | Tracked? |
|---|---|---|
| `sinty-nmd` | `/usr/bin/sinty-nmd` | **gitignored build blob** |
| `sinty-nm.service` | `/usr/lib/systemd/system/sinty-nm.service` | yes |
| `org.freedesktop.NetworkManager.conf` | `/usr/share/dbus-1/system.d/` | yes |

## Rebuilding the binary (arm64, static)

Built in an `ubuntu:26.04` arm64 container (matches O6N / .66) with the official
Go 1.25 toolchain (go.mod requires `go 1.25.0`):

```sh
git clone --depth 1 https://github.com/singularityos-lab/sinty-nm.git
cd sinty-nm
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o sinty-nmd ./cmd/sinty-nmd
```

Stage the resulting `sinty-nmd` here (or fetch from
`.66:/home/jasonperlow/sinty-build/nm-build/out/sinty-nmd`).
`build/build-squashfs-layers.sh` copies it into the base layer so console and
desktop installs share the same network owner.

For NCZ-OS 26.7, build from Sinty commit `7a5d49e` or later. That revision marks
its optional iwd D-Bus calls `FlagNoAutoStart`, preventing a 25-second boot delay
on wired-only O6 systems where iwd is correctly skipped for lack of Wi-Fi hardware.

## Notes

- sinty-nm writes `/etc/resolv.conf` **directly**, so it must be a writable
  regular file (19-sinty-nm de-symlinks it).
- iwd is installed even on ethernet-only boards (O6N) for fleet completeness.
