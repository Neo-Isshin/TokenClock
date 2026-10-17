import Foundation

/// Only inspects running Antigravity language servers owned by the current user.
/// Command lines and CSRF tokens remain in memory; none are logged or persisted.
enum AntigravityLocalEndpointDiscovery {
    struct Endpoint: Equatable {
        let port: Int
        let csrfToken: String
    }

    static func discover() -> [Endpoint] {
        #if os(Windows)
        let script = #"$ErrorActionPreference='SilentlyContinue'; $session=(Get-Process -Id $PID).SessionId; $rows=@(Get-CimInstance Win32_Process -Filter "Name LIKE 'language_server%'" | Where-Object { $_.SessionId -eq $session -and $_.ExecutablePath -match '(?i)[\\/](Antigravity|Antigravity IDE)[\\/]' } | ForEach-Object { $p=$_; $ports=@(Get-NetTCPConnection -State Listen -OwningProcess $p.ProcessId | Select-Object -ExpandProperty LocalPort -Unique); [pscustomobject]@{command=$p.CommandLine; ports=$ports} }); ConvertTo-Json -InputObject $rows -Compress"#
        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:/Windows"
        guard let data = run([systemRoot + "/System32/WindowsPowerShell/v1.0/powershell.exe"],
                             ["-NoProfile", "-NonInteractive", "-Command", script]),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.flatMap { row in
            endpoints(command: row["command"] as? String ?? "", ports: (row["ports"] as? [Int]) ?? [])
        }
        #else
        guard let data = run(["/bin/ps", "/usr/bin/ps"], ["-x", "-o", "pid=,comm="]),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let processes = text.split(separator: "\n").compactMap { line -> Int? in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let pid = Int(parts[0]), pid > 0 else { return nil }
            #if os(Linux)
            // Linux ps comm is a truncated basename, not an executable path.
            guard let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe"),
                  isAntigravityServer(executable) else { return nil }
            #else
            guard isAntigravityServer(String(parts[1])) else { return nil }
            #endif
            return pid
        }
        var result: [Endpoint] = []
        for pid in processes.sorted(by: >).prefix(4) {
            guard let commandData = run(["/bin/ps", "/usr/bin/ps"], ["-p", String(pid), "-o", "args="]),
                  let command = String(data: commandData, encoding: .utf8) else { continue }
            var ports: [Int] = []
            if let listeners = run(["/usr/sbin/lsof", "/usr/bin/lsof"],
                    ["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-Fn"]),
               let output = String(data: listeners, encoding: .utf8) {
                ports = listeningPorts(output)
            }
            #if os(Linux)
            if ports.isEmpty, let listeners = run(["/usr/bin/ss", "/bin/ss"], ["-ltnpH"]),
               let output = String(data: listeners, encoding: .utf8) {
                for line in output.split(separator: "\n") where line.contains("pid=\(pid),") {
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    if parts.count > 3, let port = parts[3].split(separator: ":").last.flatMap({ Int($0) }) {
                        ports.append(port)
                    }
                }
            }
            #endif
            // Explicit nonzero HTTPS flags also work where lsof/ss are unavailable.
            if let port = capture(#"(?:^|\s)--https_server_port(?:=|\s+)([0-9]+)(?:\s|$)"#, command).flatMap(Int.init), port > 0 {
                ports.insert(port, at: 0)
            }
            result += endpoints(command: command, ports: ports)
        }
        return result
        #endif
    }

    static func isAntigravityServer(_ executable: String) -> Bool {
        let path = executable.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard URL(fileURLWithPath: path).lastPathComponent.hasPrefix("language_server") else { return false }
        return path.contains("/antigravity.app/contents/") || path.contains("/antigravity ide.app/contents/")
            || path.contains("/antigravity/") || path.contains("/antigravity ide/") || path.contains("/google.antigravity/")
    }

    static func endpoints(command: String, ports: [Int]) -> [Endpoint] {
        let pattern = #"(?:^|\s)--csrf_token(?:=|\s+)(?:"([^"\r\n]+)"|'([^'\r\n]+)'|([^\s"']+))"#
        guard let token = capture(pattern, command), !token.isEmpty, token.utf8.count <= 4096,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return [] }
        var seen = Set<Int>()
        return ports.filter { (1...65_535).contains($0) && seen.insert($0).inserted }
            .map { Endpoint(port: $0, csrfToken: token) }
    }

    static func listeningPorts(_ output: String) -> [Int] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("n"), let value = line.split(separator: ":").last,
                  let port = Int(value), (1...65_535).contains(port) else { return nil }
            return port
        }
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for index in 1..<match.numberOfRanges {
            if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
        }
        return nil
    }

    private static func run(_ executables: [String], _ arguments: [String]) -> Data? {
        guard let executable = executables.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6) {
                if process.isRunning { process.terminate() }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }
}
