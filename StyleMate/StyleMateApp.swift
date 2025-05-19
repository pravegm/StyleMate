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

struct CapturedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct RootView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var wardrobeVM: WardrobeViewModel
    @State private var lastUserKey: String = ""
    @State private var showAddSheet: Bool = false
    @State private var activeAddFlow: AddFlow?
    @State private var capturedImage: CapturedImage? = nil
    @State private var showReviewBatch = false
    @State private var selectedImages: [UIImage] = []
    @State private var showPickerTip = false
    @AppStorage("hasShownPickerTip") private var hasShownPickerTip: Bool = false
    @State private var pendingAction: (() -> Void)? = nil
    // PhotosPicker state
    @State private var galleryItems: [PhotosPickerItem] = []
    @State private var isLoadingGalleryImages = false
    @State private var showGalleryPicker = false
    
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
        // Present PhotosPicker directly from AddSourceSheet
        .photosPicker(isPresented: $showGalleryPicker, selection: $galleryItems, maxSelectionCount: 15, matching: .images)
        .onChange(of: galleryItems) { items in
            if !items.isEmpty {
                isLoadingGalleryImages = true
                loadGalleryImages()
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            if let action = pendingAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    action()
                    pendingAction = nil
                }
            }
        }) {
            AddSourceSheet(
                onSelectFromGallery: {
                    pendingAction = {
                        if !hasShownPickerTip {
                            showPickerTip = true
                        } else {
                            showGalleryPicker = true
                        }
                    }
                    showAddSheet = false
                },
                onTakePhoto: {
                    pendingAction = {
                        activeAddFlow = .camera
                    }
                    showAddSheet = false
                }
            )
        }
        .sheet(isPresented: $showPickerTip, onDismiss: {
            if showPickerTip == false {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showGalleryPicker = true
                }
            }
        }) {
            TipSheet(showPickerTip: $showPickerTip, hasShownPickerTip: $hasShownPickerTip, showPhotoPicker: $showGalleryPicker)
        }
        .sheet(isPresented: $showReviewBatch, onDismiss: {
            selectedImages = []
        }) {
            MultiAddNewItemView(images: selectedImages, isPresented: $showReviewBatch)
                .environmentObject(wardrobeVM)
        }
        .sheet(item: $activeAddFlow) { flow in
            switch flow {
            case .camera:
                CameraSheet { image in
                    if let image = image {
                        capturedImage = CapturedImage(image: image)
                    }
                    activeAddFlow = nil
                }
            case .form:
                EmptyView()
            }
        }
        .sheet(item: $capturedImage, onDismiss: { capturedImage = nil }) { captured in
            MultiAddNewItemView(
                images: [captured.image],
                isPresented: Binding(
                    get: { capturedImage != nil },
                    set: { newValue in if !newValue { capturedImage = nil } }
                )
            )
            .environmentObject(wardrobeVM)
        }
        .overlay {
            if isLoadingGalleryImages {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView("Loading images...")
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
                }
            }
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
    // Helper for loading images from PhotosPickerItems
    private func loadGalleryImages() {
        Task {
            var images: [UIImage] = []
            for item in galleryItems {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            selectedImages = images
            isLoadingGalleryImages = false
            galleryItems = []
            if !images.isEmpty {
                showReviewBatch = true
            }
        }
    }
}

struct AddSourceSheet: View {
    var onSelectFromGallery: () -> Void
    var onTakePhoto: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Text("Add New Item")
                .font(.title2.bold())
                .padding(.top, 24)
            Button(action: onSelectFromGallery) {
                HStack {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 28))
                    Text("Choose from Gallery")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
            }
            // Styled warning directly below the Gallery button
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 18))
                Text("For best results, only pick images with only you in the picture. Avoid images with multiple people, as this can give unexpected results.")
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(8)
            .padding(.top, 4)
            .padding(.bottom, 16) // More space before next button
            Button(action: onTakePhoto) {
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

struct TipSheet: View {
    @Binding var showPickerTip: Bool
    @Binding var hasShownPickerTip: Bool
    @Binding var showPhotoPicker: Bool
    var body: some View {
        VStack(spacing: 24) {
            Text("Tip")
                .font(.title2.bold())
                .padding(.top, 24)
            Text("Tap multiple images to select them, then tap 'Add' or 'Done' to confirm.")
                .font(.body)
                .multilineTextAlignment(.center)
            Button("Continue") {
                hasShownPickerTip = true
                showPhotoPicker = true
            }
            .font(.headline)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .padding()
        .presentationDetents([.medium])
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

// New: MultiAddNewItemView for reviewing multiple images in AddNewItemView style
import SwiftUI
struct MultiAddNewItemView: View {
    let images: [UIImage]
    @Binding var isPresented: Bool
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @State private var detectedItems: [[AddNewItemView.DetectedItem]] = []
    @State private var brandInputs: [[String]] = []
    @State private var isAnalyzing = true
    @State private var currentIndex = 0
    @State private var errorMessage = ""
    @State private var showError = false
    @State private var savedStates: [Bool?] = [] // true=saved, false=removed, nil=pending
    @State private var showToast = false
    @State private var toastText = ""
    @State private var showSummary = false
    @State private var showCancelConfirm = false
    @State private var analysisStates: [Bool] = [] // true = analyzed, false = analyzing
    // New: duplicate acknowledged state per image
    @State private var duplicateAcknowledged: [[Bool]] = []
    var canFinish: Bool { savedStates.contains(true) }
    var allReviewed: Bool { savedStates.indices.allSatisfy { idx in savedStates[idx] != nil || !analysisStates.indices.contains(idx) || !analysisStates[idx] } }
    var canAddAll: Bool {
        // Only allow Add All for images that are done analyzing and not removed/saved and all duplicates acknowledged
        savedStates.indices.contains { idx in savedStates[idx] == nil && analysisStates.indices.contains(idx) && analysisStates[idx] && allDuplicatesAcknowledged(for: idx) }
    }
    var body: some View {
        NavigationStack {
            if showSummary {
                SummaryView(savedItems: savedWardrobeItems()) {
                    isPresented = false
                }
            } else {
                VStack(spacing: 0) {
                    // Navigation controls
                    HStack(alignment: .center, spacing: 16) {
                        Button(action: { if currentIndex > 0 { currentIndex -= 1 } }) {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(currentIndex == 0 ? .gray : .blue)
                        }
                        .disabled(currentIndex == 0)
                        Spacer()
                        Text("Image \(currentIndex + 1) of \(images.count)")
                            .font(.headline)
                        Spacer()
                        Button(action: { if currentIndex < images.count - 1 { currentIndex += 1 } }) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(currentIndex == images.count - 1 ? .gray : .blue)
                        }
                        .disabled(currentIndex == images.count - 1)
                        Button("Add All") {
                            addAllAndShowSummary()
                        }
                        .disabled(!canAddAll)
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    // Page indicator dots
                    HStack(spacing: 8) {
                        ForEach(0..<images.count, id: \ .self) { idx in
                            let state = savedStates.indices.contains(idx) ? savedStates[idx] : nil
                            Circle()
                                .fill(state == true ? Color.green : (state == false ? Color.red : Color(.systemGray4)))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .padding(.vertical, 8)
                    // Image review area
                    ZStack {
                        TabView(selection: $currentIndex) {
                            ForEach(images.indices, id: \ .self) { idx in
                                ZStack {
                                    if detectedItems.indices.contains(idx) && brandInputs.indices.contains(idx) && duplicateAcknowledged.indices.contains(idx) {
                                        AddNewItemViewInternal(
                                            image: images[idx],
                                            detectedItems: $detectedItems[idx],
                                            brandInputs: $brandInputs[idx],
                                            hideToolbar: true,
                                            duplicateAcknowledged: $duplicateAcknowledged[idx]
                                        )
                                        .tag(idx)
                                        .padding(.vertical)
                                    } else {
                                        // Show a spinner/placeholder while arrays are not ready
                                        VStack {
                                            Spacer()
                                            ProgressView("Preparing...")
                                            Spacer()
                                        }
                                        .tag(idx)
                                    }
                                    // Overlay spinner if not analyzed
                                    if !analysisStates.indices.contains(idx) || !analysisStates[idx] {
                                        Color.white.opacity(0.7)
                                            .cornerRadius(16)
                                        VStack {
                                            ProgressView()
                                            Text("Analyzing...")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .indexViewStyle(.page(backgroundDisplayMode: .never))
                        .frame(maxHeight: .infinity)
                        if showToast {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Label(toastText, systemImage: toastText == "Saved!" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(.title2.bold())
                                        .padding(16)
                                        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)).shadow(radius: 4))
                                        .foregroundColor(toastText == "Saved!" ? .green : .red)
                                    Spacer()
                                }
                                Spacer()
                            }
                            .transition(.opacity)
                        }
                    }
                    // Per-image Save/Remove controls
                    HStack(spacing: 24) {
                        Button(role: .destructive) {
                            markRemovedAndAdvance()
                        } label: {
                            Label("Remove Fit", systemImage: "trash")
                        }
                        .disabled(
                            !(savedStates.indices.contains(currentIndex) && analysisStates.indices.contains(currentIndex)) ||
                            savedStates[currentIndex] == false || !isAnalyzed(currentIndex)
                        )
                        Button {
                            saveCurrentAndAdvance()
                        } label: {
                            Label("Save Fit", systemImage: "checkmark")
                        }
                        .disabled(
                            !(savedStates.indices.contains(currentIndex) && detectedItems.indices.contains(currentIndex) && analysisStates.indices.contains(currentIndex)) ||
                            savedStates[currentIndex] == true || detectedItems[currentIndex].isEmpty || !isAnalyzed(currentIndex) || !allDuplicatesAcknowledged(for: currentIndex)
                        )
                    }
                    .padding(.vertical, 8)
                    // Save/Cancel controls
                    HStack {
                        Button("Cancel") { showCancelConfirm = true }
                        Spacer()
                        Button("Done") {
                            saveAllAndShowSummary()
                        }
                        .disabled(!canFinish)
                    }
                    .padding()
                }
                .navigationTitle("Review Items")
                .alert("Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
                .alert("Are you sure you want to cancel? Unsaved changes will be lost.", isPresented: $showCancelConfirm) {
                    Button("No", role: .cancel) {}
                    Button("Yes", role: .destructive) { isPresented = false }
                }
                .onAppear {
                    analyzeAllImagesInParallel()
                }
            }
        }
    }
    private func analyzeAllImagesInParallel() {
        isAnalyzing = true
        detectedItems = Array(repeating: [], count: images.count)
        brandInputs = Array(repeating: [], count: images.count)
        savedStates = Array(repeating: nil, count: images.count)
        analysisStates = Array(repeating: false, count: images.count)
        duplicateAcknowledged = Array(repeating: [], count: images.count)
        Task {
            await withTaskGroup(of: (Int, [(Category?, String?, [String], Pattern?, ImageAnalysisService.BoundingBox?)]).self) { group in
                for (idx, image) in images.enumerated() {
                    group.addTask {
                        let results = await ImageAnalysisService.shared.analyzeMultiple(image: image, imageIndex: idx)
                        return (idx, results)
                    }
                }
                for await (idx, results) in group {
                    var items = results.compactMap { cat, prod, colors, pattern, bbox in
                        if let cat = cat, let prod = prod, let pattern = pattern, !colors.isEmpty {
                            let cropped = cropImage(images[idx], with: bbox)
                            return AddNewItemView.DetectedItem(category: cat, product: prod, colors: colors, pattern: pattern, boundingBox: bbox, croppedImage: cropped)
                        } else {
                            return nil
                        }
                    }
                    // Filter duplicate footwear: if 2+ footwear, keep only one
                    let footwearIndices = items.indices.filter { items[$0].category == .footwear }
                    if footwearIndices.count > 1 {
                        items = items.enumerated().filter { idx2, item in
                            item.category != .footwear || idx2 == footwearIndices.first
                        }.map { $0.element }
                    }
                    if items.isEmpty && !results.isEmpty {
                        print("[DEBUG] Gemini raw results for image #\(idx): \(results)")
                    }
                    await MainActor.run {
                        detectedItems[idx] = items
                        brandInputs[idx] = Array(repeating: "", count: items.count)
                        analysisStates[idx] = true
                        duplicateAcknowledged[idx] = Array(repeating: false, count: items.count)
                    }
                }
            }
            await MainActor.run {
                isAnalyzing = false
            }
        }
    }
    private func isAnalyzed(_ idx: Int) -> Bool {
        analysisStates.indices.contains(idx) && analysisStates[idx]
    }
    private func saveCurrentAndAdvance() {
        guard isAnalyzed(currentIndex) else { return }
        savedStates[currentIndex] = true
        showToastWith(text: "Saved!")
        advanceToNext()
    }
    private func markRemovedAndAdvance() {
        guard isAnalyzed(currentIndex) else { return }
        savedStates[currentIndex] = false
        showToastWith(text: "Removed")
        advanceToNext()
    }
    private func advanceToNext() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if let next = (currentIndex+1..<savedStates.count).first(where: { savedStates[$0] == nil }) {
                currentIndex = next
            } else if let prev = (0..<currentIndex).reversed().first(where: { savedStates[$0] == nil }) {
                currentIndex = prev
            } else if allReviewed {
                saveAllAndShowSummary()
            }
        }
    }
    private func showToastWith(text: String) {
        toastText = text
        withAnimation { showToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation { showToast = false }
        }
    }
    private func saveAllAndShowSummary() {
        for (imgIdx, items) in detectedItems.enumerated() where savedStates[imgIdx] == true {
            for (itemIdx, detected) in items.enumerated() {
                let imagePath = WardrobeImageFileHelper.saveImage(images[imgIdx]) ?? ""
                let croppedImagePath = detected.croppedImage != nil ? WardrobeImageFileHelper.saveImage(detected.croppedImage!) : nil
                let item = WardrobeItem(
                    category: detected.category,
                    product: detected.product,
                    colors: detected.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                    brand: brandInputs[imgIdx][itemIdx],
                    pattern: detected.pattern,
                    imagePath: imagePath,
                    croppedImagePath: croppedImagePath
                )
                wardrobeViewModel.items.append(item)
            }
        }
        showSummary = true
    }
    private func savedWardrobeItems() -> [WardrobeItem] {
        var result: [WardrobeItem] = []
        for (imgIdx, items) in detectedItems.enumerated() where savedStates[imgIdx] == true {
            for (itemIdx, detected) in items.enumerated() {
                let imagePath = WardrobeImageFileHelper.saveImage(images[imgIdx]) ?? ""
                let croppedImagePath = detected.croppedImage != nil ? WardrobeImageFileHelper.saveImage(detected.croppedImage!) : nil
                let item = WardrobeItem(
                    category: detected.category,
                    product: detected.product,
                    colors: detected.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                    brand: brandInputs[imgIdx][itemIdx],
                    pattern: detected.pattern,
                    imagePath: imagePath,
                    croppedImagePath: croppedImagePath
                )
                result.append(item)
            }
        }
        return result
    }
    private func cropImage(_ image: UIImage, with bbox: ImageAnalysisService.BoundingBox?) -> UIImage? {
        guard let bbox = bbox else { return nil }
        let width = image.size.width
        let height = image.size.height
        let minCropPercent: CGFloat = 0.5 // 50% minimum
        var rect: CGRect
        if height >= width { // Portrait or square: retain full width, crop height
            let cropY = bbox.y * height
            var cropH = bbox.height * height
            if cropH < height * minCropPercent {
                cropH = height * minCropPercent
                // Center the crop on the bounding box center
                let centerY = cropY + (bbox.height * height) / 2
                let newY = max(0, min(centerY - cropH / 2, height - cropH))
                rect = CGRect(x: 0, y: newY, width: width, height: cropH)
            } else {
                rect = CGRect(x: 0, y: cropY, width: width, height: cropH)
            }
            rect.origin.y = max(0, rect.origin.y)
            if rect.maxY > height { rect.size.height = height - rect.origin.y }
        } else { // Landscape: retain full height, crop width
            let cropX = bbox.x * width
            var cropW = bbox.width * width
            if cropW < width * minCropPercent {
                cropW = width * minCropPercent
                // Center the crop on the bounding box center
                let centerX = cropX + (bbox.width * width) / 2
                let newX = max(0, min(centerX - cropW / 2, width - cropW))
                rect = CGRect(x: newX, y: 0, width: cropW, height: height)
            } else {
                rect = CGRect(x: cropX, y: 0, width: cropW, height: height)
            }
            rect.origin.x = max(0, rect.origin.x)
            if rect.maxX > width { rect.size.width = width - rect.origin.x }
        }
        guard let cgImage = image.cgImage?.cropping(to: rect) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
    private func addAllAndShowSummary() {
        for idx in savedStates.indices where savedStates[idx] == nil && isAnalyzed(idx) && allDuplicatesAcknowledged(for: idx) {
            savedStates[idx] = true
        }
        saveAllAndShowSummary()
    }
    // Helper to check if all duplicates are acknowledged for a given image
    private func allDuplicatesAcknowledged(for imageIdx: Int) -> Bool {
        guard detectedItems.indices.contains(imageIdx), duplicateAcknowledged.indices.contains(imageIdx) else { return true }
        for (idx, detected) in detectedItems[imageIdx].enumerated() {
            if isDuplicateItem(detected, imageIdx: imageIdx, itemIdx: idx) && (!duplicateAcknowledged[imageIdx].indices.contains(idx) || !duplicateAcknowledged[imageIdx][idx]) {
                return false
            }
        }
        return true
    }
    // Helper to check for duplicate for a given image/item
    private func isDuplicateItem(_ item: AddNewItemView.DetectedItem, imageIdx: Int, itemIdx: Int) -> Bool {
        let brand = brandInputs[imageIdx].indices.contains(itemIdx) ? brandInputs[imageIdx][itemIdx] : ""
        return wardrobeViewModel.items.contains { wardrobeItem in
            wardrobeItem.category == item.category &&
            wardrobeItem.product.caseInsensitiveCompare(item.product) == .orderedSame &&
            wardrobeItem.pattern == item.pattern &&
            wardrobeItem.brand.caseInsensitiveCompare(brand) == .orderedSame &&
            Set(wardrobeItem.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }) == Set(item.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        }
    }
}

// Internal AddNewItemView logic for a single image (reuses your existing UI)
struct AddNewItemViewInternal: View {
    let image: UIImage
    @Binding var detectedItems: [AddNewItemView.DetectedItem]
    @Binding var brandInputs: [String]
    var hideToolbar: Bool = false
    @Binding var duplicateAcknowledged: [Bool]
    var body: some View {
        VStack {
            AddNewItemView(
                showPhotoPicker: .constant(false),
                showCamera: .constant(false),
                isPresented: .constant(true),
                prefilledImage: image,
                detectedItemsBinding: $detectedItems,
                brandInputsBinding: $brandInputs,
                duplicateAcknowledgedBinding: $duplicateAcknowledged
            )
            .toolbar(hideToolbar ? .hidden : .visible, for: .navigationBar)
        }
    }
}
