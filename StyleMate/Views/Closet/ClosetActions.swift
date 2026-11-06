import SwiftUI
import UIKit

/// Wardrobe mutations the closet screens perform, in one place so every entry
/// point (grid context menu, bulk select, detail page, category page) cleans up
/// the same way. Call on the main thread (they mutate the published items).
enum ClosetActions {

    /// Removes items for good: their image files, their visual embedding (used by
    /// duplicate detection) and their CloudKit record. One `items` write, so the
    /// wardrobe is saved once however many items go.
    static func remove(_ items: [WardrobeItem], from wardrobe: WardrobeViewModel) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        for item in items {
            wardrobe.deleteItemFromCloud(item)
            ClosetImageLoader.shared.evict([item.imagePath, item.croppedImagePath, item.thumbnailPath])
        }
        wardrobe.items.removeAll { ids.contains($0.id) }
        // File + embedding cleanup off the main thread (the embedding store
        // rewrites its JSON per removal).
        let doomed = items
        Task.detached(priority: .utility) {
            for item in doomed {
                WardrobeImageFileHelper.deleteImage(at: item.imagePath)
                if item.croppedImagePath != item.imagePath {
                    WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
                }
                WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
            }
            // The studio records too, with the original cutouts renders were made from.
            StudioStore.shared.remove(doomed.map(\.id))
            ItemEmbeddingStore.shared.remove(doomed.map(\.id))
        }
    }

    /// Saves an edited item in place and syncs it.
    static func update(_ item: WardrobeItem, in wardrobe: WardrobeViewModel) {
        guard let idx = wardrobe.items.firstIndex(where: { $0.id == item.id }) else { return }
        wardrobe.items[idx] = item.sanitizedAttributes()
        wardrobe.syncItemToCloud(wardrobe.items[idx])
    }
}

/// A new photo for an existing item, cut out on-device the same way scanned
/// items are: the garment of the matching kind is found in the photo, so a
/// replacement photo of you wearing the jacket yields just the jacket.
struct ReplacementCutout {
    let imagePath: String
    let thumbnailPath: String?
    let featurePrint: [Float]?
    let quality: Float

    /// `photo` may be a full-size camera image: it is brought to ≤ 2048 px with its orientation
    /// baked in first (a 48 MP decode is ~190 MB, and `cgImage` ignores orientation), and the
    /// whole extraction runs inside the shared `ExtractionGate`, like every other one.
    static func make(from photo: UIImage, category: Category, product: String) async -> ReplacementCutout? {
        let photo = await Task.detached(priority: .userInitiated) {
            autoreleasepool { ImageDownsampler.downsample(image: photo) }
        }.value
        await ExtractionGate.shared.acquire()
        let found = await Self.cutout(from: photo, category: category, product: product)
        await ExtractionGate.shared.release()
        guard let made = found else { return nil }
        let (image, pick) = made
        let result: (String, String?)? = await Task.detached(priority: .userInitiated) {
            guard let path = WardrobeImageFileHelper.saveImageAsPNG(image) else { return nil }
            return (path, WardrobeImageFileHelper.saveThumbnail(image))
        }.value
        guard let result else { return nil }
        return ReplacementCutout(imagePath: result.0, thumbnailPath: result.1,
                                 featurePrint: pick?.featurePrint, quality: pick?.quality ?? 0)
    }

    /// The framed, transparent cutout of the item in an upright ≤ 2048 px photo, and the
    /// segment it came from (nil when the subject was lifted off a plain product shot).
    private static func cutout(from photo: UIImage, category: Category,
                               product: String) async -> (UIImage, ImageAnalysisService.SegmentedItem?)? {
        let segments = await ImageAnalysisService.shared.analyzeAndSegment(image: photo, describe: false)
            .filter { $0.maskImage != nil }
        let wanted = ClosetSection.of(category: category, product: product)
        let pick = segments.first { $0.category == category && $0.product == product }
            ?? segments.filter { $0.category == category }.max { $0.quality < $1.quality }
            ?? segments.filter { s in
                guard let c = s.category else { return false }
                return ClosetSection.of(category: c, product: s.product ?? "") == wanted
            }.max { $0.quality < $1.quality }
            ?? (segments.count == 1 ? segments.first : nil)

        if let pick, let mask = pick.maskImage { return (mask, pick) }
        // Nothing recognisable (e.g. a flat product shot): lift the subject off its
        // background (transparent) and frame it like every other tile. No subject found:
        // the photo itself, framed.
        let lifted = await BackgroundRemovalService.shared.removeBackground(from: photo, onWhite: false) ?? photo
        let framed = await Task.detached(priority: .userInitiated) {
            ImageAnalysisService.shared.padToSquare(lifted)
        }.value
        return (framed, nil)
    }

    /// Deletes the files (used when an edit that replaced the photo is cancelled).
    func discard() {
        WardrobeImageFileHelper.deleteImage(at: imagePath)
        WardrobeImageFileHelper.deleteImage(at: thumbnailPath)
    }
}
