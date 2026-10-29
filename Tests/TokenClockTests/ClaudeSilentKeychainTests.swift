#if os(macOS)
import XCTest
@testable import TokenClock

final class ClaudeSilentKeychainTests: XCTestCase {
    private func withHelper(_ body: String, test: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("TokenClock")
        try ("#!/bin/sh\n" + body).write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try test(executable, directory)
    }

    func testSuccessfulSilentReadUsesOnlyTheHelperAndKeepsCredentialInMemory() throws {
        try withHelper("""
        [ "$1" = '--tokenclock-silent-keychain' ] || exit 1
        [ "$2" = 'Claude Code-credentials' ] || exit 1
        [ "$3" = 'fixture-user' ] || exit 1
        printf 'synthetic-credential'
        """) { executable, _ in
            XCTAssertEqual(ClaudeSilentKeychain.read(service: "Claude Code-credentials", account: "fixture-user",
                executable: executable), Data("synthetic-credential".utf8))
        }
    }

    func testDeniedCredentialDoesNotRetryOrUseInteractiveFallback() throws {
        try withHelper("""
        printf x >> "$(dirname "$0")/calls"
        printf 'partial-credential-must-not-be-used'
        exit 1
        """) { executable, directory in
            for _ in 0..<3 {
                XCTAssertNil(ClaudeSilentKeychain.read(service: "Claude Code-credentials", executable: executable))
            }
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8), "xxx")
        }
    }

    func testUnresponsiveHelperIsBoundedWithoutInteractiveRecovery() throws {
        try withHelper("exec /bin/sleep 10\n") { executable, _ in
            let start = Date()
            XCTAssertNil(ClaudeSilentKeychain.read(service: "Claude Safe Storage", executable: executable))
            XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        }
    }

    func testInvalidRequestsCannotEnterKeychainReadMode() {
        for arguments in [[], [ClaudeSilentKeychain.helperArgument],
                          [ClaudeSilentKeychain.helperArgument, "unrelated-service"],
                          [ClaudeSilentKeychain.helperArgument, "Claude Code-credentials", "user", "extra"]] {
            XCTAssertEqual(ClaudeSilentKeychain.runHelper(arguments: arguments), 1)
        }
        let services = ClaudeQuotaService.macOSKeychainServices(environment: ["CLAUDE_CONFIG_DIR": "/fixture",
            "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://fixture.invalid"], configuredClaudeHome: "/fixture")
        XCTAssertTrue(services.allSatisfy { ClaudeSilentKeychain.accepts(service: $0) })
        XCTAssertTrue(ClaudeSilentKeychain.accepts(service: "Claude Safe Storage"))
        XCTAssertTrue(ClaudeSilentKeychain.accepts(service: "cursor-access-token"))
    }

    func testHelperCannotExportCredentialsToAnUnrelatedParentProcess() {
        // XCTest's parent is not a signed TokenClock instance. The request must
        // fail before touching either the credential or the process-wide UI flag.
        XCTAssertEqual(ClaudeSilentKeychain.runHelper(arguments: [ClaudeSilentKeychain.helperArgument,
            "Claude Code-credentials", "fixture-user"]), 1)
    }
}
#endif
