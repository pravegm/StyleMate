import SwiftUI

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
