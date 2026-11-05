import Foundation
import UIKit

/// "Try with sample photos": a handful of bundled CC0 street-style photos
/// (StyleMate/Resources/SamplePhotos, credits below and in
/// SAMPLE-PHOTO-CREDITS.md) run through the real on-device pipeline, so anyone
/// — a skeptical first-time user, or App Review on a near-empty test phone —
/// sees a closet fill up without sharing a single photo of their own.
///
/// Sample items are ordinary wardrobe items whose ids are remembered here, so
/// they're clearly labelled ("Sample clothes") and removable in one tap.
enum SampleLibrary {
    struct Credit: Identifiable {
        var id: String { file }
        let file: String
        let title: String
        let source: String
    }

    /// All CC0 1.0 (Wikimedia Commons).
    static let credits: [Credit] = [
        Credit(file: "sample_street_coat_boots.jpg", title: "Street Style of 2018 2019 in Tehran 6",
               source: "https://commons.wikimedia.org/wiki/File:Street_Style_of_2018_2019_in_Tehran_6.jpg"),
        Credit(file: "sample_street_coat_scarf.jpg", title: "Street Style of 2018 2019 in Tehran 2",
               source: "https://commons.wikimedia.org/wiki/File:Street_Style_of_2018_2019_in_Tehran_2.jpg"),
        Credit(file: "sample_pink_coat_boots.jpg", title: "Elegant woman by storefront (Unsplash)",
               source: "https://commons.wikimedia.org/wiki/File:Elegant_woman_by_storefront_(Unsplash).jpg"),
        Credit(file: "sample_casual_denim_jacket_hat.jpg", title: "Brooke Cagle 2017-01-30 (Unsplash)",
               source: "https://commons.wikimedia.org/wiki/File:Brooke_Cagle_2017-01-30_(Unsplash_HIEAVcz3CzU).jpg"),
        Credit(file: "sample_ripped_jeans_belt_watch.jpg", title: "Urban Street Clothes (Unsplash)",
               source: "https://commons.wikimedia.org/wiki/File:Urban_Street_Clothes_(Unsplash).jpg"),
        Credit(file: "sample_kurta_dhoti_turban.jpg", title: "Indian man standing in doorway (Unsplash)",
               source: "https://commons.wikimedia.org/wiki/File:Indian_man_standing_in_doorway_(Unsplash).jpg"),
    ]

    static let licence = "CC0 1.0 (public domain), via Wikimedia Commons"

    /// The bundled photos, in credit order. (Synchronized Xcode groups copy
    /// resources flat into the bundle; a folder copy is accepted too.)
    static func photoURLs(bundle: Bundle = .main) -> [URL] {
        credits.compactMap { credit in
            let name = (credit.file as NSString).deletingPathExtension
            return bundle.url(forResource: name, withExtension: "jpg")
                ?? bundle.url(forResource: name, withExtension: "jpg", subdirectory: "SamplePhotos")
        }
    }

    static func loadImages(bundle: Bundle = .main) -> [UIImage] {
        photoURLs(bundle: bundle).compactMap { UIImage(contentsOfFile: $0.path) }
    }

    static var isAvailable: Bool { !photoURLs().isEmpty }

    // MARK: Which items are samples

    private static func key(_ userId: String) -> String { "sampleItemIDs_\(userId)" }

    static func sampleItemIDs(forUser userId: String, defaults: UserDefaults = .standard) -> Set<UUID> {
        Set((defaults.stringArray(forKey: key(userId)) ?? []).compactMap(UUID.init(uuidString:)))
    }

    static func recordSampleItems(_ ids: [UUID], forUser userId: String, defaults: UserDefaults = .standard) {
        guard !ids.isEmpty, !userId.isEmpty else { return }
        let all = sampleItemIDs(forUser: userId, defaults: defaults).union(ids)
        defaults.set(all.map(\.uuidString), forKey: key(userId))
    }

    static func sampleCount(in items: [WardrobeItem], userId: String) -> Int {
        let ids = sampleItemIDs(forUser: userId)
        guard !ids.isEmpty else { return 0 }
        return items.filter { ids.contains($0.id) }.count
    }

    /// One tap: every sample item leaves the closet (files, embeddings, iCloud).
    @MainActor
    @discardableResult
    static func removeSamples(from wardrobe: WardrobeViewModel, userId: String) -> Int {
        let ids = sampleItemIDs(forUser: userId)
        if PhotoScanService.shared.isWorking, PhotoScanService.shared.currentPhase.contains("sample") {
            PhotoScanService.shared.cancelScan()
        }
        let removed = deleteItems(ids, from: wardrobe)
        UserDefaults.standard.removeObject(forKey: key(userId))
        if PhotoScanService.shared.scanState == .completed { PhotoScanService.shared.dismissCompleted() }
        print("[StyleMate] Removed \(removed) sample items")
        return removed
    }

    /// Deletes these items everywhere (closet, image files, embeddings, iCloud).
    @MainActor
    @discardableResult
    static func deleteItems(_ ids: Set<UUID>, from wardrobe: WardrobeViewModel) -> Int {
        guard !ids.isEmpty else { return 0 }
        let doomed = wardrobe.items.filter { ids.contains($0.id) }
        for item in doomed {
            wardrobe.deleteItemFromCloud(item)
            WardrobeImageFileHelper.deleteImage(at: item.imagePath)
            if item.croppedImagePath != item.imagePath { WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath) }
            WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
        }
        ItemEmbeddingStore.shared.remove(doomed.map(\.id))
        wardrobe.items.removeAll { ids.contains($0.id) }
        return doomed.count
    }

    /// Starts the sample import (returns at once; the import runs on its own).
    @MainActor
    static func start(userId: String, wardrobe: WardrobeViewModel) {
        let images = loadImages()
        guard !images.isEmpty else { print("[StyleMate] Sample photos missing from the bundle"); return }
        Task { await PhotoScanService.shared.runSampleImport(images: images, userId: userId, wardrobeViewModel: wardrobe) }
    }
}
