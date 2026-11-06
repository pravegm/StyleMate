import SwiftUI
import AuthenticationServices

/// Sign in with Apple: the only way into StyleMate (onboarding step 2, and where a signed-out or
/// revoked session lands). Asks Apple for the name only (to say hello); never the email.
///
/// Phone / Duo cover: one column, the button low where the thumb is. Duo inner display (and other
/// wide layouts): `FoldAwareSplit`, the why on one half and the button on the other, split on the
/// crease when half-open, so nothing sits on the fold.
struct SignInView: View {
    var onBack: (() -> Void)? = nil

    @EnvironmentObject private var authService: AuthService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.duoLayout) private var duo
    @State private var errorMessage: String?
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            if duo.isWideLayout {
                ScrollView {
                    FoldAwareSplit(gutter: DS.Spacing.xl, stackedSpacing: DS.Spacing.xl) {
                        pitch
                            .frame(maxWidth: 420, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    } trailing: {
                        VStack(spacing: DS.Spacing.lg) {
                            signedOutBanner
                            signInPanel
                        }
                        .frame(maxWidth: 400)
                        .frame(maxWidth: .infinity)
                        .padding(.top, DS.Spacing.xxl)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.xxl)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        signedOutBanner
                        pitch
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.top, DS.Spacing.xxl)
                    .padding(.bottom, DS.Spacing.lg)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) {
                    // An opaque tray, so the reasons scrolling underneath never show through the button.
                    signInPanel
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.top, DS.Spacing.sm)
                        .padding(.bottom, DS.Spacing.sm)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            if let onBack {
                Button {
                    Haptics.light()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.Colors.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(DS.Colors.backgroundCard.opacity(0.9), in: Circle())
                        .dsCardShadow(cornerRadius: 18)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DSTapBounce())
                .padding(.leading, DS.Spacing.sm)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("signIn.back")
            }
        }
        .onAppear { withAnimation(DS.Motion.gentle) { appeared = true } }
    }

    private var background: some View {
        ZStack(alignment: .top) {
            DS.Colors.backgroundPrimary
            LinearGradient(colors: [DS.Colors.accentSoft, DS.Colors.backgroundPrimary.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 380)
        }
        .ignoresSafeArea()
    }

    // MARK: Pitch

    private var pitch: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            ZStack {
                Circle().fill(DS.Colors.accentSoft).frame(width: 84, height: 84)
                Circle().strokeBorder(DS.Colors.accent.opacity(0.2), lineWidth: 1).frame(width: 84, height: 84)
                Image(systemName: "hanger")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(DS.Colors.accent)
            }
            .scaleEffect(appeared ? 1 : 0.85)
            .opacity(appeared ? 1 : 0)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text("Your closet, on every iPhone")
                    .font(DS.Font.title1)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("signIn.title")
                Text("Sign in with your Apple Account. Your wardrobe, outfits and Premium belong to you, not to one phone.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                reason("person.crop.circle.badge.checkmark", "One account, every device",
                       "Your 50 free pieces and Premium follow you to a new iPhone.")
                reason("icloud.fill", "Backed up to your own iCloud",
                       "Your closet syncs privately. StyleMate has no server and never sees it.")
                reason("eye.slash.fill", "No email, no password",
                       "Apple gives StyleMate a private ID and your first name, nothing else.")
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 12)
    }

    private func reason(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Colors.accent)
                .frame(width: 34, height: 34)
                .background(DS.Colors.backgroundCard, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(detail)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var signedOutBanner: some View {
        if let reason = authService.signOutReason {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(DS.Colors.warning)
                Text(reason)
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("signIn.signedOutReason")
        }
    }

    // MARK: Sign in

    private var signInPanel: some View {
        VStack(spacing: DS.Spacing.sm) {
            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName]   // the name greets you; no email is asked for
            } onCompletion: { result in
                errorMessage = authService.handleAppleSignIn(result: result)
                if errorMessage == nil { Haptics.success() }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 54)
            // The Apple button has an internal width ≤ 375 constraint: cap it and centre it.
            .frame(maxWidth: 360)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("signIn.apple")

            #if DEBUG
            if DebugLaunchSupport.fakeSignInEnabled {
                Button("Continue as test user") {
                    authService.completeSignIn(appleUserID: DebugLaunchSupport.fakeSignInAppleUserID,
                                               fullName: PersonNameComponents(givenName: "Alex", familyName: "Demo"),
                                               isTestAccount: true)
                }
                .buttonStyle(DSSecondaryButton())
                .frame(maxWidth: 360)
                .accessibilityIdentifier("signIn.debugFake")
            }
            #endif

            if let errorMessage {
                Text(errorMessage)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("signIn.error")
            }

            VStack(spacing: 2) {
                Text("By continuing you agree to the")
                    .foregroundStyle(DS.Colors.textSecondary)
                HStack(spacing: 4) {
                    Link("Terms of Use", destination: PremiumProducts.termsOfUse)
                    Text("and").foregroundStyle(DS.Colors.textSecondary)
                    Link("Privacy Policy", destination: LegalLinks.privacyPolicy)
                }
                .foregroundStyle(DS.Colors.accent)
            }
            .font(DS.Font.caption1)
            .padding(.top, DS.Spacing.micro)
        }
    }
}
