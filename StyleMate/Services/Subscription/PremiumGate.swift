import Foundation

/// The free tier as the app uses it: today's counts, the entitlement and the account's pieces
/// waiting for Premium (`WardrobeViewModel.lockedItems`, synced). The rule itself is
/// `WardrobeAllowance` (counting) + `AccountAllowance` (the deterministic cross-device reconcile).
@MainActor
enum PremiumGate {
    static var isPremium: Bool { PremiumStore.shared.isPremium }

    static func countedItems(in wardrobe: WardrobeViewModel) -> Int {
        WardrobeAllowance.countedItems(wardrobe.items, sampleIDs: wardrobe.sampleIDs)
    }

    /// Free slots left on this phone's view of the account (Int.max with Premium).
    static func freeSlots(in wardrobe: WardrobeViewModel) -> Int {
        WardrobeAllowance.freeSlots(counted: countedItems(in: wardrobe), isPremium: isPremium)
    }

    /// A manual add (camera / gallery) would add nothing: show the paywall instead.
    static func isAtLimit(_ wardrobe: WardrobeViewModel) -> Bool {
        WardrobeAllowance.isAtLimit(counted: countedItems(in: wardrobe), isPremium: isPremium)
    }

    /// Keeps a new piece for Premium, with its embedding so a later photo of the same garment is
    /// recognised instead of being locked twice.
    static func lock(_ item: WardrobeItem, embedding: [Float]?, quality: Float, truncated: Bool,
                     in wardrobe: WardrobeViewModel) {
        if let embedding { ItemEmbeddingStore.shared.set(embedding, quality: quality, truncated: truncated, for: item.id) }
        wardrobe.addLocked(item)
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
                lock(entry.item, embedding: entry.embedding, quality: entry.quality, truncated: entry.truncated, in: wardrobe)
            }
        }
        return split.lock
    }

    /// Applies the account's rule now (launch, entitlement change, removals; sync runs it itself).
    static func reconcile(_ wardrobe: WardrobeViewModel) {
        guard !wardrobe.currentUserEmail.isEmpty else { return }
        wardrobe.reconcileAllowance(isPremium: isPremium)
    }
}

/// The local list of waiting pieces kept by the first Premium build (`Application Support/Premium/
/// locked_<profile>.json`, never synced). Read once into the synced `lockedItems`, then removed.
enum LegacyLockedImport {
    private struct Stored: Decodable {
        let stored: WardrobeItemCodable
        let lockedAt: Date
    }

    static func fileURL(forUser userId: String) -> URL {
        let safe = userId.replacingOccurrences(of: "/", with: "_")
        return LocalStore.applicationSupport.appendingPathComponent("Premium", isDirectory: true)
            .appendingPathComponent("locked_\(safe).json")
    }

    /// The old list's items (oldest first), removing the file.
    static func take(forUser userId: String) -> [(item: WardrobeItem, meta: ItemMeta)] {
        guard !userId.isEmpty else { return [] }
        let url = fileURL(forUser: userId)
        guard let data = try? Data(contentsOf: url) else { return [] }
        try? FileManager.default.removeItem(at: url)
        guard let decoded = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return decoded.compactMap { s in
            s.stored.toWardrobeItem().map { (item: $0, meta: ItemMeta(createdAt: s.lockedAt, tier: .free)) }
        }
    }
}
