import SwiftUI

struct OnboardingPhotoExplanationView: View {
    let onAdvance: () -> Void
    let onSkip: () -> Void

    // MARK: - Animation State

    @State private var leftGroupVisible = false
    @State private var rightGroupVisible = false
    @State private var headlineVisible = false
    @State private var bodyVisible = false
    @State private var trust1Visible = false
    @State private var trust2Visible = false
    @State private var trust3Visible = false
    @State private var ctaVisible = false
    @State private var flowPhase: CGFloat = 0

    private let photoIcons = ["photo.fill", "photo.fill", "photo.fill",
                              "photo.fill", "photo.fill", "photo.fill",
                              "photo.fill", "photo.fill", "photo.fill"]
    private let wardrobeIcons = ["tshirt.fill", "shoe.fill", "bag.fill",
                                 "eyeglasses", "crown.fill", "heart.fill"]
    private let photoRotations: [Double] = [-2, 1, -1, 3, -2, 2, -1, 0, 1]

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(minHeight: DS.Spacing.md)

            illustration
                .frame(height: 240)
                .padding(.bottom, DS.Spacing.lg)

            headline
            bodyText
                .padding(.top, DS.Spacing.xs)

            trustSignals
                .padding(.top, DS.Spacing.xl)

            Spacer()

            ctaArea
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.xl)
        }
        .onAppear { choreographEntrance() }
    }

    // MARK: - Illustration

    private var illustration: some View {
        HStack(spacing: 0) {
            Spacer()

            VStack(spacing: DS.Spacing.micro) {
                photoGrid
                Text("Your photos")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .offset(x: leftGroupVisible ? 0 : -20)
            .opacity(leftGroupVisible ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: leftGroupVisible)

            ZStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary.opacity(0.3))

                flowingDots
            }
            .frame(width: 70)

            VStack(spacing: DS.Spacing.micro) {
                wardrobeGrid
                Text("Your wardrobe")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.accent)
            }
            .offset(x: rightGroupVisible ? 0 : 20)
            .opacity(rightGroupVisible ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: rightGroupVisible)

            Spacer()
        }
    }

    private var photoGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(28), spacing: 3), count: 3)
        return LazyVGrid(columns: columns, spacing: 3) {
            ForEach(0..<9, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5)
                    .fill(DS.Colors.backgroundSecondary)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: photoIcons[i])
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    )
                    .rotationEffect(.degrees(photoRotations[i]))
            }
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(DS.Colors.textTertiary.opacity(0.15), lineWidth: 1)
        )
    }

    private var wardrobeGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 2)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 5)
                    .fill(DS.Colors.backgroundCard)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: wardrobeIcons[i])
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.accent)
                    )
            }
        }
        .padding(DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .stroke(DS.Colors.accent.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Flowing Dots

    private var flowingDots: some View {
        Canvas { context, size in
            let midY = size.height / 2
            let startX: CGFloat = 0
            let endX = size.width
            let curveHeight: CGFloat = 12

            for i in 0..<3 {
                let offset = CGFloat(i) * 0.33
                let t = (flowPhase + offset).truncatingRemainder(dividingBy: 1.0)
                let x = startX + t * (endX - startX)
                let y = midY - sin(t * .pi) * curveHeight
                let fade = 1.0 - abs(t - 0.5) * 2.0

                context.fill(
                    Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)),
                    with: .color(DS.Colors.accent.opacity(fade * 0.8))
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 6, y: y - 6, width: 12, height: 12)),
                    with: .color(DS.Colors.accent.opacity(fade * 0.15))
                )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Text

    private var headline: some View {
        Text("Build your wardrobe in minutes")
            .font(DS.Font.title1)
            .foregroundColor(DS.Colors.textPrimary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Spacing.lg)
            .offset(y: headlineVisible ? 0 : 20)
            .opacity(headlineVisible ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: headlineVisible)
    }

    private var bodyText: some View {
        Text("We'll scan your recent photos to find clothing items automatically. A quick selfie helps us find photos of you.")
            .font(DS.Font.body)
            .foregroundColor(DS.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DS.Spacing.xl)
            .offset(y: bodyVisible ? 0 : 15)
            .opacity(bodyVisible ? 1 : 0)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: bodyVisible)
    }

    // MARK: - Trust Signals

    private var trustSignals: some View {
        VStack(spacing: DS.Spacing.sm) {
            trustRow(icon: "faceid", text: "Quick selfie to find your photos",
                     emphasized: false, visible: trust1Visible)
            trustRow(icon: "clock.fill", text: "Scans your last 6 months",
                     emphasized: false, visible: trust2Visible)
            trustRow(icon: "lock.shield.fill", text: "Everything stays on your device",
                     emphasized: true, visible: trust3Visible)
        }
        .padding(.horizontal, DS.Spacing.xl)
    }

    private func trustRow(icon: String, text: String, emphasized: Bool, visible: Bool) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(DS.Colors.accent.opacity(0.1))
                    .frame(width: 28, height: 28)
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(DS.Colors.accent)
            }
            Text(text)
                .font(emphasized ? DS.Font.headline : DS.Font.subheadline)
                .foregroundColor(emphasized ? DS.Colors.textPrimary : DS.Colors.textSecondary)
            Spacer()
        }
        .offset(y: visible ? 0 : 12)
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: visible)
    }

    // MARK: - CTAs

    private var ctaArea: some View {
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
            .padding(.top, DS.Spacing.micro)
        }
        .offset(y: ctaVisible ? 0 : 20)
        .opacity(ctaVisible ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: ctaVisible)
    }

    // MARK: - Choreography

    private func choreographEntrance() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            leftGroupVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            rightGroupVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            headlineVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            bodyVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            trust1Visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) {
            trust2Visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.86) {
            trust3Visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            ctaVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                flowPhase = 1.0
            }
        }
    }
}
