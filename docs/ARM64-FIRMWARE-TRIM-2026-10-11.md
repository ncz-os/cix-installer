# arm64 (Sky1) firmware BOM trim — 2026-10-11

## 1. Problem

`post-install/13-firmware-bom.sh` installed the **whole** `manifests/firmware.pkgs`
(the complete architecture-neutral published firmware set) on every architecture,
and `build/build-forky-mirror.sh` seeded the same set into the offline closure on
every architecture. Measured on a real Sky1 board (Radxa Orion O6N, `192.168.207.3`,
ncz/ncz, image `6351e0b3`, kernel `7.3.0-rc6-sky1-ncz`):

```
$ du -sh /lib/firmware            ->  1.6G
$ du -sm /lib/firmware/* | sort -rn | head
522 qcom   279 intel   213 nvidia   141 netronome   93 amdgpu
 71 mediatek  68 mrvl   64 ath11k   34 rtw89  29 ath12k  23 ath10k
 13 i915   13 cirrus   12 brcm   ...
$ dpkg-query -W -f='${Package} ${Installed-Size}\n' 'firmware-*'  (top)
firmware-qcom-dsp 424572   firmware-iwlwifi 193408   firmware-nvidia-graphics 156337
firmware-netronome 144055  firmware-atheros 124075   firmware-qcom-soc 109860 ...
```

A CIX Sky1 system has none of the hardware those packages serve (Qualcomm SoC/DSP,
Intel graphics/audio/QAT, NVIDIA GSP, Netronome/Cavium/Myricom/QLogic/Broadcom
server NICs). The firmware was pure install-time and disk cost.

## 2. What Sky1 actually loads (evidence)

Measured read-only on O6N `192.168.207.3` (Sky1) and from the documented MS-R1 board
(fleet `cixmini`, `192.168.207.66`; both are CIX Sky1 — MNEMOS `mem_1787343307563_294b44`).

O6N device inventory (`lspci -nn`, `lsusb`, `ip -br link`, DMI):

| device | driver | firmware source |
|---|---|---|
| 2× Realtek RTL8125 2.5GbE `10ec:8125` | `r8169` | `rtl_nic/rtl8125b-2.fw` — staged from `assets/firmware/rtl_nic`, **not** a `firmware-*` package |
| Sandisk WD SN7100 NVMe `15b7:5045` | `nvme` | none |
| Cadence CIX PCIe root ports `17cd:0100` | `pcie` | none |
| Mali‑G720 (ACPI `CIXH5000:00`) | `mali_kbase`/panthor | `arm/mali/arch12.8/mali_csffw.bin` — staged from `assets/sky1-firmware` |
| CIX DSP (HiFi5) | `cix_dsp_rproc` | `dsp_fw.bin` — `assets/sky1-firmware` |
| CIX VPU (linlon/amvx) | `amvx`/`linlondp` | 16× `*.fwb` — `assets/sky1-firmware` |
| CIX sensor-hub | `cix-firmware` deb | `sfh_fw*.bin` — vendor `cix-firmware` .deb |
| MS‑R1 M.2 WiFi/BT | `mt7921e`/`btmtk` | `mediatek/...MT7922...` — **firmware-mediatek** |
| Sky1 M.2 WiFi option | `rtw89` | `rtw89/*` — **firmware-realtek** |
| USB 1–2.5GbE / USB WiFi / BT | `r8152`/`rtw88`/`rtl_bt` | **firmware-realtek** |

The kernels/Sky1 blobs (Mali CSV, DSP, VPU `.fwb`, rtl_nic, regulatory.db) are
installed by `post-install/12-sky1-firmware.sh` from `assets/sky1-firmware` and
`assets/firmware/`, **not** by any `firmware-*` package, so trimming the BOM does
not touch them (`dpkg -S` confirms all are unowned by `firmware-*`).

`firmware-linux-nonfree` depends only on `firmware-misc-nonfree` and
`firmware-amd-graphics`, so no dropped package is pulled back as a dependency; the
`firmware-qcom-*` packages only inter-depend among themselves, and are dropped as a
group. `apt-get install --no-install-recommends` is already used by the hook, so
`Recommends:` cannot re-add anything.

The published firmware set is architecture-independent (`Architecture: all`). The
real, pinned-snapshot publication index on ULTRA lists exactly the 40 packages in
`manifests/firmware.pkgs`:

```
$ awk '/^Package: firmware-/{print $2}' \
    build/forky-mirror/.ncz-published-packages/arm64/Packages | sort -u | wc -l
40          # comm -3 vs manifests/firmware.pkgs -> empty
```

## 3. Decision: keep / drop (per package)

KEEP = a Sky1 on-board device, the documented M.2 modules (MS‑R1 MT7922, Sky1
RTW89), a deliberately small hotplug allowance (Realtek/MediaTek/Qualcomm-Atheros
USB+PCIe/M.2, plus amdgpu for the O6N PCIe slot), or a metapackage/dependency.
Everything else is dropped. Sizes are the O6N `Installed-Size` (`/lib/firmware`)
and the real `.deb` compressed size from the ULTRA arm64 mirror.

| package | keep/drop | /lib/firmware | .deb | evidence |
|---|---|---:|---:|---|
| `firmware-qcom-dsp` | DROP | 414.6 MB | 116.4 MB | Qualcomm Hexagon DSP fw; Sky1 is CIX. NOT loaded on O6N (no qcom device). |
| `firmware-iwlwifi` | DROP | 188.9 MB | 25.1 MB | Intel WiFi; net-firmware.tsv labels it "amd64 laptops". O6N lspci has no Intel radio; MS-R1 uses MT7922. Default drop (see below). |
| `firmware-nvidia-graphics` | DROP | 152.7 MB | 104.2 MB | nouveau/tegra GPU; no Sky1 fleet host has an NVIDIA GPU (default decision, see below). |
| `firmware-netronome` | DROP | 140.7 MB | 1.8 MB | Netronome Agilio SmartNIC (server PCIe). |
| `firmware-atheros` | KEEP | 121.2 MB | 38.1 MB | KEEP: Qualcomm Atheros M.2/PCIe (QCNFA ath10k/11k/12k) + USB dongles. |
| `firmware-qcom-soc` | DROP | 107.3 MB | 28.1 MB | Qualcomm SoC blobs; not a CIX part. |
| `firmware-amd-graphics` | KEEP | 97.0 MB | 16.0 MB | KEEP: amdgpu (mainline, works on arm64) for a Radeon in the O6N PCIe slot; dep of firmware-linux-nonfree. |
| `firmware-qcom-rb5` | DROP | 73.2 MB | 10.6 MB | Qualcomm Robotics RB5 dev board. |
| `firmware-mediatek` | KEEP | 71.0 MB | 34.8 MB | KEEP: MS-R1 M.2 MT7922 WiFi+BT (btmtk/mt7921e), MT7925. |
| `firmware-nvidia-gsp` | DROP | 59.2 MB | 37.1 MB | NVIDIA GSP (Turing+); proprietary arm64 dGPU. Default drop. |
| `firmware-marvell-prestera` | DROP | 59.2 MB | 61.3 MB | Marvell OcteonTX/TX2 NIC. |
| `firmware-sof-signed` | DROP | 55.5 MB | 3.2 MB | Intel Sound Open Firmware. |
| `firmware-qcom-dragonboard845c` | DROP | 40.5 MB | 8.5 MB | DragonBoard 845c (SDM845). |
| `firmware-realtek` | KEEP | 38.0 MB | 4.0 MB | KEEP: O6N/MS-R1 RTL8125/8127 rtl_nic, Sky1 M.2 RTW89, r8152 USB-ETH, USB WiFi rtw88/rtl_bt. |
| `firmware-intel-graphics` | DROP | 31.5 MB | 8.0 MB | i915/xe iGPU+Arc; Sky1 has Mali-G720, no Intel GPU. net-firmware.tsv marks i915 `initrd+target` for amd64 Meteor/Arrow Lake only. |
| `firmware-intel-misc` | DROP | 23.3 MB | 3.0 MB | Intel QAT/HFI1/e100 server+SoC misc. |
| `firmware-misc-nonfree` | KEEP | 19.9 MB | 5.8 MB | KEEP: dep of firmware-linux-nonfree; kernel-wide misc blobs. |
| `firmware-brcm80211` | DROP | 17.9 MB | 5.4 MB | Broadcom brcmfmac upstream boards only; no Sky1 module. T2 Macs use the separate apple-t2 tarball, not this package (amd64 unaffected). |
| `firmware-qcom-rb3gen2` | DROP | 13.8 MB | 6.2 MB | Qualcomm RB3 Gen 2 (QCS6490). |
| `firmware-libertas` | DROP | 11.3 MB | 3.6 MB | Marvell Libertas (pre-2010 WiFi). |
| `firmware-cirrus` | DROP | 9.0 MB | 0.5 MB | Cirrus CS42L43/sdca laptop audio amps. |
| `firmware-qlogic` | DROP | 6.6 MB | 2.4 MB | QLogic FC / NetXen. |
| `firmware-ti-connectivity` | DROP | 5.4 MB | 1.5 MB | TI WL18xx (BeagleBone class). |
| `firmware-cavium` | DROP | 5.3 MB | 0.7 MB | Cavium LiquidIO. |
| `firmware-intel-sound` | DROP | 5.0 MB | 0.8 MB | Intel display/HDMI audio DSP; Sky1 uses CIX audio. |
| `firmware-myricom` | DROP | 4.0 MB | 0.3 MB | Myricom 10-GbE. |
| `firmware-samsung` | DROP | 2.8 MB | 0.8 MB | Samsung Exynos MFC. |
| `firmware-bnx2x` | DROP | 2.4 MB | 1.8 MB | Broadcom NetXtreme II. |
| `firmware-netxen` | DROP | 2.2 MB | 1.3 MB | NetXen/QLogic 10-GbE. |
| `firmware-ipw2x00` | DROP | 1.6 MB | 0.3 MB | Intel PRO/Wireless 2100/2200 (pre-2006). |
| `firmware-siano` | DROP | 1.4 MB | 0.4 MB | Siano DVB tuners. |
| `firmware-ivtv` | DROP | 1.3 MB | 0.2 MB | Conexant ivtv/pvrusb2 TV capture. |
| `firmware-bnx2` | DROP | 0.7 MB | 0.2 MB | Broadcom NetXtreme. |
| `firmware-linux-nonfree` | KEEP | 0.5 MB | 0.1 MB | KEEP: metapackage (Depends firmware-misc-nonfree, firmware-amd-graphics). |
| `firmware-linux` | KEEP | 0.5 MB | 0.1 MB | KEEP: metapackage (Depends firmware-linux-free, firmware-linux-nonfree). |
| `firmware-ath9k-htc` | KEEP | 0.1 MB | 0.0 MB | KEEP: tiny USB Atheros WiFi (hotplug). |
| `firmware-linux-free` | KEEP | 0.1 MB | 0.0 MB | KEEP: free firmware set (metapackage dep). |
| `firmware-zd1211` | DROP | 0.1 MB | 0.0 MB | ZyDAS ZD1211 USB WiFi (pre-2006). |
| `firmware-carl9170` | DROP | 0.0 MB | 0.0 MB | Atheros AR9170 USB WiFi (pre-2010). |
| `firmware-ast` | DROP | 0.0 MB | 0.0 MB | ASPEED BMC display. |

KEEP set (9): `firmware-amd-graphics`, `firmware-ath9k-htc`, `firmware-atheros`,
`firmware-linux`, `firmware-linux-free`, `firmware-linux-nonfree`,
`firmware-mediatek`, `firmware-misc-nonfree`, `firmware-realtek`.
DROP set (31): the rest; see `manifests/firmware-bom-arm64.allow` with one reason
per line.

## 4. Sizes before / after (measured)

| quantity | before | after | delta |
|---|---:|---:|---:|
| `/lib/firmware` from `firmware-*` packages (O6N `Installed-Size`) | 1786 MB | 348 MB | −1437 MB (−80.5%) |
| arm64 offline-mirror firmware pool (real `.deb` bytes) | 532 MB | 99 MB | −434 MB (−81.4%) |
| installed `firmware-*` package count | 40 | 9 | −31 |

The whole `/lib/firmware` tree on O6N was 1.6 GB; ~1.4 GB of that was drop-only
firmware packages. The image-size delta tracks the mirror reduction (~0.4 GB per
arm64 ISO).

## 5. Mechanism (arch-scoped, amd64 untouched)

* `manifests/firmware-arm64.pkgs` — the arm64 install + mirror seed.
* `manifests/firmware-bom-arm64.allow` — the arm64 deliberate exclusions.
* `manifests/firmware.pkgs` is unchanged and remains the complete published set and
  the amd64 BOM (no `firmware-amd64.pkgs`, so every consumer falls back to it).
* Consumers honour `manifests/firmware-$ARCH.pkgs` / `firmware-bom-$ARCH.allow`
  when present:
  * `build/build-forky-mirror.sh` (`_seed_for firmware`),
  * `build/verify-firmware-bom.sh` (arch BOM + arch allow; also fails a
    declared ∩ allowed contradiction),
  * `build/verify-offline-mirror-seeds.sh` (`_seed_manifest_for firmware`),
  * `build/verify-installed-target.sh` (arch BOM; net-firmware rows limited to
    packages the arch ships),
  * `post-install/13-firmware-bom.sh` (arch-scoped BOM selection at install time;
    `NCZ_FW_BOM` still wins),
  * `build/iso/patch-initrd-t2-kernel.py` (stages only net-firmware rows whose
    package the arch BOM ships — the arm64 installer initrd no longer carries the
    amd64-only i915 firmware),
  * `build/build-installer-image.sh` passes the arch BOM to the initrd builder.
* Gate: `build/verify-firmware-bom.sh` requires, per arch,
  `published == declared(BOM) ⊎ allowed(allow-list)`; an unaccounted published
  package, an allow-list name that is not published, a declared∩allowed
  contradiction, or a required package absent from the pool all fail closed.
* Tests: `build/test-firmware-arch-bom.sh` (closure gate both arches + drift
  negatives + wiring), `build/iso/tests/test_initrd_net_firmware.py`
  (partition invariant + arch filter), `build/test-firmware-bom-hook.sh`
  (install-hook arch selection).

## 6. Risk notes / operator-decidable defaults

* **PCIe-GPU firmware.** Default: **keep `firmware-amd-graphics`, drop
  `firmware-nvidia-graphics`/`firmware-nvidia-gsp`.** amdgpu is mainline and works
  on arm64 out of the box; the NVIDIA proprietary/GSP path is uncommon on arm64
  mini-PCs and no Sky1 fleet host has an NVIDIA GPU today. If an NVIDIA dGPU in the
  O6N slot becomes a supported configuration, restore both (see §7).
* **Intel WiFi (`firmware-iwlwifi`, 189 MB).** Default: **drop.** No Sky1 on-board
  radio is Intel; `manifests/net-firmware.tsv` itself documents iwlwifi as
  "amd64 laptops". A user swapping in an Intel AX2xx M.2 card is a supported
  hotplug only after restoring the package (see §7).
* **Broadcom (`firmware-brcm80211`).** Default: **drop.** No Sky1 module uses
  brcmfmac; T2 Macs get their blobs from the separate `apple-t2` tarball via
  `build/iso/patch-initrd-firmware.py`, so amd64 is unaffected.
* **Recovery / rescue.** Unaffected: the Sky1 blobs (Mali/VPU/DSP/rtl_nic/regdb)
  come from `assets/`, not the BOM; `rescue.pkgs` and the recovery rootfs are
  independent of `firmware.pkgs`.
* **Hotplug.** The keep set covers the common WiFi/BT/Ethernet card families a
  Sky1 user is likely to add. Exotic add-in NICs (Netronome/Cavium/Myricom/QLogic/
  bnx2*) and legacy pre-2010 USB radios are not provisioned by default.

## 7. How to restore any dropped set

1. Add the package name(s) back to `manifests/firmware-arm64.pkgs`.
2. Delete the matching line(s) from `manifests/firmware-bom-arm64.allow`.
3. Rebuild the arm64 offline mirror and image with the normal pipeline.

`build/verify-firmware-bom.sh --arch arm64` passes only when the two files exactly
partition the published set, so a restore cannot silently drift. A full revert is
also a one-commit revert of the `fix/arm64-firmware-trim-20261011` change set.
