#ifndef TOKENCLOCK_GTK_SHIM_H
#define TOKENCLOCK_GTK_SHIM_H

#include <gtk/gtk.h>
#include <math.h>

typedef void (*TCGtkVoidCallback)(GtkWidget *, gpointer);
typedef gboolean (*TCGtkTimerCallback)(gpointer);
typedef gboolean (*TCGtkDrawCallback)(GtkWidget *, cairo_t *, gpointer);
typedef gboolean (*TCGtkButtonCallback)(GtkWidget *, GdkEventButton *, gpointer);

static inline GtkWindow *tc_gtk_window(GtkWidget *widget) {
    return GTK_WINDOW(widget);
}

static inline GtkContainer *tc_gtk_container(GtkWidget *widget) {
    return GTK_CONTAINER(widget);
}

static inline GtkBox *tc_gtk_box(GtkWidget *widget) {
    return GTK_BOX(widget);
}

static inline GtkLabel *tc_gtk_label(GtkWidget *widget) {
    return GTK_LABEL(widget);
}

static inline GtkCssProvider *tc_gtk_css_provider(GtkWidget *widget) {
    return GTK_CSS_PROVIDER(widget);
}

static inline void tc_gtk_add_class(GtkWidget *widget, const char *class_name) {
    gtk_style_context_add_class(gtk_widget_get_style_context(widget), class_name);
}

static inline gulong tc_gtk_on_destroy(
    GtkWidget *widget, TCGtkVoidCallback callback, gpointer data
) {
    return g_signal_connect(widget, "destroy", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_on_draw(
    GtkWidget *widget, TCGtkDrawCallback callback, gpointer data
) {
    return g_signal_connect(widget, "draw", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_on_button_press(
    GtkWidget *widget, TCGtkButtonCallback callback, gpointer data
) {
    return g_signal_connect(widget, "button-press-event", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_on_clicked(
    GtkWidget *widget, TCGtkVoidCallback callback, gpointer data
) {
    return g_signal_connect(widget, "clicked", G_CALLBACK(callback), data);
}

static inline guint tc_gtk_timeout_add_seconds(
    guint seconds, TCGtkTimerCallback callback, gpointer data
) {
    return g_timeout_add_seconds(seconds, callback, data);
}

static inline guint tc_gtk_timeout_add(
    guint milliseconds, TCGtkTimerCallback callback, gpointer data
) {
    return g_timeout_add(milliseconds, callback, data);
}

static inline guint tc_gtk_idle_add(TCGtkTimerCallback callback, gpointer data) {
    return g_idle_add(callback, data);
}

static inline void tc_gtk_begin_move(
    GtkWidget *widget, GdkEventButton *event
) {
    gtk_window_begin_move_drag(
        GTK_WINDOW(widget),
        (gint)event->button,
        (gint)event->x_root,
        (gint)event->y_root,
        event->time
    );
}

static inline guint tc_gtk_event_button(GdkEventButton *event) {
    return event->button;
}

static inline void tc_gtk_apply_css(const char *css) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, css, -1, NULL);
    GdkScreen *screen = gdk_screen_get_default();
    if (screen != NULL) {
        gtk_style_context_add_provider_for_screen(
            screen,
            GTK_STYLE_PROVIDER(provider),
            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
    g_object_unref(provider);
}

static inline void tc_cairo_set_source_rgba(
    cairo_t *context, double r, double g, double b, double a
) {
    cairo_set_source_rgba(context, r, g, b, a);
}

#endif
