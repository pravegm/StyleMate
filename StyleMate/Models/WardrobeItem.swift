import UIKit

struct WardrobeItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let category: Category
    let product: String
    let color: String
    let brand: String
    let image: UIImage
    
    var name: String { "\(brand) \(color) \(product)" }
    
    init(id: UUID = UUID(), category: Category, product: String, color: String, brand: String, image: UIImage) {
        self.id = id
        self.category = category
        self.product = product
        self.color = color
        self.brand = brand
        self.image = image
    }
    
    static func == (lhs: WardrobeItem, rhs: WardrobeItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
} 