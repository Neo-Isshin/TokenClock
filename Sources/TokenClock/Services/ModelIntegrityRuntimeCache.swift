#if os(macOS)
import Foundation
import CryptoKit

/// Running workers use immutable snapshots so an app/resource upgrade cannot
/// replace a ZIP or interpreter underneath an already-running local task.
enum ModelIntegrityRuntimeCache {
    struct Prepared { let worker: URL; let runtime: URL? }
    enum CacheError: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let detail) = self { return detail }; return nil }
    }

    static func digest(_ url: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func privateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CacheError.invalid("Invalid model detection cache directory") }
        } else { try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func installDirectory(_ destination: URL, copy: (URL) throws -> Void) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { return }
        try privateDirectory(destination.deletingLastPathComponent())
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".staging-" + UUID().uuidString)
        try privateDirectory(staging)
        defer { try? manager.removeItem(at: staging) }
        try copy(staging)
        do { try manager.moveItem(at: staging, to: destination) }
        catch { if !manager.fileExists(atPath: destination.path) { throw error } }
    }

    private static func verifyDependencies(_ runtime: URL, manifestHash: String) throws {
        let manager = FileManager.default
        let flags = try runtime.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard flags.isDirectory == true, flags.isSymbolicLink != true else { throw CacheError.invalid("Invalid cached runtime directory") }
        let manifest = runtime.appendingPathComponent("runtime-manifest.json")
        guard try digest(manifest) == manifestHash,
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any],
              let files = object["files"] as? [[String: Any]], files.count <= 40_000 else { throw CacheError.invalid("Invalid runtime file manifest") }
        var expected = Set<String>()
        for row in files {
            guard let path = row["path"] as? String, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
                  !path.split(separator: "/").contains(".."), expected.insert(path).inserted,
                  let hash = row["sha256"] as? String, hash.count == 64 else { throw CacheError.invalid("Invalid runtime file binding") }
            let file = runtime.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/"),
                  try digest(file) == hash else { throw CacheError.invalid("Runtime dependency verification failed") }
        }
        guard let entries = manager.enumerator(at: runtime, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { throw CacheError.invalid("Cannot inspect runtime files") }
        for case let file as URL in entries {
            let info = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if info.isSymbolicLink == true {
                guard file.resolvingSymlinksInPath().path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/") else { throw CacheError.invalid("Runtime link escapes its package") }
            } else if info.isRegularFile == true {
                let relative = String(file.resolvingSymlinksInPath().path.dropFirst(runtime.resolvingSymlinksInPath().path.count + 1))
                guard relative == "runtime-manifest.json" || expected.contains(relative) else { throw CacheError.invalid("Unrecorded runtime dependency file") }
            }
        }
    }

    static func prepare(worker: URL, state: URL) throws -> Prepared {
        let manager = FileManager.default, source = worker.deletingLastPathComponent()
        let manifest = source.appendingPathComponent("manifest.json"), archive = source.appendingPathComponent("runtime.zip")
        // Explicit development/mock worker overrides retain their own contract.
        guard manager.fileExists(atPath: manifest.path), manager.fileExists(atPath: archive.path) else { return Prepared(worker: worker, runtime: nil) }
        let metadata = try Data(contentsOf: manifest)
        guard metadata.count <= 4_194_304,
              let value = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let expected = value["runtime_sha256"] as? String,
              expected.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
              try digest(archive) == expected else { throw CacheError.invalid("Model detection runtime archive verification failed") }
        try privateDirectory(state)
        let cache = state.appendingPathComponent("runtime-cache")
        try privateDirectory(cache)
        let workerHash = try digest(worker)
        let manifestHash = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        let version = cache.appendingPathComponent("workers/" + expected + "-" + workerHash.prefix(16) + "-" + manifestHash.prefix(16))
        try installDirectory(version) { stage in
            let folder = stage.appendingPathComponent("model-integrity-worker")
            try privateDirectory(folder)
            for name in ["worker.py", "runtime.zip", "manifest.json"] { try manager.copyItem(at: source.appendingPathComponent(name), to: folder.appendingPathComponent(name)) }
        }
        let frozen = version.appendingPathComponent("model-integrity-worker")
        guard try digest(frozen.appendingPathComponent("runtime.zip")) == expected,
              try digest(frozen.appendingPathComponent("worker.py")) == workerHash,
              try digest(frozen.appendingPathComponent("manifest.json")) == manifestHash else { throw CacheError.invalid("Cached model detection worker verification failed") }
        let originalRuntime = source.appendingPathComponent("runtime")
        let runtimeManifest = originalRuntime.appendingPathComponent("runtime-manifest.json")
        guard manager.fileExists(atPath: runtimeManifest.path) else { return Prepared(worker: frozen.appendingPathComponent("worker.py"), runtime: nil) }
        let dependencyHash = try digest(runtimeManifest)
        let runtimeCache = cache.appendingPathComponent("dependencies/" + dependencyHash)
        try installDirectory(runtimeCache) { stage in
            let target = stage.appendingPathComponent("runtime")
            try manager.copyItem(at: originalRuntime, to: target)
            // Verification uses resolved filesystem paths, including macOS's
            // /var → /private/var alias, without allowing links out of the root.
            try verifyDependencies(target, manifestHash: dependencyHash)
        }
        let runtime = runtimeCache.appendingPathComponent("runtime")
        try verifyDependencies(runtime, manifestHash: dependencyHash)
        return Prepared(worker: frozen.appendingPathComponent("worker.py"), runtime: runtime)
    }
}
#endif
