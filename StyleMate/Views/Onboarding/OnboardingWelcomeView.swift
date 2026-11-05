import SwiftUI

struct OnboardingWelcomeView: View {
    let onAdvance: () -> Void
    /// "Try with sample photos": builds a sample closet from bundled CC0 photos.
    var onTrySamples: (() -> Void)? = nil

    @State private var glowVisible = false
    @State private var centerCardVisible = false
    @State private var innerCardsVisible = false
    @State private var outerCardsVisible = false
    @State private var breatheActive = false
    @State private var titleVisible = false
    @State private var subtitleVisible = false
    @State private var pill1Visible = false
    @State private var pill2Visible = false
    @State private var pill3Visible = false
    @State private var buttonVisible = false

    private struct CardSpec: Identifiable {
        let id: Int
        let icon: String
        let rotation: Double
        let yLift: CGFloat
    }

    private let cards: [CardSpec] = [
        CardSpec(id: 0, icon: "tshirt.fill", rotation: -20, yLift: 0),
        CardSpec(id: 1, icon: "shoe.fill", rotation: -10, yLift: -6),
        CardSpec(id: 2, icon: "bag.fill", rotation: 0, yLift: -12),
        CardSpec(id: 3, icon: "eyeglasses", rotation: 10, yLift: -6),
        CardSpec(id: 4, icon: "wind", rotation: 20, yLift: 0),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: DS.Spacing.sm)

            cardFan
                .frame(height: 150)

            textContent
                .padding(.top, DS.Spacing.md)

            featurePills
                .padding(.top, DS.Spacing.md)

            privacyNote
                .padding(.top, DS.Spacing.lg)
                .padding(.horizontal, DS.Spacing.xl)
                .opacity(buttonVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: buttonVisible)

            Spacer(minLength: DS.Spacing.md)

            VStack(spacing: DS.Spacing.sm) {
                ctaButton
                if let onTrySamples {
                    Button {
                        Haptics.light()
                        onTrySamples()
                    } label: {
                        Text("Try with sample photos")
                    }
                    .buttonStyle(DSTertiaryButton())
                    .accessibilityIdentifier("onboarding.trySamples")
                    .opacity(buttonVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.4).delay(0.1), value: buttonVisible)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
        }
        .background(
            // A radial gradient gives the same soft glow as a blurred circle but
            // without the expensive offscreen blur rasterization, which stalled the
            // main thread (~1.5s) on first render and made "Get Started" feel dead.
            RadialGradient(
                colors: [DS.Colors.accent.opacity(0.10), .clear],
                center: .center, startRadius: 0, endRadius: 250
            )
            .frame(width: 500, height: 500)
            .offset(y: -100)
            .opacity(glowVisible ? 1 : 0)
            .animation(.easeIn(duration: 0.5), value: glowVisible)
        )
        .onAppear { choreographEntrance() }
    }

    // MARK: - Card Fan

    private var cardFan: some View {
        ZStack {
            ForEach(cards) { card in
                let isCenter = card.id == 2
                let isInner = card.id == 1 || card.id == 3
                let visible = isCenter ? centerCardVisible : (isInner ? innerCardsVisible : outerCardsVisible)

                outfitCard(icon: card.icon)
                    .rotationEffect(.degrees(visible ? card.rotation : 0), anchor: .bottom)
                    .offset(y: visible ? card.yLift : 0)
                    .scaleEffect(visible ? 1.0 : 0.4)
                    .opacity(visible ? 1 : 0)
                    .animation(.spring(response: 0.6, dampingFraction: 0.7), value: visible)
            }
        }
        .scaleEffect(breatheActive ? 1.015 : 1.0)
    }

    private func outfitCard(icon: String) -> some View {
        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
            .fill(DS.Colors.backgroundCard)
            .frame(width: 70, height: 90)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(DS.Colors.accent.opacity(0.7))
            )
            .dsCardShadow()
    }

    // MARK: - Text Content

    private var textContent: some View {
        VStack(spacing: DS.Spacing.sm) {
            Text("Your camera roll already knows your wardrobe")
                .font(DS.Font.title1)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.lg)
                .offset(y: titleVisible ? 0 : 20)
                .opacity(titleVisible ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: titleVisible)

            Text("StyleMate finds the clothes you wear in your photos, builds your closet, and styles you every morning.")
                .font(DS.Font.callout)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.xl)
                .offset(y: subtitleVisible ? 0 : 20)
                .opacity(subtitleVisible ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: subtitleVisible)
        }
    }

    // MARK: - Feature Pills

    private var featurePills: some View {
        HStack(spacing: DS.Spacing.xs) {
            featurePill(icon: "camera.viewfinder", label: "Finds your clothes", visible: pill1Visible)
            featurePill(icon: "sparkles", label: "Daily outfits", visible: pill2Visible)
            featurePill(icon: "lock.shield.fill", label: "On your phone", visible: pill3Visible)
        }
    }

    private func featurePill(icon: String, label: String, visible: Bool) -> some View {
        HStack(spacing: DS.Spacing.micro) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.accent)
            Text(label)
                .font(DS.Font.caption1)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .offset(y: visible ? 0 : 15)
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: visible)
    }

    // MARK: - Privacy

    private var privacyNote: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(DS.Colors.accent)
                Text("No account. Your photos and face are analysed only on this iPhone. Your closet syncs only to your own iCloud. Nothing is sent to us.")
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
                .font(DS.Font.caption1.weight(.semibold))
                .foregroundStyle(DS.Colors.accent)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - CTA Button

    private var ctaButton: some View {
        Button {
            Haptics.medium()
            onAdvance()
        } label: {
            HStack(spacing: DS.Spacing.xs) {
                Text("Get Started")
                Image(systemName: "arrow.right")
            }
        }
        .buttonStyle(DSPrimaryButton())
        .accessibilityIdentifier("onboarding.getStarted")
        .offset(y: buttonVisible ? 0 : 20)
        .opacity(buttonVisible ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: buttonVisible)
    }

    // MARK: - Choreography

    private func choreographEntrance() {
        glowVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            centerCardVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            innerCardsVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            outerCardsVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            titleVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.80) {
            subtitleVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            pill1Visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.03) {
            pill2Visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.11) {
            pill3Visible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            buttonVisible = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                breatheActive = true
            }
        }
    }
}
