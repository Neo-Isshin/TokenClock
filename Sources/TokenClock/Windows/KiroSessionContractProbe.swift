#if os(Windows)
import Foundation

/// Validates only Kiro's documented two-file session storage contract. It does not inspect
/// undocumented event fields and therefore cannot manufacture token/request totals.
enum KiroSessionContractProbe {
    static func isReadable(at sessionsPath: String) -> Bool {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: sessionsPath, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? manager.contentsOfDirectory(atPath: sessionsPath) else { return false }

        let identifiers = Set(names.compactMap { name -> String? in
            guard (name as NSString).pathExtension.lowercased() == "json" else { return nil }
            return (name as NSString).deletingPathExtension
        })
        for identifier in identifiers.prefix(32) {
            let metadataPath = sessionsPath + "/" + identifier + ".json"
            let eventsPath = sessionsPath + "/" + identifier + ".jsonl"
            guard readableJSONObject(at: metadataPath), readableJSONLine(at: eventsPath) else { continue }
            return true
        }
        return false
    }

    private static func readableJSONObject(at path: String) -> Bool {
        guard let data = boundedData(at: path, maximumBytes: 2 * 1_024 * 1_024),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return object is [String: Any]
    }

    private static func readableJSONLine(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 512 * 1_024), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return false }
        for line in text.split(whereSeparator: \.isNewline).prefix(200) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            if object is [String: Any] { return true }
        }
        return false
    }

    private static func boundedData(at path: String, maximumBytes: Int) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= maximumBytes else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    }
}
#endif
