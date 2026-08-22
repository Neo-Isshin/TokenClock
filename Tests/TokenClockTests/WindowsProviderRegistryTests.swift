#if os(Windows)
import Foundation
import XCTest
@testable import TokenClock

final class WindowsProviderRegistryTests: XCTestCase {
    func testRegistryRetainsExistingFourteenProvidersAndAddsScopedProviders() throws {
        let entries = WindowsProviderCatalog.orderedEntries
        XCTAssertEqual(entries.count, 16)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        XCTAssertEqual(Set(entries.map(\.displayName)).count, entries.count)

        let legacyNames: Set<String> = [
            "OpenClaw", "Claude Code", "Gemini CLI", "Codex", "Hermes", "OpenCode",
            "Qwen Code", "Copilot", "Grok", "Aider", "Antigravity", "Cline",
            "Continue", "Cursor Agent",
        ]
        XCTAssertTrue(legacyNames.isSubset(of: Set(entries.map(\.displayName))))
        for name in legacyNames {
            let entry = try XCTUnwrap(WindowsProviderCatalog.entry(displayName: name))
            XCTAssertEqual(entry.measurementUnit, .tokens)
            XCTAssertEqual(entry.measurementScope, .today)
            XCTAssertEqual(entry.statisticsSupport, .parsed)
            XCTAssertTrue(entry.defaultEnabled)
        }

        let kiro = WindowsProviderCatalog.entry(.kiro)
        XCTAssertEqual(kiro.measurementUnit, .requests)
        XCTAssertEqual(kiro.measurementScope, .contractOnly)
        XCTAssertEqual(kiro.statisticsSupport, .contractOnly)
        XCTAssertFalse(kiro.defaultEnabled)

        let codeBuddy = WindowsProviderCatalog.entry(.codeBuddy)
        XCTAssertEqual(codeBuddy.measurementUnit, .tokens)
        XCTAssertEqual(codeBuddy.measurementScope, .currentSession)
        XCTAssertEqual(codeBuddy.statisticsSupport, .experimental)
        XCTAssertEqual(codeBuddy.sourceKind, .loopbackAPI)
        XCTAssertFalse(codeBuddy.defaultEnabled)
    }

    func testMissingSettingsPreferenceUsesOnlyDefaultEnabledProviders() {
        let defaults = WindowsProviderCatalog.enabledDisplayNames(saved: nil)
        XCTAssertEqual(defaults.count, 14)
        XCTAssertFalse(defaults.contains("Kiro CLI"))
        XCTAssertFalse(defaults.contains("CodeBuddy CLI"))
        XCTAssertEqual(WindowsProviderCatalog.enabledDisplayNames(saved: []), [])
        XCTAssertEqual(WindowsProviderCatalog.enabledDisplayNames(saved: ["Codex", "Unknown"]), ["Codex"])
    }

    func testCurrentSessionAndRequestValuesNeverEnterTodayTokenAggregates() {
        let today = usage(name: "today", unit: .tokens, scope: .today, todayTokens: 100)
        let currentSession = usage(name: "session", unit: .tokens, scope: .currentSession,
                                   todayTokens: 0, measurementValue: 900)
        let requests = usage(name: "requests", unit: .requests, scope: .contractOnly,
                             todayTokens: 0, measurementValue: 40)
        let credits = usage(name: "credits", unit: .credits, scope: .today,
                            todayTokens: 25, measurementValue: 25)

        XCTAssertEqual(UsageAggregator.totalTokens([today, currentSession, requests, credits]), 100)
        XCTAssertEqual(UsageAggregator.topToolsByTokens([currentSession, requests, credits, today]).map(\.name), ["today"])
        XCTAssertEqual(currentSession.value, 900)
        XCTAssertEqual(requests.value, 40)
    }

    func testCodeBuddyEndpointAllowsOnlyLiteralIPv4Loopback() {
        XCTAssertEqual(CodeBuddyStatsService.validatedLoopbackBaseURL("http://127.0.0.1:8080")?.absoluteString,
                       "http://127.0.0.1:8080")
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("http://localhost:8080"))
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("http://[::1]:8080"))
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("http://192.168.50.188:8080"))
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("https://127.0.0.1:8080"))
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("http://user:secret@127.0.0.1:8080"))
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("http://127.0.0.1:8080?password=secret"))
        XCTAssertNil(CodeBuddyStatsService.validatedLoopbackBaseURL("http://127.0.0.1:8080/api/v1/stats"))
    }

    func testCodeBuddyProbeRejectsRedirectWithoutRequestingTarget() throws {
        try withRawHTTPServer(mode: "redirect") { port, requestsURL in
            let service = CodeBuddyStatsService(endpoint: "http://127.0.0.1:\(port)")
            let probe = service.probe()
            XCTAssertFalse(probe.historicalEnvelopeReadable)
            XCTAssertFalse(probe.sessionStatisticsReadable)
            Thread.sleep(forTimeInterval: 0.1)
            let requests = (try? String(contentsOf: requestsURL, encoding: .utf8)) ?? ""
            XCTAssertFalse(requests.contains("/redirect-target"))
            XCTAssertEqual(requests.components(separatedBy: "GET ").count - 1, 2)
        }
    }

    func testCodeBuddyNativeTransportAcceptsOnlyCompleteSafeHTTP() throws {
        for mode in ["validLength", "safeEOF", "http10EOF", "duplicateLength"] {
            try withRawHTTPServer(mode: mode) { port, requestsURL in
                let snapshot = CodeBuddyStatsService(endpoint: "http://127.0.0.1:\(port)").currentSessionUsage()
                XCTAssertEqual(snapshot?.tokens, 0, "mode=\(mode)")
                let request = (try? String(contentsOf: requestsURL, encoding: .utf8)) ?? ""
                XCTAssertTrue(request.contains("GET /api/v1/stats/session HTTP/1.1"))
                XCTAssertTrue(request.contains("X-CodeBuddy-Request: 1"))
                XCTAssertFalse(request.localizedCaseInsensitiveContains("authorization:"))
                XCTAssertFalse(request.localizedCaseInsensitiveContains("cookie:"))
            }
        }
    }

    func testCodeBuddyNativeTransportRejectsUnsafeHTTPFraming() throws {
        for mode in ["auth", "chunked", "conflictingLength", "invalidLF", "truncated"] {
            try withRawHTTPServer(mode: mode) { port, _ in
                let snapshot = CodeBuddyStatsService(endpoint: "http://127.0.0.1:\(port)").currentSessionUsage()
                XCTAssertNil(snapshot, "mode=\(mode)")
            }
        }
    }

    func testCodeBuddyResponseBodyOverLimitFailsClosed() throws {
        for mode in ["oversizeLength", "oversizeEOF"] {
            try withRawHTTPServer(mode: mode) { port, _ in
                XCTAssertNil(CodeBuddyStatsService(endpoint: "http://127.0.0.1:\(port)").currentSessionUsage())
            }
        }
    }

    func testCodeBuddyNativeTransportUsesSingleEightHundredMillisecondDeadline() throws {
        try withRawHTTPServer(mode: "slow") { port, _ in
            let started = Date()
            XCTAssertNil(CodeBuddyStatsService(endpoint: "http://127.0.0.1:\(port)").currentSessionUsage())
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertGreaterThanOrEqual(elapsed, 0.65)
            XCTAssertLessThan(elapsed, 1.20)
        }
    }

    func testCodeBuddyOfficialServerIntegrationWhenConfigured() throws {
        guard let endpoint = ProcessInfo.processInfo.environment["CODEBUDDY_OFFICIAL_INTEGRATION_ENDPOINT"],
              !endpoint.isEmpty else {
            throw XCTSkip("Set CODEBUDDY_OFFICIAL_INTEGRATION_ENDPOINT for the official server integration test")
        }
        let defaults = UserDefaults.standard
        let keys: [SettingsKey] = [.enabledTools, .codeBuddyEndpoint, .hasRunInitialDetection]
        let saved = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, WindowsPreferences.shared.object(forKey: $0.rawValue))
        })
        defer {
            for key in keys {
                WindowsPreferences.shared.set(saved[key] ?? nil, forKey: key.rawValue)
            }
        }
        defaults.setStringArray(["CodeBuddy CLI"], for: .enabledTools)
        defaults.setString(endpoint, for: .codeBuddyEndpoint)
        defaults.setBool(true, for: .hasRunInitialDetection)

        // This is deliberately the first CodeBuddy request in the test process. The Windows model
        // and public API must expose a valid empty current session, not "unavailable".
        let model = WindowsUsageModel()
        XCTAssertTrue(model.scan(incremental: false))
        let api = model.usageJSONObject()
        let tools = try XCTUnwrap(api["tools"] as? [[String: Any]])
        let codeBuddy = try XCTUnwrap(tools.first { $0["name"] as? String == "CodeBuddy CLI" })
        XCTAssertEqual(codeBuddy["statisticsAvailable"] as? Bool, true)
        XCTAssertEqual(codeBuddy["statisticsStatus"] as? String, "experimental")
        XCTAssertEqual(codeBuddy["scope"] as? String, "currentSession")
        XCTAssertEqual(codeBuddy["value"] as? Int, 0)

        let service = CodeBuddyStatsService(endpoint: endpoint)
        let probe = service.probe()
        XCTAssertTrue(probe.historicalEnvelopeReadable)
        XCTAssertTrue(probe.sessionStatisticsReadable)
        let session = try XCTUnwrap(service.currentSessionUsage())
        XCTAssertEqual(session.tokens, 0)
    }

    func testCodeBuddyCurrentSessionDecoderAcceptsOnlyVerifiedOfficialShapes() throws {
        let fixture = Data(#"{"data":{"apiDuration":120,"runDuration":240,"tokenUsage":{"input":10,"output":5,"cacheRead":2,"cacheCreation":3},"fileChanges":1,"cost":0.01}}"#.utf8)
        let snapshot = try XCTUnwrap(CodeBuddyStatsService.decodeCurrentSessionUsage(fixture))
        XCTAssertEqual(snapshot.tokens, 18)
        XCTAssertEqual(snapshot.input, 10)
        XCTAssertEqual(snapshot.output, 5)
        XCTAssertEqual(snapshot.cacheRead, 2)
        XCTAssertEqual(snapshot.cacheCreation, 3)
        XCTAssertTrue(snapshot.modelTokens.isEmpty)

        let runtimeFixture = Data(#"{"data":{"startupTime":1,"apiDuration":2,"runningTime":3,"fileChangeStats":{"totalAddedLines":0},"tokenUsageByModel":{"claude-sonnet":{"inputTokens":11,"outputTokens":7,"cachedReadTokens":5,"cachedWriteTokens":3,"modelName":"Claude Sonnet"},"gpt-5":{"inputTokens":13,"outputTokens":9,"cachedReadTokens":4,"cachedWriteTokens":2,"modelName":"GPT-5"}}}}"#.utf8)
        let runtime = try XCTUnwrap(CodeBuddyStatsService.decodeCurrentSessionUsage(runtimeFixture))
        XCTAssertEqual(runtime.tokens, 45)
        XCTAssertEqual(runtime.modelTokens, ["claude-sonnet": 21, "gpt-5": 24])

        let emptyRuntime = Data(#"{"data":{"tokenUsageByModel":{}}}"#.utf8)
        XCTAssertEqual(CodeBuddyStatsService.decodeCurrentSessionUsage(emptyRuntime)?.tokens, 0)
        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"tokenUsageByModel":{"gpt-5":{"inputTokens":1,"outputTokens":2,"cachedReadTokens":3}}}}"#.utf8)))
        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"tokenUsageByModel":{"gpt-5":{"inputTokens":1.5,"outputTokens":2,"cachedReadTokens":3,"cachedWriteTokens":4}}}}"#.utf8)))
        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"tokenUsageByModel":{"gpt-5":{"inputTokens":9223372036854775807,"outputTokens":1,"cachedReadTokens":0,"cachedWriteTokens":0}}}}"#.utf8)))

        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"totalTokens":{"input":10,"output":5}}}"#.utf8)))
        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"tokenUsage":{"input":10,"output":5,"cacheRead":-1,"cacheCreation":0}}}"#.utf8)))
        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"tokenUsage":{"input":true,"output":5,"cacheRead":0,"cacheCreation":0}}}"#.utf8)))
        XCTAssertNil(CodeBuddyStatsService.decodeCurrentSessionUsage(Data(#"{"data":{"tokenUsage":{"input":1.5,"output":5,"cacheRead":0,"cacheCreation":0}}}"#.utf8)))
    }

    func testUsageAPIKeepsLegacyFieldsAndAddsUnitValueAndScope() {
        let tool = usage(name: "CodeBuddy CLI", unit: .tokens, scope: .currentSession,
                         todayTokens: 0, measurementValue: 900)
        let object = WindowsUsageModel.usageToolJSONObject(tool)
        XCTAssertEqual(object["todayTokens"] as? Int, 0)
        XCTAssertEqual(object["unit"] as? String, "tokens")
        XCTAssertEqual(object["value"] as? Int, 900)
        XCTAssertEqual(object["scope"] as? String, "currentSession")
        XCTAssertEqual(object["statisticsStatus"] as? String, "experimental")
        XCTAssertEqual(object["statisticsAvailable"] as? Bool, true)

        let kiro = usage(name: "Kiro CLI", unit: .requests, scope: .contractOnly,
                         todayTokens: 0)
        let kiroObject = WindowsUsageModel.usageToolJSONObject(kiro)
        XCTAssertEqual(kiroObject["statisticsStatus"] as? String, "contractOnly")
        XCTAssertEqual(kiroObject["statisticsAvailable"] as? Bool, false)

        let unavailableCodeBuddy = usage(name: "CodeBuddy CLI", unit: .tokens,
                                         scope: .currentSession, todayTokens: 0)
        let unavailableObject = WindowsUsageModel.usageToolJSONObject(unavailableCodeBuddy)
        XCTAssertEqual(unavailableObject["statisticsStatus"] as? String, "unavailable")
        XCTAssertEqual(unavailableObject["statisticsAvailable"] as? Bool, false)
    }

    func testKiroProbeRequiresDocumentedMetadataAndEventPair() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenClock-Kiro-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"id":"session-1","cwd":"C:\\work"}"#.utf8)
            .write(to: root.appendingPathComponent("session-1.json"))
        XCTAssertFalse(KiroSessionContractProbe.isReadable(at: root.path))
        try Data("{\"event\":\"opaque-official-event\"}\n".utf8)
            .write(to: root.appendingPathComponent("session-1.jsonl"))
        XCTAssertTrue(KiroSessionContractProbe.isReadable(at: root.path))

        try Data("not-json\n".utf8).write(to: root.appendingPathComponent("session-1.jsonl"))
        XCTAssertFalse(KiroSessionContractProbe.isReadable(at: root.path))
    }

    private func usage(
        name: String,
        unit: UsageMeasurementUnit,
        scope: UsageMeasurementScope,
        todayTokens: Int,
        measurementValue: Int? = nil
    ) -> ToolUsage {
        ToolUsage(
            name: name,
            abbreviation: name,
            emoji: "•",
            measurementUnit: unit,
            measurementScope: scope,
            measurementValue: measurementValue,
            todayTokens: todayTokens,
            todayMessages: 0,
            isActive: false,
            recentTokens: todayTokens,
            hourlyTokens: todayTokens
        )
    }

    private func withRawHTTPServer(
        mode: String,
        _ body: (Int, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokenClock-CodeBuddy-HTTP-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scriptURL = root.appendingPathComponent("server.ps1")
        let readyURL = root.appendingPathComponent("ready.txt")
        let requestsURL = root.appendingPathComponent("requests.txt")
        try Data(Self.rawHTTPServerScript.utf8).write(to: scriptURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
        process.arguments = [
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", scriptURL.path,
            "-ReadyPath", readyURL.path, "-RequestsPath", requestsURL.path, "-Mode", mode,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }
        let port = try waitForRawHTTPServerPort(at: readyURL, process: process)
        try body(port, requestsURL)
    }

    private func waitForRawHTTPServerPort(at readyURL: URL, process: Process) throws -> Int {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOf: readyURL, encoding: .utf8),
               let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return port
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw NSError(
            domain: "TokenClockTests.CodeBuddyHTTPServer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local raw HTTP server did not start"]
        )
    }

    private static let rawHTTPServerScript = #"""
param([string]$ReadyPath, [string]$RequestsPath, [string]$Mode)
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
[System.IO.File]::WriteAllText($ReadyPath, "$port")
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
            $requestLine = $reader.ReadLine()
            $headers = @()
            do { $header = $reader.ReadLine(); if ($header) { $headers += $header } } while ($null -ne $header -and $header.Length -gt 0)
            [System.IO.File]::AppendAllText($RequestsPath, $requestLine + "`n" + ($headers -join "`n") + "`n---`n")
            $body = '{"data":{"tokenUsageByModel":{}}}'
            $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            switch ($Mode) {
                'validLength' { $response = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: keep-alive`r`n`r`n" }
                'safeEOF' { $response = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nConnection: close`r`n`r`n" }
                'http10EOF' { $response = "HTTP/1.0 200 OK`r`nContent-Type: application/json`r`n`r`n" }
                'duplicateLength' { $response = "HTTP/1.1 200 OK`r`nContent-Length: $($bodyBytes.Length)`r`nContent-Length: $($bodyBytes.Length)`r`n`r`n" }
                'redirect' { $response = "HTTP/1.1 302 Found`r`nLocation: http://127.0.0.1:$port/redirect-target`r`nContent-Length: 0`r`n`r`n"; $bodyBytes = [byte[]]@() }
                'auth' { $response = "HTTP/1.1 401 Unauthorized`r`nWWW-Authenticate: Basic realm=test`r`nContent-Length: 0`r`n`r`n"; $bodyBytes = [byte[]]@() }
                'chunked' { $response = "HTTP/1.1 200 OK`r`nTransfer-Encoding: chunked`r`n`r`n"; $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes("$($bodyBytes.Length.ToString('x'))`r`n$body`r`n0`r`n`r`n") }
                'conflictingLength' { $response = "HTTP/1.1 200 OK`r`nContent-Length: $($bodyBytes.Length)`r`nContent-Length: 1`r`n`r`n" }
                'invalidLF' { $response = "HTTP/1.1 200 OK`nContent-Length: $($bodyBytes.Length)`n`n" }
                'truncated' { $response = "HTTP/1.1 200 OK`r`nContent-Length: $($bodyBytes.Length)`r`n`r`n"; $bodyBytes = $bodyBytes[0..4] }
                'oversizeLength' { $response = "HTTP/1.1 200 OK`r`nContent-Length: 1048577`r`n`r`n"; $bodyBytes = [byte[]]@() }
                'oversizeEOF' { $response = "HTTP/1.1 200 OK`r`nConnection: close`r`n`r`n"; $bodyBytes = $null }
                'slow' { Start-Sleep -Seconds 2; $response = "HTTP/1.1 200 OK`r`nContent-Length: $($bodyBytes.Length)`r`n`r`n" }
                default { throw "unknown mode" }
            }
            $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($response)
            $stream.Write($headerBytes, 0, $headerBytes.Length)
            if ($Mode -eq 'oversizeEOF') {
                $block = New-Object byte[] 65536
                for ($i = 0; $i -lt 16; $i++) { $stream.Write($block, 0, $block.Length) }
                $stream.WriteByte(0)
            } elseif ($null -ne $bodyBytes -and $bodyBytes.Length -gt 0) {
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
            }
            $stream.Flush()
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
"""#
}
#endif
