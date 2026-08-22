import Foundation

struct IPWeatherLocation: Equatable, Sendable {
    let city: String
    let latitude: Double
    let longitude: Double
}

/// IP 自动定位的纯解析与 URL 构造层。网络请求由各平台自己的天气适配器执行。
enum IPGeolocation {
    static func publicIP(from data: Data?) -> String? {
        guard let data, let text = String(data: data, encoding: .utf8) else { return nil }
        let markers = ["当前 IP：", "当前 IP:"]
        for marker in markers {
            guard let range = text.range(of: marker) else { continue }
            let token = text[range.upperBound...].split(whereSeparator: { $0.isWhitespace }).first
            if let token, !token.isEmpty { return String(token) }
        }
        return nil
    }

    static func location(from data: Data?) -> IPWeatherLocation? {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["success"] as? Bool) != false,
              let city = object["city"] as? String, !city.isEmpty,
              let latitude = object["latitude"] as? NSNumber,
              let longitude = object["longitude"] as? NSNumber else { return nil }
        return IPWeatherLocation(
            city: city,
            latitude: latitude.doubleValue,
            longitude: longitude.doubleValue
        )
    }

    static func endpoint(publicIP: String?, language: AppLanguage) -> URL? {
        guard var url = URL(string: AppConfig.API.ipGeolocationBase) else { return nil }
        if let publicIP, !publicIP.isEmpty {
            url.appendPathComponent(publicIP)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let locale: String
        switch language {
        case .en: locale = "en"
        case .zhHans: locale = "zh-CN"
        case .zhHant: locale = "zh-TW"
        }
        components?.queryItems = [URLQueryItem(name: "lang", value: locale)]
        return components?.url
    }
}
