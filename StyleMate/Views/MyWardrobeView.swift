import SwiftUI
import PhotosUI

struct MyWardrobeView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @Binding var showAddSheet: Bool
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DS.Spacing.sm)]
    @State private var selectedCategory: Category?
    @State private var editingItem: WardrobeItem? = nil
    @State private var showEditSheet = false
    @State private var activeFilter: WardrobeFilter = .all

    private enum WardrobeFilter: Hashable {
        case all
        case hasItems
        case category(Category)
    }

    private var sortedCategories: [Category] {
        Category.allCases.sorted { cat1, cat2 in
            let count1 = wardrobeViewModel.items.filter { $0.category == cat1 }.count
            let count2 = wardrobeViewModel.items.filter { $0.category == cat2 }.count
            if count1 == 0 && count2 > 0 { return false }
            if count1 > 0 && count2 == 0 { return true }
            return count1 > count2
        }
    }

    private var filteredCategories: [Category] {
        switch activeFilter {
        case .all:
            return sortedCategories
        case .hasItems:
            return sortedCategories.filter { cat in
                wardrobeViewModel.items.contains { $0.category == cat }
            }
        case .category(let cat):
            return [cat]
        }
    }

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

                        filterChips
                            .padding(.horizontal, DS.Spacing.screenH)

                        LazyVGrid(columns: columns, spacing: DS.Spacing.sm) {
                            ForEach(filteredCategories) { category in
                                let categoryItems = wardrobeViewModel.items.filter { $0.category == category }
                                Button {
                                    selectedCategory = category
                                } label: {
                                    CategoryTile(category: category, count: categoryItems.count, items: categoryItems)
                                }
                                .buttonStyle(DSTapBounce())
                            }
                        }
                        .padding(.horizontal, DS.Spacing.screenH)
                    }
                    .padding(.top, DS.Spacing.md)
                    .padding(.bottom, 100)
                }

                Button {
                    Haptics.medium()
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 58, height: 58)
                        .background(
                            LinearGradient(
                                colors: [DS.Colors.accent, DS.Colors.accent.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(Circle())
                        .shadow(color: DS.Colors.accent.opacity(0.35), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(DSTapBounce())
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

    // MARK: - Filter Chips

    @ViewBuilder
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                filterChip("All", isSelected: activeFilter == .all) {
                    activeFilter = .all
                }

                let hasPopulated = wardrobeViewModel.items.count > 0
                if hasPopulated {
                    filterChip("Has Items", isSelected: activeFilter == .hasItems) {
                        activeFilter = .hasItems
                    }
                }

                ForEach(sortedCategories.filter { cat in
                    wardrobeViewModel.items.contains { $0.category == cat }
                }) { category in
                    filterChip(category.rawValue, icon: category.iconName, isSelected: {
                        if case .category(let c) = activeFilter { return c == category }
                        return false
                    }()) {
                        selectedCategory = category
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.micro)
        }
    }

    private func filterChip(_ label: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.light()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() }
        }) {
            HStack(spacing: DS.Spacing.micro) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(DS.Font.caption2)
                }
                Text(label)
                    .font(DS.Font.subheadline)
            }
            .foregroundColor(isSelected ? DS.Colors.accent : DS.Colors.textPrimary)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
        }
        .buttonStyle(.plain)
        .background(
            isSelected
                ? DS.Colors.accent.opacity(0.15)
                : DS.Colors.backgroundSecondary,
            in: Capsule()
        )
        .overlay(
            isSelected
                ? Capsule().stroke(DS.Colors.accent, lineWidth: 1)
                : nil
        )
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
    let items: [WardrobeItem]

    private var thumbnails: [UIImage] {
        items.shuffled().compactMap { $0.thumbnailImage ?? $0.croppedImage ?? $0.image }.prefix(4).map { $0 }
    }

    var body: some View {
        VStack(spacing: DS.Spacing.xs) {
            let thumbs = thumbnails
            if thumbs.isEmpty {
                Image(systemName: category.iconName)
                    .font(.system(size: 28))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .background(DS.Colors.backgroundSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            } else if thumbs.count < 4 {
                Image(uiImage: thumbs[0])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            } else {
                let gridSize: CGFloat = 120
                let halfSize = (gridSize - 2) / 2
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        thumbnailCell(thumbs[0], size: halfSize)
                        thumbnailCell(thumbs[1], size: halfSize)
                    }
                    HStack(spacing: 2) {
                        thumbnailCell(thumbs[2], size: halfSize)
                        thumbnailCell(thumbs[3], size: halfSize)
                    }
                }
                .frame(height: gridSize)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.button))
            }

            HStack {
                Text(category.rawValue)
                    .font(DS.Font.subheadline)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(DS.Colors.backgroundSecondary)
                    .clipShape(Capsule())
            }
        }
        .padding(DS.Spacing.xs)
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
        .opacity(count > 0 ? 1.0 : 0.5)
    }

    @ViewBuilder
    private func thumbnailCell(_ image: UIImage, size: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
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
    @State private var selectedDetailItem: WardrobeItem? = nil

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
                                HStack(alignment: .firstTextBaseline) {
                                    Text(group.product)
                                        .font(DS.Font.title3)
                                        .foregroundColor(DS.Colors.textPrimary)

                                    Text("\(group.items.count)")
                                        .font(DS.Font.caption2)
                                        .foregroundColor(DS.Colors.accent)
                                        .padding(.horizontal, DS.Spacing.xs)
                                        .padding(.vertical, 2)
                                        .background(DS.Colors.accent.opacity(0.12))
                                        .clipShape(Capsule())
                                }

                                LazyVGrid(columns: photoColumns, spacing: DS.Spacing.sm) {
                                    ForEach(group.items) { item in
                                        Button {
                                            selectedDetailItem = item
                                        } label: {
                                            itemCardView(item)
                                        }
                                        .buttonStyle(DSTapBounce())
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
        .sheet(item: $selectedDetailItem) { item in
            ItemDetailSheet(
                item: item,
                onEdit: { editingItem = item; selectedDetailItem = nil },
                onReplacePhoto: { replacePhotoItem = item; selectedDetailItem = nil },
                onDelete: {
                    if let idx = wardrobeViewModel.items.firstIndex(of: item) {
                        wardrobeViewModel.deleteItemFromCloud(item)
                        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                        WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                        WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
                        wardrobeViewModel.items.remove(at: idx)
                    }
                    selectedDetailItem = nil
                },
                onImageTap: { img in
                    selectedDetailItem = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        previewImage = PreviewImage(image: img)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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

    // MARK: - Item Card

    @ViewBuilder
    private func itemCardView(_ item: WardrobeItem) -> some View {
        VStack(spacing: 0) {
            if let img = item.thumbnailImage ?? item.croppedImage ?? item.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 150)
                    .clipped()
            } else {
                Rectangle()
                    .fill(DS.Colors.backgroundSecondary)
                    .frame(height: 150)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(DS.Colors.textTertiary)
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.product)
                    .font(DS.Font.caption1)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)

                if !item.colors.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.colors.prefix(3), id: \.self) { color in
                            Circle()
                                .fill(ColorMapping.color(for: color))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Color.black.opacity(0.1), lineWidth: 0.5))
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.xs)
            .padding(.vertical, DS.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Colors.backgroundCard)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
        .dsCardShadow()
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
            WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)

            let newThumbPath = WardrobeImageFileHelper.saveThumbnail(zoneCrop ?? bgRemoved)

            let updatedItem = WardrobeItem(
                id: item.id,
                category: item.category,
                product: item.product,
                colors: item.colors,
                brand: item.brand,
                pattern: item.pattern,
                imagePath: newImagePath,
                croppedImagePath: newCroppedPath ?? item.croppedImagePath,
                thumbnailPath: newThumbPath,
                material: item.material,
                fit: item.fit,
                neckline: item.neckline,
                sleeveLength: item.sleeveLength,
                garmentLength: item.garmentLength,
                details: item.details
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
