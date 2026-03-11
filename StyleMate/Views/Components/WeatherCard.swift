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
                    Image(systemName: WeatherService.weatherIconName(for: weather.weathercode, isDay: weather.isDay == 1))
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.accent)

                    Text("\(Int(displayFahrenheit ? tempF : tempC))°")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text(WeatherService.weatherDescription(for: weather.weathercode))
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

}
