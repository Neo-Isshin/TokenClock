import Foundation
#if os(macOS)
import CommonCrypto
import CryptoKit
import LocalAuthentication
import Security
#endif

struct GrokBotNativeCredential: Equatable, Sendable {
    let accessToken: String
    let userID: String
    let email: String?
    let machineID: String
}

enum GrokBotNativeAccessState: Equatable, Sendable {
    case unavailable, authorizationRequired, authorizing, authorized, readFailed
}

/// Reuses only the active Grok Bot account. Grants are rechecked silently after
/// restart; interactive Keychain access is reserved for the explicit UI action.
/// Secrets stay in memory. A decode failure never turns into another grant request.
final class GrokBotNativeCredentialStore: @unchecked Sendable {
    static let shared = GrokBotNativeCredentialStore()
    struct PasswordReadResult: Sendable {
        let password: String?
        var authorizationRequired = false
    }
    typealias PasswordReader = @Sendable (Bool) -> PasswordReadResult
    private let lock = NSLock()
    private let credentialLock = NSLock()
    private let supportDirectory: String
    private let passwordReader: PasswordReader
    private var cachedCredential: GrokBotNativeCredential?
    private var cachedSafeStoragePassword: String?
    private var authorizationInProgress = false
    private var needsAuthorization = false
    private var readFailed = false

    init(supportDirectory: String = NSHomeDirectory() + "/Library/Application Support/Grok Bot",
         passwordReader: PasswordReader? = nil) {
        self.supportDirectory = supportDirectory
        self.passwordReader = passwordReader ?? Self.readSafeStoragePassword
    }
    private var secretsPath: String { supportDirectory + "/sand-secrets.json" }
    var hasSignedInInstance: Bool {
        #if os(macOS)
        guard let data = boundedData(supportDirectory + "/desktop-status.json", limit: 65_536),
              let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              status["signedIn"] as? Bool == true else { return false }
        return FileManager.default.fileExists(atPath: secretsPath)
        #else
        return false
        #endif
    }
    /// Current Grok Bot versions store SHA-256(JWT sub) as the active account
    /// key. Matching this public selector avoids reading Safe Storage when an
    /// already available Cursor credential belongs to that exact App account.
    func acceptsCursorToken(_ token: String) -> Bool {
        guard hasSignedInInstance else { return true }
        #if os(macOS)
        guard let data = boundedData(secretsPath, limit: 4_194_304),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = root["cursor-accounts"] as? String,
              let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let active = envelope["active"] as? String,
              let accounts = envelope["accounts"] as? [String: Any], accounts[active] != nil else { return false }
        return active == Self.accountScope(for: token)
        #else
        return false
        #endif
    }
    #if os(macOS)
    static func accountScope(for token: String) -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        var principal = token
        if parts.count == 3 {
            var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while base64.count % 4 != 0 { base64 += "=" }
            if let data = Data(base64Encoded: base64),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let subject = payload["sub"] as? String { principal = subject }
        }
        return SHA256.hash(data: Data(principal.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #endif
    var accessState: GrokBotNativeAccessState {
        let signedIn = hasSignedInInstance
        return lock.withLock {
            guard signedIn else { return .unavailable }
            if authorizationInProgress { return .authorizing }
            if cachedCredential != nil { return .authorized }
            if readFailed { return .readFailed }
            return .authorizationRequired
        }
    }
    var failureMessageKey: String? {
        lock.withLock {
            if needsAuthorization { return "quota.grokBotAuthorizationBody" }
            return readFailed ? "quota.grokBotCredentialReadFailed" : nil
        }
    }
    var currentCredential: GrokBotNativeCredential? {
        credentialLock.withLock { loadCredential(allowInteraction: false) }
    }
    func authorize() -> Bool {
        credentialLock.withLock {
            lock.withLock { authorizationInProgress = true }
            defer { lock.withLock { authorizationInProgress = false } }
            return loadCredential(allowInteraction: true) != nil
        }
    }
    func clearCachedCredential() {
        credentialLock.withLock { resetMemory() }
    }
    private func resetMemory() {
        lock.withLock {
            cachedCredential = nil; cachedSafeStoragePassword = nil
            needsAuthorization = false; readFailed = false
        }
    }
    private func boundedData(_ path: String, limit: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= limit else { return nil }
        return FileManager.default.contents(atPath: path)
    }
    private func loadCredential(allowInteraction: Bool) -> GrokBotNativeCredential? {
        guard hasSignedInInstance else { resetMemory(); return nil }
        #if os(macOS)
        guard let data = boundedData(secretsPath, limit: 4_194_304) else {
            lock.withLock { cachedCredential = nil; readFailed = true; needsAuthorization = false }
            return nil
        }
        if let password = lock.withLock({ cachedSafeStoragePassword }),
           let credential = Self.decodeCredential(data, password: password) {
            lock.withLock { cachedCredential = credential; readFailed = false; needsAuthorization = false }
            return credential
        }
        // A file change or key rotation invalidates the old credential. Never
        // fall back to an account/token retained from a previous file version.
        let result = passwordReader(allowInteraction)
        guard let password = result.password, !password.isEmpty else {
            lock.withLock {
                cachedCredential = nil; cachedSafeStoragePassword = nil
                needsAuthorization = result.authorizationRequired
                readFailed = !result.authorizationRequired
            }
            return nil
        }
        let credential = Self.decodeCredential(data, password: password)
        lock.withLock {
            cachedSafeStoragePassword = password; cachedCredential = credential
            needsAuthorization = false; readFailed = credential == nil
        }
        return credential
        #else
        return nil
        #endif
    }
    private static func readSafeStoragePassword(allowInteraction: Bool) -> PasswordReadResult {
        readKeychainString(service: "Grok Bot Safe Storage", account: "Grok Bot Key", allowInteraction: allowInteraction)
    }
    static func readCursorToken(allowInteraction: Bool) -> PasswordReadResult {
        readKeychainString(service: "cursor-access-token", account: "cursor-user", allowInteraction: allowInteraction)
    }
    private static func readKeychainString(service: String, account: String, allowInteraction: Bool) -> PasswordReadResult {
        #if os(macOS)
        if !allowInteraction {
            let result = ClaudeSilentKeychain.readResult(service: service, account: account)
            return PasswordReadResult(password: result.data.flatMap { String(data: $0, encoding: .utf8) }, authorizationRequired: result.authorizationRequired)
        }
        let context = LAContext()
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, data.count <= 16_384,
              let password = String(data: data, encoding: .utf8), !password.isEmpty else {
            return PasswordReadResult(password: nil, authorizationRequired:
                status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled)
        }
        return PasswordReadResult(password: password)
        #else
        return PasswordReadResult(password: nil)
        #endif
    }
    #if os(macOS)
    static func decodeCredential(_ data: Data, password: String) -> GrokBotNativeCredential? {
        guard data.count <= 4_194_304,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let account: [String: Any]
        let active: String?
        if let text = root["cursor-accounts"] as? String {
            guard let envelope = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let selected = envelope["active"] as? String,
                  let accounts = envelope["accounts"] as? [String: Any],
                  let current = accounts[selected] as? [String: Any] else { return nil }
            account = current; active = selected
        } else if root["cursor-accounts"] == nil {
            account = root; active = nil // Legacy single-account Sand storage.
        } else { return nil }
        guard let cipher = account["cursor-access-token"] as? String,
              let token = decryptSafeStoragePayload(cipher, password: password, expectedScope: active),
              let userID = CursorQuotaService.userID(from: token),
              let machineCipher = root["cursor-machine-id"] as? String,
              let machine = decryptSafeStoragePayload(machineCipher, password: password, expectedScope: active),
              !machine.isEmpty else { return nil }
        var email: String?
        if let cipher = account["cursor-account-profile"] as? String,
           let text = decryptSafeStoragePayload(cipher, password: password, expectedScope: active),
           let profile = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            email = (profile["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if email?.isEmpty == true { email = nil }
        }
        return GrokBotNativeCredential(accessToken: token, userID: userID, email: email, machineID: machine)
    }
    static func decryptSafeStoragePayload(_ base64: String, password: String, expectedScope: String? = nil) -> String? {
        var payload = base64
        if payload.hasPrefix("scoped:v1:") {
            let parts = payload.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, parts[2].count == 64,
                  parts[2].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                  let expectedScope, String(parts[2]) == expectedScope else { return nil }
            payload = String(parts[3])
        }
        guard var encrypted = Data(base64Encoded: payload),
              encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8) else { return nil }
        encrypted.removeFirst(3)

        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivation = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordPointer,
                    password.lengthOfBytes(using: .utf8),
                    saltPointer.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1_003,
                    &key,
                    key.count
                )
            }
        }
        guard derivation == kCCSuccess else { return nil }

        let initializationVector = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        var outputLength = 0
        let status = encrypted.withUnsafeBytes { encryptedPointer in
            key.withUnsafeBytes { keyPointer in
                initializationVector.withUnsafeBytes { ivPointer in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPointer.baseAddress,
                        key.count,
                        ivPointer.baseAddress,
                        encryptedPointer.baseAddress,
                        encrypted.count,
                        &output,
                        output.count,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return String(data: Data(output.prefix(outputLength)), encoding: .utf8)
    }
    #endif
}
