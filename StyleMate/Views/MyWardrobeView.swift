import SwiftUI
import PhotosUI

struct MyWardrobeView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @Binding var showAddSheet: Bool
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DS.Spacing.sm)]
    @State private var selectedCategory: Category?
    @State private var editingItem: WardrobeItem? = nil
    @State private var showEditSheet = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                DS.Colors.backgroundPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: DS.Spacing.md) {
                        if wardrobeViewModel.items.isEmpty {
                            VStack(spacing: DS.Spacing.md) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 44))
                                    .foregroundColor(DS.Colors.accent)
                                Text("Start building your wardrobe")
                                    .font(DS.Font.title3)
                                    .foregroundColor(DS.Colors.textPrimary)
                                Text("Take a photo or pick from your gallery to add your first items")
                                    .font(DS.Font.subheadline)
                                    .foregroundColor(DS.Colors.textSecondary)
                                    .multilineTextAlignment(.center)
                                Button(action: { Haptics.medium(); showAddSheet = true }) {
                                    HStack(spacing: DS.Spacing.xs) {
                                        Image(systemName: "plus")
                                        Text("Add Items")
                                    }
                                }
                                .buttonStyle(DSPrimaryButton())
                                .padding(.horizontal, DS.Spacing.xl)
                            }
                            .padding(DS.Spacing.xl)
                            .frame(maxWidth: .infinity)
                        }

                        LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                            ForEach(Category.allCases) { category in
                                let count = wardrobeViewModel.items.filter { $0.category == category }.count
                                Button { selectedCategory = category } label: {
                                    CategoryTile(category: category, count: count)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.top, DS.Spacing.md)
                    .padding(.bottom, 100)
                }

                // Floating Add Button
                Button {
                    Haptics.medium()
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(DS.Colors.accent)
                        .clipShape(Circle())
                        .shadow(color: DS.Colors.accent.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .padding(.trailing, DS.Spacing.screenH)
                .padding(.bottom, DS.Spacing.lg)
            }
            .navigationTitle("Wardrobe")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Text("\(wardrobeViewModel.items.count) items")
                        .font(DS.Font.subheadline)
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }
            .sheet(isPresented: Binding(
                get: { showEditSheet && editingItem != nil },
                set: { newValue in
                    if !newValue { showEditSheet = false; editingItem = nil }
                }
            )) {
                if let editingItem = editingItem {
                    EditWardrobeItemView(item: editingItem) { updatedItem in
                        if let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == updatedItem.id }) {
                            wardrobeViewModel.items[idx] = updatedItem
                            wardrobeViewModel.syncItemToCloud(updatedItem)
                        }
                        self.showEditSheet = false
                        self.editingItem = nil
                    }
                }
            }
            .navigationDestination(item: $selectedCategory) { category in
                CategoryDetailView(category: category)
                    .environmentObject(wardrobeViewModel)
            }
        }
    }
}

// MARK: - Category Icon Mapping

extension Category {
    var iconName: String {
        switch self {
        case .tops:       return "tshirt"
        case .bottoms:    return "figure.stand"
        case .midLayers:  return "wind"
        case .outerwear:  return "cloud.rain"
        case .onePieces:  return "figure.dance"
        case .footwear:   return "shoeprints.fill"
        case .accessories: return "suitcase"
        case .innerwear:  return "bed.double"
        case .activewear: return "figure.run"
        case .ethnicWear: return "sparkles"
        }
    }
}

// MARK: - Category Tile

struct CategoryTile: View {
    let category: Category
    let count: Int

    var body: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: category.iconName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(DS.Colors.accent)

            Text(category.rawValue)
                .font(DS.Font.headline)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(DS.Font.subheadline)
                .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.md)
        .background(count > 0 ? DS.Colors.accent.opacity(0.04) : DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
    }
}

// MARK: - Preview Image Wrapper

struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - Category Detail View (Photo Grid)

struct CategoryDetailView: View {
    let category: Category
    var initialProduct: String? = nil
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel

    var items: [WardrobeItem] {
        wardrobeViewModel.items.filter { $0.category == category }
    }

    @State private var previewImage: PreviewImage? = nil
    @State private var editingItem: WardrobeItem? = nil
    @State private var replacePhotoItem: WardrobeItem? = nil
    @State private var showPhotoSourcePicker = false
    @State private var showReplaceCamera = false
    @State private var showReplaceGallery = false
    @State private var replaceGallerySelection: [PhotosPickerItem] = []
    @State private var isReplacingPhoto = false

    private func normalizedProduct(_ product: String) -> String {
        let lower = product.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasSuffix("s") && lower.count > 1 { return String(lower.dropLast()) }
        return lower
    }

    var groupedItems: [(product: String, items: [WardrobeItem])] {
        let groups = Dictionary(grouping: items, by: { normalizedProduct($0.product) })
        return groups.map { (normKey, items) in
            let display = items.map { $0.product }
                .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                .max(by: { $0.value < $1.value })?.key ?? items.first?.product ?? normKey.capitalized
            return (product: display, items: items)
        }
        .sorted { $0.product.localizedCaseInsensitiveCompare($1.product) == .orderedAscending }
    }

    private let photoColumns = [GridItem(.adaptive(minimum: 150), spacing: DS.Spacing.sm)]

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: category.iconName)
                        .font(.system(size: 48))
                        .foregroundColor(DS.Colors.textTertiary)

                    Text("No \(category.rawValue) yet")
                        .font(DS.Font.title3)
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Add your first \(category.rawValue.lowercased()) item to get started.")
                        .font(DS.Font.body)
                        .foregroundColor(DS.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, DS.Spacing.xxxl)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                        ForEach(groupedItems, id: \.product) { group in
                            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                                HStack {
                                    Text(group.product)
                                        .font(DS.Font.headline)
                                        .foregroundColor(DS.Colors.textPrimary)

                                    Text("\(group.items.count)")
                                        .font(DS.Font.caption1)
                                        .foregroundColor(DS.Colors.textSecondary)
                                        .padding(.horizontal, DS.Spacing.xs)
                                        .padding(.vertical, DS.Spacing.micro)
                                        .background(DS.Colors.backgroundSecondary)
                                        .clipShape(Capsule())
                                }

                                LazyVGrid(columns: photoColumns, spacing: DS.Spacing.sm) {
                                    ForEach(group.items) { item in
                                        Button {
                                            if let img = item.croppedImage ?? item.image {
                                                previewImage = PreviewImage(image: img)
                                            }
                                        } label: {
                                            VStack(spacing: DS.Spacing.xs) {
                                                if let img = item.croppedImage ?? item.image {
                                                    Image(uiImage: img)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(height: 140)
                                                        .clipped()
                                                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
                                                } else {
                                                    RoundedRectangle(cornerRadius: DS.Radius.button)
                                                        .fill(DS.Colors.backgroundSecondary)
                                                        .frame(height: 140)
                                                        .overlay(
                                                            Image(systemName: "photo")
                                                                .foregroundColor(DS.Colors.textTertiary)
                                                        )
                                                }

                                                Text(item.name)
                                                    .font(DS.Font.caption1)
                                                    .foregroundColor(DS.Colors.textSecondary)
                                                    .lineLimit(2)
                                                    .multilineTextAlignment(.center)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button { editingItem = item } label: {
                                                Label("Edit", systemImage: "pencil")
                                            }
                                            Button { replacePhotoItem = item } label: {
                                                Label("Replace Photo", systemImage: "camera")
                                            }
                                            Button(role: .destructive) {
                                                if let idx = wardrobeViewModel.items.firstIndex(of: item) {
                                                    wardrobeViewModel.deleteItemFromCloud(item)
                                                    WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                                                    WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                                                    wardrobeViewModel.items.remove(at: idx)
                                                }
                                            } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.top, DS.Spacing.md)
                    .padding(.bottom, DS.Spacing.xxxl)
                }
            }
        }
        .background(DS.Colors.backgroundPrimary)
        .navigationTitle(category.rawValue)
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image)
                    .padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .buttonStyle(DSSecondaryButton())
                    .padding(.horizontal, DS.Spacing.screenH)
                    .padding(.bottom, DS.Spacing.lg)
            }
        }
        .sheet(item: $editingItem) { item in
            EditWardrobeItemView(item: item) { updatedItem in
                if let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == updatedItem.id }) {
                    wardrobeViewModel.items[idx] = updatedItem
                    wardrobeViewModel.syncItemToCloud(updatedItem)
                }
                editingItem = nil
            }
        }
        .confirmationDialog("Replace Photo", isPresented: $showPhotoSourcePicker, presenting: replacePhotoItem) { item in
            Button("Take Photo") { showReplaceCamera = true }
            Button("Choose from Gallery") { showReplaceGallery = true }
            Button("Cancel", role: .cancel) { replacePhotoItem = nil }
        } message: { item in
            Text("Choose a new photo for this \(item.product)")
        }
        .onChange(of: replacePhotoItem) { item in
            if item != nil { showPhotoSourcePicker = true }
        }
        .sheet(isPresented: $showReplaceCamera) {
            ImagePicker(image: Binding(
                get: { nil },
                set: { newImage in
                    if let img = newImage, let item = replacePhotoItem {
                        replacePhoto(for: item, with: img)
                    }
                }
            ))
        }
        .photosPicker(isPresented: $showReplaceGallery, selection: $replaceGallerySelection, maxSelectionCount: 1, matching: .images)
        .onChange(of: replaceGallerySelection) { items in
            guard let first = items.first else { return }
            Task {
                if let data = try? await first.loadTransferable(type: Data.self),
                   let img = UIImage(data: data),
                   let item = replacePhotoItem {
                    replacePhoto(for: item, with: img)
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

    private func replacePhoto(for item: WardrobeItem, with newImage: UIImage) {
        isReplacingPhoto = true
        Task {
            let bgRemoved = await BackgroundRemovalService.shared.removeBackground(from: newImage) ?? newImage

            guard let newImagePath = WardrobeImageFileHelper.saveImage(bgRemoved) else {
                await MainActor.run { isReplacingPhoto = false }
                return
            }
            let zoneCrop = BodyZone.cropToZone(image: bgRemoved, category: item.category)
            let newCroppedPath = zoneCrop != nil ? WardrobeImageFileHelper.saveImage(zoneCrop!) : nil

            WardrobeImageFileHelper.deleteImage(at: item.imagePath)
            WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)

            let updatedItem = WardrobeItem(
                id: item.id,
                category: item.category,
                product: item.product,
                colors: item.colors,
                brand: item.brand,
                pattern: item.pattern,
                imagePath: newImagePath,
                croppedImagePath: newCroppedPath ?? item.croppedImagePath
            )

            await MainActor.run {
                if let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == item.id }) {
                    wardrobeViewModel.items[idx] = updatedItem
                    wardrobeViewModel.syncItemToCloud(updatedItem)
                }
                replacePhotoItem = nil
                isReplacingPhoto = false
                Haptics.success()
            }
        }
    }
}

// MARK: - Zoomable Image

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let frameSize = geometry.size
            let imageAspect = image.size.width / image.size.height
            let frameAspect = frameSize.width / frameSize.height
            let (displayWidth, displayHeight): (CGFloat, CGFloat) = {
                if imageAspect > frameAspect {
                    return (frameSize.width, frameSize.width / imageAspect)
                } else {
                    return (frameSize.height * imageAspect, frameSize.height)
                }
            }()
            let maxOffsetX = max(0, (displayWidth * scale - frameSize.width) / 2)
            let maxOffsetY = max(0, (displayHeight * scale - frameSize.height) / 2)
            let clampedOffset = CGSize(
                width: min(max(offset.width, -maxOffsetX), maxOffsetX),
                height: min(max(offset.height, -maxOffsetY), maxOffsetY)
            )

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: frameSize.width, height: frameSize.height)
                .scaleEffect(scale)
                .offset(scale > 1 ? clampedOffset : .zero)
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let newScale = lastScale * value
                                scale = max(1.0, min(newScale, 5.0))
                                if scale == 1.0 { offset = .zero; lastOffset = .zero }
                            }
                            .onEnded { value in
                                lastScale = max(1.0, min(lastScale * value, 5.0))
                                if scale == 1.0 { offset = .zero; lastOffset = .zero }
                            },
                        DragGesture()
                            .onChanged { value in
                                guard scale > 1 else { return }
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                guard scale > 1 else { offset = .zero; lastOffset = .zero; return }
                                let clamped = CGSize(
                                    width: min(max(offset.width, -maxOffsetX), maxOffsetX),
                                    height: min(max(offset.height, -maxOffsetY), maxOffsetY)
                                )
                                offset = clamped
                                lastOffset = clamped
                            }
                    )
                )
                .animation(.easeInOut(duration: 0.2), value: scale)
        }
        .clipped()
    }
}

#Preview {
    MyWardrobeView(showAddSheet: .constant(false))
        .environmentObject(WardrobeViewModel())
}
