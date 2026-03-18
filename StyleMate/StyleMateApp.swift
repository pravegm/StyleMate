import SwiftUI
import PhotosUI
import Photos
import GoogleSignIn

@main
struct StyleMateApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var wardrobeVM = WardrobeViewModel()
    @StateObject private var onboardingManager = OnboardingManager()
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(wardrobeVM)
                .environmentObject(onboardingManager)
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
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
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var capturedCameraImage: UIImage? = nil
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var reviewImages: [UIImage] = []
    @State private var showReview = false
    @State private var isLoadingImages = false
    @State private var showScanRangePicker = false
    @State private var showGeminiConsent = false
    @State private var geminiConsentPurpose: GeminiConsentPurpose = .manualAdd
    @Environment(\.scenePhase) private var scenePhase

    private enum GeminiConsentPurpose {
        case manualAdd
        case autoScan
        case scanRangePicker
    }

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
        .confirmationDialog("Add New Item", isPresented: $showSourcePicker, titleVisibility: .visible) {
            Button("Choose from Gallery") { showPhotoPicker = true }
            Button("Take Photo") { showCamera = true }
            if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
                Button("Auto-scan from Photos") {
                    let userId = authService.user?.id ?? ""
                    if GeminiConsent.hasConsented(userId: userId) {
                        showScanRangePicker = true
                    } else {
                        geminiConsentPurpose = .scanRangePicker
                        showGeminiConsent = true
                    }
                }
            }
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
                    let userId = authService.user?.id ?? ""
                    if GeminiConsent.hasConsented(userId: userId) {
                        showReview = true
                    } else {
                        geminiConsentPurpose = .manualAdd
                        showGeminiConsent = true
                    }
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
                            let userId = authService.user?.id ?? ""
                            if GeminiConsent.hasConsented(userId: userId) {
                                showReview = true
                            } else {
                                geminiConsentPurpose = .manualAdd
                                showGeminiConsent = true
                            }
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
            AddItemReviewView(images: reviewImages, isPresented: $showReview)
                .environmentObject(wardrobeVM)
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
                    Task {
                        await PhotoScanService.shared.startScan(
                            forUser: authService.user?.id ?? "",
                            dateRange: dateRange,
                            userGender: authService.user?.gender,
                            wardrobeViewModel: wardrobeVM
                        )
                    }
                }
            )
        }
        .sheet(isPresented: $showGeminiConsent) {
            GeminiConsentView(
                onConsent: {
                    let userId = authService.user?.id ?? ""
                    GeminiConsent.grant(userId: userId)
                    showGeminiConsent = false
                    switch geminiConsentPurpose {
                    case .manualAdd:
                        showReview = true
                    case .scanRangePicker:
                        showScanRangePicker = true
                    case .autoScan:
                        Task {
                            await PhotoScanService.shared.startScan(
                                forUser: userId,
                                dateRange: .lastSixMonths,
                                userGender: authService.user?.gender,
                                wardrobeViewModel: wardrobeVM
                            )
                        }
                    }
                },
                onDecline: {
                    showGeminiConsent = false
                    if geminiConsentPurpose == .manualAdd {
                        reviewImages = []
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
            if newPhase == .active,
               authService.isAuthenticated,
               !wardrobeVM.currentUserEmail.isEmpty {
                Task {
                    let isAvailable = await CloudKitService.shared.checkAccountStatus()
                    if isAvailable {
                        await wardrobeVM.restoreFromCloud()
                    }
                }
            }
        }
        .onChange(of: onboardingManager.hasCompletedOnboarding) { completed in
            guard completed,
                  authService.isAuthenticated,
                  let userId = authService.user?.id, !userId.isEmpty,
                  !UserDefaults.standard.bool(forKey: "hasCompletedInitialScan_\(userId)"),
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }

            if !GeminiConsent.hasConsented(userId: userId) {
                geminiConsentPurpose = .autoScan
                showGeminiConsent = true
            }
        }
        .task(id: onboardingManager.hasCompletedOnboarding) {
            let userId = authService.user?.id ?? ""
            let scanKey = "hasCompletedInitialScan_\(userId)"

            guard onboardingManager.hasCompletedOnboarding,
                  authService.isAuthenticated,
                  !userId.isEmpty,
                  !UserDefaults.standard.bool(forKey: scanKey),
                  GeminiConsent.hasConsented(userId: userId),
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                  PhotoScanService.shared.scanState == .idle else { return }

            print("[StyleMate] Auto-scan triggered after onboarding completion")

            await PhotoScanService.shared.startScan(
                forUser: userId,
                dateRange: .lastSixMonths,
                userGender: authService.user?.gender,
                wardrobeViewModel: wardrobeVM
            )

            if PhotoScanService.shared.scanState == .completed {
                UserDefaults.standard.set(true, forKey: scanKey)
            }
        }
    }
}
