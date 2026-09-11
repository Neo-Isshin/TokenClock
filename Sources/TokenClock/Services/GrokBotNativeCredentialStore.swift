import Foundation

#if os(macOS)
import CommonCrypto
import LocalAuthentication
import Security
#endif

struct GrokBotNativeCredential: Sendable {
    let accessToken: String
    let userID: String
    let email: String?
    let machineID: String
}

enum GrokBotNativeAccessState: Equatable, Sendable {
    case unavailable
    case authorizationRequired
    case authorizing
    case authorized
}

/// Reads the Cursor account already signed into the standalone Grok Bot app.
///
/// Automatic refreshes never show an OS prompt. On macOS, another app may read Electron's
/// `safeStorage` key only after an explicit user override, so interactive access is exposed as a
/// separate UI action. Passwords and Cursor tokens are cached in memory only and are never copied
/// into TokenClock preferences, logs, or its own Keychain item.
final class GrokBotNativeCredentialStore: @unchecked Sendable {
    static let shared = GrokBotNativeCredentialStore()

    private let lock = NSLock()
    private var cachedCredential: GrokBotNativeCredential?
    private var authorizationInProgress = false

    var hasSignedInInstance: Bool {
        #if os(macOS)
        let statusPath = supportDirectory + "/desktop-status.json"
        guard let data = FileManager.default.contents(atPath: statusPath),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["signedIn"] as? Bool == true else { return false }
        return FileManager.default.fileExists(atPath: secretsPath)
        #else
        return false
        #endif
    }

    var accessState: GrokBotNativeAccessState {
        lock.withLock {
            if cachedCredential != nil { return .authorized }
            if authorizationInProgress { return .authorizing }
            return hasSignedInInstance ? .authorizationRequired : .unavailable
        }
    }

    func credential(allowInteraction: Bool = false) -> GrokBotNativeCredential? {
        if let cached = lock.withLock({ cachedCredential }) { return cached }
        guard hasSignedInInstance else { return nil }
        guard let password = safeStoragePassword(allowInteraction: allowInteraction),
              let credential = decodeCredential(password: password) else { return nil }
        lock.withLock { cachedCredential = credential }
        return credential
    }

    func authorize() -> Bool {
        lock.withLock { authorizationInProgress = true }
        defer { lock.withLock { authorizationInProgress = false } }
        return credential(allowInteraction: true) != nil
    }

    func clearCachedCredential() {
        lock.withLock { cachedCredential = nil }
    }

    #if os(macOS)
    private var supportDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/Grok Bot"
    }

    private var secretsPath: String { supportDirectory + "/sand-secrets.json" }

    private func safeStoragePassword(allowInteraction: Bool) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "Grok Bot Safe Storage",
            kSecAttrAccount: "Grok Bot Key",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              data.count <= 16_384,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else { return nil }
        return password
    }

    private func decodeCredential(password: String) -> GrokBotNativeCredential? {
        guard let data = FileManager.default.contents(atPath: secretsPath),
              data.count <= 4_194_304,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accountsText = root["cursor-accounts"] as? String,
              let accountsData = accountsText.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: accountsData) as? [String: Any],
              let active = envelope["active"] as? String,
              let accounts = envelope["accounts"] as? [String: Any],
              let account = accounts[active] as? [String: Any],
              let accessCipher = account["cursor-access-token"] as? String,
              let accessToken = Self.decryptSafeStoragePayload(accessCipher, password: password),
              let userID = CursorQuotaService.userID(from: accessToken),
              let machineCipher = root["cursor-machine-id"] as? String,
              let machineID = Self.decryptSafeStoragePayload(machineCipher, password: password),
              !machineID.isEmpty else { return nil }

        var email: String?
        if let profileCipher = account["cursor-account-profile"] as? String,
           let profileText = Self.decryptSafeStoragePayload(profileCipher, password: password),
           let profileData = profileText.data(using: .utf8),
           let profile = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any] {
            email = (profile["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if email?.isEmpty == true { email = nil }
        }
        return GrokBotNativeCredential(
            accessToken: accessToken,
            userID: userID,
            email: email,
            machineID: machineID
        )
    }

    static func decryptSafeStoragePayload(_ base64: String, password: String) -> String? {
        guard var encrypted = Data(base64Encoded: base64),
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
    #else
    private func safeStoragePassword(allowInteraction: Bool) -> String? {
        _ = allowInteraction
        return nil
    }
    #endif
}
