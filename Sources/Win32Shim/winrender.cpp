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
    const double cxd = w / 2.0, cyd = expanded ? (w / 2.0) : (h / 2.0);
    const double r = w / 2.0 - 24.0;          // 表盘半径；窗口宽 = 表盘直径
    const double S = r / 116.0;               // 按 radius 116（diameter 240pt）等比缩放

    // 柔和阴影：表盘外几圈半透明黑，略向下偏移。
    for (int i = 1; i <= 6; i++) {
        Gdiplus::SolidBrush sb(Gdiplus::Color(20, 0, 0, 0));
        double rr = r + i * 1.8;
        gfx.FillEllipse(&sb, Gdiplus::REAL(cxd - rr), Gdiplus::REAL(cyd - rr + 5.0),
                        Gdiplus::REAL(rr * 2), Gdiplus::REAL(rr * 2));
    }

    // 盘体 + 外环（宽度按主题，缩放）
    {
        Gdiplus::SolidBrush fill(cr(t->dial_fill));
        gfx.FillEllipse(&fill, Gdiplus::REAL(cxd - r), Gdiplus::REAL(cyd - r),
                        Gdiplus::REAL(r * 2), Gdiplus::REAL(r * 2));
        if (t->rim_width > 0 && (t->dial_rim >> 24) > 0) {
            Gdiplus::Pen rim(cr(t->dial_rim), (Gdiplus::REAL)(t->rim_width * S));
            gfx.DrawEllipse(&rim, Gdiplus::REAL(cxd - r), Gdiplus::REAL(cyd - r),
                            Gdiplus::REAL(r * 2), Gdiplus::REAL(r * 2));
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

    if (ov) {
        textC(ov->date,    cxd, cyd - r * 0.42, (float)(11.0 * S), t->text_secondary, false);
        textC(ov->weather, cxd, cyd - r * 0.42 + 16.0 * S, (float)(13.0 * S), t->text_primary, false);
        textC(ov->tokens,   cxd, cyd + r * 0.40, (float)(20.0 * S), t->text_primary, true);
        textC(ov->messages, cxd, cyd + r * 0.40 + 18.0 * S, (float)(10.0 * S), t->text_secondary, false);
        if (!expanded) {
            textL(ov->tool_left1, cxd - r * 0.72, cyd - 10.0 * S, (float)(13.0 * S), t->text_primary);
            textL(ov->tool_left2, cxd - r * 0.72, cyd + 12.0 * S, (float)(13.0 * S), t->text_primary);
        }
    }

    // 展开态：盘面下方一张主题色「卡片」——圆角背景 + 表头 + 数据行（label 左 / value 右，缩进表子项）。
    // 行格式：表头无 \t；数据行 "label\tvalue"，前导空格为缩进。
    if (expanded) {
        wchar_t wb[2048];
        if (to_wide(ov->detail_text, wb, 2048) > 0) {
            int n = 1;
            for (wchar_t *p = wb; *p; p++) if (*p == L'\n') n++;
            const double gap = 14.0 * S, pad = 12.0 * S, rowH = 20.0 * S, radius = 12.0 * S;
            const double cardLeft = cxd - r, cardW = 2.0 * r, cardRight = cxd + r;
            const double cardTop = w + gap, cardH = 2.0 * pad + n * rowH;

            // 圆角卡片：填充 + 描边
            Gdiplus::GraphicsPath card;
            Gdiplus::REAL rr = (Gdiplus::REAL)radius;
            card.AddArc((Gdiplus::REAL)cardLeft, (Gdiplus::REAL)cardTop, 2 * rr, 2 * rr, 180, 90);
            card.AddArc((Gdiplus::REAL)(cardRight - 2 * radius), (Gdiplus::REAL)cardTop, 2 * rr, 2 * rr, 270, 90);
            card.AddArc((Gdiplus::REAL)(cardRight - 2 * radius), (Gdiplus::REAL)(cardTop + cardH - 2 * radius), 2 * rr, 2 * rr, 0, 90);
            card.AddArc((Gdiplus::REAL)cardLeft, (Gdiplus::REAL)(cardTop + cardH - 2 * radius), 2 * rr, 2 * rr, 90, 90);
            card.CloseFigure();
            Gdiplus::SolidBrush bg(cr(t->dd_bg));
            gfx.FillPath(&bg, &card);
            if ((t->dd_border >> 24) > 0) {
                Gdiplus::Pen bp(cr(t->dd_border), 1.4f);
                gfx.DrawPath(&bp, &card);
            }

            Gdiplus::FontFamily famD(L"Segoe UI");
            Gdiplus::Font fHdr(&famD, (float)(11.0 * S), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
            Gdiplus::Font fRow(&famD, (float)(12.5 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
            Gdiplus::StringFormat sfL; sfL.SetAlignment(Gdiplus::StringAlignmentNear);  sfL.SetLineAlignment(Gdiplus::StringAlignmentCenter);
            Gdiplus::StringFormat sfR; sfR.SetAlignment(Gdiplus::StringAlignmentFar);   sfR.SetLineAlignment(Gdiplus::StringAlignmentCenter);
            Gdiplus::RectF valRect((Gdiplus::REAL)(cardLeft + pad), 0.0f, (Gdiplus::REAL)(cardW - 2 * pad), (Gdiplus::REAL)rowH);

            double y = cardTop + pad + rowH / 2.0;
            wchar_t *line = wb;
            bool first = true;
            while (*line) {
                wchar_t *nl = wcschr(line, L'\n');
                if (nl) *nl = 0;
                wchar_t *tab = wcschr(line, L'\t');
                if (tab) *tab = 0;                  // 拆出 label / value
                int indent = 0; while (line[indent] == L' ') indent++;
                wchar_t *label = line + indent;
                unsigned int labelCol = first ? t->dd_subtext : (indent > 0 ? t->dd_subtext : t->dd_text);
                Gdiplus::SolidBrush lb(cr(labelCol));
                Gdiplus::RectF lr((Gdiplus::REAL)(cardLeft + pad + indent * 4.0 * S),
                                  (Gdiplus::REAL)(y - rowH / 2.0), (Gdiplus::REAL)(cardW * 0.72), (Gdiplus::REAL)rowH);
                gfx.DrawString(label, -1, first ? &fHdr : &fRow, lr, &sfL, &lb);
                if (tab) {
                    Gdiplus::SolidBrush vb(cr(t->dd_text));
                    valRect.Y = (Gdiplus::REAL)(y - rowH / 2.0);
                    gfx.DrawString(tab + 1, -1, first ? &fHdr : &fRow, valRect, &sfR, &vb);
                }
                if (!nl) break;
                line = nl + 1;
                y += rowH;
                first = false;
            }
        }
    }

    POINT zero{0, 0};
    RECT wrc; GetWindowRect(g_hwnd, &wrc); POINT pos{wrc.left, wrc.top};
    SIZE sz{w, h};
    BLENDFUNCTION bf; bf.BlendOp = AC_SRC_OVER; bf.BlendFlags = 0; bf.SourceConstantAlpha = 255; bf.AlphaFormat = AC_SRC_ALPHA;
    UpdateLayeredWindow(g_hwnd, NULL, &pos, &sz, g_mem_dc, &zero, 0, &bf, ULW_ALPHA);
}

} // extern "C"
