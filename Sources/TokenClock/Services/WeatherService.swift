import Foundation
import CoreLocation

/// 天气服务：支持自动定位 + wttr.in 免费天气 API
@MainActor
final class WeatherService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    private let locationManager = CLLocationManager()

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

    // MARK: - Public: 按城市名获取天气

    func fetchWeather(forCity city: String, completion: @escaping @MainActor (WeatherInfo) -> Void) {
        let encoded = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        let urlString = "https://wttr.in/\(encoded)?format=%C+%t"
        guard let url = URL(string: urlString) else { return }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return
            }
            let info = Self.parseWeatherText(text, cityName: city)
            Task { @MainActor in
                completion(info)
            }
        }.resume()
    }

    // MARK: - wttr.in API

    private func fetchWeatherFromAPI(lat: Double, lon: Double, cityName: String) async {
        let urlString = "https://wttr.in/\(lat),\(lon)?format=%C+%t"
        guard let url = URL(string: urlString) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let info = Self.parseWeatherText(text, cityName: cityName)
                NotificationCenter.default.post(name: .weatherUpdated, object: info)
            }
        } catch {
            print("Weather fetch error: \(error)")
        }
    }

    // MARK: - Parsing

    /// 解析 wttr.in 返回的天气文本
    nonisolated private static func parseWeatherText(_ text: String, cityName: String) -> WeatherInfo {
        let parts = text.split(separator: " ", maxSplits: 1)
        var conditionEmoji = "🌤️"
        var tempStr = "--"

        if parts.count == 2 {
            conditionEmoji = mapCondition(String(parts[0]))
            tempStr = String(parts[1]).replacingOccurrences(of: "+", with: "").replacingOccurrences(of: "°C", with: "")
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

    /// 通过 IP 定位获取天气（无需位置权限）
    private func fetchWeatherByIP() async {
        // ip-api.com 免费 IP 定位
        guard let url = URL(string: "http://ip-api.com/json/?fields=city,lat,lon&lang=zh-CN") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let city = json["city"] as? String,
               let lat = json["lat"] as? Double,
               let lon = json["lon"] as? Double {
                await self.fetchWeatherFromAPI(lat: lat, lon: lon, cityName: city)
            }
        } catch {
            print("IP geolocation error: \(error)")
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
