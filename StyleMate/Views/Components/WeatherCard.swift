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
                    // Denied: only Settings can change it (asking again shows no prompt).
                    Button("Grant") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.accent)
                    .accessibilityIdentifier("home.weather.grant")
                }
            } else if let weather = weather, let tempC = temperatureC, let tempF = temperatureF {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: weather.iconSymbol)
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.accent)

                    // The unit sits on the temperature; tapping it switches °C / °F.
                    let degrees = Int((displayFahrenheit ? tempF : tempC).rounded())
                    Button(action: { Haptics.light(); onToggleUnit() }) {
                        HStack(alignment: .firstTextBaseline, spacing: 1) {
                            Text("\(degrees)°")
                                .font(DS.Font.display)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text(displayFahrenheit ? "F" : "C")
                                .font(DS.Font.title3)
                                .foregroundColor(DS.Colors.accent)
                        }
                    }
                    .buttonStyle(DSTapBounce())
                    .accessibilityLabel("\(degrees) degrees \(displayFahrenheit ? "Fahrenheit" : "Celsius")")
                    .accessibilityHint("Switches to \(displayFahrenheit ? "Celsius" : "Fahrenheit")")
                    .accessibilityIdentifier("home.temperatureUnit")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(weather.displayDescription)
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)

                        if let city = city {
                            Text(city)
                                .font(DS.Font.subheadline)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    // MET Norway and Open-Meteo (CC BY 4.0) ask for a credit next to their data.
                    Menu {
                        Link("Weather data: MET Norway", destination: URL(string: "https://api.met.no")!)
                        Link("Weather data: Open-Meteo.com (CC BY 4.0)", destination: URL(string: "https://open-meteo.com")!)
                    } label: {
                        Image(systemName: "info.circle")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(minWidth: 28, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Weather data sources")
                    .accessibilityIdentifier("home.weatherSources")
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
