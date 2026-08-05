import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // swift-corelibs 把 URLSession 拆到独立模块
#endif

/// Windows 天气抓取：在后台线程用 IP 定位 + wttr.in 取天气，广播 `.weatherUpdated` 通知。
///
/// 独立于 `@MainActor WeatherService`：Win32 主线程在 `GetMessage` 消息循环里，不泵 Swift main
/// actor，因此 `WeatherService` 的 `@MainActor` async 方法在 Windows 上无法执行。此处用 dataTask +
/// 信号量做同步抓取（回调在 URLSession 自有线程触发，无需 runloop），跑在后台 DispatchQueue。
/// 天气解析直接复用 `WeatherService.parseJSON`（emoji/weatherCode 映射与 macOS 同源）。

/// 线程安全的 Data 容器：dataTask 回调在 URLSession 自有线程写，调用方在信号量唤醒后读。
private final class DataBox: @unchecked Sendable { var value: Data? }

enum WindowsWeather {
    /// 触发一次后台抓取（IPIP.net 定位 → wttr.in 自动定位回退）；完成后 post `.weatherUpdated`。
    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            if let info = fetch() {
                NotificationCenter.default.post(name: .weatherUpdated, object: info)
            }
        }
    }

    private static func fetch() -> WeatherInfo? {
        // 先 IPIP.net IP 定位（国内服务，绕过代理）
        if let city = lookupCity(), !city.isEmpty {
            if let info = weather(city: city) { return info }
        }
        // 回退 wttr.in 自动定位（按 IP 自动识别城市）
        return weatherAuto()
    }

    /// IPIP.net 返回「当前 IP：x  来自于：中国 省 市 运营商」，取市名。
    private static func lookupCity() -> String? {
        guard let data = httpGet(URL(string: AppConfig.API.ipLookup)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let comps = text.components(separatedBy: "来自于：")
        guard comps.count >= 2 else { return nil }
        let parts = comps[1].trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count >= 3 else { return nil }
        var city = parts[2]
        for s in ["省", "市", "自治区"] { city = city.replacingOccurrences(of: s, with: "") }
        return city.isEmpty ? nil : city
    }

    private static func weather(city: String) -> WeatherInfo? {
        let enc = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        guard let url = URL(string: "\(AppConfig.API.weatherBase)/\(enc)?format=j1&m") else { return nil }
        return httpGet(url).map { WeatherService.parseJSON(data: $0, fallbackCity: city) }
    }

    private static func weatherAuto() -> WeatherInfo? {
        guard let url = URL(string: "\(AppConfig.API.weatherBase)/?format=j1&m") else { return nil }
        return httpGet(url).map { WeatherService.parseJSON(data: $0, fallbackCity: "") }
    }

    /// 同步 GET：dataTask 回调在 URLSession 自有线程触发 → 信号量唤醒，无需 runloop。
    private static func httpGet(_ url: URL?) -> Data? {
        guard let url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        let sem = DispatchSemaphore(value: 0)
        let box = DataBox()
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { log("http error \(url.host() ?? "?"): \(error)") }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log("http \(http.statusCode) for \(url.host() ?? "?")")
            }
            box.value = data
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return box.value
    }

    /// 错误日志（GUI 子系统无控制台，print 无输出）→ 写到 %LOCALAPPDATA%\TokenClock\weather.log，便于排查。
    private static let logPath = (ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { $0 + "\\TokenClock" } ?? "C:\\TokenClock")
    private static func log(_ msg: String) {
        let dir = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("weather.diag")
        let line = msg + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
