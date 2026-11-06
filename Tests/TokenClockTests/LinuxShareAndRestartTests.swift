#if os(Linux)
  import XCTest
  import Foundation
  import CGtk
  @testable import TokenClock

  final class LinuxShareAndRestartTests: XCTestCase {
    func testShareExportsRealArtworkAndChangingItChangesTheImage() throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let renderer = LinuxUsageShareRenderer()
      let data = UsageShareBuilder.load(date: Date(timeIntervalSince1970: 0))
      let first = folder.appendingPathComponent("first.png")
      let second = folder.appendingPathComponent("second.png")
      XCTAssertTrue(renderer.writePNG(data: data, to: first.path))
      renderer.nextArtwork()
      XCTAssertTrue(renderer.writePNG(data: data, to: second.path))
      let a = try Data(contentsOf: first)
      let b = try Data(contentsOf: second)
      XCTAssertEqual(Array(a.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
      XCTAssertNotEqual(a, b)
      func dimension(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { ($0 << 8) | UInt32(a[offset + $1]) }
      }
      XCTAssertEqual(dimension(16), 1200)
      XCTAssertEqual(dimension(20), 1500)
    }
    func testRestartHelperWaitsForOnlyTheOwnedDisposableProcess() async throws {
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: folder) }
      let script = folder.appendingPathComponent("restart.sh")
      let marker = folder.appendingPathComponent("marker")
      try Data("#!/bin/sh\nprintf 'once\\n' >> \"$1\"\n".utf8).write(to: script)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/bin/sleep")
      child.arguments = ["0.3"]
      try child.run()
      try LinuxAppRestart.schedule(
        executable: script.path, oldPID: child.processIdentifier, arguments: [marker.path])
      XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
      child.waitUntilExit()
      for _ in 0..<40 {
        if FileManager.default.fileExists(atPath: marker.path) { break }
        try await Task.sleep(nanoseconds: 50_000_000)
      }
      XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "once\n")
      XCTAssertThrowsError(try LinuxAppRestart.schedule(executable: "relative", oldPID: 1))
    }
  }
#endif
