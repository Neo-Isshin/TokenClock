import SwiftUI

/// 表盘选择弹出面板
struct ThemePickerView: View {
    @ObservedObject var viewModel: ViewModel
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L10n.shared.tr("themePicker.title"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Spacer()
                Button(action: { onDismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            ScrollView([.horizontal], showsIndicators: false) {   // 仅横向滚动；纵向按行自适应高度
                let standardThemes = ClockFaceTheme.allCases
                let customThemes = viewModel.savedCustomThemes
                let totalCount = standardThemes.count + customThemes.count
                let rows = Array(stride(from: 0, to: totalCount, by: 3))
                VStack(spacing: 12) {
                    ForEach(rows, id: \.self) { rowStart in
                        HStack(spacing: 20) {
                            ForEach(0..<3, id: \.self) { col in
                                let idx = rowStart + col
                                if idx < standardThemes.count {
                                    themeCard(theme: standardThemes[idx])
                                } else if idx - standardThemes.count < customThemes.count {
                                    customThemeCard(theme: customThemes[idx - standardThemes.count])
                                } else {
                                    Color.clear.frame(width: 78)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 12, style: .continuous))
    }

    private func themeCard(theme: ClockFaceTheme) -> some View {
        let isSelected = viewModel.selectedTheme == theme

        return VStack(spacing: 8) {
            // 缩略图预览
            ZStack {
                // 选中边框
                if isSelected {
                    Circle()
                        .stroke(theme.hourHandColor, lineWidth: 2.5)
                        .frame(width: 78, height: 78)
                }

                ZStack {
                    GlassAurora(theme: theme, size: 72, animates: false)
                    ThemePreviewClock(theme: theme)
                }
                .frame(width: 72, height: 72)
                .glassEffect(.regular.tint(theme.glassTint), in: .circle)
            }

            Text(theme.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? theme.hourHandColor : .primary)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(theme.hourHandColor)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .onTapGesture {
            viewModel.selectedTheme = theme
            viewModel.saveTheme()
            // 延迟关闭，让用户看到选中效果
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onDismiss()
            }
        }
    }

    private func customThemeCard(theme: SavedCustomTheme) -> some View {
        let isSelected = viewModel.selectedTheme == .custom && viewModel.activeCustomThemeId == theme.id
        let previewTheme = ClockFaceTheme.custom

        return VStack(spacing: 8) {
            ZStack {
                if isSelected {
                    Circle()
                        .stroke(previewTheme.hourHandColor, lineWidth: 2.5)
                        .frame(width: 78, height: 78)
                }

                // 用保存的配置渲染预览（通过临时替换 custom 配置）
                ZStack {
                    GlassAurora(theme: previewTheme, size: 72, animates: false)
                    ThemePreviewClockWithConfig(config: theme.config)
                }
                .frame(width: 72, height: 72)
                .glassEffect(.regular.tint(previewTheme.glassTint), in: .circle)
            }

            Text(theme.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? previewTheme.hourHandColor : .primary)
                .lineLimit(1)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(previewTheme.hourHandColor)
            } else {
                Color.clear.frame(width: 12, height: 12)
            }
        }
        .onTapGesture {
            viewModel.applyCustomTheme(id: theme.id)
            viewModel.selectedTheme = .custom
            viewModel.saveTheme()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                onDismiss()
            }
        }
    }
}

/// 缩略图预览时钟（固定 10:10:30）
struct ThemePreviewClock: View {
    let theme: ClockFaceTheme
    private let hours = 10
    private let minutes = 10
    private let seconds = 30

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3

            // 表盘
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            // 玻璃盘体由外层 .glassEffect 提供；预览不填充不透明底色，仅描外环。
            context.stroke(circle.strokedPath(StrokeStyle(lineWidth: theme.dialRimWidth)),
                           with: .color(theme.dialRimColor))

            // 刻度
            if theme.hasTickMarks {
                drawTickMarks(context: context, center: center, radius: radius)
            }

            // 天空装饰（在数字和指针之前）
            if theme.hasDialDecoration {
                drawSkyDecoration(context: context, center: center, radius: radius)
            }

            // 数字
            if theme.showNumbers {
                drawNumbers(context: context, center: center, radius: radius, fontSize: 7)
            }

            // 指针
            let hourAngle = Angle.degrees(Double(hours % 12) * 30 + Double(minutes) * 0.5 - 90)
            let minuteAngle = Angle.degrees(Double(minutes) * 6 - 90)
            let secondAngle = Angle.degrees(Double(seconds) * 6 - 90)

            switch theme.handStyle {
            case .round:
                drawRoundHand(context: context, center: center,
                              radius: radius * theme.hourHandLength,
                              angle: hourAngle, width: theme.hourHandWidth * 0.7,
                              color: theme.hourHandColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * theme.minuteHandLength,
                              angle: minuteAngle, width: theme.minuteHandWidth * 0.7,
                              color: theme.minuteHandColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * theme.secondHandLength,
                              angle: secondAngle, width: theme.secondHandWidth * 0.7,
                              color: theme.secondHandColor)

            case .tapered:
                drawTaperedHand(context: context, center: center,
                                radius: radius * theme.hourHandLength,
                                angle: hourAngle, baseWidth: theme.hourHandWidth * 0.7,
                                tipWidth: 1, color: theme.hourHandColor)
                drawTaperedHand(context: context, center: center,
                                radius: radius * theme.minuteHandLength,
                                angle: minuteAngle, baseWidth: theme.minuteHandWidth * 0.7,
                                tipWidth: 0.8, color: theme.minuteHandColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * theme.secondHandLength,
                              angle: secondAngle, width: theme.secondHandWidth * 0.7,
                              color: theme.secondHandColor)

            case .lance:
                drawLanceHand(context: context, center: center,
                              radius: radius * theme.hourHandLength,
                              angle: hourAngle, width: theme.hourHandWidth * 0.7,
                              color: theme.hourHandColor)
                drawLanceHand(context: context, center: center,
                              radius: radius * theme.minuteHandLength,
                              angle: minuteAngle, width: theme.minuteHandWidth * 0.7,
                              color: theme.minuteHandColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * theme.secondHandLength,
                              angle: secondAngle, width: theme.secondHandWidth * 0.7,
                              color: theme.secondHandColor)

            case .sword:
                drawSwordHand(context: context, center: center,
                              radius: radius * theme.hourHandLength,
                              angle: hourAngle, width: theme.hourHandWidth * 0.7,
                              color: theme.hourHandColor)
                drawSwordHand(context: context, center: center,
                              radius: radius * theme.minuteHandLength,
                              angle: minuteAngle, width: theme.minuteHandWidth * 0.7,
                              color: theme.minuteHandColor)
                drawSwordHand(context: context, center: center,
                              radius: radius * theme.secondHandLength,
                              angle: secondAngle, width: theme.secondHandWidth * 0.7,
                              color: theme.secondHandColor)
            }

            // 中心点
            let outerDot = Path(ellipseIn: CGRect(
                x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
            context.fill(outerDot, with: .color(theme.centerDotOuterColor))
            let innerDot = Path(ellipseIn: CGRect(
                x: center.x - 1, y: center.y - 1, width: 2, height: 2))
            context.fill(innerDot, with: .color(theme.centerDotInnerColor))
        }
    }

    // MARK: - Drawing Helpers

    private static let chineseNumbers = ["", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖", "拾", "拾壹", "拾贰"]

    private func drawTickMarks(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for i in 1...12 {
            let angle = Angle.degrees(Double(i) * 30 - 90)
            let isMajor = (i % 3 == 0)
            let innerR = radius * (isMajor ? 0.82 : 0.87)
            let outerR = radius * 0.93
            let color = isMajor ? theme.majorTickMarkColor : theme.tickMarkColor
            let width: CGFloat = isMajor ? 1.5 : 1

            let x1 = center.x + innerR * cos(angle.radians)
            let y1 = center.y + innerR * sin(angle.radians)
            let x2 = center.x + outerR * cos(angle.radians)
            let y2 = center.y + outerR * sin(angle.radians)

            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private func drawNumbers(context: GraphicsContext, center: CGPoint, radius: CGFloat, fontSize: CGFloat) {
        let numberRadius = radius * 0.72
        for i in 1...12 {
            if theme.showsCardinalNumbersOnly && i % 3 != 0 { continue }
            let angle = Angle.degrees(Double(i) * 30 - 90)
            let x = center.x + numberRadius * cos(angle.radians)
            let y = center.y + numberRadius * sin(angle.radians)

            let label: String
            switch theme.numberStyle {
            case .chinese: label = Self.chineseNumbers[i]
            case .arabic:  label = "\(i)"
            }

            let text = Text(label)
                .font(.system(size: fontSize, weight: .medium, design: theme.numberFontDesign))
                .foregroundColor(theme.numberColor)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    private func drawRoundHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: endX, y: endY))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func drawTaperedHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                                 angle: Angle, baseWidth: CGFloat, tipWidth: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let backR = radius * 0.12
        let backX = center.x - backR * cos(angle.radians)
        let backY = center.y - backR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        var path = Path()
        path.move(to: CGPoint(x: backX + dx * baseWidth / 2, y: backY + dy * baseWidth / 2))
        path.addLine(to: CGPoint(x: endX + dx * tipWidth / 2, y: endY + dy * tipWidth / 2))
        path.addLine(to: CGPoint(x: endX - dx * tipWidth / 2, y: endY - dy * tipWidth / 2))
        path.addLine(to: CGPoint(x: backX - dx * baseWidth / 2, y: backY - dy * baseWidth / 2))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func drawLanceHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let midR = radius * 0.35
        let midX = center.x + midR * cos(angle.radians)
        let midY = center.y + midR * sin(angle.radians)
        let backR = radius * 0.1
        let backX = center.x - backR * cos(angle.radians)
        let backY = center.y - backR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        var path = Path()
        path.move(to: CGPoint(x: backX, y: backY))
        path.addLine(to: CGPoint(x: midX + dx * width / 2, y: midY + dy * width / 2))
        path.addLine(to: CGPoint(x: endX, y: endY))
        path.addLine(to: CGPoint(x: midX - dx * width / 2, y: midY - dy * width / 2))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func drawSwordHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let tipStartR = radius * 0.85
        let tipStartX = center.x + tipStartR * cos(angle.radians)
        let tipStartY = center.y + tipStartR * sin(angle.radians)
        let guardFrontR = radius * 0.10
        let guardFrontX = center.x + guardFrontR * cos(angle.radians)
        let guardFrontY = center.y + guardFrontR * sin(angle.radians)
        let guardBackR = radius * 0.02
        let guardBackX = center.x + guardBackR * cos(angle.radians)
        let guardBackY = center.y + guardBackR * sin(angle.radians)
        let handleEndR = radius * 0.12
        let handleEndX = center.x - handleEndR * cos(angle.radians)
        let handleEndY = center.y - handleEndR * sin(angle.radians)
        let pommelR = radius * 0.16
        let pommelX = center.x - pommelR * cos(angle.radians)
        let pommelY = center.y - pommelR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        let hw = width / 2
        let gw = width * 0.9
        let bw = width * 0.35
        let pw = width * 0.45

        var path = Path()
        path.move(to: CGPoint(x: pommelX + dx * pw, y: pommelY + dy * pw))
        path.addLine(to: CGPoint(x: handleEndX + dx * bw, y: handleEndY + dy * bw))
        path.addLine(to: CGPoint(x: guardBackX + dx * gw, y: guardBackY + dy * gw))
        path.addLine(to: CGPoint(x: guardFrontX + dx * gw, y: guardFrontY + dy * gw))
        path.addLine(to: CGPoint(x: guardFrontX + dx * hw, y: guardFrontY + dy * hw))
        path.addLine(to: CGPoint(x: tipStartX + dx * hw, y: tipStartY + dy * hw))
        path.addLine(to: CGPoint(x: endX, y: endY))
        path.addLine(to: CGPoint(x: tipStartX - dx * hw, y: tipStartY - dy * hw))
        path.addLine(to: CGPoint(x: guardFrontX - dx * hw, y: guardFrontY - dy * hw))
        path.addLine(to: CGPoint(x: guardFrontX - dx * gw, y: guardFrontY - dy * gw))
        path.addLine(to: CGPoint(x: guardBackX - dx * gw, y: guardBackY - dy * gw))
        path.addLine(to: CGPoint(x: handleEndX - dx * bw, y: handleEndY - dy * bw))
        path.addLine(to: CGPoint(x: pommelX - dx * pw, y: pommelY - dy * pw))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    // MARK: - 天空主题装饰（缩略图版）

    private func drawSkyDecoration(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let sunColor = Color(red: 1.0, green: 0.850, blue: 0.300)
        let cloudColor = Color(white: 0.950)
        let birdColor = Color(red: 0.280, green: 0.380, blue: 0.500)

        let sunAngle = Angle.degrees(-55)
        let sunR = radius * 0.62
        let sunX = center.x + sunR * cos(sunAngle.radians)
        let sunY = center.y + sunR * sin(sunAngle.radians)
        let sunSize = radius * 0.10

        let glow = Path(ellipseIn: CGRect(
            x: sunX - sunSize * 1.5, y: sunY - sunSize * 1.5,
            width: sunSize * 3, height: sunSize * 3))
        context.fill(glow, with: .color(Color(red: 1.0, green: 0.920, blue: 0.600).opacity(0.25)))
        let sun = Path(ellipseIn: CGRect(
            x: sunX - sunSize, y: sunY - sunSize,
            width: sunSize * 2, height: sunSize * 2))
        context.fill(sun, with: .color(sunColor))

        drawCloud(context: context, cx: center.x - radius * 0.38,
                  cy: center.y - radius * 0.28, scale: radius * 0.10, color: cloudColor)
        drawBird(context: context, cx: center.x - radius * 0.35,
                 cy: center.y + radius * 0.18, scale: radius * 0.05, color: birdColor)
    }

    private func drawCloud(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                          scale: CGFloat, color: Color) {
        let c1 = Path(ellipseIn: CGRect(x: cx - scale * 1.1, y: cy - scale * 0.4,
                                        width: scale * 1.4, height: scale * 1.0))
        let c2 = Path(ellipseIn: CGRect(x: cx - scale * 0.4, y: cy - scale * 0.9,
                                        width: scale * 1.2, height: scale * 1.0))
        let c3 = Path(ellipseIn: CGRect(x: cx + scale * 0.2, y: cy - scale * 0.3,
                                        width: scale * 1.2, height: scale * 0.9))
        context.fill(c1, with: .color(color))
        context.fill(c2, with: .color(color))
        context.fill(c3, with: .color(color))
    }

    private func drawBird(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                         scale: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: cx - scale, y: cy + scale * 0.3))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy - scale * 0.2),
                         control: CGPoint(x: cx - scale * 0.3, y: cy - scale * 0.5))
        path.addQuadCurve(to: CGPoint(x: cx + scale, y: cy + scale * 0.3),
                         control: CGPoint(x: cx + scale * 0.3, y: cy - scale * 0.5))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: scale * 0.25, lineCap: .round))
    }
}

// MARK: - 基于 CustomThemeConfig 的预览时钟

struct ThemePreviewClockWithConfig: View {
    let config: CustomThemeConfig
    private let hours = 10
    private let minutes = 10
    private let seconds = 30

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3

            // 表盘
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2))
            // 玻璃盘体由外层 .glassEffect 提供；预览不填充不透明底色，仅描外环。
            context.stroke(circle.strokedPath(StrokeStyle(lineWidth: config.dialRimWidth)),
                           with: .color(config.dialRimColor.swiftUIColor))

            // 刻度
            if config.hasTickMarks {
                drawTickMarks(context: context, center: center, radius: radius)
            }

            // 天空装饰
            if config.hasDialDecoration {
                drawSkyDecoration(context: context, center: center, radius: radius)
            }

            // 数字
            if config.showNumbers {
                drawNumbers(context: context, center: center, radius: radius, fontSize: 7)
            }

            // 指针
            let hourAngle = Angle.degrees(Double(hours % 12) * 30 + Double(minutes) * 0.5 - 90)
            let minuteAngle = Angle.degrees(Double(minutes) * 6 - 90)
            let secondAngle = Angle.degrees(Double(seconds) * 6 - 90)

            switch config.handStyle {
            case .round:
                drawRoundHand(context: context, center: center,
                              radius: radius * config.hourHandLength,
                              angle: hourAngle, width: config.hourHandWidth * 0.7,
                              color: config.hourHandColor.swiftUIColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * config.minuteHandLength,
                              angle: minuteAngle, width: config.minuteHandWidth * 0.7,
                              color: config.minuteHandColor.swiftUIColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * config.secondHandLength,
                              angle: secondAngle, width: config.secondHandWidth * 0.7,
                              color: config.secondHandColor.swiftUIColor)

            case .tapered:
                drawTaperedHand(context: context, center: center,
                                radius: radius * config.hourHandLength,
                                angle: hourAngle, baseWidth: config.hourHandWidth * 0.7,
                                tipWidth: 1, color: config.hourHandColor.swiftUIColor)
                drawTaperedHand(context: context, center: center,
                                radius: radius * config.minuteHandLength,
                                angle: minuteAngle, baseWidth: config.minuteHandWidth * 0.7,
                                tipWidth: 0.8, color: config.minuteHandColor.swiftUIColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * config.secondHandLength,
                              angle: secondAngle, width: config.secondHandWidth * 0.7,
                              color: config.secondHandColor.swiftUIColor)

            case .lance:
                drawLanceHand(context: context, center: center,
                              radius: radius * config.hourHandLength,
                              angle: hourAngle, width: config.hourHandWidth * 0.7,
                              color: config.hourHandColor.swiftUIColor)
                drawLanceHand(context: context, center: center,
                              radius: radius * config.minuteHandLength,
                              angle: minuteAngle, width: config.minuteHandWidth * 0.7,
                              color: config.minuteHandColor.swiftUIColor)
                drawRoundHand(context: context, center: center,
                              radius: radius * config.secondHandLength,
                              angle: secondAngle, width: config.secondHandWidth * 0.7,
                              color: config.secondHandColor.swiftUIColor)

            case .sword:
                drawSwordHand(context: context, center: center,
                              radius: radius * config.hourHandLength,
                              angle: hourAngle, width: config.hourHandWidth * 0.7,
                              color: config.hourHandColor.swiftUIColor)
                drawSwordHand(context: context, center: center,
                              radius: radius * config.minuteHandLength,
                              angle: minuteAngle, width: config.minuteHandWidth * 0.7,
                              color: config.minuteHandColor.swiftUIColor)
                drawSwordHand(context: context, center: center,
                              radius: radius * config.secondHandLength,
                              angle: secondAngle, width: config.secondHandWidth * 0.7,
                              color: config.secondHandColor.swiftUIColor)
            }

            // 中心点
            let outerDot = Path(ellipseIn: CGRect(
                x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5))
            context.fill(outerDot, with: .color(config.centerDotOuterColor.swiftUIColor))
            let innerDot = Path(ellipseIn: CGRect(
                x: center.x - 1, y: center.y - 1, width: 2, height: 2))
            context.fill(innerDot, with: .color(config.centerDotInnerColor.swiftUIColor))
        }
    }

    // MARK: - Drawing Helpers

    private static let chineseNumbers = ["", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖", "拾", "拾壹", "拾贰"]

    private func drawTickMarks(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for i in 1...12 {
            let angle = Angle.degrees(Double(i) * 30 - 90)
            let isMajor = (i % 3 == 0)
            let innerR = radius * (isMajor ? 0.82 : 0.87)
            let outerR = radius * 0.93
            let color = isMajor ? config.majorTickMarkColor.swiftUIColor : config.tickMarkColor.swiftUIColor
            let width: CGFloat = isMajor ? 1.5 : 1

            let x1 = center.x + innerR * cos(angle.radians)
            let y1 = center.y + innerR * sin(angle.radians)
            let x2 = center.x + outerR * cos(angle.radians)
            let y2 = center.y + outerR * sin(angle.radians)

            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private func drawNumbers(context: GraphicsContext, center: CGPoint, radius: CGFloat, fontSize: CGFloat) {
        let numberRadius = radius * 0.72
        for i in 1...12 {
            let angle = Angle.degrees(Double(i) * 30 - 90)
            let x = center.x + numberRadius * cos(angle.radians)
            let y = center.y + numberRadius * sin(angle.radians)

            let label: String
            switch config.numberStyle {
            case .chinese: label = Self.chineseNumbers[i]
            case .arabic:  label = "\(i)"
            }

            let text = Text(label)
                .font(.system(size: fontSize, weight: .medium, design: config.numberFontDesign))
                .foregroundColor(config.numberColor.swiftUIColor)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    private func drawRoundHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: endX, y: endY))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func drawTaperedHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                                 angle: Angle, baseWidth: CGFloat, tipWidth: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let backR = radius * 0.12
        let backX = center.x - backR * cos(angle.radians)
        let backY = center.y - backR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        var path = Path()
        path.move(to: CGPoint(x: backX + dx * baseWidth / 2, y: backY + dy * baseWidth / 2))
        path.addLine(to: CGPoint(x: endX + dx * tipWidth / 2, y: endY + dy * tipWidth / 2))
        path.addLine(to: CGPoint(x: endX - dx * tipWidth / 2, y: endY - dy * tipWidth / 2))
        path.addLine(to: CGPoint(x: backX - dx * baseWidth / 2, y: backY - dy * baseWidth / 2))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func drawLanceHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let midR = radius * 0.35
        let midX = center.x + midR * cos(angle.radians)
        let midY = center.y + midR * sin(angle.radians)
        let backR = radius * 0.1
        let backX = center.x - backR * cos(angle.radians)
        let backY = center.y - backR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        var path = Path()
        path.move(to: CGPoint(x: backX, y: backY))
        path.addLine(to: CGPoint(x: midX + dx * width / 2, y: midY + dy * width / 2))
        path.addLine(to: CGPoint(x: endX, y: endY))
        path.addLine(to: CGPoint(x: midX - dx * width / 2, y: midY - dy * width / 2))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func drawSwordHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let tipStartR = radius * 0.85
        let tipStartX = center.x + tipStartR * cos(angle.radians)
        let tipStartY = center.y + tipStartR * sin(angle.radians)
        let guardFrontR = radius * 0.10
        let guardFrontX = center.x + guardFrontR * cos(angle.radians)
        let guardFrontY = center.y + guardFrontR * sin(angle.radians)
        let guardBackR = radius * 0.02
        let guardBackX = center.x - guardBackR * cos(angle.radians)
        let guardBackY = center.y - guardBackR * sin(angle.radians)
        let handleEndR = radius * 0.12
        let handleEndX = center.x - handleEndR * cos(angle.radians)
        let handleEndY = center.y - handleEndR * sin(angle.radians)
        let pommelR = radius * 0.16
        let pommelX = center.x - pommelR * cos(angle.radians)
        let pommelY = center.y - pommelR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        let hw = width / 2
        let gw = width * 0.9
        let bw = width * 0.35
        let pw = width * 0.45

        var path = Path()
        path.move(to: CGPoint(x: pommelX + dx * pw, y: pommelY + dy * pw))
        path.addLine(to: CGPoint(x: handleEndX + dx * bw, y: handleEndY + dy * bw))
        path.addLine(to: CGPoint(x: guardBackX + dx * gw, y: guardBackY + dy * gw))
        path.addLine(to: CGPoint(x: guardFrontX + dx * gw, y: guardFrontY + dy * gw))
        path.addLine(to: CGPoint(x: guardFrontX + dx * hw, y: guardFrontY + dy * hw))
        path.addLine(to: CGPoint(x: tipStartX + dx * hw, y: tipStartY + dy * hw))
        path.addLine(to: CGPoint(x: endX, y: endY))
        path.addLine(to: CGPoint(x: tipStartX - dx * hw, y: tipStartY - dy * hw))
        path.addLine(to: CGPoint(x: guardFrontX - dx * hw, y: guardFrontY - dy * hw))
        path.addLine(to: CGPoint(x: guardFrontX - dx * gw, y: guardFrontY - dy * gw))
        path.addLine(to: CGPoint(x: guardBackX - dx * gw, y: guardBackY - dy * gw))
        path.addLine(to: CGPoint(x: handleEndX - dx * bw, y: handleEndY - dy * bw))
        path.addLine(to: CGPoint(x: pommelX - dx * pw, y: pommelY - dy * pw))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    private func drawSkyDecoration(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let sunColor = Color(red: 1.0, green: 0.850, blue: 0.300)
        let cloudColor = Color(white: 0.950)
        let birdColor = Color(red: 0.280, green: 0.380, blue: 0.500)

        let sunAngle = Angle.degrees(-55)
        let sunR = radius * 0.62
        let sunX = center.x + sunR * cos(sunAngle.radians)
        let sunY = center.y + sunR * sin(sunAngle.radians)
        let sunSize = radius * 0.10

        let glow = Path(ellipseIn: CGRect(
            x: sunX - sunSize * 1.5, y: sunY - sunSize * 1.5,
            width: sunSize * 3, height: sunSize * 3))
        context.fill(glow, with: .color(Color(red: 1.0, green: 0.920, blue: 0.600).opacity(0.25)))
        let sun = Path(ellipseIn: CGRect(
            x: sunX - sunSize, y: sunY - sunSize,
            width: sunSize * 2, height: sunSize * 2))
        context.fill(sun, with: .color(sunColor))

        drawCloud(context: context, cx: center.x - radius * 0.38,
                  cy: center.y - radius * 0.28, scale: radius * 0.10, color: cloudColor)
        drawBird(context: context, cx: center.x - radius * 0.35,
                 cy: center.y + radius * 0.18, scale: radius * 0.05, color: birdColor)
    }

    private func drawCloud(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                          scale: CGFloat, color: Color) {
        let c1 = Path(ellipseIn: CGRect(x: cx - scale * 1.1, y: cy - scale * 0.4,
                                        width: scale * 1.4, height: scale * 1.0))
        let c2 = Path(ellipseIn: CGRect(x: cx - scale * 0.4, y: cy - scale * 0.9,
                                        width: scale * 1.2, height: scale * 1.0))
        let c3 = Path(ellipseIn: CGRect(x: cx + scale * 0.2, y: cy - scale * 0.3,
                                        width: scale * 1.2, height: scale * 0.9))
        context.fill(c1, with: .color(color))
        context.fill(c2, with: .color(color))
        context.fill(c3, with: .color(color))
    }

    private func drawBird(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                         scale: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: cx - scale, y: cy + scale * 0.3))
        path.addQuadCurve(to: CGPoint(x: cx, y: cy - scale * 0.2),
                         control: CGPoint(x: cx - scale * 0.3, y: cy - scale * 0.5))
        path.addQuadCurve(to: CGPoint(x: cx + scale, y: cy + scale * 0.3),
                         control: CGPoint(x: cx + scale * 0.3, y: cy - scale * 0.5))
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: scale * 0.25, lineCap: .round))
    }
}
