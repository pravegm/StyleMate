import SwiftUI

struct GeminiConsentView: View {
    let onConsent: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Spacer()

            VStack(spacing: DS.Spacing.md) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 44))
                    .foregroundColor(DS.Colors.accent)

                Text("AI Clothing Analysis")
                    .font(DS.Font.title3)
                    .foregroundColor(DS.Colors.textPrimary)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                consentBullet(
                    icon: "photo",
                    text: "Your photos will be sent to **Google Gemini**, a third-party AI service, to identify and classify clothing items."
                )

                consentBullet(
                    icon: "eye.slash",
                    text: "Photos are processed for classification only. Google does not use images sent via the API to train its models."
                )

                consentBullet(
                    icon: "iphone",
                    text: "Face matching happens entirely **on your device**. No facial data is ever sent to any server."
                )

                consentBullet(
                    icon: "trash",
                    text: "You can delete all your data at any time from Profile settings."
                )
            }
            .padding(DS.Spacing.md)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))

            Button {
                if let url = URL(string: "https://ai.google.dev/gemini-api/terms") {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                    Text("Google Gemini API Terms of Service")
                        .font(DS.Font.caption1)
                }
                .foregroundColor(DS.Colors.accent)
            }

            Spacer()

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    onConsent()
                } label: {
                    HStack {
                        Spacer()
                        Text("I Agree — Continue")
                        Spacer()
                    }
                }
                .buttonStyle(DSPrimaryButton(isDisabled: false))
                .accessibilityLabel("I agree to send photos to Google Gemini for clothing analysis")

                Button {
                    Haptics.light()
                    onDecline()
                } label: {
                    Text("Not Now")
                        .font(DS.Font.callout)
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.sm)
                }
                .accessibilityLabel("Decline. Photos will not be sent for analysis.")
            }
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .padding(.vertical, DS.Spacing.lg)
        .background(DS.Colors.backgroundPrimary.ignoresSafeArea())
    }

    private func consentBullet(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(DS.Colors.accent)
                .frame(width: 20, alignment: .center)
                .padding(.top, 2)

            Text(text)
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Consent Helper

enum GeminiConsent {
    private static func key(for userId: String) -> String {
        "hasConsentedToGeminiScan_\(userId)"
    }

    static func hasConsented(userId: String) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: userId))
    }

    static func grant(userId: String) {
        UserDefaults.standard.set(true, forKey: key(for: userId))
    }

    static func revoke(userId: String) {
        UserDefaults.standard.removeObject(forKey: key(for: userId))
    }
}
