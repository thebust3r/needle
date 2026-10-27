import Foundation
import Observation
import SwiftUI

// MARK: - Weather for the Home header (Open-Meteo: free, no key)

struct WeatherNow: Codable, Equatable {
    var temp: Int
    var code: Int
    var isDay: Bool
    var place: String

    var symbol: String { Self.symbol(code, isDay) }
    var words: String { Self.words(code) }

    static func symbol(_ c: Int, _ day: Bool) -> String {
        switch c {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func words(_ c: Int) -> String {
        switch c {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Foggy"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 80...82: return "Showers"
        case 95...99: return "Storms"
        default: return ""
        }
    }
}

@MainActor @Observable
final class WeatherStore {
    static let shared = WeatherStore()
    private(set) var now: WeatherNow?
    @ObservationIgnored private var fetchedAt: Date = .distantPast
    @ObservationIgnored private var fetchedFor = ""

    /// Where the weather is for. Default: Fayetteville, AR. Change it in Settings.
    var place: String {
        get { access(keyPath: \.place); return UserDefaults.standard.string(forKey: "weather.place") ?? "Fayetteville, AR" }
        set { withMutation(keyPath: \.place) { UserDefaults.standard.set(newValue, forKey: "weather.place") }; fetchedFor = "" }
    }
    var showWeather: Bool {
        get { access(keyPath: \.showWeather); return UserDefaults.standard.object(forKey: "weather.on") as? Bool ?? true }
        set { withMutation(keyPath: \.showWeather) { UserDefaults.standard.set(newValue, forKey: "weather.on") } }
    }

    private struct Geo: Decodable {
        struct R: Decodable { var name: String; var latitude: Double; var longitude: Double; var admin1: String?; var country_code: String? }
        var results: [R]?
    }
    private struct Forecast: Decodable {
        struct C: Decodable { var temperature_2m: Double; var weather_code: Int; var is_day: Int }
        var current: C
    }

    func refresh(force: Bool = false) async {
        guard showWeather else { return }
        let p = place
        guard force || p != fetchedFor || Date.now.timeIntervalSince(fetchedAt) > 20 * 60 else { return }
        do {
            var lat = 36.0626, lon = -94.1574, label = "Fayetteville"
            if p != "Fayetteville, AR" {
                let city = p.split(separator: ",").first.map(String.init) ?? p
                var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                c.queryItems = [.init(name: "name", value: city.trimmingCharacters(in: .whitespaces)), .init(name: "count", value: "1")]
                let (d, _) = try await URLSession.shared.data(from: c.url!)
                guard let r = try JSONDecoder().decode(Geo.self, from: d).results?.first else { return }
                lat = r.latitude; lon = r.longitude; label = r.name
            }
            let usesF = Locale.current.measurementSystem == .us
            var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            c.queryItems = [.init(name: "latitude", value: "\(lat)"), .init(name: "longitude", value: "\(lon)"),
                            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
                            .init(name: "temperature_unit", value: usesF ? "fahrenheit" : "celsius")]
            let (d, _) = try await URLSession.shared.data(from: c.url!)
            let f = try JSONDecoder().decode(Forecast.self, from: d)
            now = WeatherNow(temp: Int(f.current.temperature_2m.rounded()), code: f.current.weather_code, isDay: f.current.is_day == 1, place: label)
            fetchedAt = .now
            fetchedFor = p
        } catch {
            // no weather is fine; the header just leaves it out
        }
    }
}

// MARK: - Accent color

@Observable
final class AccentStore: @unchecked Sendable {
    static let shared = AccentStore()

    enum Choice: String, CaseIterable, Identifiable {
        case albumArt, teal, red, orange, pink, purple, blue, lime
        var id: String { rawValue }
        var label: String { self == .albumArt ? "Match Album Art" : rawValue.capitalized }
        var color: Color {
            switch self {
            case .albumArt, .teal: return Color(red: 0.43, green: 0.91, blue: 0.85)
            case .red: return Color(red: 1.0, green: 0.36, blue: 0.36)
            case .orange: return Color(red: 1.0, green: 0.62, blue: 0.30)
            case .pink: return Color(red: 1.0, green: 0.45, blue: 0.72)
            case .purple: return Color(red: 0.70, green: 0.56, blue: 1.0)
            case .blue: return Color(red: 0.38, green: 0.68, blue: 1.0)
            case .lime: return Color(red: 0.72, green: 0.95, blue: 0.36)
            }
        }
    }

    var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: "accent") }
    }
    /// The playing song's own color, used when "Match Album Art" is picked.
    var albumColor: Color?

    var color: Color { choice == .albumArt ? (albumColor ?? Choice.teal.color) : choice.color }

    init() {
        choice = Choice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .teal
    }
}
