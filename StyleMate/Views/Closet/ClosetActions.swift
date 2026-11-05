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
                // The original cutout a studio render was made from.
                if let original = StudioStore.shared.originalCutout(for: item) {
                    WardrobeImageFileHelper.deleteImage(at: original)
                }
                ItemEmbeddingStore.shared.remove(item.id)
            }
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

    static func make(from photo: UIImage, category: Category, product: String) async -> ReplacementCutout? {
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

        let cutout: UIImage
        if let pick, let mask = pick.maskImage {
            cutout = mask
        } else {
            // Nothing recognisable (e.g. a flat product shot): lift the subject off
            // its background and frame it like every other tile.
            let lifted = await BackgroundRemovalService.shared.removeBackground(from: photo) ?? photo
            cutout = ImageAnalysisService.shared.padToSquare(lifted)
        }
        let result: (String, String?)? = await Task.detached(priority: .userInitiated) {
            guard let path = WardrobeImageFileHelper.saveImageAsPNG(cutout) else { return nil }
            return (path, WardrobeImageFileHelper.saveThumbnail(cutout))
        }.value
        guard let result else { return nil }
        return ReplacementCutout(imagePath: result.0, thumbnailPath: result.1,
                                 featurePrint: pick?.featurePrint, quality: pick?.quality ?? 0)
    }

    /// Deletes the files (used when an edit that replaced the photo is cancelled).
    func discard() {
        WardrobeImageFileHelper.deleteImage(at: imagePath)
        WardrobeImageFileHelper.deleteImage(at: thumbnailPath)
    }
}
