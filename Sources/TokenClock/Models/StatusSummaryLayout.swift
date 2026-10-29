import Foundation

struct StatusSummaryLayout {
    let side: CGFloat
    var isCompact: Bool { side < 480 }
    var padding: CGFloat { isCompact ? 12 : 16 }
    var sectionPadding: CGFloat { isCompact ? 8 : 10 }
    var spacing: CGFloat { isCompact ? 8 : 12 }

    /// Sizes are logical points. Keep the glass's outer padding, popover arrow
    /// and screen margins inside the clicked screen's usable bounds.
    static func panelSide(available: CGSize) -> CGFloat {
        max(1, min(600, max(1, available.width - 52), max(1, available.height - 92)))
    }

    struct QuotaGrid {
        let columns: Int
        let cardWidth: CGFloat
        let ringSize: CGFloat
    }

    func quotaGrid(count: Int) -> QuotaGrid {
        let count = max(1, count)
        // Budget for a non-overlay vertical scroller. Flexible grid columns
        // reclaim this space on systems using overlay scrollbars.
        let width = max(1, side - 2 * padding - 2 * sectionPadding - 16)
        let maximumColumns = max(1, Int((width + spacing) / (112 + spacing)))
        let rows = Int(ceil(Double(count) / Double(maximumColumns)))
        let columns = Int(ceil(Double(count) / Double(rows)))
        let cardWidth = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let preferredSize = max(56, 92 - CGFloat(count - 1) * 7)
        return QuotaGrid(columns: columns, cardWidth: cardWidth,
                         ringSize: max(1, min(preferredSize, cardWidth - 12)))
    }
}
