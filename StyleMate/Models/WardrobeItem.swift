import UIKit

// Pattern enum moved here from Pattern.swift
enum Pattern: String, CaseIterable, Identifiable, Codable {
    case solid = "Solid"
    case stripes = "Stripes"
    case checks = "Checks"
    case plaid = "Plaid"
    case polkaDot = "Polka Dot"
    case floral = "Floral"
    case animalPrint = "Animal Print"
    case camouflage = "Camouflage"
    case geometric = "Geometric"
    case houndstooth = "Houndstooth"
    case paisley = "Paisley"
    case tieDye = "Tie-Dye"

    var id: String { self.rawValue }
}

struct WardrobeItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let category: Category
    let product: String
    let colors: [String]
    let brand: String
    let pattern: Pattern
    let image: UIImage
    let croppedImage: UIImage?
    
    var displayProduct: String {
        // Naive singularization: remove trailing 's' if present and not in exceptions
        let exceptions = ["Jeans", "Shorts", "Boxers/Briefs", "Trousers", "Glasses", "Sunglasses", "Spectacles", "Pants"]
        if exceptions.contains(product) {
            return product
        }
        if product.hasSuffix("s") {
            return String(product.dropLast())
        }
        return product
    }
    
    var name: String {
        ([colors.joined(separator: ", ")] + [pattern.rawValue, brand, displayProduct])
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " ")
    }
    
    private var colorsList: String {
        if let colors = self as? WardrobeItem, !colors.colors.isEmpty {
            // For backward compatibility, if only 'color' exists
            return colors.colors.joined(separator: ", ")
        }
        // If you have a [String] colors property, join them
        // But since the struct only has 'color: String', you may need to update the model to store [String] if you want true multi-color support
        return colors.joined(separator: ", ")
    }
    
    init(id: UUID = UUID(), category: Category, product: String, colors: [String], brand: String, pattern: Pattern, image: UIImage, croppedImage: UIImage? = nil) {
        self.id = id
        self.category = category
        self.product = product
        self.colors = colors
        self.brand = brand
        self.pattern = pattern
        self.image = image
        self.croppedImage = croppedImage
    }
    
    static func == (lhs: WardrobeItem, rhs: WardrobeItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
} 