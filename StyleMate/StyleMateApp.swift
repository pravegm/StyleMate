import SwiftUI
import PhotosUI
import Photos
import GoogleSignIn

@main
struct StyleMateApp: App {
    @StateObject private var authService: AuthService
    @StateObject private var wardrobeVM: WardrobeViewModel
    @StateObject private var onboardingManager = OnboardingManager()
    @StateObject private var tutorialManager = TutorialManager()
    let persistenceController = PersistenceController.shared

    init() {
        // Created here (not lazily) so the background scan, which iOS may launch
        // without any UI, works on the same objects the UI shows.
        let auth = AuthService()
        let wardrobe = WardrobeViewModel()
        _authService = StateObject(wrappedValue: auth)
        _wardrobeVM = StateObject(wrappedValue: wardrobe)
        // Background task handlers must be registered before launch finishes.
        BackgroundScanCoordinator.shared.configure(auth: auth, wardrobe: wardrobe)
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
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
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
                if !authService.isAuthenticated {
                    LoginView()
                } else if !onboardingManager.hasCompletedOnboarding {
                    OnboardingView()
                } else {
                    MainTabView(showAddSheet: $showSourcePicker)
                        .environmentObject(outfitsVM)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: authService.isAuthenticated)
            .animation(.easeInOut(duration: 0.4), value: onboardingManager.hasCompletedOnboarding)
        }
        .sheet(isPresented: $showSourcePicker) {
            AddSourceSheet(
                onGallery: { showSourcePicker = false; showPhotoPicker = true },
                onCamera: { showSourcePicker = false; showCamera = true },
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
                       let image = UIImage(data: data) {
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
                        reviewImages = [image]
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
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            if isAuthenticated, let id = authService.user?.id {
                wardrobeVM.load(forUser: id)
                lastUserKey = userKey
                onboardingManager.check(forUser: id)
                wardrobeVM.migrateBackgroundRemoval()
                wardrobeVM.migrateThumbnails()

                Task {
                    await CloudKitService.shared.setupZone()
                    let isAvailable = await CloudKitService.shared.checkAccountStatus()
                    if isAvailable {
                        await wardrobeVM.restoreFromCloud()
                    }
                }
            } else {
                wardrobeVM.clear()
                lastUserKey = ""
            }
        }
        .onAppear {
            hasPhotoAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite).allowsScan
            authService.checkCredentialState()
            if authService.isAuthenticated, let id = authService.user?.id {
                wardrobeVM.load(forUser: id)
                lastUserKey = userKey
                onboardingManager.check(forUser: id)
                wardrobeVM.migrateBackgroundRemoval()
                wardrobeVM.migrateThumbnails()

                Task {
                    await CloudKitService.shared.setupZone()
                    let isAvailable = await CloudKitService.shared.checkAccountStatus()
                    if isAvailable {
                        await wardrobeVM.restoreFromCloud()
                    }
                }
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if authService.isAuthenticated, !wardrobeVM.currentUserEmail.isEmpty {
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
                    dateRange: .lastYear,
                    userGender: authService.user?.gender,
                    wardrobeViewModel: wardrobeVM,
                    trigger: .initial
                )
            }

            if PhotoScanService.shared.scanState == .completed {
                UserDefaults.standard.set(true, forKey: scanKey)
            }
        }
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
