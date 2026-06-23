# Cix Sky1 NPU ioctl mismatch analysis

Bundle path analyzed: `/tmp/cix-npu-ioctl-bundle/`

This analysis is read-only with respect to the supplied sources and binaries. The only written file is this report.

## Executive finding

`aipu_init_context` fails because the userspace backend and loaded KMD disagree on the encoded size of `struct aipu_cap`, and that size is part of the Linux ioctl number.

The failing userspace backend `libaipu_driver.so` issues:

```
AIPU_IOCTL_QUERY_CAP = 0x80c84100 decimal 2160607488
dir=2 (_IOR), size=0x0c8 (200), type=0x41 ('A'), nr=0
0x80c84100 = (2 << 30) | (0x0c8 << 16) | (0x41 << 8) | 0
```

The loaded KMD `armchina_npu-7.0.3-cix-sky1-next.ko` dispatches query-cap only as:

```
AIPU_IOCTL_QUERY_CAP = 0x81a84100 decimal 2175287552
dir=2 (_IOR), size=0x1a8 (424), type=0x41 ('A'), nr=0
0x81a84100 = (2 << 30) | (0x1a8 << 16) | (0x41 << 8) | 0
```

The modern UMD therefore hits the KMD default `-ENOTTY` path. In `libaipu_driver.so`, `aipudrv::Aipu::init()` treats either a non-zero ioctl return or a zero `cap.partition_cnt` as `query capability [fail]`.

The `partition_cnt == 0` symptom is most likely a downstream observation of the zeroed userspace stack buffer after the ioctl failed, not a successful KMD response. The KMD query handler has no version check and fills `partition_cnt` from `aipu->partition_cnt`; clean probe logs showing one enabled partition mean a successful query should return `partition_cnt == 1`.

## Numeric convention

All ioctl derivations use Linux generic encoding:

```
_IOC(dir, type, nr, size) = (dir << 30) | (size << 16) | (type << 8) | nr
_IO(type,nr)              = _IOC(0, type, nr, 0)
_IOR(type,nr,struct)      = _IOC(2, type, nr, sizeof(struct))
_IOW(type,nr,struct)      = _IOC(1, type, nr, sizeof(struct))
_IOWR(type,nr,struct)     = _IOC(3, type, nr, sizeof(struct))
AIPU_IOCTL_MAGIC          = 'A' = 0x41
```

## Step 1: userspace ioctl extraction

### `libaipu_driver.so`

`libaipu_driver.so` imports `ioctl@GLIBC_2.17` and exports `aipu_init_context`:

```
/tmp/cix-npu-ioctl-bundle/libaipu_driver.so
nm -D --demangle:
0000000000041910 T aipudrv::Aipu::init()
0000000000042250 T aipudrv::Aipu::ioctl_cmd(unsigned int, void*)
0000000000038fd0 T aipu_init_context
                 U ioctl@GLIBC_2.17
```

The query-cap ioctl is formed immediately before the `ioctl@plt` call in `aipudrv::Aipu::init()`. In this shared object `.text` has VMA `0x18780` and file offset `0x18780`, so the VMA below is also the file offset.

```
libaipu_driver.so, aipudrv::Aipu::init(), VMA/file offset 0x41a04:
   41a04: d2882001  mov  x1, #0x4100
   41a08: 910223e2  add  x2, sp, #0x88
   41a0c: f2b01901  movk x1, #0x80c8, lsl #16
   41a10: 97ff5714  bl   17660 <ioctl@plt>
   41a14: 35000060  cbnz w0, 41a20
   41a18: b9408be1  ldr  w1, [sp, #136]
   41a1c: 350004e1  cbnz w1, 41ab8
```

Derivation:

```
x1 = 0x80c84100
dir=2, size=0x0c8, type=0x41, nr=0
0x80c84100 = (2 << 30) | (0x0c8 << 16) | (0x41 << 8) | 0
```

The failure test is also visible there: `cbnz w0` fails on non-zero ioctl return, and `ldr w1, [sp,#136]` checks `cap.partition_cnt` at offset 0.

The strings associated with that path are present:

```
libaipu_driver.so strings:
0x7ea78 AIPU UMD API input argument(s) contain NULL pointer.
0x7fbe0 .../umd/src/device/aipu/aipu.cpp
0x7fef0 %s%s%s:%d:<tid:%ld>: query capability [fail]
```

Unique direct kernel ioctl constants observed in `libaipu_driver.so` are below. Repeated call sites are folded into one row. The derivation column is `dir,size,type,nr`.

| Name inferred from bundled headers | Value hex | Value dec | Derivation | Direct call evidence |
|---|---:|---:|---|---|
| AIPU_IOCTL_ABORT_CMD_POOL | 0x0000410b | 16651 | 0,0x000,0x41,11 -> `(0<<30)|(0<<16)|(0x41<<8)|11` | VMA 0x428a8 |
| AIPU_IOCTL_DISABLE_TICK_COUNTER | 0x0000410c | 16652 | 0,0x000,0x41,12 -> `(0<<30)|(0<<16)|(0x41<<8)|12` | VMA 0x425f0 |
| AIPU_IOCTL_ENABLE_TICK_COUNTER | 0x0000410d | 16653 | 0,0x000,0x41,13 -> `(0<<30)|(0<<16)|(0x41<<8)|13` | VMA 0x42b1c |
| AIPU_IOCTL_QUERY_CAP | 0x80c84100 | 2160607488 | 2,0x0c8,0x41,0 -> `(2<<30)|(0x0c8<<16)|(0x41<<8)|0` | VMA 0x41a04/0x41a0c |
| AIPU_IOCTL_QUERY_PARTITION_CAP | 0x80804101 | 2155888897 | 2,0x080,0x41,1 -> `(2<<30)|(0x080<<16)|(0x41<<8)|1` | VMA 0x41af4/0x41afc |
| AIPU_IOCTL_REQ_BUF | 0xc0504102 | 3226484994 | 3,0x050,0x41,2 -> `(3<<30)|(0x050<<16)|(0x41<<8)|2` | VMA 0x46c40/0x46c48 and 0x46d00/0x46d08 |
| AIPU_IOCTL_FREE_BUF | 0x40284103 | 1076379907 | 1,0x028,0x41,3 -> `(1<<30)|(0x028<<16)|(0x41<<8)|3` | VMA 0x4619c/0x461b4/0x461ec, 0x46560/0x46568, 0x4694c/0x46954, 0x46f7c/0x46f84 |
| AIPU_IOCTL_SCHEDULE_JOB | 0x40904106 | 1083195654 | 1,0x090,0x41,6 -> `(1<<30)|(0x090<<16)|(0x41<<8)|6` | VMA 0x3fbcc/0x3fbd4 |
| AIPU_IOCTL_QUERY_STATUS | 0xc0184107 | 3222814983 | 3,0x018,0x41,7 -> `(3<<30)|(0x018<<16)|(0x41<<8)|7` | VMA 0x44968/0x44970 |
| AIPU_IOCTL_REQ_IO | 0xc0144109 | 3222552841 | 3,0x014,0x41,9 -> `(3<<30)|(0x014<<16)|(0x41<<8)|9` | VMA 0x3f988/0x3f998, 0x3fa9c/0x3faa4, 0x4016c/0x40174 |
| AIPU_IOCTL_CONFIG_CLUSTERS | 0x4020410e | 1075855630 | 1,0x020,0x41,14 -> `(1<<30)|(0x020<<16)|(0x41<<8)|14` | VMA 0x4269c/0x426a0 |
| AIPU_IOCTL_ALLOC_DMA_BUF | 0x8018410f | 2149073167 | 2,0x018,0x41,15 -> `(2<<30)|(0x018<<16)|(0x41<<8)|15` | VMA 0x42550/0x4255c |
| AIPU_IOCTL_FREE_DMA_BUF | 0x40044110 | 1074020624 | 1,0x004,0x41,16 -> `(1<<30)|(0x004<<16)|(0x41<<8)|16` | VMA 0x42610/0x42624 |
| AIPU_IOCTL_GET_DMA_BUF_INFO | 0xc0204111 | 3223339281 | 3,0x020,0x41,17 -> `(3<<30)|(0x020<<16)|(0x41<<8)|17` | VMA 0x4165c/0x41664, 0x42454/0x42458, 0x42a2c/0x42a34 |
| AIPU_IOCTL_GET_DRIVER_VERSION | 0x80084112 | 2148024594 | 2,0x008,0x41,18 -> `(2<<30)|(0x008<<16)|(0x41<<8)|18` | VMA 0x424d0/0x424d8 |
| AIPU_IOCTL_ATTACH_DMA_BUF | 0xc0204113 | 3223339283 | 3,0x020,0x41,19 -> `(3<<30)|(0x020<<16)|(0x41<<8)|19` | VMA 0x42358/0x42364 |
| AIPU_IOCTL_DETACH_DMA_BUF | 0x40044114 | 1074020628 | 1,0x004,0x41,20 -> `(1<<30)|(0x004<<16)|(0x41<<8)|20` | VMA 0x42734/0x42748 |
| AIPU_IOCTL_ALLOC_GRID_ID | 0x80044115 | 2147762453 | 2,0x004,0x41,21 -> `(2<<30)|(0x004<<16)|(0x41<<8)|21` | VMA 0x3fd1c/0x3fd28 |
| AIPU_IOCTL_ALLOC_GROUP_ID | 0xc0044116 | 3221504278 | 3,0x004,0x41,22 -> `(3<<30)|(0x004<<16)|(0x41<<8)|22` | VMA 0x4443c/0x44444 |
| AIPU_IOCTL_FREE_GROUP_ID | 0x40044117 | 1074020631 | 1,0x004,0x41,23 -> `(1<<30)|(0x004<<16)|(0x41<<8)|23` | VMA 0x44830/0x44838 |
| AIPU_IOCTL_GET_CLUSTER_STATUS | 0xc00c4118 | 3222028568 | 3,0x00c,0x41,24 -> `(3<<30)|(0x00c<<16)|(0x41<<8)|24` | VMA 0x401e4/0x401e8 |
| AIPU_IOCTL_REBIND_DMA_BUF | 0xc018411c | 3222815004 | 3,0x018,0x41,28 -> `(3<<30)|(0x018<<16)|(0x41<<8)|28` | VMA 0x422ac/0x422b0 |

### `libnoe.so`

`libnoe.so` does not import libc `ioctl`, and no `ioctl@plt` call exists in the binary. It imports `dlopen` and `dlsym`, and strings show it loads the AIPU backend dynamically:

```
readelf -Wr libnoe.so:
0000000000142c00 ... R_AARCH64_JUMP_SLOT dlsym@GLIBC_2.34
0000000000144170 ... R_AARCH64_JUMP_SLOT dlopen@GLIBC_2.34

strings -a -t d libnoe.so:
1017128 libaipudrv.so
1017144 AIPU_LIB_PATH
1017280 aipu_init_context
1017744 aipu_ioctl
```

The exported NoE ioctl path forwards an abstract command to the dlopened backend. It does not form a kernel ioctl immediate:

```
libnoe.so, AipuAdapter::ioctl(noe_context*, device_type_t, ioctl_cmd_t, void*), VMA 0xb3790:
   b3790: 2a0303e1  mov x1/w1, command argument
   b3794: aa0403e2  mov x2, payload argument
   b3798: f9400403  ldr x3, [x0, #8]
   b379c: f9400460  ldr x0, [x3, #8]
   b37a0: f9408463  ldr x3, [x3, #264]
   b37a4: aa0303f0  mov x16, x3
   b37a8: d61f0200  br  x16

libnoe.so, AipuAdapter::init_context(), VMA 0xb3e84:
   b3e84: f9403001  ldr x1, [x0, #96]
   b3e88: b4000441  cbz x1, b3f10
   b3e8c: 91002000  add x0, x0, #0x8
   b3e90: d63f0020  blr x1
```

Therefore the equivalent kernel query-cap number from `libnoe.so` is "none directly". If `libnoe.so` dlopens the provided `libaipu_driver.so` or an equivalent modern `libaipudrv.so`, the effective query-cap number is `0x80c84100`.

## Step 2: KMD ioctl dispatch and query handler

### KMD identity and symbols

`armchina_npu-7.0.3-cix-sky1-next.ko` is an unstripped AArch64 relocatable module. Relevant identity evidence:

```
readelf -n:
Build ID: 805dde1ad8943585e09b733f030b8e1006e021ad

readelf -p .modinfo:
name=aipu
vermagic=7.0.3-cix-sky1-next SMP preempt mod_unload aarch64

strings -a -t x:
0x128c8 6.1.1-2
0x128d0 AIPU KMD (v%s) probe start...
0x1521b armchina-npu/aipu.c
0x1522f /home/jasonperlow/yocto-tmp/.../kernel-source/include/linux/ucopysize.h
```

Symbol table:

```
0000000000001748 g F .text 00000000000017d0 aipu_ioctl
000000000000e4f8 g F .text 0000000000000190 aipu_priv_query_capability
```

For this `.ko`, `.text` has VMA `0x880` and file offset `0xa38`. Thus:

```
aipu_ioctl VMA 0x1748 -> file offset 0x1900
query-cap compare VMA 0x1b48 -> file offset 0x1d00
```

### Dispatch magic and default return

The KMD first checks the ioctl type byte and returns `-ENOTTY` for bad magic or unknown command:

```
armchina_npu...ko, aipu_ioctl, VMA 0x1818:
   1818: 12181e61  and w1, w19, #0xff00
   1824: 52882000  mov w0, #0x4100
   1838: 6b00003f  cmp w1, w0
   183c: 54009641  b.ne 2b04

unknown command:
   2a48: 92800300  mov x0, #0xffffffffffffffe7  ; -25, -ENOTTY

bad magic:
   2b04: ... _dev_err ...
   2b1c: 92800300  mov x0, #0xffffffffffffffe7  ; -25, -ENOTTY
```

The modern userspace value `0x80c84100` passes the type-byte check because `(cmd & 0xff00) == 0x4100`, but it does not match any query-cap case, so it falls to `0x2a48` and returns `-ENOTTY`.

### KMD query-cap dispatch

The loaded KMD query-cap case is:

```
armchina_npu...ko, aipu_ioctl, VMA/file offset 0x1b48/0x1d00:
   1b48: 52882000  mov  w0, #0x4100
   1b4c: 72b03500  movk w0, #0x81a8, lsl #16
   1b50: 6b00027f  cmp  w19, w0
   1b54: 540077a1  b.ne 2a48
   1b58: 910e43e1  add  x1, sp, #0x390
   1b5c: aa1503e0  mov  x0, x21
   1b60: 94000000  bl   e4f8 <aipu_priv_query_capability>
   ...
   1b94: d2803502  mov  x2, #0x1a8
   1b98: 910e43e1  add  x1, sp, #0x390
   1b9c: 94000000  bl   0 <__arch_copy_to_user>
```

Derivation:

```
w0 = 0x81a84100
dir=2, size=0x1a8, type=0x41, nr=0
0x81a84100 = (2 << 30) | (0x1a8 << 16) | (0x41 << 8) | 0
copy_to_user size = 0x1a8 = 424
```

### KMD dispatch table

The table below is the set of ioctl values dispatched by `aipu_ioctl` in the loaded KMD. Every value is derived with `(dir<<30)|(size<<16)|(0x41<<8)|nr`. Evidence addresses are KMD VMA in `aipu_ioctl`.

| Name inferred | Value hex | Value dec | dir | size | nr | Evidence |
|---|---:|---:|---:|---:|---:|---|
| QUERY_CAP, old 424-byte cap | 0x81a84100 | 2175287552 | 2 | 0x1a8 | 0 | 0x1b48/0x1b4c, copy size 0x1a8 at 0x1b94 |
| QUERY_PARTITION_CAP | 0x80804101 | 2155888897 | 2 | 0x080 | 1 | 0x186c/0x1870 |
| REQ_BUF, legacy v0 | 0xc0384102 | 3224912130 | 3 | 0x038 | 2 | 0x1c58/0x1c5c, copy size 0x38 at 0x25c8 |
| REQ_BUF, modern | 0xc0504102 | 3226484994 | 3 | 0x050 | 2 | 0x1c68/0x1c6c, copy size 0x50 at 0x2044 |
| FREE_BUF | 0x40284103 | 1076379907 | 1 | 0x028 | 3 | 0x1a20/0x1a24, copy size 0x28 at 0x1dd0 |
| DISABLE_SRAM | 0x00004104 | 16644 | 0 | 0x000 | 4 | 0x1904 |
| ENABLE_SRAM | 0x00004105 | 16645 | 0 | 0x000 | 5 | 0x1910 |
| SCHEDULE_JOB, legacy | 0x40884106 | 1082671366 | 1 | 0x088 | 6 | 0x1bbc/0x1bc0, copy size 0x88 at 0x1e4c |
| SCHEDULE_JOB, modern | 0x40904106 | 1083195654 | 1 | 0x090 | 6 | 0x1840/0x1848, copy size 0x90 at 0x253c |
| QUERY_STATUS | 0xc0184107 | 3222814983 | 3 | 0x018 | 7 | 0x1968/0x196c, copy size 0x18 at 0x19a4 |
| KILL_TIMEOUT_JOB | 0x40044108 | 1074020616 | 1 | 0x004 | 8 | computed at 0x1ab0 from 0x40044114 - 0xc; handler copies 8 at 0x29b4 |
| REQ_IO | 0xc0144109 | 3222552841 | 3 | 0x014 | 9 | 0x1958/0x195c |
| GET_HW_STATUS | 0x8004410a | 2147762442 | 2 | 0x004 | 10 | 0x1894/0x1898 |
| ABORT_CMD_POOL | 0x0000410b | 16651 | 0 | 0x000 | 11 | 0x18ec |
| DISABLE_TICK_COUNTER | 0x0000410c | 16652 | 0 | 0x000 | 12 | 0x18f8 |
| ENABLE_TICK_COUNTER | 0x0000410d | 16653 | 0 | 0x000 | 13 | 0x18dc |
| CONFIG_CLUSTERS | 0x4020410e | 1075855630 | 1 | 0x020 | 14 | 0x23e4/0x23e8 |
| ALLOC_DMA_BUF | 0x8018410f | 2149073167 | 2 | 0x018 | 15 | 0x22dc/0x22e0 |
| FREE_DMA_BUF | 0x40044110 | 1074020624 | 1 | 0x004 | 16 | computed at 0x238c from 0x40044114 - 4 |
| GET_DMA_BUF_INFO | 0xc0204111 | 3223339281 | 3 | 0x020 | 17 | 0x1930/0x1934 |
| GET_DRIVER_VERSION | 0x80084112 | 2148024594 | 2 | 0x008 | 18 | 0x1880/0x1884 |
| ATTACH_DMA_BUF | 0xc0204113 | 3223339283 | 3 | 0x020 | 19 | computed at 0x1c74 from 0xc0204111 + 2 |
| DETACH_DMA_BUF | 0x40044114 | 1074020628 | 1 | 0x004 | 20 | 0x18c8/0x18cc |
| ALLOC_GRID_ID | 0x80044115 | 2147762453 | 2 | 0x004 | 21 | computed at 0x18a4 from 0x8004410a + 0xb |
| ALLOC_GROUP_ID | 0xc0044116 | 3221504278 | 3 | 0x004 | 22 | 0x1b28/0x1b2c |
| FREE_GROUP_ID | 0x40044117 | 1074020631 | 1 | 0x004 | 23 | computed at 0x1a44 from 0x40044114 + 3 |
| GET_CLUSTER_STATUS | 0xc00c4118 | 3222028568 | 3 | 0x00c | 24 | 0x1858/0x185c |
| GET_RUNNING_JOB_THREAD_ID | 0x80804119 | 2155888921 | 2 | 0x080 | 25 | computed at 0x1b3c from 0x80804101 + 0x18 |
| ALLOC_SFLAG_ID | 0xc004411a | 3221504282 | 3 | 0x004 | 26 | computed at 0x223c from 0xc0044116 + 4 |
| FREE_SFLAG_ID | 0x4004411b | 1074020635 | 1 | 0x004 | 27 | 0x1a50/0x1a54 |
| REBIND_DMA_BUF | 0xc018411c | 3222815004 | 3 | 0x018 | 28 | 0x1944/0x1948 |
| BIND_DMA_BUF | 0xc018411d | 3222815005 | 3 | 0x018 | 29 | 0x2450/0x2454 |
| undocumented command | 0x0000411e | 16670 | 0 | 0x000 | 30 | 0x1ac0 |
| undocumented command | 0x0000411f | 16671 | 0 | 0x000 | 31 | 0x1acc |
| BUF_CACHE_INVALID | 0x40284120 | 1076379936 | 1 | 0x028 | 32 | 0x1bcc/0x1bd0 |
| BUF_CACHE_FLUSH | 0x40284121 | 1076379937 | 1 | 0x028 | 33 | 0x1bac/0x1bb0 |

Secondary note: the bundled `aipu-6.0.0` source header defines cache invalid/flush at nr 24/25, colliding with cluster/running-job ioctls, while this KMD binary dispatches cache invalid/flush at nr 32/33. That is another UAPI drift, but it is not the init failure.

### Canonical source handler logic

The supplied `aipu-6.0.0-src.tar.gz` source contains the canonical structure of `aipu_ioctl()`. Relevant lines:

```
aipu-6.0.0/armchina-npu/aipu.c
60  static long aipu_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
68      struct aipu_cap cap;
87      switch (cmd) {
88      case AIPU_IOCTL_QUERY_CAP:
89          ret = aipu_priv_query_capability(aipu, &cap);
90          if (!ret && copy_to_user((struct aipu_cap __user *)arg, &cap, sizeof(cap)))
91              ret = -EINVAL;
92          break;
```

`aipu_priv_query_capability()` has no version field or compatibility check. It fills the struct directly:

```
aipu-6.0.0/armchina-npu/aipu_priv.c
223 int aipu_priv_query_capability(struct aipu_priv *aipu, struct aipu_cap *cap)
228     if (unlikely(!aipu || !cap))
229         return -EINVAL;
231     cap->partition_cnt = aipu_priv_get_partition_cnt(aipu);
232     cap->is_homogeneous = 1;
233     cap->asid_cnt = aipu_mm_get_asid_cnt(&aipu->mm);
235     ins_cap = kcalloc(cap->partition_cnt, sizeof(*ins_cap), GFP_KERNEL);
239     aipu_priv_query_partition_capability(aipu, ins_cap);
249     if (cap->is_homogeneous)
250         cap->partition_cap = ins_cap[0];
252     aipu_mm_get_asid(&aipu->mm, cap);
253     aipu_mm_get_gm(&aipu->mm, cap);
254     cap->dtcm_base = aipu->partitions[0].dtcm_base;
255     cap->dtcm_size = aipu->partitions[0].dtcm_size;
257     kfree(ins_cap);
258     return 0;
```

`partition_cnt` is not read from userspace and is not a register read in the query handler. It is returned from `aipu->partition_cnt`:

```
aipu-6.0.0/armchina-npu/aipu_priv.c
170 int aipu_priv_get_partition_cnt(struct aipu_priv *aipu)
171 {
172     if (likely(aipu))
173         return aipu->partition_cnt;
174     return 0;
175 }
```

For Zhouyi V3, `aipu->partition_cnt` is computed during partition creation from the `cluster-partition` device property, with a default of one cluster, and then stored in the private struct:

```
aipu-6.0.0/armchina-npu/zhouyi/v3_priv.c
107     ret = device_property_count_u32(&p_dev->dev, "cluster-partition");
108     if (ret <= 0) {
109         dev_warn(&p_dev->dev, "use the default config (1 cluster)");
110         ret = 2;
111     }
113     cluster_cnt = ret >> 1;
124     for (iter = 0; iter < cluster_cnt; iter++) {
125         if (cluster_arr[2 * iter + 1] > (partition_cnt - 1))
126             partition_cnt = cluster_arr[2 * iter + 1] + 1;
127     }
146     build_info = aipu_read32(&aipu->reg, TSM_BUILD_INFO_REG);
147     aipu->max_partition_cnt = GET_MAX_PARTITION_NUM(build_info);
148     aipu->max_cmd_pool_cnt = GET_MAX_CMD_POOL_NUM(build_info);
172     aipu->partitions = partitions;
173     aipu->partition_cnt = partition_cnt;
174     aipu->cluster_cnt = cluster_cnt;
```

The probe log fields are printed from those same stored values:

```
aipu-6.0.0/armchina-npu/zhouyi/v3.c
258     dev_info(aipu->dev, "############# ZHOUYI V3 AIPU #############");
259     dev_info(aipu->dev, "# Maximum Partition Count: %d", aipu->max_partition_cnt);
260     dev_info(aipu->dev, "# Maximum Command Pool Count: %d", aipu->max_cmd_pool_cnt);
261     dev_info(aipu->dev, "# Enabled Partition Count: %d", aipu->partition_cnt);
262     dev_info(aipu->dev, "# Enabled Cluster Count: %d", aipu->cluster_cnt);
269     dev_info(aipu->dev, "# Core Count per Cluster: %d", partition->clusters[0].core_cnt);
271     dev_info(aipu->dev, "# TEC Count per Core: %d", partition->clusters[0].tec_cnt);
```

Conclusion for Step 2: there is no query-cap version negotiation and no KMD code path that intentionally reports zero partitions after a clean one-partition probe. The observed failure is the KMD not recognizing the userspace ioctl number.

## Step 3: `struct aipu_cap` layout diff

### Common `struct aipu_partition_cap`

Both header worlds use the same `struct aipu_partition_cap`. The in-tree header in `headers-bundle.tar.gz` shows:

```
home/magnetar/work/kernel-7.0.3/drivers/misc/armchina-npu/include/armchina_aipu.h
105 struct aipu_partition_cap {
106     __u32 id;
107     __u32 arch;
108     __u32 version;
109     __u32 config;
110     struct aipu_debugger_info {
111         __u64 reg_base;
112     } info;
113     __u32 cluster_cnt;
114     struct aipu_cluster_cap {
115         __u32 core_cnt;
116         __u32 en_core_cnt;
117         __u32 tec_cnt;
118     } clusters[8];
119 };
```

Layout on AArch64/Linux UAPI types:

| Field | Offset | Size |
|---|---:|---:|
| id | 0 | 4 |
| arch | 4 | 4 |
| version | 8 | 4 |
| config | 12 | 4 |
| info.reg_base | 16 | 8 |
| cluster_cnt | 24 | 4 |
| clusters[8] | 28 | 96 |
| tail padding | 124 | 4 |
| total | 0 | 128 |

So `AIPU_IOCTL_QUERY_PARTITION_CAP = _IOR('A',1,struct aipu_partition_cap)` is:

```
dir=2, size=0x80, type=0x41, nr=1
0x80804101 = (2 << 30) | (0x80 << 16) | (0x41 << 8) | 1
```

This matches both `libaipu_driver.so` and the KMD.

### Old 424-byte `struct aipu_cap`: headers bundle and loaded KMD

The in-tree kernel-source header in `headers-bundle.tar.gz`:

```
home/magnetar/work/kernel-7.0.3/drivers/misc/armchina-npu/include/armchina_aipu.h
145 struct aipu_cap {
146     __u32 partition_cnt;
147     __u32 asid_cnt;
148     __u64 asid_base[32];
149     __u32 is_homogeneous;
150     __u64 dtcm_base;
151     __u32 dtcm_size;
152     __u32 gm0_size;
153     __u32 gm1_size;
154     struct aipu_partition_cap partition_cap;
155 };
```

The Compass header in `headers-bundle.tar.gz` is identical for this struct:

```
home/magnetar/work/Compass_NPU_Driver/Linux/driver/umd/include/kmd/armchina_aipu.h
145 struct aipu_cap {
146     __u32 partition_cnt;
147     __u32 asid_cnt;
148     __u64 asid_base[32];
149     __u32 is_homogeneous;
150     __u64 dtcm_base;
151     __u32 dtcm_size;
152     __u32 gm0_size;
153     __u32 gm1_size;
154     struct aipu_partition_cap partition_cap;
155 };
```

Old layout:

| Field | Offset | Size |
|---|---:|---:|
| partition_cnt | 0 | 4 |
| asid_cnt | 4 | 4 |
| asid_base[32] | 8 | 256 |
| is_homogeneous | 264 | 4 |
| padding before u64 | 268 | 4 |
| dtcm_base | 272 | 8 |
| dtcm_size | 280 | 4 |
| gm0_size | 284 | 4 |
| gm1_size | 288 | 4 |
| padding before partition_cap | 292 | 4 |
| partition_cap | 296 | 128 |
| total | 0 | 424 |

Resulting ioctl:

```
sizeof(struct aipu_cap) = 424 = 0x1a8
_IOR('A',0,struct aipu_cap)
dir=2, size=0x1a8, type=0x41, nr=0
0x81a84100 = (2 << 30) | (0x1a8 << 16) | (0x41 << 8) | 0
```

This is exactly what the loaded KMD dispatches at VMA `0x1b48`, and exactly the copy size used at VMA `0x1b94`.

### Modern 200-byte `struct aipu_cap`: `aipu-6.0.0-src.tar.gz` and `libaipu_driver.so`

The supplied `aipu-6.0.0-src.tar.gz` header differs only in the ASID array length:

```
aipu-6.0.0/armchina-npu/include/armchina_aipu.h
146 struct aipu_cap {
147     __u32 partition_cnt;
148     __u32 asid_cnt;
149     __u64 asid_base[4];
150     __u32 is_homogeneous;
151     __u64 dtcm_base;
152     __u32 dtcm_size;
153     __u32 gm0_size;
154     __u32 gm1_size;
155     struct aipu_partition_cap partition_cap;
156 };
```

Modern layout:

| Field | Offset | Size |
|---|---:|---:|
| partition_cnt | 0 | 4 |
| asid_cnt | 4 | 4 |
| asid_base[4] | 8 | 32 |
| is_homogeneous | 40 | 4 |
| padding before u64 | 44 | 4 |
| dtcm_base | 48 | 8 |
| dtcm_size | 56 | 4 |
| gm0_size | 60 | 4 |
| gm1_size | 64 | 4 |
| padding before partition_cap | 68 | 4 |
| partition_cap | 72 | 128 |
| total | 0 | 200 |

Resulting ioctl:

```
sizeof(struct aipu_cap) = 200 = 0x0c8
_IOR('A',0,struct aipu_cap)
dir=2, size=0x0c8, type=0x41, nr=0
0x80c84100 = (2 << 30) | (0x0c8 << 16) | (0x41 << 8) | 0
```

This is exactly what `libaipu_driver.so` issues at VMA/file offset `0x41a04`/`0x41a0c`.

### Header macro line evidence

The ioctl macro itself is size-sensitive in all headers:

```
headers-bundle in-tree header:
452 #define AIPU_IOCTL_MAGIC 'A'
462 #define AIPU_IOCTL_QUERY_CAP _IOR(AIPU_IOCTL_MAGIC, 0, struct aipu_cap)

headers-bundle Compass header:
452 #define AIPU_IOCTL_MAGIC 'A'
462 #define AIPU_IOCTL_QUERY_CAP _IOR(AIPU_IOCTL_MAGIC, 0, struct aipu_cap)

aipu-6.0.0 source header:
499 #define AIPU_IOCTL_MAGIC 'A'
509 #define AIPU_IOCTL_QUERY_CAP _IOR(AIPU_IOCTL_MAGIC, 0, struct aipu_cap)
```

Therefore the macro name is the same, but the number changes solely because `sizeof(struct aipu_cap)` changes from `0x1a8` to `0x0c8`.

### Exact mismatch statement

Both sides of the failing mismatch:

```
Userspace side:
  File: /tmp/cix-npu-ioctl-bundle/libaipu_driver.so
  Evidence: VMA/file offset 0x41a04/0x41a0c
  Number: 0x80c84100 decimal 2160607488
  Struct world: aipu-6.0.0/modern, asid_base[4], sizeof(struct aipu_cap)=200

Kernel side:
  File: /tmp/cix-npu-ioctl-bundle/armchina_npu-7.0.3-cix-sky1-next.ko
  Evidence: VMA/file offset 0x1b48/0x1d00 and copy size at VMA 0x1b94
  Number: 0x81a84100 decimal 2175287552
  Struct world: headers-bundle in-tree and Compass, asid_base[32], sizeof(struct aipu_cap)=424
```

The deployed `.ko` does not match the UAPI in the supplied `aipu-6.0.0-src.tar.gz` for `struct aipu_cap`. That tarball says package version 6.0.0:

```
aipu-6.0.0/dkms.conf
1 PACKAGE_NAME="aipu"
2 PACKAGE_VERSION="6.0.0"
5 MAKE[0]="... COMPASS_DRV_BTENVAR_KMD_VERSION=${PACKAGE_VERSION}"
```

But the actual `.ko` contains KMD version string `6.1.1-2` and dispatches the old 424-byte query-cap number. For this failure, the binary evidence is decisive.

## Step 4: fix options ranked

### Rank 1: kernel-side UAPI compatibility fix

Best durable fix: make the KMD accept the modern 200-byte query-cap ioctl and return the modern 200-byte layout, while optionally preserving the old 424-byte ioctl for older userspace.

If only the modern `libaipu_driver.so`/ONNXRuntime stack must be supported, the smallest source-level fix to the old in-tree KMD source is a one-line UAPI layout change:

```
/* old in-tree/Compass header */
__u64 asid_base[32];

/* change to */
__u64 asid_base[4];
```

That changes `AIPU_IOCTL_QUERY_CAP` from `0x81a84100` to `0x80c84100`, changes `copy_to_user(... sizeof(cap))` from 424 to 200, and matches the modern UMD layout. This is the smallest patch, but it intentionally drops old 424-byte userspace compatibility.

Production-compatible KMD patch: keep both numbers and transcode the old internal layout to the modern external layout for `0x80c84100`.

Conceptual patch against the old KMD source:

```
#define AIPU_IOCTL_QUERY_CAP_V6 _IOC(_IOC_READ, AIPU_IOCTL_MAGIC, 0, 0x0c8)

case AIPU_IOCTL_QUERY_CAP:
        ret = aipu_priv_query_capability(aipu, &cap);
        if (!ret && copy_to_user((struct aipu_cap __user *)arg, &cap, sizeof(cap)))
                ret = -EINVAL;
        break;

case AIPU_IOCTL_QUERY_CAP_V6:
        ret = aipu_priv_query_capability(aipu, &cap_old);
        if (!ret) {
                cap_v6.partition_cnt = cap_old.partition_cnt;
                cap_v6.asid_cnt = min_t(__u32, cap_old.asid_cnt, 4);
                memcpy(cap_v6.asid_base, cap_old.asid_base, sizeof(cap_v6.asid_base));
                cap_v6.is_homogeneous = cap_old.is_homogeneous;
                cap_v6.dtcm_base = cap_old.dtcm_base;
                cap_v6.dtcm_size = cap_old.dtcm_size;
                cap_v6.gm0_size = cap_old.gm0_size;
                cap_v6.gm1_size = cap_old.gm1_size;
                cap_v6.partition_cap = cap_old.partition_cap;
                if (copy_to_user((void __user *)arg, &cap_v6, sizeof(cap_v6)))
                        ret = -EINVAL;
        }
        break;
```

A minimal alias-only patch that calls `aipu_priv_query_capability()` and copies the first 200 bytes of the old 424-byte struct is likely enough to make `partition_cnt` nonzero, because `partition_cnt` is at offset 0 in both layouts. It is not correct for fields after `asid_base[4]`, because `is_homogeneous`, `dtcm_base`, GM sizes, and `partition_cap` move from offsets 264/272/280/284/288/296 in the old layout to 40/48/56/60/64/72 in the modern layout. Use explicit transcode for correctness.

If using the supplied `aipu-6.0.0-src.tar.gz` as the rebuild source, note that its header already has `asid_base[4]`; rebuilding that source without reverting the header should naturally produce `0x80c84100`, not the currently loaded `.ko` behavior.

### Rank 2: userspace `LD_PRELOAD` ioctl shim

Best no-kernel-rebuild workaround: intercept `ioctl()` for `/dev/aipu` and translate only query-cap.

Behavior:

```
if request == 0x80c84100:
    allocate old 424-byte aipu_cap_old
    rc = real_ioctl(fd, 0x81a84100, &old)
    if rc == 0:
        transcode old -> modern 200-byte caller buffer
    return rc
else:
    return real_ioctl(fd, request, arg)
```

This avoids the unsafe 424-byte kernel copy into the modern UMD stack buffer. The shim should also verify the fd points at `/dev/aipu` or the AIPU character device before translating, to avoid changing unrelated ioctls with the same numeric value.

Optional secondary translations, if later execution reaches cache maintenance:

```
modern/source duplicate cache values:
  0x40284118 = (1<<30)|(0x28<<16)|(0x41<<8)|24
  0x40284119 = (1<<30)|(0x28<<16)|(0x41<<8)|25

loaded KMD cache values:
  0x40284120 = (1<<30)|(0x28<<16)|(0x41<<8)|32
  0x40284121 = (1<<30)|(0x28<<16)|(0x41<<8)|33
```

I did not observe direct `0x40284118` or `0x40284119` call sites in `libaipu_driver.so`, so query-cap is the required shim for init.

### Rank 3: matching userspace package

The loaded KMD identifies as `6.1.1-2` and dispatches the old 424-byte `struct aipu_cap` ioctl matching the two headers inside `headers-bundle.tar.gz`, not the `aipu-6.0.0` source header and not the provided modern `libaipu_driver.so`.

Seek a userspace backend package built against the 424-byte UAPI:

```
KMD string: 6.1.1-2
Source path in .ko strings: .../linux-cix-sky1-next/7.0.3+sky1-next/kernel-source/.../armchina-npu
Matching header shape: asid_base[32], sizeof(struct aipu_cap)=424
Expected query-cap: 0x81a84100
Likely package family to seek: cix-noe-umd/libaipudrv.so matching KMD 6.1.1-2, not the modern cix-npu-onnxruntime 2.0.0 libaipu_driver.so
```

This is clean if the matching deb exists. It is less flexible than the KMD compat patch because it pins userspace to the old UAPI and may conflict with the ONNXRuntime package that expects the modern backend.

### Rank 4: binary patching `libaipu_driver.so`

There is a trivial binary patch that changes the query-cap immediate from `0x80c84100` to `0x81a84100`, but it is not safe.

Patch location if someone only wants the forensic coordinates:

```
File: /tmp/cix-npu-ioctl-bundle/libaipu_driver.so
Instruction: VMA/file offset 0x41a0c
Current instruction: f2b01901  movk x1, #0x80c8, lsl #16
Current bytes: 01 19 b0 f2
New instruction:     f2b03501  movk x1, #0x81a8, lsl #16
New bytes: 01 35 b0 f2
```

Do not use that one-instruction patch as a fix. `aipudrv::Aipu::init()` allocates a 336-byte stack frame and passes the modern `struct aipu_cap` buffer at `sp+0x88`:

```
libaipu_driver.so, aipudrv::Aipu::init():
   41910: a9ab7bfd  stp x29, x30, [sp, #-336]!
   ...
   41a08: 910223e2  add x2, sp, #0x88
```

The modern 200-byte buffer exactly reaches the end of the frame:

```
0x88 + 0x0c8 = 0x150 = 336
```

If the patched UMD asks the current KMD for `0x81a84100`, the KMD will copy 424 bytes:

```
KMD VMA 0x1b94: mov x2, #0x1a8
```

That would overwrite 224 bytes beyond the UMD stack frame. A binary patch would need a much larger rewrite: grow the stack frame, adjust all stack references, call the old ioctl into a temporary old-layout buffer, and transcode to the modern layout. That is not a reasonable field fix.

## Final diagnosis

The failure is a UAPI ABI mismatch, not an NPU probe/hardware capability failure:

```
Modern UMD:
  struct aipu_cap.asid_base[4]
  sizeof(struct aipu_cap)=200
  AIPU_IOCTL_QUERY_CAP=0x80c84100

Loaded KMD:
  struct aipu_cap.asid_base[32]
  sizeof(struct aipu_cap)=424
  only dispatches AIPU_IOCTL_QUERY_CAP=0x81a84100
```

The KMD probes cleanly and stores a nonzero partition count. `aipu_init_context` fails because the query-cap ioctl number is not recognized by the KMD and returns `-ENOTTY`; the modern UMD then logs `query capability [fail]`, and higher layers can report null-pointer/input errors because context initialization did not complete.

Recommended action: rebuild/replace the KMD so it accepts the modern 200-byte query-cap ioctl and returns the modern layout, or add a temporary `LD_PRELOAD` shim that translates `0x80c84100` to `0x81a84100` with explicit old-to-modern struct transcoding.
