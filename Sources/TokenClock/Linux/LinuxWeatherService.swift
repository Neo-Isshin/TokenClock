import Foundation
import FoundationNetworking

private struct LinuxWeatherCache: Codable {
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

/// Linux weather adapter for normal mode. Automatic mode resolves the public IP
/// to a localized city and coordinates, then queries wttr.in by coordinates.
final class LinuxWeatherService: @unchecked Sendable {
    private static let cacheKey = "TC_linuxWeatherCacheV1"
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private let lock = NSLock()
    private var storedWeather: WeatherInfo
    private var generation = 0

    init() {
        let selectedCity = UserDefaults.standard.string(forKey: SettingsKey.selectedCity.rawValue) ?? "auto"
        storedWeather = Self.cachedWeather(for: selectedCity) ?? WeatherInfo()
    }

    var weather: WeatherInfo {
        lock.lock()
        defer { lock.unlock() }
        return storedWeather
    }

    func fetch(city: String, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        generation &+= 1
        let requestGeneration = generation
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            guard let target = await Self.weatherTarget(for: city),
                  let data = await Self.data(from: target.url),
                  let parsed = Self.parse(data: data, fallbackCity: target.fallbackCity) else {
                return
            }
            let isLatest = self.lock.withLock {
                guard self.generation == requestGeneration else { return false }
                self.storedWeather = parsed
                return true
            }
            guard isLatest else { return }
            Self.save(parsed, for: city)
            completion()
        }
    }

    private static func weatherTarget(for city: String) async -> (url: URL, fallbackCity: String)? {
        if city.caseInsensitiveCompare("auto") != .orderedSame && !city.isEmpty {
            let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
            return URL(string: "\(AppConfig.API.weatherBase)/\(encoded)?format=j1&m")
                .map { ($0, city) }
        }

        if let location = await automaticLocation() {
            let coordinates = "\(location.latitude)+\(location.longitude)"
            return URL(string: "\(AppConfig.API.weatherBase)/\(coordinates)?format=j1&m")
                .map { ($0, location.city) }
        }
        return URL(string: "\(AppConfig.API.weatherBase)/?format=j1&m").map { ($0, "") }
    }

    private static func automaticLocation() async -> IPWeatherLocation? {
        let publicIP: String?
        if let url = URL(string: AppConfig.API.ipLookup) {
            publicIP = IPGeolocation.publicIP(from: await data(from: url))
        } else {
            publicIP = nil
        }
        guard let url = IPGeolocation.endpoint(
            publicIP: publicIP,
            language: L10n.shared.language
        ) else { return nil }
        return IPGeolocation.location(from: await data(from: url))
    }

    private static func data(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConfig.HTTP.resourceTimeout
        request.setValue("TokenClock/1.0 (Linux)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { return nil }
            return data
        } catch {
            print("[Weather] \(error.localizedDescription)")
            return nil
        }
    }

    private static func parse(data: Data, fallbackCity: String) -> WeatherInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let current = (json["current_condition"] as? [[String: Any]])?.first ?? [:]
        let temperature = Int(current["temp_C"] as? String ?? "") ?? 0
        let code = Int(current["weatherCode"] as? String ?? "") ?? 0

        var cityName = fallbackCity
        if cityName.isEmpty,
           let nearest = (json["nearest_area"] as? [[String: Any]])?.first,
           let names = nearest["areaName"] as? [[String: Any]],
           let resolved = names.first?["value"] as? String {
            cityName = resolved
        }

        var forecast: [HourlyForecast] = []
        if let days = json["weather"] as? [[String: Any]] {
            for day in days {
                guard let hours = day["hourly"] as? [[String: Any]] else { continue }
                for hour in hours {
                    let hourCode = Int(hour["weatherCode"] as? String ?? "") ?? 0
                    forecast.append(HourlyForecast(
                        time: hour["time"] as? String ?? "",
                        tempC: Int(hour["tempC"] as? String ?? "") ?? 0,
                        emoji: emoji(for: hourCode),
                        description: (hour["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? ""
                    ))
                }
            }
        }
        return WeatherInfo(
            emoji: emoji(for: code),
            temperature: temperature,
            cityName: cityName,
            forecast: forecast
        )
    }

    private static func emoji(for code: Int) -> String {
        switch code {
        case 113: return "☀️"
        case 116: return "⛅"
        case 119, 122: return "☁️"
        case 143, 248, 260: return "🌫️"
        case 176, 263, 266, 293, 353: return "🌦️"
        case 200, 386, 389, 392, 395: return "⛈️"
        case 227, 230, 323, 326, 329, 332, 335, 338, 368, 371: return "❄️"
        case 179, 182, 185, 269, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377: return "🌨️"
        case 296, 299, 302, 305, 308, 356, 359: return "🌧️"
        default: return "🌤️"
        }
    }

    private static func normalizedCityKey(_ city: String) -> String {
        let value = city.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "auto" : value.lowercased()
    }

    private static func cachedWeather(for city: String) -> WeatherInfo? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cache = try? JSONDecoder().decode(LinuxWeatherCache.self, from: data),
              cache.cityKey == normalizedCityKey(city),
              Date().timeIntervalSince1970 - cache.savedAt <= cacheLifetime,
              !cache.cityName.isEmpty else { return nil }
        return cache.weather
    }

    private static func save(_ info: WeatherInfo, for city: String) {
        guard !info.cityName.isEmpty,
              let data = try? JSONEncoder().encode(
                LinuxWeatherCache(cityKey: normalizedCityKey(city), info: info)
              ) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}
