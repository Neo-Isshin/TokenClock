import Foundation
import Security

// Import an encrypted PKCS#12 identity into the login keychain. The transport
// passphrase arrives on stdin, never argv or logs. Only codesign is preauthorised;
// no system/user trust settings or keychain search lists are changed here.
@main struct ImportIdentity {
    static func main() throws {
        guard CommandLine.arguments.count == 2,
              let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: String],
              let password = input["passphrase"] else { throw Failure.status(errSecParam) }
        var keychain: SecKeychain?
        try check(SecKeychainCopyDefault(&keychain))
        guard let keychain else { throw Failure.status(errSecNoSuchKeychain) }
        var size: UInt32 = 4096
        var path = [CChar](repeating: 0, count: Int(size))
        try check(SecKeychainGetPath(keychain, &size, &path))
        let actual = String(cString: path)
        let directory = NSHomeDirectory() + "/Library/Keychains/"
        guard actual == directory + "login.keychain-db" || actual == directory + "login.keychain" else {
            throw Failure.status(errSecNoDefaultKeychain)
        }
        var application: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &application))
        guard let application else { throw Failure.status(errSecParam) }
        var access: SecAccess?
        try check(SecAccessCreate("TokenClock Local Code Signing" as CFString, [application] as CFArray, &access))
        guard let access else { throw Failure.status(errSecParam) }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let options: [CFString: Any] = [kSecImportExportPassphrase: password,
                                       kSecImportExportKeychain: keychain, kSecImportExportAccess: access]
        var items: CFArray?
        try check(SecPKCS12Import(data as CFData, options as CFDictionary, &items))
        print("Imported TokenClock signing identity into login keychain; trust settings unchanged.")
    }
    enum Failure: Error { case status(OSStatus) }
    static func check(_ status: OSStatus) throws {
        if status != errSecSuccess { throw Failure.status(status) }
    }
}
