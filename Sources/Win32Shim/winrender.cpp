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

    const bool expanded = ov && ov->detail_text && ov->detail_text[0];
    // 收起态：表盘居中于正方形窗口。展开态：表盘居中于顶部 w×w 区域，下方留明细列表。
    const double cxd = w / 2.0, cyd = expanded ? (w / 2.0) : (h / 2.0);
    const double r = w / 2.0 - 24.0;   // 表盘直径 = 窗口宽；r 基于 w（收起 h==w，展开 h>w，皆取 w）
    // classic 主题按 radius 116（diameter 240pt）校准；窗口尺寸变化时按 r/116 等比缩放
    // 描边/指针/字号，与 macOS 的 scale = diameter/240 行为一致。
    const double S = r / 116.0;

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
        Gdiplus::Pen rim(cr(C_RIM), (Gdiplus::REAL)(6.0 * S));
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
    hand(hourDeg,   0.48, (float)(4.5 * S), C_HOUR);
    hand(minuteDeg, 0.68, (float)(3.0 * S), C_MINUTE);
    hand(secondDeg, 0.78, (float)(1.5 * S), C_SECOND);

    // centre cap: outer gray disc (r=4) + inner red disc (r=2), scaled
    {
        double co = 4.0 * S, ci = 2.0 * S;
        Gdiplus::SolidBrush o(cr(C_CAP_OUT));
        gfx.FillEllipse(&o, Gdiplus::REAL(cxd - co), Gdiplus::REAL(cyd - co),
                        Gdiplus::REAL(co * 2), Gdiplus::REAL(co * 2));
        Gdiplus::SolidBrush in(cr(C_CAP_IN));
        gfx.FillEllipse(&in, Gdiplus::REAL(cxd - ci), Gdiplus::REAL(cyd - ci),
                        Gdiplus::REAL(ci * 2), Gdiplus::REAL(ci * 2));
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
        // top centre: date (secondary) then weather (primary) beneath it
        textC(ov->date,    cxd, cyd - r * 0.42, (float)(11.0 * S), C_TEXT_SEC, false);
        textC(ov->weather, cxd, cyd - r * 0.42 + 16.0 * S, (float)(13.0 * S), C_TEXT_PRI, false);
        // bottom centre: token count (primary, bold) then messages (secondary)
        textC(ov->tokens,   cxd, cyd + r * 0.40, (float)(20.0 * S), C_TEXT_PRI, true);
        textC(ov->messages, cxd, cyd + r * 0.40 + 18.0 * S, (float)(10.0 * S), C_TEXT_SEC, false);
        // left side: up to two active tools (collapsed only — expanded shows the full list below)
        if (!expanded) {
            textL(ov->tool_left1, cxd - r * 0.72, cyd - 10.0 * S, (float)(13.0 * S), C_TEXT_PRI);
            textL(ov->tool_left2, cxd - r * 0.72, cyd + 12.0 * S, (float)(13.0 * S), C_TEXT_PRI);
        }
    }

    // detail list (expanded): per-tool breakdown below the dial, '\n'-separated lines.
    if (expanded) {
        wchar_t wb[2048];
        if (to_wide(ov->detail_text, wb, 2048) > 0) {
            Gdiplus::Font f(&fam, (float)(12.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
            Gdiplus::SolidBrush b(cr(C_TEXT_PRI));
            Gdiplus::StringFormat sf;
            sf.SetAlignment(Gdiplus::StringAlignmentNear);
            sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
            const double lh = 19.0 * S;                    // line advance (matches Swift height math)
            const double lx = cxd - r * 0.86;              // near the dial's left edge
            double y = w + 16.0 * S;                       // first line centre, just below the dial region
            wchar_t *line = wb;
            while (*line) {
                wchar_t *nl = wcschr(line, L'\n');
                if (nl) *nl = 0;
                int len = (int)wcslen(line);
                if (len > 0) {
                    Gdiplus::RectF rect((Gdiplus::REAL)lx, (Gdiplus::REAL)(y - 12.0 * S),
                                        400.0f, (Gdiplus::REAL)(24.0 * S));
                    gfx.DrawString(line, len, &f, rect, &sf, &b);
                }
                if (!nl) break;
                line = nl + 1;
                y += lh;
            }
        }
    }

    // present with per-pixel alpha
    POINT zero{0, 0};
    RECT wrc; GetWindowRect(g_hwnd, &wrc); POINT pos{wrc.left, wrc.top};
    SIZE sz{w, h};
    BLENDFUNCTION bf; bf.BlendOp = AC_SRC_OVER; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = AC_SRC_ALPHA;
    UpdateLayeredWindow(g_hwnd, NULL, &pos, &sz, g_mem_dc, &zero, 0, &bf, ULW_ALPHA);
}

} // extern "C"
