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

enum Fit: String, CaseIterable, Identifiable, Codable {
    case slim = "Slim"
    case regular = "Regular"
    case relaxed = "Relaxed"
    case oversized = "Oversized"
    case cropped = "Cropped"
    var id: String { self.rawValue }
}

enum Neckline: String, CaseIterable, Identifiable, Codable {
    case crewNeck = "Crew Neck"
    case vNeck = "V-Neck"
    case scoopNeck = "Scoop Neck"
    case boatNeck = "Boat Neck"
    case turtleneck = "Turtleneck"
    case mockNeck = "Mock Neck"
    case henley = "Henley"
    case collared = "Collared"
    case hooded = "Hooded"
    case offShoulder = "Off-Shoulder"
    case squareNeck = "Square Neck"
    case halter = "Halter"
    case strapless = "Strapless"
    case cowlNeck = "Cowl Neck"
    var id: String { self.rawValue }
}

enum SleeveLength: String, CaseIterable, Identifiable, Codable {
    case sleeveless = "Sleeveless"
    case capSleeve = "Cap Sleeve"
    case shortSleeve = "Short Sleeve"
    case threeQuarterSleeve = "3/4 Sleeve"
    case longSleeve = "Long Sleeve"
    var id: String { self.rawValue }
}

enum GarmentLength: String, CaseIterable, Identifiable, Codable {
    case cropped = "Cropped"
    case short = "Short"
    case kneeLength = "Knee-Length"
    case midi = "Midi"
    case fullLength = "Full-Length"
    var id: String { self.rawValue }
}

struct WardrobeItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let category: Category
    let product: String
    let colors: [String]
    let brand: String
    let pattern: Pattern
    let imagePath: String
    let croppedImagePath: String?

    let material: String?
    let fit: Fit?
    let neckline: Neckline?
    let sleeveLength: SleeveLength?
    let garmentLength: GarmentLength?
    let details: String?
    
    var image: UIImage? { WardrobeImageFileHelper.loadImage(at: imagePath) }
    var croppedImage: UIImage? { croppedImagePath != nil ? WardrobeImageFileHelper.loadImage(at: croppedImagePath!) : nil }
    
    var displayProduct: String {
        let exceptions = ["Jeans", "Shorts", "Trousers", "Sunglasses", "Chinos", "Capris", "Culottes", "Slides", "Flats", "Heels"]
        if exceptions.contains(product) {
            return product
        }
        if product.hasSuffix("s") {
            return String(product.dropLast())
        }
        return product
    }
    
    var name: String {
        var parts: [String] = []

        let colorStr = colors.joined(separator: ", ")
        if !colorStr.isEmpty { parts.append(colorStr) }

        if pattern != .solid { parts.append(pattern.rawValue) }

        if let material = material, !material.isEmpty { parts.append(material) }

        if let neckline = neckline {
            let isDefaultNeckline = (neckline == .crewNeck && ["T-Shirts", "Graphic Tees", "Sweatshirts"].contains(product))
            if !isDefaultNeckline { parts.append(neckline.rawValue) }
        }

        if let fit = fit, fit != .regular { parts.append(fit.rawValue) }

        if let sleeve = sleeveLength {
            let isDefaultSleeve = (sleeve == .longSleeve && [.midLayers, .outerwear].contains(category))
                || (sleeve == .shortSleeve && ["T-Shirts", "Polo T-Shirts", "Graphic Tees"].contains(product))
            if !isDefaultSleeve { parts.append(sleeve.rawValue) }
        }

        if !brand.isEmpty { parts.append(brand) }

        parts.append(displayProduct)

        return parts.joined(separator: " ")
    }

    var detailsSubtitle: String? {
        guard let details = details, !details.isEmpty else { return nil }
        return details
    }
    
    init(id: UUID = UUID(), category: Category, product: String, colors: [String], brand: String, pattern: Pattern, imagePath: String, croppedImagePath: String? = nil, material: String? = nil, fit: Fit? = nil, neckline: Neckline? = nil, sleeveLength: SleeveLength? = nil, garmentLength: GarmentLength? = nil, details: String? = nil) {
        self.id = id
        self.category = category
        self.product = product
        self.colors = colors
        self.brand = brand
        self.pattern = pattern
        self.imagePath = imagePath
        self.croppedImagePath = croppedImagePath
        self.material = material
        self.fit = fit
        self.neckline = neckline
        self.sleeveLength = sleeveLength
        self.garmentLength = garmentLength
        self.details = details
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