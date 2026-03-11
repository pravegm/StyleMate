import SwiftUI
import CoreLocation

struct WeatherInlineRow: View {
    let weather: Weather?
    let isLoading: Bool
    let error: String?
    let locationStatus: CLAuthorizationStatus
    let onRequest: () -> Void
    let city: String?
    let temperatureC: Double?
    let temperatureF: Double?
    let displayFahrenheit: Bool
    let onToggleUnit: () -> Void

    var body: some View {
        Group {
            if isLoading {
                HStack(spacing: DS.Spacing.xs) {
                    ProgressView()
                    Text("Loading weather…")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            } else if let error = error {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(DS.Colors.warning)
                    Text(error)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                    Button("Retry", action: onRequest)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.accent)
                }
            } else if locationStatus == .denied || locationStatus == .restricted {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "location.slash")
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Location required")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                    Button("Grant", action: onRequest)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.accent)
                }
            } else if let weather = weather, let tempC = temperatureC, let tempF = temperatureF {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: weatherIconName(for: weather.weathercode, isDay: weather.isDay == 1))
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.accent)

                    Text("\(Int(displayFahrenheit ? tempF : tempC))°")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(weatherDescription(for: weather.weathercode))
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)

                    if let city = city {
                        Text("· \(city)")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button(action: { Haptics.light(); onToggleUnit() }) {
                        Text(displayFahrenheit ? "°F" : "°C")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.accent)
                            .padding(.horizontal, DS.Spacing.xs)
                            .padding(.vertical, DS.Spacing.micro)
                            .dsGlassChipUnselected()
                    }
                }
            } else {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "cloud")
                        .foregroundColor(DS.Colors.textTertiary)
                    Text("Weather unavailable")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
        }
    }

    func weatherIconName(for code: Int, isDay: Bool) -> String {
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

    func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: return "Clear sky"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61, 63, 65: return "Rain"
        case 66, 67: return "Freezing rain"
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
