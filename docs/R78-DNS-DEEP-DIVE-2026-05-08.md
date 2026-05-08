# R78 DNS deep dive - Cix Sky1 .66 pkgsel failure

Date: 2026-05-08
Target: Cix Sky1 / Minisforum MS-R1 at 192.168.207.66
Installer: NCZ Reinhardt-Magnetar r78, cix-installer `fb6a125`

## 1. Authoritative answer: who writes resolv.conf

Short answer: netcfg and busybox-udhcpc write the installer ramdisk
`/etc/resolv.conf`; base-installer/pkgsel do not invent DNS. Apt commands run
inside `/target`, so they use `/target/etc/resolv.conf`. In this cix-installer
flow, `/target/etc/resolv.conf` starts from the extracted Ubuntu rootfs, not
from netcfg, unless we explicitly write it.

Actual sequence:

1. `preseed/early_command` runs first and launches `preseed/sshd-watcher.sh`
   (`preseed/preseed-ubuntu.cfg:117-135`). Any file it writes in the ramdisk is
   still vulnerable to later netcfg DHCP writes.

2. netcfg starts DHCP. In trixie netcfg 1.197, `dhcp.c` invokes `udhcpc` with
   the d-i vendor class and requested DHCP options, including DNS. The
   busybox-udeb default script path is `/etc/udhcpc/default.script`; Debian bug
   927413 documents that script as the one run by udhcpc inside d-i and that it
   transfers DNS into `/etc/resolv.conf`.
   - Source: `netcfg-1.197/dhcp.c:41-47`, `netcfg-1.197/dhcp.c:430-457`
   - Source: busybox-udeb bug 927413, `/etc/udhcpc/default.script`

3. netcfg then reads DNS back from `RESOLV_FILE` into its interface struct and
   rewrites `/etc/resolv.conf` itself. The key point is the second write:
   `netcfg_write_resolv(...)` in `static.c` opens `RESOLV_FILE` with `"w"` and
   emits the domain/search line plus every `interface->nameservers[i]`.
   - Source: `netcfg-1.197/dhcp.c:511`, `netcfg-1.197/dhcp.c:614`
   - Source: `netcfg-1.197/static.c:258-271`
   - Source: Debian bug 1069897 explicitly calls out this overwrite path.

4. `netcfg/get_nameservers` is not a DHCP fallback chain. In DHCP mode netcfg
   only asks/uses that value if DHCP produced zero nameservers:
   `if (nameserver_count(interface) == 0) ... netcfg_get_nameservers(...)`.
   With DHCP returning `192.168.207.1`, the preseeded
   `192.168.207.1 8.8.8.8 1.1.1.1` is ignored.
   - Source: `netcfg-1.197/dhcp.c:499-508`
   - Local config: `preseed/preseed-ubuntu.cfg:39-44`

5. base-installer does not copy `/etc/resolv.conf` to `/target/etc/resolv.conf`
   as a separate step. Its relevant flow is waypoints: `install_base_system`,
   then `pre_install_hooks`, `setup_dev`, `configure_apt`, and `apt_update`.
   `apt_update` is a chrooted apt command.
   - Source: `base-installer-1.226/debian/bootstrap-base.postinst:143-157`
   - Source: `base-installer-1.226/library.sh:171-176`

6. In normal debootstrap, debootstrap may copy local config into the target.
   This ISO bypasses real debootstrap with the r40/r43 stub. The stub extracts
   the Ubuntu rootfs and only does:
   `[ -e "$TARGET/etc/resolv.conf" ] || touch "$TARGET/etc/resolv.conf"`.
   If the rootfs already has the systemd-resolved symlink, the stub preserves
   it.
   - Local source: `build/build-iso-di.sh:679-681`

7. pkgsel runs package operations inside `/target`. Its `pre-pkgsel.d` hooks
   run in the installer environment, but package installs/upgrades use
   `apt-install` or `in-target`, both ending in `chroot /target ...`. Therefore
   glibc resolver reads `/target/etc/resolv.conf`.
   - Source: `pkgsel-0.85/debian/postinst:90-132`
   - Supporting process evidence: Debian bug 760144 shows pkgsel invoking
     `/bin/in-target`, which invokes `chroot /target`.

8. The `/target/etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf`
   symlink is expected for a systemd-resolved-managed rootfs. Debian trixie
   `systemd-resolved.postinst` converts `/etc/resolv.conf` to that symlink on
   new installs/upgrades, copying the old file into the stub first.
   - Source: `systemd-257.9-1~deb13u1/debian/systemd-resolved.postinst:87-95`
   - Source: `systemd-resolved.service(8)` documents the stub-resolv mode.

## 2. Why take15, take17, and take18 fail

Take15: wrong effective layer. Replacing `/etc/udhcpc/default.script` can affect
the initial udhcpc callback, but netcfg rewrites `/etc/resolv.conf` after DHCP
from its own `interface->nameservers` state. Also, replacing the whole d-i
default script is riskier than patching it because the stock script feeds d-i
side files such as `/tmp/domain_name`.

Take17: copied the wrong source at the wrong time. The diag showed:

```
/etc/resolv.conf: nameserver 192.168.207.1
/target/etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf
/target content: nameserver 192.168.207.1
```

That is exactly what the source predicts. DHCP supplied one resolver, netcfg
accepted it and ignored `netcfg/get_nameservers`, then the watcher copied that
single resolver into the target. The one sync log at 04:57:15 is consistent
with `/target/etc` appearing once and then `cmp -s` seeing identical content.

Take18: right intent, still race-prone. It writes the target file every second,
but it is still a background daemon tied to `sshd-watcher.sh`'s 1800 second
loop (`preseed/sshd-watcher.sh:165-208`). The take17 timestamps are already
suspicious: watcher start at install time, target sync at 04:57:15, pkgsel
failure at 05:02:31. A 30 minute watchdog can expire during the long base/pkgsel
path on this hardware. Once it exits, later target writes from systemd-resolved
postinst or any unchanged single-NS target file can win.

Important: the symlink itself is not the primary bug. `cat >
/target/etc/resolv.conf` follows the symlink and can work if the target exists.
The bug is relying on a long-running watcher instead of writing the target
resolver at d-i's actual pre-apt hook points.

## 3. Recommended fix

Best preseed-only fix, if .66 can be treated as static: set static IPv4 in
netcfg so netcfg's own writer emits the desired DNS:

```cfg
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/disable_autoconfig seen true
d-i netcfg/get_ipaddress string 192.168.207.66
d-i netcfg/get_ipaddress seen true
d-i netcfg/get_netmask string 255.255.255.0
d-i netcfg/get_netmask seen true
d-i netcfg/get_gateway string 192.168.207.1
d-i netcfg/get_gateway seen true
d-i netcfg/get_nameservers string 192.168.207.1 8.8.8.8 1.1.1.1
d-i netcfg/get_nameservers seen true
d-i netcfg/confirm_static boolean true
d-i netcfg/confirm_static seen true
```

This is source-clean, but it is machine-specific and still does not repair the
pre-extracted Ubuntu target symlink before base-installer/pkgsel apt unless the
target is also written.

Recommended take19 fix: install deterministic d-i hook scripts from
`early_command`. Use `base-installer.d` before base-installer's chrooted
`apt-get update`, and `pre-pkgsel.d` immediately before pkgsel package work.
This hits the actual `/target/etc/resolv.conf` consumer and does not depend on
a daemon staying alive.

Concrete patch:

```diff
diff --git a/preseed/sshd-watcher.sh b/preseed/sshd-watcher.sh
index 0000000..0000000 100755
--- a/preseed/sshd-watcher.sh
+++ b/preseed/sshd-watcher.sh
@@
 set +e
 exec >> /var/log/early_command.log 2>&1
 echo "[watcher] start $(date -u +%FT%TZ) pid=$$"
+
+install_ncz_dns_hooks() {
+    mkdir -p /usr/lib/base-installer.d /usr/lib/pre-pkgsel.d
+    cat > /usr/lib/base-installer.d/05ncz-dns <<'NCZDNSHOOK'
+#!/bin/sh
+set +e
+LOG=/var/log/early_command.log
+router="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
+[ -n "$router" ] || router=192.168.207.1
+
+if [ -d /target/etc ]; then
+    rm -f /target/etc/resolv.conf
+    cat > /target/etc/resolv.conf <<EOF
+search nclawzero.lan
+nameserver $router
+nameserver 8.8.8.8
+nameserver 1.1.1.1
+options timeout:2 attempts:3
+EOF
+    echo "[ncz-dns] wrote /target/etc/resolv.conf router=$router at $(date -u +%FT%TZ)" >> "$LOG"
+else
+    echo "[ncz-dns] /target/etc missing at $(date -u +%FT%TZ)" >> "$LOG"
+fi
+exit 0
+NCZDNSHOOK
+    chmod 0755 /usr/lib/base-installer.d/05ncz-dns
+    cp /usr/lib/base-installer.d/05ncz-dns /usr/lib/pre-pkgsel.d/05ncz-dns
+    echo "[watcher] installed ncz DNS hooks for base-installer + pre-pkgsel"
+}
+install_ncz_dns_hooks
@@
-while [ "$i" -lt 1800 ]; do
+while :; do
@@
-done
-
-if [ "$SSHD_PATCHED" -eq 0 ]; then
-    echo "[watcher] TIMEOUT after 1800s - sshd never came up"
-    exit 1
-fi
-echo "[watcher] TIMEOUT after 1800s with sshd patched - install presumed complete"
-exit 0
+done
```

Also do this cleanup in the same patch if time permits: delete the old
`/etc/udhcpc/default.script` replacement block from `sshd-watcher.sh`. It is
not the right layer. If you keep it for take19, the new hooks are still the
decisive fix.

Last resorts, ranked:

1. Local LAN apt proxy or mirror. Good operational mitigation, but it dodges
   the d-i resolver bug instead of fixing it.
2. Hard-code `ports.ubuntu.com` IPs in apt sources. Use only for emergency
   rescue; CDN IPs change and HTTPS/SNI can break.

## 4. Verification plan

During take19, after partitioning starts or before pkgsel:

```bash
bash tools/di-diag.sh 192.168.207.66 'echo ==hooks==; ls -l /usr/lib/base-installer.d/05ncz-dns /usr/lib/pre-pkgsel.d/05ncz-dns 2>&1; echo ==log==; grep -E "\[watcher\] installed ncz DNS|\[ncz-dns\]" /var/log/early_command.log 2>&1; echo ==ramdisk==; cat /etc/resolv.conf 2>&1; echo ==target==; ls -l /target/etc/resolv.conf 2>&1; cat /target/etc/resolv.conf 2>&1'
```

Expected proof:

- `early_command.log` contains `[watcher] installed ncz DNS hooks...`.
- Before base-installer apt update, log contains `[ncz-dns] wrote
  /target/etc/resolv.conf router=192.168.207.1 ...`.
- `/target/etc/resolv.conf` is a regular file, not the systemd-resolved symlink.
- It contains exactly:

```text
search nclawzero.lan
nameserver 192.168.207.1
nameserver 8.8.8.8
nameserver 1.1.1.1
options timeout:2 attempts:3
```

If pkgsel fails again, collect this immediately:

```bash
bash tools/di-diag.sh 192.168.207.66 'echo ==time==; date -u; echo ==watcher==; ps | grep -E "[s]shd-watcher|[n]cz-dns"; echo ==resolv==; ls -l /target/etc/resolv.conf; cat /target/etc/resolv.conf; echo ==chroot-dns==; chroot /target getent ahosts ports.ubuntu.com 2>&1 | head; echo ==direct==; nslookup ports.ubuntu.com 8.8.8.8 2>&1 | head -20; echo ==apt-errors==; grep -iE "temporary failure resolving|failed to fetch|ports.ubuntu.com|ncz-dns" /var/log/syslog /var/log/installer/syslog 2>/dev/null | tail -80'
```

If `/target/etc/resolv.conf` is still three-NS at failure time and direct
8.8.8.8 resolves, then the next layer to inspect is apt's resolver behavior or
network reachability from inside the chroot. If `/target/etc/resolv.conf` is
back to the symlink or single-NS, the hook did not run late enough; add the
same `05ncz-dns` script to `/usr/lib/finish-install.d/` only for post-pkgsel
late operations, not as the pkgsel fix.

## Sources

- netcfg 1.197 source index:
  https://sources.debian.org/src/netcfg/1.197/
- netcfg DHCP and resolver source files:
  https://sources.debian.org/src/netcfg/1.197/dhcp.c/
  https://sources.debian.org/src/netcfg/1.197/static.c/
- netcfg overwrite discussion and patch context:
  https://bugs-devel.debian.org/1069897
- busybox-udeb `/etc/udhcpc/default.script` in d-i:
  https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=927413
- base-installer 1.226 package/source identity:
  https://packages.debian.org/source/trixie/i386/base-installer
- base-installer 1.226 source paths:
  https://sources.debian.org/src/base-installer/1.226/library.sh/
  https://sources.debian.org/src/base-installer/1.226/debian/bootstrap-base.postinst/
- base-installer library flow, same code path shown in Debian Sources:
  https://sources.debian.org/src/base-installer/1.213/library.sh/?hl=737
- pkgsel 0.85 package/source identity:
  https://packages.debian.org/trixie/pkgsel
- pkgsel 0.85 postinst source path:
  https://sources.debian.org/src/pkgsel/0.85/debian/postinst/
- systemd-resolved trixie package:
  https://packages.debian.org/trixie/systemd-resolved
- systemd-resolved postinst:
  https://sources.debian.org/src/systemd/257.9-1~deb13u1/debian/systemd-resolved.postinst
- systemd-resolved `/etc/resolv.conf` modes:
  https://manpages.debian.org/unstable/systemd-resolved/systemd-resolved.service.8.en.html
