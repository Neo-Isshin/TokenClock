import Foundation
import Glibc

/// Linux 上的轻量 loopback HTTP 服务，保持 `/api/usage` 与 `/api/history` 兼容。
final class LinuxAPIServer: @unchecked Sendable {
    private let model: LinuxUsageModel
    private let port: UInt16
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.tokenclock.linux-api", qos: .utility)
    private let stateLock = NSLock()
    private var running = false

    init(model: LinuxUsageModel, port: UInt16 = AppConfig.LocalServer.defaultPort) {
        self.model = model
        self.port = port
    }

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.serve()
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        let fd = serverFD
        serverFD = -1
        stateLock.unlock()
        if fd >= 0 {
            _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
            _ = Glibc.close(fd)
        }
    }

    private func serve() {
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else {
            print("[API] Linux socket creation failed")
            return
        }

        stateLock.lock()
        serverFD = fd
        stateLock.unlock()

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Glibc.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            print("[API] Unable to bind 127.0.0.1:\(port)")
            _ = Glibc.close(fd)
            return
        }
        print("[API] Server ready on 127.0.0.1:\(port)")

        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if isRunning { continue }
                break
            }
            handle(client)
            _ = Glibc.close(client)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func handle(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = Glibc.read(client, &buffer, buffer.count)
        guard count > 0, let request = String(bytes: buffer.prefix(count), encoding: .utf8) else {
            return
        }
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            send(client, status: 405, object: ["error": "Method not allowed"])
            return
        }

        let rawTarget = String(parts[1])
        let targetParts = rawTarget.split(separator: "?", maxSplits: 1).map(String.init)
        let path = targetParts[0]
        let query = targetParts.count > 1 ? parseQuery(targetParts[1]) : [:]

        switch path {
        case "/api/usage", "/api/usage/":
            send(client, status: 200, object: model.usageJSONObject())
        case "/api/history", "/api/history/":
            guard query["days"].map({ Int($0) != nil }) ?? true else {
                send(client, status: 400, object: ["error": "Invalid 'days' value"])
                return
            }
            let days = query["days"].flatMap(Int.init) ?? AppConfig.History.retentionDays
            send(
                client,
                status: 200,
                object: model.historyJSONObject(
                    days: days,
                    includeSessions: query["detail"] == "sessions"
                )
            )
        default:
            send(client, status: 404, object: ["error": "Not found"])
        }
    }

    private func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }

    private func send(_ client: Int32, status: Int, object: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            return
        }
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")
        var response = Data(header.utf8)
        response.append(body)
        response.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Glibc.send(client, pointer, remaining, Int32(MSG_NOSIGNAL))
                if written <= 0 { break }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}
