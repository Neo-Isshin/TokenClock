#if os(macOS)
import Foundation

/// A launchd-owned one-shot helper survives the current app's process-group
/// shutdown. Wait for graceful termination before starting exactly this binary.
enum MacAppRestart {
    static let jobPrefix = "com.tokenclock.restart."
    struct Plan: Sendable {
        let executable: String
        let sourcePID: Int32
        let service: String
        let helperLabel: String
        let previousHelper: String
        var sourceArguments: [String] = []
    }
    struct Failure: Error {}

    static func plan(executable: String, pid: Int32, variant: LaunchAgentHelper.Variant?,
                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     previousHelper: String? = ProcessInfo.processInfo.environment["TC_RESTART_HELPER"],
                     sourceArguments: [String] = []) throws -> Plan {
        guard (executable as NSString).isAbsolutePath, pid > 1,
              FileManager.default.isExecutableFile(atPath: executable) else { throw Failure() }
        var service = ""
        if let variant {
            let plist = home.appendingPathComponent("Library/LaunchAgents/" + variant.label + ".plist")
            if let data = try? Data(contentsOf: plist),
               let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               object["Label"] as? String == variant.label,
               (object["ProgramArguments"] as? [String]) == [executable] + sourceArguments {
                service = "gui/\(getuid())/" + variant.label
            }
        }
        let previous = previousHelper.flatMap { value in
            value.hasPrefix(jobPrefix) && UUID(uuidString: String(value.dropFirst(jobPrefix.count))) != nil ? value : nil
        } ?? ""
        return Plan(executable: executable, sourcePID: pid, service: service,
                    helperLabel: jobPrefix + UUID().uuidString, previousHelper: previous, sourceArguments: sourceArguments)
    }

    static func schedule(_ plan: Plan) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments(plan)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure() }
    }

    static func arguments(_ plan: Plan) -> [String] {
        ["submit", "-l", plan.helperLabel, "--", "/bin/bash", "-c", script, "TokenClock-restart",
         String(plan.sourcePID), plan.executable, plan.service, plan.helperLabel, plan.previousHelper] + plan.sourceArguments
    }

    // All variable data travels as argv, never interpolated into shell source.
    static let script = #"""
    set -eu
    task_pid="$1"
    task_binary="$2"
    task_service="$3"
    task_helper="$4"
    task_previous="$5"
    for ((task_attempt=0; task_attempt<100; task_attempt++)); do
      kill -0 "$task_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$task_pid" 2>/dev/null; then
      /bin/launchctl remove "$task_helper" 2>/dev/null || true
      exit 1
    fi
    if [ -n "$task_previous" ]; then
      /bin/launchctl remove "$task_previous" 2>/dev/null || true
    fi
    if [ -n "$task_service" ] && /bin/launchctl print "$task_service" >/dev/null 2>&1; then
      # No -k: an already respawned instance must not be killed/restarted twice.
      /bin/launchctl kickstart "$task_service"
      /bin/launchctl remove "$task_helper" 2>/dev/null || true
    else
      # A manually launched app stays non-autostarting. No persistent plist is written.
      export TC_RESTART_HELPER="$task_helper"
      shift 5
      exec "$task_binary" "$@"
    fi
    """#
}
#endif
