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
        RECT client; GetClientRect(h, &client);
        g_mouse_down = 1; g_mouse_dragged = 0;
        /* normal layout: panel width = dial diameter + 80 transparent side margin */
        g_mouse_can_drag = GET_Y_LPARAM(lp) < min(client.bottom - client.top, client.right - client.left - 80);
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

    case WM_NCHITTEST:
        return HTCLIENT;    /* manual drag preserves click interaction */

    case WM_DESTROY:
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
    win_render_set_opacity(a);
    InvalidateRect((HWND)hwnd, NULL, FALSE);
}
void win_resize(void *hwnd, int w, int h) { SetWindowPos((HWND)hwnd, NULL, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER); }
void win_get_pos(void *hwnd, int *x, int *y) { RECT rc; GetWindowRect((HWND)hwnd, &rc); if (x) *x = rc.left; if (y) *y = rc.top; }
void win_set_pos(void *hwnd, int x, int y)  { SetWindowPos((HWND)hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER); }
void win_show(void *hwnd, int show)         { ShowWindowAsync((HWND)hwnd, show ? SW_SHOWNORMAL : SW_HIDE); }
void win_quit(void *hwnd)                   { PostMessageW((HWND)hwnd, WM_CLOSE, 0, 0); }
void win_set_dpi_aware(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
}
void *win_self(void) { return g_hwnd; }
void win_set_topmost(void *hwnd, int topmost) {
    SetWindowPos((HWND)hwnd, topmost ? HWND_TOPMOST : HWND_NOTOPMOST,
                 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

int win_clipboard_set_text(const char *text_utf8) {
    if (!text_utf8) return 0;
    int chars = MultiByteToWideChar(CP_UTF8, 0, text_utf8, -1, NULL, 0);
    if (chars <= 0 || !OpenClipboard(g_hwnd)) return 0;
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
static int  g_dlg_result = 0;
static int  g_dlg_done = 0;
static dlg_on_cmd_t g_dlg_oncmd = NULL;
static void *g_dlg_cmdctx = NULL;

static LRESULT CALLBACK dlg_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_COMMAND:
        /* Keep the HWND and its child controls alive until Swift has read their
         * values after dlg_modal returns.  The caller owns final destruction. */
        if (LOWORD(wp) == 1) { g_dlg_result = 1; g_dlg_done = 1; ShowWindow(h, SW_HIDE); return 0; }  /* OK */
        if (LOWORD(wp) == 2) { g_dlg_result = 0; g_dlg_done = 1; ShowWindow(h, SW_HIDE); return 0; }  /* Cancel */
        if (g_dlg_oncmd) g_dlg_oncmd(g_dlg_cmdctx, (int)LOWORD(wp));   /* 其余按钮 → 回调 */
        return 0;
    case WM_CLOSE:
        g_dlg_result = 0; g_dlg_done = 1; ShowWindow(h, SW_HIDE); return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

static HFONT dlg_font(void) {
    static HFONT f = NULL;
    if (!f) f = CreateFontW(15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    return f;
}

static HWND dlg_child(HWND dlg, const wchar_t *cls, DWORD style, int id,
                      const wchar_t *text, int x, int y, int w, int h) {
    HWND c = CreateWindowExW(0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h,
                             (HWND)dlg, (HMENU)(LONG_PTR)id, GetModuleHandleW(NULL), NULL);
    SendMessageW(c, WM_SETFONT, (WPARAM)dlg_font(), TRUE);
    return c;
}

void *dlg_create(const char *title_utf8, int w, int h) {
    static int registered = 0;
    if (!registered) {
        WNDCLASSEXW wc = {0};
        wc.cbSize = sizeof(wc); wc.lpfnWndProc = dlg_proc;
        wc.hInstance = GetModuleHandleW(NULL); wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1); wc.lpszClassName = L"TCDialog";
        RegisterClassExW(&wc); registered = 1;
    }
    wchar_t title[256];
    if (to_wide(title_utf8, title, 256) == 0) title[0] = 0;
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    HWND hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, L"TCDialog", title,
                                WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                                (sw - w) / 2, (sh - h) / 2, w, h,
                                IsWindow(g_hwnd) ? g_hwnd : NULL, NULL, GetModuleHandleW(NULL), NULL);
    g_dlg = hwnd; g_dlg_done = 0; g_dlg_result = 0;
    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);
    return hwnd;
}

void dlg_add_check(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h, int checked) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    HWND c = dlg_child((HWND)dlg, L"BUTTON", BS_AUTOCHECKBOX, id, t, x, y, w, h);
    SendMessageW(c, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
}

void dlg_add_edit(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[1024]; if (to_wide(text_utf8, t, 1024) == 0) t[0] = 0;
    dlg_child((HWND)dlg, L"EDIT", ES_AUTOHSCROLL | WS_BORDER, id, t, x, y, w, h);
}

void dlg_add_static(void *dlg, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    dlg_child((HWND)dlg, L"STATIC", SS_LEFT, 0, t, x, y, w, h);
}

void dlg_add_title(void *dlg, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    HWND c = dlg_child((HWND)dlg, L"STATIC", SS_LEFT, 0, t, x, y, w, h);
    HFONT f = CreateFontW(20, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                          OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                          DEFAULT_PITCH | FF_SWISS, L"Segoe UI Semibold");
    SendMessageW(c, WM_SETFONT, (WPARAM)f, TRUE);
}

void dlg_add_sep(void *dlg, int x, int y, int w) {
    dlg_child((HWND)dlg, L"STATIC", SS_ETCHEDHORZ, 0, L"", x, y, w, 2);
}

void dlg_add_push(void *dlg, int id, const char *text_utf8, int x, int y, int w, int h) {
    wchar_t t[256]; if (to_wide(text_utf8, t, 256) == 0) t[0] = 0;
    dlg_child((HWND)dlg, L"BUTTON", BS_PUSHBUTTON, id, t, x, y, w, h);
}

static LRESULT CALLBACK brand_logo_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    (void)lp;
    if (msg == WM_PAINT) {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        int width = rc.right - rc.left, height = rc.bottom - rc.top;
        int radius = (min(width, height) - 8) / 2;
        int cx = width / 2, cy = height / 2;
        HBRUSH bg = CreateSolidBrush(RGB(244, 244, 246));
        FillRect(dc, &rc, bg); DeleteObject(bg);
        HBRUSH face = CreateSolidBrush(RGB(247, 247, 250));
        HPEN rim = CreatePen(PS_SOLID, 3, RGB(48, 48, 54));
        HGDIOBJ oldBrush = SelectObject(dc, face), oldPen = SelectObject(dc, rim);
        Ellipse(dc, cx - radius, cy - radius, cx + radius, cy + radius);
        SelectObject(dc, GetStockObject(NULL_BRUSH));
        HPEN hour = CreatePen(PS_SOLID, 5, RGB(48, 48, 54));
        SelectObject(dc, hour); MoveToEx(dc, cx, cy, NULL); LineTo(dc, cx - radius / 3, cy - radius / 3);
        HPEN minute = CreatePen(PS_SOLID, 3, RGB(48, 48, 54));
        SelectObject(dc, minute); MoveToEx(dc, cx, cy, NULL); LineTo(dc, cx - radius / 8, cy + radius / 2);
        HPEN second = CreatePen(PS_SOLID, 2, RGB(231, 74, 60));
        SelectObject(dc, second); MoveToEx(dc, cx, cy, NULL); LineTo(dc, cx + radius / 2, cy - radius / 3);
        HBRUSH cap = CreateSolidBrush(RGB(48, 48, 54)); SelectObject(dc, cap); SelectObject(dc, GetStockObject(NULL_PEN));
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
        wc.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1); wc.lpszClassName = L"TCBrandLogo";
        RegisterClassExW(&wc); registered = 1;
    }
    CreateWindowExW(0, L"TCBrandLogo", L"", WS_CHILD | WS_VISIBLE,
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
    HWND owner = GetWindow(hwnd, GW_OWNER);
    if (IsWindow(owner)) EnableWindow(owner, FALSE);
    SetForegroundWindow(hwnd);
    SetFocus(hwnd);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        if (g_dlg_done) break;
        if (IsWindow(hwnd) && IsDialogMessageW(hwnd, &msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (g_dlg_done) break;
    }
    if (IsWindow(owner)) {
        EnableWindow(owner, TRUE);
        SetForegroundWindow(owner);
    }
    return g_dlg_result;
}

void dlg_end(void *dlg, int result) {
    HWND hwnd = (HWND)dlg;
    if (!IsWindow(hwnd)) return;
    g_dlg_result = result ? 1 : 0;
    g_dlg_done = 1;
    ShowWindow(hwnd, SW_HIDE);
}

void dlg_destroy(void *dlg) {
    HWND hwnd = (HWND)dlg;
    if (IsWindow(hwnd)) DestroyWindow(hwnd);
    if (g_dlg == hwnd) g_dlg = NULL;
}

void dlg_set_text(void *dlg, int id, const char *text_utf8) {
    wchar_t w[256];
    if (to_wide(text_utf8, w, 256) == 0) w[0] = 0;
    SetDlgItemTextW((HWND)dlg, id, w);
}

int dlg_modal_cb(void *dlg, dlg_on_cmd_t on_cmd, void *ctx) {
    g_dlg_oncmd = on_cmd;
    g_dlg_cmdctx = ctx;
    int r = dlg_modal(dlg);
    g_dlg_oncmd = NULL;
    g_dlg_cmdctx = NULL;
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
