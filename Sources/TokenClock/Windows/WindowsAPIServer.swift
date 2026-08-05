import Foundation
import Win32Shim

/// Windows 上的 loopback HTTP API 服务，镜像 LinuxAPIServer 的语义（/api/usage、/api/history）。
/// 实际的 Winsock socket 循环在 Win32Shim/winhttp.c 里跑后台线程；本类提供路由 + JSON 序列化，
/// 经一个无捕获的 @convention(c) 回调把请求转回 Swift。
final class WindowsAPIServer {
    private let model: WindowsUsageModel
    private var handle: UnsafeMutableRawPointer?

    init(model: WindowsUsageModel) {
        self.model = model
    }

    func start() {
        guard handle == nil else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = win_start_api_server(UInt16(AppConfig.LocalServer.defaultPort), winApiResponder, ctx)
    }

    func stop() {
        if let h = handle {
            win_stop_api_server(h)
            handle = nil
        }
    }

    /// 处理一条 GET 请求，返回 JSON 体（UTF-8）；路径未匹配返回 nil ⇒ 404。
    fileprivate func respond(path: String, query: String) -> String? {
        switch path {
        case "/api/usage", "/api/usage/":
            return json(model.usageJSONObject())
        case "/api/history", "/api/history/":
            let days = Self.parseDays(query) ?? AppConfig.History.retentionDays
            let includeSessions = query.contains("detail=sessions")
            return json(model.historyJSONObject(days: days, includeSessions: includeSessions))
        default:
            return nil
        }
    }

    private func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func parseDays(_ query: String) -> Int? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "days" { return Int(kv[1]) }
        }
        return nil
    }
}

/// C 回调：把 path/query 转给 WindowsAPIServer，把返回的 JSON 体拷进 out 缓冲区。
/// 必须无捕获（@convention(c)）；用启动时传入的 ctx 指针找回 WindowsAPIServer 实例。
private let winApiResponder: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafeMutablePointer<CChar>?, Int32
) -> Int32 = { ctx, pathPtr, queryPtr, out, outSize in
    guard let ctx, let out else { return -1 }
    let server = Unmanaged<WindowsAPIServer>.fromOpaque(ctx).takeUnretainedValue()
    let path = pathPtr.map { String(cString: $0) } ?? ""
    let query = queryPtr.map { String(cString: $0) } ?? ""
    guard let body = server.respond(path: path, query: query) else { return -1 }

    let bytes = Array(body.utf8)
    let cap = Int(outSize) - 1
    let n = min(bytes.count, cap)
    for i in 0..<n {
        out[i] = CChar(bitPattern: bytes[i])
    }
    out[n] = 0
    return Int32(n)
}
