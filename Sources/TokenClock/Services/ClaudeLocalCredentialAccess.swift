#if os(macOS)
import Foundation
import Security
import LocalAuthentication

/// Background callers always use the isolated no-UI helper. Interactive access
/// is reachable only from the explicit “Read local login” button, never a timer.
enum ClaudeLocalCredentialAccess {
    struct Result { let data: Data?; let authorizationRequired: Bool; let cancelled: Bool }
    static func read(service: String, account: String?, userInitiated: Bool) -> Result {
        guard service.hasPrefix("Claude"),ClaudeSilentKeychain.accepts(service:service) else {
            return Result(data:nil,authorizationRequired:false,cancelled:false)
        }
        if !userInitiated {
            let value=ClaudeSilentKeychain.readResult(service:service,account:account)
            return Result(data:value.data,authorizationRequired:value.authorizationRequired,cancelled:false)
        }
        let context=LAContext()
        var query:[CFString:Any]=[kSecClass:kSecClassGenericPassword,kSecAttrService:service,kSecReturnData:true,
                                 kSecMatchLimit:kSecMatchLimitOne,kSecUseAuthenticationContext:context,
                                 kSecUseOperationPrompt:L10n.shared.tr("quota.claudeLocalAuthReason")]
        if let account {query[kSecAttrAccount]=account}
        var value:CFTypeRef?
        let status=SecItemCopyMatching(query as CFDictionary,&value)
        guard status==errSecSuccess,let data=value as? Data,!data.isEmpty,data.count<=16_384 else {
            let denied=status==errSecAuthFailed || status==errSecInteractionNotAllowed
            return Result(data:nil,authorizationRequired:denied || status==errSecUserCanceled,cancelled:denied || status==errSecUserCanceled)
        }
        return Result(data:data,authorizationRequired:false,cancelled:false)
    }
}
/// An explicitly granted App encryption key can be reused within this process.
/// This does not cache OAuth tokens or write anything to Keychain/preferences.
final class ClaudeAppPasswordCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func read(_ load: () -> ClaudeLocalCredentialAccess.Result) -> (result: ClaudeLocalCredentialAccess.Result, cached: Bool) {
        lock.withLock {
            if let value { return (.init(data: value, authorizationRequired: false, cancelled: false), true) }
            let result = load()
            if let data = result.data, !data.isEmpty, data.count <= 16_384 { value = data }
            return (result, false)
        }
    }
    func invalidate() { lock.withLock { value = nil } }
}
#endif
