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
typedef void (*win_on_click_t)      (void *ctx, int x, int y);
typedef void (*win_on_scroll_t)     (void *ctx, int delta); /* wheel delta over the detail card */

typedef struct {
  void *ctx;
  win_on_paint_t       on_paint;
  win_on_tick_t        on_tick;
  win_on_scan_t        on_scan;
  win_on_tray_click_t  on_tray_click;
  win_on_build_menu_t  on_build_menu;
  win_on_menu_cmd_t    on_menu_cmd;
  win_on_destroy_t     on_destroy;
  win_on_click_t       on_click;
  win_on_scroll_t      on_scroll;
  int    scan_interval_ms;   /* 0 => no scan timer */
  int    width;
  int    height;
  double initial_opacity;    /* 0..1 */
  int    use_initial_position;  /* 1 ⇒ place at initial_x/initial_y; 0 ⇒ centre on primary screen */
  int    initial_x;
  int    initial_y;
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
void   win_set_topmost(void *hwnd, int topmost);   /* HWND_TOPMOST / HWND_NOTOPMOST */
void  *win_self(void);              /* the main window HWND (for invalidate/resize/opacity from Swift) */
void  *win_detail_window(void);     /* non-layered Acrylic sibling; NULL while collapsed */
int    win_detail_diagnostics_json(char *out_utf8, int out_size);
int    win_clipboard_set_text(const char *text_utf8); /* copy UTF-8 text as CF_UNICODETEXT */

/* --- autostart (HKCU\…\Run) + modal info box --- */
int    win_autostart_get(void);          /* 1 if the Run\TokenClock value exists */
int    win_autostart_set(int enable);    /* write/delete Run\TokenClock = this exe path; 1 on success */
void   win_message_box(const char *title_utf8, const char *body_utf8);
int    win_confirm(const char *title_utf8, const char *body_utf8); /* owner-modal Yes/No */
void   win_open_url(const char *url_utf8);                  /* ShellExecute with the default browser */
int    win_user_locale(char *buf, int n); /* GetUserDefaultLocaleName → UTF-8 (e.g. "zh-CN"); returns wchars incl. NUL, 0 on failure */

/* --- Windows 11 Fluent surfaces (implemented without Windows App SDK) ---
 * These helpers feature-detect DWM at runtime.  Unsupported Windows builds,
 * layered windows, disabled transparency and High Contrast all receive an
 * opaque system-colour fallback; no optional API is called unconditionally. */
enum win_fluent_material {
  WIN_FLUENT_FALLBACK = 0,
  WIN_FLUENT_MICA = 1,
  WIN_FLUENT_ACRYLIC = 2,
  WIN_FLUENT_MICA_ALT = 3
};

enum win_fluent_color_role {
  WIN_FLUENT_COLOR_BACKGROUND = 0,
  WIN_FLUENT_COLOR_SURFACE = 1,
  WIN_FLUENT_COLOR_TEXT = 2,
  WIN_FLUENT_COLOR_SUBTEXT = 3,
  WIN_FLUENT_COLOR_BORDER = 4,
  WIN_FLUENT_COLOR_ACCENT = 5
};

typedef struct {
  uint32_t struct_size;
  uint32_t windows_build;
  int requested_material;
  int applied_material;
  int dwm_available;
  int system_backdrop_available;
  int transparency_enabled;
  int high_contrast;
  int dark_mode;
  int layered_window_rejected;
  int32_t last_hresult;
} win_fluent_diagnostics;

int          win_fluent_apply(void *hwnd, int material);
void         win_fluent_forget(void *hwnd);
int          win_fluent_get_diagnostics(void *hwnd, win_fluent_diagnostics *out);
int          win_fluent_diagnostics_json(void *hwnd, char *out_utf8, int out_size);
int          win_fluent_is_dark(void *hwnd);
unsigned int win_fluent_color(void *hwnd, int role); /* COLORREF-style 0x00RRGGBB */
void         win_fluent_theme_child(void *child_hwnd);
void         win_fluent_paint_fallback(void *hwnd, void *hdc, const void *rect);
void         win_fluent_paint_parent(void *child_hwnd, void *hdc, const void *rect);

/* --- modal settings dialog (programmatic child controls) ---
 * dlg_create 建一个带标题的 overlapped 窗口；dlg_add_* 摆子控件（按 id 标识）；
 * dlg_modal 跑自有消息循环，点 OK(id 1)/Cancel(id 2) 或关闭窗口时返回 1/0。 */
void *dlg_create(const char *title_utf8, int w, int h);
void  dlg_add_check(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h, int checked);
void  dlg_add_edit(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h);
void  dlg_add_static(void *dlg, const char *text_utf8, int x, int y, int w, int h);
void *dlg_add_static_id(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h); /* 带 id，可 dlg_set_text 改写 */
void  dlg_add_title(void *dlg, const char *text_utf8, int x, int y, int w, int h);   /* 大号粗体标题 */
void  dlg_add_subtitle(void *dlg, const char *text_utf8, int x, int y, int w, int h); /* secondary explanatory text */
void  dlg_add_section(void *dlg, const char *text_utf8, int x, int y, int w, int h);  /* compact semibold section title */
void  dlg_add_card(void *dlg, int x, int y, int w, int h);                            /* rounded Fluent surface */
void  dlg_add_nav(void *dlg, int id, const char *title_utf8, const char *subtitle_utf8,
                  int x, int y, int w, int h);                                        /* macOS-like settings row */
void  dlg_add_disclosure(void *dlg, int id, const char *title_utf8, const char *subtitle_utf8,
                         int x, int y, int w, int h, int expanded);                    /* accordion header */
void  dlg_add_sep(void *dlg, int x, int y, int w);                                   /* 凹陷横线 */
void  dlg_add_push(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h);
void  dlg_add_brand_logo(void *dlg, int x, int y, int w, int h); /* TokenClock clock mark */
int   dlg_check_get(void *dlg, int id);                 /* 1 if checked */
void  dlg_set_check(void *dlg, int id, int checked);
void  dlg_edit_get(void *dlg, int id, char *buf_utf8, int n);   /* read edit text → UTF-8 */
void  dlg_set_text(void *dlg, int id, const char *text_utf8);   /* set a control's label/text */
void  dlg_show_control(void *dlg, int id, int show);             /* reveal/hide a pre-created row */
void  dlg_reset_content(void *dlg, int content_height);          /* rebuild children + scroll extent */
void  dlg_scroll_to(void *dlg, int y);                            /* scroll to logical content y */
int   dlg_modal(void *dlg);                             /* blocks; returns 1=OK 0=cancel */
void  dlg_end(void *dlg, int result);                   /* programmatically finish current modal */
void  dlg_destroy(void *dlg);                           /* caller destroys after reading child controls */
typedef void (*dlg_on_cmd_t)(void *ctx, int id);
int   dlg_modal_cb(void *dlg, dlg_on_cmd_t on_cmd, void *ctx);  /* 同 dlg_modal，非 OK/Cancel 的按钮点击回调 on_cmd */

/* --- 颜色选择（系统 ChooseColor 对话框）→ ARGB；返回 1=选定 --- */
int win_pick_color(unsigned int initial_argb, unsigned int *out_argb);
int win_pick_folder(void *owner, const char *title_utf8, const char *initial_utf8,
                    char *out_utf8, int out_size);

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
void  menu_show_at(void *menu, void *hwnd, int x, int y);   /* TrackPopupMenu at fixed point (capture) */

/* Modal visual clock-face picker. Draws a real 3x3 grid of dial previews and returns
 * the selected zero-based index, or -1 when dismissed. */
typedef struct win_theme win_theme;
int win_theme_picker(const win_theme *themes, const char **names_utf8, int count,
                     int selected, const char *title_utf8);

/* --- GDI+ render (implemented in winrender.cpp) ---
 * Draws one antialiased clock frame into a per-pixel-alpha bitmap and presents it via
 * UpdateLayeredWindow — the window is fully transparent outside the dial (no rectangle).
 * Theme-driven: Swift builds a win_theme ( colours ARGB 0xAARRGGBB so .clear/opacity carry ),
 * winrender renders dial/rim/ticks/numbers/4 hand-styles/centre-cap/sky-decoration from it.
 * Each overlay string may be NULL/empty ⇒ that field is skipped. */
struct win_theme {
    unsigned int dial_fill;      /* 0xAARRGGBB */
    unsigned int dial_rim;
    double       rim_width;      /* px @ radius 116 (macOS 用分数 1.5/2.5) */
    int          material_style; /* 0 flat, 1 Frost, 2 Porcelain, 3 Smoked Glass */
    int          hand_style;     /* 0 round, 1 tapered, 2 lance, 3 sword */
    unsigned int hour_color, minute_color, second_color;
    double       hour_len, minute_len, second_len;   /* fraction of radius */
    double       hour_w, minute_w, second_w;          /* px @ radius 116 */
    unsigned int cap_outer, cap_inner;
    int          show_ticks;
    unsigned int tick_color, major_tick_color;
    int          show_numbers;    /* 0 none, 1 arabic, 2 chinese */
    unsigned int number_color;
    int          has_decoration;  /* sky theme */
    unsigned int text_primary, text_secondary;
    unsigned int dd_bg, dd_text, dd_subtext, dd_border;   /* 下拉详情卡片配色 */
};

typedef struct {
    const char *date;        /* top centre, secondary 11px */
    const char *weather;     /* top centre (under date), primary 13px */
    const char *today_label; /* bottom caption above token count */
    const char *tokens;      /* bottom centre, primary 20px bold */
    const char *messages;    /* bottom centre (under tokens), secondary 10px */
    const char *tool_left1;  /* left side, primary 13px */
    const char *tool_left2;  /* left side (under tool_left1) */
    const char *rate;        /* right-side rate emoji */
    const char *dial_image_path; /* glass_disc.png path; empty for vector dial */
    const char *detail_text; /* 展开时盘面下方的工具明细，多行 '\n' 分隔；空 ⇒ 收起态 */
    const char *detail_controls; /* session label \t model label \t percent label */
    const char *detail_header;   /* label \t usage \t messages \t cache */
    const char *forecast_summary; /* emoji/city/temp \t-ish encoded as summary|label */
    const char *forecast_slots;   /* time|emoji|temp, four slots separated by \t */
    const char *quota_label;      /* left chip label beside percent */
    const char *quota_text;       /* quota panel: typed tab-separated rows */
    int detail_grouping;         /* 0 session / 1 model */
    int detail_percentage;       /* 0 absolute / 1 percent */
    int detail_visible;          /* explicit; never infer visibility from row text */
    int detail_quota_visible;    /* 1 shows quota panel in place of the usage rows */
    int clock_diameter;          /* face diameter; independent from expanded host width */
    int detail_card_width;       /* fixed 320 for macOS-normal equivalent detail card */
} win_overlay;

void gdip_init(void);
void gdip_shutdown(void);
void win_render_set_opacity(double alpha);  /* SourceConstantAlpha for UpdateLayeredWindow */
void win_render_clock(int w, int h, int hh, int mm, int ss, const win_theme *t, const win_overlay *ov);
/* Internal bridge used by winshim.c's normal HWND paint path. */
void win_render_detail_paint(void *hdc, int w, int h);
void win_detail_present(int show, int dial_height, int main_width, int card_width, int card_height);

/* Non-zero when TokenClock has a native colored vector replacement for the
 * leading semantic emoji in a UTF-8 label. Used by Windows regression tests. */
int win_color_icon_supported_utf8(const char *text_utf8);

/* --- outbound HTTP(S) client (implemented in winclient.c, WinHTTP) ---
 * Synchronous and intended for Swift worker queues. Uses NO_PROXY, never follows redirects,
 * never loads/stores cookies or ambient credentials, retains default HTTPS certificate checks,
 * and refuses to write beyond response_capacity. Returns 1 once a complete HTTP response has
 * been received (including non-2xx responses), otherwise 0 with a Win32 error in out_error. */
int win_native_http_request(const char *url_utf8,
                            const char *method_utf8,
                            const char *headers_utf8,
                            const unsigned char *request_body,
                            int request_body_length,
                            int connect_timeout_ms,
                            int send_timeout_ms,
                            int receive_timeout_ms,
                            unsigned char *response_body,
                            int response_capacity,
                            int *out_response_length,
                            int *out_status_code,
                            unsigned long *out_error);

/* --- loopback HTTP API server (implemented in winhttp.c, Winsock) ---
 * Runs on a background thread bound to 127.0.0.1:port. For each GET it calls `responder`
 * which fills `out` (up to out_size-1 bytes) with the UTF-8 JSON body and returns its
 * length, or -1 for 404. Non-GET ⇒ 405. win_start_api_server returns an opaque handle
 * (NULL on failure); pass it to win_stop_api_server to shut the thread down. */
typedef int (*win_api_responder_t)(void *ctx, const char *path, const char *query,
                                   char *out, int out_size);
void *win_start_api_server(unsigned short port, win_api_responder_t responder, void *ctx);
void  win_pause_api_server(void *handle); /* close listener, keep the callback worker alive */
void  win_reconfigure_api_server(void *handle, unsigned short port); /* rebind on same worker */
void  win_stop_api_server(void *handle);

/* --- strict CodeBuddy loopback HTTP client (wincodebuddyhttp.c) ---
 * Always connects directly to IPv4 127.0.0.1 using Winsock. The route is fixed by this enum;
 * redirects, authentication, chunked transfer and responses larger than 1 MiB are rejected. */
enum win_codebuddy_route {
  WIN_CODEBUDDY_STATS = 0,
  WIN_CODEBUDDY_SESSION_STATS = 1
};
int win_codebuddy_http_get(unsigned short port, int route, unsigned char *out,
                           int out_capacity, int timeout_ms);

#ifdef __cplusplus
}
#endif
#endif
