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
            ReviewBatchView(images: selectedImages)
                .environmentObject(wardrobeViewModel)
        }
        .alert("Are you sure you want to empty your wardrobe?", isPresented: $showEmptyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Empty", role: .destructive) {
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
                        previewImage = PreviewImage(image: item.croppedImage ?? item.image)
                    } label: {
                        HStack {
                            if let cropped = item.croppedImage {
                                Image(uiImage: cropped)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else if let original = item.image as UIImage? {
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
                Image(uiImage: wrapper.image)
                    .resizable()
                    .scaledToFit()
                    .padding()
                Spacer()
                Button("Close") { previewImage = nil }
                    .font(.headline)
                    .padding()
            }
        }
    }
}

#Preview {
    MyWardrobeView().environmentObject(WardrobeViewModel())
} 
