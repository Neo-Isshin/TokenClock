import Foundation

/// Windows 天气抓取：在后台线程用 IP 定位 + wttr.in 取天气，广播 `.weatherUpdated` 通知。
///
/// 独立于 `@MainActor WeatherService`：Win32 主线程在 `GetMessage` 消息循环里，不泵 Swift main
/// actor，因此 `WeatherService` 的 `@MainActor` async 方法在 Windows 上无法执行。此处在后台
/// DispatchQueue 中使用同步 WinHTTP；Win32 消息线程不会被网络请求阻塞。
/// 天气解析直接复用 `WeatherService.parseJSON`（emoji/weatherCode 映射与 macOS 同源）。
private final class WeatherRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    func begin() -> Int { lock.withLock { generation += 1; return generation } }
    func isLatest(_ value: Int) -> Bool { lock.withLock { generation == value } }
}

private struct WindowsWeatherCache: Codable {
    struct Slot: Codable {
        let time: String
        let tempC: Int
        let emoji: String
        let description: String
    }

    let cityKey: String
    let savedAt: TimeInterval
    let emoji: String
    let temperature: Int
    let cityName: String
    let forecast: [Slot]

    init(cityKey: String, info: WeatherInfo) {
        self.cityKey = cityKey
        savedAt = Date().timeIntervalSince1970
        emoji = info.emoji
        temperature = info.temperature
        cityName = info.cityName
        forecast = info.forecast.map {
            Slot(time: $0.time, tempC: $0.tempC, emoji: $0.emoji, description: $0.description)
        }
    }

    var weather: WeatherInfo {
        WeatherInfo(
            emoji: emoji,
            temperature: temperature,
            cityName: cityName,
            forecast: forecast.map {
                HourlyForecast(time: $0.time, tempC: $0.tempC, emoji: $0.emoji, description: $0.description)
            }
        )
    }
}

enum WindowsWeather {
    private static let requestState = WeatherRequestState()
    private static let cacheKey = "TC_windowsWeatherCacheV1"
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60

    /// 触发一次后台抓取。city 为空或 "auto" ⇒ IP 自动定位；否则按城市名走 wttr.in。
    /// 完成后 post `.weatherUpdated`。
    static func refresh(forCity city: String = "auto") {
        let generation = requestState.begin()
        log("refresh start city=\(normalizedCityKey(city))")
        if let cached = cachedWeather(for: city) {
            log("cache hit city=\(cached.cityName)")
            NotificationCenter.default.post(name: .weatherUpdated, object: cached)
        }
        DispatchQueue.global(qos: .utility).async {
            if ProcessInfo.processInfo.environment["TC_WEATHER_MOCK"] != nil {
                let displayCity = city.caseInsensitiveCompare("auto") == .orderedSame ? "Seattle" : city
                let forecast = stride(from: 0, through: 21, by: 3).map { hour in
                    HourlyForecast(time: "\(hour)00", tempC: 18 + hour / 6,
                                   emoji: hour < 12 ? "☀️" : "⛅", description: "Test forecast")
                }
                let info = WeatherInfo(emoji: "☀️", temperature: 21, cityName: displayCity, forecast: forecast)
                if requestState.isLatest(generation) {
                    NotificationCenter.default.post(name: .weatherUpdated, object: info)
                }
                return
            }
            let info: WeatherInfo?
            if city.isEmpty || city.caseInsensitiveCompare("auto") == .orderedSame {
                info = fetch()
            } else {
                info = weather(city: city) ?? fetch()   // 指定城市失败时回退 IP 自动定位
            }
            // Rapid city/unit menu changes may leave several URL requests in flight. Only the
            // latest request is allowed to update the face, otherwise a slower old city wins.
            if let info, requestState.isLatest(generation) {
                save(info, for: city)
                log("refresh success city=\(info.cityName) forecast=\(info.forecast.count)")
                NotificationCenter.default.post(name: .weatherUpdated, object: info)
            } else if requestState.isLatest(generation) {
                log("refresh failed city=\(normalizedCityKey(city))")
            }
        }
    }

    private static func fetch() -> WeatherInfo? {
        if let location = lookupLocation(),
           let info = weather(location: location) {
            return info
        }
        return weatherAuto()
    }

    private static func lookupLocation() -> IPWeatherLocation? {
        let publicIP = IPGeolocation.publicIP(
            from: httpGet(URL(string: AppConfig.API.ipLookup))
        )
        guard let url = IPGeolocation.endpoint(
            publicIP: publicIP,
            language: L10n.shared.language
        ) else { return nil }
        return IPGeolocation.location(from: httpGet(url))
    }

    private static func weather(city: String) -> WeatherInfo? {
        let enc = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        guard let url = URL(string: "\(AppConfig.API.weatherBase)/\(enc)?format=j1&m") else { return nil }
        return httpGet(url).map { WeatherService.parseJSON(data: $0, fallbackCity: city) }
    }

    private static func weather(location: IPWeatherLocation) -> WeatherInfo? {
        let coordinates = "\(location.latitude)+\(location.longitude)"
        guard let url = URL(string: "\(AppConfig.API.weatherBase)/\(coordinates)?format=j1&m") else {
            return nil
        }
        return httpGet(url).map {
            WeatherService.parseJSON(data: $0, fallbackCity: location.city)
        }
    }

    private static func weatherAuto() -> WeatherInfo? {
        guard let url = URL(string: "\(AppConfig.API.weatherBase)/?format=j1&m") else { return nil }
        return httpGet(url).map { WeatherService.parseJSON(data: $0, fallbackCity: "") }
    }

    /// 同步 GET；调用点始终位于 refresh 的 utility worker 上。
    private static func httpGet(_ url: URL?) -> Data? {
        guard let url else { return nil }
        do {
            let response = try WindowsNativeHTTP.request(
                url: url.absoluteString,
                headers: [
                    "Accept": "application/json, text/plain;q=0.9",
                    "User-Agent": AppConfig.HTTP.userAgent,
                ],
                connectTimeout: 10,
                sendTimeout: 10,
                receiveTimeout: 30,
                maximumResponseBytes: 2 * 1024 * 1024
            )
            guard response.statusCode == 200 else {
                log("http \(response.statusCode) for \(url.host() ?? "?")")
                return nil
            }
            return response.body
        } catch {
            log("http error \(url.host() ?? "?"): \(error)")
            return nil
        }
    }

    /// 错误日志（GUI 子系统无控制台，print 无输出）→ 写到 %LOCALAPPDATA%\TokenClock\weather.log，便于排查。
    private static let logPath = (ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { $0 + "\\TokenClock" } ?? "C:\\TokenClock")

    private static func normalizedCityKey(_ city: String) -> String {
        let value = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "auto" : value.lowercased()
    }

    private static func cachedWeather(for city: String) -> WeatherInfo? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(WindowsWeatherCache.self, from: data),
              cache.cityKey == normalizedCityKey(city),
              Date().timeIntervalSince1970 - cache.savedAt <= cacheLifetime,
              !cache.cityName.isEmpty else { return nil }
        return cache.weather
    }

    private static func save(_ info: WeatherInfo, for city: String) {
        guard !info.cityName.isEmpty,
              let data = try? JSONEncoder().encode(
                WindowsWeatherCache(cityKey: normalizedCityKey(city), info: info)
              ) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.synchronize()
    }

    private static func log(_ msg: String) {
        let dir = URL(fileURLWithPath: logPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("weather.diag")
        let line = msg + "\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }
}
