#if os(Windows)
import Foundation
import XCTest
@testable import TokenClock

final class WindowsNativeHTTPTests: XCTestCase {
    func testSharedWeatherParserRetainsCurrentAndHourlyFields() throws {
        let fixture = Data(#"{"current_condition":[{"temp_C":"21","weatherCode":"113"}],"nearest_area":[{"areaName":[{"value":"Seattle"}]}],"weather":[{"hourly":[{"time":"000","tempC":"18","weatherCode":"116","weatherDesc":[{"value":"Partly cloudy"}]},{"time":"300","tempC":"17","weatherCode":"296","weatherDesc":[{"value":"Light rain"}]}]}]}"#.utf8)

        let info = WeatherService.parseJSON(data: fixture, fallbackCity: "")
        XCTAssertEqual(info.temperature, 21)
        XCTAssertEqual(info.emoji, "☀️")
        XCTAssertEqual(info.cityName, "Seattle")
        XCTAssertEqual(info.forecast.count, 2)
        XCTAssertEqual(info.forecast[0].emoji, "⛅")
        XCTAssertEqual(info.forecast[1].emoji, "🌧️")
        XCTAssertEqual(info.forecast[1].description, "Light rain")
    }

    func testNativeClientRejectsHeaderInjectionBeforeNetwork() {
        XCTAssertThrowsError(try WindowsNativeHTTP.request(
            url: "http://127.0.0.1:1/",
            headers: ["X-Test": "safe\r\nCookie: injected"],
            connectTimeout: 0.1,
            sendTimeout: 0.1,
            receiveTimeout: 0.1,
            maximumResponseBytes: 32
        ))
    }

    func testCursorCloudFetchOffGate() {
        let key = SettingsKey.cursorCloudFetchEnabled.rawValue
        let saved = WindowsPreferences.shared.object(forKey: key)
        defer { WindowsPreferences.shared.set(saved, forKey: key) }

        UserDefaults.standard.setBool(false, for: .cursorCloudFetchEnabled)
        XCTAssertFalse(CursorAgentUsageService.cloudFetchEnabled)
        UserDefaults.standard.setBool(true, for: .cursorCloudFetchEnabled)
        XCTAssertTrue(CursorAgentUsageService.cloudFetchEnabled)
    }

    func testNativeHTTPSIntegrationWhenConfigured() throws {
        guard let url = ProcessInfo.processInfo.environment["TOKENCLOCK_NATIVE_HTTP_TEST_URL"],
              !url.isEmpty else {
            throw XCTSkip("Set TOKENCLOCK_NATIVE_HTTP_TEST_URL for WinHTTP integration")
        }
        let response = try WindowsNativeHTTP.request(
            url: url,
            headers: ["Accept": "application/json, text/plain;q=0.9"],
            connectTimeout: 10,
            sendTimeout: 10,
            receiveTimeout: 20,
            maximumResponseBytes: 2 * 1024 * 1024
        )
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(response.body.isEmpty)
        if url.localizedCaseInsensitiveContains("wttr.in") {
            let info = WeatherService.parseJSON(data: response.body, fallbackCity: "")
            XCTAssertFalse(info.cityName.isEmpty)
            XCTAssertFalse(info.forecast.isEmpty)
        }
    }
}
#endif
