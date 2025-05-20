import SwiftUI

struct MyWardrobeView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 16)]
    @State private var selectedCategory: Category?
    @State private var showProfile = false
    @State private var showEmptyConfirmation = false
    @State private var showPhotoPicker = false
    @State private var selectedImages: [UIImage] = []
    @State private var showReviewBatch = false
    @State private var editingItem: WardrobeItem? = nil
    @State private var showEditSheet = false
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text("My Wardrobe")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .padding(.leading, 20)
                    Spacer()
                }
                .padding(.top, 16)
                .padding(.bottom, 8)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(Category.allCases) { category in
                            let count = wardrobeViewModel.items.filter { $0.category == category }.count
                            Button {
                                selectedCategory = category
                            } label: {
                                CategoryTile(category: category, count: count)
                            }
                            .accessibilityLabel("\(category.rawValue) category tile")
                        }
                    }
                    .padding()
                    .padding(.bottom, 120)
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileView()
            }
            .sheet(isPresented: $showPhotoPicker, onDismiss: {
                if !selectedImages.isEmpty {
                    showReviewBatch = true
                }
            }) {
                PhotoPicker(images: $selectedImages, selectionLimit: 0)
            }
            .sheet(isPresented: $showReviewBatch, onDismiss: {
                selectedImages = []
            }) {
                MultiAddNewItemView(images: selectedImages, isPresented: $showReviewBatch)
                    .environmentObject(wardrobeViewModel)
            }
            .sheet(isPresented: Binding(
                get: { showEditSheet && editingItem != nil },
                set: { newValue in
                    if !newValue {
                        showEditSheet = false
                        editingItem = nil
                    }
                }
            )) {
                if let editingItem = editingItem {
                    EditWardrobeItemView(item: editingItem) { updatedItem in
                        if let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == updatedItem.id }) {
                            wardrobeViewModel.items[idx] = updatedItem
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

// Helper for category icon and color
extension Category {
    var iconName: String {
        switch self {
        case .tops: return "tshirt"
        case .bottoms: return "figure.stand"
        case .midLayers: return "wind"
        case .outerwear: return "cloud.rain"
        case .onePieces: return "figure.dance"
        case .footwear: return "shoeprints.fill"
        case .accessories: return "suitcase"
        case .innerwear: return "bed.double"
        case .activewear: return "figure.run"
        case .ethnicWear: return "sparkles"
        }
    }
    var tileColor: Color {
        switch self {
        case .tops: return Color.blue.opacity(0.15)
        case .bottoms: return Color.green.opacity(0.15)
        case .midLayers: return Color.cyan.opacity(0.15)
        case .outerwear: return Color.gray.opacity(0.15)
        case .onePieces: return Color.purple.opacity(0.15)
        case .footwear: return Color.orange.opacity(0.15)
        case .accessories: return Color.pink.opacity(0.15)
        case .innerwear: return Color.indigo.opacity(0.15)
        case .activewear: return Color.mint.opacity(0.15)
        case .ethnicWear: return Color.yellow.opacity(0.15)
        }
    }
    var iconColor: Color {
        switch self {
        case .tops: return .blue
        case .bottoms: return .green
        case .midLayers: return .cyan
        case .outerwear: return .gray
        case .onePieces: return .purple
        case .footwear: return .orange
        case .accessories: return .pink
        case .innerwear: return .indigo
        case .activewear: return .mint
        case .ethnicWear: return .yellow
        }
    }
}

struct CategoryTile: View {
    let category: Category
    let count: Int
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(category.tileColor)
                    .frame(width: 80, height: 80)
                    .shadow(color: category.iconColor.opacity(0.15), radius: 6, x: 0, y: 4)
                Image(systemName: category.iconName)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(category.iconColor)
            }
            Text(category.rawValue)
                .font(.headline)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
            Text("\(count) item\(count == 1 ? "" : "s")")
                .font(.body)
                .foregroundColor(.primary)
                .accessibilityLabel("\(count) \(category.rawValue) items")
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.rawValue) category tile, \(count) item\(count == 1 ? "" : "s")")
    }
}

// Wrapper for image preview
struct PreviewImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct CategoryDetailView: View {
    let category: Category
    var initialProduct: String? = nil
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    var items: [WardrobeItem] {
        wardrobeViewModel.items.filter { $0.category == category }
    }
    @State private var previewImage: PreviewImage? = nil
    @State private var editingItem: WardrobeItem? = nil
    @State private var expandedProducts: Set<String> = []
    @State private var editMode: Bool = false
    @State private var selectedItems: Set<UUID> = []
    @State private var hasAutoExpanded: Bool = false

    // Helper to normalize product names (lowercase, singularize)
    private func normalizedProduct(_ product: String) -> String {
        let lower = product.lowercased().trimmingCharacters(in: .whitespaces)
        if lower.hasSuffix("s") && lower.count > 1 {
            return String(lower.dropLast())
        }
        return lower
    }
    var groupedItems: [(product: String, items: [WardrobeItem])] {
        let groups = Dictionary(grouping: items, by: { normalizedProduct($0.product) })
        // For display, pick the most common form (or the first) for the group header
        return groups.map { (normKey, items) in
            let display = items.map { $0.product }
                .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                .max(by: { $0.value < $1.value })?.key ?? items.first?.product ?? normKey.capitalized
            return (product: display, items: items)
        }
        .sorted { $0.product.localizedCaseInsensitiveCompare($1.product) == .orderedAscending }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 16) {
                    Text(emptyStateEmoji(for: category))
                        .font(.system(size: 48))
                        .padding(.bottom, 2)
                    Text("No \(category.rawValue) yet!")
                        .font(.title3.bold())
                        .foregroundColor(.accentColor)
                    Text("Start building your wardrobe by adding your first \(category.rawValue.lowercased()) item.\nTap the + button to get started!")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 60)
                .background(Color.clear)
            } else {
                List {
                    ForEach(groupedItems, id: \.product) { group in
                        Section(header:
                            HStack {
                                Text(group.product)
                                    .font(.headline)
                                ZStack {
                                    Circle()
                                        .fill(Color.accentColor)
                                        .frame(width: 22, height: 22)
                                    Text("\(group.items.count)")
                                        .font(.body.bold())
                                        .foregroundColor(.white)
                                        .accessibilityLabel("\(group.items.count) items")
                                }
                                .accessibilityLabel("\(group.items.count) items")
                                Spacer()
                                Button(action: {
                                    if expandedProducts.contains(group.product) {
                                        expandedProducts.remove(group.product)
                                    } else {
                                        expandedProducts.insert(group.product)
                                    }
                                }) {
                                    Image(systemName: expandedProducts.contains(group.product) ? "chevron.down" : "chevron.right")
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(BorderlessButtonStyle())
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if expandedProducts.contains(group.product) {
                                    expandedProducts.remove(group.product)
                                } else {
                                    expandedProducts.insert(group.product)
                                }
                            }
                        ) {
                            if expandedProducts.contains(group.product) {
                                ForEach(group.items) { item in
                                    HStack {
                                        if editMode {
                                            Button(action: {
                                                if selectedItems.contains(item.id) {
                                                    selectedItems.remove(item.id)
                                                } else {
                                                    selectedItems.insert(item.id)
                                                }
                                            }) {
                                                Image(systemName: selectedItems.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundColor(selectedItems.contains(item.id) ? .accentColor : .secondary)
                                                    .imageScale(.large)
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                        }
                                        Button {
                                            if !editMode, let previewImg = item.croppedImage ?? item.image {
                                                previewImage = PreviewImage(image: previewImg)
                                            }
                                        } label: {
                                            HStack {
                                                if let cropped = item.croppedImage {
                                                    Image(uiImage: cropped)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 60, height: 60)
                                                        .clipped()
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                } else if let original = item.image {
                                                    Image(uiImage: original)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 60, height: 60)
                                                        .clipped()
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                } else {
                                                    Rectangle()
                                                        .fill(Color.gray)
                                                        .frame(width: 60, height: 60)
                                                        .overlay(Text("No Image").font(.caption2))
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                }
                                                VStack(alignment: .leading) {
                                                    Text(item.name)
                                                        .font(.headline)
                                                    Text(item.pattern.rawValue)
                                                        .font(.subheadline)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        .disabled(editMode) // Disable preview in edit mode
                                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                            if !editMode {
                                                Button(role: .destructive) {
                                                    if let idx = wardrobeViewModel.items.firstIndex(of: item) {
                                                        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                                                        WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                                                        wardrobeViewModel.items.remove(at: idx)
                                                    }
                                                } label: {
                                                    Label("Delete", systemImage: "trash")
                                                }
                                                .tint(.red)
                                                Button {
                                                    editingItem = item
                                                } label: {
                                                    Label("Edit", systemImage: "pencil")
                                                }
                                                .tint(.blue)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if let initial = initialProduct, !hasAutoExpanded {
                // Try to expand the matching product group
                if let match = groupedItems.first(where: { $0.product.localizedCaseInsensitiveCompare(initial) == .orderedSame }) {
                    expandedProducts.insert(match.product)
                } else if let match = groupedItems.first(where: { normalizedProduct($0.product) == normalizedProduct(initial) }) {
                    expandedProducts.insert(match.product)
                }
                hasAutoExpanded = true
            } else {
                expandedProducts = [] // All collapsed by default
            }
        }
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if editMode {
                    Button(action: {
                        // Delete selected items
                        let toDelete = selectedItems
                        for id in toDelete {
                            if let item = wardrobeViewModel.items.first(where: { $0.id == id }) {
                                WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                                WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                                if let idx = wardrobeViewModel.items.firstIndex(of: item) {
                                    wardrobeViewModel.items.remove(at: idx)
                                }
                            }
                        }
                        selectedItems.removeAll()
                        editMode = false
                    }) {
                        Label("Delete", systemImage: "trash")
                            .foregroundColor(.red)
                    }
                } else {
                    Button(action: {
                        editMode = true
                        selectedItems.removeAll()
                    }) {
                        Text("Edit")
                    }
                }
            }
            if editMode {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        editMode = false
                        selectedItems.removeAll()
                    }
                }
            }
        }
        .sheet(item: $previewImage) { wrapper in
            VStack {
                Spacer()
                ZoomableImage(image: wrapper.image)
                    .padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .font(.headline)
                    .padding()
            }
        }
        .sheet(item: $editingItem) { item in
            EditWardrobeItemView(item: item) { updatedItem in
                if let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == updatedItem.id }) {
                    wardrobeViewModel.items[idx] = updatedItem
                }
                editingItem = nil
            }
        }
    }

    private func emptyStateEmoji(for category: Category) -> String {
        switch category {
        case .tops: return "👚"
        case .bottoms: return "👖"
        case .onePieces: return "👗"
        case .footwear: return "👟"
        case .accessories: return "🕶️"
        case .innerwear: return "🩲"
        case .ethnicWear: return "🥻"
        case .midLayers: return "🌬️"
        case .outerwear: return "🌧️"
        case .activewear: return "🏃"
        }
    }
}

// ZoomableImage view for pinch-to-zoom support
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
            // Calculate the displayed image size (fit)
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
                                let newOffset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                                offset = newOffset
                            }
                            .onEnded { value in
                                guard scale > 1 else { offset = .zero; lastOffset = .zero; return }
                                let maxX = max(0, (displayWidth * scale - frameSize.width) / 2)
                                let maxY = max(0, (displayHeight * scale - frameSize.height) / 2)
                                let clamped = CGSize(
                                    width: min(max(offset.width, -maxX), maxX),
                                    height: min(max(offset.height, -maxY), maxY)
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

// PreferenceKey for scroll offset
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    MyWardrobeView().environmentObject(WardrobeViewModel())
} 
