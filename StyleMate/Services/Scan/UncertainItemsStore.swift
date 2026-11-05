import Foundation
import UIKit

/// Items the scan found but wasn't sure enough about to add by itself
/// (`ItemTrust`): a fragment, a poor view, tiny jewelry. They wait here —
/// cutout saved, never in the closet — until the user taps to add or dismiss
/// ("We weren't sure about 1 item — tap to add" on Home).
///
/// Persisted per profile in `Application Support/ScanProgress/uncertain_<id>.json`
/// (backup-excluded, wiped with the scan state).
@MainActor
final class UncertainItemsStore: ObservableObject {
    static let shared = UncertainItemsStore()

    struct HeldItem: Codable, Identifiable, Equatable {
        var id: String { stored.id }
        let stored: WardrobeItemCodable
        let embedding: [Float]?
        let quality: Float
        let doubt: String
        let heldAt: Date

        var item: WardrobeItem {
            stored.toWardrobeItem() ?? WardrobeItem(category: .accessories, product: "Item", colors: [], brand: "",
                                                    pattern: .solid, imagePath: "", croppedImagePath: nil,
                                                    thumbnailPath: nil, material: nil, fit: nil, neckline: nil,
                                                    sleeveLength: nil, garmentLength: nil, details: nil)
        }

        static func == (a: HeldItem, b: HeldItem) -> Bool { a.stored.id == b.stored.id }
    }

    /// The current profile's held items, newest first.
    @Published private(set) var items: [HeldItem] = []
    private var userId = ""
    /// Oldest items (and their images) are dropped beyond this.
    static let maxHeld = 40

    private init() {}

    private static func fileURL(forUser userId: String) -> URL {
        LocalStore.directory("ScanProgress").appendingPathComponent("uncertain_\(userId).json")
    }

    func load(forUser userId: String) {
        self.userId = userId
        guard !userId.isEmpty, let data = try? Data(contentsOf: Self.fileURL(forUser: userId)),
              let decoded = try? JSONDecoder().decode([HeldItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        guard !userId.isEmpty else { return }
        let url = Self.fileURL(forUser: userId)
        let snapshot = items
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { LocalStore.write(data, to: url) }
        }
    }

    // MARK: Scan side

    func hold(_ item: WardrobeItem, embedding: [Float]?, quality: Float, doubt: ItemTrust.Doubt, forUser userId: String) {
        if self.userId != userId { load(forUser: userId) }
        items.insert(HeldItem(stored: WardrobeItemCodable(from: item), embedding: embedding, quality: quality,
                              doubt: doubt.rawValue, heldAt: Date()), at: 0)
        while items.count > Self.maxHeld, let oldest = items.popLast() { deleteFiles(oldest.item) }
        save()
    }

    // MARK: User side

    /// "Add": the item joins the closet (with its embedding, so duplicates of it
    /// are recognised from now on).
    func add(_ held: HeldItem, to wardrobe: WardrobeViewModel) {
        let item = held.item
        guard !item.imagePath.isEmpty else { dismiss(held); return }
        if let fp = held.embedding { ItemEmbeddingStore.shared.set(fp, quality: held.quality, for: item.id) }
        if !wardrobe.items.contains(where: { $0.id == item.id }) {
            wardrobe.items.append(item)
            wardrobe.syncItemToCloud(item)
        }
        items.removeAll { $0 == held }
        save()
    }

    func dismiss(_ held: HeldItem) {
        deleteFiles(held.item)
        items.removeAll { $0 == held }
        save()
    }

    func dismissAll() {
        items.forEach { deleteFiles($0.item) }
        items = []
        save()
    }

    /// Profile deletion.
    func forget(forUser userId: String) {
        if self.userId == userId { dismissAll() }
        try? FileManager.default.removeItem(at: Self.fileURL(forUser: userId))
        if self.userId == userId { self.userId = "" }
    }

    private func deleteFiles(_ item: WardrobeItem) {
        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
        if item.croppedImagePath != item.imagePath { WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath) }
        WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
    }

    // MARK: Copy

    /// "We weren't sure about 1 item — tap to add".
    static func headline(count: Int) -> String {
        "We weren't sure about \(count) item\(count == 1 ? "" : "s") — tap to add"
    }

    static func reason(_ raw: String) -> String {
        switch ItemTrust.Doubt(rawValue: raw) {
        case .fragmented: return "Looks like it might be several things"
        case .lowQuality: return "Hard to see clearly in the photo"
        case .tinyJewelry: return "Small jewelry is easy to mistake"
        case .unsureAccessory: return "Might not be what it looks like"
        case .none: return "Not sure about this one"
        }
    }
}
