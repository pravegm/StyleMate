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
    let thumbnailPath: String?

    let material: String?
    let fit: Fit?
    let neckline: Neckline?
    let sleeveLength: SleeveLength?
    let garmentLength: GarmentLength?
    let details: String?
    
    var image: UIImage? { WardrobeImageFileHelper.loadImage(at: imagePath) }
    var croppedImage: UIImage? { croppedImagePath != nil ? WardrobeImageFileHelper.loadImage(at: croppedImagePath!) : nil }
    var thumbnailImage: UIImage? { thumbnailPath != nil ? WardrobeImageFileHelper.loadImage(at: thumbnailPath!) : nil }
    
    var displayProduct: String {
        let exceptions = [
            "Jeans", "Shorts", "Trousers", "Sunglasses", "Eyeglasses",
            "Chinos", "Capris", "Culottes", "Slides", "Flats", "Heels",
            "Reading Glasses"
        ]
        if exceptions.contains(product) {
            return product
        }
        // "Watches" → "Watch", "Dresses" → "Dress", "Boxes" → "Box"; plain "-s" otherwise.
        for suffix in ["sses", "ches", "shes", "xes"] where product.hasSuffix(suffix) {
            return String(product.dropLast(2))
        }
        if product.hasSuffix("s") && !product.hasSuffix("ss") {
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

        if let neckline = neckline, category.supportsNeckline {
            let isDefaultNeckline = (neckline == .crewNeck && ["T-Shirts", "Graphic Tees", "Sweatshirts"].contains(product))
            if !isDefaultNeckline { parts.append(neckline.rawValue) }
        }

        if let fit = fit, fit != .regular, category.supportsFit { parts.append(fit.rawValue) }

        if let sleeve = sleeveLength, category.supportsSleeves {
            let isDefaultSleeve = (sleeve == .longSleeve && [.midLayers, .outerwear].contains(category))
                || (sleeve == .shortSleeve && ["T-Shirts", "Polo T-Shirts", "Graphic Tees"].contains(product))
            if !isDefaultSleeve { parts.append(sleeve.rawValue) }
        }

        if !brand.isEmpty { parts.append(brand) }

        parts.append(displayProduct)

        return parts.joined(separator: " ")
    }

    /// Returns a copy with garment-only attributes cleared when they don't apply
    /// to this item's category — repairs items saved before category gating, so a
    /// sunglasses item can't keep a stale "Collared" / "Short Sleeve" value.
    func sanitizedAttributes() -> WardrobeItem {
        let needsClean = (fit != nil && !category.supportsFit)
            || (neckline != nil && !category.supportsNeckline)
            || (sleeveLength != nil && !category.supportsSleeves)
            || (garmentLength != nil && !category.supportsLength)
        guard needsClean else { return self }
        return WardrobeItem(
            id: id, category: category, product: product, colors: colors, brand: brand,
            pattern: pattern, imagePath: imagePath, croppedImagePath: croppedImagePath,
            thumbnailPath: thumbnailPath, material: material,
            fit: category.supportsFit ? fit : nil,
            neckline: category.supportsNeckline ? neckline : nil,
            sleeveLength: category.supportsSleeves ? sleeveLength : nil,
            garmentLength: category.supportsLength ? garmentLength : nil,
            details: details
        )
    }

    /// A copy pointing at new image files (same id and attributes).
    func withImages(imagePath: String, croppedImagePath: String?, thumbnailPath: String?) -> WardrobeItem {
        WardrobeItem(
            id: id, category: category, product: product, colors: colors, brand: brand,
            pattern: pattern, imagePath: imagePath, croppedImagePath: croppedImagePath,
            thumbnailPath: thumbnailPath, material: material, fit: fit, neckline: neckline,
            sleeveLength: sleeveLength, garmentLength: garmentLength, details: details
        )
    }

    var detailsSubtitle: String? {
        guard let details = details, !details.isEmpty else { return nil }
        return details
    }
    
    init(id: UUID = UUID(), category: Category, product: String, colors: [String], brand: String, pattern: Pattern, imagePath: String, croppedImagePath: String? = nil, thumbnailPath: String? = nil, material: String? = nil, fit: Fit? = nil, neckline: Neckline? = nil, sleeveLength: SleeveLength? = nil, garmentLength: GarmentLength? = nil, details: String? = nil) {
        self.id = id
        self.category = category
        self.product = product
        self.colors = colors
        self.brand = brand
        self.pattern = pattern
        self.imagePath = imagePath
        self.croppedImagePath = croppedImagePath
        self.thumbnailPath = thumbnailPath
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

/// The wardrobe's image files: cutouts, thumbnails and outfit-history snapshots. Items
/// store bare file names; the files live in `Application Support/wardrobe_images/`
/// (excluded from iCloud Backup, protected until first unlock — see `LocalStore`).
/// Builds before Nov 2026 used `Documents/wardrobe_images/`; it is moved on first access.
///
/// Thread-safe: every method may be called from any thread.
final class WardrobeImageFileHelper {
    static let folderName = "wardrobe_images"

    /// Created + migrated exactly once per process (Swift `static let` is lazy and atomic).
    private static let baseFolderURL: URL = {
        let dir = LocalStore.directory(folderName)
        LocalStore.migrateLegacyDirectory(named: folderName, into: dir)
        return dir
    }()

    static var folderURL: URL {
        let dir = baseFolderURL
        // Recreated if something removed it (UI-test reset, delete-everything).
        if !FileManager.default.fileExists(atPath: dir.path) { _ = LocalStore.directory(folderName) }
        return dir
    }

    static func fileURL(for filename: String) -> URL {
        folderURL.appendingPathComponent(filename)
    }

    static func saveImage(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        return LocalStore.write(data, to: fileURL(for: filename)) ? filename : nil
    }

    static func saveImageAsPNG(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".png"
        guard let data = image.pngData() else { return nil }
        return LocalStore.write(data, to: fileURL(for: filename)) ? filename : nil
    }

    // MARK: - Cache
    //
    // Decoded-image caches with byte budgets (the old one was 600 entries, no size limit —
    // ~1440 px thumbnails at ~8 MB each). SwiftUI re-evaluates view bodies many times and
    // some views still read `item.thumbnailImage` / `croppedImage` in `body`, so without a
    // cache every re-render re-read the file. Thumbnails and outfit snapshots get almost the
    // whole budget; full-size cutouts (up to 4 MB decoded each) only a small one, so they
    // can't crowd the thumbnails out. ClosetImageLoader keeps its own display-ready copies.

    static let thumbnailCacheByteLimit = 64 * 1024 * 1024
    static let fullImageCacheByteLimit = 16 * 1024 * 1024

    private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = thumbnailCacheByteLimit
        cache.countLimit = 1000
        return cache
    }()

    private static let fullImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = fullImageCacheByteLimit
        cache.countLimit = 16
        return cache
    }()

    static let thumbnailPrefix = "thumb_"
    static let snapshotPrefix = "outfit_"

    static func isThumbnail(_ filename: String) -> Bool {
        filename.hasPrefix(thumbnailPrefix) || filename.hasPrefix(snapshotPrefix)
    }

    private static func cache(for filename: String) -> NSCache<NSString, UIImage> {
        isThumbnail(filename) ? thumbnailCache : fullImageCache
    }

    /// Decoded size in bytes (what the cache budgets count).
    static func decodedCost(of image: UIImage) -> Int {
        let px = ImageDownsampler.pixelSize(of: image)
        return max(1, Int(px.width * px.height) * 4)
    }

    static func loadImage(at filename: String) -> UIImage? {
        guard !filename.isEmpty else { return nil }
        let key = filename as NSString
        let store = cache(for: filename)
        if let cached = store.object(forKey: key) { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: filename)),
              let image = UIImage(data: data) else { return nil }
        let cost = decodedCost(of: image)
        if isThumbnail(filename) || cost <= fullImageCacheByteLimit / 4 {
            store.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// Cheap existence check — no decode. Use this instead of `loadImage(...) != nil`
    /// when you only need to know whether a file is present.
    static func imageExists(at filename: String) -> Bool {
        guard !filename.isEmpty else { return false }
        if cache(for: filename).object(forKey: filename as NSString) != nil { return true }
        return FileManager.default.fileExists(atPath: fileURL(for: filename).path)
    }

    static func deleteImage(at filename: String?) {
        guard let filename, !filename.isEmpty else { return }
        cache(for: filename).removeObject(forKey: filename as NSString)
        try? FileManager.default.removeItem(at: fileURL(for: filename))
    }

    static func evictFromCache(_ filename: String) {
        cache(for: filename).removeObject(forKey: filename as NSString)
    }

    static func removeAllFromCache() {
        thumbnailCache.removeAllObjects()
        fullImageCache.removeAllObjects()
    }

    // MARK: - Thumbnails

    /// Thumbnails are 480 px on the long side (real pixels): grid cards are ~170 pt wide,
    /// ~510 px on a 3x screen. The renderer is pinned to scale 1 — its default format uses
    /// the screen scale, which made the "480 px" thumbnails 1440 px (bigger than the cutouts).
    static let thumbnailMaxPixels: CGFloat = 480

    /// A thumbnail file more than this many pixels on its long side predates the scale fix.
    static let oversizedThumbnailPixels: CGFloat = 600

    static func saveThumbnail(_ image: UIImage, maxDimension: CGFloat = 480) -> String? {
        saveThumbnail(image, maxDimension: maxDimension, prefix: thumbnailPrefix)
    }

    private static func saveThumbnail(_ image: UIImage, maxDimension: CGFloat, prefix: String) -> String? {
        let px = ImageDownsampler.pixelSize(of: image)
        let longSide = max(px.width, px.height)
        guard longSide > 0 else { return nil }
        let factor = min(maxDimension / longSide, 1.0)
        let newSize = CGSize(width: max(1, (px.width * factor).rounded()),
                             height: max(1, (px.height * factor).rounded()))
        // Cutouts are transparent: keep them PNG, or JPEG flattens the background to black.
        let hasAlpha = ImageDownsampler.hasAlpha(image)
        let thumbnailImage = autoreleasepool {
            ImageDownsampler.render(size: newSize, opaque: !hasAlpha) { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }
        return writeThumbnail(thumbnailImage, hasAlpha: hasAlpha, prefix: prefix)
    }

    private static func writeThumbnail(_ thumbnail: UIImage, hasAlpha: Bool, prefix: String) -> String? {
        let filename = prefix + UUID().uuidString + (hasAlpha ? ".png" : ".jpg")
        guard let data = hasAlpha ? thumbnail.pngData() : thumbnail.jpegData(compressionQuality: 0.7) else { return nil }
        return LocalStore.write(data, to: fileURL(for: filename)) ? filename : nil
    }

    /// Makes a thumbnail straight from an image FILE with ImageIO (no full-size decode).
    /// Safe off the main thread.
    static func makeThumbnail(fromFile filename: String, prefix: String = "thumb_") -> String? {
        let url = fileURL(for: filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return autoreleasepool { () -> String? in
            guard let thumb = ImageDownsampler.downsample(fileURL: url, maxPixels: thumbnailMaxPixels) else { return nil }
            return writeThumbnail(thumb, hasAlpha: ImageDownsampler.hasAlpha(thumb), prefix: prefix)
        }
    }

    /// True when a thumbnail file is missing or was made before the scale fix (1440 px).
    static func thumbnailNeedsRegeneration(_ filename: String?) -> Bool {
        guard let filename, !filename.isEmpty else { return true }
        guard let size = ImageDownsampler.pixelSize(ofFile: fileURL(for: filename)) else { return true }
        return max(size.width, size.height) > oversizedThumbnailPixels
    }

    // MARK: - Outfit-history snapshots

    /// A private small copy of an item's picture for the outfit calendar, so history keeps
    /// its pictures after the item is deleted, re-photographed or upgraded by the scan
    /// (all of which delete the item's own files). Prefers copying the existing thumbnail;
    /// otherwise renders one from the cutout. Returns the snapshot's file name.
    static func makeOutfitSnapshot(thumbnailPath: String?, imagePath: String?) -> String? {
        let fm = FileManager.default
        if let thumb = thumbnailPath, !thumb.isEmpty, !thumbnailNeedsRegeneration(thumb) {
            let ext = (thumb as NSString).pathExtension
            let name = snapshotPrefix + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
            if (try? fm.copyItem(at: fileURL(for: thumb), to: fileURL(for: name))) != nil {
                try? fm.setAttributes([.protectionKey: LocalStore.fileProtection],
                                      ofItemAtPath: fileURL(for: name).path)
                return name
            }
        }
        for source in [thumbnailPath, imagePath].compactMap({ $0 }) where !source.isEmpty {
            if let name = makeThumbnail(fromFile: source, prefix: snapshotPrefix) { return name }
        }
        return nil
    }

    static func isOutfitSnapshot(_ filename: String?) -> Bool {
        filename?.hasPrefix(snapshotPrefix) ?? false
    }
}
