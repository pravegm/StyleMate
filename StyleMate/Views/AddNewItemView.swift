import SwiftUI
import PhotosUI

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
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isAnalyzing = false
    @State private var expandedCategoryStates: [Category: Bool] = [:]
    @State private var _duplicateAcknowledged: [Bool] = []
    var duplicateAcknowledgedBinding: Binding<[Bool]>? = nil
    var duplicateAcknowledged: Binding<[Bool]> {
        duplicateAcknowledgedBinding ?? $_duplicateAcknowledged
    }
    
    struct DetectedItem: Identifiable {
        let id = UUID()
        var category: Category
        var product: String
        var colors: [String]
        var pattern: Pattern = .solid
        var boundingBox: ImageAnalysisService.BoundingBox? = nil
        var croppedImage: UIImage? = nil
    }
    
    func productOptions(for category: Category) -> [String] {
        productTypesByCategory[category] ?? []
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
            Form {
                Section {
                    if let img = pickedImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .cornerRadius(12)
                    } else {
                        Image(systemName: "photo")
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .foregroundColor(.gray)
                        Text("No image selected.")
                            .foregroundColor(.secondary)
                    }
                }
                
                if !detectedItems.wrappedValue.isEmpty {
                    Section(header:
                        Text("Detected Items")
                            .font(.title2.bold())
                            .foregroundColor(.accentColor)
                            .padding(.vertical, 4)
                    ) {
                        let grouped = Dictionary(grouping: detectedItems.wrappedValue.indices, by: { detectedItems.wrappedValue[$0].category })
                        ForEach(Array(grouped.keys).sorted { $0.rawValue < $1.rawValue }, id: \.self) { category in
                            let indices = grouped[category] ?? []
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    Text(category.rawValue)
                                        .font(.headline)
                                        .foregroundColor(.accentColor)
                                    Spacer()
                                    Button(action: { withAnimation { expandedCategoryStates[category] = !(expandedCategoryStates[category] ?? true) } }) {
                                        Image(systemName: (expandedCategoryStates[category] ?? true) ? "chevron.down" : "chevron.right")
                                            .foregroundColor(.accentColor)
                                            .imageScale(.medium)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .padding(.trailing, 4)
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                if expandedCategoryStates[category] ?? true {
                                    VStack(spacing: 0) {
                                        ForEach(indices, id: \.self) { idx in
                                            VStack(alignment: .leading, spacing: 4) {
                                                DetectedItemCard(
                                                    item: Binding(get: { detectedItems.wrappedValue[idx] }, set: { detectedItems.wrappedValue[idx] = $0 }),
                                                    brand: Binding(get: { brandInputs.wrappedValue[idx] }, set: { brandInputs.wrappedValue[idx] = $0 }),
                                                    onRemove: { removeDetectedItem(at: idx) }
                                                )
                                                if isDuplicateItem(detectedItems.wrappedValue[idx]) {
                                                    HStack(alignment: .center, spacing: 8) {
                                                        Image(systemName: "exclamationmark.triangle.fill")
                                                            .foregroundColor(.orange)
                                                        Text("This might already be in your wardrobe.")
                                                            .font(.footnote)
                                                            .foregroundColor(.orange)
                                                        Spacer()
                                                        if !duplicateAcknowledged.wrappedValue.indices.contains(idx) || !duplicateAcknowledged.wrappedValue[idx] {
                                                            Button("OK") {
                                                                if duplicateAcknowledged.wrappedValue.indices.contains(idx) {
                                                                    duplicateAcknowledged.wrappedValue[idx] = true
                                                                }
                                                            }
                                                            .font(.footnote.bold())
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 2)
                                                            .background(Color.orange.opacity(0.15))
                                                            .cornerRadius(6)
                                                        } else {
                                                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                                        }
                                                    }
                                                    .padding(.vertical, 2)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.bottom, 8)
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(.systemBackground))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16)
                                            .stroke(Color.accentColor.opacity(0.25), lineWidth: 2)
                                    )
                                    .shadow(color: Color.accentColor.opacity(0.18), radius: 12, x: 0, y: 8)
                            )
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .disabled(isAnalyzing)
            if isAnalyzing {
                Color.black.opacity(0.2).ignoresSafeArea()
                ProgressView("Analyzing image...")
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
            }
        }
        .navigationTitle("Add Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { 
                    isPresented = false 
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save Fit") {
                    if !canSave {
                        if !allProductsValid() {
                            errorMessage = "Please select a valid product for each item."
                        } else {
                            errorMessage = "All fields are required."
                        }
                        showError = true
                        return
                    }
                    guard let img = pickedImage else { 
                        return 
                    }
                    for (idx, detected) in detectedItems.wrappedValue.enumerated() {
                        let imagePath = WardrobeImageFileHelper.saveImage(img) ?? ""
                        let croppedImagePath = detected.croppedImage != nil ? WardrobeImageFileHelper.saveImage(detected.croppedImage!) : nil
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
            if let img = newImage {
                pickedImage = img
            }
        }
    }
    
    private func analyzeMultipleImage(_ image: UIImage) {
        isAnalyzing = true
        Task {
            let results = await ImageAnalysisService.shared.analyzeMultiple(image: image)
            var items = results.compactMap { cat, prod, colors, pattern, bbox in
                if let cat = cat, let prod = prod, let pattern = pattern, !colors.isEmpty {
                    let cropped = cropImage(image, with: bbox)
                    return DetectedItem(category: cat, product: prod, colors: colors, pattern: pattern, boundingBox: bbox, croppedImage: cropped)
                } else {
                    return nil
                }
            }
            // Filter duplicate footwear: if 2+ footwear, keep only one
            let footwearIndices = items.indices.filter { items[$0].category == .footwear }
            if footwearIndices.count > 1 {
                // Keep only the first footwear, remove the rest
                items = items.enumerated().filter { idx, item in
                    item.category != .footwear || idx == footwearIndices.first
                }.map { $0.element }
            }
            detectedItems.wrappedValue = items
            brandInputs.wrappedValue = Array(repeating: "", count: detectedItems.wrappedValue.count)
            duplicateAcknowledged.wrappedValue = Array(repeating: false, count: items.count)
            isAnalyzing = false
        }
    }
    
    private func cropImage(_ image: UIImage, with bbox: ImageAnalysisService.BoundingBox?) -> UIImage? {
        guard let bbox = bbox else { return nil }
        let width = image.size.width
        let height = image.size.height
        let rect = CGRect(x: bbox.x * width, y: bbox.y * height, width: bbox.width * width, height: bbox.height * height)
        guard let cgImage = image.cgImage?.cropping(to: rect) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    private func removeDetectedItem(at idx: Int) {
        guard detectedItems.wrappedValue.indices.contains(idx) else { return }
        detectedItems.wrappedValue.remove(at: idx)
        if brandInputs.wrappedValue.indices.contains(idx) {
            brandInputs.wrappedValue.remove(at: idx)
        }
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

// UIKit camera wrapper
struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    @Binding var image: UIImage?
    
    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
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