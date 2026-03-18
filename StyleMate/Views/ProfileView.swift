import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var onboardingManager: OnboardingManager
    @ObservedObject private var cloudKitService = CloudKitService.shared
    @State private var showingSignOutAlert = false
    @State private var showEmptyConfirmation = false
    @State private var showDeleteProfileAlert = false
    @State private var showStyleSheet = false
    @State private var showRetakeSelfie = false
    @State private var tempSelectedStyles: [OutfitType] = []
    @State private var showStyleError = false
    @State private var editGender: String = ""
    @State private var editAge: String = ""
    @State private var iCloudAvailable = true
    @State private var syncRotation: Double = 0
    let genderOptions = ["", "Male", "Female"]

    private let maxStyles = 6
    private let allStyles = OutfitType.allCases

    private var initials: String {
        guard let name = authService.user?.name else { return "?" }
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var categoryCount: Int {
        Set(wardrobeViewModel.items.map { $0.category }).count
    }

    var body: some View {
        NavigationStack {
            Form {
                if let user = authService.user {
                    Section {
                        VStack(spacing: DS.Spacing.sm) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.7)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 72, height: 72)

                                Text(initials)
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }

                            Text(user.name)
                                .font(DS.Font.title2)
                                .foregroundColor(DS.Colors.textPrimary)

                            if let email = user.email, !email.isEmpty {
                                Text(email)
                                    .font(DS.Font.subheadline)
                                    .foregroundColor(DS.Colors.textSecondary)
                            }

                            HStack(spacing: DS.Spacing.xl) {
                                statBadge(value: "\(wardrobeViewModel.items.count)", label: "Items")
                                statBadge(value: "\(categoryCount)", label: "Categories")
                            }
                            .padding(.top, DS.Spacing.xs)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.sm)
                        .listRowBackground(Color.clear)
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
                                            HStack(spacing: DS.Spacing.micro) {
                                                Image(systemName: style.icon)
                                                    .font(DS.Font.caption2)
                                                Text(style.rawValue)
                                                    .font(DS.Font.caption1)
                                            }
                                            .foregroundColor(DS.Colors.accent)
                                            .padding(.horizontal, DS.Spacing.sm)
                                            .padding(.vertical, DS.Spacing.xs)
                                            .background(DS.Colors.accent.opacity(0.12))
                                            .clipShape(Capsule())
                                            .overlay(Capsule().stroke(DS.Colors.accent.opacity(0.2), lineWidth: 0.5))
                                        }
                                    }
                                }
                            }

                            Button(action: {
                                Haptics.light()
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
                            syncStatusIndicator
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
                    Button {
                        Haptics.light()
                        showRetakeSelfie = true
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "face.smiling")
                            Text("Retake Selfie")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .foregroundColor(DS.Colors.accent)
                    }
                } footer: {
                    Text("Retake your reference selfie to improve outfit photo detection.")
                        .font(DS.Font.caption2)
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

                Section {
                    Button(role: .destructive) {
                        showDeleteProfileAlert = true
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "person.crop.circle.badge.xmark")
                            Text("Delete Profile & All Data")
                        }
                        .font(DS.Font.body)
                        .foregroundColor(DS.Colors.error)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
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
                            Haptics.success()
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
            .sheet(isPresented: $showRetakeSelfie) {
                RetakeSelfieSheet()
                    .environmentObject(authService)
            }
            .alert("Delete Everything?", isPresented: $showDeleteProfileAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete Everything", role: .destructive) {
                    deleteProfile()
                }
            } message: {
                Text("This will permanently delete your profile, wardrobe items, saved outfits, selfie data, and sign you out. You'll go through onboarding again on next sign-in. This cannot be undone.")
            }
        }
    }

    // MARK: - Delete Profile

    private func deleteProfile() {
        guard let userId = authService.user?.id else { return }

        Haptics.medium()

        wardrobeViewModel.clear()

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let files = try? FileManager.default.contentsOfDirectory(atPath: documentsPath.path) {
            for file in files {
                let filePath = documentsPath.appendingPathComponent(file)
                try? FileManager.default.removeItem(at: filePath)
            }
        }

        // Delete scan progress file from Application Support
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let scanProgressFile = appSupport.appendingPathComponent("ScanProgress/scanProgress_\(userId).json")
        try? FileManager.default.removeItem(at: scanProgressFile)

        let keysToRemove = [
            "hasCompletedOnboarding_\(userId)",
            "selfieReferencePath_\(userId)",
            "wardrobeData_\(userId)",
            "hasSeenSwipeHint",
            "hasMigratedBackgroundRemoval_\(userId)",
            "hasMigratedThumbnails_\(userId)",
            "hasMigratedZoneCrop_\(userId)",
            "hasConsentedToGeminiScan_\(userId)",
            "bgRemovalMigrationComplete_\(userId)",
            "thumbnailMigrationComplete_\(userId)",
            "zoneCropMigrationComplete_\(userId)",
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "wardrobe_\(userId)")

        Task {
            await CloudKitService.shared.deleteAllData()
        }

        var profiles = AuthService.loadUserProfiles()
        profiles.removeValue(forKey: userId)
        AuthService.saveUserProfiles(profiles)

        onboardingManager.reset(forUser: userId)

        authService.signOut()

        print("[StyleMate] Profile deleted for user: \(userId)")
    }

    // MARK: - Stat Badge

    private func statBadge(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Font.title3)
                .foregroundColor(DS.Colors.textPrimary)
            Text(label)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Sync Status Indicator

    @ViewBuilder
    private var syncStatusIndicator: some View {
        switch cloudKitService.syncStatus {
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(DS.Colors.accent)
                .rotationEffect(.degrees(syncRotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                        syncRotation = 360
                    }
                }
                .onDisappear { syncRotation = 0 }
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(DS.Colors.success)
                .transition(.scale.combined(with: .opacity))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(DS.Colors.warning)
        case .idle:
            EmptyView()
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
                        let isStyleSelected = selectedStyles.contains(style)
                        Button(action: {
                            Haptics.light()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                if isStyleSelected {
                                    selectedStyles.removeAll { $0 == style }
                                } else if selectedStyles.count < maxStyles {
                                    selectedStyles.append(style)
                                } else {
                                    showStyleError = true
                                }
                            }
                        }) {
                            HStack(spacing: DS.Spacing.sm) {
                                Image(systemName: isStyleSelected ? "checkmark.square.fill" : "square")
                                    .foregroundColor(isStyleSelected ? DS.Colors.accent : DS.Colors.textTertiary)
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
                                    .fill(isStyleSelected ? DS.Colors.accent.opacity(0.1) : DS.Colors.backgroundSecondary)
                            )
                            .overlay(
                                isStyleSelected
                                    ? RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Colors.accent.opacity(0.3), lineWidth: 1)
                                    : nil
                            )
                            .scaleEffect(isStyleSelected ? 1.02 : 1.0)
                        }
                        .buttonStyle(DSTapBounce())
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
        .environmentObject(OnboardingManager())
}

// MARK: - Retake Selfie Sheet

private struct RetakeSelfieSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var selfieImage: UIImage?

    var body: some View {
        NavigationView {
            OnboardingSelfieView(
                selfieImage: $selfieImage,
                onAdvance: { dismiss() },
                onSkip: { dismiss() },
                isRetakeMode: true
            )
            .environmentObject(authService)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
        }
    }
}
