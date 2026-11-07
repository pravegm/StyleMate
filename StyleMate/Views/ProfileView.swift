import SwiftUI
import CoreData
import UserNotifications

struct ProfileView: View {
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @EnvironmentObject var onboardingManager: OnboardingManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tutorialManager: TutorialManager
    @EnvironmentObject private var outfitsVM: MyOutfitsViewModel
    @ObservedObject private var cloudKitService = CloudKitService.shared
    @ObservedObject private var morningLook = MorningLookScheduler.shared
    @State private var showRemoveSamplesAlert = false
    @State private var showEmptyConfirmation = false
    @State private var showStyleSheet = false
    @State private var showRetakeSelfie = false
    @State private var retookSelfie = false
    @State private var showReferenceBuilder = false
    @State private var tempSelectedStyles: [OutfitType] = []
    @State private var showStyleError = false
    @State private var editName: String = ""
    @State private var editGender: String = ""
    @State private var editAge: String = ""
    @State private var iCloudAvailable = true
    @State private var syncRotation: Double = 0
    @State private var didSeedFields = false
    @State private var profileSaveTask: Task<Void, Never>?
    @State private var showResetTaste = false
    /// Choices the stylist has learned from (Services/Outfits/TasteProfile).
    @State private var tasteEvents = 0
    let genderOptions = ["", "Male", "Female"]

    private let maxStyles = 6
    private let allStyles = OutfitType.allCases

    private var sampleCount: Int {
        SampleLibrary.sampleCount(in: wardrobeViewModel.items, userId: authService.user?.id ?? "")
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private var initials: String {
        guard let name = authService.user?.name else { return "" }
        let parts = name.components(separatedBy: " ").filter { !$0.isEmpty }
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    /// The closet's shelves (as the closet and the tab bar's summary count them), not the
    /// ten storage categories: one count everywhere.
    private var shelfCount: Int {
        ClosetEngine.counts(wardrobeViewModel.items).count
    }

    /// Debounced profile save: commits ~0.5s after the user stops editing, so we
    /// don't mutate the observed user (re-rendering the Form) on every keystroke.
    private func scheduleProfileSave() {
        guard didSeedFields else { return }
        profileSaveTask?.cancel()
        profileSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            commitProfileEdits()
        }
    }

    private func seedFields() {
        guard let user = authService.user else { return }
        editName = user.name
        editGender = user.gender ?? ""
        editAge = user.age.map(String.init) ?? ""
        didSeedFields = true
    }

    private func commitProfileEdits() {
        guard didSeedFields, var user = authService.user else { return }
        let trimmed = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { user.name = trimmed }
        user.gender = editGender.isEmpty ? nil : editGender
        user.age = Int(editAge)
        authService.user = user
        authService.saveCurrentUser()
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
                                            colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.75)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 76, height: 76)
                                    .shadow(color: DS.Colors.accent.opacity(colorScheme == .dark ? 0 : 0.30), radius: 10, x: 0, y: 5)

                                if initials.isEmpty {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 30, weight: .semibold))
                                        .foregroundStyle(DS.Colors.onAccent)
                                } else {
                                    Text(initials)
                                        .font(.system(size: 28, weight: .bold, design: .rounded))
                                        .foregroundStyle(DS.Colors.onAccent)
                                }
                            }
                            .coachAnchor(CoachAnchor.profileHeader)

                            Text(user.name.isEmpty ? "Your profile" : user.name)
                                .font(DS.Font.title2)
                                .foregroundColor(DS.Colors.textPrimary)

                            Text("Signed in with Apple")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textTertiary)

                            if let email = user.email, !email.isEmpty {
                                Text(email)
                                    .font(DS.Font.subheadline)
                                    .foregroundColor(DS.Colors.textSecondary)
                            }

                            HStack(spacing: DS.Spacing.xl) {
                                statBadge(value: "\(wardrobeViewModel.items.count)",
                                          label: wardrobeViewModel.items.count == 1 ? "Piece" : "Pieces")
                                statBadge(value: "\(shelfCount)", label: shelfCount == 1 ? "Shelf" : "Shelves")
                            }
                            .padding(.top, DS.Spacing.xs)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, DS.Spacing.sm)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: DS.Spacing.md, bottom: 0, trailing: DS.Spacing.md))
                    }
                    .listSectionSpacing(.compact)

                    PremiumProfileSection()   // Views/Subscription: plan, renewal, Manage, Restore

                    Section {
                        // Fields are seeded once (see .onAppear below) and saved on a
                        // debounce. Do NOT write authService.user per keystroke or
                        // re-seed via per-field .onAppear — that re-rendered the Form
                        // mid-edit and reverted the text, hanging the screen.
                        LabeledContent("Name") {
                            TextField("Name", text: $editName)
                                .multilineTextAlignment(.trailing)
                        }
                        .onChange(of: editName) { _ in scheduleProfileSave() }

                        Picker("Gender", selection: $editGender) {
                            ForEach(genderOptions, id: \.self) { option in
                                Text(option.isEmpty ? "Select Gender" : option).tag(option)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: editGender) { _ in scheduleProfileSave() }

                        LabeledContent("Age") {
                            TextField("Age", text: $editAge)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        }
                            .onChange(of: editAge) { newAge in
                                editAge = String(newAge.filter(\.isNumber).prefix(3))
                                scheduleProfileSave()
                            }
                    } header: {
                        Text("About you")
                    } footer: {
                        Text("Optional. Helps StyleMate name your clothes and pick looks. Stays on this iPhone.")
                            .font(DS.Font.caption2)
                    }

                    Section("Style preferences") {
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
                                            .foregroundStyle(DS.Colors.accent)
                                            .padding(.horizontal, DS.Spacing.sm)
                                            .padding(.vertical, DS.Spacing.xs)
                                            .background(DS.Colors.accentSoft, in: Capsule(style: .continuous))
                                            .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.accent.opacity(0.25), lineWidth: 0.5))
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
                                    Text("Edit preferences")
                                        .foregroundColor(DS.Colors.accent)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(DS.Colors.textTertiary)
                                }
                            }
                        }

                    }

                    Section {
                        insightsRow

                        Button(role: .destructive) {
                            showResetTaste = true
                        } label: {
                            Label("Reset style learning", systemImage: "arrow.counterclockwise")
                                .foregroundColor(tasteEvents == 0 ? DS.Colors.textTertiary : DS.Colors.error)
                        }
                        .disabled(tasteEvents == 0)
                        .accessibilityIdentifier("profile.resetTaste")
                    } header: {
                        Text("Your style")
                    } footer: {
                        Text(tasteFooter)
                            .font(DS.Font.caption2)
                    }

                    Section {
                        Toggle(isOn: Binding(
                            get: { morningLook.isEnabled },
                            set: { on in
                                Haptics.light()
                                if on, morningLook.authorization != .authorized {
                                    Task { await morningLook.requestAndEnable() }
                                } else {
                                    morningLook.setEnabled(on)
                                }
                            }
                        )) {
                            Label("Morning outfit", systemImage: "sun.horizon.fill")
                        }
                        .tint(DS.Colors.accent)
                        .accessibilityIdentifier("profile.morningLook")

                        if morningLook.isEnabled {
                            DatePicker("Time", selection: Binding(
                                get: { morningLook.time },
                                set: { morningLook.setTime($0) }
                            ), displayedComponents: .hourAndMinute)
                        }
                        if morningLook.authorization == .denied {
                            Button("Turn on notifications in Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                            .foregroundColor(DS.Colors.accent)
                        }
                    } header: {
                        Text("Notifications")
                    } footer: {
                        Text("Each morning: the weather and a look from your closet, styled on your iPhone. Tap it to open Today's Outfit.")
                            .font(DS.Font.caption2)
                    }

                    Section("iCloud backup") {
                        HStack {
                            Image(systemName: "icloud.fill")
                                .foregroundColor(DS.Colors.accent)
                            VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                                Text("iCloud sync")
                                    .font(DS.Font.body)
                                    .foregroundColor(DS.Colors.textPrimary)
                                if let lastSync = cloudKitService.lastSyncDate {
                                    Text("Last synced \(lastSync, style: .relative) ago")
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textSecondary)
                                } else {
                                    Text("Not yet synced")
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                            }
                            Spacer()
                            syncStatusIndicator
                        }

                        Button("Back up now") {
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

                    if sampleCount > 0 {
                        Section {
                            Button(role: .destructive) {
                                showRemoveSamplesAlert = true
                            } label: {
                                Label("Remove sample clothes (\(sampleCount))", systemImage: "photo.stack")
                            }
                            .accessibilityIdentifier("profile.removeSamples")
                        } header: {
                            Text("Sample clothes")
                        } footer: {
                            Text("These came from the bundled sample photos, not your own.")
                                .font(DS.Font.caption2)
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
                            Text("Retake selfie")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .foregroundColor(DS.Colors.accent)
                    }

                    Button {
                        Haptics.light()
                        showReferenceBuilder = true
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "person.crop.rectangle.stack")
                            Text("Improve recognition")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .foregroundColor(DS.Colors.accent)
                    }
                } footer: {
                    Text("Retake your selfie, or tap which of your photos are you so StyleMate can recognize you in pictures with other people.")
                        .font(DS.Font.caption2)
                }

                Section {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 20))
                            .foregroundColor(DS.Colors.accent)
                        VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                            Text("Everything stays on your iPhone")
                                .font(DS.Font.body)
                                .foregroundColor(DS.Colors.textPrimary)
                            Text("No photo, face or wardrobe item is sent to any AI service.")
                                .font(DS.Font.caption1)
                                .foregroundColor(DS.Colors.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    Link(destination: LegalLinks.privacyPolicy) {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "hand.raised.fill")
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .foregroundColor(DS.Colors.accent)
                    }
                    .accessibilityIdentifier("profile.privacyPolicy")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("There's no StyleMate server: you sign in with Apple, and finding you in your photos, cutting out your clothes and suggesting outfits all run on this device. The photo scan keeps going in the background and overnight while your phone charges. Your wardrobe is backed up only to your own iCloud.")
                        .font(DS.Font.caption2)
                }

                Section("About") {
                    Button {
                        Haptics.light()
                        tutorialManager.resetSeen(.generation)   // re-arm the result-screen tour too
                        tutorialManager.start(.home)
                    } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "sparkles")
                            Text("Replay app tour")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .foregroundColor(DS.Colors.accent)
                    }

                    NavigationLink {
                        SamplePhotoCreditsView()
                    } label: {
                        Text("Sample photo credits")
                    }

                    NavigationLink { AcknowledgementsView() } label: { Text("Acknowledgements") }
                        .accessibilityIdentifier("profile.acknowledgements")
                    NavigationLink { DiagnosticsView() } label: { Text("Diagnostics") }
                        .accessibilityIdentifier("profile.diagnostics")

                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showEmptyConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Empty my wardrobe")
                        }
                        .foregroundColor(DS.Colors.error)
                    }
                } footer: {
                    Text("This permanently removes all items from your wardrobe.")
                        .font(DS.Font.caption2)
                }

                // Views/Account: Signed in with Apple, Sign Out, Delete Account (5.1.1(v)).
                AccountProfileSection(onDeleteAccount: deleteProfile)
            }
            .tint(DS.Colors.accent)
            .navigationTitle("Profile")
            .task {
                iCloudAvailable = await CloudKitService.shared.checkAccountStatus()
            }
            .onAppear {
                tasteEvents = TasteStore.shared.events(forUser: authService.user?.id)
                guard !didSeedFields else { return }
                seedFields()
            }
            // Another session (sign out / Delete Account, then sign in): the fields kept the old account's name,
            // and leaving Profile would have saved it into the new one.
            .onChange(of: authService.isAuthenticated) { signedIn in
                profileSaveTask?.cancel()
                didSeedFields = false
                if signedIn { seedFields() }
            }
            .onDisappear {
                profileSaveTask?.cancel()
                commitProfileEdits()
                didSeedFields = false
            }
            .alert("Remove sample clothes?", isPresented: $showRemoveSamplesAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    if let id = authService.user?.id { SampleLibrary.removeSamples(from: wardrobeViewModel, userId: id) }
                }
            } message: {
                Text("Removes the \(sampleCount) items that came from the sample photos. Your own clothes stay.")
            }
            .alert("Are you sure you want to empty your wardrobe?", isPresented: $showEmptyConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Empty", role: .destructive) {
                    // The scan and studio renders stop first, so nothing lands right after.
                    if PhotoScanService.shared.isWorking { PhotoScanService.shared.cancelScan() }
                    StudioQueue.shared.cancel()
                    // Same cleanup as deleting pieces: files, studio originals and records,
                    // embeddings, iCloud.
                    ClosetActions.remove(wardrobeViewModel.items, from: wardrobeViewModel)
                    wardrobeViewModel.removeAllLocked()   // pieces waiting for Premium go too
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
            .sheet(isPresented: $showRetakeSelfie, onDismiss: {
                // A new selfie resets the face gallery: go straight to "Find yourself"
                // so the user can rebuild it from their photos.
                if retookSelfie {
                    retookSelfie = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showReferenceBuilder = true }
                }
            }) {
                RetakeSelfieSheet(onRetaken: { retookSelfie = true })
                    .environmentObject(authService)
            }
            .sheet(isPresented: $showReferenceBuilder) {
                if let userId = authService.user?.id {
                    FaceReferenceBuilderView(userId: userId, isPresented: $showReferenceBuilder)
                }
            }
            .alert("Reset style learning?", isPresented: $showResetTaste) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    if let id = authService.user?.id { TasteStore.shared.reset(forUser: id) }
                    tasteEvents = 0
                    Haptics.success()
                }
            } message: {
                Text("StyleMate forgets what it learned from the looks you wore, kept, swapped and skipped. Your wardrobe and outfit log stay.")
            }
        }
    }

    // MARK: - Delete Profile

    /// "Delete Account": everything StyleMate stored for the account, on the phone and in the
    /// account's iCloud zone, then the account itself is forgotten (signed out, back to Welcome).
    private func deleteProfile() {
        guard let userId = authService.user?.id else { return }

        Haptics.medium()

        // 1. Stop all work for this profile first, so nothing found for it can
        //    land afterwards (the scan also re-checks the user id per item).
        PhotoScanService.shared.resetForProfileChange()
        PhotoScanService.shared.forgetProgress(forUser: userId)
        MorningLookScheduler.shared.setEnabled(false)

        // 2. Wardrobe (real storage key), images, embeddings, outfit history, selfie +
        //    face gallery, sync ledger and the iCloud zone (retried until it succeeds).
        wardrobeViewModel.deleteAllLocalData(forUser: userId)
        outfitsVM.fetchAllOutfits()

        // 3. What the first-run / habit features keep.
        UncertainItemsStore.shared.forget(forUser: userId)
        WearLogSuggestions.shared.forget(forUser: userId)
        MorningLookStore.forgetAll()
        TasteStore.shared.reset(forUser: userId)

        let keysToRemove = [
            "hasCompletedOnboarding_\(userId)",
            "sampleItemIDs_\(userId)",
            "tour_home_\(userId)",
            "tour_generation_\(userId)",
            "todayHeroOutfit",
            "lastCloudKitSync",
            "scanProgress_\(userId)",
            "hasCompletedInitialScan_\(userId)",
            "hasSeenSwipeHint",
            "cachedWeather",
        ]
        for key in keysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // 4. Forget the account on this phone: signed out, back to Welcome.
        onboardingManager.reset(forUser: userId)
        authService.deleteAccount()

        dlog("[StyleMate] Profile deleted for user: \(userId)")
    }

    // MARK: - Your style

    /// Wardrobe insights: open to everyone today; behind the paywall when
    /// `InsightsAvailability` says so (a one-line switch).
    @ViewBuilder
    private var insightsRow: some View {
        if InsightsAvailability.isAvailable {
            NavigationLink {
                WardrobeInsightsView()
            } label: {
                Label("Wardrobe insights", systemImage: "chart.bar.xaxis")
            }
            .accessibilityIdentifier("profile.insights")
        } else {
            Button {
                Haptics.light()
                PaywallCenter.shared.present(.profile)
            } label: {
                HStack {
                    Label("Wardrobe insights", systemImage: "chart.bar.xaxis")
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer()
                    Text("Premium")
                        .font(DS.Font.caption1.weight(.semibold))
                        .foregroundStyle(DS.Colors.accent)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, 3)
                        .background(DS.Colors.accentSoft, in: Capsule(style: .continuous))
                }
            }
            .accessibilityIdentifier("profile.insights")
        }
    }

    private var tasteFooter: String {
        let learned = tasteEvents == 0
            ? "Nothing learned yet."
            : "Learned from \(tasteEvents) choice\(tasteEvents == 1 ? "" : "s") so far."
        return "Outfits adapt to what you wear, keep, swap and skip. \(learned) It stays on this iPhone and fades over time."
    }

    // MARK: - Stat Badge

    private func statBadge(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(DS.Font.title3)
                .foregroundColor(DS.Colors.textPrimary)
            Text(label)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Colors.textSecondary)
        }
    }

    // MARK: - Sync Status Indicator

    @ViewBuilder
    private var syncStatusIndicator: some View {
        switch cloudKitService.syncStatus {
        case .syncing:
            // A system symbol effect: honours Reduce Motion and doesn't leak a
            // repeatForever animation into the rest of the list.
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(DS.Colors.accent)
                .symbolEffect(.rotate, options: .repeating)
                .accessibilityLabel("Syncing")
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
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DS.Spacing.sm)]
    private let cellHeight: CGFloat = 56

    var isChanged: Bool {
        guard let user = authService.user else { return false }
        return Set(selectedStyles) != Set(user.preferredStyles)
    }

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Edit style preferences")
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
                    Button("Save my style preferences") {
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
        .environmentObject(TutorialManager())
        .environmentObject(MyOutfitsViewModel())
}

// MARK: - Sample photo credits

private struct SamplePhotoCreditsView: View {
    var body: some View {
        List {
            Section {
                ForEach(SampleLibrary.credits) { credit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(credit.title)
                            .font(DS.Font.subheadline)
                            .foregroundColor(DS.Colors.textPrimary)
                        if let url = URL(string: credit.source) {
                            Link("Wikimedia Commons", destination: url)
                                .font(DS.Font.caption1)
                        }
                    }
                }
            } footer: {
                Text("\"Try with sample photos\" uses these photos, all \(SampleLibrary.licence).")
                    .font(DS.Font.caption2)
            }
        }
        .navigationTitle("Sample photos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Retake Selfie Sheet

/// Also opened from Home's scan banner when the scan has no selfie to match.
struct RetakeSelfieSheet: View {
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var selfieImage: UIImage?
    /// Called when a new selfie was saved (not on skip / cancel).
    var onRetaken: () -> Void = {}

    var body: some View {
        NavigationView {
            OnboardingSelfieView(
                selfieImage: $selfieImage,
                onAdvance: { onRetaken(); dismiss() },
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
