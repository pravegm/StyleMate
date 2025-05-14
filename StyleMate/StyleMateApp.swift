//
//  StyleMateApp.swift
//  StyleMate
//
//  Created by Praveg Maheshwari on 12/5/2025.
//

import SwiftUI
import PhotosUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // No Firebase needed for local only
        return true
    }
}

@main
struct StyleMateApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var authService = AuthService()
    @StateObject private var wardrobeVM = WardrobeViewModel()
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authService)
                .environmentObject(wardrobeVM)
        }
    }
}

enum AddFlow: Identifiable {
    case camera
    case form(UIImage)
    var id: String {
        switch self {
        case .camera: return "camera"
        case .form: return "form"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @State private var lastUserKey: String = ""
    @State private var showAddSheet: Bool = false
    @State private var activeAddFlow: AddFlow?
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var showForm = false
    @State private var selectedImage: UIImage? = nil
    
    var userKey: String {
        if let email = authService.user?.email, !email.isEmpty {
            return email
        } else {
            return "guest"
        }
    }
    
    var body: some View {
        ZStack {
            Group {
                if authService.isAuthenticated {
                    MainTabViewWrapper(showAddSheet: $showAddSheet, activeAddFlow: $activeAddFlow)
                } else {
                    LoginView()
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSourceSheet(photoPickerItem: $photoPickerItem, onCamera: { 
                activeAddFlow = .camera
            })
        }
        .onChange(of: photoPickerItem) { item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    selectedImage = image
                    showForm = true
                    showAddSheet = false
                }
                photoPickerItem = nil
            }
        }
        .sheet(item: $activeAddFlow) { flow in
            switch flow {
            case .camera:
                CameraSheet { image in
                    if let image = image {
                        selectedImage = image
                        showForm = true
                    }
                    activeAddFlow = nil
                }
            case .form:
                EmptyView()
            }
        }
        .sheet(isPresented: $showForm) {
            if let image = selectedImage {
                NavigationStack {
                    AddNewItemView(
                        showPhotoPicker: .constant(false),
                        showCamera: .constant(false),
                        isPresented: $showForm,
                        prefilledImage: image
                    )
                    .environmentObject(wardrobeVM)
                }
            } else {
                Text("No image selected.")
            }
        }
        .onChange(of: showForm) { newValue in
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            if isAuthenticated, let email = authService.user?.email {
                wardrobeVM.load(forUser: email)
                lastUserKey = userKey
            } else {
                wardrobeVM.clear()
                lastUserKey = ""
            }
        }
        .onAppear {
            if authService.isAuthenticated, let email = authService.user?.email {
                wardrobeVM.load(forUser: email)
                lastUserKey = userKey
            }
        }
    }
}

struct AddSourceSheet: View {
    @Binding var photoPickerItem: PhotosPickerItem?
    var onCamera: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 24) {
            Text("Add New Item")
                .font(.title2.bold())
                .padding(.top, 24)
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 28))
                    Text("Choose from Library")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            Button(action: {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onCamera() }
            }) {
                HStack {
                    Image(systemName: "camera")
                        .font(.system(size: 28))
                    Text("Take Photo")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            Spacer()
        }
        .padding()
        .presentationDetents([.medium, .large])
    }
}

struct CameraSheet: View {
    var onImagePicked: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage? = nil
    var body: some View {
        ImagePicker(image: Binding(get: { image }, set: { img in
            image = img
            if img != nil {
                onImagePicked(img)
                dismiss()
            }
        }))
    }
}

struct MainTabViewWrapper: View {
    @Binding var showAddSheet: Bool
    @Binding var activeAddFlow: AddFlow?
    var body: some View {
        MainTabView(showAddSheet: $showAddSheet, activeAddFlow: $activeAddFlow)
    }
}
