#if os(Linux)
import XCTest
@testable import TokenClock
final class NativeLocalBoundaryTests:XCTestCase {
    func testReplacedAndLinkedLogsCannotReuseCleanupIdentity() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("session.jsonl")
        try Data("first".utf8).write(to:file)
        let identity=try XCTUnwrap(NativeLocalFiles.identity(file))
        let moved=directory.appendingPathComponent("original.jsonl")
        try FileManager.default.moveItem(at:file,to:moved)
        try Data("first".utf8).write(to:file)
        XCTAssertNotEqual(NativeLocalFiles.identity(file),identity)
        let link=directory.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        XCTAssertNil(NativeLocalFiles.identity(link))
    }
    func testConfigCommentsDoNotEraseURLsOrAcceptMalformedStrings() throws {
        let text="{ /* config */ api_key:'synthetic-test', base_url:\"https://example.test/a//b\", values:[1,2,], }"
        let object=try XCTUnwrap(ConfigJSON.object(text) as? [String:Any])
        XCTAssertEqual(object["base_url"] as? String,"https://example.test/a//b")
        XCTAssertEqual(object["api_key"] as? String,"synthetic-test")
        XCTAssertNil(ConfigJSON.object("{key:'unterminated}"))
    }
}
#endif
