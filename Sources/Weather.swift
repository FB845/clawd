import Foundation

struct Weather {
    var tempC: Double
    var apparentC: Double
    var code: Int          // WMO weather code
    var isDay: Bool
    var windKph: Double
    var place: String

    var isRain: Bool { (51...67).contains(code) || (80...82).contains(code) }
    var isSnow: Bool { (71...77).contains(code) || code == 85 || code == 86 }
    var isThunder: Bool { code >= 95 }
    var isFog: Bool { code == 45 || code == 48 }
    var isClear: Bool { code <= 1 }

    var summary: String {
        switch code {
        case 0: return "clear"
        case 1: return "mostly clear"
        case 2: return "partly cloudy"
        case 3: return "overcast"
        case 45, 48: return "foggy"
        case 51...57: return "drizzly"
        case 61...67: return "rainy"
        case 71...77: return "snowy"
        case 80...82: return "showery"
        case 85, 86: return "snow showers"
        case 95...99: return "stormy"
        default: return "cloudy"
        }
    }

    /// Coarse bucket used to decide when conditions have "changed" enough to mention.
    var category: String {
        if isThunder { return "storm" }
        if isSnow { return "snow" }
        if isRain { return "rain" }
        if isFog { return "fog" }
        if apparentC <= 2 { return "freezing" }
        if apparentC <= 8 { return "cold" }
        if apparentC >= 28 { return "hot" }
        return isClear ? "clear" : "cloudy"
    }

    static func format(_ celsius: Double) -> String {
        if Locale.current.measurementSystem == .us {
            return "\(Int((celsius * 9 / 5 + 32).rounded()))°F"
        }
        return "\(Int(celsius.rounded()))°C"
    }
}

enum Season {
    case spring, summer, autumn, winter

    static func current(latitude: Double?) -> Season {
        let month = Calendar.current.component(.month, from: Date())
        var s: Season
        switch month {
        case 3...5: s = .spring
        case 6...8: s = .summer
        case 9...11: s = .autumn
        default: s = .winter
        }
        if let lat = latitude, lat < 0 {
            switch s {
            case .spring: s = .autumn
            case .summer: s = .winter
            case .autumn: s = .spring
            case .winter: s = .summer
            }
        }
        return s
    }
}

/// Location + weather lookups. Open-Meteo for weather and geocoding (free, no key),
/// ipapi.co once to guess a city when the user has not set one.
enum WeatherService {
    struct Location {
        var lat: Double
        var lon: Double
        var name: String
    }

    private static let defaults = UserDefaults.standard

    static var location: Location? {
        guard let name = defaults.string(forKey: "loc.name"),
              defaults.object(forKey: "loc.lat") != nil else { return nil }
        return Location(lat: defaults.double(forKey: "loc.lat"), lon: defaults.double(forKey: "loc.lon"), name: name)
    }

    static var locationIsUserSet: Bool { defaults.bool(forKey: "loc.userSet") }

    static func saveLocation(_ loc: Location?, userSet: Bool) {
        if let loc = loc {
            defaults.set(loc.lat, forKey: "loc.lat")
            defaults.set(loc.lon, forKey: "loc.lon")
            defaults.set(loc.name, forKey: "loc.name")
        } else {
            for k in ["loc.lat", "loc.lon", "loc.name"] { defaults.removeObject(forKey: k) }
        }
        defaults.set(userSet && loc != nil, forKey: "loc.userSet")
    }

    private static func getJSON(_ urlString: String, _ done: @escaping ([String: Any]?) -> Void) {
        guard let url = URL(string: urlString) else { done(nil); return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.setValue("Clawd/1.0 (desktop pet)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done(obj) }
        }.resume()
    }

    /// Rough city from the network address. Only used when no location has been set.
    static func detectLocation(_ done: @escaping (Location?) -> Void) {
        getJSON("https://ipapi.co/json/") { obj in
            guard let o = obj, let lat = o["latitude"] as? Double, let lon = o["longitude"] as? Double else { done(nil); return }
            let name = (o["city"] as? String) ?? (o["country_name"] as? String) ?? "here"
            done(Location(lat: lat, lon: lon, name: name))
        }
    }

    static func geocode(_ query: String, _ done: @escaping (Location?) -> Void) {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        getJSON("https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=en&format=json") { obj in
            guard let r = (obj?["results"] as? [[String: Any]])?.first,
                  let lat = r["latitude"] as? Double, let lon = r["longitude"] as? Double else { done(nil); return }
            done(Location(lat: lat, lon: lon, name: (r["name"] as? String) ?? query))
        }
    }

    static func fetch(_ loc: Location, _ done: @escaping (Weather?) -> Void) {
        let url = "https://api.open-meteo.com/v1/forecast?latitude=\(loc.lat)&longitude=\(loc.lon)" +
            "&current=temperature_2m,apparent_temperature,weather_code,is_day,wind_speed_10m&timezone=auto"
        getJSON(url) { obj in
            guard let c = obj?["current"] as? [String: Any],
                  let t = c["temperature_2m"] as? Double,
                  let code = c["weather_code"] as? Int else { done(nil); return }
            done(Weather(tempC: t,
                         apparentC: c["apparent_temperature"] as? Double ?? t,
                         code: code,
                         isDay: (c["is_day"] as? Int ?? 1) == 1,
                         windKph: c["wind_speed_10m"] as? Double ?? 0,
                         place: loc.name))
        }
    }
}
