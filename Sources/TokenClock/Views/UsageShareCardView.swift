#if os(macOS)
import SwiftUI

/// A small editorial poster rather than a screenshot of the dashboard.
struct UsageShareCardView: View {
    let data: UsageShareData
    var style: UsageShareStyle = .ink
    var scale: CGFloat = 1

    private var background: Color {
        switch style {
        case .ink: return Color(red: 0.065, green: 0.085, blue: 0.11)
        case .paper: return Color(red: 0.96, green: 0.95, blue: 0.92)
        case .cobalt: return Color(red: 0.035, green: 0.16, blue: 0.33)
        }
    }
    private var foreground: Color {
        style == .paper ? Color(red: 0.10, green: 0.15, blue: 0.18) : .white
    }
    private var accent: Color {
        switch style {
        case .ink: return Color(red: 0.83, green: 0.97, blue: 0.32)
        case .paper: return Color(red: 0.90, green: 0.26, blue: 0.20)
        case .cobalt: return Color(red: 0.45, green: 0.97, blue: 0.82)
        }
    }
    private let toolPalette: [Color] = [
        Color(red: 0.31, green: 0.78, blue: 0.98),
        Color(red: 0.87, green: 0.51, blue: 0.95),
        Color(red: 1.00, green: 0.63, blue: 0.39),
        Color(red: 0.38, green: 0.84, blue: 0.69),
        Color(red: 0.98, green: 0.77, blue: 0.31),
        Color(red: 0.57, green: 0.68, blue: 1.00),
        Color(red: 0.94, green: 0.51, blue: 0.60),
        Color(red: 0.65, green: 0.68, blue: 0.70),
    ]

    var body: some View {
        ZStack {
            background
            grid
            VStack(alignment: .leading, spacing: 0) {
                header
                rule.padding(.top, 24 * scale)
                hero.padding(.top, 28 * scale)
                metrics.padding(.top, 22 * scale)
                rule.padding(.top, 27 * scale)
                HStack {
                    Text(L10n.shared.tr("share.toolBreakdown"))
                    Spacer()
                    Text(String(format: "%02d", data.rows.count))
                }
                .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                .foregroundColor(foreground.opacity(0.55))
                .padding(.top, 22 * scale)
                breakdown.padding(.top, 10 * scale)
                Spacer(minLength: 12 * scale)
                quote
                rule.padding(.top, 16 * scale)
                footer.padding(.top, 11 * scale)
            }
            .padding(.horizontal, 38 * scale)
            .padding(.vertical, 34 * scale)
        }
        .frame(width: 600 * scale, height: 750 * scale)
        .clipped()
    }

    private var rule: some View {
        Rectangle().fill(foreground.opacity(0.19)).frame(height: 0.7 * scale)
    }
    private var grid: some View {
        Path { path in
            for x in stride(from: CGFloat(0), through: 600, by: 48) {
                path.move(to: CGPoint(x: x * scale, y: 0))
                path.addLine(to: CGPoint(x: x * scale, y: 750 * scale))
            }
            for y in stride(from: CGFloat(0), through: 750, by: 48) {
                path.move(to: CGPoint(x: 0, y: y * scale))
                path.addLine(to: CGPoint(x: 600 * scale, y: y * scale))
            }
        }
        .stroke(foreground.opacity(style == .paper ? 0.055 : 0.035), lineWidth: 0.6 * scale)
    }

    private var header: some View {
        HStack(alignment: .top) {
            HStack(spacing: 11 * scale) {
                ZStack {
                    Circle().stroke(accent, lineWidth: 2.4 * scale)
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.system(size: 17 * scale, weight: .medium))
                        .foregroundColor(accent)
                }
                .frame(width: 39 * scale, height: 39 * scale)
                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text("TokenClock").font(.system(size: 17 * scale, weight: .bold, design: .rounded))
                    Text(L10n.shared.tr("share.report"))
                        .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                        .foregroundColor(foreground.opacity(0.48))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4 * scale) {
                Text(periodTitle).font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                Text("\(data.dateKey) — \(data.endDateKey)")
                    .font(.system(size: 9 * scale, weight: .medium, design: .monospaced))
                    .foregroundColor(foreground.opacity(0.56))
            }
            .padding(.top, 4 * scale)
        }
        .foregroundColor(foreground)
    }
    private var periodTitle: String {
        switch data.period {
        case .recent(let days, _):
            return days == 1 ? L10n.shared.tr("share.oneDay") : L10n.shared.tr("share.daysCount", days)
        case .month: return L10n.shared.tr("share.period.month")
        case .weekOfMonth(_, let index): return L10n.shared.tr("share.weekNumber", index)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 10 * scale) {
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text(L10n.shared.tr("share.totalUsage"))
                    .font(.system(size: 10 * scale, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Text(TokenFormat.compact(data.totalTokens))
                    .font(.system(size: 61 * scale, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.7).lineLimit(1)
                    .foregroundColor(foreground)
                Text(L10n.shared.tr(data.includesCacheRead ? "share.tokensWithCache" : "share.tokens"))
                    .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                    .foregroundColor(foreground.opacity(0.47))
            }
            Spacer(minLength: 0)
            orbit
        }
        .frame(height: 164 * scale)
    }
    private var orbit: some View {
        ZStack {
            Circle().stroke(foreground.opacity(0.10), lineWidth: 12 * scale)
            ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
                let start = data.rows.prefix(index).reduce(0.0) { $0 + $1.fraction }
                let end = min(1, start + row.fraction)
                Circle()
                    .trim(from: min(1, start + 0.003), to: max(0, end - 0.003))
                    .stroke(toolPalette[index % toolPalette.count],
                            style: StrokeStyle(lineWidth: 12 * scale, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text("\(data.rows.count)")
                    .font(.system(size: 29 * scale, weight: .bold, design: .rounded))
                Text(L10n.shared.tr("share.tools"))
                    .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
                    .foregroundColor(foreground.opacity(0.52))
            }
            .foregroundColor(foreground)
        }
        .frame(width: 140 * scale, height: 140 * scale)
    }

    private var metrics: some View {
        HStack(spacing: 25 * scale) {
            metric(L10n.shared.tr("share.messages"), integer(data.messages))
            Rectangle().fill(foreground.opacity(0.16)).frame(width: 0.8 * scale, height: 34 * scale)
            metric(L10n.shared.tr("share.cache"), String(format: "%.2f%%", data.averageCacheRate * 100))
            Spacer(minLength: 0)
        }
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            Text(label.uppercased())
                .font(.system(size: 9 * scale, weight: .semibold, design: .monospaced))
                .foregroundColor(foreground.opacity(0.47))
            Text(value)
                .font(.system(size: 21 * scale, weight: .bold, design: .rounded))
                .foregroundColor(foreground)
        }
    }

    @ViewBuilder
    private var breakdown: some View {
        if data.rows.isEmpty {
            Text(L10n.shared.tr("share.noUsage"))
                .font(.system(size: 14 * scale, weight: .medium, design: .rounded))
                .foregroundColor(foreground.opacity(0.56))
                .frame(maxWidth: .infinity, minHeight: 190 * scale)
        } else {
            VStack(spacing: 7 * scale) {
                ForEach(Array(data.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8 * scale) {
                        Text(String(format: "%02d", index + 1))
                            .font(.system(size: 9 * scale, weight: .medium, design: .monospaced))
                            .foregroundColor(foreground.opacity(0.45))
                            .frame(width: 21 * scale, alignment: .leading)
                        RoundedRectangle(cornerRadius: 2 * scale)
                            .fill(toolPalette[index % toolPalette.count])
                            .frame(width: 3 * scale, height: 27 * scale)
                        Text(row.emoji).font(.system(size: 13 * scale))
                        Text(row.name)
                            .font(.system(size: 12 * scale, weight: .medium, design: .rounded))
                            .lineLimit(1).foregroundColor(foreground)
                        Spacer()
                        Text(TokenFormat.compact(row.tokens))
                            .font(.system(size: 12 * scale, weight: .bold, design: .monospaced))
                            .foregroundColor(foreground)
                        Text(String(format: "%3.0f%%", row.fraction * 100))
                            .font(.system(size: 9 * scale, weight: .medium, design: .monospaced))
                            .foregroundColor(foreground.opacity(0.53))
                            .frame(width: 36 * scale, alignment: .trailing)
                    }
                    .frame(height: 27 * scale)
                }
            }
        }
    }
    private var quote: some View {
        HStack(alignment: .top, spacing: 12 * scale) {
            Rectangle().fill(accent).frame(width: 3 * scale)
            VStack(alignment: .leading, spacing: 7 * scale) {
                Text("“")
                    .font(.system(size: 36 * scale, weight: .black, design: .serif))
                    .foregroundColor(accent)
                    .frame(height: 23 * scale, alignment: .top)
                Text(L10n.shared.tr(data.quoteKey))
                    .font(.system(size: 17 * scale, weight: .medium, design: .serif))
                    .foregroundColor(foreground.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 76 * scale, alignment: .leading)
    }
    private var footer: some View {
        HStack {
            Text(L10n.shared.tr("share.generatedBy"))
            Spacer()
            Text("TOKENCLOCK  /  \(data.endDateKey)")
        }
        .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
        .foregroundColor(foreground.opacity(0.44))
    }
    private func integer(_ value: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}
#endif
