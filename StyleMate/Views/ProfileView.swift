import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @ObservedObject private var cloudKitService = CloudKitService.shared
    @State private var showingSignOutAlert = false
    @State private var showEmptyConfirmation = false
    @State private var showStyleSheet = false
    @State private var tempSelectedStyles: [OutfitType] = []
    @State private var showStyleError = false
    @State private var editGender: String = ""
    @State private var editAge: String = ""
    @State private var iCloudAvailable = true
    let genderOptions = ["", "Male", "Female"]

    private let maxStyles = 6
    private let allStyles = OutfitType.allCases

    var body: some View {
        NavigationStack {
            Form {
                // Profile header
                if let user = authService.user {
                    Section {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            Text(user.name)
                                .font(DS.Font.title2)
                                .foregroundColor(DS.Colors.textPrimary)

                            if let email = user.email, !email.isEmpty {
                                Text(email)
                                    .font(DS.Font.subheadline)
                                    .foregroundColor(DS.Colors.textSecondary)
                            }

                            Text("\(wardrobeViewModel.items.count) items")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.top, DS.Spacing.micro)
                        }
                        .padding(.vertical, DS.Spacing.xs)
                    }

                    Section("Personal Information") {
                        Picker("Gender", selection: $editGender) {
                            ForEach(genderOptions, id: \.self) { option in
                                Text(option.isEmpty ? "Select Gender" : option).tag(option)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onAppear { editGender = user.gender ?? "" }
                        .onChange(of: editGender) { newGender in
                            if var user = authService.user {
                                user.gender = newGender.isEmpty ? nil : newGender
                                authService.user = user
                                authService.saveCurrentUser()
                            }
                        }

                        TextField("Age", text: $editAge)
                            .keyboardType(.numberPad)
                            .onAppear { editAge = user.age != nil ? String(user.age!) : "" }
                            .onChange(of: editAge) { newAge in
                                if var user = authService.user {
                                    user.age = Int(newAge)
                                    authService.user = user
                                    authService.saveCurrentUser()
                                }
                            }
                    }

                    Section("Style Preferences") {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            if !user.preferredStyles.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: DS.Spacing.xs) {
                                        ForEach(user.preferredStyles, id: \.self) { style in
                                            Text(style.rawValue)
                                                .font(DS.Font.caption1)
                                                .foregroundColor(DS.Colors.accent)
                                                .padding(.horizontal, DS.Spacing.sm)
                                                .padding(.vertical, DS.Spacing.xs)
                                                .background(DS.Colors.accent.opacity(0.12))
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                            }

                            Button(action: {
                                if let user = authService.user {
                                    tempSelectedStyles = user.preferredStyles
                                    showStyleSheet = true
                                }
                            }) {
                                HStack {
                                    Text("Edit Preferences")
                                        .foregroundColor(DS.Colors.accent)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                        }

                        Toggle("Enable Notifications", isOn: .constant(user.notificationsEnabled))
                            .disabled(true)
                            .tint(DS.Colors.accent)
                    }

                    Section("iCloud Backup") {
                        HStack {
                            Image(systemName: "icloud.fill")
                                .foregroundColor(DS.Colors.accent)
                            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                                Text("iCloud Sync")
                                    .font(DS.Font.body)
                                    .foregroundColor(DS.Colors.textPrimary)
                                if let lastSync = cloudKitService.lastSyncDate {
                                    Text("Last synced \(lastSync, style: .relative) ago")
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textSecondary)
                                } else {
                                    Text("Not yet synced")
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                            Spacer()
                            switch cloudKitService.syncStatus {
                            case .syncing:
                                ProgressView()
                            case .success:
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(DS.Colors.success)
                            case .error:
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(DS.Colors.warning)
                            case .idle:
                                EmptyView()
                            }
                        }

                        Button("Backup Now") {
                            Haptics.medium()
                            wardrobeViewModel.backupToCloud()
                        }
                        .foregroundColor(DS.Colors.accent)
                        .disabled(cloudKitService.syncStatus == .syncing)

                        Button("Restore from iCloud") {
                            Haptics.medium()
                            Task { await wardrobeViewModel.restoreFromCloud() }
                        }
                        .foregroundColor(DS.Colors.accent)
                        .disabled(cloudKitService.syncStatus == .syncing)

                        if !iCloudAvailable {
                            Text("Sign in to iCloud in Settings to enable backup.")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }

                    Section("Subscription") {
                        HStack {
                            Text("Plan")
                            Spacer()
                            Text("Free")
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showingSignOutAlert = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                            Spacer()
                        }
                    }
                }

                Section("App Information") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }

                // Destructive section
                Section {
                    Button(role: .destructive) {
                        showEmptyConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Empty My Wardrobe")
                        }
                        .foregroundColor(DS.Colors.error)
                    }
                } footer: {
                    Text("This permanently removes all items from your wardrobe.")
                        .font(DS.Font.caption2)
                }
            }
            .tint(DS.Colors.accent)
            .navigationTitle("Profile")
            .task {
                iCloudAvailable = await CloudKitService.shared.checkAccountStatus()
            }
            .alert("Sign Out", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Sign Out", role: .destructive) { authService.signOut() }
            } message: {
                Text("Are you sure you want to sign out?")
            }
            .alert("Are you sure you want to empty your wardrobe?", isPresented: $showEmptyConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Empty", role: .destructive) {
                    for item in wardrobeViewModel.items {
                        wardrobeViewModel.deleteItemFromCloud(item)
                        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                        WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                        WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
                    }
                    wardrobeViewModel.items.removeAll()
                }
            } message: {
                Text("This will remove all items from your wardrobe and cannot be undone.")
            }
            .sheet(isPresented: $showStyleSheet) {
                StylePreferencesSheet(
                    selectedStyles: $tempSelectedStyles,
                    showStyleError: $showStyleError,
                    onApply: {
                        if tempSelectedStyles.count == maxStyles {
                            if var user = authService.user {
                                user.preferredStyles = tempSelectedStyles
                                authService.user = user
                                authService.saveCurrentUser()
                                showStyleSheet = false
                            }
                        } else {
                            showStyleError = true
                        }
                    },
                    onCancel: {
                        showStyleSheet = false
                        showStyleError = false
                    }
                )
                .environmentObject(authService)
            }
        }
    }
}

// MARK: - Style Preferences Sheet

struct StylePreferencesSheet: View {
    @Binding var selectedStyles: [OutfitType]
    @Binding var showStyleError: Bool
    var onApply: () -> Void
    var onCancel: () -> Void
    @EnvironmentObject var authService: AuthService
    private let maxStyles = 6
    private let allStyles = OutfitType.allCases
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    private let cellHeight: CGFloat = 56

    var isChanged: Bool {
        guard let user = authService.user else { return false }
        return Set(selectedStyles) != Set(user.preferredStyles)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Edit Style Preferences")
                    .font(DS.Font.title2)
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.top, DS.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text("Choose exactly 6 preferred styles")
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.top, DS.Spacing.xs)
                    .padding(.bottom, DS.Spacing.md)
                    .frame(maxWidth: .infinity, alignment: .center)

                LazyVGrid(columns: columns, spacing: DS.Spacing.md) {
                    ForEach(Array(allStyles.enumerated()), id: \.element) { _, style in
                        Button(action: {
                            Haptics.light()
                            if selectedStyles.contains(style) {
                                selectedStyles.removeAll { $0 == style }
                            } else if selectedStyles.count < maxStyles {
                                selectedStyles.append(style)
                            } else {
                                showStyleError = true
                            }
                        }) {
                            HStack(spacing: DS.Spacing.sm) {
                                Image(systemName: selectedStyles.contains(style) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(selectedStyles.contains(style) ? DS.Colors.accent : DS.Colors.textTertiary)
                                    .font(DS.Font.title3)

                                Text(style.rawValue)
                                    .foregroundColor(DS.Colors.textPrimary)
                                    .font(DS.Font.body)
                                    .multilineTextAlignment(.leading)

                                Spacer()
                            }
                            .padding(.leading, DS.Spacing.sm)
                            .frame(maxWidth: .infinity, minHeight: cellHeight, maxHeight: cellHeight, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.card)
                                    .fill(selectedStyles.contains(style) ? DS.Colors.accent.opacity(0.1) : DS.Colors.backgroundSecondary)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, DS.Spacing.xs)

                if showStyleError {
                    Text("Please select exactly 6 styles.")
                        .foregroundColor(DS.Colors.error)
                        .font(DS.Font.caption1)
                        .padding(.top, DS.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                Spacer()

                VStack(spacing: DS.Spacing.sm) {
                    Button("Save My Style Preferences") {
                        if selectedStyles.count == maxStyles && isChanged {
                            Haptics.medium()
                            onApply()
                        } else {
                            showStyleError = true
                        }
                    }
                    .buttonStyle(DSPrimaryButton(isDisabled: !isChanged || selectedStyles.count != maxStyles))
                    .disabled(!isChanged || selectedStyles.count != maxStyles)

                    Button("Cancel") { onCancel() }
                        .buttonStyle(DSSecondaryButton())
                }
                .padding(.horizontal, DS.Spacing.xs)
                .padding(.bottom, DS.Spacing.lg)
            }
            .padding(.horizontal, DS.Spacing.md)
            .background(DS.Colors.backgroundPrimary)
        }
    }
}

#Preview {
    ProfileView()
        .environmentObject(AuthService())
        .environmentObject(WardrobeViewModel())
}
