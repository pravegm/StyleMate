import Foundation
import UIKit

/// Entry point for analysing a photo into wardrobe items. Everything runs on
/// the device: `WardrobeExtractor` (Core ML garment parsing + cutouts +
/// FashionSigLIP attributes) and, on Apple Intelligence devices, Apple's
/// on-device foundation model for item details. No photo or pixel leaves the
/// phone. (Outfit suggestions live in Services/Outfits/OutfitEngine.)
class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}

    // MARK: - Segmented Items

    struct SegmentedItem {
        let category: Category?
        let product: String?
        let colors: [String]
        let pattern: Pattern?
        let material: String?
        let fit: Fit?
        let neckline: Neckline?
        let sleeveLength: SleeveLength?
        let garmentLength: GarmentLength?
        let details: String?
        let brand: String
        /// Transparent, square-framed cutout of just this item.
        let maskImage: UIImage?
        /// FashionSigLIP embedding of the cutout — visual duplicate matching.
        var featurePrint: [Float]? = nil
        /// 0...1 quality of this view of the item (see WardrobeExtractor).
        var quality: Float = 0
        /// The item was cut off by the photo frame.
        var truncated: Bool = false
    }

    // MARK: - On-device Segmentation Pipeline

    /// Finds every garment and accessory in a photo and returns one clean cutout
    /// + attributes per item, entirely on-device (see `WardrobeExtractor`). Runs
    /// off the main thread; safe to call from any task.
    /// `describe`: also ask the on-device foundation model (Apple Intelligence
    /// devices only) for each item's details/brand. The manual add flow does;
    /// the background scan does it itself, only for items it actually keeps.
    func analyzeAndSegment(image: UIImage, userGender: String? = nil, retryCount: Int = 0,
                           describe: Bool = false) async -> [SegmentedItem] {
        let perf = PerfLog.begin(.photoExtraction)
        let items = await Task.detached(priority: .utility) {
            WardrobeExtractor.extract(from: image)
        }.value
        perf.end(count: items.count)
        var out: [SegmentedItem] = []
        for item in items {
            let a = item.attributes
            var notes: GarmentDescriber.Description?
            if describe { notes = await GarmentDescriber.describe(item.cutout, product: a.product, colors: a.colors) }
            out.append(SegmentedItem(
                category: a.category, product: a.product, colors: a.colors, pattern: a.pattern,
                material: a.material, fit: a.fit, neckline: a.neckline, sleeveLength: a.sleeveLength,
                garmentLength: a.garmentLength,
                details: (notes?.details).flatMap { $0.isEmpty ? nil : $0 },
                brand: notes?.brand ?? "",
                maskImage: item.cutout, featurePrint: a.embedding, quality: item.quality,
                truncated: item.truncated))
        }
        return out
    }

    func padToSquare(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        return GarmentCutout.frame(cg)
    }
}
