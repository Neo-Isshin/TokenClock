import Foundation
import FoundationNetworking

/// Linux weather adapter for normal mode. `wttr.in` supplies both selected-city
/// and IP-based automatic weather without platform location frameworks.
final class LinuxWeatherService: @unchecked Sendable {
    private let lock = NSLock()
    private var storedWeather = WeatherInfo()
    private var generation = 0

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

        let location: String
        if city == "auto" {
            location = ""
        } else {
            location = city.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? city
        }
        guard let url = URL(string: "\(AppConfig.API.weatherBase)/\(location)?format=j1&m") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConfig.HTTP.requestTimeout
        request.setValue("TokenClock/1.0 (Linux)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data,
                  let parsed = Self.parse(data: data, fallbackCity: city == "auto" ? "" : city) else {
                if let error { print("[Weather] \(error.localizedDescription)") }
                return
            }
            self.lock.lock()
            guard self.generation == requestGeneration else {
                self.lock.unlock()
                return
            }
            self.storedWeather = parsed
            self.lock.unlock()
            completion()
        }.resume()
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
}
