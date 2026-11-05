import SwiftUI

struct StylingLoadingView: View {
    let progress: Double
    var weather: Weather?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var barWidth: CGFloat = 220

    private var stage: (icon: String, message: String, accent: Bool) {
        switch progress {
        case ..<0.15:
            return ("hanger", "Opening your wardrobe...", false)
        case 0.15..<0.30:
            let weatherText: String
            if let w = weather, let city = w.city, !city.isEmpty {
                weatherText = "\(DSFormat.degrees(celsius: w.temperature2m, fahrenheit: false))°C in \(city)"
            } else if let w = weather {
                weatherText = "\(DSFormat.degrees(celsius: w.temperature2m, fahrenheit: false))°C"
            } else {
                weatherText = ""
            }
            let msg = weatherText.isEmpty ? "Checking today's weather..." : "It's \(weatherText) today"
            return ("cloud.sun.fill", msg, false)
        case 0.30..<0.50:
            return ("paintpalette.fill", "Matching colors and patterns...", false)
        case 0.50..<0.70:
            return ("ruler.fill", "Checking fits and layers...", false)
        case 0.70..<0.85:
            return ("wand.and.stars", "Putting together 5 looks...", true)
        default:
            return ("sparkles", "Adding the finishing touches...", true)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: DS.Spacing.lg) {
                Image(systemName: stage.icon)
                    .font(.system(size: 40))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(stage.accent ? DS.Colors.accent : DS.Colors.textPrimary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)

                Text(stage.message)
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .move(edge: .bottom)))
                    .id(stage.message)
                    .animation(.easeInOut(duration: 0.4), value: stage.message)

                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: DS.Colors.accent))
                    .frame(width: barWidth)

                HStack(spacing: DS.Spacing.xs) {
                    let thresholds = [0.0, 0.15, 0.30, 0.50, 0.70, 0.85]
                    ForEach(0..<6, id: \.self) { idx in
                        Circle()
                            .fill(progress >= thresholds[idx] ? DS.Colors.accent : DS.Colors.textTertiary.opacity(0.3))
                            .frame(width: 6, height: 6)
                            .animation(.easeInOut(duration: 0.3), value: progress >= thresholds[idx])
                    }
                }
            }
            .padding(DS.Spacing.xl)
            .padding(.horizontal, DS.Spacing.md)
            .dsGlassCard(cornerRadius: DS.Radius.sheet)
        }
        .transition(.opacity)
    }
}

struct OutfitLoadingOverlay: View {
    let progress: Double
    var message: String = "Analyzing your items…"
    @ScaledMetric(relativeTo: .headline) private var barWidth: CGFloat = 200

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()

            VStack(spacing: DS.Spacing.lg) {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: DS.Colors.accent))
                    .frame(width: barWidth)

                Text(message)
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
            }
            .padding(DS.Spacing.xl)
            .dsGlassCard(cornerRadius: DS.Radius.sheet)
        }
        .transition(.opacity)
    }
}
