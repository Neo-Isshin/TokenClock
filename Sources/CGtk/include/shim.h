#ifndef TOKENCLOCK_GTK_SHIM_H
#define TOKENCLOCK_GTK_SHIM_H

#include <gtk/gtk.h>
#include <math.h>

typedef void (*TCGtkVoidCallback)(GtkWidget *, gpointer);
typedef gboolean (*TCGtkTimerCallback)(gpointer);
typedef gboolean (*TCGtkDrawCallback)(GtkWidget *, cairo_t *, gpointer);
typedef gboolean (*TCGtkButtonCallback)(GtkWidget *, GdkEventButton *, gpointer);
typedef gboolean (*TCGtkMotionCallback)(GtkWidget *, GdkEventMotion *, gpointer);

static inline GtkGrid *tc_gtk_grid(GtkWidget *widget) { return GTK_GRID(widget); }

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

static inline GtkButton *tc_gtk_button(GtkWidget *widget) {
    return GTK_BUTTON(widget);
}

static inline GtkScrolledWindow *tc_gtk_scrolled_window(GtkWidget *widget) {
    return GTK_SCROLLED_WINDOW(widget);
}

static inline GtkProgressBar *tc_gtk_progress_bar(GtkWidget *widget) {
    return GTK_PROGRESS_BAR(widget);
}

static inline GtkRevealer *tc_gtk_revealer(GtkWidget *widget) {
    return GTK_REVEALER(widget);
}

static inline GtkEntry *tc_gtk_entry(GtkWidget *widget) {
    return GTK_ENTRY(widget);
}

static inline GtkToggleButton *tc_gtk_toggle_button(GtkWidget *widget) {
    return GTK_TOGGLE_BUTTON(widget);
}

static inline GtkSpinButton *tc_gtk_spin_button(GtkWidget *widget) {
    return GTK_SPIN_BUTTON(widget);
}

static inline GtkNotebook *tc_gtk_notebook(GtkWidget *widget) {
    return GTK_NOTEBOOK(widget);
}

static inline GtkMenuShell *tc_gtk_menu_shell(GtkWidget *widget) {
    return GTK_MENU_SHELL(widget);
}

static inline GtkMenuItem *tc_gtk_menu_item(GtkWidget *widget) {
    return GTK_MENU_ITEM(widget);
}

static inline GtkCssProvider *tc_gtk_css_provider(GtkWidget *widget) {
    return GTK_CSS_PROVIDER(widget);
}

static inline void tc_gtk_add_class(GtkWidget *widget, const char *class_name) {
    gtk_style_context_add_class(gtk_widget_get_style_context(widget), class_name);
}

static inline void tc_gtk_remove_class(GtkWidget *widget, const char *class_name) {
    gtk_style_context_remove_class(gtk_widget_get_style_context(widget), class_name);
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

static inline gulong tc_gtk_on_button_release(
    GtkWidget *widget, TCGtkButtonCallback callback, gpointer data
) {
    return g_signal_connect(widget, "button-release-event", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_on_motion(
    GtkWidget *widget, TCGtkMotionCallback callback, gpointer data
) {
    return g_signal_connect(widget, "motion-notify-event", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_on_clicked(
    GtkWidget *widget, TCGtkVoidCallback callback, gpointer data
) {
    return g_signal_connect(widget, "clicked", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_on_activate(
    GtkWidget *widget, TCGtkVoidCallback callback, gpointer data
) {
    return g_signal_connect(widget, "activate", G_CALLBACK(callback), data);
}

static inline gulong tc_gtk_hide_on_delete(GtkWidget *widget) {
    return g_signal_connect(widget, "delete-event", G_CALLBACK(gtk_widget_hide_on_delete), NULL);
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

static inline void tc_gtk_begin_move_at(
    GtkWidget *widget, guint button, double root_x, double root_y, guint32 time
) {
    gtk_window_begin_move_drag(
        GTK_WINDOW(widget), (gint)button, (gint)root_x, (gint)root_y, time
    );
}

static inline double tc_gtk_button_root_x(GdkEventButton *event) { return event->x_root; }
static inline double tc_gtk_button_root_y(GdkEventButton *event) { return event->y_root; }
static inline guint32 tc_gtk_button_time(GdkEventButton *event) { return event->time; }
static inline double tc_gtk_motion_root_x(GdkEventMotion *event) { return event->x_root; }
static inline double tc_gtk_motion_root_y(GdkEventMotion *event) { return event->y_root; }
static inline guint32 tc_gtk_motion_time(GdkEventMotion *event) { return event->time; }
static inline guint tc_gtk_motion_state(GdkEventMotion *event) { return event->state; }

static inline void tc_gtk_prepare_transparent_window(GtkWidget *widget) {
    GdkScreen *screen = gtk_widget_get_screen(widget);
    GdkVisual *visual = screen != NULL ? gdk_screen_get_rgba_visual(screen) : NULL;
    if (visual != NULL) {
        gtk_widget_set_visual(widget, visual);
    }
    gtk_widget_set_app_paintable(widget, TRUE);
}

static inline void tc_gtk_set_fixed_window_size(GtkWidget *widget, gint size) {
    GdkGeometry geometry = {0};
    geometry.min_width = size;
    geometry.min_height = size;
    geometry.max_width = size;
    geometry.max_height = size;
    gtk_window_set_geometry_hints(
        GTK_WINDOW(widget), widget, &geometry,
        GDK_HINT_MIN_SIZE | GDK_HINT_MAX_SIZE
    );
    gtk_widget_set_size_request(widget, size, size);
    gtk_window_resize(GTK_WINDOW(widget), size, size);
    gtk_widget_queue_resize(widget);
}

static inline gint tc_gtk_primary_workarea_height(void) {
    GdkDisplay *display = gdk_display_get_default();
    if (display == NULL) return 900;
    GdkMonitor *monitor = gdk_display_get_primary_monitor(display);
    if (monitor == NULL) monitor = gdk_display_get_monitor(display, 0);
    if (monitor == NULL) return 900;
    GdkRectangle workarea;
    gdk_monitor_get_workarea(monitor, &workarea);
    return workarea.height;
}

// Give both the visible X11 window and its input region a true circular shape.
// Alpha compositors still use the RGBA buffer; this is the fallback that keeps
// non-composited/XQuartz desktops from showing or intercepting a square frame.
static inline void tc_gtk_shape_circle(GtkWidget *widget, gint diameter) {
    GdkWindow *window = gtk_widget_get_window(widget);
    if (window == NULL || diameter <= 0) return;

    cairo_region_t *region = cairo_region_create();
    const double radius = (double)diameter / 2.0;
    for (gint y = 0; y < diameter; y++) {
        const double dy = ((double)y + 0.5) - radius;
        const double half = sqrt(fmax(0.0, radius * radius - dy * dy));
        const gint x = (gint)floor(radius - half);
        const gint width = (gint)ceil(half * 2.0);
        cairo_rectangle_int_t row = { x, y, width, 1 };
        cairo_region_union_rectangle(region, &row);
    }
    gdk_window_shape_combine_region(window, region, 0, 0);
    gdk_window_input_shape_combine_region(window, region, 0, 0);
    cairo_region_destroy(region);
}

static inline void tc_gtk_position_adjacent_panel(
    GtkWidget *parent_widget,
    GtkWidget *panel_widget,
    gint panel_width,
    gint panel_height,
    gint margin
) {
    GtkWindow *parent = GTK_WINDOW(parent_widget);
    GtkWindow *panel = GTK_WINDOW(panel_widget);
    gint parent_x = 0, parent_y = 0, parent_width = 0, parent_height = 0;
    gtk_window_get_position(parent, &parent_x, &parent_y);
    gtk_window_get_size(parent, &parent_width, &parent_height);

    gint x = parent_x + (parent_width - panel_width) / 2;
    gint y = parent_y + parent_height + margin;
    gint actual_height = panel_height;
    GdkWindow *gdk_parent = gtk_widget_get_window(parent_widget);
    GdkDisplay *display = gdk_display_get_default();
    GdkMonitor *monitor = (display != NULL && gdk_parent != NULL)
        ? gdk_display_get_monitor_at_window(display, gdk_parent) : NULL;
    if (monitor != NULL) {
        GdkRectangle workarea;
        gdk_monitor_get_workarea(monitor, &workarea);
        const gint workarea_bottom = workarea.y + workarea.height;
        const gint below_y = parent_y + parent_height + margin;
        const gint below_space = MAX(0, workarea_bottom - below_y);
        const gint above_space = MAX(0, parent_y - margin - workarea.y);

        if (below_space >= panel_height) {
            y = below_y;
        } else if (above_space >= panel_height) {
            y = parent_y - panel_height - margin;
        } else if (below_space >= above_space) {
            actual_height = MAX(1, below_space);
            y = below_y;
        } else {
            actual_height = MAX(1, above_space);
            y = parent_y - actual_height - margin;
        }
        x = MAX(workarea.x, MIN(x, workarea.x + workarea.width - panel_width));
        y = MAX(workarea.y, MIN(y, workarea_bottom - actual_height));
    }
    gtk_widget_set_size_request(panel_widget, panel_width, actual_height);
    gtk_window_resize(panel, panel_width, actual_height);
    gtk_window_move(panel, x, y);
}

static inline void tc_gtk_remove_all_children(GtkWidget *container_widget) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(container_widget));
    for (GList *node = children; node != NULL; node = node->next) {
        gtk_widget_destroy(GTK_WIDGET(node->data));
    }
    g_list_free(children);
}

static inline void tc_gtk_clipboard_set_text(const char *text) {
    GtkClipboard *clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
    if (clipboard != NULL) {
        gtk_clipboard_set_text(clipboard, text, -1);
        gtk_clipboard_store(clipboard);
    }
}

static inline void tc_gtk_show_about(
    GtkWidget *parent_widget,
    const char *version,
    const char *logo_path
) {
    GtkWidget *dialog = gtk_about_dialog_new();
    gtk_about_dialog_set_program_name(GTK_ABOUT_DIALOG(dialog), "TokenClock");
    gtk_about_dialog_set_version(GTK_ABOUT_DIALOG(dialog), version);
    gtk_about_dialog_set_copyright(
        GTK_ABOUT_DIALOG(dialog), "Copyright © 2026 Neo-Isshin"
    );
    gtk_about_dialog_set_license_type(GTK_ABOUT_DIALOG(dialog), GTK_LICENSE_GPL_3_0);
    gtk_about_dialog_set_comments(
        GTK_ABOUT_DIALOG(dialog),
        "normal · Linux\nA beautiful desktop clock for local AI token usage."
    );
    gtk_about_dialog_set_website(
        GTK_ABOUT_DIALOG(dialog),
        "https://github.com/Neo-Isshin/TokenClock/issues"
    );
    gtk_about_dialog_set_website_label(GTK_ABOUT_DIALOG(dialog), "GitHub Issues");
    if (logo_path != NULL && logo_path[0] != '\0') {
        GError *error = NULL;
        GdkPixbuf *logo = gdk_pixbuf_new_from_file_at_scale(logo_path, 96, 96, TRUE, &error);
        if (logo != NULL) {
            gtk_about_dialog_set_logo(GTK_ABOUT_DIALOG(dialog), logo);
            g_object_unref(logo);
        }
        if (error != NULL) g_error_free(error);
    }
    gtk_window_set_transient_for(GTK_WINDOW(dialog), GTK_WINDOW(parent_widget));
    gtk_window_set_keep_above(GTK_WINDOW(dialog), TRUE);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static inline void tc_gtk_show_message(
    GtkWidget *parent_widget,
    GtkMessageType type,
    const char *title,
    const char *message
) {
    GtkWidget *dialog = gtk_message_dialog_new(
        GTK_WINDOW(parent_widget),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        type,
        GTK_BUTTONS_OK,
        "%s",
        message
    );
    gtk_window_set_title(GTK_WINDOW(dialog), title);
    gtk_window_set_keep_above(GTK_WINDOW(dialog), TRUE);
    gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
}

static inline char *tc_gtk_choose_folder(
    GtkWidget *parent_widget,
    const char *title,
    const char *current_path
) {
    GtkWidget *dialog = gtk_file_chooser_dialog_new(
        title,
        GTK_WINDOW(parent_widget),
        GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER,
        "_Cancel", GTK_RESPONSE_CANCEL,
        "_Select", GTK_RESPONSE_ACCEPT,
        NULL
    );
    if (current_path != NULL && current_path[0] != '\0') {
        gtk_file_chooser_set_filename(GTK_FILE_CHOOSER(dialog), current_path);
    }
    char *selected = NULL;
    if (gtk_dialog_run(GTK_DIALOG(dialog)) == GTK_RESPONSE_ACCEPT) {
        selected = gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
    }
    gtk_widget_destroy(dialog);
    return selected;
}

static inline void tc_g_free(gpointer pointer) {
    g_free(pointer);
}

static inline guint tc_gtk_event_button(GdkEventButton *event) {
    return event->button;
}

static inline const char *tc_gtk_widget_name(GtkWidget *widget) {
    return gtk_widget_get_name(widget);
}

static inline void tc_gtk_popup_menu(GtkWidget *menu, GdkEventButton *event) {
    gtk_menu_popup_at_pointer(GTK_MENU(menu), (GdkEvent *)event);
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

// Pango provides UTF-8 fallback and correct metrics for CJK/emoji overlay text.
// align: 0 = left, 1 = centered, 2 = right; x/y identify that anchor point.
static inline void tc_cairo_draw_text(
    cairo_t *context,
    const char *text,
    const char *family,
    double size,
    gint weight,
    double x,
    double y,
    gint align,
    double r,
    double g,
    double b,
    double a
) {
    PangoLayout *layout = pango_cairo_create_layout(context);
    PangoFontDescription *font = pango_font_description_new();
    pango_font_description_set_family(font, family);
    pango_font_description_set_absolute_size(font, size * PANGO_SCALE);
    pango_font_description_set_weight(font, (PangoWeight)weight);
    pango_layout_set_font_description(layout, font);
    pango_layout_set_text(layout, text, -1);

    PangoRectangle logical;
    pango_layout_get_pixel_extents(layout, NULL, &logical);
    double draw_x = x;
    if (align == 1) draw_x -= logical.width / 2.0;
    if (align == 2) draw_x -= logical.width;
    cairo_move_to(context, draw_x - logical.x, y - logical.y - logical.height / 2.0);
    cairo_set_source_rgba(context, r, g, b, a);
    pango_cairo_show_layout(context, layout);

    pango_font_description_free(font);
    g_object_unref(layout);
}

#endif
