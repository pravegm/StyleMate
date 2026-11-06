import Foundation

/// The free tier's one rule: **the first 50 wardrobe items are free; Premium is unlimited.**
/// Every feature works on the free tier. Pure logic (no StoreKit, no UI), so it is unit tested.
///
/// - Items from the bundled sample photos never count.
/// - Nothing the user already has is ever removed or hidden. If Premium lapses with 120 items,
///   all 120 stay usable; only NEW additions past the limit wait (locked) until Premium.
/// - A manual batch that would cross the limit adds what fits; the rest wait locked and the
///   paywall is offered for them.
/// - The background scan keeps finding items past the limit and stores them locked
///   (`LockedItemsStore`). Subscribing unlocks them all; making room (removing items) unlocks
///   the oldest locked ones into the free slots.
enum WardrobeAllowance {
    static let freeItemLimit = 50

    /// The items that count towards the limit (everything except sample-photo items).
    static func countedItems(_ items: [WardrobeItem], sampleIDs: Set<UUID>) -> Int {
        guard !sampleIDs.isEmpty else { return items.count }
        return items.reduce(0) { $0 + (sampleIDs.contains($1.id) ? 0 : 1) }
    }

    /// How many more items fit for free (never negative). Unlimited (`Int.max`) with Premium.
    static func freeSlots(counted: Int, isPremium: Bool, limit: Int = freeItemLimit) -> Int {
        isPremium ? Int.max : max(0, limit - counted)
    }

    /// What happens to `count` new items.
    struct Split: Equatable {
        /// Go straight into the wardrobe.
        var add: Int
        /// Wait locked for Premium.
        var lock: Int
    }

    /// A batch of `count` new (non-sample) items, given what's already counted.
    static func split(adding count: Int, counted: Int, isPremium: Bool, limit: Int = freeItemLimit) -> Split {
        let n = max(0, count)
        let fits = min(n, freeSlots(counted: counted, isPremium: isPremium, limit: limit))
        return Split(add: fits, lock: n - fits)
    }

    /// Locked items that can join the wardrobe now: all of them with Premium, otherwise as many
    /// as there are free slots (oldest first, by the caller).
    static func unlockable(locked: Int, counted: Int, isPremium: Bool, limit: Int = freeItemLimit) -> Int {
        min(max(0, locked), freeSlots(counted: counted, isPremium: isPremium, limit: limit))
    }

    /// True when a manual add should show the paywall before even starting (no free slot left).
    static func isAtLimit(counted: Int, isPremium: Bool, limit: Int = freeItemLimit) -> Bool {
        freeSlots(counted: counted, isPremium: isPremium, limit: limit) == 0
    }

    // MARK: Copy

    /// "23 more pieces found" / "1 more piece found".
    static func lockedHeadline(_ count: Int) -> String {
        "\(count) more piece\(count == 1 ? "" : "s") found"
    }

    /// "Your first 50 pieces are free. Premium keeps every piece StyleMate finds."
    static var freeTierLine: String {
        "Your first \(freeItemLimit) pieces are free. Premium keeps every piece StyleMate finds."
    }
}
