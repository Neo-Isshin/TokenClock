import Foundation
#if os(macOS)
import CoreLocation
#endif
#if canImport(FoundationNetworking) && !os(Windows)
import FoundationNetworking   // swift-corelibs 在 Windows 把 URLSession 拆到独立模块
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
/// 天气服务：支持自动定位 + wttr.in 免费天气 API
/// 使用 JSON 格式解析，支持 weatherCode 精确映射 + 逐小时预报
@MainActor
final class WeatherService: NSObject {
    static let shared = WeatherService()

#if os(macOS)
    private let locationManager = CLLocationManager()
#endif

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

    override private init() {
        super.init()
        #if os(macOS)
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        #endif
    }

    // MARK: - 定位

    func fetchLocalWeather() {
        #if os(macOS)
        let status = locationManager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            // 同时用 IP 定位作为备用，避免用户未授权时无数据
            Task { @MainActor in
                await self.fetchWeatherByIP()
            }
        default:
            Task { @MainActor in
                await self.fetchWeatherByIP()
            }
        }
        #else
        // 非 macOS（Windows/Linux）无 CoreLocation：直接用 IP 定位
        Task { @MainActor in
            await self.fetchWeatherByIP()
        }
        #endif
    }

    #if os(macOS)
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        Task { @MainActor in
            let city = await self.reverseGeocode(lat: lat, lon: lon)
            await self.fetchWeatherFromAPI(lat: lat, lon: lon, cityName: city)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized {
            manager.requestLocation()
        }
    }
    #endif

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
    nonisolated static func parseJSON(data: Data?, fallbackCity: String) -> WeatherInfo {
        parseWeatherJSON(data: data, fallbackCity: fallbackCity)
    }

    // MARK: - IP 定位 Fallback

    /// 通过 IP 定位获取天气（IPIP.net 国内服务为主，失败时用 wttr.in 自动定位）
    private func fetchWeatherByIP() async {
        // 先尝试 IPIP.net IP 定位（国内服务，绕过代理）
        if let cityName = await fetchCityFromIPService(), !cityName.isEmpty {
            await self.fetchWeatherByCityName(cityName)
            return
        }
        // 失败时回退到 wttr.in 自动定位（根据 IP 自动识别城市）
        await self.fetchWeatherByAutoLocation()
    }

    private func fetchCityFromIPService() async -> String? {
        // 使用 IPIP.net 获取国内真实 IP 位置（绕过代理）
        guard let url = URL(string: AppConfig.API.ipLookup) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            // 响应格式: "当前 IP：183.191.125.191  来自于：中国 山西 太原  联通"
            let components = text.components(separatedBy: "来自于：")
            guard components.count >= 2 else { return nil }
            let locationPart = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            // 按空格拆分，取城市部分（格式: 中国 省 市）
            let parts = locationPart.components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // parts 示例: ["中国", "山西", "太原", "联通"]
            guard parts.count >= 3 else { return nil }
            var cityName = parts[2] // 市名
            cityName = cityName.replacingOccurrences(of: "省", with: "")
                               .replacingOccurrences(of: "市", with: "")
                               .replacingOccurrences(of: "自治区", with: "")
            return cityName.isEmpty ? nil : cityName
        } catch {
            print("IP geolocation error: \(error)")
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

    // MARK: - 反向地理编码（仅 macOS，CoreLocation/CLGeocoder）

    #if os(macOS)
    private func reverseGeocode(lat: Double, lon: Double) async -> String {
        let location = CLLocation(latitude: lat, longitude: lon)
        // normal 分支部署目标 .macOS(.v15),MKReverseGeocodingRequest 是 macOS 26+ API。
        // 保留 CLGeocoder(在 macOS 15 上仍工作),@available(*, deprecated: 26.0) 让编译器知道
        // 这段是"明知弃用仍保留",不报 deprecation warning。等 normal 升到 v26 再切。
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: Locale(identifier: "zh_CN"))
            if let placemark = placemarks.first {
                return placemark.locality ?? placemark.administrativeArea ?? "未知位置"
            }
        } catch {
            print("Reverse geocode error: \(error)")
        }
        return "未知位置"
    }
    #endif
}
#endif

/// Platform-neutral wttr.in parser shared by macOS's WeatherService and WindowsWeather.
private func parseWeatherJSON(data: Data?, fallbackCity: String) -> WeatherInfo {
    guard let data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return WeatherInfo(emoji: "🌤️", temperature: 0, cityName: fallbackCity)
    }

    let current = (json["current_condition"] as? [[String: Any]])?.first ?? [:]
    let tempC = Int(current["temp_C"] as? String ?? "") ?? 0
    let code = Int(current["weatherCode"] as? String ?? "") ?? 0
    let emoji = mapWeatherCode(code)

    var cityName = fallbackCity
    if cityName.isEmpty,
       let nearest = (json["nearest_area"] as? [[String: Any]])?.first,
       let areaNames = nearest["areaName"] as? [[String: Any]],
       let name = areaNames.first?["value"] as? String {
        cityName = name
    }

    var forecast: [HourlyForecast] = []
    if let weatherDays = json["weather"] as? [[String: Any]] {
        for day in weatherDays {
            guard let hourly = day["hourly"] as? [[String: Any]] else { continue }
            for hour in hourly {
                let time = hour["time"] as? String ?? ""
                let temperature = Int(hour["tempC"] as? String ?? "") ?? 0
                let weatherCode = Int(hour["weatherCode"] as? String ?? "") ?? 0
                let description = (hour["weatherDesc"] as? [[String: Any]])?.first?["value"] as? String ?? ""
                forecast.append(HourlyForecast(
                    time: time,
                    tempC: temperature,
                    emoji: mapWeatherCode(weatherCode),
                    description: description
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

/// WorldWeatherOnline weatherCode → emoji 映射（覆盖全部 48 种代码）
private func mapWeatherCode(_ code: Int) -> String {
    switch code {
    case 113: return "☀️"
    case 116: return "⛅"
    case 119, 122: return "☁️"
    case 143, 248, 260: return "🌫️"
    case 176, 263, 266, 269, 281, 284, 293, 353: return "🌦️"
    case 179, 182, 185, 311, 314, 317, 320, 350, 362, 365, 374, 377: return "🌨️"
    case 200, 386, 389, 392, 395: return "⛈️"
    case 227, 230, 323, 326, 329, 332, 335, 338, 368, 371: return "❄️"
    case 296, 299, 302, 305, 308, 356, 359: return "🌧️"
    default: return "🌤️"
    }
}

extension Notification.Name {
    static let weatherUpdated = Notification.Name("weatherUpdated")
    static let customThemeApplied = Notification.Name("customThemeApplied")
}

#if os(macOS)
// CLLocationManager 只有 macOS 有；用空 extension 声明协议一致性（委托方法在类体内 #if os(macOS)）。
extension WeatherService: CLLocationManagerDelegate {}
#endif
