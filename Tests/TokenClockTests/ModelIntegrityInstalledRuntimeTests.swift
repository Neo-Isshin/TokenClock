#if os(macOS)
import XCTest
import Foundation
import CryptoKit
@testable import TokenClock

/// Opt-in acceptance of a real, already-packaged signed runtime. This starts
/// only its loopback worker; no model request, browser, GUI or installer runs.
@MainActor
final class ModelIntegrityInstalledRuntimeTests: XCTestCase {
    private enum AcceptanceError: Error {
        case launcherFailed
        case localInfoUnavailable
        case unexpectedLocalResponse
        case workerDidNotStop
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func inventory(_ root: URL) throws -> Set<String> {
        guard let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw AcceptanceError.unexpectedLocalResponse
        }
        var paths = Set<String>()
        for case let file as URL in entries { paths.insert(file.path) }
        return paths
    }

    private func start(_ launcher: ModelIntegrityLauncher) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            launcher.start { result in
                switch result {
                case .success(let url): continuation.resume(returning: url)
                case .failure: continuation.resume(throwing: AcceptanceError.launcherFailed)
                }
            }
        }
    }

    private func info(_ url: URL, session: URLSession) async throws -> [String: Any] {
        do {
            let (data, response) = try await session.data(from: url.appendingPathComponent("api/info"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AcceptanceError.unexpectedLocalResponse
            }
            return value
        } catch {
            // URLSession errors can contain the ephemeral loopback URL token.
            // Keep it out of XCTest output even when acceptance fails.
            throw AcceptanceError.localInfoUnavailable
        }
    }

    func testSignedRuntimeCachesStartsWithoutMutationAndReusesPaths() async throws {
        guard let path = ProcessInfo.processInfo.environment["TOKENCLOCK_TEST_PACKAGED_WORKER"], !path.isEmpty else {
            throw XCTSkip("Set TOKENCLOCK_TEST_PACKAGED_WORKER for real packaged-runtime acceptance")
        }
        XCTAssertTrue(path.hasPrefix("/"), "Packaged worker must be an explicit absolute path")
        let sourceWorker = URL(fileURLWithPath: path)
        let sourceManifest = sourceWorker.deletingLastPathComponent().appendingPathComponent("runtime/runtime-manifest.json")
        let sourceManifestHash = try hash(sourceManifest)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceManifest)) as? [String: Any])
        let files = try XCTUnwrap(metadata["files"] as? [[String: Any]])
        XCTAssertGreaterThan(files.count, 1_000, "This opt-in test must use the real complete dependency package")
        let components = try XCTUnwrap(metadata["components"] as? [[String: Any]])
        let expectedPython = try XCTUnwrap(components.first { $0["name"] as? String == "CPython" }?["version"] as? String)
        let paths = try XCTUnwrap(metadata["paths"] as? [String: String])
        let pythonRelative = try XCTUnwrap(paths["python_path"])

        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tc-installed-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("cache-state")
        let first = try ModelIntegrityRuntimeCache.prepare(worker: sourceWorker, state: state)
        let runtime = try XCTUnwrap(first.runtime)
        XCTAssertNotEqual(first.worker, sourceWorker)
        XCTAssertEqual(try hash(runtime.appendingPathComponent("runtime-manifest.json")), sourceManifestHash)
        let before = try inventory(runtime)
        let temporary = root.appendingPathComponent("temporary")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let configuration = ModelIntegrityLaunchConfiguration(
            executableURL: runtime.appendingPathComponent(pythonRelative),
            arguments: ["-B", "-I", first.worker.path, "serve", "--state-dir", root.appendingPathComponent("worker-state").path],
            workingDirectory: first.worker.deletingLastPathComponent(),
            environment: ["PATH": "/usr/bin:/bin", "TMPDIR": temporary.path,
                          "PYTHONDONTWRITEBYTECODE": "1", "TOKENCLOCK_MODEL_INTEGRITY_RUNTIME": runtime.path])
        let launcher = ModelIntegrityLauncher(startupTimeout: 30, configurationProvider: { configuration })
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 1
        sessionConfiguration.timeoutIntervalForResource = 2
        sessionConfiguration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: sessionConfiguration)
        defer { launcher.stop(); session.invalidateAndCancel() }
        let baseURL = try await start(launcher)
        XCTAssertEqual(baseURL.host, "127.0.0.1")
        let response = try await info(baseURL, session: session)
        let capabilities = try XCTUnwrap(response["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["runtime_source"] as? String, "bundled")
        XCTAssertEqual(capabilities["python"] as? String, expectedPython)
        XCTAssertEqual(capabilities["platform"] as? String, "darwin")
        XCTAssertEqual(capabilities["architecture"] as? String, metadata["architecture"] as? String)
        XCTAssertEqual(response["external_default"] as? Bool, false)
        XCTAssertEqual(response["api_key_in_profile_json"] as? Bool, false)
        let workerMetadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sourceWorker.deletingLastPathComponent().appendingPathComponent("manifest.json"))) as? [String: Any])
        if (workerMetadata["files"] as? [[String: Any]])?.contains(where: { ($0["path"] as? String)?.hasSuffix("/reference_release.py") == true }) == true {
            let references = try XCTUnwrap(response["references"] as? [String: Any])
            XCTAssertEqual(references["status"] as? String, "verified")
            XCTAssertEqual(references["candidate_formal_enabled"] as? Bool, false)
            XCTAssertEqual(references["identity_accuracy_validated"] as? Bool, false)
            XCTAssertEqual((references["models"] as? [String])?.count, 6)
            XCTAssertEqual(references["original_behavior_answers"] as? Int, 548)
            if (workerMetadata["files"] as? [[String: Any]])?.contains(where: { ($0["path"] as? String)?.hasSuffix("/numeric_fingerprint.py") == true }) == true {
                XCTAssertEqual(references["external_numeric_enabled"] as? Bool, true)
                let numeric = try XCTUnwrap(references["external_numeric"] as? [String: Any])
                XCTAssertEqual(numeric["models"] as? Int, 59)
                XCTAssertEqual(numeric["local_independent_identity_validation"] as? Bool, false)
            }
        }

        launcher.stop()
        var stopped = false
        for _ in 0..<30 {
            do { _ = try await info(baseURL, session: session) }
            catch { stopped = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard stopped else { throw AcceptanceError.workerDidNotStop }
        let second = try ModelIntegrityRuntimeCache.prepare(worker: sourceWorker, state: state)
        XCTAssertEqual(first.worker, second.worker)
        XCTAssertEqual(first.runtime, second.runtime)
        let after = try inventory(runtime)
        XCTAssertTrue(before == after, "Worker startup must not add dependency files or bytecode")
        XCTAssertEqual(try hash(sourceManifest), sourceManifestHash)
        XCTAssertEqual(try hash(runtime.appendingPathComponent("runtime-manifest.json")), sourceManifestHash)
        // Deliberately print no ready URL, token, full file list or environment.
    }
}
#endif
