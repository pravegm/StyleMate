import Foundation
import CoreLocation
import WeatherKit

struct Weather: Codable {
    let temperature2m: Double
    let weathercode: Int
    let isDay: Int
    let time: String
    let city: String?
    // Populated when the reading comes from Apple WeatherKit (richer than the
    // open-meteo WMO code). Optional so cached/open-meteo data still decodes.
    var symbolName: String? = nil
    var conditionText: String? = nil

    /// SF Symbol for the current condition. Prefers WeatherKit's own symbol,
    /// falling back to the WMO-code mapping for open-meteo / cached readings.
    var iconSymbol: String {
        symbolName ?? WeatherService.weatherIconName(for: weathercode, isDay: isDay == 1)
    }
    /// Human-readable condition. Prefers WeatherKit's localized description.
    var displayDescription: String {
        conditionText ?? WeatherService.weatherDescription(for: weathercode)
    }
}

struct WeatherResponse: Codable {
    struct Current: Codable {
        let temperature_2m: Double
        let weather_code: Int
        let is_day: Int
        let time: String
    }
    let current: Current
}

class WeatherService {
    static let shared = WeatherService()
    private init() {}
    
    func fetchWeather(latitude: Double, longitude: Double, useFahrenheit: Bool = false) async throws -> Weather {
        // Primary: Apple WeatherKit (reliable, accurate). Requires the WeatherKit
        // capability on the App ID; until that's enabled it throws and we fall
        // back to open-meteo below.
        if let wk = try? await fetchFromWeatherKit(latitude: latitude, longitude: longitude) {
            return wk
        }

        // Fallback: open-meteo (free, occasionally down).
        let unit = useFahrenheit ? "fahrenheit" : "celsius"
        let lat = String(format: "%.4f", latitude)
        let lon = String(format: "%.4f", longitude)
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day&temperature_unit=\(unit)"
        guard let url = URL(string: urlString) else {
            print("[Weather] Bad URL: \(urlString)")
            throw URLError(.badURL)
        }
        print("[Weather] Fetching: \(urlString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        // Retry transient failures (open-meteo's free tier occasionally returns
        // 5xx / times out). Decode failures are deterministic and not retried.
        let maxAttempts = 3
        var lastError: Error = URLError(.badServerResponse)

        for attempt in 1...maxAttempts {
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(attempt - 1) * 700_000_000)
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1

                if (500...599).contains(status) || status == -1 {
                    print("[Weather] HTTP \(status) (attempt \(attempt)/\(maxAttempts)), will retry")
                    lastError = URLError(.badServerResponse)
                    continue
                }
                guard status == 200 else {
                    let body = String(data: data, encoding: .utf8)?.prefix(200) ?? "no body"
                    print("[Weather] HTTP \(status): \(body)")
                    throw URLError(.badServerResponse)
                }

                let decoded = try JSONDecoder().decode(WeatherResponse.self, from: data)
                let current = decoded.current
                print("[Weather] OK: \(current.temperature_2m)° code=\(current.weather_code) day=\(current.is_day) (attempt \(attempt))")
                let city = try? await Self.reverseGeocodeCity(latitude: latitude, longitude: longitude)
                return Weather(
                    temperature2m: current.temperature_2m,
                    weathercode: current.weather_code,
                    isDay: current.is_day,
                    time: current.time,
                    city: city
                )
            } catch let decodeError as DecodingError {
                print("[Weather] Decode failed: \(decodeError)")
                throw decodeError
            } catch {
                print("[Weather] Attempt \(attempt)/\(maxAttempts) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }

        print("[Weather] All \(maxAttempts) attempts failed (open-meteo likely down)")
        throw lastError
    }

    // MARK: - Apple WeatherKit

    private func fetchFromWeatherKit(latitude: Double, longitude: Double) async throws -> Weather {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let current = try await WeatherKit.WeatherService.shared.weather(for: location, including: .current)
        let tempC = current.temperature.converted(to: .celsius).value
        let city = try? await Self.reverseGeocodeCity(latitude: latitude, longitude: longitude)
        print("[Weather] WeatherKit OK: \(String(format: "%.1f", tempC))° \(current.condition) day=\(current.isDaylight)")
        return Weather(
            temperature2m: tempC,
            weathercode: Self.wmoCode(for: current.condition),
            isDay: current.isDaylight ? 1 : 0,
            time: ISO8601DateFormatter().string(from: current.date),
            city: city,
            symbolName: current.symbolName,
            conditionText: current.condition.description
        )
    }

    /// Coarse mapping from WeatherKit's condition to an open-meteo WMO code, so
    /// any consumer still keyed on `weathercode` keeps working. The primary
    /// display path uses WeatherKit's own symbolName / condition text.
    static func wmoCode(for condition: WeatherCondition) -> Int {
        switch condition {
        case .clear, .hot: return 0
        case .mostlyClear: return 1
        case .partlyCloudy: return 2
        case .cloudy, .mostlyCloudy, .breezy, .windy: return 3
        case .foggy, .haze, .smoky: return 45
        case .drizzle: return 51
        case .freezingDrizzle: return 56
        case .rain: return 63
        case .heavyRain: return 65
        case .freezingRain: return 66
        case .snow, .flurries, .blowingSnow, .blizzard, .frigid: return 71
        case .heavySnow: return 75
        case .sleet, .wintryMix, .hail: return 85
        case .thunderstorms, .isolatedThunderstorms, .scatteredThunderstorms, .strongStorms: return 95
        default: return 3
        }
    }

    static func reverseGeocodeCity(latitude: Double, longitude: Double) async throws -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        let geocoder = CLGeocoder()
        return try await withCheckedThrowingContinuation { continuation in
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                if let city = placemarks?.first?.locality {
                    continuation.resume(returning: city)
                } else if let name = placemarks?.first?.name {
                    continuation.resume(returning: name)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    static func weatherIconName(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0: return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return "cloud.rain.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing Drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing Rain"
        case 71, 73, 75: return "Snow"
        case 77: return "Snow grains"
        case 80, 81, 82: return "Rain showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Unknown"
        }
    }
} 