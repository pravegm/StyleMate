import SwiftUI

struct ReviewBatchView: View {
    @EnvironmentObject var wardrobeViewModel: WardrobeViewModel
    @Environment(\.dismiss) var dismiss
    let images: [UIImage]
    @State private var detectedItems: [[DetectedItem]] = []
    @State private var brandInputs: [[String]] = []
    @State private var isAnalyzing = true
    @State private var errorMessage = ""
    @State private var showError = false
    
    struct DetectedItem: Identifiable {
        let id = UUID()
        var category: Category
        var product: String
        var colors: [String]
        var pattern: Pattern
        var boundingBox: ImageAnalysisService.BoundingBox? = nil
    }
    
    var canSave: Bool {
        detectedItems.flatMap { $0 }.allSatisfy { !$0.product.isEmpty && !$0.colors.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) }
    }
    
    var body: some View {
        NavigationStack {
            if isAnalyzing {
                ProgressView("Analyzing images...")
                    .padding()
            } else {
                ScrollView {
                    ForEach(images.indices, id: \.self) { idx in
                        VStack(alignment: .leading, spacing: 12) {
                            Image(uiImage: images[idx])
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .cornerRadius(10)
                            if detectedItems.indices.contains(idx) {
                                ForEach(detectedItems[idx].indices, id: \.self) { itemIdx in
                                    VStack(alignment: .leading, spacing: 8) {
                                        Picker("Category", selection: $detectedItems[idx][itemIdx].category) {
                                            ForEach(Category.allCases) { cat in
                                                Text(cat.rawValue).tag(cat)
                                            }
                                        }
                                        Picker("Product", selection: $detectedItems[idx][itemIdx].product) {
                                            ForEach(productOptions(for: detectedItems[idx][itemIdx].category), id: \.self) { prod in
                                                Text(prod).tag(prod)
                                            }
                                        }
                                        Section(header: Text("Colors:")) {
                                            ForEach(Array(detectedItems[idx][itemIdx].colors.enumerated()), id: \.offset) { colorIdx, _ in
                                                HStack {
                                                    TextField("Color", text: $detectedItems[idx][itemIdx].colors[colorIdx])
                                                    if detectedItems[idx][itemIdx].colors.count > 1 {
                                                        Button(action: {
                                                            detectedItems[idx][itemIdx].colors.remove(at: colorIdx)
                                                        }) {
                                                            Image(systemName: "minus.circle.fill").foregroundColor(.red)
                                                        }
                                                    }
                                                }
                                            }
                                            Button(action: {
                                                detectedItems[idx][itemIdx].colors.append("")
                                            }) {
                                                HStack {
                                                    Image(systemName: "plus.circle.fill").foregroundColor(.green)
                                                    Text("Add Color")
                                                }
                                            }
                                        }
                                        Picker("Pattern", selection: $detectedItems[idx][itemIdx].pattern) {
                                            ForEach(Pattern.allCases) { pattern in
                                                Text(pattern.rawValue).tag(pattern)
                                            }
                                        }
                                        TextField("Brand (e.g. Nike)", text: $brandInputs[idx][itemIdx])
                                    }
                                    .padding(.vertical, 6)
                                }
                                Button("Remove Image") {
                                    removeImage(at: idx)
                                }
                                .foregroundColor(.red)
                                .padding(.top, 4)
                            }
                        }
                        .padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }
                .navigationTitle("Review Items")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save All") {
                            saveAll()
                        }
                        .disabled(!canSave)
                    }
                }
                .alert("Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
            }
        }
        .onAppear {
            analyzeAllImages()
        }
    }
    
    private func analyzeAllImages() {
        isAnalyzing = true
        detectedItems = Array(repeating: [], count: images.count)
        brandInputs = Array(repeating: [], count: images.count)
        Task {
            for (idx, image) in images.enumerated() {
                let results = await ImageAnalysisService.shared.analyzeMultiple(image: image)
                let items = results.compactMap { cat, prod, colors, pattern, bbox in
                    if let cat = cat, let prod = prod, let pattern = pattern, !colors.isEmpty {
                        return DetectedItem(category: cat, product: prod, colors: colors, pattern: pattern, boundingBox: bbox)
                    } else {
                        return nil
                    }
                }
                await MainActor.run {
                    detectedItems[idx] = items
                    brandInputs[idx] = Array(repeating: "", count: items.count)
                    // Ensure product is valid for Picker
                    for itemIdx in detectedItems[idx].indices {
                        let options = productOptions(for: detectedItems[idx][itemIdx].category)
                        if !options.contains(detectedItems[idx][itemIdx].product) {
                            detectedItems[idx][itemIdx].product = options.first ?? ""
                        }
                    }
                }
            }
            isAnalyzing = false
        }
    }
    
    private func saveAll() {
        for (imgIdx, items) in detectedItems.enumerated() {
            for (itemIdx, detected) in items.enumerated() {
                let cropped: UIImage? = cropImage(images[imgIdx], with: detected.boundingBox)
                let item = WardrobeItem(
                    category: detected.category,
                    product: detected.product,
                    colors: detected.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                    brand: brandInputs[imgIdx][itemIdx],
                    pattern: detected.pattern,
                    image: images[imgIdx],
                    croppedImage: cropped
                )
                wardrobeViewModel.items.append(item)
            }
        }
        dismiss()
    }
    
    private func removeImage(at idx: Int) {
        detectedItems.remove(at: idx)
        brandInputs.remove(at: idx)
        // Remove image from parent view (handled by parent)
        // For now, just ignore removed images in saveAll
    }
    
    private func productOptions(for category: Category) -> [String] {
        // This should match your ProductType logic
        switch category {
        case .tops: return ["T-shirts", "Shirts", "Polo shirts", "Tank tops", "Blouses", "Crop tops", "Sweaters", "Sweatshirts", "Hoodies", "Jackets", "Blazers", "Coats", "Cardigans", "Vests", "Kurtas"]
        case .bottoms: return ["Jeans", "Trousers", "Chinos", "Shorts", "Skirts", "Leggings", "Joggers", "Track pants", "Cargo pants", "Dhotis", "Salwars"]
        case .onePieces: return ["Dresses", "Jumpsuits", "Rompers", "Sarees", "Gowns", "Overalls"]
        case .footwear: return ["Sneakers", "Formal shoes", "Loafers", "Boots", "Sandals", "Flip flops", "Heels", "Flats", "Slippers", "Mojaris/Juttis"]
        case .accessories: return ["Watches", "Sunglasses", "Spectacles", "Belts", "Hats", "Caps", "Scarves", "Necklaces", "Earrings", "Bracelets", "Bangles", "Rings", "Ties", "Cufflinks", "Backpacks", "Handbags", "Clutches", "Wallets"]
        case .innerwearSleepwear: return ["Undergarments", "Bras", "Boxers/Briefs", "Night suits", "Loungewear", "Slips", "Thermals"]
        case .ethnicOccasionwear: return ["Sherwanis", "Lehenga cholis", "Anarkalis", "Nehru jackets", "Dupattas", "Kurta sets", "Blouse (ethnic)", "Dhoti sets"]
        case .seasonalLayering: return ["Raincoats", "Windcheaters", "Overcoats", "Thermal inners", "Gloves", "Beanies"]
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
}