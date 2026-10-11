import Foundation

enum HarnessSourceDetection {
    static func results() -> [PathDetector.DetectionResult] {
        AdditionalHarness.allCases.map { harness in
            let roots = harness.roots()
            let files = HarnessUsageService.sourceFiles(roots: roots, harness: harness)
            let exists = !files.isEmpty
            let root = roots.first { path in files.contains { $0.hasPrefix(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) } } ?? roots.first ?? ""
            let custom = UserDefaults.standard.string(for: harness.pathKey)?.isEmpty == false
            let detail = harness.limitation ?? (exists ? root : "No local usage records found")
            #if os(Linux)
            return PathDetector.DetectionResult(service: harness.rawValue, emoji: harness.emoji, detectedPath: root,
                isDefault: !custom, catalogDeclared: true, pathExists: FileManager.default.fileExists(atPath: root),
                parserReadable: exists, source: custom ? .userDefaults : (exists ? .officialDefault : .notFound), detail: detail)
            #elseif os(Windows)
            return PathDetector.DetectionResult(service: harness.rawValue, emoji: harness.emoji, detectedPath: root,
                isDefault: !custom, pathExists: FileManager.default.fileExists(atPath: root), sourceAvailable: exists,
                contractReadable: exists, parserReadable: exists,
                source: custom ? .userDefaults : (exists ? .officialDefault : .notFound), detail: detail)
            #else
            return PathDetector.DetectionResult(service: harness.rawValue, emoji: harness.emoji, detectedPath: root,
                isDefault: !custom, exists: exists, source: custom ? .userDefaults : (exists ? .officialDefault : .notFound), detail: detail)
            #endif
        }
    }
}
