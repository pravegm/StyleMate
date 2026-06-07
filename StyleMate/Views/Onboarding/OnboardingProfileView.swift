import SwiftUI

/// Onboarding step: collect the user's name, age, and gender. Saved to the
/// signed-in user via AuthService (persisted to UserDefaults). Gender feeds
/// outfit suggestions; all fields are optional and editable later in Profile.
struct OnboardingProfileView: View {
    @EnvironmentObject var authService: AuthService
    let onAdvance: () -> Void

    @State private var name: String = ""
    @State private var age: String = ""
    @State private var gender: String = ""
    @State private var appeared = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, age }
    private let genders = ["Male", "Female"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text("About you")
                            .font(DS.Font.largeTitle)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("This helps StyleMate tailor outfit suggestions to you. You can change it anytime.")
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    .padding(.top, DS.Spacing.xl)

                    fieldCard(title: "Name") {
                        // NOTE: deliberately NO .textContentType(.givenName) here.
                        // That opts the field into name AutoFill, which queries the
                        // Contacts framework on first focus and stalls the main thread
                        // ~1-2s the moment you tap the field. Plain text input is instant.
                        TextField("Your name", text: $name)
                            .textContentType(.none)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focusedField, equals: .name)
                            .onSubmit { focusedField = .age }
                    }

                    fieldCard(title: "Gender") {
                        HStack(spacing: DS.Spacing.sm) {
                            ForEach(genders, id: \.self) { option in
                                genderPill(option)
                            }
                        }
                    }

                    fieldCard(title: "Age") {
                        TextField("Your age", text: $age)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .age)
                            .onChange(of: age) { newValue in
                                age = String(newValue.filter(\.isNumber).prefix(3))
                            }
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 16)
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: DS.Spacing.sm) {
                Button {
                    Haptics.medium()
                    save()
                    onAdvance()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(DSPrimaryButton())

                Button {
                    Haptics.light()
                    onAdvance()
                } label: {
                    Text("Skip for now")
                        .font(DS.Font.callout)
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(.top, DS.Spacing.micro)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
        }
        .onAppear {
            if let user = authService.user {
                name = (user.name == "User") ? "" : user.name
                gender = user.gender ?? ""
                age = user.age.map(String.init) ?? ""
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { appeared = true }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func fieldCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(title.uppercased())
                .font(DS.Font.footnote)
                .foregroundColor(DS.Colors.textTertiary)
            content()
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(DS.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
    }

    private func genderPill(_ option: String) -> some View {
        let selected = gender == option
        return Button {
            Haptics.light()
            gender = selected ? "" : option   // tap again to clear
        } label: {
            Text(option)
                .font(DS.Font.body)
                .foregroundColor(selected ? .white : DS.Colors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.sm)
                .background(selected ? DS.Colors.accent : DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(DSTapBounce())
    }

    private func save() {
        guard var user = authService.user else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { user.name = trimmed }
        user.gender = gender.isEmpty ? nil : gender
        user.age = Int(age)
        authService.user = user
        // Persist off the main actor so the tap/transition stays smooth.
        Task.detached(priority: .utility) {
            await MainActor.run { authService.saveCurrentUser() }
        }
    }
}
