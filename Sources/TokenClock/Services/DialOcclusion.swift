#if os(macOS)
import Foundation
import CoreGraphics

/// Circle/rectangle-union geometry, evaluated only on a menu-bar double click.
/// Window metadata describes bounds, not the pixel transparency of other apps.
enum DialOcclusion {
    static let showThreshold = 0.85

    static func dialBounds(in window: CGRect, diameter: CGFloat) -> CGRect {
        CGRect(x: window.midX - diameter / 2, y: window.midY - diameter / 2, width: diameter, height: diameter)
    }

    static func cgRect(from appKitRect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryTop - appKitRect.maxY, width: appKitRect.width, height: appKitRect.height)
    }

    static func transparentFraction(windowSize: CGSize, diameter: CGFloat) -> Double {
        1 - Double.pi * pow(Double(diameter / 2), 2) / Double(windowSize.width * windowSize.height)
    }

    static func shouldShow(hidden: Bool, coveredFraction: Double?) -> Bool {
        // Unknown metadata should reveal the clock rather than hide it.
        hidden || (coveredFraction.map { !$0.isFinite || $0 + 1e-10 >= showThreshold } ?? true)
    }

    static func coveredFraction(dial: CGRect, windowNumber: Int, windows: [[String: Any]]) -> Double? {
        var occluders: [CGRect] = [], found = false
        for window in windows {
            if (window[kCGWindowNumber as String] as? NSNumber)?.intValue == windowNumber { found = true; break }
            if (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue == 0 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? NSNumber, let y = bounds["Y"] as? NSNumber,
                  let width = bounds["Width"] as? NSNumber, let height = bounds["Height"] as? NSNumber else { continue }
            occluders.append(CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue))
        }
        return found ? coveredFraction(dial: dial, occluders: occluders) : nil
    }

    /// Exact geometric area for axis-aligned window bounds. Sweep vertical
    /// strips, merge overlapping Y intervals, then integrate the circle arcs.
    static func coveredFraction(dial: CGRect, occluders: [CGRect]) -> Double? {
        let radius = Double(min(dial.width, dial.height) / 2)
        guard radius > 0, radius.isFinite, dial.midX.isFinite, dial.midY.isFinite else { return nil }
        let square = CGRect(x: -1, y: -1, width: 2, height: 2)
        let rectangles = occluders.compactMap { rect -> CGRect? in
            guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
                  rect.width > 0, rect.height > 0 else { return nil }
            let normalized = CGRect(x: (Double(rect.minX) - Double(dial.midX)) / radius,
                y: (Double(rect.minY) - Double(dial.midY)) / radius,
                width: Double(rect.width) / radius, height: Double(rect.height) / radius).intersection(square)
            return normalized.isNull || normalized.isEmpty ? nil : normalized
        }
        let edges = Set(rectangles.flatMap { [Double($0.minX), Double($0.maxX)] } + [-1, 1]).sorted()
        var area = 0.0
        for index in 0..<(edges.count - 1) {
            let left = edges[index], right = edges[index + 1], middle = (left + right) / 2
            let intervals = rectangles.filter { Double($0.minX) < middle && Double($0.maxX) > middle }
                .map { (Double($0.minY), Double($0.maxY)) }.sorted { $0.0 < $1.0 }
            var merged: [(Double, Double)] = []
            for interval in intervals {
                if let last = merged.last, interval.0 <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, interval.1)
                } else { merged.append(interval) }
            }
            for (bottom, top) in merged { area += stripArea(left: left, right: right, bottom: bottom, top: top) }
        }
        return min(1, max(0, area / Double.pi))
    }

    private static func primitive(_ x: Double) -> Double {
        let value = min(1, max(-1, x))
        return (value * sqrt(max(0, 1 - value * value)) + asin(value)) / 2
    }

    private static func stripArea(left: Double, right: Double, bottom: Double, top: Double) -> Double {
        var cuts = [left, right]
        for y in [bottom, top] where abs(y) < 1 {
            let x = sqrt(max(0, 1 - y * y))
            for value in [-x, x] where value > left && value < right { cuts.append(value) }
        }
        cuts = Set(cuts).sorted()
        var area = 0.0
        for index in 0..<(cuts.count - 1) {
            let a = cuts[index], b = cuts[index + 1], x = (a + b) / 2
            let h = sqrt(max(0, 1 - x * x))
            guard min(top, h) > max(bottom, -h) else { continue }
            let upperConstant = top <= h ? top : 0, upperArc = top <= h ? 0.0 : 1.0
            let lowerConstant = bottom >= -h ? bottom : 0, lowerArc = bottom >= -h ? 0.0 : -1.0
            area += (upperConstant - lowerConstant) * (b - a)
                + (upperArc - lowerArc) * (primitive(b) - primitive(a))
        }
        return area
    }
}
#endif
