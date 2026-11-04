import Foundation
import XCTest
@testable import TokenClock
final class DSHUsageTests:XCTestCase {
    func testDisjointCacheAccountingAndLatestUsagePerAttempt() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let path=directory.appendingPathComponent("session.v4.jsonl")
        let time=Date().timeIntervalSince1970*1000
        let rows:[[String:Any]]=[
            ["type":"session","version":4,"id":"session","createdAt":time,"isSeeded":false,"delegationDepth":0],
            ["type":"request/header","seq":0,"time":time,"data":["turn":0,"step":0,"header":["model":"deepseek-v4-pro"]]],
            ["type":"assistant/attempt","seq":1,"time":time,"data":["turn":0,"step":0,"stream":[["type":"chunk","time":time,"chunk":["type":"usage","usage":["inputTokens":10,"outputTokens":2,"cacheReadTokens":3]]]]]],
            ["type":"assistant/message","seq":2,"time":time,"data":["turn":0,"step":0,"message":["source":["model":"deepseek-v4-pro","provider":"deepseek","kind":"model"]],"usage":["inputTokens":20,"outputTokens":4,"cacheReadTokens":5]]],
            ["type":"llm/retry-started","seq":3,"time":time,"data":["turn":0,"step":0]],
            ["type":"assistant/attempt","seq":4,"time":time,"data":["turn":0,"step":0,"stream":[["type":"chunk","time":time,"chunk":["type":"usage","usage":["inputTokens":5,"outputTokens":1,"cacheReadTokens":2]]]]]]]
        let data=try rows.map{String(decoding:try JSONSerialization.data(withJSONObject:$0),as:UTF8.self)}.joined(separator:"\n")+"\n"
        try data.write(to:path,atomically:true,encoding:.utf8)
        let result=try XCTUnwrap(DSHReceiptReader.read(path.path))
        XCTAssertEqual(result.count,2);XCTAssertEqual(result.reduce(0){$0+$1.buckets.input},25);XCTAssertEqual(result.reduce(0){$0+$1.buckets.cacheRead},7)
        let service=HarnessUsageService(.dsh,roots:[directory.path]);service.fullScan();XCTAssertEqual(service.todayUsage().tokens,30)
        let previous=directory.appendingPathComponent("session.v3.jsonl");try data.write(to:previous,atomically:true,encoding:.utf8)
        XCTAssertEqual(HarnessUsageService.sourceFiles(roots:[directory.path],harness:.dsh),[path.path])
        XCTAssertEqual(DSHReceiptReader.buckets(["inputTokens":10,"outputTokens":2,"cacheReadTokens":20])?.input,10)
        XCTAssertNil(DSHReceiptReader.buckets(["inputTokens":true,"outputTokens":2]))
        let newer=directory.appendingPathComponent("session.v5.jsonl");try data.replacingOccurrences(of:"\"version\":4",with:"\"version\":5").write(to:newer,atomically:true,encoding:.utf8)
        service.incrementalScan();XCTAssertEqual(service.todayUsage().tokens,30,"Unknown generations retain a prior good snapshot")
    }
#if os(macOS)
    func testBundledZstdDecoderAndTruncatedFrames() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let data=Data(base64Encoded:"KLUv/WAkAN0FAHILIx5gaaoDoIi2hFqy9k+NS20D3ATRgslifnrAhILAcDyG996BjgmcgBykWATSrWIJSKDplRXLIB1TyRXLe12NHQ7GQWGf2WhhtJI2kObWmfOquWwDTU8eVCyIgUSSslgQaKrgG+H8TgBSnXz6j+H5i3NgZBc8If9uLFkISsVyoGlmFEvVSr9fNDVbyDYCEQBNFd9N3litJrIwRwgtGsIJBLhkwqm88B3mYD9Vu5iwpqeZogwJZRy3ZQw=")!
        let path=directory.appendingPathComponent("session.v4.jsonl.zstd");try data.write(to:path)
        let result=try XCTUnwrap(DSHReceiptReader.read(path.path));XCTAssertEqual(result.count,1);XCTAssertEqual(result.first?.buckets.input,12)
        let second=Data(base64Encoded:"KLUv/SCPNQMAEsYTGJCpOV0LiTzatn8RDTSbETJLjKpYur4UuMZaS3CFuGVQcyJEIIWrhI5K+KwZKdSd1Hw/g1sCBHOcu8XUnMB0i/FwmXgAju55Ms81Y1rcSQcAbTIPNWBCu1k5eXMFHDgqVukB")!
        try (data+second).write(to:path)
        XCTAssertEqual(DSHReceiptReader.read(path.path)?.count,2)
        try data.dropLast(3).write(to:path);XCTAssertNil(DSHReceiptReader.read(path.path))
    }
#endif
    func testSeedReplayAndCustomPiSessionDirectory() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let lines=["{\"type\":\"session\",\"version\":4,\"id\":\"child\",\"isSeeded\":true}",
            "{\"type\":\"assistant/message\",\"seq\":0,\"time\":1800000000000,\"data\":{\"turn\":0,\"step\":0,\"usage\":{\"inputTokens\":100,\"outputTokens\":10}}}",
            "{\"type\":\"session/end-seed\",\"seq\":1,\"time\":1800000000000,\"data\":{\"inherited\":true}}",
            "{\"type\":\"assistant/message\",\"seq\":2,\"time\":1800000000000,\"data\":{\"turn\":1,\"step\":0,\"usage\":{\"inputTokens\":3,\"outputTokens\":2}}}"]
        let path=root.appendingPathComponent("session.v4.jsonl");try (lines.joined(separator:"\n")+"\n").write(to:path,atomically:true,encoding:.utf8)
        XCTAssertEqual(DSHReceiptReader.read(path.path)?.map(\.buckets.input),[3])
        XCTAssertEqual(AdditionalHarness.pi.roots(home:"/fixture",environment:["PI_CODING_AGENT_SESSION_DIR":"/custom/sessions"],includeCustom:false),["/custom/sessions"])
        XCTAssertEqual(AdditionalHarness.pig.roots(home:"/fixture",environment:[:],includeCustom:false),["/fixture/.pig/agent"])
    }
}
