import Foundation

struct StatusSummaryLayout {
    let side: CGFloat
    var isCompact: Bool { side < 480 }
    var padding: CGFloat { isCompact ? 10 : 12 }
    var sectionPadding: CGFloat { isCompact ? 7 : 8 }
    var spacing: CGFloat { isCompact ? 6 : 8 }

    var notebookWidth: CGFloat { max(94, min(210, (side - 2 * padding - spacing) * 0.36)) }
    var notebookHeight: CGFloat { isCompact ? 180 : 174 }

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
        let content = max(1, side - 2 * padding - 16)
        let width = max(1, (isCompact ? content : max(190, (side-2*padding-24)*0.43)) - 2*sectionPadding - 16)
        let columns = min(2, count)
        let cardWidth = max(1, (width - CGFloat(columns - 1)*spacing)/CGFloat(columns))
        let preferredSize: CGFloat = count == 1 ? 48 : count <= 4 ? 40 : 36
        return QuotaGrid(columns: columns, cardWidth: cardWidth, ringSize: max(1,min(preferredSize,cardWidth-12)))
    }
}
