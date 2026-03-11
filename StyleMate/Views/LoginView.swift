import SwiftUI
import AuthenticationServices
import GoogleSignInSwift

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var appear = false
    @State private var selectedQuote: String = ""
    @State private var pulseGlow = false
    @Environment(\.colorScheme) private var colorScheme

    let aiQuotes = [
        "Unlock daily style inspiration, powered by AI magic.",
        "Your next outfit is just an algorithm away.",
        "Style meets intelligence—welcome to your AI wardrobe.",
        "Fashion, reimagined by artificial intelligence.",
        "Let AI curate your closet, one look at a time.",
        "Smarter style starts here—with AI.",
        "AI: Your new personal stylist.",
        "Discover the future of fashion with AI.",
        "Dress smart. Dress AI.",
        "Where technology meets trend.",
        "AI-powered looks for every day.",
        "Your wardrobe, upgraded by AI.",
        "From code to couture—AI styles you.",
        "AI knows what looks good on you.",
        "Personalized fashion, powered by AI.",
        "Let AI help you find your signature style.",
        "The smartest way to dress is here."
    ]

    private var backgroundGradient: some View {
        ZStack {
            Color(colorScheme == .dark ? .black : .white)
                .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 200
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: -80, y: -200)
                .blur(radius: 60)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.pink.opacity(0.18), Color.pink.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 180
                    )
                )
                .frame(width: 360, height: 360)
                .offset(x: 100, y: -100)
                .blur(radius: 50)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.blue.opacity(0.12), Color.blue.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 160
                    )
                )
                .frame(width: 320, height: 320)
                .offset(x: 60, y: 280)
                .blur(radius: 50)
        }
    }

    var body: some View {
        ZStack {
            backgroundGradient

            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 80)

                // MARK: - Hero
                VStack(spacing: 20) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(pulseGlow ? 0.15 : 0.08))
                            .frame(width: 130, height: 130)
                            .scaleEffect(pulseGlow ? 1.1 : 1.0)
                            .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulseGlow)

                        Circle()
                            .fill(Color.accentColor.opacity(0.08))
                            .frame(width: 100, height: 100)

                        Image(systemName: "tshirt.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        MagicalSparkles()
                    }

                    VStack(spacing: 8) {
                        Text("StyleMate")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.primary)

                        Text("Your AI-Powered Wardrobe")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }

                    Text(selectedQuote)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor, Color.pink.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 30)
                .animation(.easeOut(duration: 0.9), value: appear)

                Spacer()

                // MARK: - Sign In Buttons
                VStack(spacing: 14) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        if let error = authService.handleAppleSignIn(result: result) {
                            errorMessage = error
                            showError = true
                        }
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Button(action: { authService.handleGoogleSignIn() }) {
                        HStack(spacing: 10) {
                            GoogleLogoView()
                                .frame(width: 20, height: 20)
                            Text("Sign in with Google")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 32)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)
                .animation(.easeOut(duration: 0.9).delay(0.15), value: appear)

                Text("Your data stays private on this device")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
                    .opacity(appear ? 1 : 0)
                    .animation(.easeOut(duration: 0.9).delay(0.25), value: appear)

                Spacer()
                    .frame(height: 24)

                // MARK: - Legal
                VStack(spacing: 4) {
                    Text("By continuing, you agree to our")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 3) {
                        Link("Terms of Service", destination: URL(string: "https://your-terms-url.com")!)
                        Text("and")
                            .foregroundStyle(.tertiary)
                        Link("Privacy Policy", destination: URL(string: "https://your-privacy-url.com")!)
                    }
                    .font(.caption2)
                }
                .padding(.bottom, 16)
                .opacity(appear ? 1 : 0)
                .animation(.easeOut(duration: 0.9).delay(0.35), value: appear)
            }
        }
        .onAppear {
            appear = true
            pulseGlow = true
            selectedQuote = aiQuotes.randomElement() ?? aiQuotes[0]
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

struct GoogleLogoView: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let cx = w / 2
            let cy = h / 2
            let r = min(w, h) / 2 * 0.85

            // Blue arc (top-right)
            var blueArc = Path()
            blueArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(-45), endAngle: .degrees(-135), clockwise: true)
            blueArc.addLine(to: CGPoint(x: cx, y: cy))
            blueArc.closeSubpath()
            context.fill(blueArc, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))

            // Green arc (bottom-right)
            var greenArc = Path()
            greenArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
            greenArc.addLine(to: CGPoint(x: cx, y: cy))
            greenArc.closeSubpath()
            context.fill(greenArc, with: .color(Color(red: 0.20, green: 0.66, blue: 0.33)))

            // Yellow arc (bottom-left)
            var yellowArc = Path()
            yellowArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(45), endAngle: .degrees(135), clockwise: false)
            yellowArc.addLine(to: CGPoint(x: cx, y: cy))
            yellowArc.closeSubpath()
            context.fill(yellowArc, with: .color(Color(red: 0.98, green: 0.74, blue: 0.02)))

            // Red arc (top-left)
            var redArc = Path()
            redArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(135), endAngle: .degrees(-135), clockwise: false)
            redArc.addLine(to: CGPoint(x: cx, y: cy))
            redArc.closeSubpath()
            context.fill(redArc, with: .color(Color(red: 0.92, green: 0.26, blue: 0.21)))

            // White inner circle
            let innerR = r * 0.55
            let innerCircle = Path(ellipseIn: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))
            context.fill(innerCircle, with: .color(.white))

            // Blue bar (right side cutout for the "G" opening)
            let barH = r * 0.3
            let barRect = CGRect(x: cx, y: cy - barH / 2, width: r + 1, height: barH)
            context.fill(Path(barRect), with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))

            // White cutout above the bar
            let cutoutRect = CGRect(x: cx + innerR * 0.2, y: cy - r, width: r, height: r - barH / 2)
            context.fill(Path(cutoutRect), with: .color(.white))
        }
    }
}

#Preview {
    LoginView()
}
