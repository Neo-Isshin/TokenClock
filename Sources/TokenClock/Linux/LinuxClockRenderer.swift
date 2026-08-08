import Foundation
import CGtk

struct LinuxClockSnapshot {
    let date: Date
    let timeZone: TimeZone
    let tools: [ToolUsage]
    let weather: WeatherInfo
    let useFahrenheit: Bool
    let theme: LinuxClockTheme
    let size: LinuxClockSize
}

/// Cairo/Pango port of macOS normal's `ClockFaceView` + `ClockContentView`.
final class LinuxClockRenderer: @unchecked Sendable {
    private let glassSurface: OpaquePointer?

    init() {
        guard let url = Bundle.module.url(forResource: "glass_disc", withExtension: "png") else {
            glassSurface = nil
            return
        }
        glassSurface = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return nil }
            let surface = cairo_image_surface_create_from_png(path)
            guard cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS else {
                cairo_surface_destroy(surface)
                return nil
            }
            return surface
        }
    }

    deinit {
        if let glassSurface { cairo_surface_destroy(glassSurface) }
    }

    func draw(_ context: OpaquePointer, width: Double, height: Double, snapshot: LinuxClockSnapshot) {
        cairo_save(context)
        cairo_set_operator(context, CAIRO_OPERATOR_SOURCE)
        setSource(context, .clear)
        cairo_paint(context)
        cairo_restore(context)

        let centerX = width / 2
        let centerY = height / 2
        let radius = min(width, height) / 2 - 4
        let theme = snapshot.theme

        drawDial(context, centerX, centerY, radius, theme)
        if theme.hasDialDecoration {
            drawSkyDecoration(context, centerX, centerY, radius)
        }
        drawTickMarks(context, centerX, centerY, radius, theme)
        drawNumbers(context, centerX, centerY, radius, theme, snapshot.size.scale)
        drawHands(context, centerX, centerY, radius, theme, snapshot.date, snapshot.timeZone)
        drawCenterDot(context, centerX, centerY, theme)
        drawOverlay(context, width, height, snapshot)
    }

    /// Compact face-only rendering used by Linux's visual clock-face picker.
    func drawPreview(
        _ context: OpaquePointer,
        width: Double,
        height: Double,
        theme: LinuxClockTheme,
        date: Date = Date()
    ) {
        let centerX = width / 2
        let centerY = height / 2
        let radius = min(width, height) / 2 - 3
        let scale = min(width, height) / 400
        drawDial(context, centerX, centerY, radius, theme)
        if theme.hasDialDecoration { drawSkyDecoration(context, centerX, centerY, radius) }
        drawTickMarks(context, centerX, centerY, radius, theme)
        drawNumbers(context, centerX, centerY, radius, theme, scale)
        drawHands(context, centerX, centerY, radius, theme, date, .current)
        drawCenterDot(context, centerX, centerY, theme)
    }

    func drawPreview(
        _ context: OpaquePointer,
        width: Double,
        height: Double,
        customConfig: LinuxCustomThemeConfig,
        date: Date = Date()
    ) {
        LinuxCustomThemeStore.shared.withPreviewConfig(customConfig) {
            drawPreview(context, width: width, height: height, theme: .custom, date: date)
        }
    }

    private func drawDial(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        _ radius: Double,
        _ theme: LinuxClockTheme
    ) {
        if theme == .glass, let glassSurface {
            let sourceWidth = Double(cairo_image_surface_get_width(glassSurface))
            let sourceHeight = Double(cairo_image_surface_get_height(glassSurface))
            cairo_save(context)
            cairo_translate(context, centerX - radius, centerY - radius)
            cairo_scale(context, radius * 2 / sourceWidth, radius * 2 / sourceHeight)
            cairo_set_source_surface(context, glassSurface, 0, 0)
            cairo_paint(context)
            cairo_restore(context)
            return
        }

        circle(context, centerX, centerY, radius)
        setSource(context, theme.dialColor)
        cairo_fill_preserve(context)
        if theme.dialRimWidth > 0, theme.dialRimColor.alpha > 0 {
            setSource(context, theme.dialRimColor)
            cairo_set_line_width(context, theme.dialRimWidth)
            cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
            cairo_stroke(context)
        } else {
            cairo_new_path(context)
        }
    }

    private func drawTickMarks(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        _ radius: Double,
        _ theme: LinuxClockTheme
    ) {
        for value in 1...12 {
            let angle = Double(value) * Double.pi / 6 - Double.pi / 2
            let isMajor = value % 3 == 0
            let innerRadius = radius * (isMajor ? 0.91 : 0.935)
            let outerRadius = radius * 0.97
            let color = isMajor ? theme.majorTickMarkColor : theme.tickMarkColor
            guard color.alpha > 0 else { continue }
            cairo_move_to(context, centerX + innerRadius * cos(angle), centerY + innerRadius * sin(angle))
            cairo_line_to(context, centerX + outerRadius * cos(angle), centerY + outerRadius * sin(angle))
            setSource(context, color)
            cairo_set_line_width(context, isMajor ? 2 : 1.2)
            cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
            cairo_stroke(context)
        }
    }

    private func drawNumbers(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        _ radius: Double,
        _ theme: LinuxClockTheme,
        _ scale: Double
    ) {
        guard theme.numberColor.alpha > 0 else { return }
        let chinese = ["", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖", "拾", "拾壹", "拾贰"]
        let numberRadius = radius * 0.84
        for value in 1...12 {
            let angle = Double(value) * Double.pi / 6 - Double.pi / 2
            let label = theme.numberStyle == .chinese ? chinese[value] : "\(value)"
            drawText(
                context,
                label,
                family: theme.numberFontFamily,
                size: 13 * scale,
                weight: 500,
                x: centerX + numberRadius * cos(angle),
                y: centerY + numberRadius * sin(angle),
                alignment: 1,
                color: theme.numberColor
            )
        }
    }

    private func drawHands(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        _ radius: Double,
        _ theme: LinuxClockTheme,
        _ date: Date,
        _ timeZone: TimeZone
    ) {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let seconds = Double(components.second ?? 0)
        let minutes = Double(components.minute ?? 0)
        let hours = Double((components.hour ?? 0) % 12)
        let hourAngle = (hours * 30 + minutes * 0.5) * Double.pi / 180 - Double.pi / 2
        let minuteAngle = minutes * Double.pi / 30 - Double.pi / 2
        let secondAngle = seconds * Double.pi / 30 - Double.pi / 2

        switch theme.handStyle {
        case .round:
            roundHand(context, centerX, centerY, radius * theme.hourHandLength, hourAngle, theme.hourHandWidth, theme.hourHandColor)
            roundHand(context, centerX, centerY, radius * theme.minuteHandLength, minuteAngle, theme.minuteHandWidth, theme.minuteHandColor)
            roundHand(context, centerX, centerY, radius * theme.secondHandLength, secondAngle, theme.secondHandWidth, theme.secondHandColor)
        case .tapered:
            taperedHand(context, centerX, centerY, radius * theme.hourHandLength, hourAngle, theme.hourHandWidth, 1.5, theme.hourHandColor)
            taperedHand(context, centerX, centerY, radius * theme.minuteHandLength, minuteAngle, theme.minuteHandWidth, 1.2, theme.minuteHandColor)
            roundHand(context, centerX, centerY, radius * theme.secondHandLength, secondAngle, theme.secondHandWidth, theme.secondHandColor)
        case .lance:
            lanceHand(context, centerX, centerY, radius * theme.hourHandLength, hourAngle, theme.hourHandWidth, theme.hourHandColor)
            lanceHand(context, centerX, centerY, radius * theme.minuteHandLength, minuteAngle, theme.minuteHandWidth, theme.minuteHandColor)
            roundHand(context, centerX, centerY, radius * theme.secondHandLength, secondAngle, theme.secondHandWidth, theme.secondHandColor)
        case .sword:
            swordHand(context, centerX, centerY, radius * theme.hourHandLength, hourAngle, theme.hourHandWidth, theme.hourHandColor)
            swordHand(context, centerX, centerY, radius * theme.minuteHandLength, minuteAngle, theme.minuteHandWidth, theme.minuteHandColor)
            swordHand(context, centerX, centerY, radius * theme.secondHandLength, secondAngle, theme.secondHandWidth, theme.secondHandColor)
        }
    }

    private func drawCenterDot(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        _ theme: LinuxClockTheme
    ) {
        circle(context, centerX, centerY, 4)
        setSource(context, theme.centerDotOuterColor)
        cairo_fill(context)
        circle(context, centerX, centerY, 2)
        setSource(context, theme.centerDotInnerColor)
        cairo_fill(context)
    }

    private func drawOverlay(
        _ context: OpaquePointer,
        _ width: Double,
        _ height: Double,
        _ snapshot: LinuxClockSnapshot
    ) {
        let scale = snapshot.size.scale
        let theme = snapshot.theme
        let tools = snapshot.tools
        let totalTokens = TokenFormat.compact(UsageAggregator.totalTokens(tools))
        let totalMessages = UsageAggregator.totalMessages(tools)

        let formatter = DateFormatter()
        formatter.timeZone = snapshot.timeZone
        switch L10n.shared.language {
        case .zhHans:
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 EEEE"
        case .zhHant:
            formatter.locale = Locale(identifier: "zh_TW")
            formatter.dateFormat = "M月d日 EEEE"
        case .en:
            formatter.locale = Locale(identifier: "en_US")
            formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        }
        let dateText = formatter.string(from: snapshot.date)
        drawText(context, dateText, family: "Sans", size: 11 * scale, weight: 500,
                 x: width / 2, y: 64 * scale, alignment: 1, color: theme.textSecondaryColor)

        if !snapshot.weather.cityName.isEmpty {
            let temperature: Int
            let unit: String
            if snapshot.useFahrenheit {
                temperature = Int(Double(snapshot.weather.temperature) * 9 / 5 + 32)
                unit = "F"
            } else {
                temperature = snapshot.weather.temperature
                unit = "C"
            }
            drawText(
                context,
                "\(snapshot.weather.emoji) \(temperature)°\(unit)",
                family: "Noto Color Emoji, Sans",
                size: 13 * scale,
                weight: 400,
                x: width / 2,
                y: 82 * scale,
                alignment: 1,
                color: theme.textPrimaryColor
            )
        }

        drawText(context, L10n.shared.tr("clock.todayTokens"), family: "Sans", size: 9 * scale, weight: 400,
                 x: width / 2, y: height - 91 * scale, alignment: 1, color: theme.textSecondaryColor)
        drawText(context, totalTokens, family: "Sans", size: 20 * scale, weight: 700,
                 x: width / 2, y: height - 71 * scale, alignment: 1, color: theme.textPrimaryColor)
        drawText(context, L10n.shared.tr("clock.messagesCount", totalMessages), family: "Sans", size: 10 * scale, weight: 400,
                 x: width / 2, y: height - 51 * scale, alignment: 1, color: theme.textSecondaryColor)

        let activeTools = UsageAggregator.topToolsByTokens(tools, limit: 2)
        let rowSpacing = 17 * scale
        let firstY = height / 2 - Double(max(0, activeTools.count - 1)) * rowSpacing / 2
        for (index, tool) in activeTools.enumerated() {
            drawText(context, "\(tool.emoji) \(tool.abbreviation)", family: "Sans", size: 13 * scale, weight: 600,
                     x: 22 * scale, y: firstY + Double(index) * rowSpacing, alignment: 0,
                     color: withAlpha(theme.textPrimaryColor, theme.textPrimaryColor.alpha * 0.75))
        }

        drawText(context, UsageAggregator.rateEmoji(tools), family: "Noto Color Emoji, Emoji, Sans", size: 28 * scale, weight: 400,
                 x: width - 22 * scale, y: height / 2, alignment: 2, color: LinuxColor(1, 1, 1))
    }

    private func roundHand(
        _ context: OpaquePointer, _ centerX: Double, _ centerY: Double,
        _ radius: Double, _ angle: Double, _ width: Double, _ color: LinuxColor
    ) {
        cairo_move_to(context, centerX, centerY)
        cairo_line_to(context, centerX + radius * cos(angle), centerY + radius * sin(angle))
        setSource(context, color)
        cairo_set_line_width(context, width)
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_stroke(context)
    }

    private func taperedHand(
        _ context: OpaquePointer, _ centerX: Double, _ centerY: Double,
        _ radius: Double, _ angle: Double, _ baseWidth: Double, _ tipWidth: Double, _ color: LinuxColor
    ) {
        let endX = centerX + radius * cos(angle)
        let endY = centerY + radius * sin(angle)
        let backRadius = radius * 0.15
        let backX = centerX - backRadius * cos(angle)
        let backY = centerY - backRadius * sin(angle)
        let dx = cos(angle + Double.pi / 2)
        let dy = sin(angle + Double.pi / 2)
        cairo_move_to(context, backX + dx * baseWidth / 2, backY + dy * baseWidth / 2)
        cairo_line_to(context, endX + dx * tipWidth / 2, endY + dy * tipWidth / 2)
        cairo_line_to(context, endX - dx * tipWidth / 2, endY - dy * tipWidth / 2)
        cairo_line_to(context, backX - dx * baseWidth / 2, backY - dy * baseWidth / 2)
        cairo_close_path(context)
        setSource(context, color)
        cairo_fill(context)
    }

    private func lanceHand(
        _ context: OpaquePointer, _ centerX: Double, _ centerY: Double,
        _ radius: Double, _ angle: Double, _ width: Double, _ color: LinuxColor
    ) {
        let endX = centerX + radius * cos(angle)
        let endY = centerY + radius * sin(angle)
        let middleX = centerX + radius * 0.35 * cos(angle)
        let middleY = centerY + radius * 0.35 * sin(angle)
        let backX = centerX - radius * 0.12 * cos(angle)
        let backY = centerY - radius * 0.12 * sin(angle)
        let dx = cos(angle + Double.pi / 2)
        let dy = sin(angle + Double.pi / 2)
        cairo_move_to(context, backX, backY)
        cairo_line_to(context, middleX + dx * width / 2, middleY + dy * width / 2)
        cairo_line_to(context, endX, endY)
        cairo_line_to(context, middleX - dx * width / 2, middleY - dy * width / 2)
        cairo_close_path(context)
        setSource(context, color)
        cairo_fill(context)
    }

    private func swordHand(
        _ context: OpaquePointer, _ centerX: Double, _ centerY: Double,
        _ radius: Double, _ angle: Double, _ width: Double, _ color: LinuxColor
    ) {
        func point(_ along: Double, _ across: Double) -> (Double, Double) {
            let dx = cos(angle + Double.pi / 2)
            let dy = sin(angle + Double.pi / 2)
            return (
                centerX + along * cos(angle) + across * dx,
                centerY + along * sin(angle) + across * dy
            )
        }

        let halfWidth = width / 2
        let guardWidth = width * 0.9
        let handleWidth = width * 0.35
        let pommelWidth = width * 0.45
        let points = [
            point(-radius * 0.16, pommelWidth),
            point(-radius * 0.12, handleWidth),
            point(radius * 0.02, guardWidth),
            point(radius * 0.10, guardWidth),
            point(radius * 0.10, halfWidth),
            point(radius * 0.85, halfWidth),
            point(radius, 0),
            point(radius * 0.85, -halfWidth),
            point(radius * 0.10, -halfWidth),
            point(radius * 0.10, -guardWidth),
            point(radius * 0.02, -guardWidth),
            point(-radius * 0.12, -handleWidth),
            point(-radius * 0.16, -pommelWidth),
        ]
        cairo_move_to(context, points[0].0, points[0].1)
        for point in points.dropFirst() { cairo_line_to(context, point.0, point.1) }
        cairo_close_path(context)
        setSource(context, color)
        cairo_fill(context)
    }

    private func drawSkyDecoration(
        _ context: OpaquePointer,
        _ centerX: Double,
        _ centerY: Double,
        _ radius: Double
    ) {
        let sunAngle = -55.0 * Double.pi / 180
        let sunX = centerX + radius * 0.62 * cos(sunAngle)
        let sunY = centerY + radius * 0.62 * sin(sunAngle)
        let sunSize = radius * 0.10
        circle(context, sunX, sunY, sunSize * 1.5)
        setSource(context, LinuxColor(1.0, 0.920, 0.600, 0.25))
        cairo_fill(context)
        circle(context, sunX, sunY, sunSize)
        setSource(context, LinuxColor(1.0, 0.850, 0.300))
        cairo_fill(context)

        drawCloud(context, centerX - radius * 0.38, centerY - radius * 0.28, radius * 0.10, LinuxColor(0.95, 0.95, 0.95))
        drawCloud(context, centerX + radius * 0.25, centerY + radius * 0.32, radius * 0.07, LinuxColor(0.95, 0.95, 0.95, 0.7))
        drawCloud(context, centerX - radius * 0.10, centerY + radius * 0.50, radius * 0.055, LinuxColor(0.95, 0.95, 0.95, 0.5))
        drawBird(context, centerX - radius * 0.35, centerY + radius * 0.18, radius * 0.05, LinuxColor(0.280, 0.380, 0.500))
        drawBird(context, centerX - radius * 0.22, centerY + radius * 0.10, radius * 0.035, LinuxColor(0.280, 0.380, 0.500, 0.6))
    }

    private func drawCloud(
        _ context: OpaquePointer, _ centerX: Double, _ centerY: Double,
        _ scale: Double, _ color: LinuxColor
    ) {
        ellipse(context, centerX - scale * 1.1, centerY - scale * 0.4, scale * 1.4, scale)
        setSource(context, color)
        cairo_fill(context)
        ellipse(context, centerX - scale * 0.4, centerY - scale * 0.9, scale * 1.2, scale)
        setSource(context, color)
        cairo_fill(context)
        ellipse(context, centerX + scale * 0.2, centerY - scale * 0.3, scale * 1.2, scale * 0.9)
        setSource(context, color)
        cairo_fill(context)
    }

    private func drawBird(
        _ context: OpaquePointer, _ centerX: Double, _ centerY: Double,
        _ scale: Double, _ color: LinuxColor
    ) {
        let start = (centerX - scale, centerY + scale * 0.3)
        let middle = (centerX, centerY - scale * 0.2)
        let end = (centerX + scale, centerY + scale * 0.3)
        let control1 = (centerX - scale * 0.3, centerY - scale * 0.5)
        let control2 = (centerX + scale * 0.3, centerY - scale * 0.5)
        cairo_move_to(context, start.0, start.1)
        quadraticCurve(context, from: start, control: control1, to: middle)
        quadraticCurve(context, from: middle, control: control2, to: end)
        setSource(context, color)
        cairo_set_line_width(context, scale * 0.25)
        cairo_set_line_cap(context, CAIRO_LINE_CAP_ROUND)
        cairo_stroke(context)
    }

    private func quadraticCurve(
        _ context: OpaquePointer,
        from: (Double, Double),
        control: (Double, Double),
        to: (Double, Double)
    ) {
        cairo_curve_to(
            context,
            from.0 + (control.0 - from.0) * 2 / 3,
            from.1 + (control.1 - from.1) * 2 / 3,
            to.0 + (control.0 - to.0) * 2 / 3,
            to.1 + (control.1 - to.1) * 2 / 3,
            to.0,
            to.1
        )
    }

    private func drawText(
        _ context: OpaquePointer,
        _ text: String,
        family: String,
        size: Double,
        weight: Int,
        x: Double,
        y: Double,
        alignment: Int,
        color: LinuxColor
    ) {
        text.withCString { textPointer in
            family.withCString { familyPointer in
                tc_cairo_draw_text(
                    context, textPointer, familyPointer, size, gint(weight), x, y, gint(alignment),
                    color.red, color.green, color.blue, color.alpha
                )
            }
        }
    }

    private func circle(_ context: OpaquePointer, _ x: Double, _ y: Double, _ radius: Double) {
        cairo_arc(context, x, y, radius, 0, Double.pi * 2)
    }

    private func ellipse(
        _ context: OpaquePointer,
        _ x: Double,
        _ y: Double,
        _ width: Double,
        _ height: Double
    ) {
        cairo_save(context)
        cairo_translate(context, x + width / 2, y + height / 2)
        cairo_scale(context, width / 2, height / 2)
        cairo_arc(context, 0, 0, 1, 0, Double.pi * 2)
        cairo_restore(context)
    }

    private func setSource(_ context: OpaquePointer, _ color: LinuxColor) {
        tc_cairo_set_source_rgba(context, color.red, color.green, color.blue, color.alpha)
    }

    private func withAlpha(_ color: LinuxColor, _ alpha: Double) -> LinuxColor {
        LinuxColor(color.red, color.green, color.blue, alpha)
    }
}
