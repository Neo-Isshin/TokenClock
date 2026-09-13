#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TokenClock

final class DetailShareLayoutTests: XCTestCase {
    @MainActor
    func testForecastShareOverlayRendersInsideFixedDetailPanel() throws {
        let weather = WeatherInfo(
            emoji: "☀️", temperature: 23, cityName: "Los Angeles",
            forecast: [
                HourlyForecast(time: "03:00", tempC: 23, emoji: "☀️", description: "Sunny"),
                HourlyForecast(time: "06:00", tempC: 22, emoji: "☀️", description: "Sunny"),
                HourlyForecast(time: "09:00", tempC: 24, emoji: "☀️", description: "Sunny"),
                HourlyForecast(time: "12:00", tempC: 28, emoji: "☀️", description: "Sunny"),
            ]
        )
        let size = NSSize(width: 320, height: 547)
        let view = NSHostingView(rootView: DetailDropdownView(
            tools: [], weather: weather, localizedCityName: "Los Angeles",
            onShareUsage: {}
        ))
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 1_094,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(bitmap.pixelsWide, 640)
        XCTAssertEqual(bitmap.pixelsHigh, 1_094)
        if let path = ProcessInfo.processInfo.environment["TOKENCLOCK_DETAIL_SHARE_PREVIEW_PATH"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
#endif
