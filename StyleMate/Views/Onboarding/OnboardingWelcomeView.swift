import SwiftUI

struct OnboardingWelcomeView: View {
    let onAdvance: () -> Void

    // MARK: - Animation State (Rule 1: separate triggers)

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

    // Shimmer (Rule 5: Timer-driven)
    @State private var shimmerX: CGFloat = -100
    private let shimmerTimer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

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
        GeometryReader { geo in
            ZStack {
                backgroundGlow(in: geo)

                VStack(spacing: 0) {
                    Spacer().frame(minHeight: DS.Spacing.xl)

                    cardFan
                        .frame(height: geo.size.height * 0.38)

                    textContent
                        .padding(.top, DS.Spacing.lg)

                    featurePills
                        .padding(.top, DS.Spacing.lg)

                    Spacer()

                    ctaButton(screenWidth: geo.size.width)
                        .padding(.horizontal, DS.Spacing.lg)
                        .padding(.bottom, DS.Spacing.xl)
                }
            }
        }
        .onAppear { choreographEntrance() }
    }

    // MARK: - Background Glow

    private func backgroundGlow(in geo: GeometryProxy) -> some View {
        Circle()
            .fill(DS.Colors.accent.opacity(0.05))
            .frame(width: geo.size.width * 1.2)
            .blur(radius: 100)
            .offset(y: -geo.size.height * 0.15)
            .opacity(glowVisible ? 1 : 0)
            .animation(.easeIn(duration: 0.5), value: glowVisible)
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
                    .animation(
                        .spring(response: 0.6, dampingFraction: 0.7),
                        value: visible
                    )
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
            Text("Never wonder what to wear")
                .font(DS.Font.display)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.lg)
                .offset(y: titleVisible ? 0 : 20)
                .opacity(titleVisible ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: titleVisible)

            Text("AI-powered outfit suggestions from your own wardrobe")
                .font(DS.Font.callout)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Spacing.xl)
                .offset(y: subtitleVisible ? 0 : 20)
                .opacity(subtitleVisible ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.8), value: subtitleVisible)
        }
    }

    // MARK: - Feature Pills

    private var featurePills: some View {
        HStack(spacing: DS.Spacing.xs) {
            featurePill(icon: "camera.viewfinder", label: "Auto-detect", visible: pill1Visible)
            featurePill(icon: "sparkles", label: "AI styling", visible: pill2Visible)
            featurePill(icon: "icloud.fill", label: "iCloud sync", visible: pill3Visible)
        }
    }

    private func featurePill(icon: String, label: String, visible: Bool) -> some View {
        HStack(spacing: DS.Spacing.micro) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.accent)
            Text(label)
                .font(DS.Font.caption1)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Colors.backgroundSecondary, in: Capsule())
        .offset(y: visible ? 0 : 15)
        .opacity(visible ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: visible)
    }

    // MARK: - CTA Button

    private func ctaButton(screenWidth: CGFloat) -> some View {
        Button {
            Haptics.medium()
            onAdvance()
        } label: {
            Text("Get Started")
                .overlay(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 30)
                    .offset(x: shimmerX)
                    .clipped()
                )
                .clipped()
        }
        .buttonStyle(DSPrimaryButton())
        .offset(y: buttonVisible ? 0 : 20)
        .opacity(buttonVisible ? 1 : 0)
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: buttonVisible)
        .onReceive(shimmerTimer) { _ in
            shimmerX = -100
            withAnimation(.linear(duration: 0.6)) {
                shimmerX = screenWidth + 100
            }
        }
    }

    // MARK: - Choreography

    private func choreographEntrance() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.0) {
            glowVisible = true
        }
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
