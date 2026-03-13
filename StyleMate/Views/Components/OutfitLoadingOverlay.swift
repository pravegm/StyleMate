import SwiftUI

struct StylingLoadingView: View {
    let progress: Double
    var weather: Weather?

    @State private var pulseScale: CGFloat = 1.0

    private var stage: (icon: String, message: String, accent: Bool) {
        switch progress {
        case ..<0.20:
            return ("hanger", "Scanning your wardrobe...", false)
        case 0.20..<0.40:
            let weatherText: String
            if let w = weather, let city = w.city, !city.isEmpty {
                weatherText = "\(Int(w.temperature2m))°C in \(city)"
            } else if let w = weather {
                weatherText = "\(Int(w.temperature2m))°C"
            } else {
                weatherText = ""
            }
            let msg = weatherText.isEmpty ? "Checking today's weather..." : "Checking weather: \(weatherText)"
            return ("cloud.sun.fill", msg, false)
        case 0.40..<0.70:
            return ("paintpalette.fill", "Mixing colors and textures...", false)
        case 0.70..<0.90:
            return ("wand.and.stars", "Styling 5 outfits for you...", true)
        default:
            return ("checkmark.circle.fill", "Almost ready...", true)
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: DS.Spacing.lg) {
                Image(systemName: stage.icon)
                    .font(.system(size: 40))
                    .foregroundColor(stage.accent ? DS.Colors.accent : DS.Colors.textPrimary)
                    .scaleEffect(pulseScale)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            pulseScale = 1.15
                        }
                    }

                Text(stage.message)
                    .font(DS.Font.headline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .id(stage.message)
                    .animation(.easeInOut(duration: 0.4), value: stage.message)

                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: DS.Colors.accent))
                    .frame(width: 220)

                HStack(spacing: DS.Spacing.xs) {
                    let thresholds = [0.0, 0.20, 0.40, 0.70, 0.90]
                    ForEach(0..<5, id: \.self) { idx in
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

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()

            VStack(spacing: DS.Spacing.lg) {
                ProgressView(value: progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: DS.Colors.accent))
                    .frame(width: 200)

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
