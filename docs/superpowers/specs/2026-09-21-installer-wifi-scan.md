# Installer WiFi scan / SSID select / WPA-prompt

Status: implementation complete 2026-09-21 on branch
`wip/installer-wifi-scan-2026-09-21`. Wired-unattended path regression
verified by focused unit-level simulation of the modified
`preseed/early_command` carrier-poll block (QEMU/KVM gate end-to-end was
not run — see "Verification gaps" below). Wireless path itself CANNOT be
end-to-end validated in this environment; see "What real-hardware
validation would still be needed".

## Scope

Wire Debian's own native `netcfg` wireless flow (scan → SSID select →
WPA passphrase) into the d-i ramdisk so a WiFi-only box can complete
install + get network during install. No custom UI. The change is
config/packaging only — no upstream d-i patches.

## Diagnosis (what was actually broken)

Verified against the substrate ISO at
`downloads/debian-testing-amd64-netinst.iso` (Debian forky, 2026-09-21):

1. **`preseed/preseed.cfg:28-29`** had `d-i netcfg/choose_interface select
   auto` + `seen true`. With `seen true`, `netcfg_get_interface()`
   silently uses `defif` (the carrier-detected NIC) and **never renders
   the "Primary network interface" dialog**. Netcfg's WCONFIG state
   machine (which runs `iw_scan` + the WPA passphrase UI) is unreachable
   on a WiFi-only box.

2. **`build/build-iso-di.sh:2598`** had
   `PRUNE_NET_DIRS="bluetooth mac80211 wireless"`. The installer initrd
   cpio overlay dropped `kernel/net/mac80211/` and `kernel/net/wireless/`
   (cfg80211 + softMAC subsystem) so even with the right udebs staged,
   no in-kernel WiFi driver could associate.

3. **`assets/firmware/iwlwifi/`** and **`assets/firmware/regdb/`** were
   staged into the INSTALLED system only. The installer initrd had no
   `/lib/firmware/iwlwifi/*.ucode` and no `regulatory.db{,.p7s}`, so
   even with `cfg80211` + `mac80211` present, an Intel WiFi card would
   probe, fail to load firmware, and silently refuse to associate.

4. **`REQUIRED_DI_UDEBS` (build-iso-di.sh:1043)** did not list
   `wpasupplicant-udeb` or its `libnl*` / `libiw30-udeb` /
   `wireless-regdb-udeb` / `wireless-tools-udeb` deps. Verified against
   the substrate's own
   `dists/forky/main/debian-installer/binary-amd64/Packages` index
   (extracted 2026-09-21 from the substrate ISO):
   the substrate's offline `pool/main/` DOES contain all six udebs today
   (`wpasupplicant-udeb_2.10-25+b2_amd64.udeb` etc. — verified), so the
   current build's `Step 1` capture → `Step 4` merge does land them in
   the offline pool. But there's no safety belt — a future substrate
   that drops any of them would silently break the wireless path.

There is no `firmware-iwlwifi-udeb` or any other `firmware-*-udeb`
family in the forky substrate's debian-installer index. This is by
design — d-i loads wifi firmware from the initrd's `/lib/firmware`
just like the r79 `rtl_nic` blob (see `build-iso-di.sh:2623`), not
via the udeb pool.

## Changes (4 files)

### 1. `build/build-iso-di.sh`

**(a) `REQUIRED_DI_UDEBS` extended (line 1056).** Added
`wpasupplicant-udeb`, `wireless-regdb-udeb`, `wireless-tools-udeb`,
`libiw30-udeb`, `libnl-3-200-udeb`, `libnl-genl-3-200-udeb` to the
list. Each is fetched by `ensure_di_udeb_from_archive` if not present
in the substrate pool — verified all six are available at
`deb.debian.org/debian/dists/forky/main/debian-installer/binary-amd64/Packages.gz`
(today's substrate is forky; the same udebs also exist in the substrate
pool at `pool/main/w/wpa/` etc.). After the udeb harvest, the offline
udeb Packages index is regenerated at line 2357 by `dpkg-scanpackages
--type udeb`, so netcfg's `apt-install wpasupplicant` finds it via the
embedded `/dists/<suite>/main/debian-installer/binary-<arch>/Packages`.

**(b) `PRUNE_NET_DIRS` was `"bluetooth mac80211 wireless"` →
`"bluetooth"` (line 2634).** The kernel modules for `cfg80211`,
`mac80211`, and `drivers/net/wireless/{realtek,intel,ath,mediatek}/`
are now staged into the installer initrd cpio overlay. Size delta:
`cfg80211.ko` + `mac80211.ko` ~ 2 MB uncompressed; all
`drivers/net/wireless/*` combined ~ 35 MB (compresses well in the cpio).

**(c) `iwlwifi` + `regdb` firmware staged into the installer initrd
(line 2685, alongside the existing `rtl_nic` block at 2623).** Exactly
the same shape as r79's `rtl_nic` — copy blobs from
`assets/firmware/{iwlwifi,regdb}` into `$WORK/lib/firmware/`, log the
count, warn (don't fail) if absent. The installed system already gets
these blobs via `post-install/12-sky1-firmware.sh`; staging them into
the initrd too keeps installer + OS agreeing on supported chip
revisions.

### 2. `preseed/preseed.cfg`

**(a) `d-i preseed/early_command` extended (line ~282).** The existing
carrier-poll block already waited 25 s for `/sys/class/net/*/carrier=1`
and on success did `db_set netcfg/choose_interface <iface>; db_fset
seen true`. The new block:

* After the carrier poll, enumerates `/sys/class/net/<if>/wireless/` and
  `/sys/class/net/<if>/phy80211` to detect a wireless iface. Detection
  relies on mac80211+cfg80211 being loaded — that's why the
  carrier-poll's existing loop already installs
  `nic-wireless-modules-*.udeb` before this block.
* udpkg-installs `wireless-regdb-udeb`, `libnl-3-200-udeb`,
  `libnl-genl-3-200-udeb`, `libiw30-udeb`, `wpasupplicant-udeb`,
  `wireless-tools-udeb` from `/cdrom/pool/main/.../`. udpkg resolves
  hard Depends from the local pool. Order: regulatory.db first so
  cfg80211 validates on first iface-up, then the libnl/libiw chain,
  then wpasupplicant itself. Failure of any single udpkg is non-fatal.
* Three-branch dispatch on `PICKED_IF` / `WIRELESS_IF`:
    1. **WIRED PATH** (`PICKED_IF != ""`) — unchanged from before:
       `db_set choose_interface <iface>; db_fset seen true`. Netcfg
       silently picks the wired NIC.
    2. **NO-LINK + WIRELESS-PRESENT** (`PICKED_IF == ""`,
       `WIRELESS_IF != ""`) — new: `db_reset netcfg/choose_interface`
       (clears value AND clears seen flag) + `db_fset seen false` (redundant
       but explicit) + `db_reset netcfg/wireless_wep` (the WEP field
       already preseeded empty on line 41; this resets the seen flag
       for open-network paths). Netcfg's `netcfg_get_interface()` then
       renders the "Primary network interface" dialog with the wireless
       ifname as `defif` default. Operator picks wireless → `is_wireless_iface()`
       returns 1 → state = `WCONFIG` →
       `apt-install iw wireless-tools` (already in pool, no-op) →
       `WCONFIG_ESSID`: `iw_scan` populates `netcfg/wireless_show_essids`
       → operator picks SSID → `WCONFIG_SECURITY_TYPE` → operator
       picks WPA → `WCONFIG_WPA`:
       `apt-install wpasupplicant` (already in pool, no-op) + a
       passphrase prompt → `START_WPA`: wpa_supplicant started →
       `GET_DHCP`: dhclient → network up during install.
    3. **NO-LINK + NO-WIRELESS** (`PICKED_IF == ""`,
       `WIRELESS_IF == ""`) — unchanged from before: no db calls; the
       preseed's `choose_interface=auto seen=true` survives; netcfg
       raises its standard "Network autoconfiguration failed" critical
       prompt. The r79 "wired is required" doctrine is preserved
       exactly.

**(b) Network section comment expanded (line 25).** The
`d-i netcfg/choose_interface select auto` + `seen true` lines are NOT
changed — the new behavior is controlled entirely by the early_command's
`db_reset + db_fset seen false` write, which overrides the preseed
template's `seen true` via cdebconf's last-write-wins semantics. The
comment block now explains the three-path contract and what each does,
with explicit reference to netcfg's `netcfg_get_interface()` semantics
(cited to Debian bug #700292 and the upstream netcfg.c source).

### 3. `sbom/expected-udebs.txt`

Added the same six new udebs to the verifier manifest, with a comment
pointing at the substrate Packages index as the source of truth and
explaining the safety-belt purpose.

## Verification

### What was verified in this environment

1. **`bash -n` syntax check** on both `build/build-iso-di.sh` and the
   embedded `preseed/early_command` shell body. Both pass.
2. **`build/verify-udebs.sh`** (the SBOM gate that greps the build
   script for each expected udeb name) — **PASS** with the expanded
   `REQUIRED_DI_UDEBS` list. Confirms all six new udebs are wired
   into the build flow.
3. **Substrate udeb-pool audit.** All six new udebs (`wpasupplicant-udeb`,
   `wireless-regdb-udeb`, `wireless-tools-udeb`, `libiw30-udeb`,
   `libnl-3-200-udeb`, `libnl-genl-3-200-udeb`) were verified to exist
   in the substrate's own `dists/forky/main/debian-installer/binary-amd64/Packages.gz`
   index. The substrate's `pool/main/w/wpa/wpasupplicant-udeb_2.10-25+b2_amd64.udeb`
   is captured by build-iso-di.sh's `Step 1` (line 854) and merged
   into the offline pool by `Step 4` (line 948). dpkg-scanpackages
   re-indexes the udeb pool at line 2357 so netcfg's `apt-install
   wpasupplicant` finds it via `/cdrom/dists/<suite>/main/debian-installer/binary-<arch>/Packages.gz`.
4. **On-demand mirror fetch.** All six new udebs verified present at
   `deb.debian.org/debian/dists/forky/main/debian-installer/binary-amd64/Packages.gz`,
   so `ensure_di_udeb_from_archive` will fetch them on any substrate
   that doesn't ship them in the offline pool.
5. **Kernel module audit.** `tar tzf assets/kernel/edge/modules-cixmini.tgz`
   shows `kernel/net/mac80211/mac80211.ko.xz`, `kernel/net/wireless/cfg80211.ko.xz`,
   and `kernel/drivers/net/wireless/{realtek/rtw89,intel/iwlwifi,ath/ath11k,ath/ath12k,mediatek}/...`
   are all built. With `mac80211 wireless` removed from
   `PRUNE_NET_DIRS`, these now reach the installer initrd.
6. **Firmware audit.** `assets/firmware/iwlwifi/` contains 70+ `.ucode`
   blobs (iwlwifi-105-6.ucode, iwlwifi-Qu-* , iwlwifi-7260-17.ucode,
   etc.) and `assets/firmware/regdb/` contains `regulatory.db` and
   `regulatory.db.p7s`. Both are staged into the installer initrd.
7. **Three-branch unit simulation.** The carrier-poll + branch-dispatch
   block from `preseed/preseed.cfg` (lines 281-354) was extracted,
   paths substituted to a `/tmp/wifi-test/fake/` chroot-like directory,
   `cdebconf` stubs provided as shell functions, and the body sourced
   in-shell under each of the three scenarios:

   | Scenario            | PICKED_IF | WIRELESS_IF | Resulting cdebconf state for `netcfg/choose_interface`             | PASS? |
   |---------------------|-----------|-------------|--------------------------------------------------------------------|-------|
   | Wired (KVM gate)    | `eth0`    | (none)      | `value=eth0`, `seen=true` (silent auto-pick, today's behavior)      | YES   |
   | Wireless only       | (none)    | `wlan0`     | `value=""`, `seen=false` (interactive prompt → operator picks wlan0)| YES   |
   | No network          | (none)    | (none)      | `value=""`, `seen=""` (preseed's auto+seen=true survives; netcfg raises "Network autoconfiguration failed") | YES |

   This is a focused unit test of the modified logic block, not a full
   d-i environment. The d-i cdebconf confmodule is mocked with a
   tab-separated text file acting as the confmodule db.

### What was NOT verified — explicit list

The following would require a real CI/build environment + hardware that
this session did not have:

1. **Full `make iso` end-to-end build.** This branch does not have the
   pre-staged `assets/squashfs/desktop-hotfix.squashfs`,
   `assets/python311/uv`, `assets/kernel/{amd64-stable,amd64-edge}/*.deb`,
   or `build/forky-mirror/` populated. A full build would need
   `make download`, `make vendor-mirror`, `make offline-mirror`,
   `make kernel-debs`, `make squashfs-layers` first — each of those is
   a multi-minute pipeline on its own. Not run in this session.
2. **Full `make iso-verified` (or `kvm-install-gate-amd64.sh`)
   regression run.** Even with a built ISO, the gate runs in QEMU/OVMF
   against a virtio NIC and asserts the install reaches the
   `Post-install completed successfully` log line. Attempted in this
   session by extracting `forky-amd64-stock-input-stock-qemutest.iso`,
   replacing its `cixmini/preseed.cfg` with the new one, and running
   `kvm-install-gate-amd64.sh`. The install boots, d-i detects the
   virtio NIC and runs our carrier-poll block, but the
   `partman/early_command` step fails with `Failed to run preseeded
   command` because the stock ISO is missing the rest of the `cixmini/`
   helper scripts (`disk-fs-chooser.sh`, `late.sh`, `extract-rootfs.sh`,
   `component-selector.sh`, `locale-keyboard-chooser.sh`, etc.) that
   those scripts depend on. This is a stock-ISO limitation, not a
   regression caused by the preseed changes — the cixmini tree only
   ships in a fully cix-installer-built ISO. Reproducing this
   regression test on a real cix-installer-built ISO would require
   the missing `make iso` pipeline above.
3. **End-to-end wireless path (the actual use case).** Even a full
   cix-installer-built ISO can't exercise the wireless path under
   QEMU/KVM because QEMU has no model for a real WiFi adapter — `iw_scan`
   has no APs to find. The wireless path can only be tested on hardware
   with a real wireless NIC. See "What real-hardware validation would
   still be needed" below.

### Verification gaps mitigated where possible

* The carrier-poll block has a clear bounded timeout (25 s, matching
  today's behavior). If the gate were to run with our changes, the
  block exits within 25 s on the wired path (the carrier comes up
  immediately on a virtio NIC), no behavioral difference from today.
* The `db_reset + db_fset seen false` write to `netcfg/choose_interface`
  is done in `preseed/early_command`, which runs AFTER the preseed
  template loads. cdebconf last-write-wins: the early_command's
  `seen=false` overwrites the preseed's `seen=true` for the
  wireless-fallback case only. The WIRED PATH early_command explicitly
  writes `seen=true`, which agrees with the preseed — no race.
* The early_command only fires the wireless branch when a wireless
  interface is genuinely detected via `/sys/class/net/<if>/wireless/`
  (kernel's cfg80211 registered it) or `/sys/class/net/<if>/phy80211`
  (mac80211 saw it). A board with no WiFi hardware at all takes the
  NO NETWORK branch, identical to today.

## What real-hardware validation would still be needed

The full wireless path — including the actual WPA-supplicant handshake
with a real AP — has to be tested on a board with a real wireless NIC
that the project's kernel supports. The two hardware platforms named
in the dispatch brief are good candidates:

### MEDUSA (recommended, once its own WiFi-firmware gap is fixed)

Per the dispatch brief, MEDUSA's own WiFi-firmware udeb problem is a
separate blocker that has to be addressed first. Once that's resolved,
MEDUSA should validate:

1. **Cold-boot install on MEDUSA with NO wired NIC plugged in.** Confirm:
   - The carrier-poll block reports no carrier (expected).
   - `WIRELESS_IF` is set to MEDUSA's wireless ifname (likely
     `wlan0` or `wlp3s0u1` depending on udev naming).
   - Netcfg renders the "Primary network interface" dialog.
   - The wireless-scan step finds the test AP's SSID.
   - WPA passphrase entry succeeds.
   - DHCP over WiFi gets an address + default route.
   - The rest of the install proceeds (network up).
2. **Same scenario with `ncz_unattended=1` on the kernel cmdline**
   (the unattended flag is set by `kvm-install-gate*.sh`). Should
   either:
   - Stall at the SSID-select prompt (expected — no operator), OR
   - Continue unattended if `preseed` ever adds a WPA-PSK key
     (currently NOT implemented — unattended WPA needs a different
     preseed key; see "Open follow-ups" below).
3. **Hot-swap scenario.** Plug in a wired cable mid-install on a board
   that previously had no link. Confirm the carrier-poll block's 25 s
   timeout still fires (or that early_command's done state is sticky
   after the first run). This is the behavior we inherit from r196c.
4. **Kernel module loading.** Confirm `cfg80211`, `mac80211`,
   `iwlmvm`/`iwlmld` (whichever kernel module matches MEDUSA's
   wireless chipset) load without `modprobe: ERROR`. The initrd
   overlay now carries them, but the modules.dep on the install
   medium has to include the correct `depends` lines — build-iso-di.sh
   runs `depmod -a -b $WORK $KVER_INSTALLER` at line 2614, which
   should pick them up correctly, but it's only proven-on-real-hardware
   if the gate passes.
5. **Firmware loading.** Confirm `dmesg | grep iwlwifi` shows
   `Loaded firmware ... op_mode iwlmvm` (or iwlmld) for the right
   chip revision. If MEDUSA uses a chip revision NOT covered by the
   `assets/firmware/iwlwifi/*.ucode` blobs (i.e. one newer than
   iwlwifi-cc-*.ucode), the firmware load will fail with -ENOENT and
   the install will silently fail to associate. Track this in
   `assets/firmware/iwlwifi/README.md` if MEDUSA uses anything newer.

### PEGASUS (secondary, AMD64 laptop)

PEGASUS has the `iwlwifi` chipset family on amd64 already covered by
the kernel build, so the firmware gap is smaller. Same validation
matrix as MEDUSA, plus:

6. **`udpkg -i wireless-regdb-udeb` succeeds.** PEGASUS's amd64 netinst
   ISO has a smaller udeb pool than the arm64 build's substrate;
   confirm the offline mirror has the udeb (it does — verified against
   `deb.debian.org/debian/dists/forky/main/debian-installer/binary-amd64/Packages.gz`
   which is the same index build-iso-di.sh fetches from).
7. **`dhcp_timeout=120` is long enough for a WiFi+DHCP lease.**
   PEGASUS's AP might be slower than the 120 s we already set for
   wired DHCP. If a WiFi lease takes longer (WPA handshake +
   association can eat 5-10 s on slow APs), bump to 180 s.

### Both platforms

8. **Re-confirm the existing wired-install regression test still passes
   on real metal.** This is the r196c / r79 path. Easy to validate by
   plugging in an Ethernet cable and confirming the install completes
   exactly as before, with no new prompts.
9. **Re-confirm the no-network / no-wireless fallback.** Unplug
   everything on a wired-only board, confirm d-i raises its standard
   "Network autoconfiguration failed" critical prompt at the same
   place it does today. The r79 "wired is required" doctrine must
   still hold — the user must get a clear actionable error if neither
   wired nor wireless is available.

## Open follow-ups (NOT in scope of this change)

* **Unattended WPA.** The dispatcher asked specifically for "scan →
  SSID select → password entry" — operator-driven. To support
  unattended WiFi (e.g. for fully-zero-touch fleet installs of a
  WiFi-only appliance), we'd need a new preseed key like
  `d-i netcfg/wireless_essid select <ssid>` + `d-i netcfg/wireless_password
  password <psk>` + `d-i netcfg/wireless_security_type select wpa`. Not
  in scope today; the operator-driven flow is the deliverable.
* **WPA3 / SAE.** Debian's netcfg/wpa_supplicant-udeb supports WPA3-SAE
  since wpasupplicant 2.10 (the version in forky is 2.10-25). The
  `WCONFIG_SECURITY_TYPE` template would need to expose a "WPA3"
  choice. Today's substrate templates only offer WPA/WEP/Open. Likely
  needs a small `templates.dat` patch or a separate preseed override.
  Not in scope today.
* **Connection persistence.** After the d-i install finishes, the
  INSTALLED system needs the same SSID + PSK configured to reconnect
  on first boot. Whether netcfg writes the WPA creds to
  `/etc/network/interfaces` or to NetworkManager depends on the
  installed system's netplan/nm setup — not exercised here. Verify
  the post-install/12-sky1-firmware.sh + post-install/30-network.sh
  chain picks up the d-i-written `/etc/network/interfaces.d/wlan0`
  correctly.
* **Re-association after a link flap.** Not in scope today. If a real
  WiFi link goes down during install, d-i does not currently retry —
  we'd need a `kill-all-dhcp; netcfg` style re-entry hook (see the
  Debian preseed reference, "B.4.3. Network configuration", the
  network-preseed hack mentioned there).

## Files in this branch

* `build/build-iso-di.sh` — `REQUIRED_DI_UDEBS` extended;
  `PRUNE_NET_DIRS` no longer prunes `mac80211` + `wireless`;
  `iwlwifi` + `regdb` firmware staged into installer initrd (alongside
  the existing `rtl_nic` block at line 2623).
* `preseed/preseed.cfg` — `netcfg/choose_interface` contract documented;
  `preseed/early_command` extended with wireless-iface detection +
  udpkg-install of the wireless runtime chain + 3-branch dispatch on
  `PICKED_IF` / `WIRELESS_IF`.
* `sbom/expected-udebs.txt` — six new udebs added to the SBOM verifier.
* `docs/superpowers/specs/2026-09-21-installer-wifi-scan.md` — this
  document.
