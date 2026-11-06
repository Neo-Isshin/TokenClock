#if os(Linux)
import XCTest
import Foundation
@testable import TokenClock

final class LinuxModelWorkerTests:XCTestCase {
    func testBundledWorkerStartsReadOnlyAndDoesNotSubmitJobs() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        var environment=ProcessInfo.processInfo.environment
        environment["TOKENCLOCK_MODEL_INTEGRITY_STATE_DIR"]=directory.path
        let configuration=try ModelIntegrityLauncher.defaultConfiguration(environment:environment)
        let launcher=ModelIntegrityLauncher(configurationProvider:{configuration})
        defer{launcher.stop()}
        let ready:URL=try await withCheckedThrowingContinuation{continuation in
            launcher.start{continuation.resume(with:$0)}
        }
        let transport=NetworkDiagnosticFetcher(maximumBodyBytes:1_048_576)
        defer{transport.cancel()}
        let info=await transport.fetch(ready.appendingPathComponent("api/info"))
        XCTAssertEqual(info.status,200)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with:info.data) as? [String:Any])
        let jobs=await transport.fetch(ready.appendingPathComponent("api/jobs"))
        XCTAssertEqual(jobs.status,200)
        let value=try JSONSerialization.jsonObject(with:jobs.data)
        if let list=value as? [Any]{XCTAssertTrue(list.isEmpty)}
        else if let root=value as? [String:Any],let list=root["jobs"] as? [Any]{XCTAssertTrue(list.isEmpty)}
        else{XCTFail("The idle local worker must expose an empty job list")}
    }
}
#endif
