import Foundation
import Network

/// 本地 HTTP API 服务器：提供工具 token 消耗数据
/// 监听端口默认 9988，端点 GET /api/usage 返回 JSON
final class UsageAPIServer: @unchecked Sendable {
    static let shared = UsageAPIServer()
    private var listener: NWListener?
    private let port: NWEndpoint.Port
    private weak var viewModel: ViewModel?

    var isRunning: Bool { listener?.state == .ready }

    init(port: UInt16 = 9988) {
        self.port = NWEndpoint.Port(integerLiteral: port)
    }

    func bind(viewModel: ViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        guard listener == nil else { return }
        do {
            listener = try NWListener(using: .tcp, on: port)
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

            let path = self.extractPath(from: request)
            if path == "/api/usage" || path == "/api/usage/" {
                self.sendUsageJSON(connection)
            } else {
                self.send404(connection)
            }

            if !isComplete {
                self.receiveHTTPRequest(connection)
            }
        }
    }

    private func extractPath(from request: String) -> String {
        let lines = request.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let first = lines.first else { return "" }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return "" }
        return String(parts[1])
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
