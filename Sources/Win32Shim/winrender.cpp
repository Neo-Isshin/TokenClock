// winrender.cpp — GDI+ 抗锯齿表盘绘制 + UpdateLayeredWindow 逐像素 alpha 合成。
// 主题驱动：Swift 构 win_theme（颜色 ARGB，可表达 .clear/opacity），winrender 据此绘制
// 盘体/外环/刻度/数字(阿拉伯|中文)/4 种指针(圆/锥/菱/剑)/中心帽/天空装饰。指针与几何
// 的路径数学逐行移植自 macOS ClockFaceView，配色取自 ClockFaceTheme，以求像素级对齐。
#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objidl.h>      // must precede gdiplus.h (IStream / PROPID)
#include <gdiplus.h>
#include <string.h>
#include <cmath>
#include <utility>   // std::make_pair
#include "winshim.h"

extern "C" HWND g_hwnd;   // defined in winshim.c (C linkage)

static ULONG_PTR  g_gdip_token = 0;
static HDC        g_mem_dc = NULL;
static HBITMAP    g_mem_bm = NULL;
static int        g_mem_w = 0, g_mem_h = 0;
static BYTE       g_window_alpha = 255;
static Gdiplus::Image *g_dial_image = NULL;
static wchar_t    g_dial_image_path[MAX_PATH] = {0};

// ARGB(0xAARRGGBB) → GDI+ Color。
static Gdiplus::Color cr(unsigned int argb) {
    return Gdiplus::Color((BYTE)((argb >> 24) & 0xff), (BYTE)((argb >> 16) & 0xff),
                          (BYTE)((argb >> 8) & 0xff), (BYTE)(argb & 0xff));
}
static double deg2rad(double d) { return d * 3.14159265358979 / 180.0; }

extern "C" {

void gdip_init(void) {
    Gdiplus::GdiplusStartupInput si;
    Gdiplus::GdiplusStartup(&g_gdip_token, &si, NULL);
}
void gdip_shutdown(void) {
    if (g_dial_image) { delete g_dial_image; g_dial_image = NULL; g_dial_image_path[0] = 0; }
    if (g_mem_bm) { DeleteObject(g_mem_bm); g_mem_bm = NULL; }
    if (g_mem_dc) { DeleteDC(g_mem_dc); g_mem_dc = NULL; }
    if (g_gdip_token) { Gdiplus::GdiplusShutdown(g_gdip_token); g_gdip_token = 0; }
}

void win_render_set_opacity(double alpha) {
    if (alpha < 0.0) alpha = 0.0;
    if (alpha > 1.0) alpha = 1.0;
    g_window_alpha = (BYTE)std::lround(alpha * 255.0);
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

// UTF-8 → UTF-16。返回写入 wchar 数（含 NUL）；空串/溢出返回 0。
static int to_wide(const char *u8, wchar_t *buf, int n) {
    if (!u8 || !u8[0]) { if (n > 0) buf[0] = 0; return 0; }
    return MultiByteToWideChar(CP_UTF8, 0, u8, -1, buf, n);
}

// Draw one clock frame into the memory ARGB bitmap and present it via UpdateLayeredWindow.
void win_render_clock(int w, int h, int hh, int mm, int ss, const win_theme *t, const win_overlay *ov) {
    if (!g_hwnd || !t) return;
    ensure_mem(w, h);
    DIBSECTION ds; GetObject(g_mem_bm, sizeof(ds), &ds);
    if (ds.dsBm.bmBits) memset(ds.dsBm.bmBits, 0, (size_t)w * h * 4);

    Gdiplus::Graphics gfx(g_mem_dc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    gfx.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);

    const bool expanded = ov && ov->detail_text && ov->detail_text[0];
    const double clockH = w - 80.0;            // ClockSize.panelWidth = diameter + 80
    const double cxd = w / 2.0, cyd = clockH / 2.0;
    const double r = clockH / 2.0 - 4.0;        // exact ClockFaceView radius
    const double S = r / 116.0;                 // medium macOS radius = 120 - 4

    // 盘体 + 外环。glass 使用与 macOS normal 相同的预捕获 Liquid Glass PNG。
    {
        bool drewImage = false;
        wchar_t imagePath[MAX_PATH];
        if (ov && to_wide(ov->dial_image_path, imagePath, MAX_PATH) > 0) {
            if (!g_dial_image || wcscmp(imagePath, g_dial_image_path) != 0) {
                if (g_dial_image) delete g_dial_image;
                g_dial_image = new Gdiplus::Image(imagePath);
                wcsncpy_s(g_dial_image_path, imagePath, _TRUNCATE);
            }
            if (g_dial_image && g_dial_image->GetLastStatus() == Gdiplus::Ok) {
                gfx.DrawImage(g_dial_image, Gdiplus::RectF((Gdiplus::REAL)(cxd - r), (Gdiplus::REAL)(cyd - r),
                                                           (Gdiplus::REAL)(r * 2), (Gdiplus::REAL)(r * 2)));
                drewImage = true;
            }
        }
        if (!drewImage) {
            Gdiplus::SolidBrush fill(cr(t->dial_fill));
            gfx.FillEllipse(&fill, Gdiplus::REAL(cxd - r), Gdiplus::REAL(cyd - r),
                            Gdiplus::REAL(r * 2), Gdiplus::REAL(r * 2));
            if (t->rim_width > 0 && (t->dial_rim >> 24) > 0) {
                Gdiplus::Pen rim(cr(t->dial_rim), (Gdiplus::REAL)(t->rim_width * S));
                gfx.DrawEllipse(&rim, Gdiplus::REAL(cxd - r), Gdiplus::REAL(cyd - r),
                                Gdiplus::REAL(r * 2), Gdiplus::REAL(r * 2));
            }
        }
    }

    // 刻度（移植自 ClockFaceView.drawTickMarks：12 根，i%3==0 为主）
    if (t->show_ticks) {
        for (int i = 1; i <= 12; i++) {
            double a = deg2rad(i * 30.0 - 90.0);
            bool major = (i % 3 == 0);
            double innerR = r * (major ? 0.91 : 0.935);
            double outerR = r * 0.97;
            unsigned int col = major ? t->major_tick_color : t->tick_color;
            if ((col >> 24) == 0) continue;
            Gdiplus::Pen tp(cr(col), (Gdiplus::REAL)((major ? 2.0 : 1.2) * S));
            tp.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
            gfx.DrawLine(&tp,
                         Gdiplus::PointF(Gdiplus::REAL(cxd + cos(a) * innerR), Gdiplus::REAL(cyd + sin(a) * innerR)),
                         Gdiplus::PointF(Gdiplus::REAL(cxd + cos(a) * outerR), Gdiplus::REAL(cyd + sin(a) * outerR)));
        }
    }

    // 数字（移植自 drawNumbers：numberRadius 0.84r，font 13*scale；gufeng 用中文）
    if (t->show_numbers && (t->number_color >> 24) > 0) {
        const wchar_t *arabic[13] = { L"", L"1", L"2", L"3", L"4", L"5", L"6", L"7", L"8", L"9", L"10", L"11", L"12" };
        const wchar_t *chinese[13] = { L"", L"\x58F9", L"\x8D30", L"\x53C1", L"\x8086", L"\x4F0D", L"\x9646",
                                       L"\x67D2", L"\x6352", L"\x7396", L"\x62FE", L"\x62FE\x58F9", L"\x62FE\x8D30" };
        const wchar_t *family = (t->show_numbers == 2) ? L"Microsoft YaHei" : L"Segoe UI";
        Gdiplus::FontFamily fam(family);
        Gdiplus::Font nf(&fam, (float)(13.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush nb(cr(t->number_color));
        Gdiplus::StringFormat sf; sf.SetAlignment(Gdiplus::StringAlignmentCenter); sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        double nr = r * 0.84;
        for (int i = 1; i <= 12; i++) {
            double a = deg2rad(i * 30.0 - 90.0);
            const wchar_t *label = (t->show_numbers == 2) ? chinese[i] : arabic[i];
            Gdiplus::RectF rect(Gdiplus::REAL(cxd + cos(a) * nr) - 40, Gdiplus::REAL(cyd + sin(a) * nr) - 16, 80, 32);
            gfx.DrawString(label, -1, &nf, rect, &sf, &nb);
        }
    }

    // 天空主题装饰：太阳 + 云朵（移植自 drawDialDecoration；飞鸟从略）
    if (t->has_decoration) {
        auto cloud = [&](double cx, double cy, double sc) {
            Gdiplus::SolidBrush wb(Gdiplus::Color(242, 242, 242));
            gfx.FillEllipse(&wb, Gdiplus::REAL(cx - sc * 1.1), Gdiplus::REAL(cy - sc * 0.4), Gdiplus::REAL(sc * 1.4), Gdiplus::REAL(sc * 1.0));
            gfx.FillEllipse(&wb, Gdiplus::REAL(cx - sc * 0.4), Gdiplus::REAL(cy - sc * 0.9), Gdiplus::REAL(sc * 1.2), Gdiplus::REAL(sc * 1.0));
            gfx.FillEllipse(&wb, Gdiplus::REAL(cx + sc * 0.2), Gdiplus::REAL(cy - sc * 0.3), Gdiplus::REAL(sc * 1.2), Gdiplus::REAL(sc * 0.9));
        };
        double sa = deg2rad(-55.0), sunR = r * 0.62, sunSize = r * 0.10;
        double sx = cxd + sunR * cos(sa), sy = cyd + sunR * sin(sa);
        Gdiplus::SolidBrush glow(Gdiplus::Color(64, 255, 235, 153));
        gfx.FillEllipse(&glow, Gdiplus::REAL(sx - sunSize * 1.5), Gdiplus::REAL(sy - sunSize * 1.5), Gdiplus::REAL(sunSize * 3), Gdiplus::REAL(sunSize * 3));
        Gdiplus::SolidBrush sun(Gdiplus::Color(255, 255, 217, 77));
        gfx.FillEllipse(&sun, Gdiplus::REAL(sx - sunSize), Gdiplus::REAL(sy - sunSize), Gdiplus::REAL(sunSize * 2), Gdiplus::REAL(sunSize * 2));
        cloud(cxd - r * 0.38, cyd - r * 0.28, r * 0.10);
        cloud(cxd + r * 0.25, cyd + r * 0.32, r * 0.07);
        cloud(cxd - r * 0.10, cyd + r * 0.50, r * 0.055);
        auto bird = [&](double cx, double cy, double sc, BYTE opacity) {
            Gdiplus::GraphicsPath path;
            path.AddBezier(Gdiplus::PointF((float)(cx - sc), (float)(cy + sc * 0.3)),
                           Gdiplus::PointF((float)(cx - sc * 0.3), (float)(cy - sc * 0.5)),
                           Gdiplus::PointF((float)(cx - sc * 0.2), (float)(cy - sc * 0.25)),
                           Gdiplus::PointF((float)cx, (float)(cy - sc * 0.2)));
            path.AddBezier(Gdiplus::PointF((float)cx, (float)(cy - sc * 0.2)),
                           Gdiplus::PointF((float)(cx + sc * 0.2), (float)(cy - sc * 0.25)),
                           Gdiplus::PointF((float)(cx + sc * 0.3), (float)(cy - sc * 0.5)),
                           Gdiplus::PointF((float)(cx + sc), (float)(cy + sc * 0.3)));
            Gdiplus::Pen pen(Gdiplus::Color(opacity, 71, 97, 128), (Gdiplus::REAL)(sc * 0.25));
            pen.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
            gfx.DrawPath(&pen, &path);
        };
        bird(cxd - r * 0.35, cyd + r * 0.18, r * 0.05, 255);
        bird(cxd - r * 0.22, cyd + r * 0.10, r * 0.035, 153);
    }

    // 指针（移植自 drawHands / drawRoundHand / drawTaperedHand / drawLanceHand / drawSwordHand）
    double hourDeg   = (double)(hh % 12) * 30.0 + (double)mm * 0.5;
    double minuteDeg = (double)mm * 6.0;
    double secondDeg = (double)ss * 6.0;
    int secStyle = (t->hand_style == 3) ? 3 : 0;   // 秒针：剑主题用剑，其余用圆头细线

    auto roundHand = [&](double deg, double lenRatio, double width, unsigned int argb) {
        double a = deg2rad(deg - 90.0), len = r * lenRatio;
        Gdiplus::Pen p(cr(argb), (float)width);
        p.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
        gfx.DrawLine(&p, Gdiplus::PointF(Gdiplus::REAL(cxd), Gdiplus::REAL(cyd)),
                     Gdiplus::PointF(Gdiplus::REAL(cxd + cos(a) * len), Gdiplus::REAL(cyd + sin(a) * len)));
    };
    auto polygon = [&](const Gdiplus::PointF *p, int n, unsigned int argb) {
        Gdiplus::GraphicsPath path;
        path.AddPolygon(p, n);
        Gdiplus::SolidBrush b(cr(argb));
        gfx.FillPath(&b, &path);
    };
    auto tapered = [&](double deg, double lenRatio, double baseW, double tipW, unsigned int argb) {
        double a = deg2rad(deg - 90.0), ca = cos(a), sa = sin(a);
        double rad = r * lenRatio, perp = deg2rad(deg), dx = cos(perp), dy = sin(perp);
        double ex = cxd + ca * rad, ey = cyd + sa * rad;
        double bx = cxd - ca * rad * 0.15, by = cyd - sa * rad * 0.15;
        Gdiplus::PointF p[4] = {
            { (float)(bx + dx * baseW / 2), (float)(by + dy * baseW / 2) },
            { (float)(ex + dx * tipW / 2),  (float)(ey + dy * tipW / 2) },
            { (float)(ex - dx * tipW / 2),  (float)(ey - dy * tipW / 2) },
            { (float)(bx - dx * baseW / 2), (float)(by - dy * baseW / 2) },
        };
        polygon(p, 4, argb);
    };
    auto lance = [&](double deg, double lenRatio, double width, unsigned int argb) {
        double a = deg2rad(deg - 90.0), ca = cos(a), sa = sin(a);
        double rad = r * lenRatio, perp = deg2rad(deg), dx = cos(perp), dy = sin(perp);
        double ex = cxd + ca * rad, ey = cyd + sa * rad;
        double mx = cxd + ca * rad * 0.35, my = cyd + sa * rad * 0.35;
        double bx = cxd - ca * rad * 0.12, by = cyd - sa * rad * 0.12;
        Gdiplus::PointF p[4] = {
            { (float)bx, (float)by },
            { (float)(mx + dx * width / 2), (float)(my + dy * width / 2) },
            { (float)ex, (float)ey },
            { (float)(mx - dx * width / 2), (float)(my - dy * width / 2) },
        };
        polygon(p, 4, argb);
    };
    auto sword = [&](double deg, double lenRatio, double width, unsigned int argb) {
        double a = deg2rad(deg - 90.0), ca = cos(a), sa = sin(a);
        double rad = r * lenRatio, perp = deg2rad(deg), dx = cos(perp), dy = sin(perp);
        auto along = [&](double fr) { return std::make_pair(cxd + ca * rad * fr, cyd + sa * rad * fr); };
        auto endP = along(1.0), tipS = along(0.85), gF = along(0.10), gB = along(0.02), hEnd = along(-0.12), pom = along(-0.16);
        double hw = width / 2, gw = width * 0.9, bw = width * 0.35, pw = width * 0.45;
        Gdiplus::PointF p[13] = {
            { (float)(pom.first + dx * pw),   (float)(pom.second + dy * pw) },
            { (float)(hEnd.first + dx * bw),  (float)(hEnd.second + dy * bw) },
            { (float)(gB.first + dx * gw),    (float)(gB.second + dy * gw) },
            { (float)(gF.first + dx * gw),    (float)(gF.second + dy * gw) },
            { (float)(gF.first + dx * hw),    (float)(gF.second + dy * hw) },
            { (float)(tipS.first + dx * hw),  (float)(tipS.second + dy * hw) },
            { (float)endP.first,              (float)endP.second },
            { (float)(tipS.first - dx * hw),  (float)(tipS.second - dy * hw) },
            { (float)(gF.first - dx * hw),    (float)(gF.second - dy * hw) },
            { (float)(gF.first - dx * gw),    (float)(gF.second - dy * gw) },
            { (float)(gB.first - dx * gw),    (float)(gB.second - dy * gw) },
            { (float)(hEnd.first - dx * bw),  (float)(hEnd.second - dy * bw) },
            { (float)(pom.first - dx * pw),   (float)(pom.second - dy * pw) },
        };
        polygon(p, 13, argb);
    };
    auto drawHand = [&](double deg, double lenRatio, double width, unsigned int argb, int style) {
        switch (style) {
        case 1: tapered(deg, lenRatio, width, width * 0.3, argb); break;
        case 2: lance(deg, lenRatio, width, argb); break;
        case 3: sword(deg, lenRatio, width, argb); break;
        default: roundHand(deg, lenRatio, width, argb); break;
        }
    };
    drawHand(hourDeg,   t->hour_len,   t->hour_w   * S, t->hour_color,   t->hand_style);
    drawHand(minuteDeg, t->minute_len, t->minute_w * S, t->minute_color, t->hand_style);
    drawHand(secondDeg, t->second_len, t->second_w * S, t->second_color, secStyle);

    // 中心帽：外盘 r4 + 内盘 r2（缩放）
    {
        double co = 4.0 * S, ci = 2.0 * S;
        if ((t->cap_outer >> 24) > 0) {
            Gdiplus::SolidBrush o(cr(t->cap_outer));
            gfx.FillEllipse(&o, Gdiplus::REAL(cxd - co), Gdiplus::REAL(cyd - co), Gdiplus::REAL(co * 2), Gdiplus::REAL(co * 2));
        }
        if ((t->cap_inner >> 24) > 0) {
            Gdiplus::SolidBrush in(cr(t->cap_inner));
            gfx.FillEllipse(&in, Gdiplus::REAL(cxd - ci), Gdiplus::REAL(cyd - ci), Gdiplus::REAL(ci * 2), Gdiplus::REAL(ci * 2));
        }
    }

    // 叠加文本（drawn last ⇒ 盘面之上）
    Gdiplus::FontFamily fam(L"Segoe UI");
    Gdiplus::StringFormat sfC; sfC.SetAlignment(Gdiplus::StringAlignmentCenter); sfC.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    auto textC = [&](const char *u8, double px, double py, float size, unsigned int argb, bool bold) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0 || (argb >> 24) == 0) return;
        Gdiplus::Font f(&fam, size, bold ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::RectF rect(Gdiplus::REAL(px - 130.0), Gdiplus::REAL(py - size), 260.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sfC, &b);
    };
    auto textL = [&](const char *u8, double px, double py, float size, unsigned int argb) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0 || (argb >> 24) == 0) return;
        Gdiplus::Font f(&fam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::StringFormat sf; sf.SetAlignment(Gdiplus::StringAlignmentNear); sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        Gdiplus::RectF rect(Gdiplus::REAL(px), Gdiplus::REAL(py - size), 200.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sf, &b);
    };
    auto textEmoji = [&](const char *u8, double px, double py, float size, unsigned int argb) {
        wchar_t wb[32];
        if (to_wide(u8, wb, 32) == 0 || (argb >> 24) == 0) return;
        Gdiplus::FontFamily emojiFam(L"Segoe UI Emoji");
        Gdiplus::Font f(&emojiFam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::RectF rect((Gdiplus::REAL)(px - size), (Gdiplus::REAL)(py - size), (Gdiplus::REAL)(size * 2), (Gdiplus::REAL)(size * 2));
        gfx.DrawString(wb, -1, &f, rect, &sfC, &b);
    };
    auto textCEmojiLine = [&](const char *u8, double px, double py, float size, unsigned int argb) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0 || (argb >> 24) == 0) return;
        Gdiplus::FontFamily emojiFam(L"Segoe UI Emoji");
        Gdiplus::Font f(&emojiFam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::RectF rect(Gdiplus::REAL(px - 130.0), Gdiplus::REAL(py - size), 260.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sfC, &b);
    };
    auto textLEmojiLine = [&](const char *u8, double px, double py, float size, unsigned int argb) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0 || (argb >> 24) == 0) return;
        Gdiplus::FontFamily emojiFam(L"Segoe UI Emoji");
        Gdiplus::Font f(&emojiFam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::StringFormat sf; sf.SetAlignment(Gdiplus::StringAlignmentNear); sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
        Gdiplus::RectF rect(Gdiplus::REAL(px), Gdiplus::REAL(py - size), 200.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sf, &b);
    };

    if (ov) {
        textC(ov->date,    cxd, cyd - r * 0.42, (float)(11.0 * S), t->text_secondary, false);
        textCEmojiLine(ov->weather, cxd, cyd - r * 0.42 + 16.0 * S, (float)(13.0 * S), t->text_primary);
        textC(ov->today_label, cxd, cyd + r * 0.28, (float)(9.0 * S), t->text_secondary, false);
        textC(ov->tokens,   cxd, cyd + r * 0.40, (float)(20.0 * S), t->text_primary, true);
        textC(ov->messages, cxd, cyd + r * 0.40 + 18.0 * S, (float)(10.0 * S), t->text_secondary, false);
        textEmoji(ov->rate, cxd + r * 0.72, cyd, (float)(25.0 * S), t->text_primary);
        if (!expanded) {
            textLEmojiLine(ov->tool_left1, cxd - r * 0.72, cyd - 10.0 * S, (float)(13.0 * S), t->text_primary);
            textLEmojiLine(ov->tool_left2, cxd - r * 0.72, cyd + 12.0 * S, (float)(13.0 * S), t->text_primary);
        }
    }

    // 展开态：与 macOS normal 对齐的交互卡片——分组胶囊、百分比 chip、四列表头、
    // 可展开父行与缩进子行。Swift 负责点击状态，renderer 只画当前快照。
    if (expanded) {
        wchar_t wb[2048];
        if (to_wide(ov->detail_text, wb, 2048) > 0) {
            int n = 1;
            for (wchar_t *p = wb; *p; p++) if (*p == L'\n') n++;
            const double gap = 14.0 * S, rowH = 30.0 * S, radius = 12.0 * S;
            const bool hasForecast = ov->forecast_summary && ov->forecast_summary[0];
            const double forecastH = hasForecast ? 76.0 * S : 0.0;
            const double cardLeft = 8.0 * S, cardW = w - 16.0 * S, cardRight = cardLeft + cardW;
            const double cardTop = clockH + gap, cardH = (94.0 + n * 30.0) * S + forecastH;

            auto roundedPath = [](Gdiplus::GraphicsPath &path, double x, double y, double width, double height, double rad) {
                Gdiplus::REAL rr = (Gdiplus::REAL)rad;
                path.AddArc((Gdiplus::REAL)x, (Gdiplus::REAL)y, 2 * rr, 2 * rr, 180, 90);
                path.AddArc((Gdiplus::REAL)(x + width - 2 * rad), (Gdiplus::REAL)y, 2 * rr, 2 * rr, 270, 90);
                path.AddArc((Gdiplus::REAL)(x + width - 2 * rad), (Gdiplus::REAL)(y + height - 2 * rad), 2 * rr, 2 * rr, 0, 90);
                path.AddArc((Gdiplus::REAL)x, (Gdiplus::REAL)(y + height - 2 * rad), 2 * rr, 2 * rr, 90, 90);
                path.CloseFigure();
            };
            auto alpha = [](unsigned int color, BYTE a) { return ((unsigned int)a << 24) | (color & 0x00ffffff); };
            auto splitTabs = [](wchar_t *text, wchar_t **fields, int count) {
                for (int i = 0; i < count; i++) fields[i] = (wchar_t *)L"";
                fields[0] = text;
                int index = 1;
                for (wchar_t *p = text; *p && index < count; p++) {
                    if (*p == L'\t') { *p = 0; fields[index++] = p + 1; }
                }
            };

            // 圆角卡片：填充 + 描边
            Gdiplus::GraphicsPath card;
            roundedPath(card, cardLeft, cardTop, cardW, cardH, radius);
            Gdiplus::SolidBrush bg(cr(t->dd_bg));
            gfx.FillPath(&bg, &card);
            if ((t->dd_border >> 24) > 0) {
                Gdiplus::Pen bp(cr(t->dd_border), 1.4f);
                gfx.DrawPath(&bp, &card);
            }

            Gdiplus::FontFamily famD(L"Segoe UI");
            Gdiplus::FontFamily famEmoji(L"Segoe UI Emoji");
            Gdiplus::StringFormat sfL; sfL.SetAlignment(Gdiplus::StringAlignmentNear);  sfL.SetLineAlignment(Gdiplus::StringAlignmentCenter);
            Gdiplus::StringFormat sfR; sfR.SetAlignment(Gdiplus::StringAlignmentFar);   sfR.SetLineAlignment(Gdiplus::StringAlignmentCenter);
            Gdiplus::StringFormat sfC2; sfC2.SetAlignment(Gdiplus::StringAlignmentCenter); sfC2.SetLineAlignment(Gdiplus::StringAlignmentCenter);

            // macOS normal weather trend: current conditions plus the current 3-hour slot and
            // the next three slots. The divider remains visible even when the forecast is empty.
            if (hasForecast) {
                wchar_t summary[512];
                if (to_wide(ov->forecast_summary, summary, 512) > 0) {
                    wchar_t *forecastLabel = wcschr(summary, L'|');
                    if (forecastLabel) { *forecastLabel = 0; forecastLabel++; }
                    else forecastLabel = (wchar_t *)L"";
                    Gdiplus::Font fSummary(&famEmoji, (float)(12.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::Font fForecastLabel(&famD, (float)(11.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::SolidBrush mainBrush(cr(t->dd_text)), subBrush(cr(t->dd_subtext));
                    Gdiplus::RectF summaryRect((Gdiplus::REAL)(cardLeft + 12.0 * S), (Gdiplus::REAL)(cardTop + 4.0 * S),
                                               (Gdiplus::REAL)(cardW - 100.0 * S), (Gdiplus::REAL)(22.0 * S));
                    Gdiplus::RectF labelRect((Gdiplus::REAL)(cardRight - 96.0 * S), (Gdiplus::REAL)(cardTop + 4.0 * S),
                                             (Gdiplus::REAL)(84.0 * S), (Gdiplus::REAL)(22.0 * S));
                    gfx.DrawString(summary, -1, &fSummary, summaryRect, &sfL, &mainBrush);
                    gfx.DrawString(forecastLabel, -1, &fForecastLabel, labelRect, &sfR, &subBrush);
                }

                wchar_t encoded[1024];
                if (to_wide(ov->forecast_slots, encoded, 1024) > 0) {
                    wchar_t *slots[4]; splitTabs(encoded, slots, 4);
                    const double innerLeft = cardLeft + 12.0 * S, slotW = (cardW - 24.0 * S) / 4.0;
                    Gdiplus::Font fTime(&famD, (float)(10.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::Font fWeatherEmoji(&famEmoji, (float)(16.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::Font fTemp(&famD, (float)(11.0 * S), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
                    Gdiplus::SolidBrush mainBrush(cr(t->dd_text)), subBrush(cr(t->dd_subtext));
                    for (int i = 0; i < 4 && slots[i] && slots[i][0]; i++) {
                        wchar_t *emoji = wcschr(slots[i], L'|');
                        if (!emoji) continue;
                        *emoji++ = 0;
                        wchar_t *temp = wcschr(emoji, L'|');
                        if (!temp) continue;
                        *temp++ = 0;
                        const double x = innerLeft + i * slotW;
                        Gdiplus::RectF timeRect((Gdiplus::REAL)x, (Gdiplus::REAL)(cardTop + 23.0 * S), (Gdiplus::REAL)slotW, (Gdiplus::REAL)(15.0 * S));
                        Gdiplus::RectF emojiRect((Gdiplus::REAL)x, (Gdiplus::REAL)(cardTop + 36.0 * S), (Gdiplus::REAL)slotW, (Gdiplus::REAL)(22.0 * S));
                        Gdiplus::RectF tempRect((Gdiplus::REAL)x, (Gdiplus::REAL)(cardTop + 55.0 * S), (Gdiplus::REAL)slotW, (Gdiplus::REAL)(15.0 * S));
                        gfx.DrawString(slots[i], -1, &fTime, timeRect, &sfC2, &subBrush);
                        gfx.DrawString(emoji, -1, &fWeatherEmoji, emojiRect, &sfC2, &mainBrush);
                        gfx.DrawString(temp, -1, &fTemp, tempRect, &sfC2, &mainBrush);
                    }
                }
                Gdiplus::Pen forecastDivider(cr(alpha(t->dd_border, 105)), (Gdiplus::REAL)(0.7 * S));
                gfx.DrawLine(&forecastDivider, (Gdiplus::REAL)(cardLeft + 8.0 * S), (Gdiplus::REAL)(cardTop + 75.0 * S),
                             (Gdiplus::REAL)(cardRight - 8.0 * S), (Gdiplus::REAL)(cardTop + 75.0 * S));
            }

            const double contentTop = cardTop + forecastH;
            // [By Session | By Model] segmented control.
            const double controlLeft = cardLeft + 12.0 * S, controlTop = contentTop + 8.0 * S;
            const double controlW = cardW - 24.0 * S, controlH = 26.0 * S, halfW = controlW / 2.0;
            Gdiplus::GraphicsPath controlPath; roundedPath(controlPath, controlLeft, controlTop, controlW, controlH, 8.0 * S);
            Gdiplus::SolidBrush controlBg(cr(alpha(t->dd_text, 18))); gfx.FillPath(&controlBg, &controlPath);
            Gdiplus::GraphicsPath selectedPath;
            roundedPath(selectedPath, controlLeft + (ov->detail_grouping ? halfW : 0), controlTop + 2.0 * S,
                        halfW, controlH - 4.0 * S, 6.0 * S);
            Gdiplus::SolidBrush selectedBg(cr(alpha(t->dd_text, 36))); gfx.FillPath(&selectedBg, &selectedPath);
            wchar_t controls[256];
            if (to_wide(ov->detail_controls, controls, 256) > 0) {
                wchar_t *parts[3]; splitTabs(controls, parts, 3);
                Gdiplus::Font fControl(&famD, (float)(10.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                Gdiplus::SolidBrush controlText(cr(t->dd_text));
                for (int i = 0; i < 2; i++) {
                    Gdiplus::RectF rect((Gdiplus::REAL)(controlLeft + i * halfW), (Gdiplus::REAL)controlTop,
                                       (Gdiplus::REAL)halfW, (Gdiplus::REAL)controlH);
                    gfx.DrawString(parts[i], -1, &fControl, rect, &sfC2, &controlText);
                }

                // Percent chip on the right, directly below the segmented control.
                const double chipW = 104.0 * S, chipH = 22.0 * S, chipTop = contentTop + 38.0 * S;
                const double chipLeft = cardRight - 12.0 * S - chipW;
                Gdiplus::GraphicsPath chip; roundedPath(chip, chipLeft, chipTop, chipW, chipH, chipH / 2.0);
                Gdiplus::SolidBrush chipBg(cr(alpha(t->dd_text, ov->detail_percentage ? 46 : 20))); gfx.FillPath(&chipBg, &chip);
                Gdiplus::Pen chipBorder(cr(alpha(t->dd_text, ov->detail_percentage ? 82 : 38)), (Gdiplus::REAL)(0.7 * S)); gfx.DrawPath(&chipBorder, &chip);
                Gdiplus::RectF chipRect((Gdiplus::REAL)chipLeft, (Gdiplus::REAL)chipTop, (Gdiplus::REAL)chipW, (Gdiplus::REAL)chipH);
                gfx.DrawString(parts[2], -1, &fControl, chipRect, &sfC2, &controlText);
            }

            // Column header.
            const double labelX = cardLeft + 14.0 * S;
            const double cacheW = 42.0 * S, messagesW = 38.0 * S, usageW = 68.0 * S;
            const double cacheX = cardRight - 12.0 * S - cacheW;
            const double messagesX = cacheX - messagesW;
            const double usageX = messagesX - usageW;
            wchar_t header[256];
            if (to_wide(ov->detail_header, header, 256) > 0) {
                wchar_t *parts[4]; splitTabs(header, parts, 4);
                Gdiplus::Font fHeader(&famD, (float)(9.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                Gdiplus::SolidBrush headerBrush(cr(t->dd_subtext));
                double headerTop = contentTop + 64.0 * S;
                Gdiplus::RectF lr((Gdiplus::REAL)labelX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)(usageX - labelX), (Gdiplus::REAL)(22.0 * S));
                gfx.DrawString(parts[0], -1, &fHeader, lr, &sfL, &headerBrush);
                Gdiplus::RectF ur((Gdiplus::REAL)usageX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)usageW, (Gdiplus::REAL)(22.0 * S));
                Gdiplus::RectF mr((Gdiplus::REAL)messagesX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)messagesW, (Gdiplus::REAL)(22.0 * S));
                Gdiplus::RectF crct((Gdiplus::REAL)cacheX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)cacheW, (Gdiplus::REAL)(22.0 * S));
                gfx.DrawString(parts[1], -1, &fHeader, ur, &sfR, &headerBrush);
                gfx.DrawString(parts[2], -1, &fHeader, mr, &sfR, &headerBrush);
                gfx.DrawString(parts[3], -1, &fHeader, crct, &sfR, &headerBrush);
            }

            Gdiplus::Font fParent(&famD, (float)(11.0 * S), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
            Gdiplus::Font fChild(&famD, (float)(10.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
            Gdiplus::Font fParentEmoji(&famEmoji, (float)(11.0 * S), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
            Gdiplus::Font fChildEmoji(&famEmoji, (float)(10.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
            double y = contentTop + 86.0 * S;
            wchar_t *line = wb;
            while (*line) {
                wchar_t *nl = wcschr(line, L'\n');
                if (nl) *nl = 0;
                wchar_t kind = line[0];
                wchar_t *content = (line[1] == L'|') ? line + 2 : line;
                wchar_t *parts[4]; splitTabs(content, parts, 4);
                bool child = kind == L'C';
                unsigned int rowColor = child ? t->dd_subtext : t->dd_text;
                Gdiplus::SolidBrush rowBrush(cr(rowColor));
                Gdiplus::Font *rowFont = child ? &fChild : &fParent;
                const double chevronW = 14.0 * S;
                if (!child) {
                    const wchar_t *chevron = kind == L'V' ? L"v" : L">";
                    Gdiplus::RectF chevRect((Gdiplus::REAL)labelX, (Gdiplus::REAL)y, (Gdiplus::REAL)chevronW, (Gdiplus::REAL)rowH);
                    gfx.DrawString(chevron, -1, &fChild, chevRect, &sfC2, &rowBrush);
                }
                double rowLabelX = labelX + (child ? 26.0 : 16.0) * S;
                Gdiplus::RectF lr((Gdiplus::REAL)rowLabelX, (Gdiplus::REAL)y, (Gdiplus::REAL)(usageX - rowLabelX - 4.0 * S), (Gdiplus::REAL)rowH);
                Gdiplus::Font *labelFont = child ? &fChildEmoji : &fParentEmoji;
                gfx.DrawString(parts[0], -1, labelFont, lr, &sfL, &rowBrush);
                Gdiplus::RectF ur((Gdiplus::REAL)usageX, (Gdiplus::REAL)y, (Gdiplus::REAL)usageW, (Gdiplus::REAL)rowH);
                Gdiplus::RectF mr((Gdiplus::REAL)messagesX, (Gdiplus::REAL)y, (Gdiplus::REAL)messagesW, (Gdiplus::REAL)rowH);
                Gdiplus::RectF crct((Gdiplus::REAL)cacheX, (Gdiplus::REAL)y, (Gdiplus::REAL)cacheW, (Gdiplus::REAL)rowH);
                gfx.DrawString(parts[1], -1, rowFont, ur, &sfR, &rowBrush);
                gfx.DrawString(parts[2], -1, &fChild, mr, &sfR, &rowBrush);
                gfx.DrawString(parts[3], -1, &fChild, crct, &sfR, &rowBrush);

                Gdiplus::Pen divider(cr(alpha(t->dd_border, 55)), (Gdiplus::REAL)(0.5 * S));
                gfx.DrawLine(&divider, (Gdiplus::REAL)(cardLeft + 12.0 * S), (Gdiplus::REAL)(y + rowH),
                             (Gdiplus::REAL)(cardRight - 12.0 * S), (Gdiplus::REAL)(y + rowH));
                if (!nl) break;
                line = nl + 1;
                y += rowH;
            }
        }
    }

    POINT zero{0, 0};
    RECT wrc; GetWindowRect(g_hwnd, &wrc); POINT pos{wrc.left, wrc.top};
    SIZE sz{w, h};
    BLENDFUNCTION bf; bf.BlendOp = AC_SRC_OVER; bf.BlendFlags = 0; bf.SourceConstantAlpha = g_window_alpha; bf.AlphaFormat = AC_SRC_ALPHA;
    UpdateLayeredWindow(g_hwnd, NULL, &pos, &sz, g_mem_dc, &zero, 0, &bf, ULW_ALPHA);
}

} // extern "C"
