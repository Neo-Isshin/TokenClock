import Foundation
#if os(macOS)
import CoreLocation
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking   // swift-corelibs 在 Linux 把 URLSession 拆到独立模块
#endif

/// 逐小时预报（3小时间隔）
struct HourlyForecast: Sendable {
    let time: String
    let tempC: Int
    let emoji: String
    let description: String
}

#if os(Windows)
/// Windows only needs the shared parser. Network I/O lives in WindowsWeather and WinHTTP, so
/// no URLSession symbol (and therefore no FoundationNetworking.dll) enters the executable.
enum WeatherService {
    static func parseJSON(data: Data?, fallbackCity: String) -> WeatherInfo {
        parseWeatherJSON(data: data, fallbackCity: fallbackCity)
    }
}
#else
/// 天气服务：自动定位统一使用公网 IP，不请求系统位置权限
/// 使用 JSON 格式解析，支持 weatherCode 精确映射 + 逐小时预报
@MainActor
final class WeatherService {
    static let shared = WeatherService()

    /// 天气请求代次：每次发起网络抓取自增；post 前比对，旧请求被新请求超越时不 post，
    /// 杜绝慢请求用旧数据覆盖快请求刚拿到的新数据。
    private var weatherGen = 0
    private func bumpWeatherGen() -> Int { weatherGen &+= 1; return weatherGen }

    /// 城市名 → 坐标映射
    private static let cityCoordinates: [String: (lat: Double, lon: Double)] = [
        "Hong Kong":    (22.3193, 114.1694),
        "Shanghai":     (31.2304, 121.4737),
        "Beijing":      (39.9042, 116.4074),
        "Tokyo":        (35.6762, 139.6503),
        "Singapore":    (1.3521,  103.8198),
        "New York":     (40.7128, -74.0060),
    ]

    private init() {}

    // MARK: - IP 定位

    func fetchLocalWeather() {
        Task { @MainActor in
            await self.fetchWeatherByIP()
        }
    }

    // MARK: - 按城市名获取天气

    func fetchWeather(forCity city: String, completion: @escaping @MainActor (WeatherInfo) -> Void) {
        if let coords = Self.cityCoordinates[city] {
            fetchWeatherFromAPI(lat: coords.lat, lon: coords.lon, cityName: city) { info in
                completion(info)
            }
        } else {
            let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
            let urlString = "\(AppConfig.API.weatherBase)/\(encoded)?format=j1&m"
            guard let url = URL(string: urlString) else { return }

            URLSession.shared.dataTask(with: url) { data, _, _ in
                let info = Self.parseJSON(data: data, fallbackCity: city)
                Task { @MainActor in
                    completion(info)
                }
            }.resume()
        }
    }

    // MARK: - wttr.in JSON API

    private func fetchWeatherFromAPI(lat: Double, lon: Double, cityName: String) async {
        let myGen = bumpWeatherGen()
        let urlString = "\(AppConfig.API.weatherBase)/\(lat)+\(lon)?format=j1&m"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard myGen == weatherGen else { return }  // 已被更新的请求超越 → 丢弃旧数据
            let info = Self.parseJSON(data: data, fallbackCity: cityName)
            NotificationCenter.default.post(name: .weatherUpdated, object: info)
        } catch {
            print("Weather fetch error: \(error)")
        }
    }

    private func fetchWeatherFromAPI(lat: Double, lon: Double, cityName: String, completion: @escaping @MainActor (WeatherInfo) -> Void) {
        let urlString = "\(AppConfig.API.weatherBase)/\(lat)+\(lon)?format=j1&m"
        guard let url = URL(string: urlString) else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let info = Self.parseJSON(data: data, fallbackCity: cityName)
            Task { @MainActor in
                completion(info)
            }
        }.resume()
    }

    // MARK: - JSON 解析

    /// 解析 wttr.in JSON 响应
    nonisolated private static func parseJSON(data: Data?, fallbackCity: String) -> WeatherInfo {
        parseWeatherJSON(data: data, fallbackCity: fallbackCity)
    }

    // MARK: - weatherCode → emoji

    /// WorldWeatherOnline weatherCode → emoji 映射（覆盖全部 48 种代码）

    // MARK: - IP 定位实现

    /// 通过 IP 定位获取天气。先取得公网 IP，再用结构化服务获得本地化城市名和经纬度，
    /// 最终按经纬度查询天气，避免把“欧文”等中文地名误判到其他国家。
    private func fetchWeatherByIP() async {
        if let location = await fetchLocationFromIPService() {
            await fetchWeatherFromAPI(
                lat: location.latitude,
                lon: location.longitude,
                cityName: location.city
            )
            return
        }
        await self.fetchWeatherByAutoLocation()
    }

    private func fetchLocationFromIPService() async -> IPWeatherLocation? {
        var publicIP: String?
        if let ipURL = URL(string: AppConfig.API.ipLookup),
           let (data, _) = try? await URLSession.shared.data(from: ipURL) {
            publicIP = IPGeolocation.publicIP(from: data)
        }

        guard let locationURL = IPGeolocation.endpoint(
            publicIP: publicIP,
            language: L10n.shared.language
        ) else { return nil }

        do {
            let (data, _) = try await URLSession.shared.data(from: locationURL)
            return IPGeolocation.location(from: data)
        } catch {
            print("Structured IP geolocation error: \(error)")
            return nil
        }
    }

    private func fetchWeatherByAutoLocation() async {
        let myGen = bumpWeatherGen()
        let urlString = "\(AppConfig.API.weatherBase)/?format=j1&m"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard myGen == weatherGen else { return }  // 已被更新的请求超越 → 丢弃旧数据
            let info = Self.parseJSON(data: data, fallbackCity: "")
            NotificationCenter.default.post(name: .weatherUpdated, object: info)
        } catch {
            print("Auto-location weather fetch error: \(error)")
        }
    }

    private func fetchWeatherByCityName(_ cityName: String) async {
        let myGen = bumpWeatherGen()
        let encoded = cityName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cityName
        let urlString = "\(AppConfig.API.weatherBase)/\(encoded)?format=j1&m"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard myGen == weatherGen else { return }  // 已被更新的请求超越 → 丢弃旧数据
            let info = Self.parseJSON(data: data, fallbackCity: cityName)
            NotificationCenter.default.post(name: .weatherUpdated, object: info)
        } catch {
            print("Weather fetch error for city \(cityName): \(error)")
        }
    }

}

#endif

/// Platform-neutral wttr.in parser shared by the WeatherService class (macOS/Linux)
/// and the Windows thin shell above.
private func parseWeatherJSON(data: Data?, fallbackCity: String) -> WeatherInfo {
    guard let data = data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return WeatherInfo(emoji: "🌤️", temperature: 0, cityName: fallbackCity)
    }

    // 当前天气
    let current = (json["current_condition"] as? [[String: Any]])?.first ?? [:]
    let tempC = Int(current["temp_C"] as? String ?? "") ?? 0
    let code = Int(current["weatherCode"] as? String ?? "") ?? 0
    let emoji = mapWeatherCode(code)

    // 城市名：优先用传入的 fallback，空时才用 wttr.in 返回的 nearest_area
    var cityName = fallbackCity
    if cityName.isEmpty,
       let nearest = (json["nearest_area"] as? [[String: Any]])?.first,
       let areaNames = nearest["areaName"] as? [[String: Any]],
       let name = areaNames.first?["value"] as? String {
        cityName = name
    }

    // 逐小时预报（合并所有可用天数，支持深夜显示次日数据）
    var forecast: [HourlyForecast] = []
    if let weatherDays = json["weather"] as? [[String: Any]] {
        for day in weatherDays {
            guard let hourly = day["hourly"] as? [[String: Any]] else { continue }
            for h in hourly {
                let time = h["time"] as? String ?? ""
                let hTemp = Int(h["tempC"] as? String ?? "") ?? 0
                let hCode = Int(h["weatherCode"] as? String ?? "") ?? 0
                let hDesc = (h["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? ""
                forecast.append(HourlyForecast(
                    time: time,
                    tempC: hTemp,
                    emoji: mapWeatherCode(hCode),
                    description: hDesc
                ))
            }
        }
    }

    return WeatherInfo(
        emoji: emoji,
        temperature: tempC,
        cityName: cityName,
        forecast: forecast
    )
}

extension Notification.Name {
    static let weatherUpdated = Notification.Name("weatherUpdated")
    static let customThemeApplied = Notification.Name("customThemeApplied")
}

/// wttr.in weatherCode → emoji（共享解析器使用）
private func mapWeatherCode(_ code: Int) -> String {
    switch code {
    case 113: return "☀️"   // Clear, Sunny
    case 116: return "⛅"   // Partly cloudy
    case 119: return "☁️"   // Cloudy
    case 122: return "☁️"   // Overcast
    case 143: return "🌫️"   // Mist
    case 176: return "🌦️"   // Patchy rain nearby
    case 179: return "🌨️"   // Patchy snow nearby
    case 182: return "🌨️"   // Patchy sleet nearby
    case 185: return "🌨️"   // Patchy freezing drizzle nearby
    case 200: return "⛈️"   // Thundery outbreaks in nearby
    case 227: return "❄️"   // Blowing snow
    case 230: return "❄️"   // Blizzard
    case 248: return "🌫️"   // Fog
    case 260: return "🌫️"   // Freezing fog
    case 263: return "🌦️"   // Patchy light drizzle
    case 266: return "🌦️"   // Light drizzle
    case 269: return "🌦️"   // Freezing drizzle
    case 281: return "🌦️"   // Heavy freezing drizzle
    case 284: return "🌦️"   // Heavy freezing drizzle
    case 293: return "🌦️"   // Patchy light rain
    case 296: return "🌧️"   // Light rain
    case 299: return "🌧️"   // Moderate rain at times
    case 302: return "🌧️"   // Moderate rain
    case 305: return "🌧️"   // Heavy rain at times
    case 308: return "🌧️"   // Heavy rain
    case 311: return "🌨️"   // Light freezing rain
    case 314: return "🌨️"   // Moderate or heavy freezing rain
    case 317: return "🌨️"   // Light sleet
    case 320: return "🌨️"   // Moderate or heavy sleet
    case 323: return "❄️"   // Patchy light snow
    case 326: return "❄️"   // Light snow
    case 329: return "❄️"   // Patchy moderate snow
    case 332: return "❄️"   // Moderate snow
    case 335: return "❄️"   // Patchy heavy snow
    case 338: return "❄️"   // Heavy snow
    case 350: return "🌨️"   // Ice pellets
    case 353: return "🌦️"   // Light rain shower
    case 356: return "🌧️"   // Moderate or heavy rain shower
    case 359: return "🌧️"   // Torrential rain shower
    case 362: return "🌨️"   // Light sleet showers
    case 365: return "🌨️"   // Moderate or heavy sleet showers
    case 368: return "❄️"   // Light snow showers
    case 371: return "❄️"   // Moderate or heavy snow showers
    case 374: return "🌨️"   // Light showers of ice pellets
    case 377: return "🌨️"   // Moderate or heavy showers of ice pellets
    case 386: return "⛈️"   // Patchy light rain with thunder
    case 389: return "⛈️"   // Moderate or heavy rain with thunder
    case 392: return "⛈️"   // Patchy light snow with thunder
    case 395: return "⛈️"   // Moderate or heavy snow with thunder
    default:  return "🌤️"   // Unknown
    }
}
