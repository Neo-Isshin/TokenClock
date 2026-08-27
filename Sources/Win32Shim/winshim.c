/* winshim.c — Win32 boilerplate driven by Swift callbacks (see winshim.h).
 * Owns: window class, topmost borderless layered tool window, system-tray icon,
 * 1s clock timer + data-scan timer, popup menu, paint dispatch, GDI helpers. */
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <windowsx.h>
#include <shellapi.h>
#include <shlobj.h>
#include <commdlg.h>   /* ChooseColor */
#include <stdio.h>
#include "winshim.h"

#define IDM_TICK   1001
#define IDM_SCAN   1002
#define WM_TRAY    (WM_APP + 1)

static win_callbacks g_cb;
HWND  g_hwnd = NULL;                  /* non-static: shared with winrender.cpp */
static UINT  g_taskbar_created = 0;   /* registered msg: explorer restarted */
static int   g_mouse_down = 0, g_mouse_dragged = 0, g_mouse_can_drag = 0;
static POINT g_mouse_down_screen;
static RECT  g_mouse_down_window;
static HWND  g_detail_hwnd = NULL;
static int   g_detail_wanted = 0;
static int   g_detail_dial_height = 0;
static int   g_detail_main_width = 0;
static int   g_detail_width = 320;
static int   g_detail_height = 547;
static BYTE  g_detail_alpha = 255;
static int   g_detail_applied_alpha = -1;
static int   g_topmost = 1;
static int   g_main_visible = 1;

static COLORREF to_cr(unsigned int rgb) {
    return RGB((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
}

/* UTF-8 (Swift strings) -> UTF-16 buffer. Returns length (wchars) written; 0 on overflow/empty. */
static int to_wide(const char *u8, wchar_t *buf, int buf_len) {
    if (!u8) { if (buf_len > 0) buf[0] = 0; return 0; }
    int n = MultiByteToWideChar(CP_UTF8, 0, u8, -1, buf, buf_len);
    if (n == 0 && GetLastError() == ERROR_INSUFFICIENT_BUFFER && buf_len > 0) { buf[0] = 0; return 0; }
    return n;   /* includes the terminating NUL on success */
}

static void add_tray(void) {
    NOTIFYICONDATAW nid = {0};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hwnd;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAY;
    nid.hIcon = LoadIconW(NULL, IDI_APPLICATION);
    wcscpy_s(nid.szTip, ARRAYSIZE(nid.szTip), L"TokenClock");
    Shell_NotifyIconW(NIM_ADD, &nid);
    nid.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &nid);
}

static void remove_tray(void) {
    NOTIFYICONDATAW nid = {0};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_hwnd;
    nid.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &nid);
}

static void show_context_menu(HWND h, int x, int y) {
    HMENU hmenu = CreatePopupMenu();
    if (g_cb.on_build_menu) g_cb.on_build_menu(g_cb.ctx, hmenu);
    POINT pt = {x, y};
    if (x < 0 || y < 0) GetCursorPos(&pt);
    SetForegroundWindow(h);
    TrackPopupMenu(hmenu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, h, NULL);
    DestroyMenu(hmenu);
}

static void detail_reposition(void) {
    if (!IsWindow(g_hwnd) || !IsWindow(g_detail_hwnd)) return;
    RECT main_rect;
    GetWindowRect(g_hwnd, &main_rect);
    int x = main_rect.left + (g_detail_main_width - g_detail_width) / 2;
    int y = main_rect.top + g_detail_dial_height + 14;
    SetWindowPos(g_detail_hwnd, g_topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                 x, y, g_detail_width, g_detail_height,
                 SWP_NOACTIVATE);
}

static void detail_apply_region(HWND hwnd) {
    RECT rect; GetClientRect(hwnd, &rect);
    HRGN region = CreateRoundRectRgn(0, 0, rect.right + 1, rect.bottom + 1, 24, 24);
    if (region && !SetWindowRgn(hwnd, region, TRUE)) DeleteObject(region);
}

/* DWM backdrops cannot be uniformly faded with ordinary Win32 painting.  Keep the native
 * Acrylic surface at full opacity; for lower user-selected opacity, switch only the detail
 * sibling to a rounded, solid layered surface so the entire card (background and content)
 * fades together.  Returning to 100% restores real Acrylic immediately. */
static void detail_apply_opacity(HWND hwnd) {
    if (!IsWindow(hwnd)) return;
    if (g_detail_applied_alpha == (int)g_detail_alpha) return;
    LONG_PTR ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
    if (g_detail_alpha < 255) {
        if ((ex_style & WS_EX_LAYERED) == 0) {
            win_fluent_apply(hwnd, WIN_FLUENT_FALLBACK);
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex_style | WS_EX_LAYERED);
            SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        SetLayeredWindowAttributes(hwnd, 0, g_detail_alpha, LWA_ALPHA);
    } else {
        if ((ex_style & WS_EX_LAYERED) != 0) {
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex_style & ~((LONG_PTR)WS_EX_LAYERED));
            SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
        win_fluent_apply(hwnd, WIN_FLUENT_ACRYLIC);
    }
    g_detail_applied_alpha = (int)g_detail_alpha;
    InvalidateRect(hwnd, NULL, TRUE);
}

static LRESULT CALLBACK detail_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        win_fluent_apply(h, WIN_FLUENT_ACRYLIC);
        detail_apply_opacity(h);
        return 0;
    case WM_ERASEBKGND: {
        RECT rect; GetClientRect(h, &rect);
        win_fluent_paint_fallback(h, (void *)wp, &rect);
        return 1;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rect; GetClientRect(h, &rect);
        win_fluent_diagnostics fluent;
        ZeroMemory(&fluent, sizeof(fluent));
        fluent.struct_size = sizeof(fluent);
        if (g_detail_alpha == 255 &&
            win_fluent_get_diagnostics(h, &fluent) &&
            fluent.applied_material == WIN_FLUENT_ACRYLIC) {
            /* A full-client DWM backdrop must be reset before alpha-compositing the next
             * frame. Without this black glass canvas, translucent text/background pixels
             * accumulate on the previous frame and leave ghosts after Model/Percent
             * switches. Black is the documented glass composition surface; DWM replaces
             * it with Acrylic before presenting the window. */
            PatBlt(dc, rect.left, rect.top,
                   rect.right - rect.left, rect.bottom - rect.top, BLACKNESS);
        } else {
            /* Old Windows, High Contrast, disabled transparency, and user opacity below
             * 100% all use the solid fallback. Repaint it fully for the same no-ghost
             * guarantee without turning those configurations black. */
            win_fluent_paint_fallback(h, dc, &rect);
        }
        win_render_detail_paint(dc, rect.right - rect.left, rect.bottom - rect.top);
        EndPaint(h, &ps);
        return 0;
    }
    case WM_SIZE:
        detail_apply_region(h);
        return 0;
    case WM_LBUTTONUP:
        if (g_cb.on_click) {
            int virtual_width = max(g_detail_main_width, g_detail_width);
            int main_x = GET_X_LPARAM(lp) + (virtual_width - g_detail_width) / 2;
            int main_y = GET_Y_LPARAM(lp) + g_detail_dial_height + 14;
            g_cb.on_click(g_cb.ctx, main_x, main_y);
        }
        return 0;
    case WM_MOUSEWHEEL:
        if (g_cb.on_scroll) g_cb.on_scroll(g_cb.ctx, GET_WHEEL_DELTA_WPARAM(wp));
        return 0;
    case WM_RBUTTONUP: {
        POINT point; GetCursorPos(&point);
        show_context_menu(g_hwnd, point.x, point.y);
        return 0;
    }
    case WM_MOUSEACTIVATE:
        return MA_NOACTIVATE;
    case WM_NCHITTEST:
        return HTCLIENT;
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        g_detail_applied_alpha = -1;
        detail_apply_opacity(h);
        return 0;
    case WM_CLOSE:
        g_detail_wanted = 0;
        ShowWindow(h, SW_HIDE);
        return 0;
    case WM_NCDESTROY:
        win_fluent_forget(h);
        if (g_detail_hwnd == h) {
            g_detail_hwnd = NULL;
            g_detail_applied_alpha = -1;
        }
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static HWND ensure_detail_window(void) {
    if (IsWindow(g_detail_hwnd)) return g_detail_hwnd;
    static int registered = 0;
    if (!registered) {
        WNDCLASSEXW wc = {0};
        wc.cbSize = sizeof(wc);
        wc.lpfnWndProc = detail_proc;
        wc.hInstance = GetModuleHandleW(NULL);
        wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
        wc.hbrBackground = NULL;
        wc.lpszClassName = L"TokenClockDetail";
        if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return NULL;
        registered = 1;
    }
    DWORD ex_style = WS_EX_TOOLWINDOW | (g_topmost ? WS_EX_TOPMOST : 0);
    g_detail_hwnd = CreateWindowExW(ex_style, L"TokenClockDetail", L"TokenClock Details",
                                    WS_POPUP, 0, 0, g_detail_width, g_detail_height,
                                    g_hwnd, NULL, GetModuleHandleW(NULL), NULL);
    return g_detail_hwnd;
}

void win_detail_present(int show, int dial_height, int main_width, int card_width, int card_height) {
    g_detail_wanted = show ? 1 : 0;
    if (!show) {
        if (IsWindow(g_detail_hwnd)) ShowWindow(g_detail_hwnd, SW_HIDE);
        return;
    }
    g_detail_dial_height = dial_height;
    g_detail_main_width = main_width;
    g_detail_width = card_width > 0 ? card_width : 320;
    g_detail_height = card_height > 0 ? card_height : 547;
    HWND detail = ensure_detail_window();
    if (!detail) return;
    detail_apply_opacity(detail);
    detail_reposition();
    detail_apply_region(detail);
    if (g_main_visible) {
        ShowWindow(detail, SW_SHOWNOACTIVATE);
        InvalidateRect(detail, NULL, TRUE);
        UpdateWindow(detail);
    }
}

void *win_detail_window(void) { return IsWindow(g_detail_hwnd) ? g_detail_hwnd : NULL; }

int win_detail_diagnostics_json(char *out_utf8, int out_size) {
    if (!out_utf8 || out_size <= 0) return 0;
    if (!IsWindow(g_detail_hwnd)) {
        int count = snprintf(out_utf8, (size_t)out_size, "{\"visible\":false,\"applied\":0}");
        return count > 0 && count < out_size ? count : 0;
    }
    return win_fluent_diagnostics_json(g_detail_hwnd, out_utf8, out_size);
}

static LRESULT CALLBACK wnd_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == g_taskbar_created) {   /* explorer restarted: re-add the tray icon */
        add_tray();
        return 0;
    }
    switch (msg) {
    case WM_CREATE:
        g_hwnd = h;
        /* WS_EX_LAYERED is set on the window; content is composited per-pixel via
         * UpdateLayeredWindow in win_render_clock — do NOT call SetLayeredWindowAttributes
         * (constant-alpha) here, it conflicts with per-pixel-alpha. */
        SetTimer(h, IDM_TICK, 1000, NULL);
        if (g_cb.scan_interval_ms > 0)
            SetTimer(h, IDM_SCAN, g_cb.scan_interval_ms, NULL);
        add_tray();
        return 0;

    case WM_TIMER:
        if (wp == IDM_TICK && g_cb.on_tick) g_cb.on_tick(g_cb.ctx);
        else if (wp == IDM_SCAN && g_cb.on_scan) g_cb.on_scan(g_cb.ctx);
        return 0;

    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        if (g_cb.on_paint) g_cb.on_paint(g_cb.ctx, hdc, (int)(rc.right - rc.left), (int)(rc.bottom - rc.top));
        EndPaint(h, &ps);
        return 0;
    }

    case WM_TRAY:
        /* NOTIFYICON_VERSION_4: lParam low word = the mouse event, high word = icon id. */
        if (g_cb.on_tray_click) {
            switch (LOWORD(lp)) {
            case WM_LBUTTONUP:
            case WM_LBUTTONDBLCLK: g_cb.on_tray_click(g_cb.ctx, 1); break;
            case WM_RBUTTONUP: {
                show_context_menu(h, -1, -1);
                break;
            }
            }
        }
        return 0;

    case WM_COMMAND:
        if (g_cb.on_menu_cmd) g_cb.on_menu_cmd(g_cb.ctx, (int)LOWORD(wp));
        return 0;

    case WM_RBUTTONUP: {
        POINT pt; GetCursorPos(&pt);
        show_context_menu(h, pt.x, pt.y);
        return 0;
    }

    case WM_LBUTTONDOWN: {
        g_mouse_down = 1; g_mouse_dragged = 0;
        /* Detail is a separate non-layered sibling, so the entire visible dial host is draggable. */
        g_mouse_can_drag = 1;
        GetCursorPos(&g_mouse_down_screen);
        GetWindowRect(h, &g_mouse_down_window);
        SetCapture(h);
        return 0;
    }

    case WM_MOUSEMOVE:
        if (g_mouse_down && (wp & MK_LBUTTON) && g_mouse_can_drag) {
            POINT now; GetCursorPos(&now);
            int dx = now.x - g_mouse_down_screen.x, dy = now.y - g_mouse_down_screen.y;
            if (abs(dx) > 3 || abs(dy) > 3) g_mouse_dragged = 1;
            if (g_mouse_dragged) {
                SetWindowPos(h, NULL, g_mouse_down_window.left + dx, g_mouse_down_window.top + dy,
                             0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
            }
        }
        return 0;

    case WM_LBUTTONUP:
        if (g_mouse_down) {
            int clicked = !g_mouse_dragged;
            g_mouse_down = 0; ReleaseCapture();
            if (clicked && g_cb.on_click) g_cb.on_click(g_cb.ctx, GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
        }
        return 0;

    case WM_MOUSEWHEEL:
        if (g_cb.on_scroll) g_cb.on_scroll(g_cb.ctx, GET_WHEEL_DELTA_WPARAM(wp));
        return 0;

    case WM_WINDOWPOSCHANGED:
        if (g_detail_wanted) detail_reposition();
        break;

    case WM_NCHITTEST:
        return HTCLIENT;    /* manual drag preserves click interaction */

    case WM_DESTROY:
        if (IsWindow(g_detail_hwnd)) DestroyWindow(g_detail_hwnd);
        remove_tray();
        if (g_cb.on_destroy) g_cb.on_destroy(g_cb.ctx);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

int win_run(const win_callbacks *cb) {
    g_cb = *cb;
    g_taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.lpszClassName = cb->class_name ? cb->class_name : L"TokenClock";
    RegisterClassExW(&wc);

    int sw = GetSystemMetrics(SM_CXSCREEN);
    int sh = GetSystemMetrics(SM_CYSCREEN);
    int w = cb->width  ? cb->width  : 360;
    int h = cb->height ? cb->height : 430;
    int x = cb->use_initial_position ? cb->initial_x : (sw - w) / 2;
    int y = cb->use_initial_position ? cb->initial_y : (sh - h) / 2;

    HWND hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
        wc.lpszClassName,
        cb->window_title ? cb->window_title : L"TokenClock",
        WS_POPUP,
        x, y, w, h,
        NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) return 1;

    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);

    gdip_init();
    win_render_set_opacity(cb->initial_opacity);
    if (cb->initial_opacity <= 0.0) g_detail_alpha = 0;
    else if (cb->initial_opacity >= 1.0) g_detail_alpha = 255;
    else g_detail_alpha = (BYTE)(cb->initial_opacity * 255.0 + 0.5);
    if (g_cb.on_tick) g_cb.on_tick(g_cb.ctx);   // first frame immediately (no 1s blank)

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    gdip_shutdown();
    return 0;
}

/* --- window control --- */
void win_invalidate(void *hwnd)      { InvalidateRect((HWND)hwnd, NULL, FALSE); }
void win_set_opacity(void *hwnd, double a) {
    if (a <= 0.0) g_detail_alpha = 0;
    else if (a >= 1.0) g_detail_alpha = 255;
    else g_detail_alpha = (BYTE)(a * 255.0 + 0.5);
    win_render_set_opacity(a);
    InvalidateRect((HWND)hwnd, NULL, FALSE);
    if (IsWindow(g_detail_hwnd)) detail_apply_opacity(g_detail_hwnd);
}
void win_resize(void *hwnd, int w, int h) {
    SetWindowPos((HWND)hwnd, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
    if ((HWND)hwnd == g_hwnd && g_detail_wanted) detail_reposition();
}
void win_get_pos(void *hwnd, int *x, int *y) { RECT rc; GetWindowRect((HWND)hwnd, &rc); if (x) *x = rc.left; if (y) *y = rc.top; }
void win_set_pos(void *hwnd, int x, int y)  { SetWindowPos((HWND)hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER); }
void win_show(void *hwnd, int show) {
    if ((HWND)hwnd == g_hwnd) g_main_visible = show ? 1 : 0;
    ShowWindowAsync((HWND)hwnd, show ? SW_SHOWNORMAL : SW_HIDE);
    if ((HWND)hwnd == g_hwnd && IsWindow(g_detail_hwnd))
        ShowWindowAsync(g_detail_hwnd, show && g_detail_wanted ? SW_SHOWNOACTIVATE : SW_HIDE);
}
void win_quit(void *hwnd)                   { PostMessageW((HWND)hwnd, WM_CLOSE, 0, 0); }
void win_set_dpi_aware(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}
void *win_self(void) { return g_hwnd; }
void win_set_topmost(void *hwnd, int topmost) {
    if ((HWND)hwnd == g_hwnd) g_topmost = topmost ? 1 : 0;
    SetWindowPos((HWND)hwnd, topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    if ((HWND)hwnd == g_hwnd && IsWindow(g_detail_hwnd))
        SetWindowPos(g_detail_hwnd, topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                     0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

int win_clipboard_set_text(const char *text_utf8) {
    if (!text_utf8) return 0;
    int chars = MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, NULL, 0);
    if (chars <= 0) return 0;
    int opened = 0;
    for (int attempt = 0; attempt < 10; attempt++) {
        if (OpenClipboard(g_hwnd)) { opened = 1; break; }
        Sleep(10);
    }
    if (!opened) return 0;
    EmptyClipboard();
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T)chars * sizeof(wchar_t));
    if (!memory) { CloseClipboard(); return 0; }
    wchar_t *text = (wchar_t *)GlobalLock(memory);
    if (!text) { GlobalFree(memory); CloseClipboard(); return 0; }
    MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, text, chars);
    GlobalUnlock(memory);
    if (!SetClipboardData(CF_UNICODETEXT, memory)) {
        GlobalFree(memory);
        CloseClipboard();
        return 0;
    }
    CloseClipboard();
    return 1;  /* clipboard owns memory after SetClipboardData succeeds */
}

/* --- autostart (per-user HKCU\Software\Microsoft\Windows\CurrentVersion\Run\TokenClock) --- */
#define TC_RUN_SUBKEY  L"Software\\Microsoft\\Windows\\CurrentVersion\\Run"
#define TC_RUN_VALUE   L"TokenClock"

/* 本进程 exe 的完整路径（带引号，供注册表 Run 项直接使用）。失败返回空串。 */
static void current_exe_quoted(wchar_t *out, int n) {
    out[0] = 0;
    wchar_t path[MAX_PATH];
    if (GetModuleFileNameW(NULL, path, MAX_PATH) == 0) return;
    _snwprintf_s(out, n, _TRUNCATE, L"\"%s\"", path);
    out[n - 1] = 0;
}

int win_autostart_get(void) {
    HKEY key;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, TC_RUN_SUBKEY, 0, KEY_READ, &key) != ERROR_SUCCESS)
        return 0;
    int exists = (RegQueryValueExW(key, TC_RUN_VALUE, NULL, NULL, NULL, NULL) == ERROR_SUCCESS);
    RegCloseKey(key);
    return exists ? 1 : 0;
}

int win_autostart_set(int enable) {
    HKEY key;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, TC_RUN_SUBKEY, 0, NULL, 0,
                        KEY_SET_VALUE, NULL, &key, NULL) != ERROR_SUCCESS)
        return 0;
    int ok = 1;
    if (enable) {
        wchar_t val[MAX_PATH + 4];
        current_exe_quoted(val, MAX_PATH + 4);
        ok = (RegSetValueExW(key, TC_RUN_VALUE, 0, REG_SZ,
                             (const BYTE *)val,
                             (DWORD)((wcslen(val) + 1) * sizeof(wchar_t))) == ERROR_SUCCESS);
    } else {
        RegDeleteValueW(key, TC_RUN_VALUE);
    }
    RegCloseKey(key);
    return ok ? 1 : 0;
}

void win_message_box(const char *title_utf8, const char *body_utf8) {
    wchar_t t[256], b[1024];
    if (to_wide(title_utf8, t, 256) == 0) t[0] = 0;
    if (to_wide(body_utf8, b, 1024) == 0) b[0] = 0;
    MessageBoxW(NULL, b, t, MB_OK | MB_ICONINFORMATION);
}

int win_confirm(const char *title_utf8, const char *body_utf8) {
    wchar_t t[256], b[1024];
    if (to_wide(title_utf8, t, 256) == 0) t[0] = 0;
    if (to_wide(body_utf8, b, 1024) == 0) b[0] = 0;
    return MessageBoxW(g_hwnd, b, t, MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2) == IDYES ? 1 : 0;
}

void win_open_url(const char *url_utf8) {
    wchar_t url[1024];
    if (to_wide(url_utf8, url, 1024) == 0) return;
    ShellExecuteW(g_hwnd, L"open", url, NULL, NULL, SW_SHOWNORMAL);
}

int win_user_locale(char *buf, int n) {
    if (!buf || n <= 0) return 0;
    wchar_t w[LOCALE_NAME_MAX_LENGTH];
    if (GetUserDefaultLocaleName(w, LOCALE_NAME_MAX_LENGTH) == 0) { buf[0] = 0; return 0; }
    return WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, n, NULL, NULL);   /* incl. NUL on success */
}

/* --- modal settings dialog --- */

static HWND g_dlg = NULL;
static dlg_on_cmd_t g_dlg_oncmd = NULL;
static void *g_dlg_cmdctx = NULL;
static HBRUSH g_dlg_background_brush = NULL;
static unsigned int g_dlg_background_rgb = 0xffffffffu;
static HBRUSH g_dlg_edit_brush = NULL;
static unsigned int g_dlg_edit_rgb = 0xffffffffu;

#define TC_TEXT_ROLE_PROP L"TokenClock.TextRole"
#define TC_EDIT_INNER_PROP L"TokenClock.EditInner"
#define TC_DIALOG_VISUAL_PROP L"TokenClock.DialogVisual"
#define TC_SCROLL_CLIPPED_PROP L"TokenClock.ScrollClipped"

typedef struct {
    int card_count;
    RECT cards[32];
    int scroll_pos;
    int content_height;
    int modal_result;
    int modal_done;
} dlg_visual_state;

static HFONT dlg_font(void);
static HFONT dlg_title_font(void);
static HFONT dlg_section_font(void);
static HFONT dlg_caption_font(void);
static HBRUSH dlg_background_brush(HWND hwnd);
static HBRUSH dlg_edit_brush(HWND hwnd);
static int dlg_child_on_card(HWND dialog, HWND child);

static unsigned int dlg_blend_rgb(unsigned int base, unsigned int overlay, int overlay_percent) {
    int keep = 100 - overlay_percent;
    unsigned int r = (((base >> 16) & 255u) * (unsigned int)keep
                    + ((overlay >> 16) & 255u) * (unsigned int)overlay_percent) / 100u;
    unsigned int g = (((base >> 8) & 255u) * (unsigned int)keep
                    + ((overlay >> 8) & 255u) * (unsigned int)overlay_percent) / 100u;
    unsigned int b = ((base & 255u) * (unsigned int)keep
                    + (overlay & 255u) * (unsigned int)overlay_percent) / 100u;
    return (r << 16) | (g << 8) | b;
}

static void dlg_fill_round_rect(HDC dc, const RECT *rect, int radius,
                                unsigned int fill_rgb, unsigned int border_rgb) {
    HBRUSH fill = CreateSolidBrush(to_cr(fill_rgb));
    HPEN border = CreatePen(PS_SOLID, 1, to_cr(border_rgb));
    HGDIOBJ old_brush = SelectObject(dc, fill);
    HGDIOBJ old_pen = SelectObject(dc, border);
    RoundRect(dc, rect->left, rect->top, rect->right, rect->bottom, radius, radius);
    SelectObject(dc, old_brush); SelectObject(dc, old_pen);
    DeleteObject(fill); DeleteObject(border);
}

static dlg_visual_state *dlg_visual(HWND dialog, int create) {
    dlg_visual_state *state = (dlg_visual_state *)GetPropW(dialog, TC_DIALOG_VISUAL_PROP);
    if (!state && create) {
        state = (dlg_visual_state *)calloc(1, sizeof(*state));
        if (state && !SetPropW(dialog, TC_DIALOG_VISUAL_PROP, state)) {
            free(state); state = NULL;
        }
    }
    return state;
}

static void dlg_paint_canvas(HWND dialog, HDC dc) {
    RECT rect; GetClientRect(dialog, &rect);
    HBRUSH background = CreateSolidBrush(to_cr(win_fluent_color(dialog, WIN_FLUENT_COLOR_BACKGROUND)));
    FillRect(dc, &rect, background); DeleteObject(background);
    dlg_visual_state *state = dlg_visual(dialog, 0);
    if (!state) return;
    for (int i = 0; i < state->card_count; i++) {
        RECT card = state->cards[i];
        OffsetRect(&card, 0, -state->scroll_pos);
        card.right -= 1; card.bottom -= 1;
        dlg_fill_round_rect(dc, &card, 16,
                            win_fluent_color(dialog, WIN_FLUENT_COLOR_SURFACE),
                            win_fluent_color(dialog, WIN_FLUENT_COLOR_BORDER));
    }
}

static void dlg_draw_owner_button(HWND dialog, DRAWITEMSTRUCT *item) {
    if (!item || item->CtlType != ODT_BUTTON) return;
    const int primary = item->CtlID == 1;
    const int pressed = (item->itemState & ODS_SELECTED) != 0;
    const int disabled = (item->itemState & ODS_DISABLED) != 0;
    const int hot = (item->itemState & ODS_HOTLIGHT) != 0;
    unsigned int surface = win_fluent_color(dialog, WIN_FLUENT_COLOR_SURFACE);
    unsigned int background = win_fluent_color(dialog, WIN_FLUENT_COLOR_BACKGROUND);
    unsigned int accent = win_fluent_color(dialog, WIN_FLUENT_COLOR_ACCENT);
    unsigned int border = win_fluent_color(dialog, WIN_FLUENT_COLOR_BORDER);
    unsigned int text = win_fluent_color(dialog, WIN_FLUENT_COLOR_TEXT);

    HBRUSH clear = CreateSolidBrush(to_cr(primary ? background : surface));
    FillRect(item->hDC, &item->rcItem, clear); DeleteObject(clear);
    RECT button = item->rcItem;
    InflateRect(&button, -1, -1);
    unsigned int fill = primary ? accent : surface;
    if (hot) fill = dlg_blend_rgb(fill, accent, primary ? 12 : 8);
    if (pressed) fill = dlg_blend_rgb(fill, 0x000000u, 12);
    if (disabled) fill = dlg_blend_rgb(fill, background, 48);
    dlg_fill_round_rect(item->hDC, &button, 10, fill, primary ? accent : border);

    wchar_t label[256];
    GetWindowTextW(item->hwndItem, label, ARRAYSIZE(label));
    SetBkMode(item->hDC, TRANSPARENT);
    SetTextColor(item->hDC, to_cr(primary ? 0xffffffu : (disabled
        ? win_fluent_color(dialog, WIN_FLUENT_COLOR_SUBTEXT) : text)));
    HGDIOBJ old_font = SelectObject(item->hDC, dlg_font());
    DrawTextW(item->hDC, label, -1, &button,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
    SelectObject(item->hDC, old_font);
    if ((item->itemState & ODS_FOCUS) != 0) {
        RECT focus = button; InflateRect(&focus, -4, -4); DrawFocusRect(item->hDC, &focus);
    }
}

typedef struct {
    wchar_t subtitle[256];
    int hot;
    int pressed;
    int expanded;
} dlg_nav_state;

#define TC_NAV_SET_EXPANDED (WM_APP + 37)

static LRESULT CALLBACK dlg_nav_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    dlg_nav_state *state = (dlg_nav_state *)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (msg) {
    case WM_NCCREATE: {
        CREATESTRUCTW *create = (CREATESTRUCTW *)lp;
        state = (dlg_nav_state *)calloc(1, sizeof(*state));
        if (!state) return FALSE;
        if (create->lpCreateParams) lstrcpynW(state->subtitle, (const wchar_t *)create->lpCreateParams, ARRAYSIZE(state->subtitle));
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)state);
        return DefWindowProcW(h, msg, wp, lp);
    }
    case WM_NCDESTROY:
        free(state); SetWindowLongPtrW(h, GWLP_USERDATA, 0); break;
    case WM_ERASEBKGND: return 1;
    case WM_MOUSEMOVE:
        if (state && !state->hot) {
            state->hot = 1;
            TRACKMOUSEEVENT track = { sizeof(track), TME_LEAVE, h, 0 };
            TrackMouseEvent(&track); InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_MOUSELEAVE:
        if (state) { state->hot = 0; state->pressed = 0; InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_LBUTTONDOWN:
        if (state) { state->pressed = 1; SetCapture(h); SetFocus(h); InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_LBUTTONUP:
        if (state && state->pressed) {
            state->pressed = 0; ReleaseCapture(); InvalidateRect(h, NULL, FALSE);
            RECT rect; POINT point = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) }; GetClientRect(h, &rect);
            if (PtInRect(&rect, point)) SendMessageW(GetParent(h), WM_COMMAND,
                MAKEWPARAM(GetDlgCtrlID(h), BN_CLICKED), (LPARAM)h);
        }
        return 0;
    case WM_KEYDOWN:
        if (wp == VK_SPACE || wp == VK_RETURN) {
            SendMessageW(GetParent(h), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(h), BN_CLICKED), (LPARAM)h);
            return 0;
        }
        break;
    case WM_GETDLGCODE: return DLGC_BUTTON | DLGC_WANTCHARS;
    case TC_NAV_SET_EXPANDED:
        if (state) { state->expanded = wp ? 1 : 0; InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_SETFOCUS:
    case WM_KILLFOCUS: InvalidateRect(h, NULL, FALSE); return 0;
    case WM_SETTEXT: {
        LRESULT result = DefWindowProcW(h, msg, wp, lp); InvalidateRect(h, NULL, FALSE); return result;
    }
    case WM_PAINT: {
        PAINTSTRUCT paint; HDC dc = BeginPaint(h, &paint);
        RECT rect; GetClientRect(h, &rect);
        HWND dialog = GetParent(h);
        unsigned int background = win_fluent_color(dialog, WIN_FLUENT_COLOR_BACKGROUND);
        unsigned int surface = win_fluent_color(dialog, WIN_FLUENT_COLOR_SURFACE);
        unsigned int accent = win_fluent_color(dialog, WIN_FLUENT_COLOR_ACCENT);
        unsigned int border = win_fluent_color(dialog, WIN_FLUENT_COLOR_BORDER);
        if (state && state->hot) surface = dlg_blend_rgb(surface, accent, 7);
        if (state && state->pressed) surface = dlg_blend_rgb(surface, accent, 13);
        HBRUSH clear = CreateSolidBrush(to_cr(background)); FillRect(dc, &rect, clear); DeleteObject(clear);
        RECT card = rect; card.right -= 1; card.bottom -= 1;
        dlg_fill_round_rect(dc, &card, 16, surface, GetFocus() == h ? accent : border);

        wchar_t title[160]; GetWindowTextW(h, title, ARRAYSIZE(title));
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, to_cr(win_fluent_color(dialog, WIN_FLUENT_COLOR_TEXT)));
        RECT title_rect = { 16, 7, rect.right - 46, 29 };
        HGDIOBJ old_font = SelectObject(dc, dlg_section_font());
        DrawTextW(dc, title, -1, &title_rect, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        SetTextColor(dc, to_cr(win_fluent_color(dialog, WIN_FLUENT_COLOR_SUBTEXT)));
        SelectObject(dc, dlg_caption_font());
        RECT subtitle_rect = { 16, 27, rect.right - 46, rect.bottom - 5 };
        DrawTextW(dc, state ? state->subtitle : L"", -1, &subtitle_rect,
                  DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        SelectObject(dc, old_font);

        HPEN chevron = CreatePen(PS_SOLID, 2, to_cr(win_fluent_color(dialog, WIN_FLUENT_COLOR_SUBTEXT)));
        HGDIOBJ old_pen = SelectObject(dc, chevron);
        int cx = rect.right - 24, cy = rect.bottom / 2;
        if (state && state->expanded) {
            MoveToEx(dc, cx - 5, cy - 2, NULL); LineTo(dc, cx, cy + 3); LineTo(dc, cx + 5, cy - 2);
        } else {
            MoveToEx(dc, cx - 3, cy - 5, NULL); LineTo(dc, cx + 2, cy); LineTo(dc, cx - 3, cy + 5);
        }
        SelectObject(dc, old_pen); DeleteObject(chevron);
        if (GetFocus() == h) { RECT focus = card; InflateRect(&focus, -4, -4); DrawFocusRect(dc, &focus); }
        EndPaint(h, &paint); return 0;
    }
    }
    return DefWindowProcW(h, msg, wp, lp);
}

typedef struct {
    int checked;
    int hot;
    int pressed;
} dlg_check_state;

static LRESULT CALLBACK dlg_check_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    dlg_check_state *state = (dlg_check_state *)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (msg) {
    case WM_NCCREATE: {
        CREATESTRUCTW *create = (CREATESTRUCTW *)lp;
        state = (dlg_check_state *)calloc(1, sizeof(*state));
        if (!state) return FALSE;
        state->checked = (int)(INT_PTR)create->lpCreateParams ? 1 : 0;
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)state);
        return DefWindowProcW(h, msg, wp, lp);
    }
    case WM_NCDESTROY:
        free(state); SetWindowLongPtrW(h, GWLP_USERDATA, 0); break;
    case BM_GETCHECK: return state && state->checked ? BST_CHECKED : BST_UNCHECKED;
    case BM_SETCHECK:
        if (state) { state->checked = wp == BST_CHECKED ? 1 : 0; InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_ERASEBKGND: return 1;
    case WM_MOUSEMOVE:
        if (state && !state->hot) {
            state->hot = 1; TRACKMOUSEEVENT track = { sizeof(track), TME_LEAVE, h, 0 };
            TrackMouseEvent(&track); InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_MOUSELEAVE:
        if (state) { state->hot = 0; state->pressed = 0; InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_LBUTTONDOWN:
        if (state && IsWindowEnabled(h)) { state->pressed = 1; SetCapture(h); SetFocus(h); InvalidateRect(h, NULL, FALSE); }
        return 0;
    case WM_LBUTTONUP:
        if (state && state->pressed) {
            state->pressed = 0; ReleaseCapture();
            RECT rect; POINT point = { GET_X_LPARAM(lp), GET_Y_LPARAM(lp) }; GetClientRect(h, &rect);
            if (PtInRect(&rect, point)) {
                state->checked = !state->checked;
                SendMessageW(GetParent(h), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(h), BN_CLICKED), (LPARAM)h);
            }
            InvalidateRect(h, NULL, FALSE);
        }
        return 0;
    case WM_KEYDOWN:
        if ((wp == VK_SPACE || wp == VK_RETURN) && state && IsWindowEnabled(h)) {
            state->checked = !state->checked; InvalidateRect(h, NULL, FALSE);
            SendMessageW(GetParent(h), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(h), BN_CLICKED), (LPARAM)h);
            return 0;
        }
        break;
    case WM_GETDLGCODE: return DLGC_BUTTON | DLGC_WANTCHARS;
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
    case WM_ENABLE: InvalidateRect(h, NULL, FALSE); return 0;
    case WM_SETTEXT: {
        LRESULT result = DefWindowProcW(h, msg, wp, lp); InvalidateRect(h, NULL, FALSE); return result;
    }
    case WM_PAINT: {
        PAINTSTRUCT paint; HDC dc = BeginPaint(h, &paint);
        RECT rect; GetClientRect(h, &rect); HWND dialog = GetParent(h);
        unsigned int canvas = win_fluent_color(dialog, dlg_child_on_card(dialog, h)
            ? WIN_FLUENT_COLOR_SURFACE : WIN_FLUENT_COLOR_BACKGROUND);
        HBRUSH clear = CreateSolidBrush(to_cr(canvas)); FillRect(dc, &rect, clear); DeleteObject(clear);
        int box_size = 16, box_y = max(1, (rect.bottom - box_size) / 2);
        RECT box = { 2, box_y, 2 + box_size, box_y + box_size };
        unsigned int accent = win_fluent_color(dialog, WIN_FLUENT_COLOR_ACCENT);
        unsigned int border = win_fluent_color(dialog, WIN_FLUENT_COLOR_BORDER);
        unsigned int fill = state && state->checked ? accent : canvas;
        if (state && state->hot && !state->checked) fill = dlg_blend_rgb(canvas, accent, 8);
        dlg_fill_round_rect(dc, &box, 6, fill, state && state->checked ? accent : border);
        if (state && state->checked) {
            HPEN check = CreatePen(PS_SOLID, 2, RGB(255, 255, 255)); HGDIOBJ old_pen = SelectObject(dc, check);
            MoveToEx(dc, 6, box_y + 8, NULL); LineTo(dc, 9, box_y + 11); LineTo(dc, 15, box_y + 5);
            SelectObject(dc, old_pen); DeleteObject(check);
        }
        wchar_t label[256]; GetWindowTextW(h, label, ARRAYSIZE(label));
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, to_cr(IsWindowEnabled(h) ? win_fluent_color(dialog, WIN_FLUENT_COLOR_TEXT)
                                                   : win_fluent_color(dialog, WIN_FLUENT_COLOR_SUBTEXT)));
        HGDIOBJ old_font = SelectObject(dc, dlg_font());
        RECT text_rect = { 26, 0, rect.right, rect.bottom };
        DrawTextW(dc, label, -1, &text_rect, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        SelectObject(dc, old_font);
        if (GetFocus() == h) { RECT focus = rect; InflateRect(&focus, -1, -2); DrawFocusRect(dc, &focus); }
        EndPaint(h, &paint); return 0;
    }
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static HWND dlg_edit_inner(HWND frame) {
    return (HWND)GetPropW(frame, TC_EDIT_INNER_PROP);
}

static LRESULT CALLBACK dlg_edit_frame_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    HWND edit = dlg_edit_inner(h);
    switch (msg) {
    case WM_ERASEBKGND: return 1;
    case WM_SIZE:
        if (edit) MoveWindow(edit, 8, 3, max(1, LOWORD(lp) - 16), max(1, HIWORD(lp) - 6), TRUE);
        {
            HRGN region = CreateRoundRectRgn(0, 0, LOWORD(lp) + 1, HIWORD(lp) + 1, 10, 10);
            SetWindowRgn(h, region, TRUE);
        }
        return 0;
    case WM_SETFOCUS: if (edit) SetFocus(edit); return 0;
    case WM_LBUTTONDOWN: if (edit) SetFocus(edit); return 0;
    case WM_GETTEXT: return edit ? SendMessageW(edit, msg, wp, lp) : 0;
    case WM_GETTEXTLENGTH: return edit ? SendMessageW(edit, msg, wp, lp) : 0;
    case WM_SETTEXT: return edit ? SendMessageW(edit, msg, wp, lp) : FALSE;
    case WM_SETFONT: if (edit) SendMessageW(edit, msg, wp, lp); return 0;
    case WM_ENABLE: if (edit) EnableWindow(edit, (BOOL)wp); InvalidateRect(h, NULL, TRUE); return 0;
    case WM_COMMAND:
        if (HIWORD(wp) == EN_SETFOCUS || HIWORD(wp) == EN_KILLFOCUS) InvalidateRect(h, NULL, FALSE);
        return 0;
    case WM_CTLCOLOREDIT: {
        HDC dc = (HDC)wp;
        SetTextColor(dc, to_cr(win_fluent_color(GetParent(h), WIN_FLUENT_COLOR_TEXT)));
        SetBkColor(dc, to_cr(win_fluent_color(GetParent(h), WIN_FLUENT_COLOR_SURFACE)));
        return (LRESULT)dlg_edit_brush(GetParent(h));
    }
    case WM_PAINT: {
        PAINTSTRUCT paint; HDC dc = BeginPaint(h, &paint);
        RECT rect; GetClientRect(h, &rect); rect.right -= 1; rect.bottom -= 1;
        HWND dialog = GetParent(h);
        dlg_fill_round_rect(dc, &rect, 10,
                            win_fluent_color(dialog, WIN_FLUENT_COLOR_SURFACE),
                            edit && GetFocus() == edit ? win_fluent_color(dialog, WIN_FLUENT_COLOR_ACCENT)
                                                       : win_fluent_color(dialog, WIN_FLUENT_COLOR_BORDER));
        EndPaint(h, &paint); return 0;
    }
    case WM_NCDESTROY: RemovePropW(h, TC_EDIT_INNER_PROP); break;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static LRESULT CALLBACK dlg_separator_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    (void)lp;
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT) {
        PAINTSTRUCT paint; HDC dc = BeginPaint(h, &paint);
        RECT rect; GetClientRect(h, &rect);
        HPEN pen = CreatePen(PS_SOLID, 1, to_cr(win_fluent_color(GetParent(h), WIN_FLUENT_COLOR_BORDER)));
        HGDIOBJ old = SelectObject(dc, pen); int y = (rect.bottom - rect.top) / 2;
        MoveToEx(dc, 0, y, NULL); LineTo(dc, rect.right, y); SelectObject(dc, old); DeleteObject(pen);
        EndPaint(h, &paint); return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

typedef struct {
    int percent;
} dlg_progress_state;

static LRESULT CALLBACK dlg_progress_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    (void)wp;
    dlg_progress_state *state = (dlg_progress_state *)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (msg) {
    case WM_NCCREATE: {
        CREATESTRUCTW *create = (CREATESTRUCTW *)lp;
        state = (dlg_progress_state *)calloc(1, sizeof(*state));
        if (!state) return FALSE;
        state->percent = max(0, min(100, (int)(INT_PTR)create->lpCreateParams));
        SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)state);
        return DefWindowProcW(h, msg, wp, lp);
    }
    case WM_NCDESTROY:
        free(state); SetWindowLongPtrW(h, GWLP_USERDATA, 0); break;
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT paint; HDC dc = BeginPaint(h, &paint);
        RECT rect; GetClientRect(h, &rect);
        HWND dialog = GetParent(h);
        unsigned int canvas = win_fluent_color(dialog, WIN_FLUENT_COLOR_SURFACE);
        HBRUSH clear = CreateSolidBrush(to_cr(canvas)); FillRect(dc, &rect, clear); DeleteObject(clear);
        RECT trough = rect; trough.right -= 1; trough.bottom -= 1;
        unsigned int track = dlg_blend_rgb(
            canvas, win_fluent_color(dialog, WIN_FLUENT_COLOR_TEXT), 10
        );
        dlg_fill_round_rect(dc, &trough, max(2, rect.bottom), track, track);
        if (state && state->percent > 0) {
            RECT fill = trough;
            fill.right = max(
                fill.left + min(4, trough.right - trough.left),
                fill.left + (trough.right - trough.left) * state->percent / 100
            );
            unsigned int accent = state->percent <= 15 ? 0xef4b4bu
                                : state->percent <= 35 ? 0xf0a32fu : 0x3ac56cu;
            dlg_fill_round_rect(dc, &fill, max(2, rect.bottom), accent, accent);
        }
        EndPaint(h, &paint); return 0;
    }
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static void dlg_register_fluent_controls(void) {
    static int registered = 0;
    if (registered) return;
    WNDCLASSEXW wc = {0}; wc.cbSize = sizeof(wc); wc.hInstance = GetModuleHandleW(NULL);
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW); wc.hbrBackground = NULL;
    wc.lpfnWndProc = dlg_nav_proc; wc.lpszClassName = L"TCDialogNav"; RegisterClassExW(&wc);
    wc.lpfnWndProc = dlg_edit_frame_proc; wc.lpszClassName = L"TCEditFrame"; RegisterClassExW(&wc);
    wc.lpfnWndProc = dlg_check_proc; wc.lpszClassName = L"TCDialogCheck"; RegisterClassExW(&wc);
    wc.lpfnWndProc = dlg_separator_proc; wc.lpszClassName = L"TCDialogSeparator"; RegisterClassExW(&wc);
    wc.lpfnWndProc = dlg_progress_proc; wc.lpszClassName = L"TCDialogProgress"; RegisterClassExW(&wc);
    registered = 1;
}

static HBRUSH dlg_background_brush(HWND hwnd) {
    unsigned int rgb = win_fluent_color(hwnd, WIN_FLUENT_COLOR_BACKGROUND);
    if (!g_dlg_background_brush || rgb != g_dlg_background_rgb) {
        if (g_dlg_background_brush) DeleteObject(g_dlg_background_brush);
        g_dlg_background_brush = CreateSolidBrush(to_cr(rgb));
        g_dlg_background_rgb = rgb;
    }
    return g_dlg_background_brush;
}

static HBRUSH dlg_edit_brush(HWND hwnd) {
    unsigned int rgb = win_fluent_color(hwnd, WIN_FLUENT_COLOR_SURFACE);
    if (!g_dlg_edit_brush || rgb != g_dlg_edit_rgb) {
        if (g_dlg_edit_brush) DeleteObject(g_dlg_edit_brush);
        g_dlg_edit_brush = CreateSolidBrush(to_cr(rgb));
        g_dlg_edit_rgb = rgb;
    }
    return g_dlg_edit_brush;
}

static int dlg_child_on_card(HWND dialog, HWND child) {
    RECT child_rect;
    if (!IsWindow(child) || !GetWindowRect(child, &child_rect)) return 0;
    POINT center = { (child_rect.left + child_rect.right) / 2,
                     (child_rect.top + child_rect.bottom) / 2 };
    ScreenToClient(dialog, &center);
    dlg_visual_state *state = dlg_visual(dialog, 0);
    if (state) {
        for (int i = 0; i < state->card_count; i++) {
            RECT card = state->cards[i];
            OffsetRect(&card, 0, -state->scroll_pos);
            if (PtInRect(&card, center)) return 1;
        }
    }
    return 0;
}

static int dlg_max_scroll(HWND dialog, dlg_visual_state *state) {
    if (!state) return 0;
    RECT client; GetClientRect(dialog, &client);
    return max(0, state->content_height - (client.bottom - client.top));
}

static void dlg_apply_scroll(HWND dialog, int requested) {
    dlg_visual_state *state = dlg_visual(dialog, 0);
    if (!state) return;
    const int next = min(dlg_max_scroll(dialog, state), max(0, requested));
    if (next == state->scroll_pos) return;
    const int delta = state->scroll_pos - next;
    state->scroll_pos = next;
    SetScrollPos(dialog, SB_VERT, next, TRUE);
    for (HWND child = GetWindow(dialog, GW_CHILD); IsWindow(child); ) {
        HWND following = GetWindow(child, GW_HWNDNEXT);
        RECT rect; GetWindowRect(child, &rect);
        POINT origin = { rect.left, rect.top }; ScreenToClient(dialog, &origin);
        SetWindowPos(child, NULL, origin.x, origin.y + delta, 0, 0,
                     SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        RECT moved; GetWindowRect(child, &moved);
        POINT moved_origin = { moved.left, moved.top }; ScreenToClient(dialog, &moved_origin);
        if (moved_origin.y < 0) {
            if (IsWindowVisible(child)) {
                SetPropW(child, TC_SCROLL_CLIPPED_PROP, (HANDLE)(INT_PTR)1);
                ShowWindow(child, SW_HIDE);
            }
        } else if (GetPropW(child, TC_SCROLL_CLIPPED_PROP)) {
            RemovePropW(child, TC_SCROLL_CLIPPED_PROP);
            ShowWindow(child, SW_SHOWNA);
        }
        InvalidateRect(child, NULL, TRUE);
        child = following;
    }
    InvalidateRect(dialog, NULL, TRUE);
    UpdateWindow(dialog);
}

static void dlg_update_scroll_info(HWND dialog) {
    dlg_visual_state *state = dlg_visual(dialog, 0);
    if (!state) return;
    RECT client; GetClientRect(dialog, &client);
    SCROLLINFO info = { sizeof(info), SIF_PAGE | SIF_RANGE | SIF_POS, 0,
                        max(0, state->content_height - 1),
                        (UINT)max(1, client.bottom - client.top), state->scroll_pos, 0 };
    SetScrollInfo(dialog, SB_VERT, &info, TRUE);
    if (state->scroll_pos > dlg_max_scroll(dialog, state))
        dlg_apply_scroll(dialog, dlg_max_scroll(dialog, state));
}

static BOOL CALLBACK dlg_invalidate_child(HWND child, LPARAM erase) {
    win_fluent_theme_child(child);
    InvalidateRect(child, NULL, erase ? TRUE : FALSE);
    return TRUE;
}

static LRESULT CALLBACK dlg_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        win_fluent_apply(h, WIN_FLUENT_MICA);
        return 0;
    case WM_SIZE:
        dlg_update_scroll_info(h);
        return 0;
    case WM_VSCROLL: {
        dlg_visual_state *state = dlg_visual(h, 0);
        if (!state) break;
        SCROLLINFO info = {0};
        info.cbSize = sizeof(info);
        info.fMask = SIF_ALL;
        GetScrollInfo(h, SB_VERT, &info);
        int next = state->scroll_pos;
        switch (LOWORD(wp)) {
        case SB_LINEUP: next -= 36; break;
        case SB_LINEDOWN: next += 36; break;
        case SB_PAGEUP: next -= (int)info.nPage; break;
        case SB_PAGEDOWN: next += (int)info.nPage; break;
        case SB_THUMBPOSITION:
        case SB_THUMBTRACK: next = info.nTrackPos; break;
        case SB_TOP: next = 0; break;
        case SB_BOTTOM: next = dlg_max_scroll(h, state); break;
        default: return 0;
        }
        dlg_apply_scroll(h, next);
        return 0;
    }
    case WM_MOUSEWHEEL: {
        dlg_visual_state *state = dlg_visual(h, 0);
        if (!state || dlg_max_scroll(h, state) == 0) break;
        const int notches = GET_WHEEL_DELTA_WPARAM(wp) / WHEEL_DELTA;
        dlg_apply_scroll(h, state->scroll_pos - notches * 72);
        return 0;
    }
    case WM_ERASEBKGND: {
        /* A successful DWM backdrop attribute does not guarantee that an
         * ordinary GDI client surface is transparent.  In particular, the
         * common-controls v6 dialog surface can remain opaque white while
         * its children have already switched to a dark theme.  Paint a
         * coherent Fluent canvas ourselves; Mica remains active for the
         * non-client frame/title bar and the dialog is readable on every
         * compositor/theme combination. */
        dlg_paint_canvas(h, (HDC)wp);
        return 1;
    }
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(h, &paint);
        dlg_paint_canvas(h, dc);
        EndPaint(h, &paint);
        return 0;
    }
    case WM_CTLCOLORSTATIC: {
        HDC dc = (HDC)wp;
        HWND child = (HWND)lp;
        int role = (int)(INT_PTR)GetPropW(child, TC_TEXT_ROLE_PROP);
        int on_card = dlg_child_on_card(h, child);
        unsigned int rgb = win_fluent_color(h, role == 1
            ? WIN_FLUENT_COLOR_SUBTEXT : WIN_FLUENT_COLOR_TEXT);
        SetTextColor(dc, to_cr(rgb));
        SetBkColor(dc, to_cr(win_fluent_color(h, on_card
            ? WIN_FLUENT_COLOR_SURFACE : WIN_FLUENT_COLOR_BACKGROUND)));
        SetBkMode(dc, TRANSPARENT);
        return (LRESULT)(on_card ? dlg_edit_brush(h) : dlg_background_brush(h));
    }
    case WM_CTLCOLORBTN: {
        HDC dc = (HDC)wp;
        SetTextColor(dc, to_cr(win_fluent_color(h, WIN_FLUENT_COLOR_TEXT)));
        SetBkColor(dc, to_cr(win_fluent_color(h, WIN_FLUENT_COLOR_SURFACE)));
        SetBkMode(dc, TRANSPARENT);
        return (LRESULT)dlg_edit_brush(h);
    }
    case WM_CTLCOLOREDIT: {
        HDC dc = (HDC)wp;
        SetTextColor(dc, to_cr(win_fluent_color(h, WIN_FLUENT_COLOR_TEXT)));
        SetBkColor(dc, to_cr(win_fluent_color(h, WIN_FLUENT_COLOR_SURFACE)));
        return (LRESULT)dlg_edit_brush(h);
    }
    case WM_DRAWITEM:
        if ((DRAWITEMSTRUCT *)lp && ((DRAWITEMSTRUCT *)lp)->CtlType == ODT_BUTTON) {
            dlg_draw_owner_button(h, (DRAWITEMSTRUCT *)lp); return TRUE;
        }
        break;
    case WM_SETTINGCHANGE:
    case WM_SYSCOLORCHANGE:
    case WM_THEMECHANGED:
        win_fluent_apply(h, WIN_FLUENT_MICA);
        EnumChildWindows(h, dlg_invalidate_child, (LPARAM)TRUE);
        InvalidateRect(h, NULL, TRUE);
        return 0;
    case WM_COMMAND:
        /* Keep the HWND and its child controls alive until Swift has read their
         * values after dlg_modal returns.  The caller owns final destruction. */
        if (LOWORD(wp) == 1 || LOWORD(wp) == 2) {
            dlg_visual_state *state = dlg_visual(h, 1);
            if (state) { state->modal_result = LOWORD(wp) == 1 ? 1 : 0; state->modal_done = 1; }
            ShowWindow(h, SW_HIDE); return 0;
        }
        if (g_dlg_oncmd) g_dlg_oncmd(g_dlg_cmdctx, (int)LOWORD(wp));   /* 其余按钮 → 回调 */
        return 0;
    case WM_CLOSE:
        {
            dlg_visual_state *state = dlg_visual(h, 1);
            if (state) { state->modal_result = 0; state->modal_done = 1; }
            ShowWindow(h, SW_HIDE); return 0;
        }
    case WM_NCDESTROY:
        free((dlg_visual_state *)RemovePropW(h, TC_DIALOG_VISUAL_PROP));
        win_fluent_forget(h);
        break;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static HFONT dlg_font(void) {
    static HFONT f = NULL;
    if (!f) f = CreateFontW(-16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_SWISS, L"Segoe UI Variable Text");
    return f;
}

static HFONT dlg_title_font(void) {
    static HFONT f = NULL;
    if (!f) f = CreateFontW(-22, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_SWISS, L"Segoe UI Variable Display");
    return f;
}

static HFONT dlg_section_font(void) {
    static HFONT f = NULL;
    if (!f) f = CreateFontW(-16, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_SWISS, L"Segoe UI Variable Text");
    return f;
}

static HFONT dlg_caption_font(void) {
    static HFONT f = NULL;
    if (!f) f = CreateFontW(-14, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_SWISS, L"Segoe UI Variable Text");
    return f;
}

static HWND dlg_child_ex(HWND dlg, DWORD ex_style, const wchar_t *cls, DWORD style, int id,
                         const wchar_t *text, int x, int y, int w, int h) {
    HWND c = CreateWindowExW(ex_style, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h,
                             (HWND)dlg, (HMENU)(LONG_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)dlg_font(), TRUE);
    win_fluent_theme_child(c);
    return c;
}

static HWND dlg_child(HWND dlg, const wchar_t *cls, DWORD style, int id,
                      const wchar_t *text, int x, int y, int w, int h) {
    return dlg_child_ex(dlg, 0, cls, style, id, text, x, y, w, h);
}

void *dlg_create(const char *title_utf8, int w, int h) {
    static int registered = 0;
    if (!registered) {
        WNDCLASSEXW wc = {0};
        wc.cbSize = sizeof(wc); wc.lpfnWndProc = dlg_proc;
        wc.hInstance = GetModuleHandleW(NULL); wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
        wc.hbrBackground = NULL; wc.lpszClassName = L"TCDialog";
        RegisterClassExW(&wc); registered = 1;
    }
    dlg_register_fluent_controls();
    wchar_t title[256];
    if (to_wide(title_utf8, title, 256) == 0) title[0] = 0;
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    HWND owner = IsWindow(g_dlg) && IsWindowVisible(g_dlg)
        ? g_dlg : (IsWindow(g_hwnd) ? g_hwnd : NULL);
    HWND hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, L"TCDialog", title,
                                WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN,
                                (sw - w) / 2, (sh - h) / 2, w, h,
                                owner, NULL, GetModuleHandleW(NULL), NULL);
    g_dlg = hwnd;
    dlg_visual_state *state = dlg_visual(hwnd, 1);
    if (state) { state->modal_done = 0; state->modal_result = 0; }
    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
    return hwnd;
}

void dlg_add_check(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h, int checked) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    CreateWindowExW(0, L"TCDialogCheck", t, WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                    x, y, w, h, (HWND)dlg, (HMENU)(LONG_PTR)id,
                    GetModuleHandleW(NULL), (void *)(INT_PTR)(checked ? 1 : 0));
}

void dlg_add_edit(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[1024]; if (to_wide(text_utf8, t, 1024) == 0) t[0] = 0;
    HWND frame = CreateWindowExW(0, L"TCEditFrame", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                                  x, y, w, h, (HWND)dlg, (HMENU)(LONG_PTR)id,
                                  GetModuleHandleW(NULL), NULL);
    HWND edit = CreateWindowExW(0, L"EDIT", t, WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
                                 8, 3, max(1, w - 16), max(1, h - 6), frame,
                                 (HMENU)(LONG_PTR)1, GetModuleHandleW(NULL), NULL);
    SetPropW(frame, TC_EDIT_INNER_PROP, edit);
    SendMessageW(edit, WM_SETFONT, (WPARAM)dlg_font(), TRUE);
    win_fluent_theme_child(edit);
    SendMessageW(frame, WM_SIZE, 0, MAKELPARAM(w, h));
}

void dlg_add_static(void *dlg, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    dlg_child((HWND)dlg, L"STATIC", SS_LEFT, 0, t, x, y, w, h);
}

/* 同 dlg_add_static，但携带 id：dlg_set_text 可在运行时改写文案（如价格目录状态行）。 */
void *dlg_add_static_id(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    return dlg_child((HWND)dlg, L"STATIC", SS_LEFT, id, t, x, y, w, h);
}

void dlg_add_title(void *dlg, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    HWND c = dlg_child((HWND)dlg, L"STATIC", SS_LEFT, 0, t, x, y, w, h);
    SendMessageW(c, WM_SETFONT, (WPARAM)dlg_title_font(), TRUE);
}

void dlg_add_subtitle(void *dlg, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[512]; if (to_wide(text_utf8, t, 512) == 0) t[0] = 0;
    HWND c = dlg_child((HWND)dlg, L"STATIC", SS_LEFT, 0, t, x, y, w, h);
    SetPropW(c, TC_TEXT_ROLE_PROP, (HANDLE)(INT_PTR)1);
    SendMessageW(c, WM_SETFONT, (WPARAM)dlg_caption_font(), TRUE);
}

void dlg_add_section(void *dlg, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    HWND c = dlg_child((HWND)dlg, L"STATIC", SS_LEFT, 0, t, x, y, w, h);
    SetPropW(c, TC_TEXT_ROLE_PROP, (HANDLE)(INT_PTR)2);
    SendMessageW(c, WM_SETFONT, (WPARAM)dlg_section_font(), TRUE);
}

void dlg_add_card(void *dlg, int x, int y, int w, int h) {
    HWND dialog = (HWND)dlg;
    dlg_visual_state *state = dlg_visual(dialog, 1);
    if (!state || state->card_count >= (int)ARRAYSIZE(state->cards)) return;
    RECT card = { x, y, x + w, y + h };
    state->cards[state->card_count++] = card;
    InvalidateRect(dialog, &card, TRUE);
}

void dlg_add_progress(void *dlg, int x, int y, int w, int h, int percent) {
    CreateWindowExW(0, L"TCDialogProgress", L"", WS_CHILD | WS_VISIBLE,
                    x, y, w, h, (HWND)dlg, NULL, GetModuleHandleW(NULL),
                    (void *)(INT_PTR)max(0, min(100, percent)));
}

void dlg_add_nav(void *dlg, int id, const char *title_utf8, const char *subtitle_utf8,
                 int x, int y, int w, int h) {
    wchar_t title[256], subtitle[512];
    if (to_wide(title_utf8, title, 256) == 0) title[0] = 0;
    if (to_wide(subtitle_utf8, subtitle, 512) == 0) subtitle[0] = 0;
    CreateWindowExW(0, L"TCDialogNav", title, WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                    x, y, w, h, (HWND)dlg, (HMENU)(LONG_PTR)id,
                    GetModuleHandleW(NULL), subtitle);
}

void dlg_add_disclosure(void *dlg, int id, const char *title_utf8, const char *subtitle_utf8,
                        int x, int y, int w, int h, int expanded) {
    dlg_add_nav(dlg, id, title_utf8, subtitle_utf8, x, y, w, h);
    HWND control = GetDlgItem((HWND)dlg, id);
    if (IsWindow(control)) SendMessageW(control, TC_NAV_SET_EXPANDED, expanded ? 1 : 0, 0);
}

void dlg_add_sep(void *dlg, int x, int y, int w) {
    CreateWindowExW(WS_EX_TRANSPARENT, L"TCDialogSeparator", L"", WS_CHILD | WS_VISIBLE | WS_DISABLED,
                    x, y, w, 1, (HWND)dlg, NULL, GetModuleHandleW(NULL), NULL);
}

void dlg_add_push(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    dlg_child((HWND)dlg, L"BUTTON", BS_OWNERDRAW | WS_TABSTOP, id, t, x, y, w, h);
}

void dlg_add_tooltip(void *dlg, int control_id, const char *text_utf8) {
    HWND dialog = (HWND)dlg;
    HWND control = dialog ? GetDlgItem(dialog, control_id) : NULL;
    if (!dialog || !control || !text_utf8 || !text_utf8[0]) return;
    HWND tooltip = CreateWindowExW(
        WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL,
        WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX,
        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
        dialog, NULL, GetModuleHandleW(NULL), NULL
    );
    if (!tooltip) return;
    wchar_t buffer[2048];
    if (to_wide(text_utf8, buffer, 2048) == 0) return;
    wchar_t *text = _wcsdup(buffer);
    if (!text) return;
    TOOLINFOW info = {0};
    info.cbSize = sizeof(info);
    info.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
    info.hwnd = dialog;
    info.uId = (UINT_PTR)control;
    info.lpszText = text;
    SendMessageW(tooltip, TTM_SETMAXTIPWIDTH, 0, 520);
    SendMessageW(tooltip, TTM_ADDTOOLW, 0, (LPARAM)&info);
}

static LRESULT CALLBACK brand_logo_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    (void)lp;
    if (msg == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        int width = rc.right - rc.left, height = rc.bottom - rc.top;
        int radius = (min(width, height) - 8) / 2;
        int cx = width / 2, cy = height / 2;
        unsigned int face_rgb = win_fluent_color(GetParent(h), WIN_FLUENT_COLOR_SURFACE);
        unsigned int text_rgb = win_fluent_color(GetParent(h), WIN_FLUENT_COLOR_TEXT);
        win_fluent_paint_parent(h, dc, &rc);
        HBRUSH face = CreateSolidBrush(to_cr(face_rgb));
        HPEN rim = CreatePen(PS_SOLID, 3, to_cr(text_rgb));
        HGDIOBJ oldBrush = SelectObject(dc, face), oldPen = SelectObject(dc, rim);
        Ellipse(dc, cx - radius, cy - radius, cx + radius, cy + radius);
        SelectObject(dc, GetStockObject(NULL_BRUSH));
        HPEN hour = CreatePen(PS_SOLID, 5, to_cr(text_rgb));
        SelectObject(dc, hour); MoveToEx(dc, cx, cy, NULL); LineTo(dc, cx - radius / 3, cy - radius / 3);
        HPEN minute = CreatePen(PS_SOLID, 3, to_cr(text_rgb));
        SelectObject(dc, minute); MoveToEx(dc, cx, cy, NULL); LineTo(dc, cx - radius / 8, cy + radius / 2);
        HPEN second = CreatePen(PS_SOLID, 2, RGB(231, 74, 60));
        SelectObject(dc, second); MoveToEx(dc, cx, cy, NULL); LineTo(dc, cx + radius / 2, cy - radius / 3);
        HBRUSH cap = CreateSolidBrush(to_cr(text_rgb)); SelectObject(dc, cap); SelectObject(dc, GetStockObject(NULL_PEN));
        Ellipse(dc, cx - 4, cy - 4, cx + 4, cy + 4);
        SelectObject(dc, oldBrush); SelectObject(dc, oldPen);
        DeleteObject(face); DeleteObject(rim); DeleteObject(hour); DeleteObject(minute); DeleteObject(second); DeleteObject(cap);
        EndPaint(h, &ps); return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

void dlg_add_brand_logo(void *dlg, int x, int y, int w, int h) {
    static int registered = 0;
    if (!registered) {
        WNDCLASSEXW wc = {0}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = brand_logo_proc;
        wc.hInstance = GetModuleHandleW(NULL); wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
        wc.hbrBackground = NULL; wc.lpszClassName = L"TCBrandLogo";
        RegisterClassExW(&wc); registered = 1;
    }
    CreateWindowExW(WS_EX_TRANSPARENT, L"TCBrandLogo", L"", WS_CHILD | WS_VISIBLE,
                    x, y, w, h, (HWND)dlg, NULL, GetModuleHandleW(NULL), NULL);
}

int dlg_check_get(void *dlg, int id) {
    return IsDlgButtonChecked((HWND)dlg, id) == BST_CHECKED ? 1 : 0;
}

void dlg_set_check(void *dlg, int id, int checked) {
    CheckDlgButton((HWND)dlg, id, checked ? BST_CHECKED : BST_UNCHECKED);
}

void dlg_edit_get(void *dlg, int id, char *buf_utf8, int n) {
    wchar_t w[1024];
    GetDlgItemTextW((HWND)dlg, id, w, 1024);
    if (n > 0) buf_utf8[0] = 0;
    WideCharToMultiByte(CP_UTF8, 0, w, -1, buf_utf8, n, NULL, NULL);
}

int dlg_modal(void *dlg) {
    HWND hwnd = (HWND)dlg;
    dlg_visual_state *state = dlg_visual(hwnd, 1);
    if (!state) return 0;
    state->modal_done = 0;
    state->modal_result = 0;
    HWND owner = GetWindow(hwnd, GW_OWNER);
    if (IsWindow(owner)) EnableWindow(owner, FALSE);
    SetForegroundWindow(hwnd);
    SetFocus(hwnd);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (state->modal_done) break;
        if (IsWindow(hwnd) && IsDialogMessageW(hwnd, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (state->modal_done) break;
    }
    if (IsWindow(owner)) {
        EnableWindow(owner, TRUE);
        SetForegroundWindow(owner);
    }
    return state->modal_result;
}

void dlg_end(void *dlg, int result) {
    HWND hwnd = (HWND)dlg;
    if (!IsWindow(hwnd)) return;
    dlg_visual_state *state = dlg_visual(hwnd, 1);
    if (state) { state->modal_result = result ? 1 : 0; state->modal_done = 1; }
    ShowWindow(hwnd, SW_HIDE);
}

void dlg_destroy(void *dlg) {
    HWND hwnd = (HWND)dlg;
    if (IsWindow(hwnd)) DestroyWindow(hwnd);
    if (g_dlg == hwnd) g_dlg = NULL;
}

void dlg_post_command(void *dlg, int id) {
    HWND hwnd = (HWND)dlg;
    if (IsWindow(hwnd)) PostMessageW(hwnd, WM_COMMAND, MAKEWPARAM(id, BN_CLICKED), 0);
}

void dlg_set_text(void *dlg, int id, const char *text_utf8) {
    wchar_t w[256];
    if (to_wide(text_utf8, w, 256) == 0) w[0] = 0;
    SetDlgItemTextW((HWND)dlg, id, w);
}

void dlg_show_control(void *dlg, int id, int show) {
    HWND control = GetDlgItem((HWND)dlg, id);
    if (IsWindow(control)) ShowWindow(control, show ? SW_SHOW : SW_HIDE);
}

void dlg_reset_content(void *dlg, int content_height) {
    HWND dialog = (HWND)dlg;
    if (!IsWindow(dialog)) return;
    HWND child;
    while ((child = GetWindow(dialog, GW_CHILD)) != NULL) DestroyWindow(child);
    dlg_visual_state *state = dlg_visual(dialog, 1);
    if (!state) return;
    state->card_count = 0;
    state->scroll_pos = 0;
    state->content_height = max(1, content_height);
    RECT client; GetClientRect(dialog, &client);
    LONG_PTR style = GetWindowLongPtrW(dialog, GWL_STYLE);
    if (state->content_height > client.bottom - client.top) style |= WS_VSCROLL;
    else style &= ~((LONG_PTR)WS_VSCROLL);
    SetWindowLongPtrW(dialog, GWL_STYLE, style);
    SetWindowPos(dialog, NULL, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    dlg_update_scroll_info(dialog);
    InvalidateRect(dialog, NULL, TRUE);
}

void dlg_scroll_to(void *dlg, int y) {
    HWND dialog = (HWND)dlg;
    if (IsWindow(dialog)) dlg_apply_scroll(dialog, y);
}

int dlg_modal_cb(void *dlg, dlg_on_cmd_t on_cmd, void *ctx) {
    dlg_on_cmd_t previous_oncmd = g_dlg_oncmd;
    void *previous_ctx = g_dlg_cmdctx;
    g_dlg_oncmd = on_cmd;
    g_dlg_cmdctx = ctx;
    int r = dlg_modal(dlg);
    g_dlg_oncmd = previous_oncmd;
    g_dlg_cmdctx = previous_ctx;
    return r;
}

int win_pick_color(unsigned int initial_argb, unsigned int *out_argb) {
    static COLORREF cust[16] = { 0 };
    COLORREF ini = RGB((initial_argb >> 16) & 0xff, (initial_argb >> 8) & 0xff, initial_argb & 0xff);
    CHOOSECOLORW cc;
    memset(&cc, 0, sizeof(cc));
    cc.lStructSize = sizeof(cc);
    cc.Flags = CC_FULLOPEN | CC_RGBINIT;
    cc.rgbResult = ini;
    cc.lpCustColors = cust;
    if (!ChooseColorW(&cc)) return 0;
    /* COLORREF 0x00BBGGRR → ARGB 0xFFRRGGBB */
    *out_argb = 0xFF000000u | ((cc.rgbResult & 0xFF) << 16) | (cc.rgbResult & 0xFF00) | ((cc.rgbResult >> 16) & 0xFF);
    return 1;
}

static int CALLBACK browse_folder_cb(HWND h, UINT msg, LPARAM lp, LPARAM data) {
    (void)lp;
    if (msg == BFFM_INITIALIZED && data) {
        SendMessageW(h, BFFM_SETSELECTIONW, TRUE, data);
    }
    return 0;
}

int win_pick_folder(void *owner, const char *title_utf8, const char *initial_utf8,
                    char *out_utf8, int out_size) {
    if (!out_utf8 || out_size <= 0) return 0;
    out_utf8[0] = 0;
    wchar_t title[256], initial[MAX_PATH], selected[MAX_PATH];
    if (to_wide(title_utf8, title, 256) == 0) title[0] = 0;
    if (to_wide(initial_utf8, initial, MAX_PATH) == 0) initial[0] = 0;
    BROWSEINFOW bi = {0};
    bi.hwndOwner = (HWND)owner;
    bi.lpszTitle = title;
    bi.ulFlags = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX;
    bi.lpfn = browse_folder_cb;
    bi.lParam = (LPARAM)initial;
    PIDLIST_ABSOLUTE pidl = SHBrowseForFolderW(&bi);
    if (!pidl) return 0;
    BOOL ok = SHGetPathFromIDListW(pidl, selected);
    CoTaskMemFree((LPVOID)pidl);
    if (!ok) return 0;
    return WideCharToMultiByte(CP_UTF8, 0, selected, -1, out_utf8, out_size, NULL, NULL) > 0 ? 1 : 0;
}

/* --- GDI helpers --- */
void gdi_clear(void *hdc, int w, int h, unsigned int rgb) {
    RECT rc = {0, 0, w, h};
    HBRUSH br = CreateSolidBrush(to_cr(rgb));
    FillRect((HDC)hdc, &rc, br);
    DeleteObject(br);
}
void gdi_fill_circle(void *hdc, int cx, int cy, int r,
                     unsigned int fill, unsigned int stroke, int pen_w) {
    HBRUSH br = CreateSolidBrush(to_cr(fill));
    HPEN pen = CreatePen(PS_SOLID, pen_w, to_cr(stroke));
    HGDIOBJ ob = SelectObject((HDC)hdc, br);   /* Ellipse uses current pen (outline) + brush (fill) */
    HGDIOBJ op = SelectObject((HDC)hdc, pen);
    Ellipse((HDC)hdc, cx - r, cy - r, cx + r, cy + r);
    SelectObject((HDC)hdc, ob);
    SelectObject((HDC)hdc, op);
    DeleteObject(br); DeleteObject(pen);
}
void gdi_circle(void *hdc, int cx, int cy, int r, unsigned int stroke, int pen_w) {
    HPEN pen = CreatePen(PS_SOLID, pen_w, to_cr(stroke));
    HPEN op = SelectObject((HDC)hdc, pen);
    HBRUSH ob = SelectObject((HDC)hdc, GetStockObject(NULL_BRUSH));
    Ellipse((HDC)hdc, cx - r, cy - r, cx + r, cy + r);
    SelectObject((HDC)hdc, ob);
    SelectObject((HDC)hdc, op);
    DeleteObject(pen);
}
void gdi_line(void *hdc, int x1, int y1, int x2, int y2, int width, unsigned int rgb) {
    HPEN pen = CreatePen(PS_SOLID, width, to_cr(rgb));
    HPEN op = SelectObject((HDC)hdc, pen);
    MoveToEx((HDC)hdc, x1, y1, NULL);
    LineTo((HDC)hdc, x2, y2);
    SelectObject((HDC)hdc, op);
    DeleteObject(pen);
}
void gdi_text_center(void *hdc, int cx, int cy, const char *text_utf8,
                     int size_pt, unsigned int rgb, int bold) {
    wchar_t wbuf[256];
    if (to_wide(text_utf8, wbuf, 256) == 0) return;
    int n = (int)wcslen(wbuf);
    int hpx = -MulDiv(size_pt, GetDeviceCaps((HDC)hdc, LOGPIXELSY), 72);
    HFONT f = CreateFontW(hpx, 0, 0, 0, bold ? FW_BOLD : FW_NORMAL, FALSE, FALSE, FALSE,
                          DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                          CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HFONT of = SelectObject((HDC)hdc, f);
    SetBkMode((HDC)hdc, TRANSPARENT);
    SetTextColor((HDC)hdc, to_cr(rgb));
    SIZE sz; GetTextExtentPoint32W((HDC)hdc, wbuf, n, &sz);
    RECT rc = { cx - sz.cx / 2, cy - sz.cy / 2, cx - sz.cx / 2 + sz.cx, cy - sz.cy / 2 + sz.cy };
    DrawTextW((HDC)hdc, wbuf, n, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
    SelectObject((HDC)hdc, of);
    DeleteObject(f);
}

/* --- popup menu --- */
void *menu_create(void) { return CreatePopupMenu(); }
void menu_add_item(void *hmenu, int cmd_id, const char *label_utf8, int checked) {
    wchar_t wbuf[256];
    if (to_wide(label_utf8, wbuf, 256) == 0) { wbuf[0] = L'?'; wbuf[1] = 0; }
    UINT flags = MF_STRING | (checked ? MF_CHECKED : 0);
    AppendMenuW((HMENU)hmenu, flags, (UINT_PTR)cmd_id, wbuf);
}
void menu_add_separator(void *hmenu) { AppendMenuW((HMENU)hmenu, MF_SEPARATOR, 0, NULL); }
void menu_add_submenu(void *hmenu, const char *label_utf8, void *sub) {
    wchar_t wbuf[256];
    if (to_wide(label_utf8, wbuf, 256) == 0) { wbuf[0] = L'?'; wbuf[1] = 0; }
    AppendMenuW((HMENU)hmenu, MF_POPUP, (UINT_PTR)sub, wbuf);
}
void menu_track(void *hmenu, void *hwnd) {
    POINT pt; GetCursorPos(&pt);
    SetForegroundWindow((HWND)hwnd);
    TrackPopupMenu((HMENU)hmenu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, (HWND)hwnd, NULL);
}
void menu_show_at(void *menu, void *hwnd, int x, int y) {
    SetForegroundWindow((HWND)hwnd);
    TrackPopupMenu((HMENU)menu, TPM_LEFTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN, x, y, 0, (HWND)hwnd, NULL);
}
