/*
 * gtk-repro.c -- pure GTK4, no layer shell.
 *
 * Cycles two toplevel windows hidden/shown. The hide is dispatched from a
 * G_PRIORITY_HIGH idle scheduled inside the frame-clock tick, AFTER
 * gtk_widget_queue_draw() -- so a paint is already in flight when the unmap
 * happens. That stands in for a real close animation.
 *
 * On the GL/GLES renderer the queued frame lands after GTK's clean
 * attach(nil) unmap, leaving a live buffer attached to a wl_surface that GTK
 * then reuses for the next xdg_surface:
 *
 *   xdg_wm_base#N: error 3: xdg_surface must not have a buffer at creation
 *
 * On the default Vulkan renderer the same binary runs clean.
 *
 * Build:
 *   cc -o gtk-repro gtk-repro.c $(pkg-config --cflags --libs gtk4)
 * Run:
 *   GSK_RENDERER=ngl ./gtk-repro     # fails
 *   ./gtk-repro                      # default (vulkan): clean
 */
#include <gtk/gtk.h>

#define N_WINDOWS 2
#define MAX_CYCLES 120

typedef struct { GtkWindow *win; GtkWidget *area; guint cycles; } LWin;

static LWin wins[N_WINDOWS];
static GMainLoop *loop;
static guint finished;

static gboolean hide_idle(gpointer data) {
    LWin *lw = data;
    /* Unmap now: a paint for this surface has already been queued, so its
     * buffer can land after the unmap's attach(nil) and remain current when
     * the next xdg_surface is created over the same wl_surface. */
    gtk_widget_set_visible(GTK_WIDGET(lw->win), FALSE);
    if (++lw->cycles >= MAX_CYCLES && ++finished >= N_WINDOWS)
        g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

static gboolean tick_cb(GtkWidget *w, GdkFrameClock *clock, gpointer data) {
    LWin *lw = data;
    (void) clock;
    if (!gtk_widget_get_visible(GTK_WIDGET(lw->win)))
        return G_SOURCE_CONTINUE;
    gtk_widget_queue_draw(w);                                /* queue a paint ... */
    g_idle_add_full(G_PRIORITY_HIGH, hide_idle, lw, NULL);   /* ... then unmap  */
    return G_SOURCE_CONTINUE;
}

static gboolean reopen(gpointer data) {
    LWin *lw = data;
    if (!gtk_widget_get_visible(GTK_WIDGET(lw->win)) && lw->cycles < MAX_CYCLES)
        gtk_widget_set_visible(GTK_WIDGET(lw->win), TRUE);
    return G_SOURCE_CONTINUE;
}

static void build(LWin *lw, int i) {
    lw->win = GTK_WINDOW(gtk_window_new());
    gtk_window_set_title(lw->win, "xdgrepro");
    gtk_window_set_default_size(lw->win, 320, 200);

    lw->area = gtk_drawing_area_new();
    gtk_widget_set_size_request(lw->area, 320, 200);
    gtk_window_set_child(lw->win, lw->area);
    gtk_widget_add_tick_callback(lw->area, tick_cb, lw, NULL);

    gtk_widget_set_visible(GTK_WIDGET(lw->win), TRUE);
    g_timeout_add(30 + i * 7, reopen, lw);
}

int main(void) {
    gtk_init();
    for (int i = 0; i < N_WINDOWS; i++)
        build(&wins[i], i);
    loop = g_main_loop_new(NULL, FALSE);
    g_main_loop_run(loop);
    g_print("completed %d cycles per window with no protocol error\n", MAX_CYCLES);
    return 0;
}
