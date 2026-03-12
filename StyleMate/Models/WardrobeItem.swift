import UIKit

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
    let imagePath: String // Path to image file in wardrobe_images
    let croppedImagePath: String? // Path to cropped image file in wardrobe_images
    
    // Helper to load images from disk
    var image: UIImage? { WardrobeImageFileHelper.loadImage(at: imagePath) }
    var croppedImage: UIImage? { croppedImagePath != nil ? WardrobeImageFileHelper.loadImage(at: croppedImagePath!) : nil }
    
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
    
    init(id: UUID = UUID(), category: Category, product: String, colors: [String], brand: String, pattern: Pattern, imagePath: String, croppedImagePath: String? = nil) {
        self.id = id
        self.category = category
        self.product = product
        self.colors = colors
        self.brand = brand
        self.pattern = pattern
        self.imagePath = imagePath
        self.croppedImagePath = croppedImagePath
    }
    
    static func == (lhs: WardrobeItem, rhs: WardrobeItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

class WardrobeImageFileHelper {
    static let folderName = "wardrobe_images"
    static var folderURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent(folderName)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
    static func saveImage(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        let url = folderURL.appendingPathComponent(filename)
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        do {
            try data.write(to: url)
            return filename
        } catch {
            return nil
        }
    }
    static func saveImageAsPNG(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".png"
        let url = folderURL.appendingPathComponent(filename)
        guard let data = image.pngData() else { return nil }
        do {
            try data.write(to: url)
            return filename
        } catch {
            return nil
        }
    }
    static func loadImage(at filename: String) -> UIImage? {
        let url = folderURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
    static func deleteImage(at filename: String?) {
        guard let filename = filename else { return }
        let url = folderURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
} 