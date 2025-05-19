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
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,weather_code,is_day&temperature_unit=\(unit)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(WeatherResponse.self, from: data)
        let current = decoded.current
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
} 