import AppKit
import ObjectiveC
import SwiftUI

// MARK: - SPIKE: 私有 API 液态玻璃折射（macOS 26+）
//
// 用 NSGlassEffectView 的私有 SPI set_variant: / set_contentLensing: 驱动真·折射
// （Dock 同款材质），替代公开 .glassEffect（只模糊、不折射）。
//
// 参数由 SwiftUI 侧注入（DialGlassModifier → LiquidGlassDial）：
//   variant     材质配方：2=dock(标准) 13=clearGlass(清透) 8=controlCenter(磨砂)
//   lensing     折射强度 0–6（锁 6：dock 材质上 2/4/6 视觉无差，6=max 稳定）
//   tintColor   玻璃底色 NSColor?（nil=纯净玻璃）；走私有 set_tintColor: / 公开 setTintColor:
//
// 来源：NSGlassEffectView 私有 SPI，经 macOS 27 (26A5368g) responds(to:) + 回读实测可用；
// set_variant: / set_contentLensing: 跨 26↔27 稳定（electron-liquid-glass / qt-liquid-glass / window-vibrancy 三方一致）。

/// 调用 NSGlassEffectView 的私有整数 setter（Obj-C 运行时 dispatch，arm64/x86_64 皆可）。
@inline(__always)
private func setIntSPI(_ obj: AnyObject, _ key: String, _ value: Int) {
    let sel = NSSelectorFromString("set_\(key):")
    guard obj.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: obj), sel) else { return }
    typealias Fn = @convention(c) (AnyObject, Selector, Int) -> Void
    unsafeBitCast(imp, to: Fn.self)(obj, sel, value)
}

/// 调用 NSGlassEffectView 的私有对象 setter（传完整 selector，如 "set_tintColor:" / "setTintColor:"）。
@inline(__always)
private func setObjectSPI(_ obj: AnyObject, _ selector: String, _ value: AnyObject) {
    let sel = NSSelectorFromString(selector)
    guard obj.responds(to: sel),
          let imp = class_getMethodImplementation(type(of: obj), sel) else { return }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    unsafeBitCast(imp, to: Fn.self)(obj, sel, value)
}

/// 私有折射玻璃表盘。d×d 正圆（cornerRadius = d/2）。
struct LiquidGlassDial: NSViewRepresentable {
    let diameter: CGFloat
    let variant: Int
    /// 折射强度（set_contentLensing: 0–6）。锁定 6。
    let lensing: Int = 6
    /// 玻璃底色（nil = 纯净玻璃，随壁纸自适应）。
    let tintColor: NSColor?

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        configure(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        configure(view)
        let f = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        if view.frame.size != f.size { view.frame = f }
    }

    private func configure(_ view: NSGlassEffectView) {
        // 顺序：先 variant（重建内部子层），再 contentLensing（折射强度）。
        setIntSPI(view, "variant", variant)
        setIntSPI(view, "contentLensing", lensing)

        // 玻璃底色：私有 SPI set_tintColor: 优先（与 set_variant: 同族），回退公开 setTintColor:。
        // 注意：macOS 27 Beta 上 tint 可能渲染偏实心（与 .clear.tint 同 bug）—— 若如此需改走背后低透明度 CALayer。
        Self.applyTint(view, tintColor)

        // 圆形：d×d 方形 + cornerRadius = d/2 → 正圆。
        view.cornerRadius = diameter / 2
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerCurve = .continuous
    }

    nonisolated(unsafe) private static var didProbeTintSPI = false

    private static func applyTint(_ view: NSGlassEffectView, _ tint: NSColor?) {
        // 首次打印 tint SPI 可用性，确认 27 Beta 走哪条路径（看 Console / 运行日志）。
        if !didProbeTintSPI {
            didProbeTintSPI = true
            let underscored = view.responds(to: NSSelectorFromString("set_tintColor:"))
            let publicSel = view.responds(to: NSSelectorFromString("setTintColor:"))
            NSLog("TC_GLASS tint SPI probe: set_tintColor:%@ setTintColor:%@",
                  underscored ? "YES" : "NO", publicSel ? "YES" : "NO")
        }
        guard let tint else { return }
        let capped = Self.cappedTint(tint)
        if view.responds(to: NSSelectorFromString("set_tintColor:")) {
            setObjectSPI(view, "set_tintColor:", capped)
        } else if view.responds(to: NSSelectorFromString("setTintColor:")) {
            setObjectSPI(view, "setTintColor:", capped)
        }
    }

    /// 极端亮度（纯白/纯黑附近）会把玻璃染成实心、完全挡住背景 —— 压到半透明；
    /// 中间色保持原强度（NSGlassEffectView 自身会做玻璃混合，已是柔和染色）。
    private static func cappedTint(_ color: NSColor) -> NSColor {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        let cappedAlpha: CGFloat = (lum > 0.90 || lum < 0.10) ? 0.5 : a
        return NSColor(srgbRed: r, green: g, blue: b, alpha: cappedAlpha)
    }
}
