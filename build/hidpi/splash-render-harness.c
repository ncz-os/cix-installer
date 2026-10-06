/* splash-render-harness.c -- render singularity-loginui's boot/session splash
 * frame at a given resolution, write it as PNG and report where the logo and
 * the loading bar landed.
 *
 * It links the REAL loginui sources (image.c, draw.c, render.c, ...) and calls
 * the same two functions the native KMS boot splash calls:
 *   logo = loginui_load_image(path, -1, 256);
 *   loginui_render_splash(cr, mode.hdisplay, mode.vdisplay, NULL, logo, t);
 * so the pixels are the ones the splash would scan out for that mode.
 *
 * usage: splash-render-harness LOGO.png WIDTH HEIGHT OUT.png
 * prints: res=WxH logo_bbox=x0,y0,x1,y1 logo_w_pct=P bar_bbox=x0,y0,x1,y1 \
 *         clipped=0|1 over60=0|1
 * exit:   0 when the logo is fully on screen and at most 60 % of the width,
 *         1 when it is clipped or too wide, 2 on usage/load errors.
 */
#include "loginui.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static int lit(const unsigned char *row, int x) {
    uint32_t px;
    memcpy(&px, row + (size_t)x * 4, sizeof px);  /* no type-punned load */
    /* splash background is opaque black; anything brighter is drawn content */
    return ((px >> 16) & 0xff) > 24 || ((px >> 8) & 0xff) > 24 || (px & 0xff) > 24;
}

static void bbox(cairo_surface_t *s, int y_from, int y_to,
                 int *x0, int *y0, int *x1, int *y1) {
    int w = cairo_image_surface_get_width(s);
    int stride = cairo_image_surface_get_stride(s);
    unsigned char *d = cairo_image_surface_get_data(s);
    *x0 = w; *y0 = y_to; *x1 = -1; *y1 = -1;
    for (int y = y_from; y < y_to; y++) {
        const unsigned char *row = d + (size_t)y * stride;
        for (int x = 0; x < w; x++) {
            if (!lit(row, x)) continue;
            if (x < *x0) *x0 = x;
            if (x > *x1) *x1 = x;
            if (y < *y0) *y0 = y;
            if (y > *y1) *y1 = y;
        }
    }
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s LOGO.png WIDTH HEIGHT OUT.png\n", argv[0]);
        return 2;
    }
    int w = atoi(argv[2]), h = atoi(argv[3]);
    if (w <= 0 || h <= 0) return 2;
    cairo_surface_t *logo = loginui_load_image(argv[1], -1, 256);
    if (!logo) { fprintf(stderr, "cannot load %s\n", argv[1]); return 2; }

    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t *cr = cairo_create(s);
    /* phase 0: the bar's bright segment sits mid-track */
    loginui_render_splash(cr, w, h, NULL, logo, 0.0);
    cairo_destroy(cr);
    cairo_surface_flush(s);

    /* the logo is centred at 0.46 h, the bar at 0.62 h: split at 0.58 h */
    int split = (int)(h * 0.58);
    int lx0, ly0, lx1, ly1, bx0, by0, bx1, by1;
    bbox(s, 0, split, &lx0, &ly0, &lx1, &ly1);
    bbox(s, split, h, &bx0, &by0, &bx1, &by1);
    int lw = lx1 >= lx0 ? lx1 - lx0 + 1 : 0;
    /* Lit pixels in the first or last column (or row of the logo band) mean
     * the logo runs into the frame edge, i.e. it continues past it: the
     * unpatched renderer lights every column from 0 to w-1. A logo that fits
     * always leaves a black margin. No logo at all (lx1 < 0) also fails. */
    int clipped = lx1 < 0 || lx0 <= 0 || lx1 >= w - 1 || ly0 <= 0 || ly1 >= split - 1;
    int over60 = lw > (int)(w * 0.60) + 2;  /* 2 px of antialiased edge */
    printf("res=%dx%d logo_bbox=%d,%d,%d,%d logo_w_pct=%.1f bar_bbox=%d,%d,%d,%d clipped=%d over60=%d\n",
           w, h, lx0, ly0, lx1, ly1, 100.0 * lw / w, bx0, by0, bx1, by1, clipped, over60);

    cairo_status_t st = cairo_surface_write_to_png(s, argv[4]);
    cairo_surface_destroy(s);
    cairo_surface_destroy(logo);
    if (st != CAIRO_STATUS_SUCCESS) return 2;
    return (clipped || over60) ? 1 : 0;
}
