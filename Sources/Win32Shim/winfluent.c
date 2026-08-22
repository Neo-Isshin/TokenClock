/* winfluent.c — small, runtime-detected Windows 11 Fluent material layer.
 *
 * Keep this implementation Win32-only: TokenClock does not need the Windows
 * App SDK merely to use documented DWM system backdrops.  All newer DWM calls
 * and attributes are guarded so the same binary keeps working on Windows 10.
 */
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "winshim.h"

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_BORDER_COLOR
#define DWMWA_BORDER_COLOR 34
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif

#define TC_DWMWCP_ROUND 2
#define TC_DWMSBT_NONE 1
#define TC_DWMSBT_MAINWINDOW 2
#define TC_DWMSBT_TRANSIENTWINDOW 3
#define TC_DWMSBT_TABBEDWINDOW 4
#define TC_FLUENT_PROP L"TokenClock.FluentState"
#define TC_FLUENT_APPLIED_PROP L"TokenClock.FluentApplied"

typedef HRESULT (WINAPI *tc_dwm_set_window_attribute_t)(HWND, DWORD, LPCVOID, DWORD);
typedef HRESULT (WINAPI *tc_dwm_extend_frame_t)(HWND, const void *);
typedef HRESULT (WINAPI *tc_set_window_theme_t)(HWND, LPCWSTR, LPCWSTR);
typedef HRESULT (WINAPI *tc_draw_theme_parent_background_t)(HWND, HDC, const RECT *);
typedef LONG (WINAPI *tc_rtl_get_version_t)(void *);

typedef struct {
    int cxLeftWidth;
    int cxRightWidth;
    int cyTopHeight;
    int cyBottomHeight;
} tc_margins;

typedef struct {
    ULONG dwOSVersionInfoSize;
    ULONG dwMajorVersion;
    ULONG dwMinorVersion;
    ULONG dwBuildNumber;
    ULONG dwPlatformId;
    WCHAR szCSDVersion[128];
} tc_rtl_osversioninfo;

typedef struct {
    int requested;
    int applied;
    int layered_rejected;
    HRESULT last_hr;
} tc_window_fluent_state;

static int g_initialized = 0;
static DWORD g_windows_build = 0;
static HMODULE g_dwm = NULL;
static HMODULE g_uxtheme = NULL;
static tc_dwm_set_window_attribute_t g_dwm_set = NULL;
static tc_dwm_extend_frame_t g_dwm_extend = NULL;
static tc_set_window_theme_t g_set_window_theme = NULL;
static tc_draw_theme_parent_background_t g_draw_theme_parent_background = NULL;

static void tc_init(void) {
    if (g_initialized) return;
    g_initialized = 1;

    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    tc_rtl_get_version_t rtl_get_version = ntdll
        ? (tc_rtl_get_version_t)(void *)GetProcAddress(ntdll, "RtlGetVersion") : NULL;
    if (rtl_get_version) {
        tc_rtl_osversioninfo version;
        ZeroMemory(&version, sizeof(version));
        version.dwOSVersionInfoSize = sizeof(version);
        if (rtl_get_version(&version) == 0) g_windows_build = version.dwBuildNumber;
    }

    g_dwm = LoadLibraryW(L"dwmapi.dll");
    if (g_dwm) {
        g_dwm_set = (tc_dwm_set_window_attribute_t)(void *)GetProcAddress(g_dwm, "DwmSetWindowAttribute");
        g_dwm_extend = (tc_dwm_extend_frame_t)(void *)GetProcAddress(g_dwm, "DwmExtendFrameIntoClientArea");
    }
    g_uxtheme = LoadLibraryW(L"uxtheme.dll");
    if (g_uxtheme) {
        g_set_window_theme = (tc_set_window_theme_t)(void *)GetProcAddress(g_uxtheme, "SetWindowTheme");
        g_draw_theme_parent_background = (tc_draw_theme_parent_background_t)(void *)
            GetProcAddress(g_uxtheme, "DrawThemeParentBackground");
    }
}

static DWORD tc_read_personalize_dword(const wchar_t *name, DWORD fallback) {
    HKEY key = NULL;
    DWORD value = fallback, size = sizeof(value), type = 0;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
                      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                      0, KEY_QUERY_VALUE, &key) == ERROR_SUCCESS) {
        if (RegQueryValueExW(key, name, NULL, &type, (BYTE *)&value, &size) != ERROR_SUCCESS || type != REG_DWORD)
            value = fallback;
        RegCloseKey(key);
    }
    return value;
}

static int tc_high_contrast(void) {
    HIGHCONTRASTW high_contrast;
    ZeroMemory(&high_contrast, sizeof(high_contrast));
    high_contrast.cbSize = sizeof(high_contrast);
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(high_contrast), &high_contrast, 0)
        && (high_contrast.dwFlags & HCF_HIGHCONTRASTON) ? 1 : 0;
}

static int tc_transparency_enabled(void) {
    return tc_read_personalize_dword(L"EnableTransparency", 1) != 0;
}

static int tc_dark_mode(void) {
    if (tc_high_contrast()) return 0;
    return tc_read_personalize_dword(L"AppsUseLightTheme", 1) == 0;
}

static tc_window_fluent_state *tc_state(HWND hwnd, int create) {
    tc_window_fluent_state *state = (tc_window_fluent_state *)GetPropW(hwnd, TC_FLUENT_PROP);
    if (!state && create) {
        state = (tc_window_fluent_state *)calloc(1, sizeof(*state));
        if (state && !SetPropW(hwnd, TC_FLUENT_PROP, state)) {
            free(state);
            state = NULL;
        }
    }
    return state;
}

static int tc_dwm_backdrop_for(int material) {
    switch (material) {
    case WIN_FLUENT_MICA: return TC_DWMSBT_MAINWINDOW;
    case WIN_FLUENT_ACRYLIC: return TC_DWMSBT_TRANSIENTWINDOW;
    case WIN_FLUENT_MICA_ALT: return TC_DWMSBT_TABBEDWINDOW;
    default: return TC_DWMSBT_NONE;
    }
}

static void tc_report(HWND hwnd, tc_window_fluent_state *state) {
    /* Applied+1 keeps the property non-NULL for fallback.  A smoke harness can
     * query it with GetProp without linking to TokenClock; the public JSON API
     * provides the complete report to C/Swift tests. */
    SetPropW(hwnd, TC_FLUENT_APPLIED_PROP, (HANDLE)(INT_PTR)(state->applied + 1));
    wchar_t enabled[8];
    if (GetEnvironmentVariableW(L"TC_FLUENT_REPORT", enabled, ARRAYSIZE(enabled)) > 0
        && enabled[0] != L'0') {
        char report[512];
        if (win_fluent_diagnostics_json(hwnd, report, (int)sizeof(report))) {
            OutputDebugStringA("TokenClock Fluent: ");
            OutputDebugStringA(report);
            OutputDebugStringA("\n");
        }
    }
}

int win_fluent_apply(void *window, int material) {
    HWND hwnd = (HWND)window;
    if (!IsWindow(hwnd)) return 0;
    tc_init();

    tc_window_fluent_state *state = tc_state(hwnd, 1);
    if (!state) return 0;
    state->requested = material;
    state->applied = WIN_FLUENT_FALLBACK;
    state->layered_rejected = 0;
    state->last_hr = S_OK;

    if ((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_LAYERED) != 0) {
        state->layered_rejected = 1;
        tc_report(hwnd, state);
        return 0;
    }

    const int dark = tc_dark_mode();
    if (g_dwm_set && g_windows_build >= 17763) {
        BOOL use_dark = dark ? TRUE : FALSE;
        HRESULT dark_hr = g_dwm_set(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &use_dark, sizeof(use_dark));
        if (FAILED(dark_hr) && g_windows_build < 18985) {
            const DWORD legacy_dark_attribute = 19;
            g_dwm_set(hwnd, legacy_dark_attribute, &use_dark, sizeof(use_dark));
        }
    }

    if (g_dwm_set && g_windows_build >= 22000) {
        int corners = TC_DWMWCP_ROUND;
        g_dwm_set(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corners, sizeof(corners));
        COLORREF border = dark ? RGB(72, 72, 78) : RGB(214, 214, 220);
        g_dwm_set(hwnd, DWMWA_BORDER_COLOR, &border, sizeof(border));
    }

    const int may_use_backdrop = material != WIN_FLUENT_FALLBACK
        && g_dwm_set && g_dwm_extend && g_windows_build >= 22621
        && !tc_high_contrast() && tc_transparency_enabled();
    if (may_use_backdrop) {
        int backdrop = tc_dwm_backdrop_for(material);
        HRESULT hr = g_dwm_set(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop));
        state->last_hr = hr;
        if (SUCCEEDED(hr)) {
            /* Acrylic cards deliberately expose the DWM surface throughout
             * their client area.  Ordinary Mica dialogs contain classic GDI
             * controls, so extending glass over the full client can make DWM
             * composite a light surface over controls themed for dark mode
             * (or the inverse).  Keep their client area opaque and coherent;
             * the Mica system backdrop still styles the frame/title region. */
            tc_margins margins = material == WIN_FLUENT_ACRYLIC
                ? (tc_margins){-1, -1, -1, -1}
                : (tc_margins){0, 0, 0, 0};
            hr = g_dwm_extend(hwnd, &margins);
            state->last_hr = hr;
            if (SUCCEEDED(hr)) {
                state->applied = material;
                RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
                tc_report(hwnd, state);
                return 1;
            }
        }
    }

    if (g_dwm_set && g_windows_build >= 22621) {
        int none = TC_DWMSBT_NONE;
        g_dwm_set(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &none, sizeof(none));
    }
    if (g_dwm_extend) {
        tc_margins none = {0, 0, 0, 0};
        g_dwm_extend(hwnd, &none);
    }
    RedrawWindow(hwnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
    tc_report(hwnd, state);
    return 0;
}

void win_fluent_forget(void *window) {
    HWND hwnd = (HWND)window;
    if (!hwnd) return;
    tc_window_fluent_state *state = (tc_window_fluent_state *)RemovePropW(hwnd, TC_FLUENT_PROP);
    RemovePropW(hwnd, TC_FLUENT_APPLIED_PROP);
    free(state);
}

int win_fluent_get_diagnostics(void *window, win_fluent_diagnostics *out) {
    HWND hwnd = (HWND)window;
    if (!out || out->struct_size < sizeof(*out)) return 0;
    tc_init();
    tc_window_fluent_state *state = IsWindow(hwnd) ? tc_state(hwnd, 0) : NULL;
    const uint32_t requested_size = out->struct_size;
    ZeroMemory(out, sizeof(*out));
    out->struct_size = requested_size;
    out->windows_build = g_windows_build;
    out->requested_material = state ? state->requested : WIN_FLUENT_FALLBACK;
    out->applied_material = state ? state->applied : WIN_FLUENT_FALLBACK;
    out->dwm_available = g_dwm_set && g_dwm_extend ? 1 : 0;
    out->system_backdrop_available = g_dwm_set && g_dwm_extend && g_windows_build >= 22621 ? 1 : 0;
    out->transparency_enabled = tc_transparency_enabled();
    out->high_contrast = tc_high_contrast();
    out->dark_mode = tc_dark_mode();
    out->layered_window_rejected = state ? state->layered_rejected : 0;
    out->last_hresult = state ? (int32_t)state->last_hr : 0;
    return 1;
}

int win_fluent_diagnostics_json(void *window, char *out, int out_size) {
    if (!out || out_size <= 0) return 0;
    win_fluent_diagnostics d;
    ZeroMemory(&d, sizeof(d));
    d.struct_size = sizeof(d);
    if (!win_fluent_get_diagnostics(window, &d)) { out[0] = 0; return 0; }
    int count = snprintf(out, (size_t)out_size,
        "{\"windowsBuild\":%lu,\"requested\":%d,\"applied\":%d,"
        "\"dwmAvailable\":%s,\"systemBackdropAvailable\":%s,"
        "\"transparencyEnabled\":%s,\"highContrast\":%s,\"darkMode\":%s,"
        "\"layeredWindowRejected\":%s,\"hresult\":%ld}",
        (unsigned long)d.windows_build, d.requested_material, d.applied_material,
        d.dwm_available ? "true" : "false",
        d.system_backdrop_available ? "true" : "false",
        d.transparency_enabled ? "true" : "false",
        d.high_contrast ? "true" : "false",
        d.dark_mode ? "true" : "false",
        d.layered_window_rejected ? "true" : "false",
        (long)d.last_hresult);
    if (count < 0 || count >= out_size) { out[out_size - 1] = 0; return 0; }
    return count;
}

int win_fluent_is_dark(void *window) {
    (void)window;
    tc_init();
    return tc_dark_mode();
}

unsigned int win_fluent_color(void *window, int role) {
    (void)window;
    const int high_contrast = tc_high_contrast();
    const int dark = tc_dark_mode();
    if (high_contrast) {
        int system_role = COLOR_WINDOW;
        if (role == WIN_FLUENT_COLOR_TEXT || role == WIN_FLUENT_COLOR_SUBTEXT || role == WIN_FLUENT_COLOR_BORDER)
            system_role = COLOR_WINDOWTEXT;
        else if (role == WIN_FLUENT_COLOR_ACCENT)
            system_role = COLOR_HIGHLIGHT;
        COLORREF c = GetSysColor(system_role);
        return ((unsigned int)GetRValue(c) << 16) | ((unsigned int)GetGValue(c) << 8) | GetBValue(c);
    }
    if (dark) {
        static const unsigned int colors[] = {
            0x202023, 0x2b2b2f, 0xf5f5f7, 0xb9b9c0, 0x48484f, 0x60a5fa
        };
        return colors[(role >= 0 && role <= WIN_FLUENT_COLOR_ACCENT) ? role : 0];
    }
    {
        static const unsigned int colors[] = {
            0xf3f3f5, 0xfafafd, 0x202124, 0x64646b, 0xd5d5dc, 0x2563eb
        };
        return colors[(role >= 0 && role <= WIN_FLUENT_COLOR_ACCENT) ? role : 0];
    }
}

void win_fluent_theme_child(void *child) {
    HWND hwnd = (HWND)child;
    if (!IsWindow(hwnd)) return;
    tc_init();
    if (g_set_window_theme) {
        if (tc_high_contrast())
            g_set_window_theme(hwnd, L"", L"");
        else
            g_set_window_theme(hwnd, tc_dark_mode() ? L"DarkMode_Explorer" : L"Explorer", NULL);
    }
    wchar_t class_name[32];
    if (GetClassNameW(hwnd, class_name, ARRAYSIZE(class_name)) > 0 && _wcsicmp(class_name, L"Edit") == 0)
        SendMessageW(hwnd, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELPARAM(7, 7));
}

void win_fluent_paint_fallback(void *window, void *device_context, const void *rectangle) {
    HWND hwnd = (HWND)window;
    HDC dc = (HDC)device_context;
    const RECT *rect = (const RECT *)rectangle;
    if (!IsWindow(hwnd) || !dc || !rect) return;
    tc_window_fluent_state *state = tc_state(hwnd, 0);
    if (state && state->applied != WIN_FLUENT_FALLBACK) return;
    unsigned int rgb = win_fluent_color(hwnd, WIN_FLUENT_COLOR_BACKGROUND);
    HBRUSH brush = CreateSolidBrush(RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255));
    FillRect(dc, rect, brush);
    DeleteObject(brush);
}

void win_fluent_paint_parent(void *child_window, void *device_context, const void *rectangle) {
    HWND child = (HWND)child_window;
    HDC dc = (HDC)device_context;
    const RECT *rect = (const RECT *)rectangle;
    if (!IsWindow(child) || !dc || !rect) return;
    tc_init();
    HWND parent = GetParent(child);
    tc_window_fluent_state *state = IsWindow(parent) ? tc_state(parent, 0) : NULL;
    if (state && state->applied != WIN_FLUENT_FALLBACK && g_draw_theme_parent_background
        && SUCCEEDED(g_draw_theme_parent_background(child, dc, rect)))
        return;
    unsigned int rgb = win_fluent_color(parent, WIN_FLUENT_COLOR_BACKGROUND);
    HBRUSH brush = CreateSolidBrush(RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255));
    FillRect(dc, rect, brush);
    DeleteObject(brush);
}
