import Foundation
import XCTest
@testable import TokenClock

final class IPGeolocationTests: XCTestCase {
    func testParsesPublicIPFromIPIPResponse() {
        let data = Data("当前 IP：24.249.245.242  来自于：美国 加利福尼亚州 欧文".utf8)
        XCTAssertEqual(IPGeolocation.publicIP(from: data), "24.249.245.242")
    }

    func testDecodesStructuredLocation() throws {
        let data = Data(#"{"success":true,"city":"Irvine","latitude":33.6846,"longitude":-117.8265}"#.utf8)
        XCTAssertEqual(
            IPGeolocation.location(from: data),
            IPWeatherLocation(city: "Irvine", latitude: 33.6846, longitude: -117.8265)
        )
    }

    func testBuildsLocalizedExplicitIPEndpoint() throws {
        let url = try XCTUnwrap(IPGeolocation.endpoint(publicIP: "24.249.245.242", language: .en))
        XCTAssertEqual(url.host, "ipwho.is")
        XCTAssertEqual(url.path, "/24.249.245.242")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "en")
    }
}
