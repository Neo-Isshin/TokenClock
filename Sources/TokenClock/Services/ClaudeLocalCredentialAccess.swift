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
#endif
