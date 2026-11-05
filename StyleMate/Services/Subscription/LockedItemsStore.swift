import Foundation
import UIKit

/// Pieces found past the free tier's limit (`WardrobeAllowance`), waiting for Premium.
///
/// They are real, fully extracted items (cutout + thumbnail in `wardrobe_images/`, embedding in
/// `ItemEmbeddingStore`) but NOT in `WardrobeViewModel.items`, so the closet, the outfit engine,
/// studio renders and iCloud never see them. Home and the closet show a card ("23 more pieces
/// found — unlock with Premium"); subscribing moves them all into the wardrobe at once (and only
/// then are they uploaded to the user's iCloud). Removing items makes room: the oldest locked
/// pieces fill the free slots.
///
/// Persisted per profile as JSON in `Application Support/Premium/locked_<id>.json` (local only,
/// excluded from iCloud Backup like every personal file — see `LocalStore`). Deleted with the
/// profile (`WardrobeViewModel.deleteAllLocalData`) and by "Empty My Wardrobe".
@MainActor
final class LockedItemsStore: ObservableObject {
    static let shared = LockedItemsStore()

    struct LockedItem: Codable, Identifiable, Equatable {
        var id: String { stored.id }
        let stored: WardrobeItemCodable
        let lockedAt: Date

        var item: WardrobeItem? { stored.toWardrobeItem() }

        static func == (a: LockedItem, b: LockedItem) -> Bool { a.stored.id == b.stored.id }
    }

    /// The current profile's locked items, oldest first.
    @Published private(set) var items: [LockedItem] = []
    private(set) var userId = ""

    /// Writes are serialized so an older snapshot can never overwrite a newer one.
    nonisolated private static let writer = DispatchQueue(label: "com.stylemates.StyleMate.lockedItems", qos: .utility)

    /// nil = `Application Support/Premium` (tests pass a temporary folder).
    private let directoryOverride: URL?

    init(directory: URL? = nil) {
        directoryOverride = directory
    }

    func fileURL(forUser userId: String) -> URL {
        let safe = userId.replacingOccurrences(of: "/", with: "_")
        let dir = directoryOverride ?? LocalStore.directory("Premium")
        return dir.appendingPathComponent("locked_\(safe).json")
    }

    // MARK: Load / save

    func load(forUser userId: String) {
        self.userId = userId
        items = read(forUser: userId)
    }

    func read(forUser userId: String) -> [LockedItem] {
        guard !userId.isEmpty, let data = try? Data(contentsOf: fileURL(forUser: userId)),
              let decoded = try? JSONDecoder().decode([LockedItem].self, from: data) else { return [] }
        return decoded
    }

    private func save() {
        guard !userId.isEmpty else { return }
        let url = fileURL(forUser: userId)
        let snapshot = items
        Self.writer.async {
            if snapshot.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder().encode(snapshot) {
                LocalStore.write(data, to: url)
            }
        }
    }

    /// Waits for pending writes (tests, profile deletion).
    nonisolated static func flushWrites() { writer.sync {} }

    // MARK: Scan / manual add side

    var count: Int { items.count }

    /// Keeps a new item for Premium. Its embedding (if any) is stored so a later photo of the
    /// same garment is recognised as a duplicate instead of being locked twice.
    func lock(_ item: WardrobeItem, embedding: [Float]? = nil, quality: Float = 0, truncated: Bool = false,
              forUser userId: String) {
        guard !userId.isEmpty else { return }
        if self.userId != userId { load(forUser: userId) }
        guard !items.contains(where: { $0.stored.id == item.id.uuidString }) else { return }
        if let embedding { ItemEmbeddingStore.shared.set(embedding, quality: quality, truncated: truncated, for: item.id) }
        items.append(LockedItem(stored: WardrobeItemCodable(from: item), lockedAt: Date()))
        save()
    }

    /// The locked items as wardrobe items (for duplicate checks and the card's thumbnails).
    var wardrobeItems: [WardrobeItem] { items.compactMap(\.item) }

    /// This profile's locked items, loading them first if another profile (or none) is loaded
    /// (a background scan can run before any view appeared).
    func wardrobeItems(forUser userId: String) -> [WardrobeItem] {
        if self.userId != userId { load(forUser: userId) }
        return wardrobeItems
    }

    // MARK: Unlock

    /// Moves locked items into the wardrobe: every one with Premium, otherwise as many as there
    /// are free slots (oldest first). Each is queued for the user's iCloud backup. Returns how
    /// many moved.
    @discardableResult
    func unlock(into wardrobe: WardrobeViewModel, isPremium: Bool, sampleIDs: Set<UUID>) -> Int {
        guard !items.isEmpty, !userId.isEmpty, wardrobe.currentUserEmail == userId else { return 0 }
        let moving = takeUnlockable(wardrobe: wardrobe.items, isPremium: isPremium, sampleIDs: sampleIDs)
        guard !moving.isEmpty else { return 0 }
        let existing = Set(wardrobe.items.map(\.id))
        let newItems = moving.filter { !existing.contains($0.id) }
        if !newItems.isEmpty {
            wardrobe.items.append(contentsOf: newItems)   // one write
            for item in newItems { wardrobe.syncItemToCloud(item) }
        }
        dlog("[Premium] Unlocked \(moving.count) items (\(items.count) still locked)")
        return moving.count
    }

    /// Removes and returns the locked items the wardrobe may take now (oldest first): all with
    /// Premium, otherwise as many as fit in the free tier.
    func takeUnlockable(wardrobe: [WardrobeItem], isPremium: Bool, sampleIDs: Set<UUID>) -> [WardrobeItem] {
        let counted = WardrobeAllowance.countedItems(wardrobe, sampleIDs: sampleIDs)
        let n = WardrobeAllowance.unlockable(locked: items.count, counted: counted, isPremium: isPremium)
        guard n > 0 else { return [] }
        let moving = Array(items.prefix(n))
        items.removeFirst(moving.count)
        save()
        return moving.compactMap(\.item)
    }

    // MARK: Deletion

    /// "Empty My Wardrobe": the locked pieces go too (files and embeddings).
    func removeAll() {
        let doomed = items.compactMap(\.item)
        for item in doomed { Self.deleteFiles(of: item) }
        ItemEmbeddingStore.shared.remove(doomed.map(\.id))
        items = []
        save()
    }

    /// Profile deletion: everything this profile had locked, files and embeddings included.
    func forget(forUser userId: String) {
        guard !userId.isEmpty else { return }
        let doomed = (self.userId == userId ? items : read(forUser: userId)).compactMap(\.item)
        for item in doomed { Self.deleteFiles(of: item) }
        ItemEmbeddingStore.shared.remove(doomed.map(\.id))
        if self.userId == userId {
            items = []
            self.userId = ""
        }
        let url = fileURL(forUser: userId)
        Self.writer.async { try? FileManager.default.removeItem(at: url) }
    }

    private static func deleteFiles(of item: WardrobeItem) {
        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
        if item.croppedImagePath != item.imagePath { WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath) }
        WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
    }
}

/// The free-tier gate as the app uses it: today's counts, the entitlement and the locked store.
@MainActor
enum PremiumGate {
    static func sampleIDs(_ userId: String) -> Set<UUID> {
        SampleLibrary.sampleItemIDs(forUser: userId)
    }

    static func countedItems(in wardrobe: WardrobeViewModel) -> Int {
        WardrobeAllowance.countedItems(wardrobe.items, sampleIDs: sampleIDs(wardrobe.currentUserEmail))
    }

    static var isPremium: Bool { PremiumStore.shared.isPremium }

    /// Free slots left (Int.max with Premium).
    static func freeSlots(in wardrobe: WardrobeViewModel) -> Int {
        WardrobeAllowance.freeSlots(counted: countedItems(in: wardrobe), isPremium: isPremium)
    }

    /// A manual add (camera / gallery) would add nothing: show the paywall instead.
    static func isAtLimit(_ wardrobe: WardrobeViewModel) -> Bool {
        WardrobeAllowance.isAtLimit(counted: countedItems(in: wardrobe), isPremium: isPremium)
    }

    /// Adds `items` to the wardrobe up to the free limit; the rest are locked for Premium.
    /// Embeddings are stored for every item. Returns how many were locked.
    @discardableResult
    static func admit(_ items: [(item: WardrobeItem, embedding: [Float]?, quality: Float, truncated: Bool)],
                      to wardrobe: WardrobeViewModel) -> Int {
        let split = WardrobeAllowance.split(adding: items.count, counted: countedItems(in: wardrobe), isPremium: isPremium)
        for (i, entry) in items.enumerated() {
            if i < split.add {
                if let fp = entry.embedding {
                    ItemEmbeddingStore.shared.set(fp, quality: entry.quality, truncated: entry.truncated, for: entry.item.id)
                }
                wardrobe.items.append(entry.item)
                wardrobe.syncItemToCloud(entry.item)
            } else {
                LockedItemsStore.shared.lock(entry.item, embedding: entry.embedding, quality: entry.quality,
                                             truncated: entry.truncated, forUser: wardrobe.currentUserEmail)
            }
        }
        return split.lock
    }

    /// Moves locked items into the wardrobe when they're allowed: all of them once Premium is
    /// active, otherwise into any free slots (after the user removed items). Cheap when there is
    /// nothing to do; called at launch, on an entitlement change and when the item count drops.
    static func reconcile(_ wardrobe: WardrobeViewModel) {
        let user = wardrobe.currentUserEmail
        guard !user.isEmpty else { return }
        let store = LockedItemsStore.shared
        if store.userId != user { store.load(forUser: user) }
        store.unlock(into: wardrobe, isPremium: isPremium, sampleIDs: sampleIDs(user))
    }
}
