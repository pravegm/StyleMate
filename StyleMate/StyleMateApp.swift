import SwiftUI
import PhotosUI
import GoogleSignIn

@main
struct StyleMateApp: App {
    @StateObject private var authService = AuthService()
    @StateObject private var wardrobeVM = WardrobeViewModel()
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(wardrobeVM)
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
    @Environment(\.scenePhase) private var scenePhase

    var userKey: String {
        authService.user?.id ?? "guest"
    }

    var body: some View {
        ZStack {
            Group {
                if authService.isAuthenticated {
                    MainTabView(showAddSheet: $showSourcePicker)
                        .environmentObject(outfitsVM)
                } else {
                    LoginView()
                }
            }
        }
        .confirmationDialog("Add New Item", isPresented: $showSourcePicker, titleVisibility: .visible) {
            Button("Choose from Gallery") { showPhotoPicker = true }
            Button("Take Photo") { showCamera = true }
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
            AddItemReviewView(images: reviewImages, isPresented: $showReview)
                .environmentObject(wardrobeVM)
        }
        .overlay {
            if isLoadingImages {
                OutfitLoadingOverlay(progress: 0.5, message: "Loading images…")
            }
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            if isAuthenticated, let id = authService.user?.id {
                wardrobeVM.load(forUser: id)
                lastUserKey = userKey
                wardrobeVM.migrateBackgroundRemoval()

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
                wardrobeVM.migrateBackgroundRemoval()

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
    }
}
