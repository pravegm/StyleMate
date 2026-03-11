import SwiftUI

struct AddNewItemView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @Binding var showPhotoPicker: Bool
    @Binding var showCamera: Bool
    @Binding var isPresented: Bool
    var prefilledImage: UIImage? = nil
    var detectedItemsBinding: Binding<[DetectedItem]>?
    var brandInputsBinding: Binding<[String]>?
    @State private var pickedImage: UIImage?
    @State private var detectedItemsState: [DetectedItem] = []
    @State private var brandInputsState: [String] = []
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isAnalyzing = false
    @State private var _duplicateAcknowledged: [Bool] = []
    var duplicateAcknowledgedBinding: Binding<[Bool]>? = nil
    var duplicateAcknowledged: Binding<[Bool]> {
        duplicateAcknowledgedBinding ?? $_duplicateAcknowledged
    }
    @State private var progress: Double = 0.0
    @State private var progressTimer: Timer? = nil
    @State private var bgRemovedImage: UIImage? = nil

    struct DetectedItem: Identifiable {
        let id = UUID()
        var category: Category
        var product: String
        var colors: [String]
        var pattern: Pattern = .solid
    }

    var detectedItems: Binding<[DetectedItem]> {
        detectedItemsBinding ?? $detectedItemsState
    }
    var brandInputs: Binding<[String]> {
        brandInputsBinding ?? $brandInputsState
    }

    var canSave: Bool {
        !detectedItems.wrappedValue.isEmpty && detectedItems.wrappedValue.indices.allSatisfy { idx in
            !detectedItems.wrappedValue[idx].colors.isEmpty &&
            !detectedItems.wrappedValue[idx].colors[0].trimmingCharacters(in: .whitespaces).isEmpty &&
            !detectedItems.wrappedValue[idx].product.isEmpty &&
            (productTypesByCategory[detectedItems.wrappedValue[idx].category]?.contains(detectedItems.wrappedValue[idx].product) ?? false)
        } && pickedImage != nil
    }

    init(
        showPhotoPicker: Binding<Bool>,
        showCamera: Binding<Bool>,
        isPresented: Binding<Bool>,
        prefilledImage: UIImage? = nil,
        detectedItemsBinding: Binding<[DetectedItem]>? = nil,
        brandInputsBinding: Binding<[String]>? = nil,
        duplicateAcknowledgedBinding: Binding<[Bool]>? = nil
    ) {
        _showPhotoPicker = showPhotoPicker
        _showCamera = showCamera
        _isPresented = isPresented
        self.prefilledImage = prefilledImage
        self.detectedItemsBinding = detectedItemsBinding
        self.brandInputsBinding = brandInputsBinding
        self.duplicateAcknowledgedBinding = duplicateAcknowledgedBinding
        _pickedImage = State(initialValue: prefilledImage)
    }

    var body: some View {
        ZStack {
            DS.Colors.backgroundPrimary.ignoresSafeArea()

            ScrollView {
                VStack(spacing: DS.Spacing.lg) {
                    // Image preview
                    if let img = pickedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    } else {
                        RoundedRectangle(cornerRadius: DS.Radius.card)
                            .fill(DS.Colors.backgroundSecondary)
                            .frame(height: 200)
                            .overlay(
                                VStack(spacing: DS.Spacing.xs) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 40))
                                        .foregroundColor(DS.Colors.textTertiary)
                                    Text("No image selected")
                                        .font(DS.Font.subheadline)
                                        .foregroundColor(DS.Colors.textSecondary)
                                }
                            )
                    }

                    // Detected items
                    if !detectedItems.wrappedValue.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text("Detected Items")
                                .font(DS.Font.title3)
                                .foregroundColor(DS.Colors.textPrimary)

                            ForEach(detectedItems.wrappedValue.indices, id: \.self) { idx in
                                VStack(spacing: DS.Spacing.xs) {
                                    DetectedItemCard(
                                        item: Binding(
                                            get: { detectedItems.wrappedValue[idx] },
                                            set: { detectedItems.wrappedValue[idx] = $0 }
                                        ),
                                        brand: Binding(
                                            get: { brandInputs.wrappedValue[idx] },
                                            set: { brandInputs.wrappedValue[idx] = $0 }
                                        ),
                                        onRemove: { removeDetectedItem(at: idx) }
                                    )

                                    if isDuplicateItem(detectedItems.wrappedValue[idx]) {
                                        HStack(spacing: DS.Spacing.xs) {
                                            Circle()
                                                .fill(DS.Colors.warning)
                                                .frame(width: 8, height: 8)

                                            Text("Possible duplicate")
                                                .font(DS.Font.caption1)
                                                .foregroundColor(DS.Colors.warning)

                                            Spacer()

                                            if !duplicateAcknowledged.wrappedValue.indices.contains(idx) || !duplicateAcknowledged.wrappedValue[idx] {
                                                Button("Dismiss") {
                                                    if duplicateAcknowledged.wrappedValue.indices.contains(idx) {
                                                        duplicateAcknowledged.wrappedValue[idx] = true
                                                    }
                                                }
                                                .font(DS.Font.caption1)
                                                .foregroundColor(DS.Colors.accent)
                                            } else {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundColor(DS.Colors.success)
                                                    .font(DS.Font.caption1)
                                            }
                                        }
                                        .padding(.horizontal, DS.Spacing.md)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.screenH)
                .padding(.vertical, DS.Spacing.md)
            }
            .disabled(isAnalyzing)

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
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
        )
        .navigationTitle("Add Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isPresented = false }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Items") {
                    if !canSave {
                        errorMessage = !allProductsValid()
                            ? "Please select a valid product for each item."
                            : "All fields are required."
                        showError = true
                        return
                    }
                    guard let img = pickedImage else { return }
                    Haptics.success()
                    for (idx, detected) in detectedItems.wrappedValue.enumerated() {
                        let fullImage = bgRemovedImage ?? img
                        let imagePath = WardrobeImageFileHelper.saveImage(fullImage) ?? ""
                        let zoneCrop = BodyZone.cropToZone(image: fullImage, category: detected.category)
                        let croppedImagePath = zoneCrop != nil ? WardrobeImageFileHelper.saveImage(zoneCrop!) : nil
                        let item = WardrobeItem(
                            category: detected.category,
                            product: detected.product,
                            colors: detected.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                            brand: brandInputs.wrappedValue[idx],
                            pattern: detected.pattern,
                            imagePath: imagePath,
                            croppedImagePath: croppedImagePath
                        )
                        wardrobeViewModel.items.append(item)
                        wardrobeViewModel.syncItemToCloud(item)
                    }
                    isPresented = false
                }
                .disabled(!canSave || !allDuplicatesAcknowledged())
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onChange(of: pickedImage) { newImage in
            if let img = newImage, detectedItems.wrappedValue.isEmpty {
                analyzeMultipleImage(img)
            }
        }
        .onChange(of: prefilledImage) { newImage in
            if let img = newImage { pickedImage = img }
        }
    }

    private func analyzeMultipleImage(_ image: UIImage) {
        isAnalyzing = true
        Task {
            let bgRemoved = await BackgroundRemovalService.shared.removeBackground(from: image)
            self.bgRemovedImage = bgRemoved

            let results = await ImageAnalysisService.shared.analyzeMultiple(image: image)
            var items = results.compactMap { cat, prod, colors, pattern in
                if let cat = cat, let prod = prod, let pattern = pattern, !colors.isEmpty {
                    return DetectedItem(category: cat, product: prod, colors: colors, pattern: pattern)
                } else {
                    return nil
                }
            }
            let footwearIndices = items.indices.filter { items[$0].category == .footwear }
            if footwearIndices.count > 1 {
                items = items.enumerated().filter { idx, item in
                    item.category != .footwear || idx == footwearIndices.first
                }.map { $0.element }
            }
            detectedItems.wrappedValue = items
            brandInputs.wrappedValue = Array(repeating: "", count: detectedItems.wrappedValue.count)
            duplicateAcknowledged.wrappedValue = Array(repeating: false, count: items.count)
            isAnalyzing = false
            progress = 1.0
        }
    }

    private func removeDetectedItem(at idx: Int) {
        guard detectedItems.wrappedValue.indices.contains(idx) else { return }
        detectedItems.wrappedValue.remove(at: idx)
        if brandInputs.wrappedValue.indices.contains(idx) { brandInputs.wrappedValue.remove(at: idx) }
        if duplicateAcknowledged.wrappedValue.indices.contains(idx) { duplicateAcknowledged.wrappedValue.remove(at: idx) }
    }

    private func allProductsValid() -> Bool {
        detectedItems.wrappedValue.allSatisfy { item in
            productTypesByCategory[item.category]?.contains(item.product) ?? false
        }
    }

    private func isDuplicateItem(_ item: DetectedItem) -> Bool {
        let idx = detectedItems.wrappedValue.firstIndex(where: { $0.id == item.id }) ?? 0
        let brand = brandInputs.wrappedValue.indices.contains(idx) ? brandInputs.wrappedValue[idx] : ""
        return wardrobeViewModel.items.contains { wardrobeItem in
            wardrobeItem.category == item.category &&
            wardrobeItem.product.caseInsensitiveCompare(item.product) == .orderedSame &&
            wardrobeItem.pattern == item.pattern &&
            wardrobeItem.brand.caseInsensitiveCompare(brand) == .orderedSame &&
            Set(wardrobeItem.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }) == Set(item.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
        }
    }

    private func allDuplicatesAcknowledged() -> Bool {
        for (idx, detected) in detectedItems.wrappedValue.enumerated() {
            if isDuplicateItem(detected) && (!duplicateAcknowledged.wrappedValue.indices.contains(idx) || !duplicateAcknowledged.wrappedValue[idx]) {
                return false
            }
        }
        return true
    }
}

// MARK: - UIKit Camera Wrapper

struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    @Binding var image: UIImage?

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let uiImage = info[.originalImage] as? UIImage { parent.image = uiImage }
            parent.presentationMode.wrappedValue.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.presentationMode.wrappedValue.dismiss()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
}

#Preview {
    NavigationStack {
        AddNewItemView(
            showPhotoPicker: .constant(false),
            showCamera: .constant(false),
            isPresented: .constant(true)
        )
        .environmentObject(WardrobeViewModel())
    }
}
