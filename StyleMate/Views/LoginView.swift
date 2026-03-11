import SwiftUI
import AuthenticationServices
import GoogleSignInSwift

struct LoginView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var appear = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                // MARK: - Hero
                VStack(spacing: DS.Spacing.lg) {
                    ZStack {
                        Circle()
                            .fill(DS.Colors.backgroundSecondary)
                            .frame(width: 110, height: 110)

                        Image(systemName: "tshirt.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 52, height: 52)
                            .foregroundStyle(DS.Colors.accent)
                    }

                    VStack(spacing: DS.Spacing.xs) {
                        Text("StyleMate")
                            .font(DS.Font.largeTitle)
                            .foregroundColor(DS.Colors.textPrimary)

                        Text("Your AI-Powered Wardrobe")
                            .font(DS.Font.callout)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }

                    Text("Your wardrobe, simplified.")
                        .font(DS.Font.subheadline)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Spacing.xxl)
                }
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 30)
                .animation(.easeOut(duration: 0.9), value: appear)

                Spacer()

                // MARK: - Sign In Buttons (preserved exactly)
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
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

                    Button(action: { authService.handleGoogleSignIn() }) {
                        HStack(spacing: 10) {
                            GoogleLogoView()
                                .frame(width: 20, height: 20)
                            Text("Sign in with Google")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.1) : Color.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.15), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, DS.Spacing.xl)
                .opacity(appear ? 1 : 0)
                .offset(y: appear ? 0 : 20)
                .animation(.easeOut(duration: 0.9).delay(0.15), value: appear)

                Text("Your data stays private on this device")
                    .font(DS.Font.caption1)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .padding(.top, DS.Spacing.md)
                    .opacity(appear ? 1 : 0)
                    .animation(.easeOut(duration: 0.9).delay(0.25), value: appear)

                Spacer().frame(height: DS.Spacing.lg)

                // MARK: - Legal
                VStack(spacing: DS.Spacing.micro) {
                    Text("By continuing, you agree to our")
                        .font(DS.Font.caption2)
                        .foregroundStyle(DS.Colors.textTertiary)
                    HStack(spacing: 3) {
                        Link("Terms of Service", destination: URL(string: "https://your-terms-url.com")!)
                        Text("and")
                            .foregroundStyle(DS.Colors.textTertiary)
                        Link("Privacy Policy", destination: URL(string: "https://your-privacy-url.com")!)
                    }
                    .font(DS.Font.caption2)
                }
                .padding(.bottom, DS.Spacing.md)
                .opacity(appear ? 1 : 0)
                .animation(.easeOut(duration: 0.9).delay(0.35), value: appear)
            }
        }
        .onAppear { appear = true }
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

            var blueArc = Path()
            blueArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(-45), endAngle: .degrees(-135), clockwise: true)
            blueArc.addLine(to: CGPoint(x: cx, y: cy))
            blueArc.closeSubpath()
            context.fill(blueArc, with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))

            var greenArc = Path()
            greenArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(-45), endAngle: .degrees(45), clockwise: false)
            greenArc.addLine(to: CGPoint(x: cx, y: cy))
            greenArc.closeSubpath()
            context.fill(greenArc, with: .color(Color(red: 0.20, green: 0.66, blue: 0.33)))

            var yellowArc = Path()
            yellowArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(45), endAngle: .degrees(135), clockwise: false)
            yellowArc.addLine(to: CGPoint(x: cx, y: cy))
            yellowArc.closeSubpath()
            context.fill(yellowArc, with: .color(Color(red: 0.98, green: 0.74, blue: 0.02)))

            var redArc = Path()
            redArc.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(135), endAngle: .degrees(-135), clockwise: false)
            redArc.addLine(to: CGPoint(x: cx, y: cy))
            redArc.closeSubpath()
            context.fill(redArc, with: .color(Color(red: 0.92, green: 0.26, blue: 0.21)))

            let innerR = r * 0.55
            let innerCircle = Path(ellipseIn: CGRect(x: cx - innerR, y: cy - innerR, width: innerR * 2, height: innerR * 2))
            context.fill(innerCircle, with: .color(.white))

            let barH = r * 0.3
            let barRect = CGRect(x: cx, y: cy - barH / 2, width: r + 1, height: barH)
            context.fill(Path(barRect), with: .color(Color(red: 0.26, green: 0.52, blue: 0.96)))

            let cutoutRect = CGRect(x: cx + innerR * 0.2, y: cy - r, width: r, height: r - barH / 2)
            context.fill(Path(cutoutRect), with: .color(.white))
        }
    }
}

#Preview {
    LoginView()
}
