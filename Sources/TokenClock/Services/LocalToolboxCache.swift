#if os(macOS)
import Foundation
import CryptoKit

struct LocalToolboxSnapshot: Codable {
    var checkedAt: Date
    var findings: [LocalFinding]
    var files: [LocalLogFile]
    var keys: [APIProbeResult]
}
struct LocalToolboxResults: Codable {
    var selectedMode: String
    var snapshots: [String: LocalToolboxSnapshot]
}
enum LocalToolboxPersistence {
    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(value)
        // Set permissions on the temporary file before replacing the previous snapshot.
        let temporary = parent.appendingPathComponent(".toolbox-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary, options: .usingNewMetadataOnly) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
}

/// File-level incremental scan. No log bytes, matching text, or custom regex is persisted.
enum LocalSecretCache {
    struct Stamp: Codable, Equatable {
        let size: Int64
        let modified: Date
        let identity: String
        init(_ file: LocalLogFile) { size = file.size; modified = file.modified; identity = file.fileID }
        static func current(_ path: String) -> Stamp? {
            guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]),
                  v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, let modified = v.contentModificationDate else { return nil }
            return Stamp(.init(tool: "", path: path, size: Int64(size), modified: modified, fileID: String(describing: v.fileResourceIdentifier)))
        }
    }
    struct Record: Codable { let stamp: Stamp; let findings: [LocalFinding] }
    struct Cache: Codable { let rules: String; var records: [String: Record] }
    struct Result { var findings: [LocalFinding]; var scanned: Int; var reused: Int }
    static func scan(files: [LocalLogFile], pattern: String, full: Bool, url: URL, cancelled: @Sendable () -> Bool) -> Result {
        let invalid = LocalLogScanner.leaks(files: [], pattern: pattern, cancelled: cancelled)
        if !invalid.isEmpty { return Result(findings: invalid, scanned: 0, reused: 0) }
        let rules = SHA256.hash(data: Data(("secrets-v2:" + pattern).utf8)).map { String(format: "%02x", $0) }.joined()
        let previous = full ? nil : (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        var cache = Cache(rules: rules, records: [:]), output = Result(findings: [], scanned: 0, reused: 0)
        for file in files {
            if cancelled() { return output }
            let ext = URL(fileURLWithPath: file.path).pathExtension.lowercased()
            guard ["jsonl", "log", "json"].contains(ext), ext != "json" || ["/sessions/", "/projects/", "/tasks/", "/logs/"].contains(where: { file.path.contains($0) }) else { continue }
            if output.findings.count >= 2000 {
                output.findings.append(.init(title: "结果已截断", detail: "达到 2000 条，请按工具缩小扫描范围")); break
            }
            let stamp = Stamp(file)
            if previous?.rules == rules, let old = previous?.records[file.path], old.stamp == stamp, Stamp.current(file.path) == stamp {
                output.findings += old.findings; output.reused += 1; cache.records[file.path] = old
            } else {
                let findings = LocalLogScanner.leaks(files: [file], pattern: pattern, cancelled: cancelled)
                output.scanned += 1; output.findings += findings
                // A partial/unreadable/changed file must be retried on the next incremental scan.
                if !cancelled(), findings.count < 2000, findings.allSatisfy({ $0.title.hasPrefix("疑似密钥") }), Stamp.current(file.path) == stamp {
                    cache.records[file.path] = .init(stamp: stamp, findings: findings)
                }
            }
        }
        if !cancelled() { try? LocalToolboxPersistence.save(cache, to: url) }
        return output
    }
}
#endif
