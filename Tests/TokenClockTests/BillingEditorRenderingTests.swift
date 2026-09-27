#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

final class BillingEditorRenderingTests: XCTestCase {
    @MainActor func testManualBillingEditorFitsAndRenders() throws {
        var account = SubscriptionAccountRecord(provider: .codex, accountID: "test", email: "example@example.com",
            note: "Main", detectedPlan: "pro", manualPlan: "Pro 20x", groups: [], refreshedAt: nil,
            source: "test", creditBalance: nil, hasUnlimitedCredits: false, resetCreditCount: 0)
        account.manualBilling = SubscriptionBillingInfo(date: Date(), cycle: .monthly, autoRenews: true, source: "manual", observedAt: Date())
        let root = SubscriptionAccountEditorView(account: account, onSave: { _,_,_ in }, onCancel: {})
        let view = NSHostingView(rootView: root.frame(width: 400, height: 620).background(Color.white).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0,y: 0,width: 400,height: 620)
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(view.fittingSize.height, 620)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds,to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png,properties: [:]))
        XCTAssertGreaterThan(data.count, 3000)
        if let path = ProcessInfo.processInfo.environment["TOKENCLOCK_BILLING_PREVIEW"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
