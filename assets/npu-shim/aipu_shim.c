/* aipu_shim.c — LD_PRELOAD bridge for Cix SDK r2p1 ↔ kernel r2p0 ioctl ABI
 *
 * The Cix NOE SDK 26Q1 (r2p1) uses different struct layouts than the
 * in-tree armchina_npu kernel driver (r2p0). This shim intercepts
 * ioctl() calls on /dev/aipu and translates:
 *
 *   QUERY_CAP:  200→424 bytes, field remapping (asid_base[4]→[32])
 *   REQ_BUF:    80→56 bytes, field remapping (added exec_id, shifted align)
 *   SCHEDULE_JOB: handled by kernel patch (144→128 bytes, bypass switch)
 *
 * The SDK r2p1 structs differ from kernel r2p0:
 *   - aipu_cap:          asid_base[4] vs [32] (424→200 byte delta)
 *   - aipu_buf_request:  added exec_id, reserve_iova_size, alloc_mode
 *   - aipu_buf_desc:     added exec_id
 *   - aipu_job_desc:     added is_coredump_en
 *
 * Compile: gcc -shared -fPIC -o aipu_shim.so aipu_shim.c -ldl
 * Use:    LD_PRELOAD=/path/to/aipu_shim.so python3 ...
 *
 * See docs/NPU-SHIM.md for full documentation.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <stdarg.h>
#include <linux/ioctl.h>
#include <sys/syscall.h>
#include <errno.h>

/* Track all /dev/aipu file descriptors */
static int aipu_fds[256] = {0};
static void track(const char *path, int fd) {
    if (fd >= 0 && fd < 256 && path && strstr(path, "/dev/aipu"))
        aipu_fds[fd] = 1;
}

static int needs_open_mode(int flags) {
    if ((flags & O_CREAT)
#ifdef O_TMPFILE
        || ((flags & O_TMPFILE) == O_TMPFILE)
#endif
    )
        return 1;
    return 0;
}

static mode_t get_open_mode(int flags, va_list ap) {
    if (needs_open_mode(flags))
        return va_arg(ap, mode_t);
    return 0;
}

static int (*real_open)(const char *, int, ...);
int open(const char *path, int flags, ...) {
    if (!real_open) real_open = dlsym(RTLD_NEXT, "open");
    va_list ap; va_start(ap, flags);
    mode_t mode = get_open_mode(flags, ap); va_end(ap);
    int fd = needs_open_mode(flags) ? real_open(path, flags, mode) : real_open(path, flags);
    track(path, fd);
    return fd;
}

static int (*real_open64)(const char *, int, ...);
int open64(const char *path, int flags, ...) {
    if (!real_open64) real_open64 = dlsym(RTLD_NEXT, "open64");
    va_list ap; va_start(ap, flags);
    mode_t mode = get_open_mode(flags, ap); va_end(ap);
    int fd = needs_open_mode(flags) ? real_open64(path, flags, mode) : real_open64(path, flags);
    track(path, fd);
    return fd;
}

static int (*real_openat)(int, const char *, int, ...);
int openat(int dirfd, const char *path, int flags, ...) {
    if (!real_openat) real_openat = dlsym(RTLD_NEXT, "openat");
    va_list ap; va_start(ap, flags);
    mode_t mode = get_open_mode(flags, ap); va_end(ap);
    int fd = needs_open_mode(flags) ? real_openat(dirfd, path, flags, mode) : real_openat(dirfd, path, flags);
    track(path, fd);
    return fd;
}

static int (*real_openat64)(int, const char *, int, ...);
int openat64(int dirfd, const char *path, int flags, ...) {
    if (!real_openat64) real_openat64 = dlsym(RTLD_NEXT, "openat64");
    va_list ap; va_start(ap, flags);
    mode_t mode = get_open_mode(flags, ap); va_end(ap);
    int fd = needs_open_mode(flags) ? real_openat64(dirfd, path, flags, mode) : real_openat64(dirfd, path, flags);
    track(path, fd);
    return fd;
}

/* Core ioctl handler */
static int do_aipu_ioctl(int fd, unsigned long req, void *arg) {
    unsigned int nr = _IOC_NR(req), usz = _IOC_SIZE(req);
    unsigned char *u = (unsigned char *)arg;

    /* QUERY_CAP: SDK (200 bytes, asid_base[4]) → kernel (424 bytes, asid_base[32])
     * SDK layout:  pcnt(4) + acnt(4) + asid_base[4](32) + homo(4) + pad(4)
     *              + dtcm_base(8) + dtcm_sz(4) + gm0(4) + gm1(4) + pad(4)
     *              + partition_cap(128) = 200
     * Kern layout: pcnt(4) + acnt(4) + asid_base[32](256) + homo(4)
     *              + dtcm_base(8) + dtcm_sz(4) + gm0(4) + gm1(4)
     *              + partition_cap(132) = 424
     */
    if (nr == 0 && usz == 200) {
        char kbuf[512] = {0};
        long r = syscall(__NR_ioctl, fd, _IOC(2, 65, 0, 424), kbuf);
        if (r == 0) {
            memcpy(u + 0,  kbuf + 0, 8);            /* pcnt + acnt */
            if (*(unsigned *)(u + 4) > 4)
                *(unsigned *)(u + 4) = 4;           /* clamp asid_cnt */
            memcpy(u + 8,  kbuf + 8, 32);           /* asid_base[0..3] */
            *(unsigned *)(u + 40) = *(unsigned *)(kbuf + 264);  /* homo */
            *(unsigned long long *)(u + 48) = *(unsigned long long *)(kbuf + 272);
            *(unsigned *)(u + 56) = *(unsigned *)(kbuf + 280);
            *(unsigned *)(u + 60) = *(unsigned *)(kbuf + 284);  /* gm0 */
            *(unsigned *)(u + 64) = *(unsigned *)(kbuf + 288);  /* gm1 */
            memcpy(u + 72, kbuf + 292, 128);        /* partition_cap */
        }
        return r;
    }

    /* REQ_BUF: SDK (80 bytes) → kernel (56 bytes)
     * SDK:  bytes(8)+exec_id(8)+reserve(8)+align(4)+dtype(4)
     *       +region(1)+asid(1)+amode(1)+pad(5)+desc(40) = 80
     * Kern: bytes(8)+align(4)+dtype(4)+region(1)+asid(1)+pad(6)+desc(28) = 56
     * SDK desc: pa(8)+dev_off(8)+bytes(8)+exec_id(8)+region(1)+asid(1)+pad(6) = 40
     * Kern desc: pa(8)+dev_off(8)+bytes(8)+region(1)+asid(1)+pad(6) = 28
     */
    if (nr == 2 && usz == 80) {
        char kbuf[256] = {0};
        unsigned char *k = (unsigned char *)kbuf;
        *(unsigned long long *)(k + 0) = *(unsigned long long *)(u + 0);    /* bytes */
        unsigned av = *(unsigned *)(u + 24);
        *(unsigned *)(k + 8)  = (av >= 1 && av <= 31) ? (1u << av) : av;  /* align: log2→byte */
        *(unsigned *)(k + 12) = *(unsigned *)(u + 28);  /* data_type */
        k[16] = u[32];   /* region */
        k[17] = u[33];   /* asid */
        /* desc: kernel offset 24, SDK offset 40 */
        *(unsigned long long *)(k + 24) = *(unsigned long long *)(u + 40);
        *(unsigned long long *)(k + 32) = *(unsigned long long *)(u + 48);
        *(unsigned long long *)(k + 40) = *(unsigned long long *)(u + 56);
        k[48] = u[72];   /* desc.region (SDK at 72) */
        k[49] = u[73];   /* desc.asid */
        long r = syscall(__NR_ioctl, fd, _IOC(3, 65, 2, 56), kbuf);
        if (r == 0) {
            *(unsigned long long *)(u + 40) = *(unsigned long long *)(k + 24); /* desc.pa */
            *(unsigned long long *)(u + 48) = *(unsigned long long *)(k + 32); /* desc.dev_offset */
            *(unsigned long long *)(u + 56) = *(unsigned long long *)(k + 40); /* desc.bytes */
            *(unsigned long long *)(u + 64) = 0;  /* exec_id (generated) */
            u[72] = k[48];   /* desc.region */
            u[73] = k[49];   /* desc.asid */
        }
        return r;
    }

    /* SCHEDULE_JOB (144→128) and FREE_BUF (40→32): handled by kernel patch */
    return syscall(__NR_ioctl, fd, req, arg);
}

int ioctl(int fd, unsigned long req, ...) {
    va_list ap; void *arg;
    va_start(ap, req); arg = va_arg(ap, void *); va_end(ap);
    if (fd >= 0 && fd < 256 && aipu_fds[fd] && _IOC_TYPE(req) == 65)
        return do_aipu_ioctl(fd, req, arg);
    return syscall(__NR_ioctl, fd, req, arg);
}
