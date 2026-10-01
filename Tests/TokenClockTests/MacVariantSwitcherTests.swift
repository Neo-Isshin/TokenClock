#if os(macOS)
import Foundation
import XCTest
@testable import TokenClock

final class MacVariantSwitcherTests: XCTestCase {

    func testHandoffTransfersAutostartWithoutKeepingBothEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-autostart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var childPID: Int32?
        defer {
            if let childPID { _ = kill(childPID, SIGTERM) }
            try? FileManager.default.removeItem(at: root)
        }
        func writeExecutable(_ path: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        let source = root.appendingPathComponent("source")
        let target = MacVariantSwitcher.binaryURL(.normal, home: root)
        try writeExecutable(source, "#!/bin/sh\nexit 1\n")
        try writeExecutable(target, "#!/bin/sh\necho $$ > '\(root.path)/target.pid'\nexec /bin/sleep 30\n")
        let agents = root.appendingPathComponent("Library/LaunchAgents")
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        func plist(_ url: URL, _ variant: String, _ path: String, _ enabled: Bool) throws {
            try PropertyListSerialization.data(fromPropertyList: [
                "Label": "com.tokenclock.app.\(variant)", "ProgramArguments": [path], "RunAtLoad": enabled
            ], format: .xml, options: 0).write(to: url)
        }
        let oldPlist = agents.appendingPathComponent("com.tokenclock.app.glass.plist")
        let newPlist = agents.appendingPathComponent("com.tokenclock.app.normal.plist")
        try plist(oldPlist, "glass", source.path, true)
        try plist(newPlist, "normal", target.path, false)
        try plist(stage.appendingPathComponent("target.plist"), "normal", target.path, true)
        let defaults = root.appendingPathComponent("defaults")
        try writeExecutable(defaults, "#!/bin/sh\necho \"$*\" >> '\(root.path)/defaults.log'\n")
        let launcher = root.appendingPathComponent("launchctl")
        try writeExecutable(launcher, """
        #!/bin/sh
        echo "$*" >> '\(root.path)/launchctl.log'
        case "$1" in
          bootstrap) '\(target.path)' >/dev/null 2>&1 & ;;
          print) echo "pid = $(cat '\(root.path)/target.pid')" ;;
        esac
        exit 0
        """)
        let resource = try XCTUnwrap(Bundle.module.url(forResource: "macos-variant-switch", withExtension: "sh"))
        let helper = root.appendingPathComponent("helper")
        let script = try String(contentsOf: resource, encoding: .utf8)
            .replacingOccurrences(of: "/bin/launchctl", with: "'\(launcher.path)'")
            .replacingOccurrences(of: "/usr/bin/defaults", with: "'\(defaults.path)'")
        try writeExecutable(helper, script)
        let previous = Process()
        previous.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try previous.run(); previous.waitUntilExit()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path, root.path, "glass", "normal", String(previous.processIdentifier), source.path, "1", stage.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        if let text = try? String(contentsOf: root.appendingPathComponent("target.pid"), encoding: .utf8) {
            childPID = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        XCTAssertEqual(process.terminationStatus, 0)
        func enabled(_ path: URL) throws -> Bool? {
            try (PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: Any])?["RunAtLoad"] as? Bool
        }
        XCTAssertEqual(try enabled(oldPlist), false)
        XCTAssertEqual(try enabled(newPlist), true)
        XCTAssertNotNil(childPID)
    }
    func testSupportedEditionsRespectMinimumOS() {
        XCTAssertFalse(MacVariantSwitcher.supported(.glass, majorVersion: 25))
        XCTAssertTrue(MacVariantSwitcher.supported(.glass, majorVersion: 26))
        XCTAssertTrue(MacVariantSwitcher.supported(.normal, majorVersion: 12))
        XCTAssertFalse(MacVariantSwitcher.supported(.normal, majorVersion: 11))
    }

    func testInstallationRequiresExecutableAndSwitchingResource() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tc-edition-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertTrue(MacVariantSwitcher.needsInstallation(.normal, home: home))
        let binary = MacVariantSwitcher.binaryURL(.normal, home: home)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertTrue(MacVariantSwitcher.needsInstallation(.normal, home: home))
        let resource = binary.deletingLastPathComponent().appendingPathComponent("TokenClock_TokenClock.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: resource, withIntermediateDirectories: true)
        try Data().write(to: resource.appendingPathComponent(MacVariantSwitcher.helperName))
        XCTAssertFalse(MacVariantSwitcher.needsInstallation(.normal, home: home))
    }

    func testReleaseMetadataRequiresExactRepositoryTagAndDigest() throws {
        func metadata(url: String, digest: String, draft: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "tag_name": "v1.5.12", "draft": draft, "prerelease": false,
                "assets": [["name": "TokenClock-normal-universal.tar.gz", "size": 400,
                            "browser_download_url": url, "digest": digest]]
            ])
        }
        let url = "https://github.com/Neo-Isshin/TokenClock/releases/download/v1.5.12/TokenClock-normal-universal.tar.gz"
        let digest = "sha256:" + String(repeating: "a", count: 64)
        XCTAssertEqual(try MacVariantSwitcher.decodeAsset(metadata(url: url, digest: digest), variant: .normal, version: "1.5.12").size, 400)
        XCTAssertThrowsError(try MacVariantSwitcher.decodeAsset(metadata(url: "https://example.com/package", digest: digest), variant: .normal, version: "1.5.12"))
        XCTAssertThrowsError(try MacVariantSwitcher.decodeAsset(metadata(url: url, digest: "sha256:bad"), variant: .normal, version: "1.5.12"))
        XCTAssertThrowsError(try MacVariantSwitcher.decodeAsset(metadata(url: url, digest: digest, draft: true), variant: .normal, version: "1.5.12"))
    }

    func testArchivePathsCannotEscapeOrIntroduceUnrelatedFiles() {
        for path in ["TokenClock", "./TokenClock_TokenClock.bundle/", "TokenClock_TokenClock.bundle/Contents/Resources/icon.png"] {
            XCTAssertTrue(MacVariantSwitcher.archiveEntryIsSafe(path))
        }
        for path in ["../TokenClock", "/TokenClock", "TokenClock_TokenClock.bundle/../../secret", "other/file", "TokenClock/file"] {
            XCTAssertFalse(MacVariantSwitcher.archiveEntryIsSafe(path))
        }
    }

    func testHandoffWithAutostartOffAndFailureRollback() throws {
        for fail in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-handoff-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var ownedPIDs: [Int32] = []
            defer {
                for pid in ownedPIDs { _ = kill(pid, SIGTERM) }
                try? FileManager.default.removeItem(at: root)
            }
            func executable(_ name: String, _ text: String) throws -> URL {
                let url = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
                return url
            }
            let target = try executable(".tokenclock/normal/TokenClock", fail ? "#!/bin/sh\nexit 1\n" : "#!/bin/sh\necho $$ > '\(root.path)/target.pid'\nexec /bin/sleep 30\n")
            let source = try executable("source", "#!/bin/sh\necho $$ > '\(root.path)/source.pid'\nexec /bin/sleep 30\n")
            let defaults = try executable("defaults", "#!/bin/sh\necho \"$*\" >> '\(root.path)/defaults.log'\n")
            let launcher = try executable("launchctl", "#!/bin/sh\necho \"$*\" >> '\(root.path)/launchctl.log'\n")
            let stage = root.appendingPathComponent("stage")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: stage.appendingPathComponent("target.plist"))
            let resource = try XCTUnwrap(Bundle.module.url(forResource: "macos-variant-switch", withExtension: "sh"))
            var script = try String(contentsOf: resource, encoding: .utf8)
            // Redirect system mutations to fixture-only executors; no user jobs/defaults are touched.
            script = script.replacingOccurrences(of: "/bin/launchctl", with: "'\(launcher.path)'")
                .replacingOccurrences(of: "/usr/bin/defaults", with: "'\(defaults.path)'")
            let helper = try executable("helper", script)
            let old = Process()
            old.executableURL = URL(fileURLWithPath: "/usr/bin/true")
            try old.run(); old.waitUntilExit()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path, root.path, "glass", "normal", String(old.processIdentifier), source.path, "0", stage.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            let expectedPIDFile = root.appendingPathComponent(fail ? "source.pid" : "target.pid")
            for _ in 0..<20 where !FileManager.default.fileExists(atPath: expectedPIDFile.path) {
                Thread.sleep(forTimeInterval: 0.05)
            }
            for filename in ["target.pid", "source.pid"] {
                if let text = try? String(contentsOf: root.appendingPathComponent(filename), encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { ownedPIDs.append(pid) }
            }
            let written = try String(contentsOf: root.appendingPathComponent("defaults.log"), encoding: .utf8)
            if fail {
                XCTAssertNotEqual(process.terminationStatus, 0)
                XCTAssertTrue(written.contains("TC_preferredMacVariant -string glass"))
                XCTAssertTrue(written.contains("TC_macVariantSwitchFailure -string normal"))
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.pid").path))
            } else {
                XCTAssertEqual(process.terminationStatus, 0)
                XCTAssertTrue(written.contains("TC_preferredMacVariant -string normal"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launchctl.log").path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("target.pid").path))
            }
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.path))
        }
    }
}
#endif
