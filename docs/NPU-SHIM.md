# NPU IOCTL Translation Shim — r2p1 SDK ↔ r2p0 Kernel Bridge

**Date:** 2026-05-27  
**Kernel:** Reinhardt 7.0.9 (custom, CONFIG_ARMCHINA_NPU=m, V3+V3_1+Sky1)  
**SDK:** CIX NOE SDK 26Q1 (cix-npu-umd 3.0.2, cix-noe-umd 3.1.2, libnoe 3.1.2)

## Problem

The Cix NOE SDK 26Q1 (r2p1) uses different kernel ioctl struct layouts than the in-tree `armchina_npu` driver (r2p0). These are NOT binary compatible — different field sizes, offsets, and enum values.

### Struct Layout Differences

| IOCTL | r2p1 (SDK) | r2p0 (kernel) | Delta |
|---|---|---|---|
| `QUERY_CAP` (nr=0) | 200 bytes, `asid_base[4]` | 424 bytes, `asid_base[32]` | 224 bytes |
| `QUERY_PARTITION_CAP` (nr=1) | 128 bytes | 128 bytes | **same** |
| `REQ_BUF` (nr=2) | 80 bytes | 56 bytes | 24 bytes (added fields) |
| `SCHEDULE_JOB` (nr=6) | 144 bytes | 128 bytes | 16 bytes (`is_coredump_en`) |
| `FREE_BUF` (nr=3) | 40 bytes | 32 bytes | 8 bytes (`exec_id`) |

### Field-Level Differences

**`aipu_cap` (QUERY_CAP):**
- r2p1: `asid_base[4]` (32 bytes) at offset 8
- r2p0: `asid_base[32]` (256 bytes) at offset 8
- All subsequent fields (`is_homogeneous`, `dtcm_base`, `gm0_size`, `gm1_size`, `partition_cap`) shift by 224 bytes

**`aipu_buf_request` (REQ_BUF):**
- r2p1 adds `exec_id` (8 bytes), `reserve_iova_size` (8 bytes), `alloc_mode` (1 byte)
- `align_in_page` shifts from offset 8 → 24
- `desc` shifts from offset 24 → 40
- `desc.exec_id` (8 bytes) added, shifting `region`/`asid`

**`aipu_job_desc` (SCHEDULE_JOB):**
- r2p1 adds `is_coredump_en` (4 bytes) at the end
- Rest of the struct (first 128 bytes) is identical

## Solution Architecture

### Userspace: LD_PRELOAD Shim (`aipu_shim.so`)

Intercepts `ioctl()` calls on `/dev/aipu` and translates:
1. **QUERY_CAP**: Full field remapping (200→424 bytes). Handles all 11 fields with correct offset mapping. Clamps `asid_cnt` from 32→4 for safety.
2. **REQ_BUF**: Full field remapping (80→56 bytes). Converts `align_in_page` from log2→byte value. Maps `desc` fields with correct offsets.
3. **Other ioctls**: Sized-based passthrough (ioctl number won't match kernel's expected size, so kernel returns ENOTTY).

### Kernel: SCHEDULE_JOB Patch

Applied to `drivers/misc/armchina-npu/aipu.c`:

```c
/* Before the switch statement, handle SCHEDULE_JOB 144-byte ioctl */
if (_IOC_TYPE(cmd) == AIPU_IOCTL_MAGIC && _IOC_NR(cmd) == 6 && _IOC_SIZE(cmd) == 144) {
    struct aipu_job_desc jd;
    if (!copy_from_user(&jd, (void __user *)arg, sizeof(jd)))
        ret = aipu_job_manager_scheduler(manager, &jd, filp);
    else
        ret = -EINVAL;
    return ret;
}
```

The extra `is_coredump_en` field is truncated via `sizeof(jd)` = 128 bytes.

## Build & Deploy

```bash
# 1. Build shim
gcc -shared -fPIC -o aipu_shim.so aipu_shim.c -ldl

# 2. Build kernel with patch
cd /usr/src/linux-7.0.9-cix-sky1-next
make -C /lib/modules/7.0.9/build M=$(pwd)/drivers/misc/armchina-npu modules
cp drivers/misc/armchina-npu/armchina_npu.ko /lib/modules/7.0.9/kernel/drivers/misc/armchina-npu/
depmod -a
modprobe -r armchina_npu; modprobe armchina_npu

# 3. Run
LD_PRELOAD=/opt/ncz/aipu_shim.so python3 -c "from NOE_Engine import EngineInfer; ..."
```

## Pipeline Status

```
NOE_Engine.__init__()
  ├── _init_context()    → QUERY_CAP          ✅ (shim: 200→424)
  ├── _load_graph()      → REQ_BUF × N        ✅ (shim: 80→56, N allocations)
  ├── _setup_tensors()
  └── forward()
       ├── _init_context()
       ├── create_job()                        ✅
       └── job_infer_sync() → SCHEDULE_JOB     ✅ (kernel bypass)
            └── QUERY_STATUS                    ✅ (same size, passthrough)
                      → get_tensor()           ✅
```

## Limitations

1. **Feature flags not checked**: `_IOC_DIR` is not validated, trusting the shim's direction table
2. **No multi-fd safety**: All `/dev/aipu` fds share the same tracking array (up to 256 fds)
3. **exec_id generated**: The kernel doesn't provide `exec_id`; set to 0 for all allocations
4. **Single-NPU only**: Assumes a single AIPU device; multi-NPU systems need fd-to-context mapping

## References

- SDK KMD header: `cix-npu-umd 3.0.2` → `/usr/share/cix/include/npu/kmd/armchina_aipu.h`
- Kernel header: `/usr/src/linux-7.0.9-cix-sky1-next/include/uapi/misc/armchina_aipu.h`
- SDK docs: `CIX-P1-NPU 开发指导手册_v1.2.pdf` (Chinese dev guide)
- GitHub issue: cixtech/cix-linux-main#21 (request for open SDK)
