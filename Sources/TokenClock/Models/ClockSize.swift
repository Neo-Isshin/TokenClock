import SwiftUI

/// 表盘尺寸档位：4 个固定值，覆盖 13" 笔电到 6K 巨屏。
///
/// 采用离散档位（而非连续缩放）以换取稳定性——只有 4 种固定配置需要验证，
/// 避免 .scaleEffect 在极端倍率下的光栅化与布局漂移。
///
/// 直径单位为逻辑点（pt）。表盘是矢量 Canvas，任意 pt 尺寸在 Retina 上都锐利。
enum ClockSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    /// 表盘直径（pt）。`medium = 240` 与历史默认一致。
    var diameter: CGFloat {
        switch self {
        case .small:      return 200
        case .medium:     return 240
        case .large:      return 300
        case .extraLarge: return 360
        }
    }

    /// 相对中档（240）的缩放比，供叠加层 padding / 字号等比缩放。
    var scale: CGFloat { diameter / 240.0 }

    /// 浮动面板宽度 = 直径 + 左右各 40pt 边距（历史 320 = 240 + 80）。
    var panelWidth: CGFloat { diameter + 80 }

    /// 详情面板至少保持 medium 的可用宽度，避免 small 档压缩控制行与数据列。
    /// 表盘窗口仍使用 `panelWidth`，large / extraLarge 的详情宽度保持不变。
    var detailPanelWidth: CGFloat { max(panelWidth, ClockSize.medium.panelWidth) }

    var localizedName: String {
        switch self {
        case .small:      return L10n.shared.tr("size.small")
        case .medium:     return L10n.shared.tr("size.medium")
        case .large:      return L10n.shared.tr("size.large")
        case .extraLarge: return L10n.shared.tr("size.extraLarge")
        }
    }

    /// 按主屏可用高度（逻辑点，已扣除菜单栏 / Dock）自动选档。
    /// 阈值依据：让选中的档位在对应屏幕上约占 20–27% 屏高（角落悬浮件的舒适区）。
    static func autoDetect(screenHeight h: CGFloat) -> ClockSize {
        if h < 850  { return .small }      // 紧凑小屏 / "更大文字"缩放档
        if h < 1250 { return .medium }     // 13–16" 笔电（主流）
        if h < 1500 { return .large }      // 4K / 5K
        return .extraLarge                  // 6K / 巨屏
    }
}
