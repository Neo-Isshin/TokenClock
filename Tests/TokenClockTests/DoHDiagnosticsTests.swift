#if os(macOS)
import XCTest
@testable import TokenClock
final class DoHDiagnosticsTests: XCTestCase {
    func testOnlyValidMatchingDnsResponsesCountAsDoH() {
        var reply=DoHWire.query("d0.fixture.example");reply[2]=0x81;reply[3]=0x83
        let valid=NetworkDiagnosticReply(data:reply,status:200,limited:false,mime:"application/dns-message")
        XCTAssertTrue(DoHDiagnostics.verified(valid,name:"d0.fixture.example"))
        XCTAssertFalse(DoHDiagnostics.verified(valid,name:"d1.fixture.example"))
        XCTAssertFalse(DoHDiagnostics.verified(.init(data:Data("<html>ok</html>".utf8),status:200,limited:false,mime:"text/html"),name:"d0.fixture.example"))
        reply[0]=1;XCTAssertNil(DoHWire.response(reply,question:"d0.fixture.example"))
        let request=DoHDiagnostics.request("https://dns.google/dns-query",name:"test.example")
        XCTAssertEqual(request.httpMethod,"POST");XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"),"application/dns-message")
    }
    func testCompressedWhoamiAnswerIsNotConfusedWithResolverAddress() {
        let name="whoami.cloudflare";var wire=DoHWire.query(name,type:16,qclass:3)
        wire[2]=0x81;wire[3]=0x80;wire[7]=1
        let text=Array("8.8.8.8".utf8)
        wire.append(contentsOf:[192,12,0,16,0,3,0,0,0,0,0,UInt8(text.count+1),UInt8(text.count)]+text)
        XCTAssertEqual(DoHWire.response(wire,question:name,type:16,qclass:3)?.addresses,["8.8.8.8"])
        XCTAssertNil(DoHWire.response(wire,question:"o-o.myaddr.l.google.com",type:16))
    }
    func testConfigurationSnapshotDoesNotExposePrivateEndpointIdentifiers() {
        let value=BrowserDoHConfiguration.values(["dns_over_https":["mode":"secure","templates":"https://dns.example/private-id?token=secret{?dns}"]])
        XCTAssertEqual(value?.0,"secure");XCTAssertEqual(value?.1,"dns.example")
        XCTAssertNil(BrowserDoHConfiguration.values([:]))
    }
    func testTTFTIsSeparateAndOnlyAggregatesActualFirstTokenEvidence() {
        var speed=GenerationSpeed()
        speed.include(.init(id:"a",model:"model",completedAt:Date(),outputTokens:100,seconds:2,estimated:false,firstTokenDelay:0.2))
        speed.include(.init(id:"b",model:"model",completedAt:Date(),outputTokens:100,seconds:2,estimated:false))
        XCTAssertEqual(speed.tokensPerSecond,50)
        XCTAssertEqual(speed.timeToFirstToken,0.2)
        XCTAssertEqual(speed.firstTokenDelayCount,1)
        XCTAssertEqual(GenerationSpeed().formattedTTFT,"—")
        speed.include(.init(id:"c",model:"model",completedAt:Date(),outputTokens:100,seconds:2,estimated:false,firstTokenDelay:-1))
        XCTAssertEqual(speed.firstTokenDelayCount,1)
    }
}
#endif
