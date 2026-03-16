import SwiftUI

struct OnboardingPhotoExplanationView: View {
    let onAdvance: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @State private var dotPhase: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            illustrationArea
                .frame(height: 200)
                .padding(.bottom, DS.Spacing.xl)

            VStack(spacing: DS.Spacing.sm) {
                Text("Build your wardrobe in minutes")
                    .font(DS.Font.title1)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.lg)
                    .offset(y: appeared ? 0 : 20)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.3), value: appeared)

                Text("We'll scan your recent photos to find your clothes automatically. Just take a quick selfie first so we know which photos are yours.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xl)
                    .offset(y: appeared ? 0 : 15)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.45), value: appeared)
            }

            trustSignals
                .padding(.top, DS.Spacing.xl)

            Spacer()

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    onAdvance()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(DSPrimaryButton())

                Button {
                    Haptics.light()
                    onSkip()
                } label: {
                    Text("I'll add items manually")
                        .font(DS.Font.callout)
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(.top, DS.Spacing.xs)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.xl)
            .offset(y: appeared ? 0 : 20)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.9), value: appeared)
        }
        .onAppear {
            appeared = true
            startDotAnimation()
        }
    }

    // MARK: - Illustration

    private var illustrationArea: some View {
        HStack(spacing: DS.Spacing.xl) {
            photoStack
                .offset(x: appeared ? 0 : -30)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.1), value: appeared)

            flowDots
                .frame(width: 60)

            wardrobeGrid
                .offset(x: appeared ? 0 : 30)
                .opacity(appeared ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.75).delay(0.2), value: appeared)
        }
    }

    private var photoStack: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .fill(DS.Colors.backgroundSecondary)
                    .frame(width: 60, height: 80)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 20))
                            .foregroundColor(DS.Colors.textTertiary)
                    )
                    .rotationEffect(.degrees(Double(index - 1) * 5))
                    .offset(x: CGFloat(index - 1) * 3, y: CGFloat(index - 1) * -2)
            }
        }
    }

    private var flowDots: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 6, height: 6)
                    .offset(x: flowDotOffset(for: index))
                    .opacity(flowDotOpacity(for: index))
            }
        }
    }

    private func flowDotOffset(for index: Int) -> CGFloat {
        let progress = (dotPhase + CGFloat(index) * 0.25).truncatingRemainder(dividingBy: 1.0)
        return -25 + progress * 50
    }

    private func flowDotOpacity(for index: Int) -> Double {
        let progress = (dotPhase + CGFloat(index) * 0.25).truncatingRemainder(dividingBy: 1.0)
        let fade = 1.0 - abs(progress - 0.5) * 2.0
        return appeared ? fade : 0
    }

    private func startDotAnimation() {
        withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
            dotPhase = 1.0
        }
    }

    private var wardrobeGrid: some View {
        let icons = ["tshirt.fill", "shoe.fill", "eyeglasses", "bag.fill", "crown.fill", "heart.fill"]
        let columns = [GridItem(.fixed(30), spacing: 4), GridItem(.fixed(30), spacing: 4)]

        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6)
                    .fill(DS.Colors.backgroundCard)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: icons[index])
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    )
            }
        }
    }

    // MARK: - Trust Signals

    private var trustSignals: some View {
        VStack(spacing: DS.Spacing.md) {
            trustRow(icon: "faceid", text: "Quick selfie to match your photos", emphasized: false, delay: 0.6)
            trustRow(icon: "clock.fill", text: "Scans your last 6 months", emphasized: false, delay: 0.7)
            trustRow(icon: "lock.shield.fill", text: "Everything stays on your device", emphasized: true, delay: 0.8)
        }
        .padding(.horizontal, DS.Spacing.xl)
    }

    private func trustRow(icon: String, text: String, emphasized: Bool, delay: Double) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(DS.Colors.accent.opacity(0.12))
                    .frame(width: 28, height: 28)

                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.accent)
            }

            Text(text)
                .font(emphasized ? DS.Font.headline : DS.Font.subheadline)
                .foregroundColor(emphasized ? DS.Colors.textPrimary : DS.Colors.textSecondary)

            Spacer()
        }
        .offset(y: appeared ? 0 : 15)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.75).delay(delay), value: appeared)
    }
}
