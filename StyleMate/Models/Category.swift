import SwiftUI

// Exhaustive enum for all categories
enum Category: String, CaseIterable, Identifiable, Hashable {
    case tops = "Tops"
    case bottoms = "Bottoms"
    case midLayers = "Mid-Layers"
    case outerwear = "Outerwear"
    case onePieces = "One-Pieces"
    case footwear = "Footwear"
    case accessories = "Accessories"
    case innerwear = "Innerwear"
    case activewear = "Activewear"
    case ethnicWear = "Ethnic Wear"
    
    var id: String { self.rawValue }
}

// Shared wardrobe view model
class WardrobeViewModel: ObservableObject {
    @Published var items: [WardrobeItem] = [] {
        didSet {
            if !suspendSaving {
                save(forUser: currentUserEmail)
            }
        }
    }
    private(set) var currentUserEmail: String = ""
    private var suspendSaving = false
    
    private func storageKey(for email: String) -> String {
        "wardrobe_\(email.replacingOccurrences(of: "@", with: "_").replacingOccurrences(of: ".", with: "_"))"
    }
    
    func load(forUser email: String) {
        currentUserEmail = email
        let key = storageKey(for: email)
        guard let data = UserDefaults.standard.data(forKey: key) else {
            items = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([WardrobeItemCodable].self, from: data)
            items = decoded.compactMap { $0.toWardrobeItem() }
        } catch {
            items = []
        }
    }
    
    func save(forUser email: String) {
        guard !email.isEmpty else { return }
        let key = storageKey(for: email)
        let codableItems = items.map { WardrobeItemCodable(from: $0) }
        if let data = try? JSONEncoder().encode(codableItems) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    func clear() {
        suspendSaving = true
        items = []
        suspendSaving = false
        currentUserEmail = ""
    }
}

// Codable wrapper for WardrobeItem (UIImage is not Codable)
struct WardrobeItemCodable: Codable {
    let id: String
    let category: String
    let product: String
    let colors: [String]
    let brand: String
    let pattern: String
    let imagePath: String
    let croppedImagePath: String?
    
    init(from item: WardrobeItem) {
        self.id = item.id.uuidString
        self.category = item.category.rawValue
        self.product = item.product
        self.colors = item.colors
        self.brand = item.brand
        self.pattern = item.pattern.rawValue
        self.imagePath = item.imagePath
        self.croppedImagePath = item.croppedImagePath
    }
    
    func toWardrobeItem() -> WardrobeItem? {
        guard let cat = Category(rawValue: category),
              let pat = Pattern(rawValue: pattern) else { return nil }
        return WardrobeItem(
            id: UUID(uuidString: id) ?? UUID(),
            category: cat,
            product: product,
            colors: colors,
            brand: brand,
            pattern: pat,
            imagePath: imagePath,
            croppedImagePath: croppedImagePath
        )
    }
} 