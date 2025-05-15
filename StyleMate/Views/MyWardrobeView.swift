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
    @State private var showPickerTip = false
    @AppStorage("hasShownPickerTip") private var hasShownPickerTip: Bool = false
    
    var body: some View {
        NavigationStack {
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
            }
            .navigationTitle("My Wardrobe")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button("Empty Wardrobe") {
                            showEmptyConfirmation = true
                        }
                        Button(action: { showProfile = true }) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 26, weight: .regular))
                        }
                        .accessibilityLabel("Profile")
                    }
                }
            }
            .background(
                NavigationLink(
                    destination: Group {
                        if let selected = selectedCategory {
                            CategoryDetailView(category: selected)
                        }
                    },
                    isActive: Binding(
                        get: { selectedCategory != nil },
                        set: { if !$0 { selectedCategory = nil } }
                    )
                ) { EmptyView() }
                .hidden()
            )
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
        .alert("Are you sure you want to empty your wardrobe?", isPresented: $showEmptyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Empty", role: .destructive) {
                for item in wardrobeViewModel.items {
                    WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                    WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                }
                wardrobeViewModel.items.removeAll()
            }
        } message: {
            Text("This will remove all items from your wardrobe and cannot be undone.")
        }
        .alert("Tip", isPresented: $showPickerTip) {
            Button("Continue") {
                hasShownPickerTip = true
                showPhotoPicker = true
            }
        } message: {
            Text("Tap multiple images to select them, then tap 'Add' or 'Done' to confirm.")
        }
    }
}

// Helper for category icon and color
extension Category {
    var iconName: String {
        switch self {
        case .tops: return "tshirt"
        case .bottoms: return "figure.walk"
        case .onePieces: return "figure.dress.line.vertical.figure"
        case .footwear: return "shoeprints.fill"
        case .accessories: return "suitcase"
        case .innerwearSleepwear: return "bed.double"
        case .ethnicOccasionwear: return "sparkles"
        case .seasonalLayering: return "cloud.sun.rain"
        }
    }
    var tileColor: Color {
        switch self {
        case .tops: return Color.blue.opacity(0.15)
        case .bottoms: return Color.green.opacity(0.15)
        case .onePieces: return Color.purple.opacity(0.15)
        case .footwear: return Color.orange.opacity(0.15)
        case .accessories: return Color.pink.opacity(0.15)
        case .innerwearSleepwear: return Color.indigo.opacity(0.15)
        case .ethnicOccasionwear: return Color.yellow.opacity(0.15)
        case .seasonalLayering: return Color.teal.opacity(0.15)
        }
    }
    var iconColor: Color {
        switch self {
        case .tops: return .blue
        case .bottoms: return .green
        case .onePieces: return .purple
        case .footwear: return .orange
        case .accessories: return .pink
        case .innerwearSleepwear: return .indigo
        case .ethnicOccasionwear: return .yellow
        case .seasonalLayering: return .teal
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
                .font(.subheadline)
                .foregroundColor(.secondary)
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
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    var items: [WardrobeItem] {
        wardrobeViewModel.items.filter { $0.category == category }
    }
    @State private var previewImage: PreviewImage? = nil
    var body: some View {
        List {
            if items.isEmpty {
                Text("No items in this category.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(items) { item in
                    Button {
                        if let previewImg = item.croppedImage ?? item.image {
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
                }
                .onDelete { indexSet in
                    let itemsToDelete = indexSet.map { items[$0] }
                    for item in itemsToDelete {
                        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                        WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                        if let idx = wardrobeViewModel.items.firstIndex(of: item) {
                            wardrobeViewModel.items.remove(at: idx)
                        }
                    }
                }
            }
        }
        .navigationTitle(category.rawValue)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
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

#Preview {
    MyWardrobeView().environmentObject(WardrobeViewModel())
} 
