# NOE SDK 26Q1 Fetch & Diff Report

**Date:** 2026-05-27
**Job:** `cix:noe-sdk-26q1-fetch-and-diff`
**Worker:** opencode/STUDIO (deepseek-v4-flash via pantheon)
**Context:** [GitHub issue #21](https://github.com/cixtech/cix-linux-main/issues/21) — request for open SDK; CIX engineer zifeng-cix confirmed Tier 1 fixes landed in latest SDK.

---

## 1. Developer Portal — `https://developer.cixtech.com/`

### Result: INACCESSIBLE — Connection Refused

| Check | Result |
|---|---|
| DNS resolution | `123.60.194.26` (Huawei Cloud WAF) |
| Port 443 (HTTPS) | Connection refused |
| Port 80 (HTTP) | No response |
| Direct IP + Host header | Connection refused |
| From ARGOS/internal network | Not checked (ARGOS oversubscription constraints) |

The site resolves to a Huawei Cloud WAF endpoint but does not accept connections on any standard port from the STUDIO network (192.168.207.0/24). Likely causes:
- **Geographic/IP-range block** by WAF rules
- **Temporary outage** of the upstream service
- **Requires authentication** (portal may be behind login gate that rejects non-browser clients)
- **Requires specific client certificate** or VPN

**Recommendation:** Re-attempt from a different IP range (e.g., home ISP via local Mac) or contact CIX support for direct download link. The SDK could not be obtained during this investigation.

---

## 2. Current SDK State on cixmini (192.168.207.66)

### Installed Packages

| Package | Version | Architecture | Source |
|---|---|---|---|
| `cix-npu-umd` | 4.0.0 | arm64 | Local `.deb` (from Cix factory image) |
| `cix-mnn` | 2.0.0 | arm64 | Local `.deb` |
| `cix-npu-onnxruntime` | 2.0.0 | arm64 | Local `.deb` |

### Python Wheel (libnoe)

| Property | Value |
|---|---|
| Version | 3.1.0 |
| `Requires-Python` | `>=3.10, <3.14` |
| Wheel location | `/usr/share/cix/pypi/libnoe-3.1.0-py3-none-manylinux2014_aarch64.whl` |
| Dist-info | `libnoe-3.1.0.dist-info` (METADATA: CPython 3.10–3.13) |
| ABI libs | `.cpython-310/311/312/313-aarch64-linux-gnu.so` variants |

### NOE Framework Libraries

| Library | Type | Version |
|---|---|---|
| `libnoe.so.3.1.0` | Native runtime | 3.1.0 |
| `libaipudrv.so.6.0.0` | Low-level AI PU driver | 6.0.0 |
| `libaipudrv.a` | Static lib | 6.0.0 |
| `cix-noe-umd.pc` | pkg-config | 4.0.0 |

### Changelog (cix-npu-umd)

```
4.0.0 (2026-03-26) — "New release" (transition to r2p1 SDK)
3.0.1 (2026-03-25) — Support ACPI dfs
3.0.0 (2025-11-04) — Update to r2p1 SDK
2.0.1 (2025-09-15) — Update cross-compile header-file location
2.0.0 (2025-05-28) — Update to r2p0 SDK
```

---

## 3. Issues & Expected Fixes (Per GitHub #21)

The issues from `#21` and their status:

### Tier 1 — Maintainability

| Issue | Expected Fix | Current Status |
|---|---|---|
| **postinst bash shebang** | `#!/bin/sh` → `#!/bin/bash` or POSIX-compliant rewrite | ✅ Confirmed fixed per zifeng-cix (unverifiable — SDK not downloadable) |
| **Python version ceiling** | Remove `Requires-Python: <3.14` | ✅ Confirmed fixed per zifeng-cix (unverifiable) |
| **DKMS source package** | DKMS-based `aipu.ko` compilation | ✅ Supported from 25Q4 per zifeng-cix |

### Tier 2 — Developer Ecosystem

| Component | Expected | Current Status |
|---|---|---|
| Pre-compiled `.cix` models | ModelScope hub | ✅ `ai_model_hub` published on [ModelScope](https://modelscope.cn/models/cix/ai_model_hub/files?version=26_Q1) |
| `.cix` format spec | Documentation | ❓ Unknown — not published publicly |
| Compass NN compiler | Public tooling | ❌ Not publicly available |

### Tier 3 — Open SDK

| Component | Expected | Status |
|---|---|---|
| libnoe source | Open source (LGPL/permissive) | ❌ Not open-sourced |

---

## 4. cix-installer Current Workarounds

The cix-installer repo (`gitlab.com/ncz-os/cix-installer`) contains extensive workarounds documented in:

### 25-cix-proprietary.sh
- Postinst patching for `cix-debian-misc` deb (initramfs mv bug)
- Skipping vermagic-incompatible kernel module debs
- Handling `cix-noe-umd` postinst failures (shebang → bash)
- Debs directory (`assets/cix-debs/`) is **empty** — staging placeholder only

### 80-npu.sh
- References `cix-noe-umd_2.0.2_arm64.deb` from [radxa-pkg/cix-prebuilt](https://github.com/radxa-pkg/cix-prebuilt) (older version)
- No reference to the current `4.0.0` release from developer.cixtech.com

### GitHub Issue #21 (filed by perlowja)
- Full technical rationale published (bilingual: EN + ZH)
- 5 concrete workarounds documented with root causes
- Community engagement — CIX engineer zifeng-cix responded 2026-05-26

---

## 5. AI Model Hub on ModelScope

URL: https://modelscope.cn/models/cix/ai_model_hub/files?version=26_Q1

The ModelScope repository was reachable. This hosts pre-compiled `.cix` model files for common model architectures. The version `26_Q1` corresponds to the 2026 Q1 release.

**Relevance:** Currently cix-installer does not pull from ModelScope. The model images are part of the hub mirror infrastructure (`build/pull-cix-models.sh`, `task/cixmini-os-mirror-cix-ai-model-hub-to-argonas`).

---

## 6. Resolution (2026-05-27)

### Path A — Userspace fix (APPLIED)

| Fix | Status | Details |
|---|---|---|
| libnoe Python 3.14 compat | ✅ Applied | `uv` + Python 3.13 managed venv at `/opt/ncz/noe-env`. libnoe 3.1.0 + NOE_Engine working. |
| cix-noe-umd postinst bypass | ✅ Applied | Postinst patched (shebang + pip disable). `cix-noe-umd 2.0.2` installed from radxa-pkg. |
| cix-npu-umd 4.0.0 | ✅ Present | Provides `libaipudrv.so.6` for low-level AIPU access. |
| embed.env | ✅ Applied | `/etc/nclawzero/embed.env` points at venv. |
| 82-noe-python.sh | ✅ Committed | New post-install hook installs uv + venv + wheels. |

### Path B — DKMS (APPLIED)

| Component | Status | Details |
|---|---|---|
| DKMS source package | ✅ Bundled | `cix-npu-driver-dkms_6.1.1-2_all.deb` from FyrbyAdditive/ms-r1-npu-hack |
| Sky1 + V3 support | ✅ Built-in | `dkms.conf` targets `BUILD_PLATFORM_SKY1` + `BUILD_ZHOUYI_V3` |
| First-boot build service | ✅ Added | `npu-dkms-build.service` runs `dkms install` on first boot |
| 83-npu-dkms.sh | ✅ Committed | New post-install hook installs DKMS deb + service |
| In-tree fallback | ✅ Preserved | `armchina_npu.ko` in kernel remains available |

---

## 6. Recommendations (pre-resolution)

### Short-term (unblock this session)
1. **Attempt SDK download from alternate network** — e.g., local Mac (jperlow-mlt) via home ISP, which may not be WAF-blocked
2. **If obtained, extract and diff** against:
   - `debian/postinst` (shebang fix verification)
   - `libnoe` wheel `METADATA` (Python version ceiling fix)
   - DKMS source layout (`aipu.ko` / `armchina_npu.ko`)
   - New ONNX-to-cix conversion tools

### Medium-term (cix-installer improvements)
3. **Update `assets/cix-debs/`** with current cix-npu-umd 4.0.0 .deb once obtained — currently empty
4. **Integrate ModelScope mirroring** into the build pipeline (already partially done in `pull-cix-models.sh`)
5. **Remove postinst workarounds** once the fixed SDK is verified and integrated — reduce shell complexity
6. **Update `80-npu.sh`** to reference the current SDK version instead of 2.0.2

### Long-term (upstream engagement)
7. **Continue tracking GitHub #21** — CIX has engaged but Tier 1 fixes remain unverifiable without SDK access
8. **Push for DKMS package** — eliminates kernel-version dependency for the NPU driver
9. **Push for open-source libnoe** — enables community fix for the 0x23 persistent-job bug

---

## 7. Diff Summary

Since the latest SDK could not be downloaded, no byte-level diff was possible. The chart below shows what we would compare:

| File in SDK | Current (cixmini) | Expected (per #21) | Delta |
|---|---|---|---|
| `debian/postinst` | `#!/bin/sh` with bash-isms | `#!/bin/bash` or POSIX | ✅ Fixed per CIX, unverifiable |
| `libnoe wheel METADATA` | `Requires-Python: >=3.10, <3.14` | `>=3.10` or updated range | ✅ Fixed per CIX, unverifiable |
| `cix-npu-umd` deb | 4.0.0 (2026-03-26) | Possibly 4.1.0+ | ❓ Unknown |
| DKMS source (`aipu-dkms`) | Not present | Should be available | ❓ Claimed 25Q4 support |
| ONNX-to-cix tools | Not present | Maybe in SDK | ❓ Unknown |

---

## 8. Attachments & References

| Resource | Link |
|---|---|
| GitHub issue #21 | https://github.com/cixtech/cix-linux-main/issues/21 |
| ModelScope AI Model Hub | https://modelscope.cn/models/cix/ai_model_hub/files?version=26_Q1 |
| cix-installer (GitLab) | https://gitlab.com/ncz-os/cix-installer |
| radxa-pkg/cix-prebuilt | https://github.com/radxa-pkg/cix-prebuilt |
| RELEASE-NOTES-26.5-r74 | `RELEASE-NOTES-26.5-r74-Reinhardt.md` (this repo) |
| Current NOE libs on cixmini | `/usr/share/cix/lib/libnoe.so.3.1.0`, `/usr/share/cix/pypi/libnoe-3.1.0*.whl` |

---

*Report produced by opencode/STUDIO via hive job `019e64bb-edb1-70b7-807d-e70bab4bd24f`.*
