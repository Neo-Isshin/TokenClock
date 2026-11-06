#if os(Linux)
  import Foundation

  enum LinuxAppRestart {
    struct InvalidPlan: Error {}
    static func schedule(executable: String, oldPID: Int32, arguments: [String] = []) throws {
      guard executable.hasPrefix("/"), oldPID > 1,
        FileManager.default.isExecutableFile(atPath: executable)
      else { throw InvalidPlan() }
      let helper = Process()
      helper.executableURL = URL(fileURLWithPath: "/bin/sh")
      helper.arguments =
        [
          "-c",
          #"pid="$1"; shift; n=0; while kill -0 "$pid" 2>/dev/null; do n=$((n+1)); [ "$n" -lt 200 ] || exit 75; sleep 0.1; done; exec "$@""#,
          "TokenClockRestart", String(oldPID), executable,
        ] + arguments
      helper.standardInput = FileHandle.nullDevice
      helper.standardOutput = FileHandle.nullDevice
      helper.standardError = FileHandle.nullDevice
      try helper.run()
    }
  }
#endif
