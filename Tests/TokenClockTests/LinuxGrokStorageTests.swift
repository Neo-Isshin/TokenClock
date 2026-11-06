#if os(Linux)
  import XCTest
  @testable import TokenClock
  final class LinuxGrokStorageTests: XCTestCase {
    func testBasicAndDesktopKeyringEncodingsPreserveAccountBinding() throws {
      let v10 = Data(
        base64Encoded:
          "eyJjdXJzb3ItYWNjb3VudHMiOiJ7XCJhY3RpdmVcIjogXCJlODlkMzM1YTI5ZDJjZjY2MjI4YmNjMDI2ZWQ1ZDNlMmFmY2JhNTJkMTU4YzNhOTRlYzU4OGY1N2QzYmI2NzQzXCIsIFwiYWNjb3VudHNcIjoge1wiZTg5ZDMzNWEyOWQyY2Y2NjIyOGJjYzAyNmVkNWQzZTJhZmNiYTUyZDE1OGMzYTk0ZWM1ODhmNTdkM2JiNjc0M1wiOiB7XCJjdXJzb3ItYWNjZXNzLXRva2VuXCI6IFwic2NvcGVkOnYxOmU4OWQzMzVhMjlkMmNmNjYyMjhiY2MwMjZlZDVkM2UyYWZjYmE1MmQxNThjM2E5NGVjNTg4ZjU3ZDNiYjY3NDM6ZGpFdzJpK2tYMCtiVGxnTDE1K1JybDFkUmJrb05pdWQ4OEYvTCsyZHNJZ0F3U1U0eUNVUHdUSHc0VkllSXgxdzQ5RXZGT1hUcHErdWh3UFQ5Q0ZlRHE1WlVyQ3dpMHEycGdmbEt0WFV3SGdUMTk2ODNxVmE3K0M4b1E1ejUzU3M0eUpmXCIsIFwiY3Vyc29yLWFjY291bnQtcHJvZmlsZVwiOiBcImRqRXdLWWJmRTdISjJRbkN0Wm9oWUt3Wkc0TGRsQTJ2b0p6STgrczRDM1RuTFRwMTNRVyswM25IMERHTGQwRGJMNnpQXCJ9fX0iLCJjdXJzb3ItbWFjaGluZS1pZCI6ImRqRXdBRFZXYXg2Vjg3NGMwaVRwR3lYb1RnNG9SeTZZMzFMaExXcUVWbzJIQnFnPSJ9"
      )!
      let cv10 = try XCTUnwrap(
        GrokBotNativeCredentialStore.decodeCredential(v10, password: "peanuts"))
      XCTAssertEqual(cv10.email, "synthetic@example.test")
      XCTAssertEqual(cv10.machineID, "synthetic-machine")
      XCTAssertNil(GrokBotNativeCredentialStore.decodeCredential(v10, password: "wrong-key"))
      let v11 = Data(
        base64Encoded:
          "eyJjdXJzb3ItYWNjb3VudHMiOiJ7XCJhY3RpdmVcIjogXCJlODlkMzM1YTI5ZDJjZjY2MjI4YmNjMDI2ZWQ1ZDNlMmFmY2JhNTJkMTU4YzNhOTRlYzU4OGY1N2QzYmI2NzQzXCIsIFwiYWNjb3VudHNcIjoge1wiZTg5ZDMzNWEyOWQyY2Y2NjIyOGJjYzAyNmVkNWQzZTJhZmNiYTUyZDE1OGMzYTk0ZWM1ODhmNTdkM2JiNjc0M1wiOiB7XCJjdXJzb3ItYWNjZXNzLXRva2VuXCI6IFwic2NvcGVkOnYxOmU4OWQzMzVhMjlkMmNmNjYyMjhiY2MwMjZlZDVkM2UyYWZjYmE1MmQxNThjM2E5NGVjNTg4ZjU3ZDNiYjY3NDM6ZGpFeFdtTHNjZ0xHOHV0RVZxc3V1djNrYi9YMkNzaWhYZDhqdVRCZUI1T21VTDV6NTYwSVNwM3o5MnNzam5vVW9CaWljYmhCd204N3NnNWpBSkVuV1B0SFcyTFc0SVJnbUpXbDczQXIrUk8zbkFUbFBNZUZVVW4rY2t4UFMvQUZvcURhXCIsIFwiY3Vyc29yLWFjY291bnQtcHJvZmlsZVwiOiBcImRqRXg0WThyVDVNcVdNVHQwV2pWQ3FzUktQcG5pMmgxc045aHZ3K0tYNUhnaW1LdDBHMnFxTTZSeEJyU0wzZklSSmtlXCJ9fX0iLCJjdXJzb3ItbWFjaGluZS1pZCI6ImRqRXhpYklLYUZTcE0zWW1mQnBSZHZiRTdkSGZLNU05dzNqMU9GNGgrd0w5S21JPSJ9"
      )!
      let cv11 = try XCTUnwrap(
        GrokBotNativeCredentialStore.decodeCredential(v11, password: "synthetic-vault-key"))
      XCTAssertEqual(cv11.email, "synthetic@example.test")
      XCTAssertEqual(cv11.machineID, "synthetic-machine")
      XCTAssertNil(GrokBotNativeCredentialStore.decodeCredential(v11, password: "wrong-key"))
    }
    func testBasicStorageReadsWithoutPromptAndRejectsAnotherCursorAccount() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      try Data("{\"signedIn\":true}".utf8).write(
        to: folder.appendingPathComponent("desktop-status.json"))
      let data = Data(
        base64Encoded:
          "eyJjdXJzb3ItYWNjb3VudHMiOiJ7XCJhY3RpdmVcIjogXCJlODlkMzM1YTI5ZDJjZjY2MjI4YmNjMDI2ZWQ1ZDNlMmFmY2JhNTJkMTU4YzNhOTRlYzU4OGY1N2QzYmI2NzQzXCIsIFwiYWNjb3VudHNcIjoge1wiZTg5ZDMzNWEyOWQyY2Y2NjIyOGJjYzAyNmVkNWQzZTJhZmNiYTUyZDE1OGMzYTk0ZWM1ODhmNTdkM2JiNjc0M1wiOiB7XCJjdXJzb3ItYWNjZXNzLXRva2VuXCI6IFwic2NvcGVkOnYxOmU4OWQzMzVhMjlkMmNmNjYyMjhiY2MwMjZlZDVkM2UyYWZjYmE1MmQxNThjM2E5NGVjNTg4ZjU3ZDNiYjY3NDM6ZGpFdzJpK2tYMCtiVGxnTDE1K1JybDFkUmJrb05pdWQ4OEYvTCsyZHNJZ0F3U1U0eUNVUHdUSHc0VkllSXgxdzQ5RXZGT1hUcHErdWh3UFQ5Q0ZlRHE1WlVyQ3dpMHEycGdmbEt0WFV3SGdUMTk2ODNxVmE3K0M4b1E1ejUzU3M0eUpmXCIsIFwiY3Vyc29yLWFjY291bnQtcHJvZmlsZVwiOiBcImRqRXdLWWJmRTdISjJRbkN0Wm9oWUt3Wkc0TGRsQTJ2b0p6STgrczRDM1RuTFRwMTNRVyswM25IMERHTGQwRGJMNnpQXCJ9fX0iLCJjdXJzb3ItbWFjaGluZS1pZCI6ImRqRXdBRFZXYXg2Vjg3NGMwaVRwR3lYb1RnNG9SeTZZMzFMaExXcUVWbzJIQnFnPSJ9"
      )!
      try data.write(to: folder.appendingPathComponent("sand-secrets.json"))
      let store = GrokBotNativeCredentialStore(
        supportDirectory: folder.path,
        passwordReader: { _ in
          XCTFail("Basic text must not query/unlock the keyring")
          return .init(password: nil)
        })
      let credential = try XCTUnwrap(store.currentCredential)
      XCTAssertTrue(store.hasSignedInInstance)
      XCTAssertTrue(store.acceptsCursorToken(credential.accessToken))
      XCTAssertFalse(store.acceptsCursorToken("another-account"))
      XCTAssertEqual(store.accessState, .authorized)
    }
    func testLegacyAccountUsesItsOwnVerifiedPrincipal() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let source =
        try JSONSerialization.jsonObject(
          with: Data(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
              .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
                "Tests/fixtures/native-grok-v10.json"))) as! [String: Any]
      let envelope =
        try JSONSerialization.jsonObject(with: Data((source["cursor-accounts"] as! String).utf8))
        as! [String: Any]
      let active = envelope["active"] as! String
      var legacy = (envelope["accounts"] as! [String: [String: Any]])[active]!
      // Old files are unscoped. Remove only the fixture's explicit scope marker.
      for key in ["cursor-access-token", "cursor-account-profile"] {
        if let value = legacy[key] as? String, value.hasPrefix("scoped:v1:") {
          legacy[key] = String(value.split(separator: ":", maxSplits: 3)[3])
        }
      }
      legacy["cursor-machine-id"] = source["cursor-machine-id"]
      try JSONSerialization.data(withJSONObject: legacy).write(
        to: folder.appendingPathComponent("sand-secrets.json"))
      try Data("{\"signedIn\":true}".utf8).write(
        to: folder.appendingPathComponent("desktop-status.json"))
      let store = GrokBotNativeCredentialStore(supportDirectory: folder.path)
      let credential = try XCTUnwrap(store.currentCredential)
      XCTAssertTrue(store.acceptsCursorToken(credential.accessToken))
      XCTAssertFalse(store.acceptsCursorToken("unrelated"))
    }

  }
#endif
