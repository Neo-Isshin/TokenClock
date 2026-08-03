/* winshim.c — Win32 boilerplate driven by Swift callbacks (see winshim.h).
 * Owns: window class, topmost borderless layered tool window, system-tray icon,
 * 1s clock timer + data-scan timer, popup menu, paint dispatch, GDI helpers. */
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include "winshim.h"

#define IDM_TICK   1001
#define IDM_SCAN   1002
#define WM_TRAY    (WM_APP + 1)

static win_callbacks g_cb;
static HWND  g_hwnd = NULL;
static UINT  g_taskbar_created = 0;   /* registered msg: explorer restarted */

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
    wcscpy(nid.szTip, L"TokenClock");
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

static LRESULT CALLBACK wnd_proc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        g_hwnd = h;
        if (g_cb.initial_opacity < 1.0)
            SetLayeredWindowAttributes(h, 0, (BYTE)(g_cb.initial_opacity * 255.0), LWA_ALPHA);
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
                /* Build + show the context menu at the cursor. */
                HMENU hmenu = CreatePopupMenu();
                if (g_cb.on_build_menu) g_cb.on_build_menu(g_cb.ctx, hmenu);
                POINT pt; GetCursorPos(&pt);
                SetForegroundWindow(h);   /* needed so menu dismisses on click-away */
                TrackPopupMenu(hmenu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0, h, NULL);
                DestroyMenu(hmenu);
                break;
            }
            }
        }
        return 0;

    case WM_COMMAND:
        if (g_cb.on_menu_cmd) g_cb.on_menu_cmd(g_cb.ctx, (int)LOWORD(wp));
        return 0;

    case WM_NCHITTEST:
        return HTCAPTION;   /* whole window is draggable */

    case g_taskbar_created:   /* explorer restarted: re-add the tray icon */
        add_tray();
        return 0;

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

    HWND hwnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED,
        wc.lpszClassName,
        cb->window_title ? cb->window_title : L"TokenClock",
        WS_POPUP,
        (sw - w) / 2, (sh - h) / 2, w, h,
        NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) return 1;

    ShowWindow(hwnd, SW_SHOWNORMAL);
    UpdateWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

/* --- window control --- */
void win_invalidate(void *hwnd)      { InvalidateRect((HWND)hwnd, NULL, FALSE); }
void win_set_opacity(void *hwnd, double a) {
    if (a >= 1.0) { SetWindowLongPtrW((HWND)hwnd, GWL_EXSTYLE,
                      GetWindowLongPtrW((HWND)hwnd, GWL_EXSTYLE) & ~WS_EX_LAYERED); }
    else { SetWindowLongPtrW((HWND)hwnd, GWL_EXSTYLE,
                      GetWindowLongPtrW((HWND)hwnd, GWL_EXSTYLE) | WS_EX_LAYERED);
           SetLayeredWindowAttributes((HWND)hwnd, 0, (BYTE)(a * 255.0), LWA_ALPHA); }
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
