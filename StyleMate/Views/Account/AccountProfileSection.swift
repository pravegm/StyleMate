import SwiftUI

/// Profile's "Account" section: who's signed in, Sign Out, and Delete Account (App Review
/// 5.1.1(v)). Delete runs `onDeleteAccount` (Profile removes everything on the phone and the
/// account's iCloud zone) after a full-screen explanation that also says how to stop using Sign in
/// with Apple for StyleMate in Settings (Apple's token revocation needs a server StyleMate doesn't
/// have; see docs/LAUNCH-READINESS.md).
struct AccountProfileSection: View {
    let onDeleteAccount: @MainActor () -> Void

    @EnvironmentObject private var authService: AuthService
    @State private var confirmSignOut = false
    @State private var showDelete = false

    var body: some View {
        Section {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.Colors.onAccent)
                    .frame(width: 34, height: 34)
                    .background(DS.Colors.textPrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Signed in with Apple")
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundStyle(DS.Colors.textPrimary)
                    Text("Your closet, outfits and Premium belong to this account on every iPhone.")
                        .font(DS.Font.caption1)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile.account.status")
            .confirmationDialog("Sign out of StyleMate?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Haptics.medium()
                    authService.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your closet stays on this iPhone and in your iCloud. Sign in again with the same Apple Account to see it.")
            }
            .fullScreenCover(isPresented: $showDelete) {
                DeleteAccountView(onDelete: {
                    showDelete = false
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)   // let the cover close first
                        onDeleteAccount()
                    }
                }, onCancel: { showDelete = false })
            }

            Button {
                Haptics.light()
                confirmSignOut = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .foregroundStyle(DS.Colors.accent)
            .accessibilityIdentifier("profile.account.signOut")

            Button(role: .destructive) {
                Haptics.light()
                showDelete = true
            } label: {
                Label("Delete Account", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(DS.Colors.error)
            }
            .accessibilityIdentifier("profile.account.delete")
        } header: {
            Text("Account")
        } footer: {
            Text("StyleMate gets a private ID from Apple and the first name you chose to share. No email, no password.")
                .font(DS.Font.caption2)
        }
    }
}

/// What deleting the account removes, the two things only the person can do in Settings, and
/// the destructive button. Full screen so it works on the Duo's inner display (two panes, split on
/// the crease when half-open) as well as on a phone.
struct DeleteAccountView: View {
    let onDelete: () -> Void
    let onCancel: () -> Void
    @Environment(\.duoLayout) private var duo

    var body: some View {
        ZStack(alignment: .topTrailing) {
            DS.Colors.backgroundPrimary.ignoresSafeArea()
            ScrollView {
                if duo.isWideLayout {
                    FoldAwareSplit(gutter: DS.Spacing.xl, stackedSpacing: DS.Spacing.lg) {
                        whatGoes
                            .frame(maxWidth: 420, alignment: .leading)
                            .frame(maxWidth: .infinity)
                    } trailing: {
                        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                            settingsSteps
                            buttons
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.horizontal, DS.Spacing.lg)
                    .padding(.vertical, DS.Spacing.xxl)
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        whatGoes
                        settingsSteps
                        buttons
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.vertical, DS.Spacing.xxl)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollIndicators(.hidden)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(DS.Colors.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(DS.Colors.backgroundCard, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .padding(.trailing, DS.Spacing.sm)
            .padding(.top, DS.Spacing.xs)
            .accessibilityLabel("Cancel")
        }
        .accessibilityIdentifier("deleteAccount.root")
    }

    private var whatGoes: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(DS.Colors.error)
                .accessibilityHidden(true)
            Text("Delete your StyleMate account?")
                .font(DS.Font.title1)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("This permanently deletes, from this iPhone and from your iCloud:")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                row("tshirt", "Your wardrobe, including pieces waiting for Premium")
                row("calendar", "Your outfit calendar")
                row("face.smiling", "Your selfie and face data")
                row("icloud.slash", "This account's iCloud backup")
                row("key", "The account on this iPhone")
            }
            Text("Your photos aren't touched. Other iPhones signed in to this account keep what they have until you delete it there too.")
                .font(DS.Font.footnote)
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingsSteps: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Two things only you can do in Settings")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Colors.textPrimary)
            step("1", "Stop using Apple sign-in for StyleMate",
                 "Settings › your name › Sign-In & Security › Sign in with Apple › StyleMate › Stop Using Apple Account.")
            step("2", "Cancel Premium, if you have it",
                 "Deleting the account doesn't cancel the subscription: Settings › your name › Subscriptions › StyleMate Premium.")
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.backgroundCard, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .accessibilityIdentifier("deleteAccount.settingsSteps")
    }

    private var buttons: some View {
        VStack(spacing: DS.Spacing.sm) {
            Button(role: .destructive) {
                Haptics.warning()
                onDelete()
            } label: {
                Text("Delete Account")
                    .font(DS.Font.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: DS.ButtonSize.height)
                    .background(DS.Colors.error, in: RoundedRectangle(cornerRadius: DS.Radius.button, style: .continuous))
            }
            .accessibilityIdentifier("deleteAccount.confirm")
            Button("Keep my account", action: onCancel)
                .buttonStyle(DSSecondaryButton())
                .accessibilityIdentifier("deleteAccount.cancel")
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DS.Colors.error)
                .frame(width: 28, height: 28)
                .background(DS.Colors.error.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.subheadline)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Text(n)
                .font(DS.Font.caption1.weight(.bold))
                .foregroundStyle(DS.Colors.onAccent)
                .frame(width: 22, height: 22)
                .background(DS.Colors.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Font.subheadline.weight(.semibold))
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(detail)
                    .font(DS.Font.footnote)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
