import SwiftUI

/// 表盘视图：支持多种主题
struct ClockFaceView: View {
    let hours: Int
    let minutes: Int
    let seconds: Int
    var theme: ClockFaceTheme = .classic

    enum Role { case face, hands, full }
    var role: Role = .full

    /// 相对中档(240)的缩放比，用于缩放表盘数字字号（其余几何已按 radius 自动缩放）。
    var scale: CGFloat = 1.0

    /// 表盘数字颜色覆盖（nil = 跟随主题 theme.numberColor）。
    /// 由「表盘外观 ▸ 文字颜色」注入，解决浅色壁纸上白色数字不可见。
    var numberColorOverride: Color? = nil

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 4

            if role == .face || role == .full {
                drawDial(context: context, center: center, radius: radius)

                if theme.hasDialDecoration {
                    drawDialDecoration(context: context, center: center, radius: radius)
                }

                if theme.hasTickMarks {
                    drawTickMarks(context: context, center: center, radius: radius)
                }

                if theme.showNumbers {
                    drawNumbers(context: context, center: center, radius: radius)
                }
            }

            if role == .hands || role == .full {
                drawHands(context: context, center: center, radius: radius)
                drawCenterDot(context: context, center: center)
            }
        }
    }

    // MARK: - 表盘

    private func drawDial(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        // 玻璃盘体由 ClockContentView 的 .glassEffect 提供；
        // 表盘不再填充不透明色，仅描出外环，让玻璃折射壁纸透出。
        let circle = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))

        // 外环（直接描边，避免 strokedPath 导致的双层叠加）
        context.stroke(
            circle,
            with: .color(theme.dialRimColor),
            style: StrokeStyle(lineWidth: theme.dialRimWidth, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - 刻度

    private func drawTickMarks(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        for i in 1...12 {
            let angle = Angle.degrees(Double(i) * 30 - 90)
            let isMajor = (i % 3 == 0)
            let innerR = radius * (isMajor ? 0.91 : 0.935)
            let outerR = radius * 0.97
            let color = numberColorOverride ?? (isMajor ? theme.majorTickMarkColor : theme.tickMarkColor)
            let width: CGFloat = isMajor ? 2 : 1.2

            let x1 = center.x + innerR * cos(angle.radians)
            let y1 = center.y + innerR * sin(angle.radians)
            let x2 = center.x + outerR * cos(angle.radians)
            let y2 = center.y + outerR * sin(angle.radians)

            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            path.addLine(to: CGPoint(x: x2, y: y2))
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    // MARK: - 数字

    private static let chineseNumbers = ["", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖", "拾", "拾壹", "拾贰"]

    private func drawNumbers(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let numberRadius = radius * 0.84
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
                .font(.system(size: 13 * scale, weight: .medium, design: theme.numberFontDesign))
                .foregroundColor(numberColorOverride ?? theme.numberColor)
            let resolved = context.resolve(text)
            context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
        }
    }

    // MARK: - 指针

    private func drawHands(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let hourAngle = Angle.degrees(Double(hours % 12) * 30 + Double(minutes) * 0.5 - 90)
        let minuteAngle = Angle.degrees(Double(minutes) * 6 - 90)
        let secondAngle = Angle.degrees(Double(seconds) * 6 - 90)

        switch theme.handStyle {
        case .round:
            drawRoundHand(context: context, center: center,
                          radius: radius * theme.hourHandLength,
                          angle: hourAngle, width: theme.hourHandWidth,
                          color: theme.hourHandColor)
            drawRoundHand(context: context, center: center,
                          radius: radius * theme.minuteHandLength,
                          angle: minuteAngle, width: theme.minuteHandWidth,
                          color: theme.minuteHandColor)
            drawRoundHand(context: context, center: center,
                          radius: radius * theme.secondHandLength,
                          angle: secondAngle, width: theme.secondHandWidth,
                          color: theme.secondHandColor)

        case .tapered:
            drawTaperedHand(context: context, center: center,
                            radius: radius * theme.hourHandLength,
                            angle: hourAngle, baseWidth: theme.hourHandWidth,
                            tipWidth: 1.5, color: theme.hourHandColor)
            drawTaperedHand(context: context, center: center,
                            radius: radius * theme.minuteHandLength,
                            angle: minuteAngle, baseWidth: theme.minuteHandWidth,
                            tipWidth: 1.2, color: theme.minuteHandColor)
            drawRoundHand(context: context, center: center,
                          radius: radius * theme.secondHandLength,
                          angle: secondAngle, width: theme.secondHandWidth,
                          color: theme.secondHandColor)

        case .lance:
            drawLanceHand(context: context, center: center,
                          radius: radius * theme.hourHandLength,
                          angle: hourAngle, width: theme.hourHandWidth,
                          color: theme.hourHandColor)
            drawLanceHand(context: context, center: center,
                          radius: radius * theme.minuteHandLength,
                          angle: minuteAngle, width: theme.minuteHandWidth,
                          color: theme.minuteHandColor)
            drawRoundHand(context: context, center: center,
                          radius: radius * theme.secondHandLength,
                          angle: secondAngle, width: theme.secondHandWidth,
                          color: theme.secondHandColor)

        case .sword:
            drawSwordHand(context: context, center: center,
                          radius: radius * theme.hourHandLength,
                          angle: hourAngle, width: theme.hourHandWidth,
                          color: theme.hourHandColor)
            drawSwordHand(context: context, center: center,
                          radius: radius * theme.minuteHandLength,
                          angle: minuteAngle, width: theme.minuteHandWidth,
                          color: theme.minuteHandColor)
            drawSwordHand(context: context, center: center,
                          radius: radius * theme.secondHandLength,
                          angle: secondAngle, width: theme.secondHandWidth,
                          color: theme.secondHandColor)
        }
    }

    // MARK: - 中心点

    private func drawCenterDot(context: GraphicsContext, center: CGPoint) {
        let outerR: CGFloat = 4
        let innerR: CGFloat = 2
        let outerDot = Path(ellipseIn: CGRect(
            x: center.x - outerR, y: center.y - outerR,
            width: outerR * 2, height: outerR * 2))
        context.fill(outerDot, with: .color(theme.centerDotOuterColor))

        let innerDot = Path(ellipseIn: CGRect(
            x: center.x - innerR, y: center.y - innerR,
            width: innerR * 2, height: innerR * 2))
        context.fill(innerDot, with: .color(theme.centerDotInnerColor))
    }

    // MARK: - 指针绘制

    /// 圆头线条指针（经典样式）
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

    /// 锥形指针（底宽顶尖）
    private func drawTaperedHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                                 angle: Angle, baseWidth: CGFloat, tipWidth: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let backR = radius * 0.15
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

    /// 菱形指针（中间最宽，两端尖）
    private func drawLanceHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)
        let midR = radius * 0.35
        let midX = center.x + midR * cos(angle.radians)
        let midY = center.y + midR * sin(angle.radians)
        let backR = radius * 0.12
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

    /// 剑形指针（古风主题）
    /// 形状：剑尖 → 剑身 → 剑格（护手）→ 缠绳剑柄 → 剑尾（剑首）
    private func drawSwordHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                               angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)

        // 剑尖：最后 15% 逐渐变窄
        let tipStartR = radius * 0.85
        let tipStartX = center.x + tipStartR * cos(angle.radians)
        let tipStartY = center.y + tipStartR * sin(angle.radians)

        // 剑格（护手）：中心偏前，比剑身宽
        let guardFrontR = radius * 0.10
        let guardFrontX = center.x + guardFrontR * cos(angle.radians)
        let guardFrontY = center.y + guardFrontR * sin(angle.radians)
        let guardBackR = radius * 0.02
        let guardBackX = center.x + guardBackR * cos(angle.radians)
        let guardBackY = center.y + guardBackR * sin(angle.radians)

        // 剑柄（缠绳部分）：比剑身窄，在剑格之后
        let handleEndR = radius * 0.12
        let handleEndX = center.x - handleEndR * cos(angle.radians)
        let handleEndY = center.y - handleEndR * sin(angle.radians)

        // 剑首（剑柄尾端圆头）
        let pommelR = radius * 0.16
        let pommelX = center.x - pommelR * cos(angle.radians)
        let pommelY = center.y - pommelR * sin(angle.radians)

        let perpAngle = angle + .degrees(90)
        let dx = cos(perpAngle.radians)
        let dy = sin(perpAngle.radians)

        let hw = width / 2          // 剑身半宽
        let gw = width * 0.9        // 剑格半宽（比剑身更宽）
        let bw = width * 0.35       // 剑柄半宽（比剑身窄）
        let pw = width * 0.45       // 剑首半宽（比剑柄略宽）

        var path = Path()
        // 剑首（左）
        path.move(to: CGPoint(x: pommelX + dx * pw, y: pommelY + dy * pw))
        // 剑柄（左）
        path.addLine(to: CGPoint(x: handleEndX + dx * bw, y: handleEndY + dy * bw))
        // 剑格后（左）
        path.addLine(to: CGPoint(x: guardBackX + dx * gw, y: guardBackY + dy * gw))
        // 剑格前（左）
        path.addLine(to: CGPoint(x: guardFrontX + dx * gw, y: guardFrontY + dy * gw))
            // 剑格到剑身过渡（左）
            path.addLine(to: CGPoint(x: guardFrontX + dx * hw, y: guardFrontY + dy * hw))
        // 剑身（左）
        path.addLine(to: CGPoint(x: tipStartX + dx * hw, y: tipStartY + dy * hw))
        // 剑尖
        path.addLine(to: CGPoint(x: endX, y: endY))
        // 剑身（右）
        path.addLine(to: CGPoint(x: tipStartX - dx * hw, y: tipStartY - dy * hw))
        // 剑格到剑身过渡（右）
        path.addLine(to: CGPoint(x: guardFrontX - dx * hw, y: guardFrontY - dy * hw))
        // 剑格前（右）
        path.addLine(to: CGPoint(x: guardFrontX - dx * gw, y: guardFrontY - dy * gw))
        // 剑格后（右）
        path.addLine(to: CGPoint(x: guardBackX - dx * gw, y: guardBackY - dy * gw))
        // 剑柄（右）
        path.addLine(to: CGPoint(x: handleEndX - dx * bw, y: handleEndY - dy * bw))
        // 剑首（右）
        path.addLine(to: CGPoint(x: pommelX - dx * pw, y: pommelY - dy * pw))
        path.closeSubpath()

        context.fill(path, with: .color(color))
    }

    // MARK: - 表盘装饰

    /// 天空主题装饰：太阳 + 云朵 + 飞鸟
    private func drawDialDecoration(context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let sunColor = Color(red: 1.0, green: 0.850, blue: 0.300)
        let cloudColor = Color(white: 0.950)
        let birdColor = Color(red: 0.280, green: 0.380, blue: 0.500)

        // ☀️ 太阳（右上角，约 1~2 点钟方向之间）
        let sunAngle = Angle.degrees(-55)
        let sunR = radius * 0.62
        let sunX = center.x + sunR * cos(sunAngle.radians)
        let sunY = center.y + sunR * sin(sunAngle.radians)
        let sunSize = radius * 0.10

        // 太阳光晕
        let glow = Path(ellipseIn: CGRect(
            x: sunX - sunSize * 1.5, y: sunY - sunSize * 1.5,
            width: sunSize * 3, height: sunSize * 3
        ))
        context.fill(glow, with: .color(Color(red: 1.0, green: 0.920, blue: 0.600).opacity(0.25)))

        // 太阳本体
        let sun = Path(ellipseIn: CGRect(
            x: sunX - sunSize, y: sunY - sunSize,
            width: sunSize * 2, height: sunSize * 2
        ))
        context.fill(sun, with: .color(sunColor))

        // ☁️ 云朵（多个位置）
        drawCloud(context: context, cx: center.x - radius * 0.38,
                  cy: center.y - radius * 0.28, scale: radius * 0.10, color: cloudColor)
        drawCloud(context: context, cx: center.x + radius * 0.25,
                  cy: center.y + radius * 0.32, scale: radius * 0.07, color: cloudColor.opacity(0.7))
        drawCloud(context: context, cx: center.x - radius * 0.10,
                  cy: center.y + radius * 0.50, scale: radius * 0.055, color: cloudColor.opacity(0.5))

        // 🐦 飞鸟（简笔 V 形，左下区域）
        drawBird(context: context, cx: center.x - radius * 0.35,
                 cy: center.y + radius * 0.18, scale: radius * 0.05, color: birdColor)
        drawBird(context: context, cx: center.x - radius * 0.22,
                 cy: center.y + radius * 0.10, scale: radius * 0.035, color: birdColor.opacity(0.6))
    }

    /// 绘制一朵云（三个重叠圆）
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

    /// 绘制一只飞鸟（简笔 V 形）
    private func drawBird(context: GraphicsContext, cx: CGFloat, cy: CGFloat,
                         scale: CGFloat, color: Color) {
        var path = Path()
        path.move(to: CGPoint(x: cx - scale, y: cy + scale * 0.3))
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy - scale * 0.2),
            control: CGPoint(x: cx - scale * 0.3, y: cy - scale * 0.5)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + scale, y: cy + scale * 0.3),
            control: CGPoint(x: cx + scale * 0.3, y: cy - scale * 0.5)
        )
        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: scale * 0.25, lineCap: .round))
    }
}
