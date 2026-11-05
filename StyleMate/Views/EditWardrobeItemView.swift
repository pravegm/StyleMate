import SwiftUI
import PhotosUI

/// Edit an item's details, or give it a new photo. A replacement photo is cut out
/// on-device like scanned items (just the garment, transparent PNG) and its
/// visual embedding is refreshed for duplicate detection. Nothing on disk
/// changes until Save: cancelling discards the new photo and keeps the old one.
struct EditWardrobeItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category
    @State private var product: String
    @State private var colors: [String]
    @State private var brand: String
    @State private var pattern: Pattern
    @State private var material: String
    @State private var fit: Fit?
    @State private var neckline: Neckline?
    @State private var sleeveLength: SleeveLength?
    @State private var garmentLength: GarmentLength?
    @State private var details: String
    private let original: WardrobeItem
    var onSave: (WardrobeItem) -> Void

    @State private var replacement: ReplacementCutout? = nil
    @State private var replacementImage: UIImage? = nil
    @State private var showReplacePhotoSource = false
    @State private var showReplaceCamera = false
    @State private var showReplaceGallery = false
    @State private var replaceGallerySelection: [PhotosPickerItem] = []
    @State private var isReplacingPhoto = false
    @State private var replaceFailed = false
    @State private var saved = false

    init(item: WardrobeItem, onSave: @escaping (WardrobeItem) -> Void) {
        _category = State(initialValue: item.category)
        _product = State(initialValue: item.product)
        _colors = State(initialValue: item.colors.map(ClosetColor.normalize).filter { !$0.isEmpty })
        _brand = State(initialValue: item.brand)
        _pattern = State(initialValue: item.pattern)
        _material = State(initialValue: item.material ?? "")
        _fit = State(initialValue: item.fit)
        _neckline = State(initialValue: item.neckline)
        _sleeveLength = State(initialValue: item.sleeveLength)
        _garmentLength = State(initialValue: item.garmentLength)
        _details = State(initialValue: item.details ?? "")
        self.original = item
        self.onSave = onSave
    }

    private var productOptions: [String] { productTypesByCategory[category] ?? [] }

    private var canSave: Bool { !product.isEmpty && !colors.isEmpty && !isReplacingPhoto }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    photoHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Type") {
                    Picker("Category", selection: $category) {
                        ForEach(Category.allCases) { cat in
                            Text(cat.rawValue).tag(cat)
                        }
                    }
                    Picker("Product", selection: $product) {
                        if !productOptions.contains(product) && !product.isEmpty {
                            Text(product).tag(product)
                        }
                        ForEach(productOptions, id: \.self) { prod in
                            Text(prod).tag(prod)
                        }
                    }
                    LabeledContent("Shelf") {
                        Label(ClosetSection.of(category: category, product: product).title,
                              systemImage: ClosetSection.of(category: category, product: product).iconName)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }

                Section {
                    colorPicker
                } header: {
                    Text("Colors")
                } footer: {
                    Text(colors.isEmpty ? "Pick at least one color." : "Main color first: \(colors.joined(separator: ", "))")
                }

                Section("Look") {
                    Picker("Pattern", selection: $pattern) {
                        ForEach(Pattern.allCases) { pat in
                            Text(pat.rawValue).tag(pat)
                        }
                    }
                    TextField("Material (e.g. Cotton, Denim, Wool)", text: $material)
                    TextField("Brand (e.g. Nike)", text: $brand)
                        .textInputAutocapitalization(.words)
                }

                if category.supportsFit || category.supportsNeckline || category.supportsSleeves || category.supportsLength {
                    Section("Cut") {
                        if category.supportsFit {
                            Picker("Fit", selection: Binding(get: { fit ?? .regular }, set: { fit = $0 })) {
                                ForEach(Fit.allCases) { f in Text(f.rawValue).tag(f) }
                            }
                        }
                        if category.supportsNeckline {
                            Picker("Neckline", selection: Binding(get: { neckline ?? .crewNeck }, set: { neckline = $0 })) {
                                ForEach(Neckline.allCases) { n in Text(n.rawValue).tag(n) }
                            }
                        }
                        if category.supportsSleeves {
                            Picker("Sleeve length", selection: Binding(get: { sleeveLength ?? .longSleeve }, set: { sleeveLength = $0 })) {
                                ForEach(SleeveLength.allCases) { s in Text(s.rawValue).tag(s) }
                            }
                        }
                        if category.supportsLength {
                            Picker("Length", selection: Binding(get: { garmentLength ?? .fullLength }, set: { garmentLength = $0 })) {
                                ForEach(GarmentLength.allCases) { l in Text(l.rawValue).tag(l) }
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField("Details (e.g. ribbed cuffs, front zip)", text: $details, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .tint(DS.Colors.accent)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.backgroundPrimary)
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Replace Photo", isPresented: $showReplacePhotoSource) {
                Button("Take Photo") { showReplaceCamera = true }
                Button("Choose from Gallery") { showReplaceGallery = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use a photo of you wearing it, or of the item on its own.")
            }
            .alert("Couldn't use that photo", isPresented: $replaceFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try another photo where the item is clearly visible.")
            }
            .sheet(isPresented: $showReplaceCamera) {
                ImagePicker(image: Binding(
                    get: { nil },
                    set: { newImage in
                        if let img = newImage { processReplacementPhoto(img) }
                    }
                ))
            }
            .photosPicker(isPresented: $showReplaceGallery, selection: $replaceGallerySelection, maxSelectionCount: 1, matching: .images)
            .onChange(of: replaceGallerySelection) { items in
                guard let first = items.first else { return }
                Task {
                    // Decoded straight to ≤ 2048 px, upright, off the main thread (never the full 48 MP bitmap).
                    if let data = try? await first.loadTransferable(type: Data.self),
                       let img = await Task.detached(priority: .userInitiated, operation: { ImageDownsampler.downsample(data: data) }).value {
                        processReplacementPhoto(img)
                    }
                    replaceGallerySelection = []
                }
            }
            .onChange(of: category) { newCategory in
                // Keep the product valid for the new category.
                let options = productTypesByCategory[newCategory] ?? []
                if !options.contains(product), let first = options.first { product = first }
            }
            .onDisappear {
                // Cancelled (or swiped away) after picking a new photo: drop it.
                if !saved { replacement?.discard() }
            }
        }
    }

    // MARK: - Photo

    private var photoHeader: some View {
        VStack(spacing: DS.Spacing.sm) {
            ZStack {
                if let replacementImage {
                    ItemCutoutTile(image: replacementImage, height: 220, cornerRadius: DS.Radius.card, inset: 20)
                } else {
                    AsyncItemTile(path: original.gridImagePath, height: 220, cornerRadius: DS.Radius.card,
                                  inset: 20, upgradePath: original.fullImagePath)
                }
                if isReplacingPhoto {
                    RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                        .fill(.ultraThinMaterial)
                    VStack(spacing: DS.Spacing.xs) {
                        ProgressView()
                        Text("Cutting out the item…")
                            .font(DS.Font.footnote)
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(isReplacingPhoto ? "Processing new photo" : "Item photo")

            Button {
                showReplacePhotoSource = true
            } label: {
                Label(replacement == nil ? "Replace photo" : "Choose a different photo", systemImage: "camera")
                    .font(DS.Font.subheadline.weight(.semibold))
            }
            .disabled(isReplacingPhoto)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: - Colors

    private var colorPicker: some View {
        ColorSwatchPicker(colors: $colors)
    }

    // MARK: - Save / replace

    private func save() {
        Haptics.medium()
        var imagePath = original.imagePath
        var croppedImagePath = original.croppedImagePath
        var thumbnailPath = original.thumbnailPath
        if let replacement {
            imagePath = replacement.imagePath
            croppedImagePath = replacement.imagePath
            thumbnailPath = replacement.thumbnailPath
            ClosetImageLoader.shared.evict([original.imagePath, original.croppedImagePath, original.thumbnailPath])
            WardrobeImageFileHelper.deleteImage(at: original.imagePath)
            if original.croppedImagePath != original.imagePath {
                WardrobeImageFileHelper.deleteImage(at: original.croppedImagePath)
            }
            WardrobeImageFileHelper.deleteImage(at: original.thumbnailPath)
            if let fp = replacement.featurePrint {
                ItemEmbeddingStore.shared.set(fp, quality: replacement.quality, for: original.id)
            } else {
                ItemEmbeddingStore.shared.remove(original.id)
            }
        }
        let updated = WardrobeItem(
            id: original.id,
            category: category,
            product: product,
            colors: colors,
            brand: brand.trimmingCharacters(in: .whitespaces),
            pattern: pattern,
            imagePath: imagePath,
            croppedImagePath: croppedImagePath,
            thumbnailPath: thumbnailPath,
            material: material.trimmingCharacters(in: .whitespaces).isEmpty ? nil : material,
            fit: category.supportsFit ? fit : nil,
            neckline: category.supportsNeckline ? neckline : nil,
            sleeveLength: category.supportsSleeves ? sleeveLength : nil,
            garmentLength: category.supportsLength ? garmentLength : nil,
            details: details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : details
        )
        saved = true
        onSave(updated)
        dismiss()
    }

    private func processReplacementPhoto(_ photo: UIImage) {
        isReplacingPhoto = true
        let category = self.category, product = self.product
        Task {
            let result = await ReplacementCutout.make(from: photo, category: category, product: product)
            let preview = await ClosetImageLoader.shared.load(result?.imagePath)
            await MainActor.run {
                if let result {
                    replacement?.discard()      // a previous unsaved pick
                    replacement = result
                    replacementImage = preview
                    Haptics.success()
                } else {
                    replaceFailed = true
                }
                isReplacingPhoto = false
            }
        }
    }
}
