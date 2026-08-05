// winrender.cpp — GDI+ 抗锯齿表盘绘制 + UpdateLayeredWindow 逐像素 alpha 合成。
// 忠实复刻 macOS 经典（classic）主题：白色盘体 + 灰色外环 + 红色圆头指针 + 双色中心帽 +
// 盘面叠加文本（顶部日期、底部 token 计数）。配色/几何取自 ClockFaceTheme.classic +
// ClockContentView， authored at diameter=240pt (radius=116)。Swift 经 win_render_clock 驱动。
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objidl.h>      // must precede gdiplus.h (IStream / PROPID)
#include <gdiplus.h>
#include <string.h>
#include <cmath>
#include "winshim.h"

extern "C" HWND g_hwnd;   // defined in winshim.c (C linkage)

static ULONG_PTR  g_gdip_token = 0;
static HDC        g_mem_dc = NULL;
static HBITMAP    g_mem_bm = NULL;
static int        g_mem_w = 0, g_mem_h = 0;

// Classic theme palette (0xRRGGBB), lifted verbatim from ClockFaceTheme.classic.
static const unsigned int C_DIAL       = 0xF7F7FA;  // Color(0.97,0.97,0.98)
static const unsigned int C_RIM        = 0xD1D1D1;  // Color(white: 0.82)
static const unsigned int C_HOUR       = 0xB71C1C;  // Color(0.718,0.110,0.110)
static const unsigned int C_MINUTE     = 0xE53935;  // Color(0.898,0.224,0.208)
static const unsigned int C_SECOND     = 0xFF5252;  // Color(1.0,0.322,0.322)
static const unsigned int C_CAP_OUT    = 0xD1D1D1;  // centerDotOuterColor  white:0.82
static const unsigned int C_CAP_IN     = 0xE53935;  // centerDotInnerColor  minute red
static const unsigned int C_TEXT_PRI   = 0x2E2E33;  // textPrimaryColor  Color(0.18,0.18,0.20)
static const unsigned int C_TEXT_SEC   = 0x73737A;  // textSecondaryColor Color(0.45,0.45,0.48)

static Gdiplus::Color cr(unsigned int rgb, BYTE alpha = 255) {
    return Gdiplus::Color(alpha, (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
}
static double deg2rad(double d) { return d * 3.14159265358979 / 180.0; }

extern "C" {

void gdip_init(void) {
    Gdiplus::GdiplusStartupInput si;
    Gdiplus::GdiplusStartup(&g_gdip_token, &si, NULL);
}
void gdip_shutdown(void) {
    if (g_mem_bm) { DeleteObject(g_mem_bm); g_mem_bm = NULL; }
    if (g_mem_dc) { DeleteDC(g_mem_dc); g_mem_dc = NULL; }
    if (g_gdip_token) { Gdiplus::GdiplusShutdown(g_gdip_token); g_gdip_token = 0; }
}

static void ensure_mem(int w, int h) {
    if (g_mem_dc && g_mem_w == w && g_mem_h == h) return;
    if (g_mem_bm) DeleteObject(g_mem_bm);
    if (g_mem_dc) DeleteDC(g_mem_dc);
    HDC screen = GetDC(NULL);
    g_mem_dc = CreateCompatibleDC(screen);
    BITMAPINFO bi; memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    g_mem_bm = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, NULL, NULL, 0);
    ReleaseDC(NULL, screen);
    SelectObject(g_mem_dc, g_mem_bm);
    g_mem_w = w; g_mem_h = h;
}

// UTF-8 → UTF-16 (Windows wchar). Returns wchars written (incl. NUL) on success, 0 on overflow/empty.
static int to_wide(const char *u8, wchar_t *buf, int n) {
    if (!u8 || !u8[0]) { if (n > 0) buf[0] = 0; return 0; }
    return MultiByteToWideChar(CP_UTF8, 0, u8, -1, buf, n);
}

// Draw one clock frame into the memory ARGB bitmap and present it via UpdateLayeredWindow.
// Faithful classic theme. authored at radius 116 (diameter 240pt); window 280 ⇒ r = 116.
void win_render_clock(int w, int h, int hh, int mm, int ss, const win_overlay *ov) {
    if (!g_hwnd) return;
    ensure_mem(w, h);
    // clear to fully transparent (premultiplied alpha 0)
    DIBSECTION ds; GetObject(g_mem_bm, sizeof(ds), &ds);
    if (ds.dsBm.bmBits) memset(ds.dsBm.bmBits, 0, (size_t)w * h * 4);

    Gdiplus::Graphics gfx(g_mem_dc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    gfx.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);

    const double cxd = w / 2.0, cyd = h / 2.0;
    const double r = (w < h ? w : h) / 2.0 - 24.0;   // ⇒ 116 at window 280 (matches macOS medium)

    // soft drop shadow: a few translucent rings just outside the dial, offset slightly down.
    for (int i = 1; i <= 6; i++) {
        Gdiplus::SolidBrush sb(Gdiplus::Color(20, 0, 0, 0));
        double rr = r + i * 1.8;
        gfx.FillEllipse(&sb, Gdiplus::REAL(cxd - rr), Gdiplus::REAL(cyd - rr + 5.0),
                        Gdiplus::REAL(rr * 2), Gdiplus::REAL(rr * 2));
    }

    // dial fill (white) + gray rim (width 6, centred on the path like SwiftUI stroke)
    {
        Gdiplus::SolidBrush fill(cr(C_DIAL));
        gfx.FillEllipse(&fill, Gdiplus::REAL(cxd - r), Gdiplus::REAL(cyd - r),
                        Gdiplus::REAL(r * 2), Gdiplus::REAL(r * 2));
        Gdiplus::Pen rim(cr(C_RIM), 6.0f);
        gfx.DrawEllipse(&rim, Gdiplus::REAL(cxd - r), Gdiplus::REAL(cyd - r),
                        Gdiplus::REAL(r * 2), Gdiplus::REAL(r * 2));
    }

    // hands — round-cap lines from centre. Angles match ClockFaceView exactly
    // (hour carries minutes; minute/second are discrete steps like the original).
    auto hand = [&](double deg, double lenRatio, float width, unsigned int rgb) {
        double a = deg2rad(deg - 90.0);
        double len = r * lenRatio;
        Gdiplus::Pen p(cr(rgb), width);
        p.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
        gfx.DrawLine(&p,
                     Gdiplus::PointF(Gdiplus::REAL(cxd), Gdiplus::REAL(cyd)),
                     Gdiplus::PointF(Gdiplus::REAL(cxd + cos(a) * len),
                                     Gdiplus::REAL(cyd + sin(a) * len)));
    };
    double hourDeg   = (double)(hh % 12) * 30.0 + (double)mm * 0.5;
    double minuteDeg = (double)mm * 6.0;
    double secondDeg = (double)ss * 6.0;
    hand(hourDeg,   0.48, 4.5f, C_HOUR);
    hand(minuteDeg, 0.68, 3.0f, C_MINUTE);
    hand(secondDeg, 0.78, 1.5f, C_SECOND);

    // centre cap: outer gray disc (r=4) + inner red disc (r=2)
    {
        Gdiplus::SolidBrush o(cr(C_CAP_OUT));
        gfx.FillEllipse(&o, Gdiplus::REAL(cxd - 4.0), Gdiplus::REAL(cyd - 4.0), 8.0f, 8.0f);
        Gdiplus::SolidBrush in(cr(C_CAP_IN));
        gfx.FillEllipse(&in, Gdiplus::REAL(cxd - 2.0), Gdiplus::REAL(cyd - 2.0), 4.0f, 4.0f);
    }

    // overlay text (drawn last ⇒ on top of hands, matching ClockContentView ZStack order)
    Gdiplus::FontFamily fam(L"Segoe UI");
    Gdiplus::StringFormat sfCenter;
    sfCenter.SetAlignment(Gdiplus::StringAlignmentCenter);
    sfCenter.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    auto textC = [&](const char *u8, double px, double py, float size,
                     unsigned int rgb, bool bold) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0) return;
        Gdiplus::Font f(&fam, size, bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular,
                        Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(rgb));
        Gdiplus::RectF rect(Gdiplus::REAL(px - 130.0), Gdiplus::REAL(py - size),
                            260.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sfCenter, &b);
    };
    // left-aligned text: anchored at px (left edge), vertically centred at py.
    auto textL = [&](const char *u8, double px, double py, float size, unsigned int rgb) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0) return;
        Gdiplus::Font f(&fam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(rgb));
        Gdiplus::StringFormat sf;
        sf.SetAlignment(Gdiplus::StringAlignmentNear);
        sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        Gdiplus::RectF rect(Gdiplus::REAL(px), Gdiplus::REAL(py - size),
                            200.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sf, &b);
    };

    if (ov) {
        // top centre: date (secondary 11px) then weather (primary 13px) beneath it
        textC(ov->date,    cxd, cyd - r * 0.42, 11.0f, C_TEXT_SEC, false);
        textC(ov->weather, cxd, cyd - r * 0.42 + 16.0, 13.0f, C_TEXT_PRI, false);
        // bottom centre: token count (primary 20px bold) then messages (secondary 10px)
        textC(ov->tokens,   cxd, cyd + r * 0.40, 20.0f, C_TEXT_PRI, true);
        textC(ov->messages, cxd, cyd + r * 0.40 + 18.0, 10.0f, C_TEXT_SEC, false);
        // left side: up to two active tools (primary 13px), like ClockContentView's leading HStack
        textL(ov->tool_left1, cxd - r * 0.72, cyd - 10.0, 13.0f, C_TEXT_PRI);
        textL(ov->tool_left2, cxd - r * 0.72, cyd + 12.0, 13.0f, C_TEXT_PRI);
    }

    // present with per-pixel alpha
    POINT zero{0, 0};
    RECT wrc; GetWindowRect(g_hwnd, &wrc); POINT pos{wrc.left, wrc.top};
    SIZE sz{w, h};
    BLENDFUNCTION bf; bf.BlendOp = AC_SRC_OVER; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = AC_SRC_ALPHA;
    UpdateLayeredWindow(g_hwnd, NULL, &pos, &sz, g_mem_dc, &zero, 0, &bf, ULW_ALPHA);
}

} // extern "C"
