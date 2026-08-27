# Kernel warning audit — 7.2 (O6N, 2026-08-16)

> Gathered on a `7.2.0-rc7-sky1-ncz` build. The shipping kernel reports
> `7.2.0-sky1-ncz` — same series, release localversion.

Every warning, error and stuck probe the shipped kernel produces on a clean
boot, with evidence and where the fix belongs. Gathered on O6N booted
`sky1.gpu=vendor` with a healthy system (0 failed systemd units).

**Where fixes go.** `assets/kernel/edge/` is a **gitignored staging area** for
build artifacts, and `assets/kernel-manifest.json` checksums the config in it.
Editing the staged config is not a fix — it is untracked, unreproducible, and
breaks the manifest checksum. Kernel config changes belong in the Yocto recipe
`meta-cix/recipes-kernel/linux-cix-sky1-ncz/linux-cix-sky1-ncz_7.2.bb` (or its
config fragments), rebuilt with BitBake.

---

## 1. `CONFIG_DRM_PANIC_SCREEN="qr_code"` is not supported by this build

```
Unsupported value for CONFIG_DRM_PANIC_SCREEN ('qr_code'), falling back to 'user'...
```

**Confirmed in the shipped config:**

```
CONFIG_DRM_PANIC=y
CONFIG_DRM_PANIC_SCREEN="qr_code"
CONFIG_DRM_PANIC_SCREEN_QR_CODE   (absent)
```

The QR-code panic screen requires `CONFIG_DRM_PANIC_SCREEN_QR_CODE`, whose
generator is Rust and is not enabled here. The kernel warns on **every boot**
and falls back to `user`.

**Fix:** either set `CONFIG_DRM_PANIC_SCREEN="user"` to declare what actually
happens (zero behaviour change, removes the warning), or enable the QR option
and its Rust dependency if the QR panic screen is genuinely wanted.
**Impact:** cosmetic, but it is a config that does not mean what it says.
**Confidence:** high — config and log agree.

## 2. `CONFIG_AUTOFS_FS` is not set, and systemd asks for it every boot

```
systemd[1]: Failed to find module 'autofs4'
```

**Confirmed:** `# CONFIG_AUTOFS_FS is not set` in the shipped config, and
`/usr/lib/modules/<kver>/kernel/fs/autofs/` does not exist. systemd requests the
legacy `autofs4` name; nothing can satisfy it because autofs is not built at all.

**Fix:** `CONFIG_AUTOFS_FS=y` in the recipe.
**Impact:** systemd `.automount` units cannot work. Worth fixing rather than
silencing — automount is used for `binfmt_misc` among others.
**Confidence:** high.

## 3. ramoops is configured twice and the second registration fails

```
ramoops: using module parameters
ramoops: already initialized
ramoops PRP0001:03: probe with driver ramoops failed with error -22
```

The cmdline carries 5 `ramoops.*` parameters **and** the ACPI tables expose
PRP0001 ramoops devices. The cmdline instance wins and works
(`pstore backend=ramoops`, 0 stored crashes = nothing pending); the ACPI one
then fails with `-EINVAL`.

**Fix:** drop one of the two configurations — preferably the cmdline
parameters if the ACPI description is correct, or ignore the PRP0001 node.
**Impact:** cosmetic; pstore is functional. Classed as a kludge: two mechanisms
configuring one device.
**Confidence:** high.

## 4. `cdns-usbssp` runtime-PM parent ordering — 10 instances per boot

```
cdns-usbssp CIXH2031:00: runtime PM trying to activate child device CIXH2031:00
                         but parent (CIXH2030:00) is not active
```

Ten of these, one per USB controller instance, at boot.

**Impact:** unknown, and worth establishing. This board has a **known USB
enumeration defect** (devices detected but the hub is never told; unbind/rebind
enumerates instantly) — these PM-ordering complaints are in the same subsystem
and may be related.
**Fix:** needs investigation, not a config toggle.
**Confidence:** the messages are certain; the link to the enumeration bug is a
hypothesis, not established.

## 5. `CIXH5040:00` never probes — stuck deferred forever

```
platform CIXH5040:00: deferred probe pending: platform: supplier CIXH5041:00 not ready
/sys/kernel/debug/devices_deferred:  CIXH5040:00  platform: supplier CIXH5041:00 not ready
```

Present at the end of boot, so this is permanent, not transient.

**IDENTIFIED 2026-08-16.** Both are display devices, from their ACPI paths in
`/sys/bus/platform/devices/*/firmware_node/path`:

| ACPI id | path | what it is | driver bound |
|---|---|---|---|
| `CIXH5040:00` | `\_SB_.EDP0` | eDP0 — embedded DisplayPort, the internal panel | none |
| `CIXH5041:00` | `\_SB_.DPBL` | DP backlight | none |

Both report `status: 15` (present, enabled, functioning), so firmware declares
them real. The eDP panel is device-linked to the backlight as its supplier, the
backlight has no driver, so the panel defers forever.

The consumer side is already present: patch 0008 (`drm-add-cix-linlon-dp-driver`)
matches `{ .id = "CIXH5040" }` and implements `acpi_find_backlight()` /
`fwnode_find_reference(dev->fwnode, "backlight", 0)`, and patch 0161 adds the
CIXH5040 `_DSD` panel properties. What is missing is `CIXH5041`. It DOES exist
in the vendor layer — `meta-cix/.../linux-cix-sky1/files/sky1-patches/0065-treewide-Add-ACPI-device-IDs-for-CIX-Sky1-SoC-periph.patch:332`
and `linux-cix-sky1-next/.../0018-arm64-cix-Add-Sky1-miscellaneous-peripheral-drivers.patch:3735`
both carry `{ "CIXH5041", 0 }` — but neither patch was carried into the 7.2 tree.

**DECISION: document, do not fix.** These boards have NO internal panel
installed (operator, 2026-08-16). Carrying the vendor driver would register a
backlight for a display that does not physically exist. Measured on O6N with
the deferral in place: `card0-DP-2` connected and enabled, `/dev/fb0` present,
`linlondp`, `trilin-dptx-cix` and `cix-edp-panel` all bound — the external
DisplayPort path is entirely unaffected. `/sys/class/backlight/` is empty,
which costs nothing when there is no panel to dim.

**Revisit IF** a Sky1 design with an eDP panel is ever targeted; then carry
`CIXH5041` from the vendor patches above and the existing 0008 consumer code
should complete the link.
**Impact:** none on hardware without an internal panel. One permanent line in
`devices_deferred`.
**Confidence:** high — ACPI paths read from firmware_node, vendor patches
located, display verified working alongside the deferral.

## 6. `sbsa-uart` references an ACPI pinctrl node that does not exist

```
sbsa-uart ARMH0011:02: pctldev with ACPI name '\_SB.MUX0' not found
```

The DSDT points the third UART at a pin-mux device that is not present.

**Fix:** firmware/DSDT side, or a driver quirk to tolerate it.
**Impact:** that UART instance may not be usable. The console UART
(`ttyAMA0`) works, so this is not the serial console.
**Confidence:** high.

## 7. mali kbase runtime-PM refcount warning

```
mali CIXH5000:00: Warning: kbase_device_runtime_init: Device runtime usage
                  count unexpectedly non zero 1
```

Appears at probe. The same counter shows up on unload
(`kbase_device_runtime_disable: ... non zero 1`), and after a kbase unload the
GPU is left in a state where **panthor cannot probe** (`-EINVAL`) — which is why
live mali->panthor switching does not work and the boot entry is the supported
path.

**Fix:** vendor DDK behaviour; likely not ours to fix. Worth reporting upstream
to CIX with the panthor-after-unload reproduction.
**Confidence:** high that they are linked in time; the causal link to the failed
panthor probe is strongly suggested but not proven.

## 8. systemd `bpf-restrict-fs` fails despite BPF LSM being enabled

```
systemd[1]: bpf-restrict-fs: Failed to load BPF object: No such process
```

Not a missing feature: `CONFIG_BPF_LSM=y` and the active LSM list already
includes `bpf` (`capability,landlock,yama,apparmor,tomoyo,bpf,ipe,ima,evm`).

**Fix:** investigate — most likely missing BTF (`CONFIG_DEBUG_INFO_BTF`) or a
systemd/kernel version mismatch.
**Impact:** `RestrictFileSystems=` in unit files is silently inert.
**Confidence:** medium — cause not yet established.

## 9. Kernel taint 4100 — expected, no action

```
tainted = 4100        aipu: loading out-of-tree module taints kernel.
```

4096 (out-of-tree) + 4 (unsigned). The NPU driver is DKMS by doctrine — CIX
drivers are all DKMS, never in-tree. Recorded so the taint flag is not mistaken
for a defect later.

## 10. `CONFIG_VIDEO_LINLON=m` puts a second, unvalidated VPU module in the image

`kernel-manifest.py check` warns:

```
WARN: [edge] CONFIG_VIDEO_LINLON=m is IN-TREE in config-7.2.0-rc7-sky1-ncz —
      accelerators must ship out-of-tree (an in-tree copy masks the validated
      overlay/DKMS module at modprobe time)
```

This is real: **two copies of amvx ship in the image.**

```
kernel/drivers/media/platform/cix/amvx.ko.xz   <- in-tree, from CONFIG_VIDEO_LINLON=m
updates/dkms/amvx.ko.xz                        <- the validated DKMS build
```

**It is currently LATENT, not active.** Verified on O6N: `modprobe
--show-depends amvx` resolves to `updates/dkms/amvx.ko.xz`, `modules.dep` lists
the updates path, and the VPU nodes are present (`/dev/video0-3`,
`/dev/video-cixdec0`). `updates/` outranks `kernel/` in depmod's search order,
so the right module wins today.

It becomes an active defect the moment the DKMS build fails or is skipped for a
kernel: depmod then finds only the in-tree copy and loads an **unvalidated**
VPU driver silently, with no error anywhere. That is the failure mode the
"CIX drivers are all DKMS, never in-tree" doctrine exists to prevent, and it is
the same class as the panthor/mali case where `CONFIG_*=y` cannot be overridden
at runtime.

**Fix:** unset `CONFIG_VIDEO_LINLON` in the kernel recipe so only the DKMS
module exists.
**Impact:** none today; silent use of an unvalidated VPU driver if DKMS ever
fails.
**Confidence:** high — both copies confirmed on disk, resolution confirmed by
modprobe.

Related, from the same manifest run: the NPU entry reports `npu=None (?)
[MISMATCH]`. Catching NPU vermagic drift is the manifest's stated purpose, and
it currently cannot see the module at all. Worth fixing so the check is real.
The NPU itself is clean — `aipu.ko.xz` exists only under `updates/dkms/`.

---

## Summary

| # | Finding | Fix location | Priority |
|---|---|---|---|
| 1 | DRM_PANIC_SCREEN unsupported value | kernel recipe config | low, trivial |
| 2 | AUTOFS_FS not built | kernel recipe config | medium, trivial |
| 3 | ramoops configured twice | cmdline or DSDT | low |
| 4 | cdns-usbssp PM ordering x10 | investigation | medium |
| 5 | CIXH5040 permanently deferred | identify device | medium |
| 6 | sbsa-uart missing pinctrl node | DSDT/firmware | low |
| 7 | kbase PM refcount, blocks panthor probe after unload | vendor / upstream report | medium |
| 8 | bpf-restrict-fs inert | investigation | low |
| 9 | taint 4100 | none — expected | none |
| 10 | CONFIG_VIDEO_LINLON=m ships a 2nd, unvalidated amvx | kernel recipe config | medium (latent) |
| 11 | manifest cannot see the NPU module (npu=None) | build/kernel-manifest.py | medium |

Items 1 and 2 are one-line config changes and should land in the 7.2 port.
