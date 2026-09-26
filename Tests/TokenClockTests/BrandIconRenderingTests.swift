#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

final class BrandIconRenderingTests: XCTestCase {
    @MainActor
    func testBundledIconsRenderOnBothPanelBackgrounds() throws {
        let names = ["Codex", "gpt-6-astra", "Claude Code", "claude-opus-5", "Gemini CLI",
                     "Cursor Agent", "Antigravity", "Grok Bot", "grok-4", "Qwen Code",
                     "qwen3-coder", "MiniMax-M3", "ZCode", "glm-5", "OpenClaw", "Hermes",
                     "OpenCode", "Copilot", "Aider", "Cline", "Continue", "Kiro CLI", "CodeBuddy CLI"]
        let content = HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { dark in
                VStack(alignment: .leading, spacing: 7) {
                    Text(dark ? "Dark panel" : "Light panel").font(.headline)
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 8) {
                            BrandIconView(name: name, fallback: "?", size: 16)
                            Text(name).font(.system(size: 12))
                            Spacer()
                            BrandIconView(name: name, fallback: "?", size: 24)
                        }
                        .frame(height: 24)
                    }
                }
                .padding(18).frame(width: 280)
                .foregroundColor(dark ? .white : .black)
                .background(dark ? Color(white: 0.13) : Color(white: 0.96))
            }
        }
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 800)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000)
        if let path = ProcessInfo.processInfo.environment["TOKENCLOCK_BRAND_PREVIEW_PATH"] {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
