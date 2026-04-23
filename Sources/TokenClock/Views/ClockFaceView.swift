import SwiftUI

/// 表盘视图：浅灰色圆盘 + 红色层次指针
struct ClockFaceView: View {
    let hours: Int
    let minutes: Int
    let seconds: Int
    let onTap: () -> Void

    /// 纯灰色表盘
    private let dialColor = Color(red: 0.75, green: 0.75, blue: 0.77)
    /// 时针：深红 #B71C1C
    private let hourHandColor = Color(red: 0.718, green: 0.110, blue: 0.110)
    /// 分针：中红 #E53935
    private let minuteHandColor = Color(red: 0.898, green: 0.224, blue: 0.208)
    /// 秒针：亮红 #FF5252
    private let secondHandColor = Color(red: 1.0, green: 0.322, blue: 0.322)

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 4

            // 纯灰色圆盘
            let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                 width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(dialColor))

            // 简洁外环
            let rimPath = circle.strokedPath(StrokeStyle(lineWidth: 2))
            context.stroke(rimPath, with: .color(Color(white: 0.55)),
                           style: StrokeStyle(lineWidth: 2))

            // 画指针：时针→分针→秒针
            drawHand(context: context, center: center, radius: radius * 0.48,
                     angle: hourAngle, width: 4.5, color: hourHandColor)
            drawHand(context: context, center: center, radius: radius * 0.68,
                     angle: minuteAngle, width: 3, color: minuteHandColor)
            drawHand(context: context, center: center, radius: radius * 0.78,
                     angle: secondAngle, width: 1.5, color: secondHandColor)

            // 中心圆点
            let dotPath = Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3,
                                                  width: 6, height: 6))
            context.fill(dotPath, with: .color(Color(white: 0.55)))
            let innerDot = Path(ellipseIn: CGRect(x: center.x - 1.5, y: center.y - 1.5,
                                                   width: 3, height: 3))
            context.fill(innerDot, with: .color(minuteHandColor))
        }
        .onTapGesture { onTap() }
    }

    // MARK: - 角度计算

    private var hourAngle: Angle {
        Angle.degrees(Double(hours % 12) * 30 + Double(minutes) * 0.5 - 90)
    }

    private var minuteAngle: Angle {
        Angle.degrees(Double(minutes) * 6 - 90)
    }

    private var secondAngle: Angle {
        Angle.degrees(Double(seconds) * 6 - 90)
    }

    // MARK: - 绘制指针

    private func drawHand(context: GraphicsContext, center: CGPoint, radius: CGFloat,
                          angle: Angle, width: CGFloat, color: Color) {
        let endX = center.x + radius * cos(angle.radians)
        let endY = center.y + radius * sin(angle.radians)

        var path = Path()
        path.move(to: center)
        path.addLine(to: CGPoint(x: endX, y: endY))

        context.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
