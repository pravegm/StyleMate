import SwiftUI
import PhotosUI

struct EditWardrobeItemView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var category: Category
    @State private var product: String
    @State private var colors: [String]
    @State private var brand: String
    @State private var pattern: Pattern
    @State private var imagePath: String
    @State private var croppedImagePath: String?
    let id: UUID
    var onSave: (WardrobeItem) -> Void
    @State private var showReplacePhotoSource = false
    @State private var showReplaceCamera = false
    @State private var showReplaceGallery = false
    @State private var replaceGallerySelection: [PhotosPickerItem] = []
    @State private var isReplacingPhoto = false

    init(item: WardrobeItem, onSave: @escaping (WardrobeItem) -> Void) {
        _category = State(initialValue: item.category)
        _product = State(initialValue: item.product)
        _colors = State(initialValue: item.colors)
        _brand = State(initialValue: item.brand)
        _pattern = State(initialValue: item.pattern)
        _imagePath = State(initialValue: item.imagePath)
        _croppedImagePath = State(initialValue: item.croppedImagePath)
        self.id = item.id
        self.onSave = onSave
    }

    var productOptions: [String] {
        productTypesByCategory[category] ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        if let img = WardrobeImageFileHelper.loadImage(at: croppedImagePath ?? imagePath) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)

                    Button {
                        showReplacePhotoSource = true
                    } label: {
                        Label("Replace Photo", systemImage: "camera")
                            .foregroundColor(DS.Colors.accent)
                    }
                }

                Picker("Category", selection: $category) {
                    ForEach(Category.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .tint(DS.Colors.accent)

                Picker("Product", selection: $product) {
                    ForEach(productOptions, id: \.self) { prod in
                        Text(prod).tag(prod)
                    }
                }
                .tint(DS.Colors.accent)

                Section(header: Text("Colors")) {
                    ForEach(colors.indices, id: \.self) { idx in
                        HStack(spacing: DS.Spacing.xs) {
                            colorSwatch(for: colors[idx])

                            TextField("Color", text: Binding(
                                get: { colors[idx] },
                                set: { colors[idx] = $0 }
                            ))

                            if colors.count > 1 {
                                Button(action: { colors.remove(at: idx) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(DS.Colors.error)
                                }
                            }
                        }
                    }
                    Button(action: { colors.append("") }) {
                        Label("Add Color", systemImage: "plus.circle.fill")
                            .foregroundColor(DS.Colors.success)
                    }
                }

                Picker("Pattern", selection: $pattern) {
                    ForEach(Pattern.allCases) { pat in
                        Text(pat.rawValue).tag(pat)
                    }
                }
                .tint(DS.Colors.accent)

                TextField("Brand (e.g. Nike)", text: $brand)
            }
            .tint(DS.Colors.accent)
            .navigationTitle("Edit Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Haptics.medium()
                        let updatedItem = WardrobeItem(
                            id: id,
                            category: category,
                            product: product,
                            colors: colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                            brand: brand,
                            pattern: pattern,
                            imagePath: imagePath,
                            croppedImagePath: croppedImagePath
                        )
                        onSave(updatedItem)
                        dismiss()
                    }
                    .disabled(product.isEmpty || colors.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
            .confirmationDialog("Replace Photo", isPresented: $showReplacePhotoSource) {
                Button("Take Photo") { showReplaceCamera = true }
                Button("Choose from Gallery") { showReplaceGallery = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Choose a new photo for this item")
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
                    if let data = try? await first.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        processReplacementPhoto(img)
                    }
                    replaceGallerySelection = []
                }
            }
            .overlay {
                if isReplacingPhoto {
                    OutfitLoadingOverlay(progress: 0.5, message: "Processing photo…")
                }
            }
        }
    }

    private func processReplacementPhoto(_ newImage: UIImage) {
        isReplacingPhoto = true
        Task {
            let bgRemoved = await BackgroundRemovalService.shared.removeBackground(from: newImage) ?? newImage

            guard let newImagePath = WardrobeImageFileHelper.saveImage(bgRemoved) else {
                await MainActor.run { isReplacingPhoto = false }
                return
            }
            let zoneCrop = BodyZone.cropToZone(image: bgRemoved, category: category)
            let newCroppedPath = zoneCrop != nil ? WardrobeImageFileHelper.saveImage(zoneCrop!) : nil

            let oldImagePath = self.imagePath
            let oldCroppedPath = self.croppedImagePath

            await MainActor.run {
                WardrobeImageFileHelper.deleteImage(at: oldImagePath)
                WardrobeImageFileHelper.deleteImage(at: oldCroppedPath)
                self.imagePath = newImagePath
                self.croppedImagePath = newCroppedPath
                isReplacingPhoto = false
                Haptics.success()
            }
        }
    }

    @ViewBuilder
    private func colorSwatch(for colorName: String) -> some View {
        let name = colorName.lowercased().trimmingCharacters(in: .whitespaces)
        let color: Color = {
            switch name {
            case "black": return .black
            case "white": return .white
            case "red": return .red
            case "blue": return .blue
            case "green": return .green
            case "yellow": return .yellow
            case "orange": return .orange
            case "pink": return .pink
            case "purple": return .purple
            case "brown": return .brown
            case "gray", "grey": return .gray
            case "navy": return Color(red: 0, green: 0, blue: 0.5)
            case "beige": return Color(red: 0.96, green: 0.96, blue: 0.86)
            case "cream": return Color(red: 1, green: 0.99, blue: 0.82)
            case "teal": return .teal
            default: return DS.Colors.backgroundSecondary
            }
        }()

        Circle()
            .fill(color)
            .frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 1))
    }
}
