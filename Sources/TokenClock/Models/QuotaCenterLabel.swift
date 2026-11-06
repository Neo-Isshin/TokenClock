import Foundation

/// Compact ring-center text only; tooltips and spoken values remain percentages.
struct QuotaCenterLabel: Equatable {
    let text: String
    let showsPercent: Bool

    init(remaining: Double) {
        guard remaining.isFinite else { text = "—"; showsPercent = false; return }
        let value = min(100, max(0, remaining))
        let formatted = String(format: "%.0f", value)
        if formatted == "100" {
            text = "F"; showsPercent = false
        } else {
            // Preserve the existing integer-percentage display convention.
            text = formatted; showsPercent = true
        }
    }
}
