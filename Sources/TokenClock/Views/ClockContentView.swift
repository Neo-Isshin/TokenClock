import SwiftUI

/// 主内容视图：表盘 + 叠加信息
struct ClockContentView: View {
    @ObservedObject var viewModel: ViewModel
    @ObservedObject private var clockTicker: ClockTicker
    let onNotificationClick: () -> Void
    let onClockDragStart: () -> Void

    init(
        viewModel: ViewModel,
        onNotificationClick: @escaping () -> Void = {},
        onClockDragStart: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onNotificationClick = onNotificationClick
        self.onClockDragStart = onClockDragStart
        self._clockTicker = ObservedObject(wrappedValue: viewModel.clockTicker)
    }

    var body: some View {
        // 表盘大小随用户设置缩放：d = 直径，s = 相对中档(240)的缩放比。
        let d = viewModel.clockSize.diameter
        let s = viewModel.clockSize.scale

        ZStack {
            // 表盘
            ClockFaceView(
                hours: viewModel.hours,
                minutes: viewModel.minutes,
                seconds: viewModel.seconds,
                theme: viewModel.selectedTheme,
                numberColorOverride: viewModel.effectiveDialNumberColor,
                scale: s
            )
            .frame(width: d, height: d)

            // 叠加信息：位于中心到边缘中点位置
            VStack(spacing: 0) {
                // 上方：日期 + 天气（中心到上部中点）
                VStack(spacing: 3) {
                    Text(viewModel.dateString)
                        .font(.system(size: 11 * s, weight: .medium))
                        .foregroundColor(viewModel.effectiveDialSecondary)
                    Color.clear.frame(height: 16 * s)
                }
                .padding(.top, 55 * s)

                Spacer()

                // 下方：tokens + 消息数（中心到下部中点）
                VStack(spacing: 2) {
                    Text(L10n.shared.tr("clock.todayTokens"))
                        .font(.system(size: 9 * s))
                        .foregroundColor(viewModel.effectiveDialSecondary)
                    Text(viewModel.totalTokensFormatted)
                        .font(.system(size: 20 * s, weight: .bold, design: .rounded))
                        .foregroundColor(viewModel.effectiveDialPrimary)
                    Text(viewModel.totalMessagesFormatted)
                        .font(.system(size: 10 * s))
                        .foregroundColor(viewModel.effectiveDialSecondary)
                }
                .padding(.bottom, 48 * s)
            }

            // 左侧：活跃工具标签
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.activeToolsList) { tool in
                        Text("\(tool.emoji) \(tool.abbreviation)")
                            .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                            .foregroundColor(viewModel.effectiveDialPrimary.opacity(0.75))
                    }
                }
                .padding(.leading, 32 * s)
                Spacer()
            }

            // 右侧：速率 emoji
            HStack {
                Spacer()
                Text(viewModel.rateEmoji)
                    .font(.system(size: 28 * s))
                    .padding(.trailing, 32 * s)
            }

            // SwiftUI 的 tap 手势会吞掉「窗口背景拖拽」的鼠标序列（normal 版曾因此拖不动表盘）。
            // 点击/拖动改由 AppKit 层分发：>3pt 位移 = 拖动窗口，否则 = 点击展开详情。
            ClockInteractionLayer {
                viewModel.isExpanded.toggle()
            } onDragStart: {
                viewModel.isExpanded = false
                onClockDragStart()
            }
            .frame(width: d, height: d)
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                HStack(spacing: 4 * s) {
                    Text(viewModel.weatherString)
                        .font(.system(size: 13 * s))
                        .foregroundColor(viewModel.effectiveDialPrimary)
                        .allowsHitTesting(false)
                    if viewModel.unreadNotificationCount > 0 {
                        notificationButton(scale: s)
                    }
                }
                .padding(.top, 70 * s)
                Spacer()
            }
        }
        .frame(width: d, height: d)
        // 无障碍：表盘是纯视觉（指针/emoji/格式化数字），VoiceOver 读不出含义。
        // 收拢成单一元素，朗读「时间 + 今日用量」摘要；保留按钮特性（点按展开）。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityHint(Text(L10n.shared.tr("a11y.clockHint")))
        .accessibilityAddTraits(.isButton)
    }

    /// VoiceOver 朗读摘要：时间 + 今日 token + 消息数（已随语言本地化）。
    private var accessibilitySummary: String {
        let time = String(format: "%d:%02d", viewModel.hours, viewModel.minutes)
        return L10n.shared.tr("a11y.clockSummary",
                              viewModel.dateString,
                              time,
                              viewModel.totalTokensFormatted,
                              viewModel.totalMessagesFormatted)
    }

    @ViewBuilder
    private func notificationButton(scale s: CGFloat) -> some View {
        Button(action: onNotificationClick) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: viewModel.unreadNotificationCount > 0 ? "bell.fill" : "bell")
                    .font(.system(size: 14 * s, weight: .semibold))
                    .foregroundColor(viewModel.effectiveDialPrimary.opacity(
                        viewModel.unreadNotificationCount > 0 ? 0.95 : 0.62
                    ))
                    .frame(width: 20 * s, height: 20 * s)
                    .contentShape(Circle())

                if viewModel.unreadNotificationCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6 * s, height: 6 * s)
                        .overlay(Circle().stroke(viewModel.selectedTheme.dialColor, lineWidth: 1 * s))
                        .offset(x: -2 * s, y: 2 * s)
                }
            }
        }
        .buttonStyle(.plain)
        .help(L10n.shared.tr("notification.open"))
        .accessibilityLabel(Text(L10n.shared.tr("notification.open")))
    }
}
