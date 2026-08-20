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
#include <algorithm>
#include <cmath>
#include <utility>   // std::make_pair
#include "winshim.h"

using std::max;
using std::min;

extern "C" HWND g_hwnd;   // defined in winshim.c (C linkage)

static ULONG_PTR  g_gdip_token = 0;
static HDC        g_mem_dc = NULL;
static HBITMAP    g_mem_bm = NULL;
static int        g_mem_w = 0, g_mem_h = 0;
static HDC        g_detail_mem_dc = NULL;
static HBITMAP    g_detail_mem_bm = NULL;
static int        g_detail_mem_w = 0, g_detail_mem_h = 0;
static BYTE       g_window_alpha = 255;
static Gdiplus::Image *g_dial_image = NULL;
static wchar_t    g_dial_image_path[MAX_PATH] = {0};
static Gdiplus::Bitmap *g_material_face_cache = NULL;
static int        g_material_face_cache_style = 0;
static int        g_material_face_cache_size = 0;

struct theme_picker_state {
    win_theme themes[9];
    wchar_t names[9][96];
    int count = 0;
    int selected = -1;
    int result = -1;
    bool done = false;
    HWND hwnd = NULL;
    HWND owner = NULL;
};
static theme_picker_state g_picker;

// ARGB(0xAARRGGBB) → GDI+ Color。
static Gdiplus::Color cr(unsigned int argb) {
    return Gdiplus::Color((BYTE)((argb >> 24) & 0xff), (BYTE)((argb >> 16) & 0xff),
                          (BYTE)((argb >> 8) & 0xff), (BYTE)(argb & 0xff));
}
static Gdiplus::Color fluent_cr(HWND hwnd, int role, BYTE alpha = 255) {
    unsigned int rgb = win_fluent_color(hwnd, role);
    return Gdiplus::Color(alpha, (BYTE)((rgb >> 16) & 0xff),
                         (BYTE)((rgb >> 8) & 0xff), (BYTE)(rgb & 0xff));
}
static double deg2rad(double d) { return d * 3.14159265358979 / 180.0; }
extern "C" {
static int to_wide(const char *u8, wchar_t *buf, int n);
}

// GDI+ renders Segoe UI Emoji through its monochrome outline fallback.  That made the
// Windows widget look markedly flatter than the macOS normal build, even on systems that
// have the color font installed.  Keep the strings as the shared semantic source, but map
// their leading glyph to small, resolution-independent color artwork.  Unknown glyphs still
// use the normal font fallback, so new providers remain readable without a renderer update.
enum tc_color_icon {
    TC_ICON_NONE, TC_ICON_SUN, TC_ICON_PARTLY, TC_ICON_CLOUD, TC_ICON_RAIN,
    TC_ICON_STORM, TC_ICON_SNOW, TC_ICON_FOG, TC_ICON_LOBSTER, TC_ICON_STAR,
    TC_ICON_ROBOT, TC_ICON_OCTOPUS, TC_ICON_PURPLE, TC_ICON_BOLT,
    TC_ICON_HANDSHAKE, TC_ICON_SHIELD, TC_ICON_PLAY, TC_ICON_MOUSE,
    TC_ICON_BRAIN, TC_ICON_GEM, TC_ICON_MOUNTAIN, TC_ICON_MEDICAL,
    TC_ICON_SLEEP, TC_ICON_BED, TC_ICON_COFFEE, TC_ICON_RUNNER, TC_ICON_FLAME,
    TC_ICON_BURST, TC_ICON_MOON, TC_ICON_WHALE, TC_ICON_SPEAKER,
    TC_ICON_RECYCLE
};

static tc_color_icon color_icon_for(const wchar_t *text) {
    if (!text || !*text) return TC_ICON_NONE;
    if (wcsstr(text, L"⛈") || wcsstr(text, L"🌩")) return TC_ICON_STORM;
    if (wcsstr(text, L"🌨") || wcsstr(text, L"❄")) return TC_ICON_SNOW;
    if (wcsstr(text, L"🌧") || wcsstr(text, L"🌦")) return TC_ICON_RAIN;
    if (wcsstr(text, L"🌤") || wcsstr(text, L"⛅")) return TC_ICON_PARTLY;
    if (wcsstr(text, L"🌫")) return TC_ICON_FOG;
    if (wcsstr(text, L"☁")) return TC_ICON_CLOUD;
    if (wcsstr(text, L"☀")) return TC_ICON_SUN;
    if (wcsstr(text, L"🦞")) return TC_ICON_LOBSTER;
    if (wcsstr(text, L"✨") || wcsstr(text, L"✳")) return TC_ICON_STAR;
    if (wcsstr(text, L"🤖")) return TC_ICON_ROBOT;
    if (wcsstr(text, L"🐙")) return TC_ICON_OCTOPUS;
    if (wcsstr(text, L"🟣")) return TC_ICON_PURPLE;
    if (wcsstr(text, L"⚡")) return TC_ICON_BOLT;
    if (wcsstr(text, L"🤝")) return TC_ICON_HANDSHAKE;
    if (wcsstr(text, L"🛡")) return TC_ICON_SHIELD;
    if (wcsstr(text, L"▶")) return TC_ICON_PLAY;
    if (wcsstr(text, L"🖱")) return TC_ICON_MOUSE;
    if (wcsstr(text, L"🧠")) return TC_ICON_BRAIN;
    if (wcsstr(text, L"💎")) return TC_ICON_GEM;
    if (wcsstr(text, L"🏔")) return TC_ICON_MOUNTAIN;
    if (wcsstr(text, L"⚕")) return TC_ICON_MEDICAL;
    if (wcsstr(text, L"💤")) return TC_ICON_SLEEP;
    if (wcsstr(text, L"🛌")) return TC_ICON_BED;
    if (wcsstr(text, L"☕")) return TC_ICON_COFFEE;
    if (wcsstr(text, L"🏃")) return TC_ICON_RUNNER;
    if (wcsstr(text, L"🔥")) return TC_ICON_FLAME;
    if (wcsstr(text, L"💥")) return TC_ICON_BURST;
    if (wcsstr(text, L"🌙")) return TC_ICON_MOON;
    if (wcsstr(text, L"🐋")) return TC_ICON_WHALE;
    if (wcsstr(text, L"🔊")) return TC_ICON_SPEAKER;
    if (wcsstr(text, L"♻")) return TC_ICON_RECYCLE;
    return TC_ICON_NONE;
}

static const wchar_t *text_after_icon(const wchar_t *text) {
    if (color_icon_for(text) == TC_ICON_NONE) return text;
    const wchar_t *space = wcschr(text, L' ');
    if (!space) return text + wcslen(text);
    while (*space == L' ') ++space;
    return space;
}

static void draw_color_icon(Gdiplus::Graphics &gfx, tc_color_icon icon,
                            float cx, float cy, float size) {
    using namespace Gdiplus;
    if (icon == TC_ICON_NONE || size <= 0) return;
    const float s = size / 24.0f;
    auto ellipse = [&](float x, float y, float w, float h, BYTE r, BYTE g, BYTE b) {
        SolidBrush fill(Color(255, r, g, b));
        gfx.FillEllipse(&fill, cx + x*s, cy + y*s, w*s, h*s);
    };
    auto line = [&](float x1, float y1, float x2, float y2, BYTE r, BYTE g, BYTE b, float w = 1.8f) {
        Pen stroke(Color(255, r, g, b), w * s);
        stroke.SetStartCap(LineCapRound); stroke.SetEndCap(LineCapRound);
        gfx.DrawLine(&stroke, cx+x1*s, cy+y1*s, cx+x2*s, cy+y2*s);
    };
    auto polygon = [&](const PointF *points, int count, BYTE r, BYTE g, BYTE b) {
        PointF p[16]; for (int i=0; i<count; ++i) p[i] = PointF(cx+points[i].X*s, cy+points[i].Y*s);
        SolidBrush fill(Color(255, r, g, b)); gfx.FillPolygon(&fill, p, count);
    };
    auto cloud = [&](float dx, float dy) {
        ellipse(dx-8,dy-1,16,7,238,243,249); ellipse(dx-6,dy-5,9,9,247,250,253); ellipse(dx,dy-4,8,8,231,238,246);
        Pen edge(Color(255,126,145,166),1.0f*s); gfx.DrawArc(&edge,cx+(dx-8)*s,cy+(dy-1)*s,16*s,7*s,0,180);
    };

    switch (icon) {
    case TC_ICON_SUN:
        ellipse(-5,-5,10,10,255,190,38);
        for (int i=0;i<8;i++) { double a=deg2rad(i*45.0); line((float)cos(a)*7,(float)sin(a)*7,(float)cos(a)*10,(float)sin(a)*10,246,156,22,1.5f); }
        break;
    case TC_ICON_PARTLY:
        ellipse(-7,-8,10,10,255,188,37); cloud(2,2); break;
    case TC_ICON_CLOUD: cloud(0,0); break;
    case TC_ICON_RAIN:
        cloud(0,-3); for(int i=-1;i<=1;i++) line(i*5-1,3,i*5-3,8,52,144,220,1.7f); break;
    case TC_ICON_STORM: {
        cloud(0,-3); PointF p[]={{-1,2},{4,2},{1,7},{5,7},{-2,12},{0,6},{-4,6}}; polygon(p,7,250,183,34); break;
    }
    case TC_ICON_SNOW:
        cloud(0,-4); for(int i=-1;i<=1;i++){ ellipse(i*6-1,5,2.4f,2.4f,92,176,235); line(i*6-3,6,i*6+3,6,92,176,235,1.0f); } break;
    case TC_ICON_FOG:
        cloud(0,-5); for(int i=0;i<3;i++) line(-8,3+i*3,8,3+i*3,143,158,174,1.4f); break;
    case TC_ICON_LOBSTER:
        ellipse(-4,-6,8,14,232,73,64); ellipse(-8,-7,5,5,242,102,83); ellipse(3,-7,5,5,242,102,83);
        line(-2,-5,-7,-10,205,49,46,1.5f); line(2,-5,7,-10,205,49,46,1.5f);
        for(int i=-1;i<=1;i+=2){ line(i*3,-1,i*9,-3,205,49,46,1.5f); line(i*3,3,i*9,5,205,49,46,1.5f); } break;
    case TC_ICON_STAR: {
        PointF p[10]; for(int i=0;i<10;i++){ double a=deg2rad(-90+i*36.0); float rr=(i%2)?4.2f:9.5f; p[i]=PointF((float)cos(a)*rr,(float)sin(a)*rr); }
        polygon(p,10,250,183,34); break;
    }
    case TC_ICON_ROBOT: {
        GraphicsPath body; body.AddArc(cx-8*s,cy-6*s,16*s,14*s,180,180); body.AddLine(cx+8*s,cy+1*s,cx+8*s,cy+7*s); body.AddLine(cx-8*s,cy+7*s,cx-8*s,cy+1*s); body.CloseFigure();
        SolidBrush fill(Color(255,105,118,216)); gfx.FillPath(&fill,&body); ellipse(-4,-1,2.7f,2.7f,244,248,255); ellipse(1.3f,-1,2.7f,2.7f,244,248,255); line(0,-6,0,-10,76,87,180,1.4f); ellipse(-1,-11,2,2,250,183,34); break;
    }
    case TC_ICON_OCTOPUS:
        ellipse(-7,-8,14,14,107,94,207); ellipse(-4,-3,2.2f,2.2f,255,255,255); ellipse(2,-3,2.2f,2.2f,255,255,255);
        for(int i=-3;i<=3;i+=2) { line(i,4,i*1.7f,10,84,70,184,2.0f); } break;
    case TC_ICON_PURPLE: ellipse(-8,-8,16,16,155,89,221); ellipse(-3,-4,4,4,211,171,246); break;
    case TC_ICON_BOLT: { PointF p[]={{1,-11},{-7,1},{-1,1},{-4,11},{8,-3},{2,-3}}; polygon(p,6,250,183,34); break; }
    case TC_ICON_HANDSHAKE:
        line(-9,-3,-2,4,224,158,108,4.4f); line(9,-3,2,4,180,118,79,4.4f); line(-2,3,2,3,126,80,60,2.0f); break;
    case TC_ICON_SHIELD: { PointF p[]={{0,-10},{9,-6},{7,4},{0,11},{-7,4},{-9,-6}}; polygon(p,6,65,132,214); line(-4,0,-1,4,4,76,132,1.8f); line(-1,4,5,-4,4,76,132,1.8f); break; }
    case TC_ICON_PLAY: { PointF p[]={{-6,-9},{9,0},{-6,9}}; polygon(p,3,47,171,103); break; }
    case TC_ICON_MOUSE:
        ellipse(-6,-10,12,20,78,132,196); line(0,-9,0,-2,221,235,250,1.2f); line(0,-2,5,-2,221,235,250,1.0f); break;
    case TC_ICON_BRAIN:
        ellipse(-8,-7,9,14,238,124,165); ellipse(-1,-8,9,15,244,145,181); line(0,-6,0,7,174,72,115,1.2f); line(-6,-2,-2,0,174,72,115,1.0f); line(6,-2,2,1,174,72,115,1.0f); break;
    case TC_ICON_GEM: { PointF p[]={{-8,-5},{-3,-9},{4,-9},{9,-4},{0,10}}; polygon(p,5,53,170,232); line(-8,-5,9,-4,205,241,255,1.0f); line(-3,-9,0,10,205,241,255,1.0f); line(4,-9,0,10,205,241,255,1.0f); break; }
    case TC_ICON_MOUNTAIN: { PointF p[]={{-11,9},{-3,-8},{2,0},{6,-6},{11,9}}; polygon(p,5,69,137,102); PointF snow[]={{-6,-2},{-3,-8},{0,-2},{-3,0}}; polygon(snow,4,240,246,249); break; }
    case TC_ICON_MEDICAL:
        line(0,-10,0,10,52,162,155,2.0f); line(-6,-4,6,-4,52,162,155,1.5f); ellipse(-3,-9,6,6,238,94,105); break;
    case TC_ICON_SLEEP:
        for(int i=0;i<3;i++){ float o=(float)i*4; line(-8+o,-6+o,-3+o,-6+o,83,106,196,1.7f); line(-3+o,-6+o,-8+o,-1+o,83,106,196,1.7f); line(-8+o,-1+o,-3+o,-1+o,83,106,196,1.7f); } break;
    case TC_ICON_BED:
        line(-10,7,10,7,70,82,106,2.2f); line(-9,-7,-9,10,70,82,106,2.2f);
        { Gdiplus::SolidBrush cover(Gdiplus::Color(255,93,142,214)); gfx.FillRectangle(&cover,cx-7*s,cy-1*s,17*s,7*s); }
        ellipse(-7,-5,7,5,246,190,140); line(-9,9,-9,11,70,82,106,1.6f); line(9,9,9,11,70,82,106,1.6f); break;
    case TC_ICON_COFFEE:
        { GraphicsPath cup; cup.AddArc(cx-8*s,cy-3*s,14*s,12*s,0,180); cup.AddLine(cx-8*s,cy+3*s,cx-8*s,cy-3*s); cup.CloseFigure(); SolidBrush fill(Color(255,151,94,55)); gfx.FillPath(&fill,&cup); Pen edge(Color(255,107,64,39),1.6f*s); gfx.DrawEllipse(&edge,cx+4*s,cy-2*s,6*s,6*s); line(-4,-6,-3,-10,202,211,219,1.3f); line(1,-6,2,-10,202,211,219,1.3f); } break;
    case TC_ICON_RUNNER:
        ellipse(-1,-10,4,4,49,151,100); line(0,-5,-2,2,49,151,100,2.1f); line(-2,2,-7,8,49,151,100,2.0f); line(-1,1,5,7,49,151,100,2.0f); line(-1,-3,-7,0,49,151,100,2.0f); line(0,-3,6,-1,49,151,100,2.0f); break;
    case TC_ICON_FLAME: { PointF p[]={{0,-11},{6,-3},{4,2},{9,1},{5,10},{-5,10},{-9,2},{-4,-5},{-2,1}}; polygon(p,9,241,87,52); PointF q[]={{0,-2},{4,4},{1,9},{-3,7},{-3,3}}; polygon(q,5,255,190,38); break; }
    case TC_ICON_BURST: { PointF p[16]; for(int i=0;i<16;i++){ double a=deg2rad(i*22.5); float rr=(i%2)?4.5f:10.5f; p[i]=PointF((float)cos(a)*rr,(float)sin(a)*rr); } polygon(p,16,236,68,77); ellipse(-3,-3,6,6,255,198,39); break; }
    case TC_ICON_MOON: ellipse(-8,-9,16,18,250,196,55); ellipse(-3,-11,14,17,246,246,248); break;
    case TC_ICON_WHALE:
        ellipse(-9,-5,17,11,53,145,207); { PointF p[]={{7,-1},{11,-6},{10,1},{11,6},{6,2}}; polygon(p,5,53,145,207); } ellipse(-5,-2,2,2,250,252,255); break;
    case TC_ICON_SPEAKER: { PointF p[]={{-9,-3},{-4,-3},{2,-9},{2,9},{-4,3},{-9,3}}; polygon(p,6,72,133,217); for(int i=0;i<2;i++){ Pen wave(Color(255,72,133,217),(1.5f+i*.2f)*s); gfx.DrawArc(&wave,cx+(2+i*3)*s,cy+(-6-i*2)*s,(8+i*4)*s,(12+i*4)*s,-60,120); } break; }
    case TC_ICON_RECYCLE:
        for(int i=0;i<3;i++){ double a=deg2rad(-90+i*120.0); double b=a+2.0; PointF p[]={{(float)cos(a)*9,(float)sin(a)*9},{(float)cos(b)*7,(float)sin(b)*7},{(float)cos(a+0.7)*4,(float)sin(a+0.7)*4}}; polygon(p,3,48,168,104); } break;
    default: break;
    }
}

static void picker_rounded_path(Gdiplus::GraphicsPath &path, float x, float y, float w, float h, float r) {
    path.AddArc(x, y, r * 2, r * 2, 180, 90);
    path.AddArc(x + w - r * 2, y, r * 2, r * 2, 270, 90);
    path.AddArc(x + w - r * 2, y + h - r * 2, r * 2, r * 2, 0, 90);
    path.AddArc(x, y + h - r * 2, r * 2, r * 2, 90, 90);
    path.CloseFigure();
}

/* The layered dial cannot receive DWM Acrylic directly, so its material is drawn as a
 * compact vector surface.  The full-size result is cached below: these gradients, grain
 * and highlights are rebuilt only when the face or size changes, never on the one-second
 * hand refresh.  Picker previews use the same renderer at thumbnail scale. */
static void material_grain(Gdiplus::Graphics &gfx, Gdiplus::GraphicsPath &clip,
                           float cx, float cy, float radius, int style, bool preview) {
    Gdiplus::GraphicsState state = gfx.Save();
    gfx.SetClip(&clip);
    unsigned int seed = 0x9e3779b9u ^ (unsigned int)(style * 0x45d9f3bu);
    const int count = preview ? 36 : 180;
    const float diameter = radius * 1.76f;
    const float dot = preview ? 0.42f : max(0.55f, radius / 230.0f);
    for (int i = 0; i < count; i++) {
        seed = seed * 1664525u + 1013904223u;
        float x = cx - diameter * 0.5f + diameter * (float)(seed & 0xffffu) / 65535.0f;
        seed = seed * 1664525u + 1013904223u;
        float y = cy - diameter * 0.5f + diameter * (float)(seed & 0xffffu) / 65535.0f;
        float dx = x - cx, dy = y - cy;
        if (dx * dx + dy * dy > radius * radius * 0.80f) continue;
        seed = seed * 1664525u + 1013904223u;
        bool light = (seed & 1u) != 0;
        BYTE alpha = (BYTE)(style == 2 ? (light ? 17 : 10) : (light ? 15 : 12));
        BYTE tone = style == 3 ? (light ? 222 : 8) : (light ? 255 : 73);
        Gdiplus::SolidBrush grain(Gdiplus::Color(alpha, tone, tone, tone));
        gfx.FillEllipse(&grain, x, y, dot, dot);
    }
    gfx.Restore(state);
}

static void draw_material_face(Gdiplus::Graphics &gfx, const win_theme &theme,
                               float cx, float cy, float radius, bool preview) {
    using namespace Gdiplus;
    const float faceR = radius - (preview ? 0.45f : 1.25f);

    SolidBrush shadow(theme.material_style == 3
                          ? Color(90, 0, 0, 0)
                          : Color(48, 30, 43, 55));
    gfx.FillEllipse(&shadow, cx - faceR - 0.8f, cy - faceR + (preview ? 0.9f : 2.0f),
                    faceR * 2.0f + 1.6f, faceR * 2.0f + 1.2f);

    GraphicsPath face;
    face.AddEllipse(cx - faceR, cy - faceR, faceR * 2.0f, faceR * 2.0f);

    if (theme.material_style == 1) {
        // Frost: a cool translucent crystal, brighter at the upper-left and denser below.
        LinearGradientBrush base(PointF(cx - faceR, cy - faceR), PointF(cx + faceR, cy + faceR),
                                 Color(252, 250, 253, 255), Color(247, 204, 220, 235));
        base.SetGammaCorrection(TRUE);
        gfx.FillPath(&base, &face);

        PathGradientBrush edge(&face);
        edge.SetCenterPoint(PointF(cx - faceR * 0.24f, cy - faceR * 0.30f));
        edge.SetCenterColor(Color(16, 255, 255, 255));
        Color surround[1] = { Color(78, 73, 111, 140) }; INT surroundCount = 1;
        edge.SetSurroundColors(surround, &surroundCount);
        gfx.FillPath(&edge, &face);

        Pen innerLight(Color(170, 255, 255, 255), preview ? 0.8f : 1.25f);
        gfx.DrawArc(&innerLight, cx - faceR + 2.0f, cy - faceR + 2.0f,
                    (faceR - 2.0f) * 2.0f, (faceR - 2.0f) * 2.0f, 203.0f, 150.0f);
        Pen reflection(Color(102, 255, 255, 255), preview ? 1.0f : 2.0f);
        reflection.SetLineCap(LineCapRound, LineCapRound, DashCapRound);
        gfx.DrawArc(&reflection, cx - faceR * 0.73f, cy - faceR * 0.76f,
                    faceR * 1.46f, faceR * 1.30f, 207.0f, 102.0f);
        material_grain(gfx, face, cx, cy, faceR, theme.material_style, preview);

        Pen outer(Color(190, 238, 248, 255), preview ? 0.9f : 1.5f);
        Pen inner(Color(92, 70, 105, 132), preview ? 0.7f : 1.0f);
        gfx.DrawEllipse(&outer, cx - faceR, cy - faceR, faceR * 2.0f, faceR * 2.0f);
        gfx.DrawEllipse(&inner, cx - faceR + 2.2f, cy - faceR + 2.2f,
                        (faceR - 2.2f) * 2.0f, (faceR - 2.2f) * 2.0f);
    } else if (theme.material_style == 2) {
        // Porcelain: warm glaze with a soft centre bloom and a pressed ceramic rim.
        LinearGradientBrush base(PointF(cx - faceR, cy - faceR), PointF(cx + faceR, cy + faceR),
                                 Color(255, 255, 253, 245), Color(255, 229, 221, 207));
        base.SetGammaCorrection(TRUE);
        gfx.FillPath(&base, &face);

        PathGradientBrush glaze(&face);
        glaze.SetCenterPoint(PointF(cx - faceR * 0.18f, cy - faceR * 0.22f));
        glaze.SetCenterColor(Color(92, 255, 255, 250));
        Color surround[1] = { Color(72, 165, 148, 126) }; INT surroundCount = 1;
        glaze.SetSurroundColors(surround, &surroundCount);
        gfx.FillPath(&glaze, &face);
        material_grain(gfx, face, cx, cy, faceR, theme.material_style, preview);

        Pen glazeLine(Color(190, 255, 255, 251), preview ? 0.9f : 1.6f);
        gfx.DrawArc(&glazeLine, cx - faceR + 1.5f, cy - faceR + 1.5f,
                    (faceR - 1.5f) * 2.0f, (faceR - 1.5f) * 2.0f, 198.0f, 150.0f);
        Pen warmRim(Color(185, 151, 137, 112), preview ? 1.0f : 1.7f);
        Pen pressed(Color(105, 104, 89, 72), preview ? 0.7f : 0.95f);
        gfx.DrawEllipse(&warmRim, cx - faceR, cy - faceR, faceR * 2.0f, faceR * 2.0f);
        gfx.DrawEllipse(&pressed, cx - faceR + 2.4f, cy - faceR + 2.4f,
                        (faceR - 2.4f) * 2.0f, (faceR - 2.4f) * 2.0f);
    } else {
        // Smoked Glass: blue-black glass with restrained edge light and a diagonal sheen.
        LinearGradientBrush base(PointF(cx - faceR, cy - faceR), PointF(cx + faceR, cy + faceR),
                                 Color(248, 40, 54, 67), Color(248, 7, 12, 18));
        base.SetGammaCorrection(TRUE);
        gfx.FillPath(&base, &face);

        PathGradientBrush depth(&face);
        depth.SetCenterPoint(PointF(cx - faceR * 0.20f, cy - faceR * 0.28f));
        depth.SetCenterColor(Color(42, 79, 112, 134));
        Color surround[1] = { Color(132, 0, 4, 9) }; INT surroundCount = 1;
        depth.SetSurroundColors(surround, &surroundCount);
        gfx.FillPath(&depth, &face);
        material_grain(gfx, face, cx, cy, faceR, theme.material_style, preview);

        GraphicsState state = gfx.Save();
        gfx.SetClip(&face);
        LinearGradientBrush sheen(PointF(cx - faceR, cy - faceR * 0.85f),
                                  PointF(cx + faceR * 0.35f, cy + faceR * 0.45f),
                                  Color(22, 184, 224, 245), Color(0, 184, 224, 245));
        gfx.FillEllipse(&sheen, cx - faceR * 1.08f, cy - faceR * 1.02f,
                        faceR * 1.62f, faceR * 0.78f);
        gfx.Restore(state);

        Pen outer(Color(195, 131, 160, 181), preview ? 0.9f : 1.45f);
        Pen inner(Color(130, 22, 42, 56), preview ? 0.7f : 1.1f);
        gfx.DrawEllipse(&outer, cx - faceR, cy - faceR, faceR * 2.0f, faceR * 2.0f);
        gfx.DrawEllipse(&inner, cx - faceR + 2.4f, cy - faceR + 2.4f,
                        (faceR - 2.4f) * 2.0f, (faceR - 2.4f) * 2.0f);
        Pen reflection(Color(88, 225, 244, 255), preview ? 1.0f : 1.8f);
        reflection.SetLineCap(LineCapRound, LineCapRound, DashCapRound);
        gfx.DrawArc(&reflection, cx - faceR * 0.76f, cy - faceR * 0.78f,
                    faceR * 1.52f, faceR * 1.35f, 207.0f, 86.0f);
    }
}

static bool draw_cached_material_face(Gdiplus::Graphics &gfx, const win_theme &theme,
                                      float cx, float cy, int faceSize) {
    if (theme.material_style <= 0 || faceSize <= 8) return false;
    if (!g_material_face_cache || g_material_face_cache_style != theme.material_style ||
        g_material_face_cache_size != faceSize) {
        delete g_material_face_cache;
        g_material_face_cache = new Gdiplus::Bitmap(faceSize, faceSize, PixelFormat32bppPARGB);
        g_material_face_cache_style = theme.material_style;
        g_material_face_cache_size = faceSize;
        if (!g_material_face_cache || g_material_face_cache->GetLastStatus() != Gdiplus::Ok) return false;
        Gdiplus::Graphics cached(g_material_face_cache);
        cached.Clear(Gdiplus::Color(0, 0, 0, 0));
        cached.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        cached.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);
        draw_material_face(cached, theme, faceSize * 0.5f, faceSize * 0.5f,
                           faceSize * 0.5f - 4.0f, false);
    }
    gfx.DrawImage(g_material_face_cache,
                  Gdiplus::RectF(cx - faceSize * 0.5f, cy - faceSize * 0.5f,
                                 (Gdiplus::REAL)faceSize, (Gdiplus::REAL)faceSize));
    return true;
}

static void draw_picker_cell(DRAWITEMSTRUCT *item) {
    int index = (int)item->CtlID - 5000;
    if (index < 0 || index >= g_picker.count) return;
    const win_theme &theme = g_picker.themes[index];
    const RECT &rcItem = item->rcItem;
    const float w = (float)(rcItem.right - rcItem.left), h = (float)(rcItem.bottom - rcItem.top);
    win_fluent_paint_parent(item->hwndItem, item->hDC, &rcItem);
    Gdiplus::Graphics gfx(item->hDC);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

    Gdiplus::GraphicsPath card;
    picker_rounded_path(card, 3, 3, w - 6, h - 6, 12);
    Gdiplus::SolidBrush cardBrush(item->itemState & ODS_SELECTED
                                     ? fluent_cr(g_picker.hwnd, WIN_FLUENT_COLOR_SURFACE)
                                     : fluent_cr(g_picker.hwnd, WIN_FLUENT_COLOR_SURFACE, 245));
    gfx.FillPath(&cardBrush, &card);
    Gdiplus::Pen border(index == g_picker.selected
                            ? fluent_cr(g_picker.hwnd, WIN_FLUENT_COLOR_ACCENT)
                            : fluent_cr(g_picker.hwnd, WIN_FLUENT_COLOR_BORDER, 150),
                        index == g_picker.selected ? 2.6f : 1.0f);
    gfx.DrawPath(&border, &card);

    const float cx = w / 2.0f, cy = 48.0f, radius = 34.0f;
    if (theme.material_style > 0) {
        draw_material_face(gfx, theme, cx, cy, radius, true);
    } else {
        Gdiplus::SolidBrush dial(cr(theme.dial_fill));
        gfx.FillEllipse(&dial, cx - radius, cy - radius, radius * 2, radius * 2);
        if ((theme.dial_rim >> 24) && theme.rim_width > 0) {
            Gdiplus::Pen rim(cr(theme.dial_rim), (float)max(1.0, theme.rim_width * 0.42));
            gfx.DrawEllipse(&rim, cx - radius, cy - radius, radius * 2, radius * 2);
        }
    }
    if (theme.show_ticks) {
        const int tickCount = theme.material_style > 0 ? 60 : 12;
        for (int tick = 0; tick < tickCount; tick++) {
            double angle = deg2rad(tick * (360.0 / tickCount) - 90.0);
            int minute = theme.material_style > 0 ? tick : tick * 5;
            bool major = minute % 15 == 0, hour = minute % 5 == 0;
            float inner = radius * (major ? 0.78f : (hour ? 0.84f : 0.89f));
            float outer = radius * 0.94f;
            Gdiplus::Pen pen(cr(major || hour ? theme.major_tick_color : theme.tick_color),
                             major ? 1.45f : (hour ? 1.0f : 0.55f));
            gfx.DrawLine(&pen,
                         Gdiplus::PointF(cx + (float)cos(angle) * inner, cy + (float)sin(angle) * inner),
                         Gdiplus::PointF(cx + (float)cos(angle) * outer, cy + (float)sin(angle) * outer));
        }
    }
    auto hand = [&](double degrees, float length, float width, unsigned int color) {
        double angle = deg2rad(degrees - 90.0);
        Gdiplus::Pen pen(cr(color), width);
        pen.SetLineCap(Gdiplus::LineCapRound, Gdiplus::LineCapRound, Gdiplus::DashCapRound);
        gfx.DrawLine(&pen, Gdiplus::PointF(cx, cy),
                     Gdiplus::PointF(cx + (float)cos(angle) * length, cy + (float)sin(angle) * length));
    };
    hand(312, radius * 0.43f, 3.1f, theme.hour_color);
    hand(186, radius * 0.64f, 2.2f, theme.minute_color);
    hand(235, radius * 0.74f, 1.1f, theme.second_color);
    Gdiplus::SolidBrush cap(cr(theme.cap_outer));
    gfx.FillEllipse(&cap, cx - 3.0f, cy - 3.0f, 6.0f, 6.0f);

    Gdiplus::FontFamily family(L"Segoe UI");
    Gdiplus::Font font(&family, 12.0f, index == g_picker.selected ? Gdiplus::FontStyleBold : Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::SolidBrush text(fluent_cr(g_picker.hwnd, WIN_FLUENT_COLOR_TEXT));
    Gdiplus::StringFormat format; format.SetAlignment(Gdiplus::StringAlignmentCenter); format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::RectF label(5, h - 35, w - 10, 27);
    gfx.DrawString(g_picker.names[index], -1, &font, label, &format, &text);
}

static BOOL CALLBACK invalidate_picker_child(HWND child, LPARAM) {
    InvalidateRect(child, NULL, TRUE);
    return TRUE;
}

static LRESULT CALLBACK theme_picker_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_CREATE:
        win_fluent_apply(hwnd, WIN_FLUENT_ACRYLIC);
        return 0;
    case WM_ERASEBKGND: {
        RECT rect; GetClientRect(hwnd, &rect);
        win_fluent_paint_fallback(hwnd, (void *)wp, &rect);
        return 1;
    }
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        win_fluent_apply(hwnd, WIN_FLUENT_ACRYLIC);
        InvalidateRect(hwnd, NULL, TRUE);
        EnumChildWindows(hwnd, invalidate_picker_child, 0);
        return 0;
    case WM_DRAWITEM:
        draw_picker_cell((DRAWITEMSTRUCT *)lp);
        return TRUE;
    case WM_COMMAND: {
        int id = LOWORD(wp);
        if (id >= 5000 && id < 5000 + g_picker.count) {
            g_picker.result = id - 5000;
            g_picker.done = true;
            ShowWindow(hwnd, SW_HIDE);
            return 0;
        }
        break;
    }
    case WM_KEYDOWN:
        if (wp == VK_ESCAPE) { g_picker.result = -1; g_picker.done = true; ShowWindow(hwnd, SW_HIDE); return 0; }
        break;
    case WM_CLOSE:
        g_picker.result = -1; g_picker.done = true; ShowWindow(hwnd, SW_HIDE); return 0;
    case WM_NCDESTROY:
        win_fluent_forget(hwnd);
        break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

extern "C" {

void gdip_init(void) {
    Gdiplus::GdiplusStartupInput si;
    Gdiplus::GdiplusStartup(&g_gdip_token, &si, NULL);
}
void gdip_shutdown(void) {
    if (g_dial_image) { delete g_dial_image; g_dial_image = NULL; g_dial_image_path[0] = 0; }
    if (g_material_face_cache) { delete g_material_face_cache; g_material_face_cache = NULL; }
    g_material_face_cache_style = 0; g_material_face_cache_size = 0;
    /* A bitmap cannot be deleted while selected into a memory DC. Destroying the DC first
     * releases the selection; reversing this order leaks one GDI bitmap per cache resize. */
    if (g_mem_dc) { DeleteDC(g_mem_dc); g_mem_dc = NULL; }
    if (g_mem_bm) { DeleteObject(g_mem_bm); g_mem_bm = NULL; }
    if (g_detail_mem_dc) { DeleteDC(g_detail_mem_dc); g_detail_mem_dc = NULL; }
    if (g_detail_mem_bm) { DeleteObject(g_detail_mem_bm); g_detail_mem_bm = NULL; }
    if (g_gdip_token) { Gdiplus::GdiplusShutdown(g_gdip_token); g_gdip_token = 0; }
}

void win_render_set_opacity(double alpha) {
    if (alpha < 0.0) alpha = 0.0;
    if (alpha > 1.0) alpha = 1.0;
    g_window_alpha = (BYTE)std::lround(alpha * 255.0);
}

int win_theme_picker(const win_theme *themes, const char **names_utf8, int count,
                     int selected, const char *title_utf8) {
    if (!themes || !names_utf8 || count <= 0) return -1;
    count = min(9, count);
    g_picker = theme_picker_state();
    g_picker.count = count;
    g_picker.selected = selected;
    for (int i = 0; i < count; i++) {
        g_picker.themes[i] = themes[i];
        if (to_wide(names_utf8[i], g_picker.names[i], 96) == 0) g_picker.names[i][0] = 0;
    }

    static bool registered = false;
    if (!registered) {
        WNDCLASSEXW wc = {0}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = theme_picker_proc;
        wc.hInstance = GetModuleHandleW(NULL); wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
        wc.hbrBackground = NULL; wc.lpszClassName = L"TCThemePicker";
        RegisterClassExW(&wc); registered = true;
    }
    wchar_t title[256]; if (to_wide(title_utf8, title, 256) == 0) wcscpy_s(title, L"Select Clock Face");
    const int windowW = 520, windowH = 474;
    RECT work; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int x = work.left + (work.right - work.left - windowW) / 2;
    int y = work.top + (work.bottom - work.top - windowH) / 2;
    g_picker.owner = IsWindow(g_hwnd) ? g_hwnd : NULL;
    g_picker.hwnd = CreateWindowExW(WS_EX_DLGMODALFRAME, L"TCThemePicker", title,
                                    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
                                    x, y, windowW, windowH, g_picker.owner, NULL, GetModuleHandleW(NULL), NULL);
    if (!g_picker.hwnd) return -1;
    for (int i = 0; i < count; i++) {
        int col = i % 3, row = i / 3;
        HWND cell = CreateWindowExW(0, L"BUTTON", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                    18 + col * 164, 14 + row * 136, 154, 126,
                                    g_picker.hwnd, (HMENU)(LONG_PTR)(5000 + i), GetModuleHandleW(NULL), NULL);
        win_fluent_theme_child(cell);
    }
    if (g_picker.owner) EnableWindow(g_picker.owner, FALSE);
    ShowWindow(g_picker.hwnd, SW_SHOWNORMAL); UpdateWindow(g_picker.hwnd); SetForegroundWindow(g_picker.hwnd);
    MSG message;
    while (!g_picker.done && GetMessageW(&message, NULL, 0, 0) > 0) {
        if (IsDialogMessageW(g_picker.hwnd, &message)) continue;
        TranslateMessage(&message); DispatchMessageW(&message);
    }
    if (g_picker.owner) { EnableWindow(g_picker.owner, TRUE); SetForegroundWindow(g_picker.owner); }
    if (IsWindow(g_picker.hwnd)) DestroyWindow(g_picker.hwnd);
    return g_picker.result;
}

static void ensure_mem(int w, int h) {
    if (g_mem_dc && g_mem_w == w && g_mem_h == h) return;
    if (g_mem_dc) DeleteDC(g_mem_dc);
    if (g_mem_bm) DeleteObject(g_mem_bm);
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

static void ensure_detail_mem(int w, int h) {
    if (g_detail_mem_dc && g_detail_mem_w == w && g_detail_mem_h == h) return;
    if (g_detail_mem_dc) DeleteDC(g_detail_mem_dc);
    if (g_detail_mem_bm) DeleteObject(g_detail_mem_bm);
    HDC screen = GetDC(NULL);
    g_detail_mem_dc = CreateCompatibleDC(screen);
    BITMAPINFO bi; memset(&bi, 0, sizeof(bi));
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    g_detail_mem_bm = CreateDIBSection(screen, &bi, DIB_RGB_COLORS, NULL, NULL, 0);
    ReleaseDC(NULL, screen);
    SelectObject(g_detail_mem_dc, g_detail_mem_bm);
    g_detail_mem_w = w; g_detail_mem_h = h;
}

typedef BOOL (WINAPI *tc_alpha_blend_t)(HDC, int, int, int, int, HDC, int, int, int, int, BLENDFUNCTION);

void win_render_detail_paint(void *device_context, int w, int h) {
    HDC dc = (HDC)device_context;
    if (!dc || !g_detail_mem_dc || !g_detail_mem_bm || w <= 0 || h <= 0) return;
    static tc_alpha_blend_t alpha_blend = NULL;
    static int attempted = 0;
    if (!attempted) {
        attempted = 1;
        HMODULE msimg32 = LoadLibraryW(L"msimg32.dll");
        if (msimg32) alpha_blend = (tc_alpha_blend_t)(void *)GetProcAddress(msimg32, "AlphaBlend");
    }
    int draw_w = min(w, g_detail_mem_w), draw_h = min(h, g_detail_mem_h);
    if (alpha_blend) {
        /* The detail HWND owns uniform opacity.  At 100% it is native Acrylic; below 100%
         * Win32Shim switches it to a uniformly faded layered fallback.  Applying the main
         * dial alpha again here would square the selected opacity. */
        BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        alpha_blend(dc, 0, 0, draw_w, draw_h, g_detail_mem_dc, 0, 0, draw_w, draw_h, blend);
    } else {
        /* AlphaBlend exists on every supported Windows release.  Keep a readable
         * last-resort path for stripped compatibility environments. */
        BitBlt(dc, 0, 0, draw_w, draw_h, g_detail_mem_dc, 0, 0, SRCCOPY);
    }
}

// UTF-8 → UTF-16。返回写入 wchar 数（含 NUL）；空串/溢出返回 0。
static int to_wide(const char *u8, wchar_t *buf, int n) {
    if (!u8 || !u8[0]) { if (n > 0) buf[0] = 0; return 0; }
    return MultiByteToWideChar(CP_UTF8, 0, u8, -1, buf, n);
}

// Draw one clock frame into the memory ARGB bitmap and present it via UpdateLayeredWindow.
void win_render_clock(int w, int h, int hh, int mm, int ss, const win_theme *t, const win_overlay *ov) {
    if (!g_hwnd || !t) return;
    const int mainW = w, mainH = h;
    const bool expanded = ov && ov->detail_visible;
    const int dialHeight = (ov && ov->clock_diameter > 0) ? ov->clock_diameter : h;
    const int detailWidth = (ov && ov->detail_card_width > 0) ? ov->detail_card_width : 320;
    const int detailHeight = 547;
    const int renderW = expanded ? max(mainW, detailWidth) : mainW;
    const int renderH = expanded ? dialHeight + 14 + detailHeight : mainH;
    w = renderW; h = renderH;
    ensure_mem(renderW, renderH);
    DIBSECTION ds; GetObject(g_mem_bm, sizeof(ds), &ds);
    if (ds.dsBm.bmBits) memset(ds.dsBm.bmBits, 0, (size_t)w * h * 4);

    Gdiplus::Graphics gfx(g_mem_dc);
    gfx.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    gfx.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAliasGridFit);
    gfx.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHighQuality);

    const double clockH = (ov && ov->clock_diameter > 0) ? ov->clock_diameter : (w - 80.0);
    const double cxd = w / 2.0, cyd = clockH / 2.0;
    const double r = clockH / 2.0 - 4.0;        // exact ClockFaceView radius
    const double S = r / 116.0;                 // medium macOS radius = 120 - 4

    // 盘体 + 外环。Windows material faces are cached vector surfaces; legacy glass_disc
    // remains available to flat themes/custom payloads for backwards compatibility.
    {
        bool drewImage = draw_cached_material_face(gfx, *t, (float)cxd, (float)cyd,
                                                    (int)std::lround(clockH));
        wchar_t imagePath[MAX_PATH];
        if (!drewImage && ov && to_wide(ov->dial_image_path, imagePath, MAX_PATH) > 0) {
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

    // Material faces use a watch-like 60-minute track; legacy faces retain the exact
    // 12-tick macOS-normal geometry.
    if (t->show_ticks) {
        const int tickCount = t->material_style > 0 ? 60 : 12;
        for (int i = 0; i < tickCount; i++) {
            double a = deg2rad(i * (360.0 / tickCount) - 90.0);
            int minute = t->material_style > 0 ? i : i * 5;
            bool major = (minute % 15 == 0), hour = (minute % 5 == 0);
            double innerR = t->material_style > 0
                ? r * (major ? 0.885 : (hour ? 0.915 : 0.943))
                : r * (major ? 0.91 : 0.935);
            double outerR = r * 0.97;
            unsigned int col = (major || hour) ? t->major_tick_color : t->tick_color;
            if ((col >> 24) == 0) continue;
            double width = t->material_style > 0
                ? (major ? 2.15 : (hour ? 1.35 : 0.72))
                : (major ? 2.0 : 1.2);
            Gdiplus::Pen tp(cr(col), (Gdiplus::REAL)(width * S));
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
    if (t->material_style > 0) {
        // One soft physical shadow is enough to separate the hands from every material.
        gfx.TranslateTransform((Gdiplus::REAL)(0.9 * S), (Gdiplus::REAL)(1.25 * S));
        drawHand(hourDeg,   t->hour_len,   t->hour_w   * S, 0x52000000u, t->hand_style);
        drawHand(minuteDeg, t->minute_len, t->minute_w * S, 0x46000000u, t->hand_style);
        drawHand(secondDeg, t->second_len, t->second_w * S, 0x30000000u, secStyle);
        gfx.ResetTransform();
    }
    drawHand(hourDeg,   t->hour_len,   t->hour_w   * S, t->hour_color,   t->hand_style);
    drawHand(minuteDeg, t->minute_len, t->minute_w * S, t->minute_color, t->hand_style);
    drawHand(secondDeg, t->second_len, t->second_w * S, t->second_color, secStyle);

    // 中心帽：外盘 r4 + 内盘 r2（缩放）
    {
        double co = 4.0 * S, ci = 2.0 * S;
        if (t->material_style > 0) {
            Gdiplus::SolidBrush shadow(Gdiplus::Color(82, 0, 0, 0));
            gfx.FillEllipse(&shadow, Gdiplus::REAL(cxd - co + 0.9 * S), Gdiplus::REAL(cyd - co + 1.25 * S),
                            Gdiplus::REAL(co * 2.2), Gdiplus::REAL(co * 2.2));
        }
        if ((t->cap_outer >> 24) > 0) {
            Gdiplus::SolidBrush o(cr(t->cap_outer));
            gfx.FillEllipse(&o, Gdiplus::REAL(cxd - co), Gdiplus::REAL(cyd - co), Gdiplus::REAL(co * 2), Gdiplus::REAL(co * 2));
        }
        if ((t->cap_inner >> 24) > 0) {
            Gdiplus::SolidBrush in(cr(t->cap_inner));
            gfx.FillEllipse(&in, Gdiplus::REAL(cxd - ci), Gdiplus::REAL(cyd - ci), Gdiplus::REAL(ci * 2), Gdiplus::REAL(ci * 2));
        }
        if (t->material_style > 0) {
            Gdiplus::SolidBrush highlight(Gdiplus::Color(135, 255, 255, 255));
            gfx.FillEllipse(&highlight, Gdiplus::REAL(cxd - co * 0.58), Gdiplus::REAL(cyd - co * 0.68),
                            Gdiplus::REAL(co * 0.72), Gdiplus::REAL(co * 0.48));
            Gdiplus::Pen ring(Gdiplus::Color(92, 255, 255, 255), (Gdiplus::REAL)max(0.65, 0.85 * S));
            gfx.DrawEllipse(&ring, Gdiplus::REAL(cxd - co), Gdiplus::REAL(cyd - co),
                            Gdiplus::REAL(co * 2), Gdiplus::REAL(co * 2));
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
        tc_color_icon icon = color_icon_for(wb);
        if (icon != TC_ICON_NONE) {
            draw_color_icon(gfx, icon, (float)px, (float)py, size * 1.15f);
            return;
        }
        Gdiplus::FontFamily emojiFam(L"Segoe UI Emoji");
        Gdiplus::Font f(&emojiFam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::RectF rect((Gdiplus::REAL)(px - size), (Gdiplus::REAL)(py - size), (Gdiplus::REAL)(size * 2), (Gdiplus::REAL)(size * 2));
        gfx.DrawString(wb, -1, &f, rect, &sfC, &b);
    };
    auto textCEmojiLine = [&](const char *u8, double px, double py, float size, unsigned int argb) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0 || (argb >> 24) == 0) return;
        tc_color_icon icon = color_icon_for(wb);
        if (icon != TC_ICON_NONE) {
            const wchar_t *label = text_after_icon(wb);
            Gdiplus::Font f(&fam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
            Gdiplus::SolidBrush b(cr(argb));
            Gdiplus::RectF measured;
            Gdiplus::RectF probe(0, 0, 240.0f, size * 2.0f);
            gfx.MeasureString(label, -1, &f, probe, &sfC, &measured);
            const float iconSize = size * 1.2f, gap = label[0] ? 4.0f : 0.0f;
            const float total = iconSize + gap + (label[0] ? measured.Width : 0.0f);
            const float left = (float)px - total / 2.0f;
            draw_color_icon(gfx, icon, left + iconSize / 2.0f, (float)py, iconSize);
            if (label[0]) {
                Gdiplus::StringFormat sf; sf.SetAlignment(Gdiplus::StringAlignmentNear); sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
                Gdiplus::RectF rect(left + iconSize + gap, (Gdiplus::REAL)(py - size), measured.Width + 6.0f, size * 2.0f);
                gfx.DrawString(label, -1, &f, rect, &sf, &b);
            }
            return;
        }
        Gdiplus::FontFamily emojiFam(L"Segoe UI Emoji");
        Gdiplus::Font f(&emojiFam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
        Gdiplus::SolidBrush b(cr(argb));
        Gdiplus::RectF rect(Gdiplus::REAL(px - 130.0), Gdiplus::REAL(py - size), 260.0f, Gdiplus::REAL(size * 2.0f));
        gfx.DrawString(wb, -1, &f, rect, &sfC, &b);
    };
    auto textLEmojiLine = [&](const char *u8, double px, double py, float size, unsigned int argb) {
        wchar_t wb[128];
        if (to_wide(u8, wb, 128) == 0 || (argb >> 24) == 0) return;
        tc_color_icon icon = color_icon_for(wb);
        if (icon != TC_ICON_NONE) {
            const wchar_t *label = text_after_icon(wb);
            const float iconSize = size * 1.2f;
            draw_color_icon(gfx, icon, (float)px + iconSize / 2.0f, (float)py, iconSize);
            if (label[0]) {
                Gdiplus::Font f(&fam, size, Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                Gdiplus::SolidBrush b(cr(argb));
                Gdiplus::StringFormat sf; sf.SetAlignment(Gdiplus::StringAlignmentNear); sf.SetLineAlignment(Gdiplus::StringAlignmentCenter);
                Gdiplus::RectF rect((Gdiplus::REAL)(px + iconSize + 4.0f), (Gdiplus::REAL)(py - size), 180.0f, size * 2.0f);
                gfx.DrawString(label, -1, &f, rect, &sf, &b);
            }
            return;
        }
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
        /* The sibling's real DWM Acrylic supplies the material.  Keep each face's
         * detail palette as a translucent tint rather than hiding the backdrop
         * beneath the former opaque layered card.  Dial rendering above already
         * consumed the original theme. */
        win_theme acrylicTheme = *t;
        acrylicTheme.dd_bg = (0x68u << 24) | (t->dd_bg & 0x00ffffffu);
        acrylicTheme.dd_border = (0x90u << 24) | (t->dd_border & 0x00ffffffu);
        t = &acrylicTheme;
        // Detail geometry is intentionally independent from face size. The macOS normal panel is
        // 320x547 at all four clock-size choices; only the dial uses the ClockSize scale above.
        const double S = 1.0;
        wchar_t wb[2048];
        if (to_wide(ov->detail_text, wb, 2048) == 0) wcscpy_s(wb, L"C|\t\t\t\t");
        {
            const double gap = 14.0 * S, rowH = 30.0 * S, radius = 12.0 * S;
            const bool hasForecast = ov->forecast_summary && ov->forecast_summary[0];
            const double forecastH = hasForecast ? 76.0 * S : 0.0;
            const double cardW = (ov->detail_card_width > 0) ? ov->detail_card_width : 320.0;
            const double cardLeft = (w - cardW) / 2.0, cardRight = cardLeft + cardW;
            // Match the macOS normal detail panel's stable 320x547 presentation at the
            // medium clock size. Rows are paged by Swift; expanding content never moves
            // the clock or changes this card's visible height.
            const double cardTop = clockH + gap, cardH = 547.0 * S;

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
                    Gdiplus::Font fSummary(&famD, (float)(12.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::Font fForecastLabel(&famD, (float)(11.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::SolidBrush mainBrush(cr(t->dd_text)), subBrush(cr(t->dd_subtext));
                    Gdiplus::RectF summaryRect((Gdiplus::REAL)(cardLeft + 12.0 * S), (Gdiplus::REAL)(cardTop + 4.0 * S),
                                               (Gdiplus::REAL)(cardW - 100.0 * S), (Gdiplus::REAL)(22.0 * S));
                    Gdiplus::RectF labelRect((Gdiplus::REAL)(cardRight - 96.0 * S), (Gdiplus::REAL)(cardTop + 4.0 * S),
                                             (Gdiplus::REAL)(84.0 * S), (Gdiplus::REAL)(22.0 * S));
                    tc_color_icon summaryIcon = color_icon_for(summary);
                    if (summaryIcon != TC_ICON_NONE) {
                        const float iconSize = (float)(17.0 * S);
                        draw_color_icon(gfx, summaryIcon,
                                        summaryRect.X + iconSize / 2.0f,
                                        summaryRect.Y + summaryRect.Height / 2.0f,
                                        iconSize);
                        Gdiplus::RectF summaryText(summaryRect.X + iconSize + (float)(4.0 * S), summaryRect.Y,
                                                   summaryRect.Width - iconSize - (float)(4.0 * S), summaryRect.Height);
                        gfx.DrawString(text_after_icon(summary), -1, &fSummary, summaryText, &sfL, &mainBrush);
                    } else {
                        gfx.DrawString(summary, -1, &fSummary, summaryRect, &sfL, &mainBrush);
                    }
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
                        tc_color_icon forecastIcon = color_icon_for(emoji);
                        if (forecastIcon != TC_ICON_NONE) {
                            draw_color_icon(gfx, forecastIcon,
                                            emojiRect.X + emojiRect.Width / 2.0f,
                                            emojiRect.Y + emojiRect.Height / 2.0f,
                                            (float)(19.0 * S));
                        } else {
                            gfx.DrawString(emoji, -1, &fWeatherEmoji, emojiRect, &sfC2, &mainBrush);
                        }
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

                // Quota and Percent chips share the second control row, matching macOS.
                const double chipW = 104.0 * S, chipH = 22.0 * S, chipTop = contentTop + 38.0 * S;
                const double chipLeft = cardRight - 12.0 * S - chipW;
                Gdiplus::GraphicsPath chip; roundedPath(chip, chipLeft, chipTop, chipW, chipH, chipH / 2.0);
                Gdiplus::SolidBrush chipBg(cr(alpha(t->dd_text, ov->detail_percentage ? 46 : 20))); gfx.FillPath(&chipBg, &chip);
                Gdiplus::Pen chipBorder(cr(alpha(t->dd_text, ov->detail_percentage ? 82 : 38)), (Gdiplus::REAL)(0.7 * S)); gfx.DrawPath(&chipBorder, &chip);
                Gdiplus::RectF chipRect((Gdiplus::REAL)chipLeft, (Gdiplus::REAL)chipTop, (Gdiplus::REAL)chipW, (Gdiplus::REAL)chipH);
                gfx.DrawString(parts[2], -1, &fControl, chipRect, &sfC2, &controlText);

                const double quotaLeft = cardLeft + 12.0 * S;
                Gdiplus::GraphicsPath quotaChip; roundedPath(quotaChip, quotaLeft, chipTop, chipW, chipH, chipH / 2.0);
                Gdiplus::SolidBrush quotaBg(cr(alpha(t->dd_text, ov->detail_quota_visible ? 46 : 20))); gfx.FillPath(&quotaBg, &quotaChip);
                Gdiplus::Pen quotaBorder(cr(alpha(t->dd_text, ov->detail_quota_visible ? 82 : 38)), (Gdiplus::REAL)(0.7 * S)); gfx.DrawPath(&quotaBorder, &quotaChip);
                wchar_t quotaLabel[96];
                if (to_wide(ov->quota_label, quotaLabel, 96) > 0) {
                    Gdiplus::RectF quotaRect((Gdiplus::REAL)quotaLeft, (Gdiplus::REAL)chipTop, (Gdiplus::REAL)chipW, (Gdiplus::REAL)chipH);
                    gfx.DrawString(quotaLabel, -1, &fControl, quotaRect, &sfC2, &controlText);
                }
            }

            if (ov->detail_quota_visible) {
                // Typed quota rows supplied by the shared CodexQuotaSnapshot presenter:
                // H\ttitle\trefresh; B\tname\twindow\tremaining\treset\tpercent;
                // M\tmetadata; S\tsource/update; E\tmessage\tretry.
                const double panelTop = contentTop + 72.0 * S;
                wchar_t quota[4096];
                if (to_wide(ov->quota_text, quota, 4096) > 0) {
                    Gdiplus::Font fQuotaTitle(&famD, (float)(12.0 * S), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
                    Gdiplus::Font fQuota(&famD, (float)(10.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                    Gdiplus::Font fQuotaBold(&famD, (float)(11.0 * S), Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
                    Gdiplus::SolidBrush mainBrush(cr(t->dd_text)), subBrush(cr(t->dd_subtext));
                    double quotaY = panelTop;
                    wchar_t *line = quota;
                    while (*line && quotaY < cardTop + cardH - 24.0 * S) {
                        wchar_t *nl = wcschr(line, L'\n'); if (nl) *nl = 0;
                        wchar_t *fields[7]; splitTabs(line, fields, 7);
                        wchar_t kind = fields[0][0];
                        if (kind == L'H') {
                            Gdiplus::RectF titleRect((Gdiplus::REAL)(cardLeft + 14.0 * S), (Gdiplus::REAL)quotaY,
                                                     (Gdiplus::REAL)(cardW - 110.0 * S), (Gdiplus::REAL)(26.0 * S));
                            Gdiplus::RectF refreshRect((Gdiplus::REAL)(cardRight - 92.0 * S), (Gdiplus::REAL)quotaY,
                                                       (Gdiplus::REAL)(78.0 * S), (Gdiplus::REAL)(26.0 * S));
                            gfx.DrawString(fields[1], -1, &fQuotaTitle, titleRect, &sfL, &mainBrush);
                            gfx.DrawString(fields[2], -1, &fQuota, refreshRect, &sfR, &subBrush);
                            quotaY += 30.0 * S;
                        } else if (kind == L'B') {
                            const double boxH = 78.0 * S;
                            Gdiplus::GraphicsPath box; roundedPath(box, cardLeft + 12.0 * S, quotaY,
                                                                  cardW - 24.0 * S, boxH, 9.0 * S);
                            Gdiplus::SolidBrush boxBg(cr(alpha(t->dd_text, 15))); gfx.FillPath(&boxBg, &box);
                            Gdiplus::RectF nameRect((Gdiplus::REAL)(cardLeft + 22.0 * S), (Gdiplus::REAL)(quotaY + 7.0 * S),
                                                   (Gdiplus::REAL)(cardW - 130.0 * S), (Gdiplus::REAL)(18.0 * S));
                            Gdiplus::RectF remainRect((Gdiplus::REAL)(cardRight - 104.0 * S), (Gdiplus::REAL)(quotaY + 7.0 * S),
                                                     (Gdiplus::REAL)(82.0 * S), (Gdiplus::REAL)(18.0 * S));
                            gfx.DrawString(fields[1], -1, &fQuotaBold, nameRect, &sfL, &mainBrush);
                            gfx.DrawString(fields[3], -1, &fQuotaBold, remainRect, &sfR, &mainBrush);
                            double percent = max(0.0, min(100.0, _wtof(fields[5])));
                            const double barX = cardLeft + 22.0 * S, barY = quotaY + 31.0 * S, barW = cardW - 44.0 * S;
                            Gdiplus::GraphicsPath bar; roundedPath(bar, barX, barY, barW, 7.0 * S, 3.5 * S);
                            Gdiplus::SolidBrush barBg(cr(alpha(t->dd_text, 22))); gfx.FillPath(&barBg, &bar);
                            if (percent > 0.1) {
                                Gdiplus::GraphicsPath fill; roundedPath(fill, barX, barY, max(7.0 * S, barW * percent / 100.0), 7.0 * S, 3.5 * S);
                                unsigned int accent = percent < 20 ? 0xffe05252u : (percent < 45 ? 0xffd59a33u : 0xff4aae73u);
                                Gdiplus::SolidBrush fillBrush(cr(accent)); gfx.FillPath(&fillBrush, &fill);
                            }
                            Gdiplus::RectF resetRect((Gdiplus::REAL)(cardLeft + 22.0 * S), (Gdiplus::REAL)(quotaY + 44.0 * S),
                                                    (Gdiplus::REAL)(cardW - 44.0 * S), (Gdiplus::REAL)(24.0 * S));
                            gfx.DrawString(fields[4], -1, &fQuota, resetRect, &sfL, &subBrush);
                            quotaY += boxH + 8.0 * S;
                        } else if (kind == L'M') {
                            Gdiplus::RectF meta((Gdiplus::REAL)(cardLeft + 16.0 * S), (Gdiplus::REAL)quotaY,
                                                (Gdiplus::REAL)(cardW - 32.0 * S), (Gdiplus::REAL)(30.0 * S));
                            gfx.DrawString(fields[1], -1, &fQuota, meta, &sfL, &mainBrush);
                            quotaY += 30.0 * S;
                        } else if (kind == L'S') {
                            Gdiplus::RectF source((Gdiplus::REAL)(cardLeft + 16.0 * S), (Gdiplus::REAL)quotaY,
                                                  (Gdiplus::REAL)(cardW - 32.0 * S), (Gdiplus::REAL)(24.0 * S));
                            gfx.DrawString(fields[1], -1, &fQuota, source, &sfL, &subBrush);
                            quotaY += 24.0 * S;
                        } else if (kind == L'E' || kind == L'L') {
                            Gdiplus::RectF message((Gdiplus::REAL)(cardLeft + 20.0 * S), (Gdiplus::REAL)(quotaY + 20.0 * S),
                                                   (Gdiplus::REAL)(cardW - 40.0 * S), (Gdiplus::REAL)(54.0 * S));
                            gfx.DrawString(fields[1], -1, &fQuota, message, &sfC2, &subBrush);
                            quotaY += 70.0 * S;
                        }
                        if (!nl) break;
                        line = nl + 1;
                    }
                }
            } else {
            // Column header.
            const double labelX = cardLeft + 14.0 * S;
            const double costW = 50.0 * S, cacheW = 40.0 * S, messagesW = 34.0 * S, usageW = 62.0 * S;
            const double costX = cardRight - 12.0 * S - costW;
            const double cacheX = costX - 4.0 * S - cacheW;
            const double messagesX = cacheX - messagesW;
            const double usageX = messagesX - usageW;
            wchar_t header[256];
            if (to_wide(ov->detail_header, header, 256) > 0) {
                wchar_t *parts[5]; splitTabs(header, parts, 5);
                Gdiplus::Font fHeader(&famD, (float)(9.0 * S), Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
                Gdiplus::SolidBrush headerBrush(cr(t->dd_subtext));
                double headerTop = contentTop + 64.0 * S;
                Gdiplus::RectF lr((Gdiplus::REAL)labelX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)(usageX - labelX), (Gdiplus::REAL)(22.0 * S));
                gfx.DrawString(parts[0], -1, &fHeader, lr, &sfL, &headerBrush);
                Gdiplus::RectF ur((Gdiplus::REAL)usageX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)usageW, (Gdiplus::REAL)(22.0 * S));
                Gdiplus::RectF mr((Gdiplus::REAL)messagesX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)messagesW, (Gdiplus::REAL)(22.0 * S));
                Gdiplus::RectF crct((Gdiplus::REAL)cacheX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)cacheW, (Gdiplus::REAL)(22.0 * S));
                Gdiplus::RectF costR((Gdiplus::REAL)costX, (Gdiplus::REAL)headerTop, (Gdiplus::REAL)costW, (Gdiplus::REAL)(22.0 * S));
                gfx.DrawString(parts[1], -1, &fHeader, ur, &sfR, &headerBrush);
                gfx.DrawString(parts[2], -1, &fHeader, mr, &sfR, &headerBrush);
                gfx.DrawString(parts[3], -1, &fHeader, crct, &sfR, &headerBrush);
                gfx.DrawString(parts[4], -1, &fHeader, costR, &sfR, &headerBrush);
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
                wchar_t *parts[5]; splitTabs(content, parts, 5);
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
                Gdiplus::Font *labelFont = child ? &fChild : &fParent;
                tc_color_icon rowIcon = color_icon_for(parts[0]);
                if (rowIcon != TC_ICON_NONE) {
                    const float iconSize = (float)((child ? 14.0 : 16.0) * S);
                    draw_color_icon(gfx, rowIcon, lr.X + iconSize / 2.0f,
                                    lr.Y + lr.Height / 2.0f, iconSize);
                    Gdiplus::RectF labelRect(lr.X + iconSize + (float)(4.0 * S), lr.Y,
                                             lr.Width - iconSize - (float)(4.0 * S), lr.Height);
                    gfx.DrawString(text_after_icon(parts[0]), -1, labelFont, labelRect, &sfL, &rowBrush);
                } else {
                    Gdiplus::Font *emojiFont = child ? &fChildEmoji : &fParentEmoji;
                    gfx.DrawString(parts[0], -1, emojiFont, lr, &sfL, &rowBrush);
                }
                Gdiplus::RectF ur((Gdiplus::REAL)usageX, (Gdiplus::REAL)y, (Gdiplus::REAL)usageW, (Gdiplus::REAL)rowH);
                Gdiplus::RectF mr((Gdiplus::REAL)messagesX, (Gdiplus::REAL)y, (Gdiplus::REAL)messagesW, (Gdiplus::REAL)rowH);
                Gdiplus::RectF crct((Gdiplus::REAL)cacheX, (Gdiplus::REAL)y, (Gdiplus::REAL)cacheW, (Gdiplus::REAL)rowH);
                Gdiplus::RectF costR((Gdiplus::REAL)costX, (Gdiplus::REAL)y, (Gdiplus::REAL)costW, (Gdiplus::REAL)rowH);
                gfx.DrawString(parts[1], -1, rowFont, ur, &sfR, &rowBrush);
                gfx.DrawString(parts[2], -1, &fChild, mr, &sfR, &rowBrush);
                gfx.DrawString(parts[3], -1, &fChild, crct, &sfR, &rowBrush);
                gfx.DrawString(parts[4], -1, &fChild, costR, &sfR, &rowBrush);

                Gdiplus::Pen divider(cr(alpha(t->dd_border, 55)), (Gdiplus::REAL)(0.5 * S));
                gfx.DrawLine(&divider, (Gdiplus::REAL)(cardLeft + 12.0 * S), (Gdiplus::REAL)(y + rowH),
                             (Gdiplus::REAL)(cardRight - 12.0 * S), (Gdiplus::REAL)(y + rowH));
                if (!nl) break;
                line = nl + 1;
                y += rowH;
            }
            }
        }
    }

    if (expanded) {
        const int detailX = (renderW - detailWidth) / 2;
        const int detailY = dialHeight + 14;
        ensure_detail_mem(detailWidth, detailHeight);
        BitBlt(g_detail_mem_dc, 0, 0, detailWidth, detailHeight,
               g_mem_dc, detailX, detailY, SRCCOPY);
        win_detail_present(1, dialHeight, mainW, detailWidth, detailHeight);
    } else {
        win_detail_present(0, dialHeight, mainW, detailWidth, detailHeight);
    }

    POINT source{(renderW - mainW) / 2, 0};
    RECT wrc; GetWindowRect(g_hwnd, &wrc); POINT pos{wrc.left, wrc.top};
    SIZE sz{mainW, mainH};
    BLENDFUNCTION bf; bf.BlendOp = AC_SRC_OVER; bf.BlendFlags = 0; bf.SourceConstantAlpha = g_window_alpha; bf.AlphaFormat = AC_SRC_ALPHA;
    UpdateLayeredWindow(g_hwnd, NULL, &pos, &sz, g_mem_dc, &source, 0, &bf, ULW_ALPHA);
}

} // extern "C"
