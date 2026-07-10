import AppKit
import SwiftUI

// MARK: - 公开 NSVisualEffectView 毛玻璃底板（折射玻璃下层）
//
// set_variant: 私有枚举给不出干净的多档（非 dock + max 折射会变形），改用公开稳定的
// NSVisualEffectView 做底板：固定 `.menu` 材质（系统菜单同款中性毛玻璃，绝不变形），
// 用 alphaValue 连续调透明度 —— 0=无底板（纯玻璃通透），1=实心底板。
// 折射玻璃（LiquidGlassDial，锁 variant 2）浮于其上；本底板在其下层。

struct VibrancyBacking: NSViewRepresentable {
    let diameter: CGFloat
    /// 底板毛玻璃透明度 0…1（0=无底板）。走公开 NSVisualEffectView.alphaValue。
    let alpha: Double

    func makeNSView(context: Context) -> NSView {
        let v = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        v.material = .menu
        v.blendingMode = .behindWindow   // 取窗口背后的桌面做毛玻璃
        v.state = .active                // 强制激活态（非激活会偏暗），避免浮窗 dim
        v.isEmphasized = false
        v.alphaValue = alpha
        v.wantsLayer = true
        v.layer?.cornerRadius = diameter / 2
        v.layer?.masksToBounds = true
        v.layer?.cornerCurve = .continuous
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let f = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        if nsView.frame.size != f.size { nsView.frame = f }
        if let v = nsView as? NSVisualEffectView { v.alphaValue = alpha }
    }
}
