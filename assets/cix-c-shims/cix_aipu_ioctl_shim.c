/*
 * cix_aipu_ioctl_shim.c - LD_PRELOAD shim translating modern UMD's
 * AIPU_IOCTL_QUERY_CAP (0x80c84100, sizeof aipu_cap = 200) to the loaded
 * KMD's older variant (0x81a84100, sizeof aipu_cap = 424), with explicit
 * struct transcoding.
 *
 * Diagnosis: see CODEX-ANALYSIS.md in this bundle.
 *
 * Build:
 *   gcc -shared -fPIC -O2 -Wall -o libcix_aipu_shim.so cix_aipu_ioctl_shim.c -ldl
 *
 * Usage:
 *   LD_LIBRARY_PATH=/usr/share/cix/lib/onnxruntime \
 *   LD_PRELOAD=/path/to/libcix_aipu_shim.so \
 *       <python or other consumer of libaipu_driver.so>
 *
 * Only translates query-cap on /dev/aipu fds. Forwards everything else.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

/* Modern UMD's value: dir=2, size=0x0c8, type='A', nr=0  -> 200 bytes */
#define AIPU_QUERY_CAP_NEW  0x80c84100u
/* Loaded KMD's value:    dir=2, size=0x1a8, type='A', nr=0  -> 424 bytes */
#define AIPU_QUERY_CAP_OLD  0x81a84100u

#define AIPU_DEV_PATH       "/dev/aipu"

/* aipu_partition_cap is identical in both layouts (128 bytes) */
struct aipu_partition_cap {
    uint32_t id;
    uint32_t arch;
    uint32_t version;
    uint32_t config;
    struct {
        uint64_t reg_base;
    } info;
    uint32_t cluster_cnt;
    struct {
        uint32_t core_cnt;
        uint32_t en_core_cnt;
        uint32_t tec_cnt;
    } clusters[8];
};

/* Old layout = what the loaded KMD writes (424 bytes total) */
struct aipu_cap_old {
    uint32_t partition_cnt;          /* +0   */
    uint32_t asid_cnt;               /* +4   */
    uint64_t asid_base[32];          /* +8   */
    uint32_t is_homogeneous;         /* +264 */
    uint32_t _pad0;                  /* +268 */
    uint64_t dtcm_base;              /* +272 */
    uint32_t dtcm_size;              /* +280 */
    uint32_t gm0_size;               /* +284 */
    uint32_t gm1_size;               /* +288 */
    uint32_t _pad1;                  /* +292 */
    struct aipu_partition_cap partition_cap; /* +296 .. +424 */
};

/* New layout = what the modern UMD allocates (200 bytes total) */
struct aipu_cap_new {
    uint32_t partition_cnt;          /* +0   */
    uint32_t asid_cnt;               /* +4   */
    uint64_t asid_base[4];           /* +8   */
    uint32_t is_homogeneous;         /* +40  */
    uint32_t _pad0;                  /* +44  */
    uint64_t dtcm_base;              /* +48  */
    uint32_t dtcm_size;              /* +56  */
    uint32_t gm0_size;               /* +60  */
    uint32_t gm1_size;               /* +64  */
    uint32_t _pad1;                  /* +68  */
    struct aipu_partition_cap partition_cap; /* +72 .. +200 */
};

static int (*real_ioctl)(int, unsigned long, ...) = NULL;

static int fd_is_aipu(int fd) {
    static int aipu_dev_major = -1;
    static int aipu_dev_minor = -1;
    if (aipu_dev_major < 0) {
        struct stat st;
        if (stat(AIPU_DEV_PATH, &st) == 0) {
            aipu_dev_major = (int)((st.st_rdev >> 8) & 0xff);
            aipu_dev_minor = (int)(st.st_rdev & 0xff);
        }
    }
    if (aipu_dev_major < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0) return 0;
    if ((st.st_mode & S_IFMT) != S_IFCHR) return 0;
    return ((int)((st.st_rdev >> 8) & 0xff)) == aipu_dev_major
        && ((int)(st.st_rdev & 0xff)) == aipu_dev_minor;
}

int ioctl(int fd, unsigned long request, ...) {
    if (!real_ioctl) {
        real_ioctl = dlsym(RTLD_NEXT, "ioctl");
        if (!real_ioctl) {
            errno = ENOSYS;
            return -1;
        }
    }

    va_list ap;
    va_start(ap, request);
    void *arg = va_arg(ap, void *);
    va_end(ap);

    if ((unsigned int)request == AIPU_QUERY_CAP_NEW && fd_is_aipu(fd)) {
        /* Allocate the larger buffer the KMD will write.  We keep this on
         * the stack so the caller never sees the extra bytes. */
        struct aipu_cap_old old;
        memset(&old, 0, sizeof(old));
        int rc = real_ioctl(fd, (unsigned long)AIPU_QUERY_CAP_OLD, &old);
        if (rc != 0) return rc;

        struct aipu_cap_new *out = (struct aipu_cap_new *)arg;
        memset(out, 0, sizeof(*out));
        out->partition_cnt   = old.partition_cnt;
        out->asid_cnt        = old.asid_cnt < 4 ? old.asid_cnt : 4;
        for (uint32_t i = 0; i < out->asid_cnt; i++) {
            out->asid_base[i] = old.asid_base[i];
        }
        out->is_homogeneous  = old.is_homogeneous;
        out->dtcm_base       = old.dtcm_base;
        out->dtcm_size       = old.dtcm_size;
        out->gm0_size        = old.gm0_size;
        out->gm1_size        = old.gm1_size;
        out->partition_cap   = old.partition_cap;

        /* Banner once for visibility */
        static int announced = 0;
        if (!announced) {
            fprintf(stderr, "[cix_aipu_shim] translated QUERY_CAP 0x%08x -> 0x%08x; "
                            "partition_cnt=%u, asid_cnt=%u, is_homogeneous=%u\n",
                    AIPU_QUERY_CAP_NEW, AIPU_QUERY_CAP_OLD,
                    out->partition_cnt, out->asid_cnt, out->is_homogeneous);
            announced = 1;
        }
        return 0;
    }

    return real_ioctl(fd, request, arg);
}
