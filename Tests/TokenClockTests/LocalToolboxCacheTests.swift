#if os(macOS)
import XCTest
@testable import TokenClock

final class LocalToolboxCacheTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ToolboxTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:url, withIntermediateDirectories:true)
        return url
    }
    private func logs(_ directory: URL) -> [LocalLogFile] {
        LocalLogScanner.inventory(roots:[.init(name:"Test",path:directory.path)],cancelled:{false}).0
    }
    func testIncrementalReusesUnchangedRescansChangedTruncatedAndRules() throws {
        let directory = try fixture(); defer {try? FileManager.default.removeItem(at:directory)}
        let file = directory.appendingPathComponent("session.jsonl"), cache = directory.appendingPathComponent("cache.data")
        let secret = "sk-" + String(repeating:"q",count:24)
        try (secret+"\n").write(to:file,atomically:true,encoding:.utf8)
        let first = LocalSecretCache.scan(files:logs(directory),pattern:"",full:false,url:cache,cancelled:{false})
        XCTAssertEqual(first.scanned,1);XCTAssertEqual(first.findings.count,1)
        let second = LocalSecretCache.scan(files:logs(directory),pattern:"",full:false,url:cache,cancelled:{false})
        XCTAssertEqual(second.reused,1);XCTAssertEqual(second.scanned,0);XCTAssertEqual(second.findings.count,1)
        XCTAssertFalse(String(decoding:try Data(contentsOf:cache),as:UTF8.self).contains(secret))
        try "clean\n".write(to:file,atomically:true,encoding:.utf8)
        let changed = LocalSecretCache.scan(files:logs(directory),pattern:"",full:false,url:cache,cancelled:{false})
        XCTAssertEqual(changed.scanned,1);XCTAssertTrue(changed.findings.isEmpty)
        let rules = LocalSecretCache.scan(files:logs(directory),pattern:"clean",full:false,url:cache,cancelled:{false})
        XCTAssertEqual(rules.scanned,1);XCTAssertEqual(rules.findings.count,1)
        let full = LocalSecretCache.scan(files:logs(directory),pattern:"clean",full:true,url:cache,cancelled:{false})
        XCTAssertEqual(full.scanned,1);XCTAssertEqual(full.reused,0)
        try FileManager.default.removeItem(at:file)
        _ = LocalSecretCache.scan(files:[],pattern:"clean",full:false,url:cache,cancelled:{false})
        let saved = try JSONDecoder().decode(LocalSecretCache.Cache.self,from:Data(contentsOf:cache))
        XCTAssertTrue(saved.records.isEmpty)
    }
    func testCancellationKeepsPreviousCacheAndPrivateSnapshotsContainOnlyMaskedKeys() throws {
        let directory = try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let cache = directory.appendingPathComponent("cache.data")
        try Data("previous".utf8).write(to:cache)
        _ = LocalSecretCache.scan(files:[],pattern:"",full:true,url:cache,cancelled:{true})
        XCTAssertEqual(try String(contentsOf:cache),"previous")
        let result = LocalToolboxResults(selectedMode:"keys",snapshots:["keys":.init(checkedAt:Date(),findings:[],files:[],keys:[.init(source:"config",endpoint:"https://example.test/v1/models",masked:"sk-q••••qqqq",status:"Valid")])])
        try LocalToolboxPersistence.save(result,to:cache)
        let saved = try JSONDecoder().decode(LocalToolboxResults.self,from:Data(contentsOf:cache))
        XCTAssertEqual(saved.snapshots["keys"]?.keys.first?.masked,"sk-q••••qqqq")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:cache.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    @MainActor func testReopenRestoresResultsAndCancellationDoesNotClearThem() throws {
        let directory = try fixture();defer {try? FileManager.default.removeItem(at:directory)}
        let date = Date(timeIntervalSince1970:1000)
        try LocalToolboxPersistence.save(LocalToolboxResults(selectedMode:"secrets",snapshots:["secrets":.init(checkedAt:date,findings:[.init(title:"Saved",detail:"Masked")],files:[],keys:[])]),to:directory.appendingPathComponent("local-toolbox-results.json"))
        let model = LocalToolboxModel(directory:directory)
        XCTAssertEqual(model.selectedMode,"secrets");XCTAssertEqual(model.checkedAt,date)
        model.run("secrets");model.stop()
        XCTAssertEqual(model.findings.first?.title,"Saved");XCTAssertEqual(model.checkedAt,date)
        model.selectMode("disk");XCTAssertNil(model.checkedAt)
        model.selectMode("secrets");XCTAssertEqual(model.findings.first?.title,"Saved")
    }
}
#endif
