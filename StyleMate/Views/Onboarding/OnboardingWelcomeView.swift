import SwiftUI

struct OnboardingWelcomeView: View {
    let onAdvance: () -> Void

    @State private var appeared = false
    @State private var shimmerOffset: CGFloat = -200

    private struct OrbitIcon: Identifiable {
        let id = UUID()
        let systemName: String
        let angle: Double
        let distance: CGFloat
    }

    private let orbitIcons: [OrbitIcon] = [
        OrbitIcon(systemName: "shoe.fill", angle: -60, distance: 95),
        OrbitIcon(systemName: "eyeglasses", angle: -20, distance: 100),
        OrbitIcon(systemName: "bag.fill", angle: 20, distance: 95),
        OrbitIcon(systemName: "crown.fill", angle: 60, distance: 100),
        OrbitIcon(systemName: "heart.fill", angle: 100, distance: 90),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            heroAnimation
                .frame(height: 260)

            Spacer().frame(height: DS.Spacing.xl)

            VStack(spacing: DS.Spacing.sm) {
                Text("Your wardrobe, organized by AI")
                    .font(DS.Font.display)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, DS.Spacing.lg)
                    .offset(y: appeared ? 0 : 20)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.4), value: appeared)

                Text("Snap your clothes. Get styled every morning.")
                    .font(DS.Font.callout)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xl)
                    .offset(y: appeared ? 0 : 20)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.55), value: appeared)
            }

            valuePillars
                .padding(.top, DS.Spacing.xl)

            Spacer()

            ctaButton
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.xl)
        }
        .onAppear { appeared = true }
    }

    // MARK: - Hero Animation

    private var heroAnimation: some View {
        ZStack {
            ForEach(Array(orbitIcons.enumerated()), id: \.element.id) { index, icon in
                let radians = icon.angle * .pi / 180
                let x = cos(radians) * icon.distance
                let y = sin(radians) * icon.distance - 20

                ZStack {
                    Circle()
                        .fill(DS.Colors.backgroundSecondary)
                        .frame(width: 44, height: 44)

                    Image(systemName: icon.systemName)
                        .font(.system(size: 24))
                        .foregroundColor(DS.Colors.textSecondary.opacity(0.6))
                }
                .offset(x: appeared ? x : 0, y: appeared ? y : 0)
                .scaleEffect(appeared ? 1 : 0)
                .opacity(appeared ? 1 : 0)
                .animation(
                    .spring(response: 0.5, dampingFraction: 0.65)
                        .delay(0.3 + Double(index) * 0.05),
                    value: appeared
                )
                .modifier(FloatingModifier(
                    amplitude: 2,
                    period: 3,
                    phase: Double(index) * 0.4,
                    active: appeared
                ))
            }

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 130, height: 130)

                Image(systemName: "tshirt.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.white)
            }
            .scaleEffect(appeared ? 1 : 0.5)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.45, dampingFraction: 0.7).delay(0.1), value: appeared)
        }
    }

    // MARK: - Value Pillars

    private var valuePillars: some View {
        VStack(spacing: DS.Spacing.md) {
            valuePillarRow(icon: "camera.viewfinder", text: "AI detects your clothing automatically", delay: 0.65)
            valuePillarRow(icon: "sparkles", text: "Daily outfit suggestions, styled for your day", delay: 0.75)
            valuePillarRow(icon: "icloud.fill", text: "Synced safely to iCloud across devices", delay: 0.85)
        }
        .padding(.horizontal, DS.Spacing.xl)
    }

    private func valuePillarRow(icon: String, text: String, delay: Double) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(DS.Colors.accent.opacity(0.12))
                    .frame(width: 36, height: 36)

                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(DS.Colors.accent)
            }

            Text(text)
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()
        }
        .offset(x: appeared ? 0 : -30)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.75).delay(delay), value: appeared)
    }

    // MARK: - CTA Button

    private var ctaButton: some View {
        Button {
            Haptics.medium()
            onAdvance()
        } label: {
            Text("Let's Go")
                .overlay(shimmerOverlay)
        }
        .buttonStyle(DSPrimaryButton())
        .offset(y: appeared ? 0 : 30)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.8), value: appeared)
        .onAppear { startShimmer() }
    }

    private var shimmerOverlay: some View {
        GeometryReader { geometry in
            LinearGradient(
                colors: [
                    Color.white.opacity(0),
                    Color.white.opacity(0.1),
                    Color.white.opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 60)
            .offset(x: shimmerOffset)
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .allowsHitTesting(false)
        .clipped()
    }

    private func startShimmer() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.linear(duration: 0.8)) {
                shimmerOffset = 400
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                shimmerOffset = -200
                startShimmer()
            }
        }
    }
}

// MARK: - Floating Animation Modifier

private struct FloatingModifier: ViewModifier {
    let amplitude: CGFloat
    let period: Double
    let phase: Double
    let active: Bool

    @State private var floating = false

    func body(content: Content) -> some View {
        content
            .offset(y: active && floating ? -amplitude : amplitude)
            .animation(
                active
                    ? .easeInOut(duration: period).repeatForever(autoreverses: true).delay(phase)
                    : .default,
                value: floating
            )
            .onAppear {
                if active {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + phase) {
                        floating = true
                    }
                }
            }
            .onChange(of: active) { isActive in
                if isActive {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + phase) {
                        floating = true
                    }
                }
            }
    }
}
