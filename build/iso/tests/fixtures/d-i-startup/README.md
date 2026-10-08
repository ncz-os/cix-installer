# d-i preseed startup fixtures (real upstream)

Byte-for-byte copies of the Debian installer startup scripts that decide
whether the baked `/preseed.cfg` is loaded once or twice. They are vendored so
`build/iso/tests/test-single-preseed.sh` exercises the real upstream ordering
instead of a reimplementation.

Source: official Debian forky netboot initrds (`deb.debian.org`), extracted
2026-10-08 by the read-only preseed/wall-clock investigation:

| initrd | url | sha256 |
|---|---|---|
| amd64 | `dists/forky/main/installer-amd64/current/images/netboot/debian-installer/amd64/initrd.gz` | `d1a74bab79df5684fe7ceea9b628c9e2b45178a36db86249fcb1dc6e95ae7c64` |
| arm64 | `dists/forky/main/installer-arm64/current/images/netboot/debian-installer/arm64/initrd.gz` | `f6c78af7078ca67638ef3a50c926cd3c1485673243f8b37952e6bd854d6ba007` |

The amd64 and arm64 copies are identical files (same sha256); both directories
are kept so the test iterates per architecture exactly as the Install entry
does.

File sha256:

| file | sha256 |
|---|---|
| `amd64/S30initrd-preseed`, `arm64/S30initrd-preseed` | `f58151f324dca1c2ab7d4e5f6ea00fadc5f528bb557dc95d692619d0e4e0d909` |
| `amd64/S33preseed_early_command`, `arm64/S33preseed_early_command` | `14d262783aa4b861afc0727a147da543ed68dc52e0e2439329c4e30b177f8c4f` |
| `amd64/S60auto-install`, `arm64/S60auto-install` | `1ad20dcaca5d61aa5734d6f6049cbc3b33f80d134f832e54afe6580a0699c4dd` |
| `file-preseed.isinstallable` | `1efc378303cb071bc479f96a5369ea06700d8b94075af9002b658ca9a5a97265` |

How the test uses them:

1. Copies them into a sandbox under the project-local tmp dir
   (`.test-tmp/`, never `/tmp`).
2. Rewrites the absolute paths (`/preseed.cfg`, `/lib/preseed/preseed.sh`,
   `/usr/share/debconf/confmodule`, `/var/run/`) to sandbox paths **in the
   sandbox copy only**; the production `preseed/preseed.cfg` is untouched.
3. Sources them in d-i's lexical `S*` order (S30, S33, S60) plus the baked
   `S61ncz-preseed-reenable` hook read from `patch-initrd-t2-kernel.py`, and
   asserts one `preseed_location`, one `preseed/early_command`, the restored
   `auto-install.active=0`, and the naive-S33 `echo 0` failure mode.
4. Runs the real `file-preseed.isinstallable` to prove that with `preseed/file`
   empty the udeb is not installed (no second preseed load).
