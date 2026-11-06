#if os(macOS)
import AppKit
import WebKit
import XCTest
@testable import TokenClock

final class NetworkLeakLiveTests: XCTestCase {
    @MainActor func testRealWebKitCheckAndWindowTeardown() async throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_NETWORK_LIVE_TEST"] == "1" else {
            throw XCTSkip("Opt-in live DNS/STUN service check")
        }
        _ = NSApplication.shared
        let controller = NetworkLeakWindow()
        controller.show()
        defer { controller.window?.close() }
        XCTAssertTrue(controller.hasActiveProbe)
        let browser = try XCTUnwrap(controller.probeView)
        var state = ""
        for _ in 0..<150 {
            try await Task.sleep(for: .milliseconds(200))
            state = await text(browser, "document.getElementById('idle')?.textContent || ''")
            if state.contains("finished") || state.contains("检测完成") || state.contains("could not") || state.contains("未能完成") { break }
        }
        XCTAssertTrue(state.contains("finished") || state.contains("检测完成"), state)
        let resolvers = await text(browser, "String(document.querySelectorAll('#dnsAddresses code').length)")
        XCTAssertGreaterThan(Int(resolvers) ?? 0, 0)
        let verdict = await text(browser, "document.getElementById('rtcBadge')?.dataset.state || ''")
        XCTAssertTrue(["match", "review", "risk"].contains(verdict), "Live WebRTC did not obtain a public candidate: " + verdict)
        print("Native WebKit live check: DNS observed; WebRTC public candidate obtained; verdict=" + verdict)
        let aiCount = await text(browser, "String(document.querySelectorAll('#aiAddresses .diagnostic-row').length)")
        XCTAssertEqual(aiCount, "6")
        let consistency = await text(browser, "String(document.querySelectorAll('#consistencyAddresses .diagnostic-row').length)")
        XCTAssertGreaterThanOrEqual(Int(consistency) ?? 0, 3)
        let v6 = await text(browser, "document.getElementById('ipv6Badge')?.dataset.state || ''")
        XCTAssertTrue(["match", "review", "risk", "notObserved"].contains(v6))
        print("Native diagnostics: six AI domains, exit/country observations, IPv6 verdict=" + v6)
        XCTAssertEqual(controller.presentedCards.count,7)
        for card in controller.presentedCards {
            XCTAssertFalse(card.text.replacingOccurrences(of:"·",with:"").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Hidden WebKit text must reach native cards: "+card.id)
        }
        XCTAssertFalse(controller.presentedSummary.isEmpty)
        let doh = await text(browser,"document.getElementById('dohBadge')?.textContent || ''")
        XCTAssertTrue(doh.contains("2/2") || doh.contains("1/2"),"At least one live DoH query must verify: "+doh)
        // An explicit second run is cancelled by closing the containing window.
        _ = await text(browser, "document.getElementById('start').click(); 'started'")
        controller.window?.close()
        XCTAssertFalse(controller.hasActiveProbe)
    }

    @MainActor private func text(_ browser: WKWebView, _ script: String) async -> String {
        await withCheckedContinuation { continuation in
            browser.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String ?? "")
            }
        }
    }
}
#endif
