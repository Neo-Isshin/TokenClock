#if os(macOS)
import XCTest
@testable import TokenClock

final class MacAppRestartTests: XCTestCase {
    func testRealManagedRestartKeepsOneInstanceAndOriginalPlistWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_RESTART_TESTS"] == "1" else { throw XCTSkip("Opt-in disposable managed job") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-managed-restart-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let binary = root.appendingPathComponent("TokenClock"), log = root.appendingPathComponent("starts")
        try Data("#!/bin/sh\nprintf '%s\\n' $$ >> '\(log.path)'\nexec /bin/sleep 30\n".utf8).write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        let label = "com.tokenclock.fixture."+UUID().uuidString
        let helperLabel = MacAppRestart.jobPrefix+UUID().uuidString
        let domain = "gui/\(getuid())", service = domain+"/"+label
        func launchctl(_ args:[String]) throws -> Int32 {
            let p = Process(); p.executableURL=URL(fileURLWithPath:"/bin/launchctl");p.arguments=args
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
            try p.run();p.waitUntilExit();return p.terminationStatus
        }
        defer { _ = try? launchctl(["bootout",service]); _ = try? launchctl(["remove",helperLabel]) }
        let plist = root.appendingPathComponent("test.plist")
        let original = try PropertyListSerialization.data(fromPropertyList:["Label":label,"ProgramArguments":[binary.path],"RunAtLoad":false,"KeepAlive":false],format:.xml,options:0)
        try original.write(to:plist)
        XCTAssertEqual(try launchctl(["bootstrap",domain,plist.path]),0)
        XCTAssertEqual(try launchctl(["kickstart",service]),0)
        func starts() -> [String] { ((try? String(contentsOf:log,encoding:.utf8)) ?? "").split(separator:"\n").map(String.init) }
        var deadline = Date().addingTimeInterval(5)
        while starts().isEmpty,Date()<deadline { Thread.sleep(forTimeInterval:0.05) }
        let oldPID = try XCTUnwrap(starts().first.flatMap(Int32.init))
        try MacAppRestart.schedule(.init(executable:binary.path,sourcePID:oldPID,service:service,helperLabel:helperLabel,previousHelper:""))
        XCTAssertEqual(try launchctl(["kill","SIGTERM",service]),0)
        // launchd's default spawn throttle is 10 seconds for a just-started job.
        deadline=Date().addingTimeInterval(15)
        while starts().count<2,Date()<deadline { Thread.sleep(forTimeInterval:0.05) }
        XCTAssertEqual(starts().count,2)
        XCTAssertNotEqual(starts().last,starts().first)
        XCTAssertEqual(try Data(contentsOf:plist),original)
    }
    func testRealDetachedLauncherWithDisposableProcessWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["TOKENCLOCK_RUN_RESTART_TESTS"] == "1" else {
            throw XCTSkip("Opt in to a disposable launchd helper; never restarts the user's clock")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-restart-live-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let binary = root.appendingPathComponent("TokenClock")
        let marker = root.appendingPathComponent("started")
        try Data("#!/bin/sh\nprintf 'started' > '\(marker.path)'\nexec /bin/sleep 30\n".utf8).write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        let old = Process(); old.executableURL = URL(fileURLWithPath:"/usr/bin/true"); try old.run(); old.waitUntilExit()
        let plan = try MacAppRestart.plan(executable:binary.path,pid:old.processIdentifier,variant:nil,home:root)
        defer {
            let cleanup = Process(); cleanup.executableURL = URL(fileURLWithPath:"/bin/launchctl")
            cleanup.arguments = ["remove",plan.helperLabel]
            cleanup.standardError = FileHandle.nullDevice; cleanup.standardOutput = FileHandle.nullDevice
            try? cleanup.run(); cleanup.waitUntilExit()
        }
        try MacAppRestart.schedule(plan)
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath:marker.path), Date() < deadline { Thread.sleep(forTimeInterval:0.05) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("Library/LaunchAgents").path))
    }
    func testArgumentsDoNotInterpolatePathsAndOnlyExactOwnedServiceIsUsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-restart-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let binary = root.appendingPathComponent("a 'quoted' $literal/TokenClock")
        try FileManager.default.createDirectory(at:binary.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        let agents = root.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at:agents,withIntermediateDirectories:true)
        let plist = agents.appendingPathComponent("com.tokenclock.app.glass.plist")
        try PropertyListSerialization.data(fromPropertyList:["Label":"com.tokenclock.app.glass","ProgramArguments":[binary.path],"RunAtLoad":false],format:.xml,options:0).write(to:plist)
        let original = try Data(contentsOf:plist)
        let plan = try MacAppRestart.plan(executable:binary.path,pid:123,variant:.glass,home:root,previousHelper:"com.some.other.job")
        XCTAssertEqual(plan.service,"gui/\(getuid())/com.tokenclock.app.glass")
        XCTAssertEqual(plan.previousHelper,"")
        let args = MacAppRestart.arguments(plan)
        XCTAssertTrue(args.contains(binary.path))
        XCTAssertFalse(MacAppRestart.script.contains(binary.path))
        XCTAssertFalse(MacAppRestart.script.contains("kickstart -k"))
        XCTAssertEqual(try Data(contentsOf:plist),original)
        let unmanaged = try MacAppRestart.plan(executable:binary.path,pid:123,variant:.normal,home:root)
        XCTAssertEqual(unmanaged.service,"")
    }

    func testHelperWaitsForOldPIDAndDoesNotLaunchDuplicate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-restart-wait-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let marker = root.appendingPathComponent("started")
        let binary = root.appendingPathComponent("TokenClock")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to:binary)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:binary.path)
        let old = Process(); old.executableURL = URL(fileURLWithPath:"/bin/sleep"); old.arguments = ["30"]
        try old.run()
        defer { if old.isRunning { old.terminate(); old.waitUntilExit() } }
        let script = MacAppRestart.script.replacingOccurrences(of:"task_attempt<100",with:"task_attempt<2")
            .replacingOccurrences(of:"/bin/launchctl",with:"/usr/bin/true")
        let helper = Process(); helper.executableURL = URL(fileURLWithPath:"/bin/bash")
        helper.arguments = ["-c",script,"test",String(old.processIdentifier),binary.path,"","test-helper",""]
        try helper.run(); helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus,1)
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }

    func testManagedHelperUsesExistingJobWithoutChangingStartupPlist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-restart-job-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = root.appendingPathComponent("launchctl")
        let log = root.appendingPathComponent("calls")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\nexit 0\n".utf8).write(to:recorder)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:recorder.path)
        let old = Process(); old.executableURL = URL(fileURLWithPath:"/usr/bin/true"); try old.run(); old.waitUntilExit()
        let helper = Process(); helper.executableURL = URL(fileURLWithPath:"/bin/bash")
        helper.arguments = ["-c",MacAppRestart.script.replacingOccurrences(of:"/bin/launchctl",with:"'\(recorder.path)'"),
                            "test",String(old.processIdentifier),"/not-used","gui/123/owned-job","own-helper",""]
        try helper.run(); helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus,0)
        let calls = try String(contentsOf:log,encoding:.utf8)
        XCTAssertTrue(calls.contains("kickstart gui/123/owned-job"))
        XCTAssertFalse(calls.contains("bootstrap"))
        XCTAssertFalse(calls.contains("enable"))
    }
}
#endif
