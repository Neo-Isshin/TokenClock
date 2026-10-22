#if os(macOS)
import XCTest
import Foundation
import CryptoKit
@testable import TokenClock

/// Small real filesystem fixtures only. No Python, model, browser, installer or
/// dependency executable is launched by these cache tests.
final class ModelIntegrityRuntimeCacheTests: XCTestCase {
    func testDigestUsesTheStandardSHA256HexEncoding() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tc-digest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try ModelIntegrityRuntimeCache.digest(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    private struct Fixture {
        let root: URL
        let source: URL
        let state: URL
        var worker: URL { source.appendingPathComponent("worker.py") }
        var archive: URL { source.appendingPathComponent("runtime.zip") }
        var manifest: URL { source.appendingPathComponent("manifest.json") }
        var runtime: URL { source.appendingPathComponent("runtime") }
        var runtimeManifest: URL { runtime.appendingPathComponent("runtime-manifest.json") }
        var python: URL { runtime.appendingPathComponent("python/bin/python3") }
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func archive(comment: String) -> Data {
        // Valid empty ZIP end-of-central-directory plus a bounded comment.
        let bytes = Array(comment.utf8)
        return Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 16)
            + [UInt8(bytes.count), 0] + bytes)
    }

    private func json(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url)
    }

    private func writeWorkerManifest(_ fixture: Fixture, hash: String? = nil) throws {
        try json(["schema": "tokenclock-l1-runtime-bundle/v1",
                  "runtime_sha256": hash ?? sha(Data(contentsOf: fixture.archive))], to: fixture.manifest)
    }

    private func writeRuntimeManifest(_ fixture: Fixture, hash: String? = nil) throws {
        let data = try Data(contentsOf: fixture.python)
        try json(["schema": "tokenclock-portable-runtime/v1", "platform": "darwin", "architecture": "arm64",
                  "paths": ["python_path": "python/bin/python3"],
                  "files": [["path": "python/bin/python3", "sha256": hash ?? sha(data), "bytes": data.count]]],
                 to: fixture.runtimeManifest)
    }

    private func fixture(portableRuntime: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("tc-runtime-cache-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let value = Fixture(root: root, source: root.appendingPathComponent("source"),
                            state: root.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: value.source, withIntermediateDirectories: true)
        try Data("# explicit cache fixture; never executed\n".utf8).write(to: value.worker)
        try archive(comment: "original").write(to: value.archive)
        try writeWorkerManifest(value)
        if portableRuntime {
            try FileManager.default.createDirectory(at: value.python.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not an executable; dependency bytes fixture\n".utf8).write(to: value.python)
            try writeRuntimeManifest(value)
        }
        return value
    }

    func testSourceZIPUpgradeDoesNotChangeAlreadyFrozenWorker() throws {
        let f = try fixture()
        let first = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        let frozenZIP = first.worker.deletingLastPathComponent().appendingPathComponent("runtime.zip")
        let original = try Data(contentsOf: frozenZIP)
        try archive(comment: "updated").write(to: f.archive)
        try writeWorkerManifest(f)
        let second = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        XCTAssertNotEqual(first.worker, second.worker)
        XCTAssertEqual(first.runtime, second.runtime, "Unchanged dependencies can be shared across worker versions")
        XCTAssertEqual(try Data(contentsOf: frozenZIP), original)
        XCTAssertNotEqual(try Data(contentsOf: f.archive), original)
    }

    func testSourceDependencyUpgradeLeavesOldSnapshotUnchanged() throws {
        let f = try fixture()
        let first = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        let oldRuntime = try XCTUnwrap(first.runtime)
        let original = try Data(contentsOf: oldRuntime.appendingPathComponent("python/bin/python3"))
        try Data("new dependency fixture\n".utf8).write(to: f.python)
        try writeRuntimeManifest(f)
        let second = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        XCTAssertEqual(first.worker, second.worker)
        XCTAssertNotEqual(first.runtime, second.runtime)
        XCTAssertEqual(try Data(contentsOf: oldRuntime.appendingPathComponent("python/bin/python3")), original)
    }

    func testIdenticalPrepareReusesPathsAndDoesNotRewriteFrozenFiles() throws {
        let f = try fixture()
        let first = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        let marker = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: first.worker.path)
        let second = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        XCTAssertEqual(first.worker, second.worker)
        XCTAssertEqual(first.runtime, second.runtime)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: second.worker.path)[.modificationDate] as? Date, marker)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.state.path)[.posixPermissions] as? NSNumber,
                       NSNumber(value: 0o700))
    }

    func testWrongZIPHashAndMalformedManifestAreRejected() throws {
        let f = try fixture()
        try writeWorkerManifest(f, hash: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
        try json(["runtime_sha256": "not-a-sha256"], to: f.manifest)
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
        try Data("[invalid json".utf8).write(to: f.manifest)
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
    }

    func testWrongDependencyFileHashIsRejectedBeforeUse() throws {
        let f = try fixture()
        try writeRuntimeManifest(f, hash: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state),
                             "Hashing the manifest file alone does not validate its declared dependency bytes")
    }

    func testChangedFrozenWorkerManifestIsRejectedOnReuse() throws {
        let f = try fixture()
        let frozen = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        try Data("{}".utf8).write(to: frozen.worker.deletingLastPathComponent().appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
    }

    func testChangedFrozenDependencyIsRejectedOnReuse() throws {
        let f = try fixture()
        let frozen = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        let runtime = try XCTUnwrap(frozen.runtime)
        try Data("changed independently of original dependency manifest\n".utf8)
            .write(to: runtime.appendingPathComponent("python/bin/python3"))
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
    }

    func testRuntimeLinkOutsidePackageIsRejected() throws {
        let f = try fixture()
        let outside = f.root.appendingPathComponent("outside-fixture")
        try Data("synthetic outside sentinel\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.runtime.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
    }

    func testRuntimeInternalRelativeLinkRemainsSupported() throws {
        let f = try fixture()
        try FileManager.default.createSymbolicLink(atPath: f.runtime.appendingPathComponent("python/bin/python-alias").path,
                                                   withDestinationPath: "python3")
        let frozen = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        let runtime = try XCTUnwrap(frozen.runtime)
        let alias = runtime.appendingPathComponent("python/bin/python-alias")
        XCTAssertEqual(try Data(contentsOf: alias), try Data(contentsOf: f.python))
        XCTAssertTrue(alias.resolvingSymlinksInPath().path.hasPrefix(runtime.resolvingSymlinksInPath().path + "/"))
    }

    func testRuntimeLinkInsertedIntoExistingCacheIsRejectedOnReuse() throws {
        let f = try fixture()
        let frozen = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        let runtime = try XCTUnwrap(frozen.runtime)
        let outside = f.root.appendingPathComponent("outside-cache-fixture")
        try Data("synthetic outside sentinel\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: runtime.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
    }

    func testSourceRuntimeDirectoryCannotBeAnExternalLink() throws {
        let f = try fixture()
        let moved = f.root.appendingPathComponent("external-runtime")
        try FileManager.default.moveItem(at: f.runtime, to: moved)
        try FileManager.default.createSymbolicLink(at: f.runtime, withDestinationURL: moved)
        XCTAssertThrowsError(try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state))
    }

    func testExplicitMockWorkerWithoutBundleMetadataKeepsOwnLocation() throws {
        let f = try fixture(portableRuntime: false)
        try FileManager.default.removeItem(at: f.manifest)
        try FileManager.default.removeItem(at: f.archive)
        let prepared = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        XCTAssertEqual(prepared.worker, f.worker)
        XCTAssertNil(prepared.runtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.state.appendingPathComponent("runtime-cache").path))
    }

    func testWorkerBundleWithoutPortableRuntimeStillFreezesWorkerCode() throws {
        let f = try fixture(portableRuntime: false)
        let prepared = try ModelIntegrityRuntimeCache.prepare(worker: f.worker, state: f.state)
        XCTAssertNotEqual(prepared.worker, f.worker)
        XCTAssertNil(prepared.runtime)
        XCTAssertEqual(try Data(contentsOf: prepared.worker), try Data(contentsOf: f.worker))
    }
}
#endif
