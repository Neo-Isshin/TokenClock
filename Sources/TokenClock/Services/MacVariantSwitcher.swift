#if os(macOS)
import Foundation
import CryptoKit

enum MacVariantSwitcher {
    static let helperName = "macos-variant-switch.sh"
    static let preferredKey = "TC_preferredMacVariant"
    static let failureKey = "TC_macVariantSwitchFailure"

    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
        let size: Int
    }
    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func supported(_ variant: LaunchAgentHelper.Variant, majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> Bool {
        majorVersion >= (variant == .glass ? 26 : 12)
    }

    static func binaryURL(_ variant: LaunchAgentHelper.Variant, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".tokenclock/\(variant.rawValue)/TokenClock")
    }

    static func needsInstallation(_ variant: LaunchAgentHelper.Variant, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let binary = binaryURL(variant, home: home)
        let helper = binary.deletingLastPathComponent()
            .appendingPathComponent("TokenClock_TokenClock.bundle/Contents/Resources/\(helperName)")
        return !FileManager.default.isExecutableFile(atPath: binary.path)
            || !FileManager.default.fileExists(atPath: helper.path)
    }

    static func decodeAsset(_ data: Data, variant: LaunchAgentHelper.Variant, version: String) throws -> Asset {
        let release = try JSONDecoder().decode(Release.self, from: data)
        let name = "TokenClock-\(variant.rawValue)-universal.tar.gz"
        let expected = "https://github.com/Neo-Isshin/TokenClock/releases/download/v\(version)/\(name)"
        guard release.tag_name == "v\(version)", !release.draft, !release.prerelease,
              let asset = release.assets.first(where: { $0.name == name }),
              asset.browser_download_url.absoluteString == expected,
              asset.size > 0, asset.size <= 32 * 1024 * 1024,
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.dropFirst(7).count == 64,
              digest.dropFirst(7).allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw Failure("The release does not contain a verified macOS package.")
        }
        return asset
    }

    static func archiveEntryIsSafe(_ entry: String) -> Bool {
        let clean = entry.hasPrefix("./") ? String(entry.dropFirst(2)) : entry
        let parts = clean.split(separator: "/", omittingEmptySubsequences: true)
        guard !clean.hasPrefix("/"), !parts.contains(".."), let first = parts.first else { return false }
        return first == "TokenClock" && parts.count == 1 || first == "TokenClock_TokenClock.bundle"
    }

    static func prepare(_ target: LaunchAgentHelper.Variant) async throws {
        guard supported(target) else { throw Failure("This macOS version does not support the selected edition.") }
        guard needsInstallation(target) else { return }
        let tag = "v\(AppConfig.version)"
        let api = URL(string: "https://api.github.com/repos/Neo-Isshin/TokenClock/releases/tags/\(tag)")!
        var request = URLRequest(url: api, timeoutInterval: 20)
        request.setValue("TokenClock/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        let (metadata, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("Unable to read release metadata.") }
        let asset = try decodeAsset(metadata, variant: target, version: AppConfig.version)
        let (archive, downloadResponse) = try await URLSession.shared.data(for: URLRequest(url: asset.browser_download_url, timeoutInterval: 60))
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200, archive.count == asset.size,
              SHA256.hash(data: archive).map({ String(format: "%02x", $0) }).joined() == String(asset.digest!.dropFirst(7)).lowercased() else {
            throw Failure("The downloaded package failed SHA-256 verification.")
        }
        let fm = FileManager.default
        let stage = fm.temporaryDirectory.appendingPathComponent("tokenclock-edition-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let tar = stage.appendingPathComponent("package.tar.gz")
        try archive.write(to: tar, options: .atomic)
        let listing = try run("/usr/bin/tar", ["-tzf", tar.path])
        let entries = listing.split(separator: "\n").map(String.init)
        guard !entries.isEmpty, entries.allSatisfy(archiveEntryIsSafe) else { throw Failure("Unsafe package contents.") }
        _ = try run("/usr/bin/tar", ["-xzf", tar.path, "-C", stage.path])
        let newBinary = stage.appendingPathComponent("TokenClock")
        let newBundle = stage.appendingPathComponent("TokenClock_TokenClock.bundle")
        guard fm.isExecutableFile(atPath: newBinary.path),
              fm.fileExists(atPath: newBundle.appendingPathComponent("Contents/Resources/\(helperName)").path) else {
            throw Failure("The package does not support edition switching. Please retry after the hot update is available.")
        }
        _ = try run("/usr/bin/codesign", ["--verify", newBinary.path])
        let destination = binaryURL(target).deletingLastPathComponent()
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let backup = destination.appendingPathComponent("edition-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let names = ["TokenClock", "TokenClock_TokenClock.bundle"]
        var saved: [String] = []
        var installed: [String] = []
        do {
            for name in names where fm.fileExists(atPath: destination.appendingPathComponent(name).path) {
                try fm.moveItem(at: destination.appendingPathComponent(name), to: backup.appendingPathComponent(name))
                saved.append(name)
            }
            for name in names {
                try fm.moveItem(at: stage.appendingPathComponent(name), to: destination.appendingPathComponent(name))
                installed.append(name)
            }
        } catch {
            for name in installed { try? fm.removeItem(at: destination.appendingPathComponent(name)) }
            for name in saved { try? fm.moveItem(at: backup.appendingPathComponent(name), to: destination.appendingPathComponent(name)) }
            throw error
        }
    }

    static func launchHandoff(to target: LaunchAgentHelper.Variant, from source: LaunchAgentHelper.Variant, sourcePath: String, sourcePID: Int32, launchAtLogin: Bool) throws {
        let existing = LaunchAgentHelper.plistURL(variant: target)
        if FileManager.default.fileExists(atPath: existing.path) {
            let data = try Data(contentsOf: existing)
            let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            guard dictionary?["Label"] as? String == target.label,
                  (dictionary?["ProgramArguments"] as? [String])?.first == binaryURL(target).path else {
                throw Failure("The target LaunchAgent points to a custom installation. Update its registration before switching.")
            }
        }
        guard let helper = Bundle.module.url(forResource: "macos-variant-switch", withExtension: "sh") else {
            throw Failure("The edition-switching helper is missing.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let stage = home.appendingPathComponent(".tokenclock/edition-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": target.label, "ProgramArguments": [binaryURL(target).path], "RunAtLoad": launchAtLogin,
            "ProcessType": "Interactive", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
            "KeepAlive": ["Crashed": true]
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: stage.appendingPathComponent("target.plist"), options: .atomic)
        let log = stage.appendingPathComponent("handoff.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path, home.path, source.rawValue, target.rawValue,
                             String(sourcePID), sourcePath, launchAtLogin ? "1" : "0", stage.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try? output.close()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("Package validation failed: \(executable)") }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
#endif
