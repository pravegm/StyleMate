import Foundation
import CoreLocation

struct Weather: Codable {
    let temperature2m: Double
    let weathercode: Int
    let isDay: Int
    let time: String
    let city: String?
    // Populated by met.no (its own symbol code maps directly to an SF Symbol +
    // description). Optional so open-meteo / cached data still decodes.
    var symbolName: String? = nil
    var conditionText: String? = nil

    /// SF Symbol for the current condition. Prefers met.no's mapped symbol,
    /// falling back to the WMO-code mapping for open-meteo / cached readings.
    var iconSymbol: String {
        symbolName ?? WeatherService.weatherIconName(for: weathercode, isDay: isDay == 1)
    }
    /// Human-readable condition.
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
        // Two free providers backing each other up: try MET Norway first (it has
        // been the more reliable of the two), fall back to open-meteo if met.no
        // is unreachable.
        do {
            return try await fetchFromMetNo(latitude: latitude, longitude: longitude)
        } catch {
            print("[Weather] met.no failed (\(error.localizedDescription)); trying open-meteo")
            return try await fetchFromOpenMeteo(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: - open-meteo (fallback)

    private func fetchFromOpenMeteo(latitude: Double, longitude: Double) async throws -> Weather {
        let lat = String(format: "%.4f", latitude)
        let lon = String(format: "%.4f", longitude)
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day&temperature_unit=celsius"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        print("[Weather] Fetching (open-meteo): \(urlString)")

        let maxAttempts = 3
        var lastError: Error = URLError(.badServerResponse)
        for attempt in 1...maxAttempts {
            if attempt > 1 { try? await Task.sleep(nanoseconds: UInt64(attempt - 1) * 600_000_000) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if (500...599).contains(status) || status == -1 {
                    print("[Weather] open-meteo HTTP \(status) (attempt \(attempt))")
                    lastError = URLError(.badServerResponse)
                    continue
                }
                guard status == 200 else { throw URLError(.badServerResponse) }
                let c = try JSONDecoder().decode(WeatherResponse.self, from: data).current
                let city = try? await Self.reverseGeocodeCity(latitude: latitude, longitude: longitude)
                print("[Weather] open-meteo OK: \(c.temperature_2m)° code=\(c.weather_code) (attempt \(attempt))")
                return Weather(temperature2m: c.temperature_2m, weathercode: c.weather_code,
                               isDay: c.is_day, time: c.time, city: city)
            } catch let d as DecodingError {
                print("[Weather] open-meteo decode failed: \(d)")
                throw d
            } catch {
                print("[Weather] open-meteo attempt \(attempt) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }
        print("[Weather] open-meteo: all \(maxAttempts) attempts failed")
        throw lastError
    }

    // MARK: - MET Norway (api.met.no)

    private struct MetNoResponse: Codable {
        struct Properties: Codable { let timeseries: [TimeSeries] }
        struct TimeSeries: Codable { let time: String; let data: TSData }
        struct TSData: Codable {
            let instant: Instant
            let next_1_hours: Period?
            let next_6_hours: Period?
        }
        struct Instant: Codable { let details: Details }
        struct Details: Codable { let air_temperature: Double }
        struct Period: Codable { let summary: Summary }
        struct Summary: Codable { let symbol_code: String }
        let properties: Properties
    }

    private func fetchFromMetNo(latitude: Double, longitude: Double) async throws -> Weather {
        let lat = String(format: "%.4f", latitude)
        let lon = String(format: "%.4f", longitude)
        let urlString = "https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=\(lat)&lon=\(lon)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // MET Norway requires an identifying User-Agent or it returns 403.
        request.setValue("StyleMate/1.0 (github.com/pravegm/StyleMate)", forHTTPHeaderField: "User-Agent")

        print("[Weather] Fetching (met.no): \(urlString)")

        let maxAttempts = 3
        var lastError: Error = URLError(.badServerResponse)
        for attempt in 1...maxAttempts {
            if attempt > 1 { try? await Task.sleep(nanoseconds: UInt64(attempt - 1) * 600_000_000) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if status != 200 {
                    let body = String(data: data, encoding: .utf8)?.prefix(200) ?? "no body"
                    print("[Weather] met.no HTTP \(status) (attempt \(attempt)): \(body)")
                    lastError = URLError(.badServerResponse)
                    if (500...599).contains(status) || status == -1 { continue }
                    throw URLError(.badServerResponse)
                }

                let decoded = try JSONDecoder().decode(MetNoResponse.self, from: data)
                guard let first = decoded.properties.timeseries.first else {
                    throw URLError(.cannotParseResponse)
                }
                let tempC = first.data.instant.details.air_temperature
                let symbolCode = first.data.next_1_hours?.summary.symbol_code
                    ?? first.data.next_6_hours?.summary.symbol_code
                    ?? "cloudy"
                let (icon, desc, isDay) = Self.mapMetNoSymbol(symbolCode)
                let city = try? await Self.reverseGeocodeCity(latitude: latitude, longitude: longitude)

                print("[Weather] met.no OK: \(tempC)° \(symbolCode) -> \(desc) day=\(isDay) (attempt \(attempt))")
                return Weather(
                    temperature2m: tempC,
                    weathercode: 0,
                    isDay: isDay ? 1 : 0,
                    time: first.time,
                    city: city,
                    symbolName: icon,
                    conditionText: desc
                )
            } catch let decodeError as DecodingError {
                print("[Weather] met.no decode failed: \(decodeError)")
                throw decodeError
            } catch {
                print("[Weather] met.no attempt \(attempt) failed: \(error.localizedDescription)")
                lastError = error
                continue
            }
        }
        print("[Weather] met.no: all \(maxAttempts) attempts failed")
        throw lastError
    }

    /// Maps a MET Norway symbol_code (e.g. "rainshowers_day", "clearsky_night")
    /// to an SF Symbol, a description, and a day/night flag.
    static func mapMetNoSymbol(_ code: String) -> (icon: String, description: String, isDay: Bool) {
        let isNight = code.hasSuffix("_night")
        let isDay = !isNight
        // Strip the _day / _night / _polartwilight suffix to get the base condition.
        var base = code
        for suffix in ["_day", "_night", "_polartwilight"] {
            if base.hasSuffix(suffix) { base = String(base.dropLast(suffix.count)); break }
        }

        func icon(_ day: String, _ night: String) -> String { isNight ? night : day }

        if base.contains("thunder") {
            return (icon("cloud.bolt.rain.fill", "cloud.bolt.rain.fill"), "Thunderstorm", isDay)
        }
        if base.contains("sleet") {
            return ("cloud.sleet.fill", "Sleet", isDay)
        }
        if base.contains("snow") {
            return ("cloud.snow.fill", "Snow", isDay)
        }
        if base.contains("heavyrain") {
            return ("cloud.heavyrain.fill", "Heavy rain", isDay)
        }
        if base.contains("rain") || base.contains("drizzle") {
            let heavy = base.contains("light")
            return ("cloud.rain.fill", heavy ? "Light rain" : "Rain", isDay)
        }
        if base.contains("fog") {
            return ("cloud.fog.fill", "Fog", isDay)
        }
        switch base {
        case "clearsky":
            return (icon("sun.max.fill", "moon.stars.fill"), "Clear sky", isDay)
        case "fair":
            return (icon("sun.max.fill", "moon.stars.fill"), "Fair", isDay)
        case "partlycloudy":
            return (icon("cloud.sun.fill", "cloud.moon.fill"), "Partly cloudy", isDay)
        case "cloudy":
            return ("cloud.fill", "Cloudy", isDay)
        default:
            return ("cloud.fill", base.capitalized, isDay)
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