//
//  StyleMateApp.swift
//  StyleMate
//
//  Created by Praveg Maheshwari on 12/5/2025.
//

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

enum AddFlow: Identifiable {
    case camera
    var id: String {
        switch self {
        case .camera: return "camera"
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
    @State private var galleryItems: [PhotosPickerItem] = []
    @State private var isLoadingGalleryImages = false
    @State private var showGalleryPicker = false

    var userKey: String {
        authService.user?.id ?? "guest"
    }

    var body: some View {
        ZStack {
            Group {
                if authService.isAuthenticated {
                    MainTabViewWrapper(showAddSheet: $showAddSheet)
                } else {
                    LoginView()
                }
            }
        }
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
            CameraSheet { image in
                if let image = image {
                    capturedImage = CapturedImage(image: image)
                }
                activeAddFlow = nil
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
                OutfitLoadingOverlay(progress: 0.5, message: "Loading images…")
            }
        }
        .onChange(of: authService.isAuthenticated) { isAuthenticated in
            if isAuthenticated, let id = authService.user?.id {
                wardrobeVM.load(forUser: id)
                lastUserKey = userKey
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
            }
        }
    }

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

// MARK: - Add Source Sheet

struct AddSourceSheet: View {
    var onSelectFromGallery: () -> Void
    var onTakePhoto: () -> Void

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text("Add New Item")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.top, DS.Spacing.lg)

            Button(action: onSelectFromGallery) {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 28))
                        .foregroundColor(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Choose from Gallery")
                            .font(DS.Font.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Select one or more photos")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .dsCardShadow()
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: DS.Spacing.xs) {
                Image(systemName: "info.circle")
                    .foregroundColor(DS.Colors.textTertiary)
                    .font(DS.Font.subheadline)
                Text("For best results, pick images with only you in the picture.")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .padding(.horizontal, DS.Spacing.md)

            Button(action: onTakePhoto) {
                HStack(spacing: DS.Spacing.md) {
                    Image(systemName: "camera")
                        .font(.system(size: 28))
                        .foregroundColor(DS.Colors.accent)
                    VStack(alignment: .leading, spacing: DS.Spacing.micro) {
                        Text("Take Photo")
                            .font(DS.Font.headline)
                            .foregroundColor(DS.Colors.textPrimary)
                        Text("Use your camera")
                            .font(DS.Font.caption1)
                            .foregroundColor(DS.Colors.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(DS.Spacing.md)
                .background(DS.Colors.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                .dsCardShadow()
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .background(DS.Colors.backgroundPrimary)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Tip Sheet

struct TipSheet: View {
    @Binding var showPickerTip: Bool
    @Binding var hasShownPickerTip: Bool
    @Binding var showPhotoPicker: Bool

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            Image(systemName: "hand.tap")
                .font(.system(size: 40))
                .foregroundColor(DS.Colors.accent)
                .padding(.top, DS.Spacing.xl)

            Text("Tip")
                .font(DS.Font.title2)
                .foregroundColor(DS.Colors.textPrimary)

            Text("Tap multiple images to select them, then tap 'Add' or 'Done' to confirm.")
                .font(DS.Font.body)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button("Continue") {
                hasShownPickerTip = true
                showPhotoPicker = true
            }
            .buttonStyle(DSPrimaryButton())
            .padding(.horizontal, DS.Spacing.screenH)
        }
        .padding(.horizontal, DS.Spacing.screenH)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Camera Sheet

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

// MARK: - Tab View Wrapper

struct MainTabViewWrapper: View {
    @Binding var showAddSheet: Bool
    var body: some View {
        MainTabView(showAddSheet: $showAddSheet)
    }
}

// MARK: - Multi Add New Item View

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
    @State private var savedStates: [Bool?] = []
    @State private var showToast = false
    @State private var toastText = ""
    @State private var showSummary = false
    @State private var showCancelConfirm = false
    @State private var analysisStates: [Bool] = []
    @State private var duplicateAcknowledged: [[Bool]] = []
    @State private var progress: Double = 0.0
    @State private var progressTimer: Timer? = nil
    @State private var reanalyzingIndex: Int? = nil
    @State private var reanalyzeProgress: Double = 0.0
    @State private var reanalyzeProgressTimer: Timer? = nil

    var canFinish: Bool { savedStates.contains(true) }
    var allReviewed: Bool {
        savedStates.indices.allSatisfy { idx in
            savedStates[idx] != nil || !analysisStates.indices.contains(idx) || !analysisStates[idx]
        }
    }
    var canAddAll: Bool {
        savedStates.indices.contains { idx in
            savedStates[idx] == nil && analysisStates.indices.contains(idx) && analysisStates[idx] && allDuplicatesAcknowledged(for: idx)
        }
    }

    var body: some View {
        NavigationStack {
            if showSummary {
                SummaryView(savedItems: savedWardrobeItems()) {
                    isPresented = false
                }
            } else {
                ZStack {
                    DS.Colors.backgroundPrimary.ignoresSafeArea()

                    VStack(spacing: 0) {
                        // Top bar: pager
                        HStack(alignment: .center, spacing: DS.Spacing.md) {
                            Button(action: { if currentIndex > 0 { currentIndex -= 1 } }) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(currentIndex == 0 ? DS.Colors.textTertiary : DS.Colors.accent)
                            }
                            .disabled(currentIndex == 0)

                            Spacer()

                            Text("Image \(currentIndex + 1) of \(images.count)")
                                .font(DS.Font.headline)
                                .foregroundColor(DS.Colors.textPrimary)

                            Spacer()

                            Button(action: { if currentIndex < images.count - 1 { currentIndex += 1 } }) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(currentIndex == images.count - 1 ? DS.Colors.textTertiary : DS.Colors.accent)
                            }
                            .disabled(currentIndex == images.count - 1)
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.top, DS.Spacing.sm)

                        // Page indicator
                        HStack(spacing: DS.Spacing.xs) {
                            ForEach(0..<images.count, id: \.self) { idx in
                                let isSaved = savedStates.indices.contains(idx) && savedStates[idx] == true
                                let isRejected = savedStates.indices.contains(idx) && savedStates[idx] == false
                                let hasWarning: Bool = {
                                    guard detectedItems.indices.contains(idx), duplicateAcknowledged.indices.contains(idx) else { return false }
                                    for (itemIdx, detected) in detectedItems[idx].enumerated() {
                                        if isDuplicateItem(detected, imageIdx: idx, itemIdx: itemIdx) && (!duplicateAcknowledged[idx].indices.contains(itemIdx) || !duplicateAcknowledged[idx][itemIdx]) { return true }
                                    }
                                    return false
                                }()
                                let isCurrent = idx == currentIndex
                                let dotColor: Color = isSaved ? DS.Colors.success : (isRejected ? DS.Colors.error : (hasWarning ? DS.Colors.warning : DS.Colors.textTertiary))

                                Circle()
                                    .fill(dotColor)
                                    .frame(width: isCurrent ? 12 : 8, height: isCurrent ? 12 : 8)
                                    .animation(.easeInOut(duration: 0.15), value: isCurrent)
                            }
                        }
                        .padding(.vertical, DS.Spacing.xs)

                        // Content pager
                        ZStack {
                            TabView(selection: $currentIndex) {
                                ForEach(images.indices, id: \.self) { idx in
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
                                        } else {
                                            VStack {
                                                Spacer()
                                                ProgressView()
                                                Text("Preparing…")
                                                    .font(DS.Font.subheadline)
                                                    .foregroundColor(DS.Colors.textSecondary)
                                                Spacer()
                                            }
                                            .tag(idx)
                                        }

                                        if (!analysisStates.indices.contains(idx) || !analysisStates[idx]) && reanalyzingIndex != idx {
                                            Color(DS.Colors.backgroundPrimary).opacity(0.7)
                                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                            VStack {
                                                ProgressView()
                                                Text("Analyzing…")
                                                    .font(DS.Font.subheadline)
                                                    .foregroundColor(DS.Colors.textSecondary)
                                            }
                                        }

                                        if reanalyzingIndex == idx {
                                            OutfitLoadingOverlay(progress: reanalyzeProgress, message: "Re-analyzing image…")
                                                .onAppear {
                                                    reanalyzeProgress = 0.0
                                                    reanalyzeProgressTimer?.invalidate()
                                                    reanalyzeProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { timer in
                                                        if reanalyzeProgress < 0.98 { reanalyzeProgress += 0.006 } else { timer.invalidate() }
                                                    }
                                                }
                                                .onDisappear { reanalyzeProgressTimer?.invalidate() }
                                        }
                                    }
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                            .frame(maxHeight: .infinity)

                            if showToast {
                                VStack {
                                    Spacer()
                                    Label(toastText, systemImage: toastText == "Saved!" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .font(DS.Font.headline)
                                        .padding(DS.Spacing.md)
                                        .background(DS.Colors.backgroundCard)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                                        .dsCardShadow()
                                        .foregroundColor(toastText == "Saved!" ? DS.Colors.success : DS.Colors.error)
                                    Spacer()
                                }
                                .transition(.opacity)
                            }
                        }

                        // Bottom actions
                        VStack(spacing: DS.Spacing.sm) {
                            // Reanalyze (context action, smaller)
                            Button(action: { reanalyzeCurrentImage() }) {
                                HStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: "arrow.clockwise")
                                    Text("Reanalyze Image")
                                }
                                .font(DS.Font.subheadline)
                                .foregroundColor(DS.Colors.accent)
                            }

                            HStack(spacing: DS.Spacing.md) {
                                Button(role: .destructive) { markRemovedAndAdvance() } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                                .buttonStyle(DSSecondaryButton())
                                .disabled(
                                    !(savedStates.indices.contains(currentIndex) && analysisStates.indices.contains(currentIndex)) ||
                                    savedStates[currentIndex] == false || !isAnalyzed(currentIndex)
                                )

                                Button { saveCurrentAndAdvance() } label: {
                                    Label("Save", systemImage: "checkmark")
                                }
                                .buttonStyle(DSPrimaryButton())
                                .disabled(
                                    !(savedStates.indices.contains(currentIndex) && detectedItems.indices.contains(currentIndex) && analysisStates.indices.contains(currentIndex)) ||
                                    savedStates[currentIndex] == true || detectedItems[currentIndex].isEmpty || !isAnalyzed(currentIndex) || !allDuplicatesAcknowledged(for: currentIndex)
                                )
                            }

                            HStack {
                                Button("Cancel") { showCancelConfirm = true }
                                    .buttonStyle(DSTertiaryButton())
                                Spacer()
                                if canAddAll {
                                    Button("Add All") { addAllAndShowSummary() }
                                        .buttonStyle(DSTertiaryButton())
                                }
                            }
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                        .padding(.bottom, DS.Spacing.sm)
                    }

                    if isAnalyzing {
                        OutfitLoadingOverlay(progress: progress, message: "Analyzing your items…")
                            .onAppear {
                                progress = 0.0
                                progressTimer?.invalidate()
                                progressTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { timer in
                                    if progress < 0.98 { progress += 0.006 } else { timer.invalidate() }
                                }
                            }
                            .onDisappear { progressTimer?.invalidate() }
                    }
                }
                .navigationTitle("Review Items")
                .alert("Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: { Text(errorMessage) }
                .alert("Are you sure you want to cancel? Unsaved changes will be lost.", isPresented: $showCancelConfirm) {
                    Button("No", role: .cancel) {}
                    Button("Yes", role: .destructive) { isPresented = false }
                }
                .interactiveDismissDisabled(showCancelConfirm == false)
                .onAppear { analyzeAllImagesInParallel() }
            }
        }
    }

    // MARK: - Analysis

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
                        } else { return nil }
                    }
                    let footwearIndices = items.indices.filter { items[$0].category == .footwear }
                    if footwearIndices.count > 1 {
                        items = items.enumerated().filter { i, item in
                            item.category != .footwear || i == footwearIndices.first
                        }.map { $0.element }
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
                progress = 1.0
            }
        }
    }

    private func reanalyzeCurrentImage() {
        let idx = currentIndex
        reanalyzingIndex = idx
        reanalyzeProgress = 0.0
        reanalyzeProgressTimer?.invalidate()
        reanalyzeProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { timer in
            if reanalyzeProgress < 0.98 { reanalyzeProgress += 0.006 } else { timer.invalidate() }
        }
        Task {
            let results = await ImageAnalysisService.shared.analyzeMultiple(image: images[idx], imageIndex: idx)
            var items = results.compactMap { cat, prod, colors, pattern, bbox in
                if let cat = cat, let prod = prod, let pattern = pattern, !colors.isEmpty {
                    let cropped = cropImage(images[idx], with: bbox)
                    return AddNewItemView.DetectedItem(category: cat, product: prod, colors: colors, pattern: pattern, boundingBox: bbox, croppedImage: cropped)
                } else { return nil }
            }
            let footwearIndices = items.indices.filter { items[$0].category == .footwear }
            if footwearIndices.count > 1 {
                items = items.enumerated().filter { i, item in
                    item.category != .footwear || i == footwearIndices.first
                }.map { $0.element }
            }
            await MainActor.run {
                detectedItems[idx] = items
                brandInputs[idx] = Array(repeating: "", count: items.count)
                analysisStates[idx] = true
                duplicateAcknowledged[idx] = Array(repeating: false, count: items.count)
                reanalyzingIndex = nil
                reanalyzeProgress = 1.0
            }
        }
    }

    // MARK: - Helpers

    private func isAnalyzed(_ idx: Int) -> Bool {
        analysisStates.indices.contains(idx) && analysisStates[idx]
    }

    private func saveCurrentAndAdvance() {
        guard isAnalyzed(currentIndex) else { return }
        savedStates[currentIndex] = true
        Haptics.success()
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
            if let next = (currentIndex + 1..<savedStates.count).first(where: { savedStates[$0] == nil }) {
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
        let minCropPercent: CGFloat = 0.5
        var rect: CGRect
        if height >= width {
            let cropY = bbox.y * height
            var cropH = bbox.height * height
            if cropH < height * minCropPercent {
                cropH = height * minCropPercent
                let centerY = cropY + (bbox.height * height) / 2
                let newY = max(0, min(centerY - cropH / 2, height - cropH))
                rect = CGRect(x: 0, y: newY, width: width, height: cropH)
            } else {
                rect = CGRect(x: 0, y: cropY, width: width, height: cropH)
            }
            rect.origin.y = max(0, rect.origin.y)
            if rect.maxY > height { rect.size.height = height - rect.origin.y }
        } else {
            let cropX = bbox.x * width
            var cropW = bbox.width * width
            if cropW < width * minCropPercent {
                cropW = width * minCropPercent
                let centerX = cropX + (bbox.width * width) / 2
                let newX = max(0, min(centerX - cropW / 2, width - cropW))
                rect = CGRect(x: newX, y: 0, width: cropW, height: height)
            } else {
                rect = CGRect(x: cropX, y: 0, width: cropW, height: height)
            }
            rect.origin.x = max(0, rect.origin.x)
            if rect.maxX > width { rect.size.width = width - rect.origin.x }
        }
        guard let cgImage = image.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func addAllAndShowSummary() {
        for idx in savedStates.indices where savedStates[idx] == nil && isAnalyzed(idx) && allDuplicatesAcknowledged(for: idx) {
            savedStates[idx] = true
        }
        saveAllAndShowSummary()
    }

    private func allDuplicatesAcknowledged(for imageIdx: Int) -> Bool {
        guard detectedItems.indices.contains(imageIdx), duplicateAcknowledged.indices.contains(imageIdx) else { return true }
        for (idx, detected) in detectedItems[imageIdx].enumerated() {
            if isDuplicateItem(detected, imageIdx: imageIdx, itemIdx: idx) && (!duplicateAcknowledged[imageIdx].indices.contains(idx) || !duplicateAcknowledged[imageIdx][idx]) {
                return false
            }
        }
        return true
    }

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

// MARK: - Internal Item View Wrapper

struct AddNewItemViewInternal: View {
    let image: UIImage
    @Binding var detectedItems: [AddNewItemView.DetectedItem]
    @Binding var brandInputs: [String]
    var hideToolbar: Bool = false
    @Binding var duplicateAcknowledged: [Bool]

    var body: some View {
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
