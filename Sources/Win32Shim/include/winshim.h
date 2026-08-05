#ifndef WINSHIM_H
#define WINSHIM_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Win32Shim: a thin C wrapper that owns the Win32 boilerplate (window, tray,
 * message loop, timers, popup menu, GDI) and dispatches to Swift via callbacks.
 * Win32 handles (HWND/HDC/HMENU) are passed to Swift as opaque void*.
 * Colors are packed as 0x00RRGGBB (helper converts to Win32 COLORREF 0x00BBGGRR). */

typedef void (*win_on_paint_t)      (void *ctx, void *hdc, int w, int h);
typedef void (*win_on_tick_t)       (void *ctx);          /* 1s clock tick */
typedef void (*win_on_scan_t)       (void *ctx);          /* data-scan tick */
typedef void (*win_on_tray_click_t) (void *ctx, int button); /* 1=left, 2=right */
typedef void (*win_on_build_menu_t) (void *ctx, void *hmenu);
typedef void (*win_on_menu_cmd_t)   (void *ctx, int cmd_id);
typedef void (*win_on_destroy_t)    (void *ctx);

typedef struct {
  void *ctx;
  win_on_paint_t       on_paint;
  win_on_tick_t        on_tick;
  win_on_scan_t        on_scan;
  win_on_tray_click_t  on_tray_click;
  win_on_build_menu_t  on_build_menu;
  win_on_menu_cmd_t    on_menu_cmd;
  win_on_destroy_t     on_destroy;
  int    scan_interval_ms;   /* 0 => no scan timer */
  int    width;
  int    height;
  double initial_opacity;    /* 0..1 */
  const wchar_t *class_name;
  const wchar_t *window_title;
} win_callbacks;

/* Run the app (blocks on the message loop). Returns 0 on clean exit. */
int win_run(const win_callbacks *cb);

/* --- window control (Swift calls these) --- */
void   win_invalidate(void *hwnd);
void   win_set_opacity(void *hwnd, double alpha);
void   win_resize(void *hwnd, int w, int h);
void   win_get_pos(void *hwnd, int *x, int *y);
void   win_set_pos(void *hwnd, int x, int y);
void   win_show(void *hwnd, int show);
void   win_quit(void *hwnd);
void   win_set_dpi_aware(void);
void  *win_self(void);              /* the main window HWND (for invalidate/resize/opacity from Swift) */

/* --- GDI helpers (called from Swift on_paint with the hdc it received) --- */
void gdi_clear(void *hdc, int w, int h, unsigned int rgb);
void gdi_fill_circle(void *hdc, int cx, int cy, int r,
                     unsigned int fill_rgb, unsigned int stroke_rgb, int pen_w);
void gdi_circle(void *hdc, int cx, int cy, int r, unsigned int stroke_rgb, int pen_w);
void gdi_line(void *hdc, int x1, int y1, int x2, int y2, int width, unsigned int rgb);
void gdi_text_center(void *hdc, int cx, int cy, const char *text_utf8,
                     int size_pt, unsigned int rgb, int bold);

/* --- popup menu helpers --- */
void *menu_create(void);
void  menu_add_item(void *hmenu, int cmd_id, const char *label_utf8, int checked);
void  menu_add_separator(void *hmenu);
void  menu_add_submenu(void *hmenu, const char *label_utf8, void *submenu);
void  menu_track(void *hmenu, void *hwnd);

/* --- GDI+ render (implemented in winrender.cpp) ---
 * Draws one antialiased clock frame into a per-pixel-alpha bitmap and presents it via
 * UpdateLayeredWindow — the window is fully transparent outside the dial (no rectangle).
 * Faithful classic theme: palette + geometry baked in; Swift supplies time + overlay text.
 * Each overlay string may be NULL/empty ⇒ that field is skipped. */
typedef struct {
    const char *date;        /* top centre, secondary 11px */
    const char *weather;     /* top centre (under date), primary 13px */
    const char *tokens;      /* bottom centre, primary 20px bold */
    const char *messages;    /* bottom centre (under tokens), secondary 10px */
    const char *tool_left1;  /* left side, primary 13px */
    const char *tool_left2;  /* left side (under tool_left1) */
} win_overlay;

void gdip_init(void);
void gdip_shutdown(void);
void win_render_clock(int w, int h, int hh, int mm, int ss, const win_overlay *ov);

/* --- loopback HTTP API server (implemented in winhttp.c, Winsock) ---
 * Runs on a background thread bound to 127.0.0.1:port. For each GET it calls `responder`
 * which fills `out` (up to out_size-1 bytes) with the UTF-8 JSON body and returns its
 * length, or -1 for 404. Non-GET ⇒ 405. win_start_api_server returns an opaque handle
 * (NULL on failure); pass it to win_stop_api_server to shut the thread down. */
typedef int (*win_api_responder_t)(void *ctx, const char *path, const char *query,
                                   char *out, int out_size);
void *win_start_api_server(unsigned short port, win_api_responder_t responder, void *ctx);
void  win_stop_api_server(void *handle);

#ifdef __cplusplus
}
#endif
#endif
