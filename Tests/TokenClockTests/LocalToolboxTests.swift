#if os(macOS)
import XCTest
@testable import TokenClock

final class LocalToolboxTests: XCTestCase {
    func testProviderKeysStayWithTheirOwnEndpointsAndAreMasked() {
        let open="sk-fixture-openai-0123456789",anth="sk-fixture-anthro-0123456789"
        let text="""
        {"env":{"OPENAI_API_KEY":"\(open)","ANTHROPIC_API_KEY":"\(anth)","OPENAI_BASE_URL":"https://open.example/v1","ANTHROPIC_BASE_URL":"https://anth.example/v1"}}
        """
        let values=LocalConfigReader.credentials(text:text,source:"fixture",label:"Claude Code")
        XCTAssertEqual(values.first{$0.key==open}?.base,"https://open.example/v1")
        XCTAssertEqual(values.first{$0.key==anth}?.base,"https://anth.example/v1")
        XCTAssertTrue(values.allSatisfy{!$0.masked.contains($0.key)})
        let claw="{\"models\":{\"providers\":{\"custom\":{\"api\":\"anthropic-messages\",\"baseUrl\":\"https://proxy.example/v1\",\"apiKey\":\"fixture-0123456789abcd\"}}}}"
        let custom=LocalConfigReader.credentials(text:claw,source:"fixture",label:"OpenClaw")
        XCTAssertEqual(custom.first?.base,"https://proxy.example/v1");XCTAssertEqual(custom.first?.provider,"anthropic")
        let auth="""
        {"anthropic":{"type":"api","key":"\(anth)"},"openai":{"type":"oauth","refresh":"private-oauth-session"}}
        """
        let parsed=LocalConfigReader.credentials(text:auth,source:"auth.json",label:"OpenCode")
        XCTAssertEqual(parsed.count,1);XCTAssertEqual(parsed[0].provider,"anthropic")
    }
    func testReferencesAndTomlSelectionNeverExecuteShellOrGuessProviders() {
        let config="""
        model_provider="custom"
        model="fixture-model"
        [model_providers.custom]
        base_url="https://configured.example/v1"
        env_key="MY_FIXTURE_KEY"
        wire_api="responses"
        """
        let entries=LocalConfigReader.credentials(text:config,source:"config.toml",label:"Codex",environment:["MY_FIXTURE_KEY":"fixture-key-0123456789"])
        XCTAssertEqual(entries.count,1);XCTAssertEqual(entries[0].provider,"responses")
        XCTAssertEqual(entries[0].base,"https://configured.example/v1")
        XCTAssertTrue(LocalConfigReader.credentials(text:"{\"apiKey\":\"${MISSING}\"}",source:"fixture",label:"Claude Code",environment:[:]).isEmpty)
        XCTAssertTrue(LocalConfigReader.credentials(text:"{\"apiKey\":\"long-fixture-key-012345\"}",source:"fixture",label:"Unknown").isEmpty)
        XCTAssertTrue(LocalConfigReader.credentials(text:"OPENAI_API_KEY='fixture-key-012345'\nOPENAI_BASE_URL='https://user:password@public.example/v1'",source:"fixture",label:"Shell").isEmpty)
    }
    func testYamlModelEntriesStayPaired() {
        let yaml="""
        models:
          - provider: openai
            model: fixture-model
            apiBase: https://yaml.example/v1
            apiKey: ${FIXTURE_KEY}
        """
        let keys=LocalConfigReader.credentials(text:yaml,source:"config.yaml",label:"Continue",environment:["FIXTURE_KEY":"fixture-key-0123456789"])
        XCTAssertEqual(keys.count,1);XCTAssertEqual(keys.first?.base,"https://yaml.example/v1");XCTAssertEqual(keys.first?.model,"fixture-model")
    }
    func testErrorsPreserveBillingRegionPermissionAndRateLimitDistinctions() {
        XCTAssertTrue(LocalConfigReader.classify(status:401,body:Data()).contains("❌"))
        XCTAssertTrue(LocalConfigReader.classify(status:429,body:Data("{\"code\":\"insufficient_quota\"}".utf8)).contains("💸"))
        XCTAssertTrue(LocalConfigReader.classify(status:403,body:Data("unsupported_country_region_territory".utf8)).contains("🌍"))
        XCTAssertFalse(LocalConfigReader.classify(status:429,body:Data()).contains("❌"))
        XCTAssertFalse(LocalConfigReader.classify(status:403,body:Data()).contains("❌"))
    }
    func testLogScanRedactsMatchesAndChangedFilesCannotBeTrashed() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let key="sk-fixture-secret-0123456789012345",file=root.appendingPathComponent("old.jsonl")
        try "hello\n\(key)\n".write(to:file,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-40*86400)],ofItemAtPath:file.path)
        let (files,_)=LocalLogScanner.inventory(roots:[.init(name:"Fixture",path:root.path)],cancelled:{false})
        XCTAssertEqual(files.count,1);XCTAssertTrue(files[0].eligible)
        let found=LocalLogScanner.leaks(files:files,pattern:"",cancelled:{false})
        XCTAssertEqual(found.count,1);XCTAssertTrue(found[0].title.contains("2"))
        XCTAssertFalse(found[0].detail.contains(key))
        try "changed".write(to:file,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try LocalLogScanner.recycle(files[0]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:file.path))
    }
    func testAPIHeadersAndSingleOutputTokenFallback() async throws {
        ProbeFixtureProtocol.state.clear()
        func transport()->NetworkDiagnosticFetcher {let c=URLSessionConfiguration.ephemeral;c.protocolClasses=[ProbeFixtureProtocol.self];return NetworkDiagnosticFetcher(configuration:c)}
        let secret="fixture-key-0123456789abcdef"
        let result=await LocalConfigReader.probe(.init(source:"fixture",provider:"anthropic",key:secret,base:"https://probe-fixture.invalid/v1",model:"fixture-model"),transport:transport())
        XCTAssertFalse(result.masked.contains(secret));XCTAssertTrue(result.status.contains("1-token"))
        let requests=ProbeFixtureProtocol.state.snapshot()
        XCTAssertEqual(requests.count,2);XCTAssertEqual(requests[0].httpMethod,"GET");XCTAssertEqual(requests[1].url?.path,"/v1/messages")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField:"x-api-key"),secret)
        XCTAssertNil(requests[1].value(forHTTPHeaderField:"Cookie"))
        let body=try XCTUnwrap(try JSONSerialization.jsonObject(with:try XCTUnwrap(requests[1].httpBody)) as? [String:Any])
        XCTAssertEqual(body["max_tokens"] as? Int,1)
        _=await LocalConfigReader.probe(.init(source:"fixture",provider:"openai",key:secret,base:"https://probe-fixture.invalid/invalid",model:"fixture-model"),transport:transport())
        XCTAssertEqual(ProbeFixtureProtocol.state.snapshot().count,3,"An invalid key must not trigger inference")
    }
    func testNTPResponseMustEchoOurRequestAndUseServerMode() {
        let sent=Date(timeIntervalSince1970:1700000000),received=sent.addingTimeInterval(0.1)
        let request=NTPClockCheck.packet(at:sent);var reply=NTPClockCheck.packet(at:sent.addingTimeInterval(0.06))
        reply[0]=0x24;reply[1]=2;reply.replaceSubrange(24..<32,with:request[40..<48]);reply.replaceSubrange(32..<40,with:reply[40..<48])
        XCTAssertEqual(NTPClockCheck.offset(reply:reply,request:request,sent:sent,received:received)!,0.01,accuracy:0.000001)
        reply[24]^=1;XCTAssertNil(NTPClockCheck.offset(reply:reply,request:request,sent:sent,received:received))
    }
}
private final class ProbeFixtureProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        let lock=NSLock();private var requests:[URLRequest]=[]
        func add(_ r:URLRequest){lock.lock();requests.append(r);lock.unlock()}
        func snapshot()->[URLRequest]{lock.lock();defer{lock.unlock()};return requests}
        func clear(){lock.lock();requests=[];lock.unlock()}
    }
    static let state=State()
    override class func canInit(with request:URLRequest)->Bool {request.url?.host=="probe-fixture.invalid"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading(){
        var captured=request
        if captured.httpBody == nil,let stream=request.httpBodyStream {
            stream.open();defer{stream.close()};var bytes=[UInt8](repeating:0,count:2048);let n=stream.read(&bytes,maxLength:2048);if n>0{captured.httpBody=Data(bytes.prefix(n))}
        }
        Self.state.add(captured)
        let status=request.url!.path.contains("invalid") ? 401 : request.httpMethod=="POST" ? 200 : 404
        let data=Data("{}".utf8)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Length":"2"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading(){}
}
#endif
