// Replays Chrome's VASupportedProfiles::FillProfileInfo_Locked sequence against
// the installed CIX VA driver, to find which step Chrome bails on.
// Chrome differs from ffmpeg in that it passes VAConfigAttribRTFormat to
// vaCreateConfig and validates the mask returned by vaGetConfigAttributes.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_str.h>
#include <va/va_drm.h>

static const char *rtfmt(unsigned int v) {
    static char b[256];
    b[0] = 0;
    if (v & VA_RT_FORMAT_YUV420)    strcat(b, "YUV420 ");
    if (v & VA_RT_FORMAT_YUV422)    strcat(b, "YUV422 ");
    if (v & VA_RT_FORMAT_YUV444)    strcat(b, "YUV444 ");
    if (v & VA_RT_FORMAT_YUV420_10) strcat(b, "YUV420_10 ");
    if (v & VA_RT_FORMAT_RGB32)     strcat(b, "RGB32 ");
    if (!b[0]) strcat(b, "(none)");
    return b;
}

static const char *attrname(VASurfaceAttribType t) {
    switch (t) {
    case VASurfaceAttribPixelFormat: return "PixelFormat";
    case VASurfaceAttribMinWidth:    return "MinWidth";
    case VASurfaceAttribMaxWidth:    return "MaxWidth";
    case VASurfaceAttribMinHeight:   return "MinHeight";
    case VASurfaceAttribMaxHeight:   return "MaxHeight";
    case VASurfaceAttribMemoryType:  return "MemoryType";
    default: return "other";
    }
}

int main(int argc, char **argv) {
    const char *node = (argc > 1) ? argv[1] : "/dev/dri/renderD129";
    int fd = open(node, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    VADisplay dpy = vaGetDisplayDRM(fd);
    int maj, min;
    VAStatus st = vaInitialize(dpy, &maj, &min);
    if (st != VA_STATUS_SUCCESS) { printf("vaInitialize FAILED: %s\n", vaErrorStr(st)); return 1; }
    printf("node=%s  VA-API %d.%d  driver=%s\n\n", node, maj, min, vaQueryVendorString(dpy));

    VAProfile probe[] = { VAProfileH264ConstrainedBaseline, VAProfileH264Main,
                          VAProfileH264High, VAProfileHEVCMain, VAProfileVP9Profile0,
                          VAProfileAV1Profile0, VAProfileNone };
    VAEntrypoint eps[] = { VAEntrypointVLD, VAEntrypointVideoProc };

    for (unsigned p = 0; p < sizeof(probe)/sizeof(probe[0]); p++) {
        for (unsigned e = 0; e < sizeof(eps)/sizeof(eps[0]); e++) {
            VAProfile prof = probe[p];
            VAEntrypoint ep = eps[e];
            // VideoProc pairs with VAProfileNone; VLD with real profiles.
            if ((prof == VAProfileNone) != (ep == VAEntrypointVideoProc)) continue;

            printf("=== %s / %s\n", vaProfileStr(prof), vaEntrypointStr(ep));

            // STEP 1: Chrome's AreAttribsSupported_Locked - query RTFormat mask.
            VAConfigAttrib got = { .type = VAConfigAttribRTFormat, .value = 0 };
            st = vaGetConfigAttributes(dpy, prof, ep, &got, 1);
            if (st != VA_STATUS_SUCCESS) {
                printf("  vaGetConfigAttributes FAILED: %s\n\n", vaErrorStr(st));
                continue;
            }
            printf("  RTFormat mask = 0x%08x  [%s]\n", got.value, rtfmt(got.value));
            if (got.value == VA_ATTRIB_NOT_SUPPORTED) {
                printf("  ** VA_ATTRIB_NOT_SUPPORTED -> Chrome AreAttribsSupported would FAIL\n\n");
                continue;
            }
            unsigned int want = (prof == VAProfileNone) ? VA_RT_FORMAT_RGB32 : VA_RT_FORMAT_YUV420;
            printf("  Chrome requires 0x%08x [%s] -> %s\n", want, rtfmt(want),
                   ((got.value & want) == want) ? "SATISFIED" : "** NOT SATISFIED (Chrome returns false) **");

            // STEP 2: vaCreateConfig WITH the required attrib, as Chrome does.
            VAConfigAttrib req = { .type = VAConfigAttribRTFormat, .value = VA_RT_FORMAT_YUV420 };
            VAConfigID cfg = VA_INVALID_ID;
            st = vaCreateConfig(dpy, prof, ep, &req, 1, &cfg);
            if (st != VA_STATUS_SUCCESS) {
                printf("  vaCreateConfig(with RTFormat) FAILED: %s\n\n", vaErrorStr(st));
                continue;
            }
            printf("  vaCreateConfig(with RTFormat) ok, cfg=%d\n", cfg);

            // STEP 3: two-pass vaQuerySurfaceAttributes, exactly as Chrome does.
            unsigned int n = 0;
            st = vaQuerySurfaceAttributes(dpy, cfg, NULL, &n);
            printf("  pass1: st=%s num_attribs=%u\n", vaErrorStr(st), n);
            if (st != VA_STATUS_SUCCESS || n == 0) {
                printf("  ** Chrome returns false here (!num_attribs)\n\n");
                vaDestroyConfig(dpy, cfg); continue;
            }
            VASurfaceAttrib *list = calloc(n, sizeof(*list));
            st = vaQuerySurfaceAttributes(dpy, cfg, list, &n);
            printf("  pass2: st=%s num_attribs=%u\n", vaErrorStr(st), n);

            int haveMinW = 0, haveMaxW = 0, haveMinH = 0, haveMaxH = 0;
            for (unsigned i = 0; i < n; i++) {
                printf("    [%u] type=%d %-12s flags=%d value=0x%08x\n",
                       i, list[i].type, attrname(list[i].type),
                       list[i].flags, list[i].value.value.i);
                if (list[i].type == VASurfaceAttribMinWidth)  haveMinW = 1;
                if (list[i].type == VASurfaceAttribMaxWidth)  haveMaxW = 1;
                if (list[i].type == VASurfaceAttribMinHeight) haveMinH = 1;
                if (list[i].type == VASurfaceAttribMaxHeight) haveMaxH = 1;
            }
            printf("  resolution attribs: MinW=%d MaxW=%d MinH=%d MaxH=%d -> %s\n\n",
                   haveMinW, haveMaxW, haveMinH, haveMaxH,
                   (haveMinW && haveMaxW && haveMinH && haveMaxH) ? "COMPLETE" : "** INCOMPLETE **");
            free(list);
            vaDestroyConfig(dpy, cfg);
        }
    }
    vaTerminate(dpy);
    close(fd);
    return 0;
}
