#if os(macOS)
import AppKit
import XCTest
@testable import TokenClock

final class NetworkLeakEndpointTests: XCTestCase {
    func testOnlyExplicitEmbeddedLaunchAutoStarts() {
        let embedded = NetworkLeakEndpoint.url(language: "zh-Hans", embedded: true)
        let browser = NetworkLeakEndpoint.url(language: "en", embedded: false)
        XCTAssertEqual(embedded.fragment, "run")
        XCTAssertNil(browser.fragment)
        XCTAssertTrue(embedded.query?.contains("embedded=1") == true)
        XCTAssertFalse(browser.query?.contains("embedded") == true)
        XCTAssertTrue(NetworkLeakEndpoint.permits(embedded))
        XCTAssertTrue(NetworkLeakEndpoint.permits(browser))
    }

    func testEmbeddedNavigationCannotLeaveItsOriginOrChangeService() {
        for value in ["http://www.ailyre.com/tokenclock/network-check/",
                      "https://www.ailyre.com.evil.test/tokenclock/network-check/",
                      "https://evil.test/tokenclock/network-check/",
                      "https://www.ailyre.com:8443/tokenclock/network-check/",
                      "https://user@www.ailyre.com/tokenclock/network-check/",
                      "https://www.ailyre.com/console/"] {
            XCTAssertFalse(NetworkLeakEndpoint.permits(URL(string: value)!), value)
        }
    }

    @MainActor func testLauncherSymbolExistsAndControllerIsLazy() {
        XCTAssertNotNil(NSImage(systemSymbolName: "network.badge.shield.half.filled", accessibilityDescription: nil))
        let controller = NetworkLeakWindow()
        XCTAssertFalse(controller.hasActiveProbe)
    }
}
#endif
