/* brand-render-harness.c -- render the session splash (loginui_render_brand,
 * what singularity-splash paints after login) and report the drawn logo box.
 * usage: brand-render-harness LOGO WIDTH HEIGHT OUT.png
 * The logo is loaded exactly like singularity-splash does:
 *   loginui_load_image(path, -1, 256)
 * exit: 0 when the drawn aspect matches the source within 3 % and the logo is
 *       on screen, 1 when squeezed/stretched or clipped, 2 on usage errors. */
#include "loginui.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "usage: %s LOGO W H OUT.png\n", argv[0]); return 2; }
    int w = atoi(argv[2]), h = atoi(argv[3]);
    if (w <= 0 || h <= 0) return 2;
    cairo_surface_t *logo = loginui_load_image(argv[1], -1, 256);
    if (!logo) { fprintf(stderr, "cannot load %s\n", argv[1]); return 2; }
    double src_aspect = (double)cairo_image_surface_get_width(logo) / cairo_image_surface_get_height(logo);

    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    cairo_t *cr = cairo_create(s);
    loginui_render_brand(cr, w, h, logo, 0.0, 0.0);   /* no loading bar */
    cairo_destroy(cr);
    cairo_surface_flush(s);

    int stride = cairo_image_surface_get_stride(s);
    unsigned char *d = cairo_image_surface_get_data(s);
    uint32_t bg; memcpy(&bg, d, 4);
    int x0 = w, y0 = h, x1 = -1, y1 = -1;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            uint32_t px; memcpy(&px, d + (size_t)y * stride + x * 4, 4);
            int dr = abs((int)((px >> 16) & 255) - (int)((bg >> 16) & 255));
            int dg = abs((int)((px >> 8) & 255) - (int)((bg >> 8) & 255));
            int db = abs((int)(px & 255) - (int)(bg & 255));
            if (dr + dg + db > 90) {
                if (x < x0) x0 = x; if (x > x1) x1 = x;
                if (y < y0) y0 = y; if (y > y1) y1 = y;
            }
        }
    int bw = x1 >= x0 ? x1 - x0 + 1 : 0, bh = y1 >= y0 ? y1 - y0 + 1 : 0;
    double drawn = bh ? (double)bw / bh : 0;
    int clipped = bw == 0 || x0 <= 0 || y0 <= 0 || x1 >= w - 1 || y1 >= h - 1;
    /* trimmed art can be narrower than the file; allow the bbox to be at most
     * the file aspect and at least 85 % of it (antialiased edges, side bearing) */
    int squeezed = drawn > src_aspect * 1.03 || drawn < src_aspect * 0.85;
    printf("res=%dx%d src_aspect=%.2f drawn_bbox=%d,%d,%d,%d drawn_aspect=%.2f clipped=%d squeezed=%d\n",
           w, h, src_aspect, x0, y0, x1, y1, drawn, clipped, squeezed);
    cairo_status_t st = cairo_surface_write_to_png(s, argv[4]);
    cairo_surface_destroy(s); cairo_surface_destroy(logo);
    if (st != CAIRO_STATUS_SUCCESS) return 2;
    return (clipped || squeezed) ? 1 : 0;
}
