import SwiftUI

/// 关于 / 版权信息面板（右键菜单「关于 TokenClock」项弹出）。
struct AboutView: View {
    let onDone: () -> Void

    // ⚠️ 发版时同步版本号（与 cli/install.sh 的 RELEASE_TAG、cli/tokenclock 的 CLI_VERSION 一致）
    private let version = "v1.2.9"
    private let issuesURL = URL(string: "https://github.com/Neo-Isshin/TokenClock/issues")!

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("TokenClock")
                    .font(.system(size: 22, weight: .semibold))
                Text(version)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(spacing: 6) {
                Text("Copyright © 2026 Neo-Isshin")
                Text(L10n.shared.tr("about.license"))
            }
            .font(.system(size: 13))

            Divider()

            VStack(spacing: 6) {
                Text(L10n.shared.tr("about.contact"))
                    .font(.system(size: 13, weight: .medium))
                Link("GitHub Issues", destination: issuesURL)
                    .font(.system(size: 13))
            }

            Spacer(minLength: 0)

            Button(L10n.shared.tr("about.close")) { onDone() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 320)
    }
}
