import SwiftUI
import CoreLocation

struct WeatherCard: View {
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
        HomeCard {
            VStack(spacing: 10) {
                // Header: match style of card above
                Text("Today's Weather in \(city ?? "—")")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(red: 0.18, green: 0.44, blue: 0.97)) // match blue
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                // 4-column layout
                if isLoading {
                    ProgressView("Loading weather...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else if let error = error {
                    VStack(spacing: 4) {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.body)
                            .multilineTextAlignment(.center)
                        Button("Retry", action: onRequest)
                            .font(.headline)
                            .padding(.top, 2)
                    }
                } else if locationStatus == .denied || locationStatus == .restricted {
                    VStack(spacing: 4) {
                        Text("Location permission is required to show weather.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Grant Permission", action: onRequest)
                            .font(.headline)
                            .padding(.top, 2)
                    }
                } else if let weather = weather, let tempC = temperatureC, let tempF = temperatureF {
                    HStack(alignment: .center, spacing: 0) {
                        // Column 1: Icon
                        Image(systemName: weatherIconName(for: weather.weathercode, isDay: weather.isDay == 1))
                            .font(.system(size: 34))
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .center)
                        // Column 2: Temp + unit
                        Text("\(Int(displayFahrenheit ? tempF : tempC))°" + (displayFahrenheit ? "F" : "C"))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .center)
                        // Column 3: Description
                        let desc = weatherDescription(for: weather.weathercode)
                        Text(desc)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                        // Column 4: Toggle
                        Picker("Unit", selection: Binding(
                            get: { displayFahrenheit ? 1 : 0 },
                            set: { _ in onToggleUnit() }
                        )) {
                            Text("°C").tag(0)
                            Text("°F").tag(1)
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 90)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("Weather unavailable.")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.vertical, 0)
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