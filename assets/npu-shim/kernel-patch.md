# Kernel Patch: SCHEDULE_JOB r2p1 144-byte compat

Apply to: `drivers/misc/armchina-npu/aipu.c`

Insert BEFORE the `switch (cmd) {` statement (line 83):

```c
	/* r2p1 compat: handle SCHEDULE_JOB 144-byte directly */
	if (_IOC_TYPE(cmd) == AIPU_IOCTL_MAGIC && _IOC_NR(cmd) == 6 && _IOC_SIZE(cmd) == 144) {
		struct aipu_job_desc jd;
		if (!copy_from_user(&jd, (void __user *)arg, sizeof(jd)))
			ret = aipu_job_manager_scheduler(manager, &jd, filp);
		else
			ret = -EINVAL;
		return ret;
	}
```

The SDK adds `is_coredump_en` (4 bytes) at the end of `aipu_job_desc` (144 bytes total).  
The kernel struct is 128 bytes. This bypass truncates via `sizeof(jd)`.

Rebuild:
```bash
cd /usr/src/linux-7.0.9-cix-sky1-next
make -C /lib/modules/7.0.9/build M=$(pwd)/drivers/misc/armchina-npu modules
cp drivers/misc/armchina-npu/armchina_npu.ko /lib/modules/7.0.9/kernel/drivers/misc/armchina-npu/
depmod -a
modprobe -r -f armchina_npu; modprobe armchina_npu
```
