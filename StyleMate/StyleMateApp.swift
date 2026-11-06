import SwiftUI
import PhotosUI
import Photos

@main
struct StyleMateApp: App {
    @StateObject private var authService: AuthService
    @StateObject private var wardrobeVM: WardrobeViewModel
    @StateObject private var onboardingManager = OnboardingManager()
    @StateObject private var tutorialManager = TutorialManager()
    let persistenceController = PersistenceController.shared

    init() {
        // Created here (not lazily) so the background scan, which iOS may launch
        // without any UI, works on the same objects the UI shows. AuthService
        // restores the signed-in account (Sign in with Apple) from the Keychain.
        let auth = AuthService()
        let wardrobe = WardrobeViewModel()
        _authService = StateObject(wrappedValue: auth)
        _wardrobeVM = StateObject(wrappedValue: wardrobe)
        // Background task handlers must be registered before launch finishes.
        BackgroundScanCoordinator.shared.configure(auth: auth, wardrobe: wardrobe)
        // Morning outfit notification: refresh task + the tap router (a tap can cold-launch the app).
        if !AppRuntime.isUnitTestHost { MorningLookScheduler.shared.configure(auth: auth, wardrobe: wardrobe) }
        // StyleMate Premium (StoreKit 2): Transaction.updates listener + entitlement refresh, for the
        // signed-in account (set here too, so a background scan launched with no UI knows it), and
        // the account's own CloudKit zone.
        PremiumStore.shared.setAccount(auth.account?.uuid)
        PremiumStore.shared.start()
        if let account = auth.account, !AppRuntime.isUnitTestHost {
            CloudKitService.shared.configure(zoneName: account.cloudZoneName)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(wardrobeVM)
                .environmentObject(onboardingManager)
                .environmentObject(tutorialManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                // iPhone Duo / large displays: \.duoLayout (posture, fold, wide layout). Views/Components/DuoLayout.swift
                .duoLayoutReader()
                // UI tests' dark-mode pass (`-uiTestDarkMode`); nil = follow the system.
                .preferredColorScheme(Self.forcedColorScheme)
        }
    }

    private static var forcedColorScheme: ColorScheme? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiTestDarkMode") { return .dark }
        #endif
        return nil
    }
}

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @EnvironmentObject var onboardingManager: OnboardingManager
    @StateObject private var outfitsVM = MyOutfitsViewModel()
    @State private var lastUserKey: String = ""
    @State private var showSourcePicker = false
    @State private var hasPhotoAccess = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var capturedCameraImage: UIImage? = nil
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var reviewImages: [UIImage] = []
    @State private var showReview = false
    @State private var isLoadingImages = false
    @State private var showScanRangePicker = false
    @Environment(\.scenePhase) private var scenePhase

    var userKey: String {
        authService.user?.id ?? "guest"
    }

    var body: some View {
        ZStack {
            Group {
                // Signed out (Sign in with Apple is the only way in) or not onboarded yet.
                if !authService.isAuthenticated || !onboardingManager.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    MainTabView(showAddSheet: $showSourcePicker)
                        .environmentObject(outfitsVM)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: onboardingManager.hasCompletedOnboarding)
            .animation(.easeInOut(duration: 0.4), value: authService.isAuthenticated)
        }
        .sheet(isPresented: $showSourcePicker) {
            AddSourceSheet(
                // Free wardrobe full (50 pieces): the paywall instead of the picker / camera.
                onGallery: {
                    showSourcePicker = false
                    if PremiumGate.isAtLimit(wardrobeVM) { PaywallCenter.shared.present(.atLimit, after: 0.5) }
                    else { showPhotoPicker = true }
                },
                onCamera: {
                    showSourcePicker = false
                    if PremiumGate.isAtLimit(wardrobeVM) { PaywallCenter.shared.present(.atLimit, after: 0.5) }
                    else { showCamera = true }
                },
                onAutoScan: {
                    showSourcePicker = false
                    showScanRangePicker = true
                },
                showAutoScan: hasPhotoAccess
            )
            .presentationDetents([.medium])
            // Regular width (Duo inner display): a sheet sized to its rows.
            .presentationSizing(.fitted)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItems, maxSelectionCount: 15, matching: .images)
        .onChange(of: pickerItems) { items in
            guard !items.isEmpty else { return }
            isLoadingImages = true
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = ImageDownsampler.downsample(data: data) {   // ≤2048 px, not a 24 MP decode
                        images.append(image)
                    }
                }
                reviewImages = images
                pickerItems = []
                isLoadingImages = false
                if !images.isEmpty {
                    showReview = true
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ImagePicker(image: Binding(
                get: { capturedCameraImage },
                set: { img in
                    capturedCameraImage = img
                    showCamera = false
                    if let image = img {
                        reviewImages = [ImageDownsampler.downsample(image: image)]
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showReview = true
                        }
                    }
                }
            ))
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showReview, onDismiss: {
            capturedCameraImage = nil
            reviewImages = []
        }) {
            AddItemFlowView(images: reviewImages, isPresented: $showReview)
                .environmentObject(wardrobeVM)
                .environmentObject(authService)
        }
        .overlay {
            if isLoadingImages {
                OutfitLoadingOverlay(progress: 0.5, message: "Loading images…")
            }
        }
        // Paywall host, entitlement refresh, unlocking pieces that waited for Premium.
        .premiumSupport(userId: authService.user?.id ?? "")
        .sheet(isPresented: $showScanRangePicker) {
            ScanRangePickerView(
                isPresented: $showScanRangePicker,
                userId: authService.user?.id ?? "",
                onStartScan: { dateRange in
                    showScanRangePicker = false
                    let uid = authService.user?.id ?? ""
                    // No progress reset: photos already scanned are skipped, so a
                    // wider range just adds the photos not looked at yet.
                    Task {
                        await PhotoScanService.shared.startScan(
                            forUser: uid,
                            dateRange: dateRange,
                            userGender: authService.user?.gender,
                            wardrobeViewModel: wardrobeVM
                        )
                    }
                }
            )
        }
        .onChange(of: authService.user?.id) { newID in
            // Signed in, signed out, or another account (Delete account signs out).
            guard let id = newID else { deactivateProfile(); return }
            guard id != lastUserKey else { return }
            activateProfile(id)
        }
        .onAppear {
            hasPhotoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan
            if let id = authService.user?.id { activateProfile(id) }
            #if DEBUG
            TryOnDebugSeed.applyIfNeeded()   // UI tests only (-uiTestSeedTryOn)
            #endif
        }
        // Apple may have revoked the sign-in (Settings › Sign in with Apple › Stop Using).
        .task { await authService.verifyCredential() }
        // Studio renders: whenever items arrive (scan, manual add, restore),
        // turn their cutouts into lifelike catalog images in the background.
        .task(id: wardrobeVM.items.count) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard authService.isAuthenticated, scenePhase == .active else { return }
            StudioQueue.shared.enqueueMissing(wardrobeVM)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                Task { await authService.verifyCredential() }
                if authService.isAuthenticated, !wardrobeVM.currentUserEmail.isEmpty, !AppRuntime.isUnitTestHost {
                    Task {
                        let isAvailable = await CloudKitService.shared.checkAccountStatus()
                        if isAvailable {
                            await wardrobeVM.restoreFromCloud()
                        }
                    }
                }
                // Continue an interrupted scan, or pick up photos added since the
                // last one — the wardrobe keeps growing on its own. (Waits until
                // the first scan after onboarding has been started below.)
                if let userId = authService.user?.id, !userId.isEmpty,
                   UserDefaults.standard.bool(forKey: "hasCompletedInitialScan_\(userId)")
                    || PhotoScanService.shared.hasUnfinishedScan(forUser: userId) {
                    BackgroundScanCoordinator.shared.appBecameActive()
                }
            case .background:
                BackgroundScanCoordinator.shared.appDidEnterBackground()
                // Precompute the next morning look now, while the app last ran.
                Task { await MorningLookScheduler.shared.reschedule() }
            default:
                break
            }
        }
        .task(id: onboardingManager.hasCompletedOnboarding) {
            let userId = authService.user?.id ?? ""
            let scanKey = "hasCompletedInitialScan_\(userId)"

            guard onboardingManager.hasCompletedOnboarding,
                  authService.isAuthenticated,
                  !userId.isEmpty,
                  !UserDefaults.standard.bool(forKey: scanKey),
                  // No selfie (skipped): nobody to recognise; Home offers the selfie instead.
                  LocalStore.hasSelfie(userId: userId),
                  PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan,
                  !PhotoScanService.shared.isWorking,
                  PhotoScanService.shared.scanState == .idle else { return }

            // First scan: the last 12 months, newest first. Items appear in the
            // wardrobe as they're found; the scan continues in the background and
            // overnight, and Profile / Add → Auto-scan can extend it to every photo.
            print("[StyleMate] Auto-scan triggered after onboarding completion")

            if PhotoScanService.shared.hasUnfinishedScan(forUser: userId) {
                // Killed mid-way last time: pick up exactly where it stopped.
                await PhotoScanService.shared.continueScanning(
                    forUser: userId, userGender: authService.user?.gender, wardrobeViewModel: wardrobeVM)
            } else {
                await PhotoScanService.shared.startScan(
                    forUser: userId,
                    // Limited access: scan every photo the user chose, whatever its date.
                    dateRange: PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited ? .all : .lastYear,
                    userGender: authService.user?.gender,
                    wardrobeViewModel: wardrobeVM,
                    trigger: .initial,
                    firstLook: true
                )
            }

            if PhotoScanService.shared.scanState == .completed {
                UserDefaults.standard.set(true, forKey: scanKey)
            }
        }
    }

    /// Loads everything that hangs off the signed-in account's profile id.
    private func activateProfile(_ id: String) {
        lastUserKey = id
        // The account's own CloudKit zone and its own subscription, before anything syncs.
        if let account = authService.account {
            if !AppRuntime.isUnitTestHost { CloudKitService.shared.configure(zoneName: account.cloudZoneName) }
            PremiumStore.shared.setAccount(account.uuid)
        }
        outfitsVM.setUser(id)   // the outfit calendar is scoped per profile (Core Data v2)
        wardrobeVM.load(forUser: id)
        onboardingManager.check(forUser: id)
        UncertainItemsStore.shared.load(forUser: id)
        WearLogSuggestions.shared.load(forUser: id)
        wardrobeVM.migrateBackgroundRemoval()
        wardrobeVM.migrateThumbnails()
        // First sign-in on a phone with an earlier on-device profile: its wardrobe was backed up to
        // the shared legacy zone; send it to the account's zone once.
        if let account = authService.account {
            let key = AuthService.adoptedLegacyKey(for: account.uuid)
            if UserDefaults.standard.bool(forKey: key) {
                wardrobeVM.queueFullReupload()
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        // The unit-test host runs unsigned (no iCloud entitlement): CKContainer would trap.
        guard !AppRuntime.isUnitTestHost else { return }
        Task {
            await CloudKitService.shared.setupZone()
            let isAvailable = await CloudKitService.shared.checkAccountStatus()
            if isAvailable {
                await wardrobeVM.restoreFromCloud()
            }
        }
    }
}

extension RootView {
    /// Signed out: stop everything for the account and forget it in memory (its data stays on the
    /// phone for the next sign-in).
    fileprivate func deactivateProfile() {
        guard !lastUserKey.isEmpty else { return }
        PhotoScanService.shared.resetForProfileChange()
        StudioQueue.shared.cancel()
        PaywallCenter.shared.dismiss()
        wardrobeVM.clear()
        outfitsVM.setUser("")
        onboardingManager.hasCompletedOnboarding = false
        PremiumStore.shared.setAccount(nil)
        lastUserKey = ""
    }
}

// MARK: - Add Source Bottom Sheet

private struct AddSourceSheet: View {
    let onGallery: () -> Void
    let onCamera: () -> Void
    let onAutoScan: () -> Void
    let showAutoScan: Bool

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Add to Wardrobe")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.top, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.lg)

            VStack(spacing: DS.Spacing.sm) {
                addOptionRow(
                    icon: "photo.on.rectangle.angled",
                    iconColor: DS.Colors.accent,
                    title: "Choose from Gallery",
                    subtitle: "Pick photos of your clothes",
                    delay: 0,
                    action: onGallery
                )
                .accessibilityIdentifier("addSource.gallery")

                addOptionRow(
                    icon: "camera.fill",
                    iconColor: DS.Colors.accent,
                    title: "Take a Photo",
                    subtitle: "Snap a picture of what you're wearing",
                    delay: 1,
                    action: onCamera
                )
                .accessibilityIdentifier("addSource.camera")

                if showAutoScan {
                    addOptionRow(
                        icon: "sparkles.rectangle.stack.fill",
                        iconColor: DS.Colors.accent,
                        title: "Auto-Scan Photos",
                        subtitle: "Finds your outfits in your photos, on your iPhone",
                        delay: 2,
                        action: onAutoScan
                    )
                    .accessibilityIdentifier("addSource.autoScan")
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.bottom, DS.Spacing.lg)
        }
        // Top-aligned without a Spacer, so a fitted sheet is exactly its rows.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.Colors.backgroundPrimary)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                appeared = true
            }
        }
    }

    @ViewBuilder
    private func addOptionRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        delay: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            Haptics.medium()
            action()
        }) {
            HStack(spacing: DS.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 44, height: 44)
                    .background(iconColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.headline)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(subtitle)
                        .font(DS.Font.caption1)
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .background(DS.Colors.backgroundCard)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .dsCardShadow()
        }
        .buttonStyle(DSTapBounce())
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .animation(
            .spring(response: 0.45, dampingFraction: 0.78).delay(Double(delay) * 0.06),
            value: appeared
        )
    }
}

/// Where the app process is running.
enum AppRuntime {
    /// Hosting the unit tests (StyleMateTests): an unsigned build without the iCloud
    /// entitlement, where touching CloudKit at launch would crash the host before the
    /// tests connect. (UI tests launch a separately signed app without this variable.)
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
