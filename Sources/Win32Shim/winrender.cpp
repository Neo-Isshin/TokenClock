// winrender.cpp — GDI+ 抗锯齿表盘绘制 + UpdateLayeredWindow 逐像素 alpha 合成。
// 让窗口在表盘外完全透明（无矩形背景）、边缘平滑、带柔和阴影。Swift 经 win_render_clock 驱动。
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

// UTF-8 → UTF-16 (Windows wchar).
static int to_wide(const char *u8, wchar_t *buf, int n) {
    if (!u8) { if (n > 0) buf[0] = 0; return 0; }
    return MultiByteToWideChar(CP_UTF8, 0, u8, -1, buf, n);
}

// Draw one clock frame into the memory ARGB bitmap and present it via UpdateLayeredWindow.
void win_render_clock(int w, int h, int hh, int mm, int ss, const char *token_utf8,
                      unsigned int dial_fill, unsigned int dial_stroke,
                      unsigned int tick_rgb, unsigned int hand_rgb,
                      unsigned int sec_rgb, unsigned int text_rgb) {
    if (!g_hwnd) return;
    ensure_mem(w, h);
    // clear to fully transparent (premultiplied alpha 0)
    DIBSECTION ds; GetObject(g_mem_bm, sizeof(ds), &ds);
    if (ds.dsBm.bmBits) memset(ds.dsBm.bmBits, 0, (size_t)w * h * 4);

    Gdiplus::Graphics gfx(g_mem_dc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);

    const int cx = w / 2, cy = h / 2;
    const int r = (w < h ? w : h) / 2 - 26;   // leave room for the soft shadow
    const double cxd = cx, cyd = cy;

    // soft shadow: a few translucent rings just outside the dial
    for (int i = 1; i <= 5; i++) {
        Gdiplus::SolidBrush sb(Gdiplus::Color(28, 0, 0, 0));
        int rr = r + i * 2;
        gfx.FillEllipse(&sb, cx - rr, cy - rr + 5, rr * 2, rr * 2);
    }

    // dial
    Gdiplus::SolidBrush fill(cr(dial_fill));
    gfx.FillEllipse(&fill, cx - r, cy - r, r * 2, r * 2);
    Gdiplus::Pen stroke(cr(dial_stroke), 3.2f);
    gfx.DrawEllipse(&stroke, cx - r, cy - r, r * 2, r * 2);

    // subtle inner ring
    Gdiplus::Pen inner(cr(0xC9BFA8), 1.0f);
    gfx.DrawEllipse(&inner, cx - r + 6, cy - r + 6, (r - 6) * 2, (r - 6) * 2);

    // 60 ticks
    for (int i = 0; i < 60; i++) {
        double a = deg2rad(i * 6.0 - 90.0);
        bool hour = (i % 5 == 0);
        double inner = r - (hour ? 20.0 : 12.0);
        double outer = r - 4.0;
        Gdiplus::Pen tp(cr(tick_rgb), hour ? 2.6f : 1.0f);
        gfx.DrawLine(&tp,
                     Gdiplus::PointF((float)(cxd + cos(a) * inner), (float)(cyd + sin(a) * inner)),
                     Gdiplus::PointF((float)(cxd + cos(a) * outer), (float)(cyd + sin(a) * outer)));
    }

    // numbers 12 / 3 / 6 / 9
    Gdiplus::FontFamily fam(L"Segoe UI");
    Gdiplus::Font numFont(&fam, 15, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush numBrush(cr(0x6A5F52));
    Gdiplus::StringFormat sf; sf.SetAlignment(Gdiplus::StringAlignmentCenter); sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    const wchar_t *nums[4] = { L"12", L"3", L"6", L"9" };
    int ndeg[4] = { 0, 90, 180, 270 };
    for (int k = 0; k < 4; k++) {
        double a = deg2rad(ndeg[k] - 90);
        double nr = r - 38;
        Gdiplus::RectF rect((float)(cxd + cos(a) * nr) - 20, (float)(cyd + sin(a) * nr) - 12, 40, 24);
        gfx.DrawString(nums[k], 1, &numFont, rect, &sf, &numBrush);
    }

    // hands (thick rounded caps → AA, less crude than bare lines)
    double hp = (hh % 12) + mm / 60.0, mp = mm + ss / 60.0, sp = ss;
    auto hand = [&](double deg, double lenRatio, float width, unsigned int rgb) {
        double a = deg2rad(deg - 90);
        Gdiplus::Pen p(cr(rgb), width);
        p.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
        double len = r * lenRatio;
        gfx.DrawLine(&p, Gdiplus::PointF((float)cxd, (float)cyd),
                     Gdiplus::PointF((float)(cxd + cos(a) * len), (float)(cyd + sin(a) * len)));
    };
    hand(hp * 30.0, 0.52, 6.5f, hand_rgb);
    hand(mp * 6.0,  0.74, 4.5f, hand_rgb);
    hand(sp * 6.0,  0.80, 2.0f, sec_rgb);

    // center cap
    Gdiplus::SolidBrush cap(cr(hand_rgb));
    gfx.FillEllipse(&cap, cx - 6, cy - 6, 12, 12);

    // token text (below center)
    if (token_utf8) {
        wchar_t wbuf[64];
        if (to_wide(token_utf8, wbuf, 64) > 0) {
            Gdiplus::Font tf(&fam, 22, Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
            Gdiplus::SolidBrush tb(cr(text_rgb));
            Gdiplus::RectF rect(cx - 90, (float)(cyd + r * 0.46) - 16, 180, 32);
            gfx.DrawString(wbuf, -1, &tf, rect, &sf, &tb);
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
