import Foundation
import CoreLocation

/// 天气服务：支持自动定位 + wttr.in 免费天气 API
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    private let locationManager = CLLocationManager()

    /// 城市名 → 坐标映射（wttr.in 城市名查询不稳定，改用坐标）
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
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    /// 请求定位权限并获取天气
    func fetchLocalWeather() {
        let status = locationManager.authorizationStatus
        switch status {
        case .authorized:
            locationManager.requestLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            // 定位不可用，用 IP 定位作为 fallback
            print("Location not available (status: \(status.rawValue)), using IP geolocation")
            Task { @MainActor in
                await self.fetchWeatherByIP()
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

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

    // MARK: - Public: 按城市名获取天气（使用坐标，更可靠）

    func fetchWeather(forCity city: String, completion: @escaping @MainActor (WeatherInfo) -> Void) {
        // 优先用坐标查询（wttr.in 城市名经常 500）
        if let coords = Self.cityCoordinates[city] {
            fetchWeatherFromAPI(lat: coords.lat, lon: coords.lon, cityName: city) { info in
                completion(info)
            }
        } else {
            // fallback: 用城市名查询
            let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
            let urlString = "https://wttr.in/\(encoded)?format=%C+%t"
            guard let url = URL(string: urlString) else { return }

            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data,
                      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      Self.isValidWeatherResponse(text) else {
                    // 城市名也失败，返回默认值
                    Task { @MainActor in
                        completion(WeatherInfo(emoji: "🌤️", temperature: 0, cityName: city))
                    }
                    return
                }
                let info = Self.parseWeatherText(text, cityName: city)
                Task { @MainActor in
                    completion(info)
                }
            }.resume()
        }
    }

    // MARK: - wttr.in API

    /// 用坐标获取天气（通知方式，用于自动定位）
    private func fetchWeatherFromAPI(lat: Double, lon: Double, cityName: String) async {
        // 用 + 分隔坐标，比逗号更稳定
        let urlString = "https://wttr.in/\(lat)+\(lon)?format=%C+%t"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               Self.isValidWeatherResponse(text) {
                let info = Self.parseWeatherText(text, cityName: cityName)
                NotificationCenter.default.post(name: .weatherUpdated, object: info)
            } else {
                print("Weather API returned invalid response for \(cityName): \(String(data: data, encoding: .utf8) ?? "nil")")
            }
        } catch {
            print("Weather fetch error: \(error)")
        }
    }

    /// 用坐标获取天气（回调方式，用于城市选择）
    private func fetchWeatherFromAPI(lat: Double, lon: Double, cityName: String, completion: @escaping @MainActor (WeatherInfo) -> Void) {
        let urlString = "https://wttr.in/\(lat)+\(lon)?format=%C+%t"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data,
                  let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  Self.isValidWeatherResponse(text) else {
                print("Weather API returned invalid response for \(cityName)")
                Task { @MainActor in
                    completion(WeatherInfo(emoji: "🌤️", temperature: 0, cityName: cityName))
                }
                return
            }
            let info = Self.parseWeatherText(text, cityName: cityName)
            Task { @MainActor in
                completion(info)
            }
        }.resume()
    }

    // MARK: - Validation & Parsing

    /// 检查响应是否为有效天气数据（排除 "weather data source not available" 等错误）
    nonisolated private static func isValidWeatherResponse(_ text: String) -> Bool {
        let lower = text.lowercased()
        return !lower.contains("not available") && !lower.contains("error") && !lower.contains("unknown")
    }

    /// 解析 wttr.in 返回的天气文本
    nonisolated private static func parseWeatherText(_ text: String, cityName: String) -> WeatherInfo {
        let parts = text.split(separator: " ", maxSplits: 1)
        var conditionEmoji = "🌤️"
        var tempStr = "--"

        if parts.count == 2 {
            conditionEmoji = mapCondition(String(parts[0]))
            tempStr = String(parts[1]).replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "°C", with: "").replacingOccurrences(of: "°F", with: "")
        }

        let temp = Int(tempStr) ?? 0
        return WeatherInfo(emoji: conditionEmoji, temperature: temp, cityName: cityName)
    }

    /// 天气描述 → emoji
    nonisolated private static func mapCondition(_ condition: String) -> String {
        switch condition.lowercased() {
        case let c where c.contains("clear"): return "☀️"
        case let c where c.contains("sunny"): return "☀️"
        case let c where c.contains("partly cloudy"): return "⛅"
        case let c where c.contains("cloudy"): return "☁️"
        case let c where c.contains("overcast"): return "☁️"
        case let c where c.contains("fog"): return "🌫️"
        case let c where c.contains("rain"): return "🌧️"
        case let c where c.contains("drizzle"): return "🌦️"
        case let c where c.contains("thunder"): return "⛈️"
        case let c where c.contains("snow"): return "❄️"
        case let c where c.contains("sleet"): return "🌨️"
        default: return "🌤️"
        }
    }

    // MARK: - IP Geolocation Fallback

    /// 通过 IP 定位获取天气（无需位置权限，使用国内 IP 定位服务）
    private func fetchWeatherByIP() async {
        // ip.plyz.net 返回格式: IP|国家 省份 城市 运营商
        guard let url = URL(string: "http://ip.plyz.net/ip.ashx") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            // 解析: "171.116.82.78|中国 山西省 太原市 联通" → 提取城市名
            let parts = text.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else {
                print("IP geolocation: unexpected format: \(text)")
                return
            }
            let locationStr = String(parts[1])
            // 提取城市：取空格分隔的第三段（如 "中国 山西省 太原市 联通"）
            let segments = locationStr.split(separator: " ")
            var cityName = ""
            if segments.count >= 3 {
                cityName = String(segments[2]).replacingOccurrences(of: "市", with: "")
            } else if segments.count >= 2 {
                cityName = String(segments[1]).replacingOccurrences(of: "省", with: "").replacingOccurrences(of: "市", with: "")
            }
            guard !cityName.isEmpty else {
                print("IP geolocation: could not extract city from: \(locationStr)")
                return
            }
            // 用城市名查询 wttr.in
            await self.fetchWeatherByCityName(cityName)
        } catch {
            print("IP geolocation error: \(error)")
        }
    }

    /// 用城市名查询 wttr.in 天气（IP 定位 fallback 用）
    private func fetchWeatherByCityName(_ cityName: String) async {
        let encoded = cityName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cityName
        let urlString = "https://wttr.in/\(encoded)?format=%C+%t"
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               Self.isValidWeatherResponse(text) {
                let info = Self.parseWeatherText(text, cityName: cityName)
                NotificationCenter.default.post(name: .weatherUpdated, object: info)
            } else {
                print("Weather API failed for city \(cityName)")
            }
        } catch {
            print("Weather fetch error for city \(cityName): \(error)")
        }
    }

    // MARK: - Geocoding

    /// 反向地理编码：坐标 → 城市名
    private func reverseGeocode(lat: Double, lon: Double) async -> String {
        let location = CLLocation(latitude: lat, longitude: lon)
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
}

extension Notification.Name {
    static let weatherUpdated = Notification.Name("weatherUpdated")
}
