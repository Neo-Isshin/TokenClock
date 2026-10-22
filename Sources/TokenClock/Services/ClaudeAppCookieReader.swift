#if os(macOS)
import Foundation
import SQLite3
import Security
import LocalAuthentication
import CommonCrypto
import CryptoKit

enum ClaudeSilentKeychain {
    /// No security CLI subprocess and no interactive recovery. An ACL denial is
    /// a normal missing-credential result, not permission to open a dialog.
    static func read(service: String, account: String? = nil) -> Data? {
        let context = LAContext(); context.interactionNotAllowed = true
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context]
        if let account { query[kSecAttrAccount] = account }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 16_384 else { return nil }
        return data
    }
}

enum ClaudeAppCookieReader {
    static func read(homes: [String] = ClaudeDesktopData.homes(), now: Date = Date(),
                     password: () -> String? = {
                         ClaudeSilentKeychain.read(service: "Claude Safe Storage", account: "Claude Key")
                             .flatMap { String(data: $0, encoding: .utf8) }
                     }) -> ClaudeAppSession? {
        for home in homes {
            // Newer profile location wins. Do not fall back to an older database
            // (and potentially another account) when the current one is unreadable.
            guard let path = [home + "/Network/Cookies", home + "/Cookies"].first(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            var db: OpaquePointer?
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if let db { sqlite3_close(db) }; return nil
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 100)
            var active: OpaquePointer?
            let activeQuery = "SELECT 1 FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name='sessionKey' AND is_secure=1 AND (expires_utc=0 OR expires_utc>?) LIMIT 1"
            guard sqlite3_prepare_v2(db, activeQuery, -1, &active, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_double(active, 1, (now.timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
            let hasActiveSession = sqlite3_step(active) == SQLITE_ROW
            sqlite3_finalize(active)
            guard hasActiveSession else { return nil }
            var statement: OpaquePointer?
            let query = "SELECT host_key,name,value,encrypted_value,expires_utc FROM cookies WHERE host_key IN ('claude.ai','.claude.ai') AND name IN ('sessionKey','lastActiveOrg') AND is_secure=1 LIMIT 17"
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            var schema = 0, version: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key='version'", -1, &version, nil) == SQLITE_OK,
               sqlite3_step(version) == SQLITE_ROW { schema = Int(sqlite3_column_int(version, 0)) }
            sqlite3_finalize(version)
            var values: [String: Set<String>] = [:], count = 0
            var cachedPassword: String?, triedPassword = false
            while sqlite3_step(statement) == SQLITE_ROW {
                count += 1; guard count <= 16 else { return nil }
                guard let host = sqlite3_column_text(statement, 0), let name = sqlite3_column_text(statement, 1) else { continue }
                let expiry = sqlite3_column_int64(statement, 4)
                guard expiry == 0 || Double(expiry) / 1_000_000 - 11_644_473_600 > now.timeIntervalSince1970 else { continue }
                var value = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
                if value.isEmpty {
                    let length = Int(sqlite3_column_bytes(statement, 3))
                    guard length > 3, length <= 16_384, let bytes = sqlite3_column_blob(statement, 3) else { continue }
                    let encrypted = Data(bytes: bytes, count: length)
                    guard encrypted.prefix(3) == Data("v10".utf8) else { continue }
                    if !triedPassword { cachedPassword = password(); triedPassword = true }
                    guard let cachedPassword,
                          let decoded = decrypt(encrypted, password: cachedPassword, host: String(cString: host), schema: schema) else { continue }
                    value = decoded
                }
                guard ClaudeAppSession.validKey(value) else { continue }
                values[String(cString: name), default: []].insert(value)
            }
            guard let keys = values["sessionKey"], keys.count == 1, let key = keys.first else { return nil }
            let organizations = values["lastActiveOrg"] ?? []
            guard organizations.count <= 1 else { return nil }
            let org = organizations.first.flatMap { UUID(uuidString: $0) == nil ? nil : $0 }
            return ClaudeAppSession(key: key, organizationID: org, connected: false)
        }
        return nil
    }

    static func decrypt(_ data: Data, password: String, host: String, schema: Int) -> String? {
        guard data.prefix(3) == Data("v10".utf8), data.count > 3 else { return nil }
        let encrypted = data.dropFirst(3), salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: 16)
        let status = password.withCString { pointer in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pointer, password.utf8.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, 16)
        }
        guard status == kCCSuccess else { return nil }
        let iv = [UInt8](repeating: 0x20, count: 16)
        var output = [UInt8](repeating: 0, count: encrypted.count + 16), length = 0
        let result = encrypted.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key, 16, iv, bytes.baseAddress, encrypted.count, &output, output.count, &length)
        }
        guard result == kCCSuccess else { return nil }
        var clear = Data(output.prefix(length))
        if schema >= 24 {
            let digest = Data(SHA256.hash(data: Data(host.utf8)))
            guard clear.count >= 32, clear.prefix(32) == digest else { return nil }
            clear.removeFirst(32)
        }
        return String(data: clear, encoding: .utf8)
    }
}
#endif
