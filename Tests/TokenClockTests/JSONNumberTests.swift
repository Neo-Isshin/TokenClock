import XCTest
@testable import TokenClock
final class JSONNumberTests: XCTestCase {
    func testNativeJSONBooleansNeverMasqueradeAsZeroOrOne() throws {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data("{\"yes\":true,\"no\":false,\"one\":1,\"zero\":0,\"fraction\":0.1}".utf8)) as? [String:Any])
        for key in ["yes","no"] { XCTAssertTrue(JSONNumber.isBoolean(try XCTUnwrap(root[key] as? NSNumber))) }
        for key in ["one","zero","fraction"] { XCTAssertFalse(JSONNumber.isBoolean(try XCTUnwrap(root[key] as? NSNumber))) }
    }
}
