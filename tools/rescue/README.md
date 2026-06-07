# CIX mini rescue media

Builds a bootable ARM64 rescue ISO from the known-good R80 installer ISO.

Requirements:
- macOS `hdiutil`
- `bsdtar`
- Python 3

Default source ISO:
`/Users/jperlow/ncz-installer-cixmini-26.6-r80.iso`

Output ISO:
`/Users/jperlow/ncz-r80-rescue-cixmini.iso`

Rescue boot behavior:
- boots R80 installer kernel/initrd
- uses a preseed early command to configure network
- starts BusyBox HTTP file server on port 80
- starts an easy TCP rescue shell listener on port 2323 via BusyBox `nc`
- mounts discovered local filesystems read-only under `/target-ro/*`
- provides helper commands in `/rescue-tools`

Connect after boot:

```sh
nc <cixmini-ip> 2323
curl http://<cixmini-ip>/
```

Telnet note: the R80 installer initrd BusyBox does not include a `telnetd` applet. The rescue listener uses BusyBox `nc` for the same easy unauthenticated LAN rescue-shell purpose. If a future initrd includes `telnetd`, the script can start it too.
