# CIX Sky1 device comparison — O6 / O6N / Orange Pi 6 / Orange Pi 6 Plus / MS-R1

> **Author:** Jason Perlow (via minimax, 2026-08-21, single session)
> **Purpose:** single-table reference for the resume/wake investigation and
> for any future cross-board kernel quirk. Not a marketing comparison.
> **Method:** read every committed doc under `docs/`, `docs/upstream-patches/`,
> `build/`, `post-install/`, and `kernel-source/` for board-specific claims;
> then read vendor spec pages where we have no first-party hardware. Sources
> are cited inline; **CONFIRMED** = real hardware tested or authoritative
> source (board DSDT, our docs, patch file we carry) ; **UNCONFIRMED** =
> inferred from architecture, vendor marketing copy, or community report.

---

## 1. The five boards in scope

| Board | Vendor | SoC | Form factor | In our fleet? |
|---|---|---|---|---|
| **Radxa Orion O6** | Radxa Computer (Shenzhen) Co., Ltd. | CIX P1 / CD8180 | 170×170 mm mini-ITX | **No** — not in our DC |
| **Radxa Orion O6N** | Radxa Computer (Shenzhen) Co., Ltd. | CIX P1 / CD8160 | 120×120 mm Nano-ITX | **Yes** — the dev box (`192.168.207.3`, `ncz-20e7bc`) |
| **Orange Pi 6** | Shenzhen Xunlong Software Co., Ltd. | CIX P1 / CD8180 | 90×90 mm non-standard | **No** — incoming, not yet on site |
| **Orange Pi 6 Plus** | Shenzhen Xunlong Software Co., Ltd. | CIX P1 / CD8180 or CD8160 | 115×100 mm non-standard | **No** — separate SKU, not yet on site |
| **Minisforum MS-R1** | Micro Computer (HK) Ltd. (Minisforum) | CIX P1 / CP8180 | 1.7 L mini-workstation | **Yes** — second confirmed board |

The O6N is the bulk of our evidence; the MS-R1 is the second board on which
acceleration and the install path were validated; the O6, Orange Pi 6, and
Orange Pi 6 Plus are not yet directly tested by us. Everything below separates
those two confidence levels explicitly.

---

## 2. Master comparison table

For each property, the column is the board; the row is the property.
**Each cell carries two pieces of information: the value, and the confidence
level.** `C` = confirmed (real hardware or authoritative source in this repo)
; `U` = unconfirmed (vendor marketing copy, inference, or needs a real unit).

| Property | Radxa O6 | Radxa O6N | Orange Pi 6 | Orange Pi 6 Plus | Minisforum MS-R1 |
|---|---|---|---|---|---|
| **Embedded Controller (EC)** | Reported present (Stuart Shelton, independent CIX Sky1 kernel maintainer: *"O6 has EC but O6N doesn't"*). **C** for the claim's existence; **U** for the chip identity — we have no schematics or DSDT dump. | Reported absent (Stuart, same source). **C** for the claim's existence; **U** for "no EC of any kind" — no ACPI scan of the O6N firmware has been published to definitively rule out a sub-feature controller. | **U** — vendor spec page does not mention EC. No DSDT dump available. | **U** — vendor spec page does not mention EC. No DSDT dump available. | **U** — vendor spec page does not mention EC. ACPI scan has not been published. |
| **On-board RTC chip** | Yes — vendor spec lists *"Real-Time Clock with backup battery holder (CR1220)"* (CNX-Software, 2024-12). **C**. Most likely an HYM8563 or RX8900-class I²C RTC; the exact chip is **U** (no teardown we have access to). | Yes — vendor spec lists *"Real-Time Clock with backup battery header (instead of CR1220 holder)"* (CNX-Software, 2025-10). **C** that the chip is on-board; the spec explicitly says O6N differs from O6 only in the **battery connector**, not in the chip. **U** for the chip identity. | Yes — vendor spec lists *"2-pin RTC connector"* (CNX-Software, 2026-06). **C** for the connector; **U** for whether the connector is wired to an on-board chip or to a user-supplied external RTC module. We have not seen a teardown. | Yes — vendor spec lists *"2-pin RTC connector"* (CNX-Software, 2025-10). **C** for the connector; **U** for chip identity / on-board vs external. | **U** — vendor spec page does not state RTC chip presence. The install-time SSDT logic in `post-install/80-npu.sh` does not probe RTC; it adjusts the NPU SSDT. |
| **RTC architecture (the critical Stuart field)** | Real accessible HYM8563/RX8900-class I²C RTC, exposed to Linux through `rtc_hym8563` or `rtc_rx8900` (per Stuart's email referenced in the task brief). **C** for the fact that this is Stuart's confirmed observation; **U** for the exact `_HID` / bus address / driver name — we have not run an O6 unit to enumerate. | **Firmware-owned via ACPI `Device(ERTC)`, `_HID "ERTC0000"`, `_STA = Zero`** (so Linux never enumerates it). Driving a Cadence I²C controller at `0x04040000` not exposed to Linux. UEFI runtime `GetTime`/`SetTime` is the only path. Linux driver: `rtc-efi`, `/dev/rtc0`, `hctosys=1`. **C** — measured on O6N with `DRIVER_FIDELITY_72.md` documented, "Metal-verified on O6N under BOTH 7.2.0-rc6 and 7.0.12." | **U** — unconfirmed. Inferring from the rest of the table: the Orange Pi 6 Plus is in the same firmware-only RTC design (the firmware-owned architecture is what the CIX Sky1 reference EDK-II produces by default when the OEM firmware-side path is left at the CIX default). The Orange Pi 6, with the same CIX Sky1 reference firmware, is presumed to do the same. **Both are unconfirmed until a DSDT dump is taken.** | **U** — same as Orange Pi 6. | **Firmware-owned via the same ACPI `Device(ERTC)`, `_HID "ERTC0000"`, `_STA = Zero` design**, UEFI runtime `GetTime`/`SetTime` path only, `rtc-efi`. **C** — `DRIVER_FIDELITY_72.md` records that the O6N and MS-R1 share "IDENTICAL RTC architecture" and the workaround that protects them (`efi=noruntime` on MS-R1, gated off elsewhere) is the same firmware-class fix. |
| **GPU driver / status** | Not metal-tested by us. **C** that the hardware is identical Mali-G720-Immortalis MC10 (same silicon as O6N); **U** for which boot entry actually works on it. | **Mali-G720-Immortalis via `mali_kbase` (DKMS, default)** — measured up to 1.0 GHz, GLES 3.2 + Vulkan 1.3 (via blob ICD), **C**. Panthor is also a supported option (per `DRIVER_FIDELITY_72.md` addendum 2026-08-16, IDM secure-access fix). **C**. | **C** that the hardware is Mali-G720-Immortalis MC10 (vendor spec). **U** for which driver works — we have not run a unit. | **C** that the hardware is Mali-G720-Immortalis MC10 (vendor spec). **U** for driver status. | **Mali-G720-Immortalis via `mali_kbase` (DKMS)** — measured working on actual MS-R1 hardware (`DRIVER_FIDELITY_72.md` status note, 2026-08-18). **C**. |
| **NPU driver / status** | Not metal-tested. **C** that the silicon is the same ArmChina Zhouyi V3 (3 cores, ~30 TOPS INT8). **U** for driver behavior on this specific board. | **Zhouyi V3 via `aipu` DKMS driver (26Q2 SDK), `cix-npu-driver-dkms 6.2.0`** — inference confirmed on actual O6N hardware, 95.5 ms per 256-token chunk, deterministic. **C** (`DRIVER_FIDELITY_72.md`, 2026-08-18). | **C** that the silicon is Zhouyi V3 (vendor spec). **U** for driver behavior, including whether the ACPI `_HID` enumeration is present. | **C** that the silicon is Zhouyi V3 (vendor spec). **U** for driver behavior. **U** for whether the Orange Pi 6 Plus needs the same NPU SSDT override as MS-R1. | **Zhouyi V3 via `aipu` DKMS driver (26Q2 SDK)** — inference confirmed on actual MS-R1 hardware. **C** (`DRIVER_FIDELITY_72.md`, 2026-08-18). |
| **VPU driver / status** | Not metal-tested. **C** that the silicon is the same Linlon / amvx (codec block on the CIX P1 SoC). **U** for driver behavior on this specific board. | **Linlon / amvx via DKMS** — hardware decode + encode round-tripped, including H.264/HEVC/VP8/VP9. `mvxdec` / `mvxenc` nodes. **C** (`DRIVER_FIDELITY_72.md`). | **C** that the silicon is the same Linlon VPU (vendor spec). **U** for driver behavior. | **C** that the silicon is the same Linlon VPU (vendor spec). **U** for driver behavior. | **Linlon / amvx via DKMS** — same silicon, same driver. **C** (`DRIVER_FIDELITY_72.md` NPU addendum also notes the VPU acceleration matrix measured on the box). |
| **Suspend / resume** | **Unknown / untested** — we have no O6 in our fleet. **U**. Stuart's "EC on O6" observation is the leading hypothesis for why a resume fix that works on O6N will not transfer cleanly to O6; that is the *reason this document exists*. | **CPU0 lockup-on-resume is the active bug under investigation** (per the task brief that produced this document). The firmware-owned RTC path makes the userland RTC restore trivial; the residual CPU0 lockup is downstream of the kernel's late-stage wake wiring. **C** for the bug's existence on O6N; **U** for what specifically locks CPU0. No `mem_sleep` state has been confirmed working on O6N. | **U** — unknown. The same architecture-family concern applies (PC states, SCMI perf gating, the 9011 pm-runtime gate). | **U** — unknown. | **U** — no published result. The MS-R1 firmware does need `efi=noruntime` to avoid an RTC-wedge on wake (implicitly, via the same class of firmware bug Stuart identified in the `ncz_efi_rt_workaround` comment), but the CPU0 lockup itself has not been tested/reported on MS-R1. |
| **Console UART** | **U** — assumed `ttyAMA0` (same CIX Sky1 reference platform as O6N) but not directly observed. | **`ttyAMA0`** — used for the rescue diagnostic entry and serial mirror (`tty0` primary). **C** (`docs/ENGINEERING-EFFORT.md` line 86, `build/build-iso-di.sh` line 2791). | **U** — not observed. | **U** — not observed. | **`ttyAMA2`** — the MS-R1 hardware UART mapping is different from O6/O6N; the rescue entry uses `ttyAMA2` on MS-R1 vs `ttyAMA0` on O6N. **C** (`build/build-iso-di.sh` line 2791). |
| **Primary NIC** | **U** — Stuart's `90050` board-profile patch selects `R8126` (Realtek RTL8126 vendor driver) for the O6; mainline `r8169` may also work. Differentiating from O6N. **C** for the patch's stated intent; **U** for runtime behavior on the actual O6. | Mainline `r8169` (CONFIG_R8169=y). **C** — `kernel-source/.../config-7.2-lean-msr1-o6n.defconfig` and the `docs/upstream-patches/srcshelton-tier3-examination-2026-08-20.md` `O6 NIC` comment. | **U** — vendor spec lists 2x 2.5GbE RJ45 (no chip identified). | **U** — vendor spec lists 2x 5GbE RJ45 (no chip identified). | **RTL8127 × 2** (Realtek 10 GbE per vendor spec; mainline `r8169` covers RTL8127). **C** for the chip; **U** for which exact driver variant binds. |
| **WiFi chip** | **U** — Stuart's `80010` patch is gated by DMI on `Radxa Computer (Shenzhen) Co., Ltd.` matching product names `Radxa Orion O6` or `Radxa Orion O6N`, and patches `rtw89` for the RTL8852B. **C** that the O6 uses RTL8852B (`rtw89`); **U** for whether the chip is the same part on this board. | **RTL8852B** on `rtw89` — board-specific rfkill polling workaround (`80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch`) is DMI-gated to O6/O6N. **C** (`docs/upstream-patches/srcshelton-tier3-examination-2026-08-20.md` §4.1). | **U** — optional M.2 E-Key only, no fixed WiFi. | **U** — optional M.2 E-Key only, no fixed WiFi. | **MediaTek RZ616** (vendor spec). **C** for the chip; **U** for driver status. |
| **ACPI NPU core enumeration** | Native (`CIXH4010` enumerated, ≥3 cores). **C** — `post-install/80-npu.sh` `should_apply_npu_ssdt()` reports ">=3 cores present → SKIP" on O6/O6N. | Native (`CIXH4010` enumerated, ≥3 cores). **C** — `should_apply_npu_ssdt()` skips the override. | **U** — unknown. The override's failure mode if injected into a board that already enumerates correctly is `_HID` collision (AE_ALREADY_EXISTS); an Orange Pi 6 with full native enumeration would be safe; with the same MS-R1-style absence it would need the SSDT. | **U** — same as Orange Pi 6. | **Missing in factory BIOS** — `CIXH4010` _HID is omitted on the MS-R1 CRE0/CRE1/CRE2 cores. **C** — this is what the SSDT override in `build/build-npu-ssdt.sh` fixes. The functional ACPI check (`>=3 CIXH4010:*`) gates the SSDT injection. |
| **DMI / firmware issue** | `sys_vendor` = `Radxa Computer (Shenzhen) Co., Ltd.`; `product_name` = `Radxa Orion O6`. **C** (Stuart's `80010` DMI table). | `sys_vendor` = `Radxa Computer (Shenzhen) Co., Ltd.`; `product_name` = `Radxa Orion O6N`. **C** (Stuart's `80010` DMI table + our own `build/70-bootloader.sh` board allow-list). | `sys_vendor` = `*Xunlong*` / `*Shenzhen Xunlong*` (vendor tells us); `product_name` likely `Orange Pi 6` or `OrangePi 6`. **U** for the exact string — the allow-list in `build/70-bootloader.sh` accepts both `*"Orange Pi 6"*` and `*"OrangePi 6"*` and the `*Xunlong*` vendor fallback. | Same as Orange Pi 6. **U** for the exact string — the bootloader's allow-list is *not* "`Orange Pi 6 Plus`" specifically; the `*Xunlong*` vendor fallback is what would carry it. **Needs verification on a real unit.** | `sys_vendor` = `*Micro Computer (HK)*`; `product_name` = `MS-R1*`. **C** — `build/70-bootloader.sh` `ncz_efi_rt_workaround()` matches both. |
| **EFI `efi=noruntime` needed?** | **No**. **C** — the bootloader's allow-list explicitly opts O6 out of the workaround. | **No**. **C** — `ncz_efi_rt_workaround()` returns `""` for any `*Orion O6*` product name. | **No** (predicted). **U** — Orange Pi 6 is in the allow-list (`*"Orange Pi 6"*|*"OrangePi 6"*`) and the `*Xunlong*` vendor fallback would catch it independently. | **No** (predicted). **U** — the `Orange Pi 6 Plus` string is **not** in the explicit allow-list; the `*Xunlong*` vendor fallback is what would carry it. **Needs verification** — if the firmware reports `OrangePi 6 Plus` (any spacing) under a `*Shenzhen Xunlong*` vendor string, the `*Xunlong*` vendor rule is what saves it. | **Yes**. **C** — `ncz_efi_rt_workaround()` returns `efi=noruntime` for MS-R1. The reason is the MS-R1 firmware's EFI runtime services are reportedly buggy; the workaround tracks firmware behaviour, not the kernel version. |
| **Board-specific DMI / quirk gating in the patch series** | `80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch` — DMI-gated to `Radxa*` + `Orion O6|E6N` + `RTL8852B`. **C** (in our `docs/upstream-patches/srcshelton-tier3-examination-2026-08-20.md` §4.1, "Port" recommendation). `80000-pci-rtl8126-disable-unreadable-vpd-quietly.patch` is an O6-specific NIC quirk. **C** (list in `srcshelton-comparison-2026-08-20.md` §1.4). | Same `80010` patch (covered by same DMI gate). **C**. | **None in our patch series yet.** Orange Pi 6 will need its own DMI gate when the first one ships. **U** for what those quirks will be. | **None in our patch series yet.** Same as Orange Pi 6. **U**. | The `ncz_efi_rt_workaround()` DMI gate is the one board-specific quirk gate. **C** — `build/70-bootloader.sh`, `assets/refind/ncz-refind-refresh.sh`, `build/build-kernel-debs.sh` (three copies, all synced). The `should_apply_npu_ssdt()` DMI fallback is also MS-R1-biased (`*MS-R1*\|*MINISFORUM*\|*[Mm]inisforum*` → APPLY). **C**. |
| **DTB filename** | `sky1-orion-o6.dtb` (shared with O6N; "same SoC, same peripherals"). **C** (`docs/KERNEL-BUILD-YOCTO.md` line 90). | `sky1-orion-o6.dtb` (shared). **C**. | **U** — likely an `orangepi-6.dtb` or similar; Orange Pi's vendor tree is the authoritative source. | **U** — likely an `orangepi-6-plus.dtb` or similar. | Separate build dir (`build-cix-msr1`) using the `cixmsr1` machine. **C** (`docs/KERNEL-BUILD-YOCTO.md` line 92). |
| **M.2 LTE/5G WWAN** | **U** — not in published vendor spec. | Vendor spec lists an M.2 B-Key socket for 4G LTE/5G cellular. **C**. | **U** — not in published vendor spec. | **U** — not in published vendor spec. | **U** — not in published vendor spec for MS-R1 product page. |
| **UFS support** | **U** — not in published vendor spec. | Vendor spec lists a UFS connector for a Radxa module (**C**). Thin-config stage 1 has a comment confirming O6N officially supports a pluggable UFS module. **C**. | **U** — vendor spec does not mention UFS. | **U** — vendor spec does not mention UFS. | **U** — vendor spec does not mention UFS. |
| **CPU0-lockup-on-resume — symptom** | **U** — no O6 in our fleet, no report. | **Active bug under investigation**. Real-hardware repro exists; root cause unconfirmed. The firmware-owned RTC means Linux does not see the wake-time directly through ACPI, which is one of the hypotheses. | **U** — unknown. | **U** — unknown. | **U** — no published repro; the same firmware-class concern applies via the `efi=noruntime` workaround on the same wake path. |

---

## 3. Per-board prose

### 3.1 Radxa Orion O6 (`Radxa Computer (Shenzhen) Co., Ltd.`, `Radxa Orion O6`)

- **EC presence.** Stuart Shelton, the independent CIX Sky1 kernel maintainer
  quoted in the task brief, stated: *"O6 has EC but O6N doesn't"* — meaning
  any wake/resume fix cannot assume one's behaviour generalises to the other.
  The DSDT dump / chip identity is **not** in our tree; we have no O6 in the
  fleet and have not run an `acpidump` against one. **For the wake-investigation
  doc-and-code purpose, the only firm conclusion is that the O6 is NOT a
  drop-in for the O6N's `rtc-efi` path.** That is the practical lesson.
- **RTC.** Stuart's report (same source) is that the O6 has a real accessible
  HYM8563/RX8900-class I²C RTC device Linux can enumerate directly. The vendor
  spec confirms the chip is on-board (CR1220 holder) — *"Real-Time Clock with
  backup battery holder (CR1220)"* (CNX-Software, 2024-12). The exact chip
  part number is **U**; we have no schematics. The architectural difference
  (firmware-owned vs Linux-enumerable) is the load-bearing fact for the
  resume/wake work.
- **WiFi.** RTL8852B on `rtw89`, plus a board-specific rfkill polling fix
  (Stuart's `80010-rtw89-disable-hw-rfkill-polling-on-orion-o6.patch`).
  This patch is **DMI-gated** to `Radxa Computer (Shenzhen) Co., Ltd.` with
  product name `Radxa Orion O6` *or* `Radxa Orion O6N`, and a chip-ID gate
  on `RTL8852B`. (Source: `docs/upstream-patches/srcshelton-tier3-examination-2026-08-20.md`
  §4.1. Recommendation: **Port**.)
- **NIC.** Stuart's `90050-arm64-cix-add-radxa-orion-board-profiles.patch`
  selects `R8126` (the vendor Realtek RTL8126 driver) for O6, vs `R8169`
  (mainline) for O6N. The recommendation in our tier-2 examination is "do
  not port as-is" — we already maintain explicit `config-7.2-lean-msr1-o6n.defconfig`
  and the additional board preset would create a second policy surface. But
  the **fact** that the two boards differ on which NIC driver is appropriate
  is a real hardware difference, not a Stuart quirk. (Source: `srcshelton-tier2-examination-2026-08-20.md`
  §4 line 311.)
- **Fan control.** Stuart's `90040-hwmon-cix-add-safe-acpi-fan-control.patch`
  is gated to O6 (the `SENSORS_CIX_FAN` Kconfig is in the O6 preset list per
  the §4 listing). The O6N does not have this Kconfig in its preset. **C**
  that Stuart's profile treats O6 as having the ACPI-fan hardware; **U** for
  whether the O6N genuinely lacks it — but the architectural difference is
  consistent with the "EC on O6, no EC on O6N" claim, since an EC is the
  most common SMBus/ACPI host for a smart-fan PWM control.
- **Suspend / resume.** No first-party observation. The wake-investigation
  hypothesis is that the EC presence on O6 is what makes a fix that targets
  the O6N's firmware-only RTC path insufficient for O6. Until the O6 is in
  the fleet, the safest position is **do not assume O6N behaviour
  generalises.**
- **Console UART.** Most likely `ttyAMA0` (same CIX Sky1 reference wiring as
  O6N). **U** — not directly observed.

### 3.2 Radxa Orion O6N (`Radxa Computer (Shenzhen) Co., Ltd.`, `Radxa Orion O6N`)

- **EC presence.** Stuart: *"O6N doesn't [have an EC]"*. No ACPI scan has
  been published; the firmware's lack of `PNP0C09` `_HID` could be confirmed
  with a real `acpidump` but we have not done that exercise. The practical
  consequence is that no EC exists to mediate wake — wake-time is purely the
  CIX Sky1 firmware's responsibility.
- **RTC.** **Firmware-owned.** Quote from `docs/DRIVER_FIDELITY_72.md`:
  *"The O6N RTC is firmware-owned: ACPI `Device (ERTC)`, `_HID "ERTC0000"`,
  `_STA = Zero` (so Linux never enumerates it), driving a Cadence I2C
  controller at `0x04040000` that is not among the buses exposed to Linux.
  UEFI runtime `GetTime`/`SetTime` is the only path to it."* Linux driver:
  `rtc-efi`, `/dev/rtc0`, `hctosys=1`. **C** — metal-verified on O6N under
  both `7.2.0-rc6` and `7.0.12`. `efi=noruntime` therefore removes the
  only route to the clock, which is why the workaround is **gated off** the
  O6N by the `ncz_efi_rt_workaround()` DMI logic.
- **GPU.** Mali-G720-Immortalis via `mali_kbase` (DKMS, default boot entry).
  Measured up to 1.0 GHz, GLES 3.2 + Vulkan 1.3 (via blob ICD). Panthor is
  also a supported option (2026-08-16, IDM secure-access fix). **C**.
- **NPU.** Zhouyi V3 via `aipu` DKMS driver (26Q2 SDK,
  `cix-npu-driver-dkms 6.2.0`). Inference confirmed on actual O6N hardware,
  95.5 ms per 256-token chunk, deterministic across runs. **C**.
- **VPU.** Linlon / amvx via DKMS, hardware decode + encode round-tripped.
  **C**.
- **Console UART.** `ttyAMA0` (line 86 of `docs/ENGINEERING-EFFORT.md`).
  Used for the rescue diagnostic entry and serial mirror. **C**.
- **Suspend / resume.** **CPU0 lockup-on-resume is the active bug under
  investigation** (per the task brief that produced this document).
  No `mem_sleep` state has been confirmed working on O6N. The firmware-owned
  RTC means the userland side of the clock restore is trivial; the residual
  bug is somewhere in the kernel's late-stage wake wiring — SCMI perf
  domain resume, gpio/pinctrl wake, or something we have not yet isolated.
- **WiFi.** RTL8852B on `rtw89`, with the same DMI-gated rfkill polling fix
  as the O6.
- **NIC.** Mainline `r8169` (CONFIG_R8169=y). The d-i netcfg stage requires
  `assets/firmware/rtl_nic` blobs to be in the installer initrd for the
  link to come up (per `build/build-iso-di.sh` line 1976-1986).
- **UFS.** Pluggable UFS module socket (Radxa module). **C** — vendor spec.
- **DTB.** `sky1-orion-o6.dtb`, shared with O6. **C**.

### 3.3 Orange Pi 6 (Shenzhen Xunlong Software Co., Ltd.)

- **Form factor.** 90×90 mm non-standard. CNX-Software published the
  announcement on 2026-06-25; first stock is on AliExpress.
- **SoC.** CIX P1 / CD8180. 12 cores (4× A720 @ 2.6 GHz, 4× A720 @ 2.4 GHz,
  4× A520 @ 1.8 GHz). GPU = Mali-G720-Immortalis MC10. NPU = Zhouyi V3,
  "28.85 TOPS" / 45 TOPS combined. VPU = the same Linlon codec block on the
  SoC.
- **EC presence.** **U** — vendor spec does not mention EC. No DSDT dump.
  Inferential hint: the Orange Pi 6 spec lists a *"2-pin RTC connector"*
  (see RTC row) — a 2-pin connector is the standard footprint for an
  **external** coin-cell battery or an external RTC module, **not** an
  on-board EC. That is suggestive but **not** confirmed.
- **RTC.** Vendor spec lists *"2-pin RTC connector"* (CNX-Software, 2026-06).
  **C** that the connector exists; **U** whether (a) the connector is wired
  to an on-board RTC chip on the board, or (b) it is purely a user-supplied
  external RTC battery header with no on-board chip. Since the firmware is
  the CIX Sky1 reference EDK-II plus whatever Xunlong's BSP adds, the
  *most likely* architecture is the firmware-owned-via-ERTC pattern (same
  as O6N / MS-R1), but this is **inference, not measurement.**
- **GPU / NPU / VPU.** **C** that the silicon is the same Mali-G720,
  Zhouyi V3, and Linlon VPU (vendor spec). **U** for runtime / driver
  behaviour on this specific board — we have not tested a unit.
- **NIC.** 2× 2.5GbE RJ45 (vendor spec). Chip identity **U**.
- **WiFi.** Optional M.2 E-Key only — no fixed WiFi.
- **Console UART.** **U** — not observed.
- **Suspend / resume.** **U** — unknown. The same architecture-family
  concerns apply (PC states, SCMI perf gating, the 9011 pm-runtime gate).
- **Boot-stage EC NPU core enumeration.** **U** — unknown.
- **DMI allow-list.** `build/70-bootloader.sh` `ncz_efi_rt_workaround()`
  has explicit `case "$pn"` entries for `*"Orange Pi 6"*` and
  `*"OrangePi 6"*` (no spaces between Orange and Pi), and a vendor fallback
  `*Xunlong*|*Shenzhen Xunlong*`. On the *predicted* DMI strings
  (`Shenzhen Xunlong Software Co., Ltd.` + `Orange Pi 6`), the workaround
  is gated OFF and `efi=noruntime` is NOT emitted. **C** that the gate is
  correct on the predicted strings; **U** for the real strings until a unit
  is in hand.

### 3.4 Orange Pi 6 Plus (Shenzhen Xunlong Software Co., Ltd.)

- **Form factor.** 115×100 mm non-standard, with a vendor-supplied metal
  case. CNX-Software published the announcement on 2025-10-15.
- **SoC.** CIX P1 / CD8180 or CD8160 (the spec says "CD8180 or CD8160" — the
  actual SKU varies by RAM size: CD8160 for some lower-tier SKUs, CD8180
  for higher-tier). Same 12-core layout as the Orange Pi 6.
- **EC presence.** **U** — vendor spec does not mention EC. The 2-pin RTC
  connector, same as the smaller Orange Pi 6, is the only inferential hint.
- **RTC.** *"2-pin RTC connector"* (CNX-Software, 2025-10). **C** for the
  connector; **U** for chip identity / on-board vs external. The most-likely
  architecture is the same firmware-owned-via-ERTC pattern as O6N / MS-R1,
  *but this is inference, not measurement.*
- **Plus-specific differences from Orange Pi 6.**
  - 5GbE ports (not 2.5GbE).
  - 16, 32, 64 GB LPDDR5 (the Orange Pi 6 tops out at 32 GB).
  - 115×100 mm vs 90×90 mm.
  - Has a battery interface + charging IC (the Orange Pi 6 dropped that).
  - Larger 132g vs 106g.
- **GPU / NPU / VPU.** Same silicon as Orange Pi 6. **U** for runtime.
- **DMI allow-list.** **The `*"Orange Pi 6 Plus"*` string is NOT in the
  explicit allow-list** in `build/70-bootloader.sh`. The `*Xunlong*` /
  `*Shenzhen Xunlong*` vendor fallback is what would carry it. **C** for the
  gap; **U** for the exact DMI string the board will report. **If the
  firmware reports `OrangePi 6 Plus` or `Orange Pi 6 Plus` under a
  `*Shenzhen Xunlong*` vendor string, the vendor rule will save it.** If the
  vendor string is something else (e.g. `OrangePi`), the explicit allow-list
  will miss it and the `MS-R1*` / `*Micro Computer (HK)*` fallback will
  incorrectly emit `efi=noruntime` — which would wedge the RTC. **Action
  item: verify the DMI string on the first unit and add an explicit entry
  to the allow-list if needed.**

### 3.5 Minisforum MS-R1 (`Micro Computer (HK) Ltd.`, `MS-R1`)

- **EC presence.** **U** — vendor spec does not mention EC. No ACPI scan
  has been published. The fact that the MS-R1 and O6N share an identical
  RTC architecture and the same firmware-wake workaround is the most
  relevant inference: if MS-R1 had an EC mediating wake, the workaround
  would not be needed in the same shape. **Inferential: likely no EC** —
  but this is not measured.
- **RTC.** **Firmware-owned**, identical to O6N. Source:
  `docs/DRIVER_FIDELITY_72.md` — *"O6N and MS-R1 share IDENTICAL RTC
  architecture."* Linux driver: `rtc-efi`, `/dev/rtc0`, `hctosys=1`. **C**.
- **Why `efi=noruntime` is needed on MS-R1.** The MS-R1 firmware has buggy
  EFI runtime services. `efi=noruntime` removes the only path to the RTC,
  but the MS-R1 ships without a real HYM8563 path, so the workaround is
  required to **avoid an RTC-wedge on wake**. The DMI gate is
  `MS-R1*` + `*Micro Computer (HK)*`. **C** —
  `build/70-bootloader.sh` `ncz_efi_rt_workaround()`.
- **GPU / NPU / VPU.** All confirmed working on the MS-R1 (see
  `DRIVER_FIDELITY_72.md` status note / 2026-08-18).
- **NIC.** 2× RTL8127 (10 GbE). Mainline `r8169` covers RTL8127. **C** for
  the chip; **U** for the exact driver variant binding.
- **WiFi.** MediaTek RZ616 (WiFi 6E + Bluetooth 5.3). **C** for the chip.
- **NPU SSDT override.** MS-R1's factory BIOS omits the `_HID="CIXH4010"`
  on the NPU cores, so the cores never enumerate. The
  `build/build-npu-ssdt.sh` + `post-install/80-npu.sh` injects an ACPI
  SSDT override through the kernel's early-initramfs mechanism. **C** —
  this is the canonical MS-R1 fix.
- **Console UART.** `ttyAMA2` (different from O6/O6N). The installer ISO
  lists both `ttyAMA0` and `ttyAMA2` in its cmdline so one ISO covers both
  the O6N (`ttyAMA0`) and MS-R1 (`ttyAMA2`) — a `console=` naming a
  non-existent port is ignored, so listing both is safe. **C**.
- **Suspend / resume.** **U** — no published repro/test result. The same
  firmware-class concern applies via the `efi=noruntime` workaround on the
  same wake path. The CPU0 lockup has not been tested on the MS-R1.

---

## 4. Cross-cutting implications for the resume/wake investigation

These are the conclusions *this document is meant to enable*. None of them
should be acted on without reading the cited source again; they are stated
here so the table and the per-board sections can be checked against them.

1. **The "O6 has EC but O6N doesn't" claim is the load-bearing fact for any
   wake/resume fix.** Any fix that lands on O6N firmware-RTC behaviour cannot
   be assumed to generalise to O6. The O6's real HYM8563-style RTC means the
   O6 has a Linux-enumerable clock source — wake from the RTC interrupt is
   wired differently, and the firmware's role in wake is correspondingly
   smaller. **Implication:** the wake fix needs a gate that picks RTC-wake
   behaviour by EC presence, not by DMI. We do not have that signal today.
2. **O6N and MS-R1 share a RTC architecture but not a firmware.** The
   workaround that protects them is shaped by the firmware, not by the
   silicon. **Source:** `build/70-bootloader.sh` line 6 — *"the workaround
   tracks firmware behaviour, not kernel version."* The implication: when the
   CPU0 lockup is fixed on O6N, the same fix is *more likely* to generalise
   to MS-R1 (same firmware-class) and *less likely* to generalise to O6
   (different EC, different RTC).
3. **Orange Pi 6 / 6 Plus are the biggest unknowns.** The 2-pin RTC connector
   wording is consistent with firmware-owned-via-ERTC (the CIX Sky1 default),
   but no DSDT dump exists in our repo. **Action:** when the first unit
   arrives, the very first five minutes should be `acpidump > dsdt.${board}.dat`
   and `cat /sys/class/dmi/id/{product_name,sys_vendor,product_family}` so
   the DMI string is known and the wake path can be characterised.
4. **The `ncz_efi_rt_workaround()` DMI logic is the only board-specific
   gate in our patch series.** There are three identical copies — in
   `build/70-bootloader.sh`, `assets/refind/ncz-refind-refresh.sh`, and
   `build/build-kernel-debs.sh` — which **must stay synchronised**. The
   comment at line 25 of `build/70-bootloader.sh` says: *"duplicated verbatim
   in [the other two scripts]. KEEP ALL THREE IN SYNC."* The reason for
   duplication (no sourced library) is documented in lines 26-33.
5. **Five board-specific DMI gates already exist in our code, but only
   one is keyed on the wake-class of problem.** The other four are more
   ordinary: `ncz_efi_rt_workaround()` (RTC), `should_apply_npu_ssdt()`
   (NPU cores), `should_apply_panthor()` (Panthor opt-in), and the
   `80010-rtw89` (`Radxa` + `Orion O6|O6N` + `RTL8852B`) in the upstream
   patch series. None of these addresses the wake path. **The next
   workaround added for the CPU0 lockup should follow the same DMI-gate
   pattern**, and the gate should be on the *actual* condition (EC presence,
   kernel/pm-runtime state, ACPI wake capability), not on a board name.
6. **The DTB story is split.** Radxa O6/O6N share `sky1-orion-o6.dtb`;
   MS-R1 uses a separate `cixmsr1` build dir. The Orange Pi boards will
   need their own DTBs (likely sourced from Orange Pi's vendor tree). The
   implication is that the bootloader / DTB handoff across the four
   families is not yet unified — it is per-board, and the
   `ncz_efi_rt_workaround()` gate is the only place where the four families
   are handled in one place.

---

## 5. Sources / confidence legend

Confidence tags used in §2:

- **C** = confirmed. Either:
  - real hardware tested on this actual board (O6N, MS-R1),
  - a DSDT / firmware / ACPI measurement taken from a real unit (O6N RTC),
  - a vendor spec page that states the fact explicitly (O6 CR1220 holder,
    O6N battery header, Orange Pi 2-pin RTC connector, MS-R1 RTL8127 NIC),
  - a code file we carry that contains the fact (bootloader DMI gate,
    `should_apply_npu_ssdt()`, `DRIVER_FIDELITY_72.md` finding).
- **U** = unconfirmed. Either:
  - vendor spec does not state the fact (Orange Pi EC, MS-R1 EC),
  - the fact is a third-party report (Stuart's "O6 has EC, O6N doesn't"),
  - the fact is an inference from architecture or vendor-text pattern
    (Orange Pi 6 / 6 Plus expected RTC architecture),
  - the fact depends on a real unit that has not yet been acquired
    (Orange Pi 6 / 6 Plus DMI strings, O6N on a deep suspend/resume path).

Specific sources read for this document:

- `docs/DRIVER_FIDELITY_72.md` — the O6N + MS-R1 RTC and acceleration
  evidence (659 lines, read in full).
- `docs/ENGINEERING-EFFORT.md` — historical kernel/exploration work that
  produced the cmdline, plus the depth of the Sky1 ACPI/PMD patch series.
- `docs/KERNEL-BUILD-YOCTO.md` — DTB / build dir / kernel channel facts.
- `docs/NCZ-OS-ORGANIZATION.md` — naming / variant taxonomy.
- `docs/RELEASE-HISTORY.md` — release evidence on O6N and MS-R1.
- `docs/ISO-REBAKE-ARGOS-2026-08-21.md` — installer cmdline adaptations
  per board (ttyAMA0 vs ttyAMA2, etc.).
- `docs/KERNEL-WARNINGS-72.md` — 7.2-specific warnings observed on O6N.
- `docs/upstream-patches/srcshelton-comparison-2026-08-20.md` — board
  quirk patches from Stuart's series.
- `docs/upstream-patches/srcshelton-tier2-examination-2026-08-20.md` —
  examination of the `90050` Radxa board profile (O6 vs O6N R8126/R8169).
- `docs/upstream-patches/srcshelton-tier3-examination-2026-08-20.md` —
  examination of the `80010` rtw89 DMI-gated patch.
- `build/70-bootloader.sh` — three copies of the DMI gate (with the
  comment explaining why they are duplicated).
- `build/build-iso-di.sh` — installer cmdline, rtl_nic firmware staging,
  console=ttyAMA0/2 differentiation.
- `build/build-npu-ssdt.sh` + `post-install/80-npu.sh` — MS-R1 NPU
  enumeration fix.
- `post-install/80-npu.sh` — `should_apply_npu_ssdt()` DMI fallback.
- `kernel-source/SOURCE.md` — kernel build provenance.
- Vendor spec pages (CNX-Software, Minisforum):
  - <https://www.cnx-software.com/2024/12/18/radxa-orion-o6-mini-itx-motherboard-is-powered-by-cix-p1-12-core-armv9-soc-with-a-30-tops-ai-accelerator/>
  - <https://www.cnx-software.com/2025/10/14/radxa-orion-o6n-smaller-cheaper-12-core-armv9-nano-itx-sbc-cix-p1-cd8160-soc/>
  - <https://www.cnx-software.com/2025/10/15/orange-pi-6-plus-cix-p1-sbc-64gb-lpddr5-45-tops-ai-performance/>
  - <https://www.cnx-software.com/2026/06/25/orange-pi-6-cix-cd8180-12-core-arm-sbc-gets-2-5gbe-networking-smaller-form-factor-drops-battery-support/>
  - <https://www.minisforum.com/products/ms-r1>
