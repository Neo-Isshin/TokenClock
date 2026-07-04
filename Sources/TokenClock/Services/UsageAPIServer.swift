import Foundation
import Network

/// 本地 HTTP API 服务器：提供工具 token 消耗数据
/// 监听端口默认 9988，端点 GET /api/usage 返回 JSON
final class UsageAPIServer: @unchecked Sendable {
    static let shared = UsageAPIServer()
    private var listener: NWListener?
    private var port: NWEndpoint.Port
    private weak var viewModel: ViewModel?

    var isRunning: Bool { listener?.state == .ready }

    init(port: UInt16 = AppConfig.LocalServer.defaultPort) {
        self.port = NWEndpoint.Port(integerLiteral: port)
    }

    /// 在 start() 之前覆盖监听端口。start() 之后调用无效。
    /// 选这个最小侵入方案，避免改变现有 `start()` 签名。
    func configure(port: UInt16) {
        self.port = NWEndpoint.Port(integerLiteral: port)
    }

    func bind(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        guard listener == nil else { return }
        do {
            // 仅绑定回环地址(127.0.0.1),防止局域网访问(LAN-exposed)
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
            listener = try NWListener(using: params, on: port)
        } catch {
            print("[API] Failed to create listener: \(error)")
            return
        }

        let port = self.port
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[API] Server ready on port \(port)")
            case .failed(let err):
                print("[API] Server failed: \(err)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global())
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - nonisolated 网络处理（在后台队列执行）

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("[API] Connection failed: \(error)")
            }
        }
        connection.start(queue: .global())

        receiveHTTPRequest(connection)
    }

    private func receiveHTTPRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                print("[API] Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = data,
                  let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let parsed = self.extractPathAndQuery(from: request)
            let path = parsed.path
            let query = parsed.query
            if path == "/api/usage" || path == "/api/usage/" {
                self.sendUsageJSON(connection)
            } else if path == "/api/history" || path == "/api/history/" {
                self.sendHistoryJSON(connection, query: query)
            } else {
                self.send404(connection)
            }

            if !isComplete {
                self.receiveHTTPRequest(connection)
            }
        }
    }

    /// 解析 "GET /path?key=value HTTP/1.1" 形式,返回 (path, query dict)
    private func extractPathAndQuery(from request: String) -> (path: String, query: [String: String]) {
        let firstLine = request.split(separator: "\r\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return ("", [:]) }
        let raw = parts[1]
        let split = raw.split(separator: "?", maxSplits: 1).map(String.init)
        let path = split[0]
        var query: [String: String] = [:]
        if split.count > 1 {
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard kv.count == 2 else { continue }
                query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            }
        }
        return (path, query)
    }

    private func sendUsageJSON(_ connection: NWConnection) {
        Task { @MainActor in
            guard let vm = self.viewModel else {
                self.sendJSON(connection, status: 503, body: ["error": "Service unavailable"])
                return
            }

            let toolsData = vm.tools.map { tool -> [String: Any] in
                var dict: [String: Any] = [
                    "name": tool.name,
                    "emoji": tool.emoji,
                    "todayTokens": tool.todayTokens,
                    "todayMessages": tool.todayMessages,
                    "isActive": tool.isActive,
                    "cacheRate": tool.cacheRate,
                    "recentTokens": tool.recentTokens,
                    "hourlyTokens": tool.hourlyTokens,
                ]
                if !tool.sessions.isEmpty {
                    dict["sessions"] = tool.sessions.map { session -> [String: Any] in
                        [
                            "id": session.rawId,
                            "displayName": session.displayName,
                            "todayTokens": session.todayTokens,
                            "todayMessages": session.todayMessages,
                            "isActive": session.isActive,
                        ]
                    }
                }
                return dict
            }

            let body: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "totalTokens": UsageAggregator.totalTokens(vm.tools),
                "totalMessages": UsageAggregator.totalMessages(vm.tools),
                "rateEmoji": UsageAggregator.rateEmoji(vm.tools),
                "windowMinutes": vm.rateWindowMinutes,
                "theme": vm.selectedTheme.rawValue,
                "weather": [
                    "city": vm.weather.cityName,
                    "temperature": vm.weather.temperature,
                    "emoji": vm.weather.emoji,
                ],
                "tools": toolsData,
            ]

            self.sendJSON(connection, status: 200, body: body)
        }
    }

    private func sendHistoryJSON(_ connection: NWConnection, query: [String: String]) {
        // 解析 days 参数:clamp 到 [1, AppConfig.History.retentionDays]
        // 给了非数字 → 400;给负数/0 → clamp 到 1(避免误报错)
        let maxDays = AppConfig.History.retentionDays
        let requested: Int
        if let raw = query["days"] {
            guard let v = Int(raw) else {
                self.sendJSON(connection, status: 400, body: [
                    "error": "Invalid 'days' value: \(raw). Expected integer."
                ])
                return
            }
            requested = v
        } else {
            requested = maxDays
        }
        let days = min(maxDays, max(1, requested))

        // 查 DB 拿真实存在的快照
        let snapshots = HistoryStore.shared.queryRecent(days: days)

        // 补 0:连续 N 天,缺数据日填 0
        let cal = Calendar.current
        var padded: [[String: Any]] = []
        for offset in 0..<days {
            guard let d = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let key = DateHelper.dateKey(from: d)
            if let snap = snapshots.first(where: { $0.date == key }) {
                padded.append([
                    "date": snap.date,
                    "totalTokens": snap.totalTokens,
                    "totalMessages": snap.totalMessages,
                    "tools": snap.tools.map { t -> [String: Any] in
                        [
                            "name": t.name,
                            "tokens": t.tokens,
                            "messages": t.messages,
                            "cacheRate": t.cacheRate,
                            "isActive": t.isActive,
                        ]
                    },
                ])
            } else {
                padded.append([
                    "date": key,
                    "totalTokens": 0,
                    "totalMessages": 0,
                    "tools": [],
                ])
            }
        }

        let body: [String: Any] = [
            "windowDays": days,
            "days": padded,
        ]
        self.sendJSON(connection, status: 200, body: body)
    }

    private func sendJSON(_ connection: NWConnection, status: Int, body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted) else {
            connection.cancel()
            return
        }
        let statusLine = "HTTP/1.1 \(status) \(statusText(status))"
        let headers = [
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(data.count)",
            "Connection: keep-alive",
        ]
        let response = ([statusLine] + headers + ["", ""]).joined(separator: "\r\n").data(using: .utf8)! + data
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func send404(_ connection: NWConnection) {
        let body = Data("{\"error\":\"Not Found\"}".utf8)
        let response = """
            HTTP/1.1 404 Not Found\r\
            Content-Type: application/json\r\
            Content-Length: \(body.count)\r\
            Connection: close\r\n\r\n
            """.data(using: .utf8)! + body
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}
