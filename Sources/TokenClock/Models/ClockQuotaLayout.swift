import Foundation

struct ClockQuotaLayout {
    let diameter: CGFloat
    let count: Int
    let scale: CGFloat
    var ringSize: CGFloat { (count == 1 ? 42 : 36) * scale }
    var spacing: CGFloat { 8 * scale }
    var trailing: CGFloat { (count == 1 ? 36 : 28) * scale }
    var totalHeight: CGFloat { ringSize * CGFloat(count) + spacing * CGFloat(max(0, count - 1)) }
    func frame(at index: Int) -> CGRect {
        CGRect(x: diameter - trailing - ringSize,
               y: (diameter - totalHeight) / 2 + CGFloat(index) * (ringSize + spacing),
               width: ringSize, height: ringSize)
    }
}
