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

    func start(port: UInt16 = AppConfig.LocalServer.defaultPort) {
        if let handle {
            win_reconfigure_api_server(handle, port)
            return
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        handle = win_start_api_server(port, winApiResponder, ctx)
    }

    /// Disable the listener without destroying the one native worker that may call Swift.
    func pause() {
        if let handle { win_pause_api_server(handle) }
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

    /// Serialize the small, known API object graph without Foundation's dynamic
    /// JSONSerialization bridge. On swift-corelibs-foundation for Windows that bridge retains
    /// native wait handles on every invocation; a local dashboard polling once per second would
    /// therefore grow the process forever. This serializer accepts precisely the JSON-safe types
    /// produced by WindowsUsageModel and is locale-independent.
    private func json(_ object: [String: Any]) -> String? { Self.jsonValue(object) }

    private static func jsonValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return "\"\(jsonEscaped(string))\""
        case let bool as Bool:
            return bool ? "true" : "false"
        case let integer as Int:
            return String(integer)
        case let integer as Int64:
            return String(integer)
        case let integer as UInt:
            return String(integer)
        case let integer as UInt64:
            return String(integer)
        case let number as Double:
            return number.isFinite ? String(number) : "null"
        case let number as Float:
            return number.isFinite ? String(number) : "null"
        case let dictionary as [String: Any]:
            var members: [String] = []
            members.reserveCapacity(dictionary.count)
            for key in dictionary.keys.sorted() {
                guard let encoded = dictionary[key].flatMap(jsonValue) else { return nil }
                members.append("\"\(jsonEscaped(key))\":\(encoded)")
            }
            return "{\(members.joined(separator: ","))}"
        case let array as [Any]:
            var elements: [String] = []
            elements.reserveCapacity(array.count)
            for item in array {
                guard let encoded = jsonValue(item) else { return nil }
                elements.append(encoded)
            }
            return "[\(elements.joined(separator: ","))]"
        case _ as NSNull:
            return "null"
        default:
            return nil
        }
    }

    private static func jsonEscaped(_ value: String) -> String {
        let hex = Array("0123456789abcdef".unicodeScalars)
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result.append(contentsOf: "\\\"".unicodeScalars)
            case 0x5c: result.append(contentsOf: "\\\\".unicodeScalars)
            case 0x08: result.append(contentsOf: "\\b".unicodeScalars)
            case 0x0c: result.append(contentsOf: "\\f".unicodeScalars)
            case 0x0a: result.append(contentsOf: "\\n".unicodeScalars)
            case 0x0d: result.append(contentsOf: "\\r".unicodeScalars)
            case 0x09: result.append(contentsOf: "\\t".unicodeScalars)
            case 0..<0x20:
                result.append(contentsOf: "\\u00".unicodeScalars)
                result.append(hex[Int((scalar.value >> 4) & 0xf)])
                result.append(hex[Int(scalar.value & 0xf)])
            default:
                result.append(scalar)
            }
        }
        return String(result)
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
