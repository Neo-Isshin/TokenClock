#if os(Linux)
import XCTest
import CGtk
@testable import TokenClock

final class LinuxBrandIconRenderingTests: XCTestCase {
    func testEveryBundledIconDecodesInNativeRenderer() throws {
        let keys = Set(BrandIconCatalog.tools.values).union(BrandIconCatalog.modelFamilies.map(\.1))
        for key in keys {
            let url = try XCTUnwrap(BrandIconCatalog.url(forKey: key))
            XCTAssertNotNil(tc_brand_icon_pixbuf(url.path), key)
        }
    }
}
#endif
