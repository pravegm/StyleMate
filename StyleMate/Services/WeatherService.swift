import Foundation
import CoreLocation

struct Weather: Codable {
    let temperature2m: Double
    let weathercode: Int
    let isDay: Int
    let time: String
    let city: String?
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            print("[Weather] Network error: \(error.localizedDescription)")
            throw error
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? "no body"
            print("[Weather] HTTP \(status): \(body)")
            throw URLError(.badServerResponse)
        }

        let decoded: WeatherResponse
        do {
            decoded = try JSONDecoder().decode(WeatherResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8)?.prefix(300) ?? "no body"
            print("[Weather] Decode failed: \(error) | body=\(body)")
            throw error
        }
        let current = decoded.current
        print("[Weather] OK: \(current.temperature_2m)° code=\(current.weather_code) day=\(current.is_day)")
        // Reverse geocode to get city name
        let city = try? await Self.reverseGeocodeCity(latitude: latitude, longitude: longitude)
        return Weather(
            temperature2m: current.temperature_2m,
            weathercode: current.weather_code,
            isDay: current.is_day,
            time: current.time,
            city: city
        )
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