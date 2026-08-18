// Tests the FINAL block of Chrome's FillProfileInfo_Locked (Chrome 151,
// media/gpu/vaapi/vaapi_wrapper.cc:1508-1445): create a config with NO
// attributes, then vaQueryConfigAttributes, and require at least one of
// YUV420 / YUV420_10 / YUV422 / YUV444 in VAConfigAttribRTFormat.
// If none are present Chrome returns false via DLOG_IF, which is compiled out
// in release builds -> silent failure.
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_str.h>
#include <va/va_drm.h>

int main(int argc, char **argv) {
    const char *node = (argc > 1) ? argv[1] : "/dev/dri/renderD129";
    int fd = open(node, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }
    VADisplay dpy = vaGetDisplayDRM(fd);
    int maj, min;
    if (vaInitialize(dpy, &maj, &min) != VA_STATUS_SUCCESS) { printf("init failed\n"); return 1; }

    int maxattr = vaMaxNumConfigAttributes(dpy);
    printf("node=%s driver=%s vaMaxNumConfigAttributes=%d\n\n", node, vaQueryVendorString(dpy), maxattr);

    VAProfile probe[] = { VAProfileH264ConstrainedBaseline, VAProfileH264Main,
                          VAProfileH264High, VAProfileHEVCMain, VAProfileVP9Profile0,
                          VAProfileAV1Profile0, VAProfileNone };
    for (unsigned p = 0; p < sizeof(probe)/sizeof(probe[0]); p++) {
        VAProfile prof = probe[p];
        VAEntrypoint ep = (prof == VAProfileNone) ? VAEntrypointVideoProc : VAEntrypointVLD;
        printf("=== %s / %s\n", vaProfileStr(prof), vaEntrypointStr(ep));

        // Chrome: vaCreateConfig(..., nullptr, 0, &cfg)  <-- no required attribs
        VAConfigID cfg = VA_INVALID_ID;
        VAStatus st = vaCreateConfig(dpy, prof, ep, NULL, 0, &cfg);
        if (st != VA_STATUS_SUCCESS) { printf("  vaCreateConfig(nullptr,0) FAILED: %s\n\n", vaErrorStr(st)); continue; }

        VAConfigAttrib *attrs = calloc(maxattr > 0 ? maxattr : 32, sizeof(*attrs));
        int n = 0;
        VAProfile qp = prof; VAEntrypoint qe = ep;
        st = vaQueryConfigAttributes(dpy, cfg, &qp, &qe, attrs, &n);
        if (st != VA_STATUS_SUCCESS) {
            printf("  vaQueryConfigAttributes FAILED: %s\n\n", vaErrorStr(st));
            free(attrs); vaDestroyConfig(dpy, cfg); continue;
        }
        printf("  vaQueryConfigAttributes ok, num_config_attributes=%d\n", n);

        int sawRT = 0; unsigned int rtval = 0;
        for (int i = 0; i < n; i++) {
            printf("    attrib[%d] type=%d value=0x%08x%s\n", i, attrs[i].type, attrs[i].value,
                   attrs[i].type == VAConfigAttribRTFormat ? "   <-- VAConfigAttribRTFormat" : "");
            if (attrs[i].type == VAConfigAttribRTFormat) { sawRT = 1; rtval = attrs[i].value; }
        }
        if (!sawRT) {
            printf("  ** NO VAConfigAttribRTFormat reported -> Chrome: is_any_profile_supported=false -> RETURNS FALSE (silently)\n\n");
        } else {
            int y420  = !!(rtval & VA_RT_FORMAT_YUV420);
            int y1010 = !!(rtval & VA_RT_FORMAT_YUV420_10);
            int y422  = !!(rtval & VA_RT_FORMAT_YUV422);
            int y444  = !!(rtval & VA_RT_FORMAT_YUV444);
            printf("  RTFormat=0x%08x yuv420=%d yuv420_10=%d yuv422=%d yuv444=%d -> Chrome %s\n\n",
                   rtval, y420, y1010, y422, y444,
                   (y420||y1010||y422||y444) ? "SUCCEEDS" : "** RETURNS FALSE (silently) **");
        }
        free(attrs);
        vaDestroyConfig(dpy, cfg);
    }
    vaTerminate(dpy);
    close(fd);
    return 0;
}
