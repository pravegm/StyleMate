import Foundation

/// Per-item bookkeeping for the account-level free tier, synced with the item (CloudKit fields
/// `createdAt`, `tier`, `isSample`; the lock itself is `isLocked`). Kept beside `WardrobeItem` (in
/// `WardrobeViewModel.meta`), so editing an item never resets it.
struct ItemMeta: Codable, Equatable {
    enum Tier: String, Codable {
        /// Added before the account-level free tier existed: never locked.
        case grandfathered
        /// Added or unlocked while Premium was active: stays when Premium lapses.
        case premium
        /// Added on the free tier: one of the account's 50 free pieces.
        case free
    }

    var createdAt: Date
    var tier: Tier
    var isSample = false

    /// Items that predate this bookkeeping (and records uploaded by older builds).
    static var legacy: ItemMeta { ItemMeta(createdAt: Date(timeIntervalSince1970: 0), tier: .grandfathered) }

    /// A brand-new item.
    static func new(premium: Bool, at date: Date = Date(), sample: Bool = false) -> ItemMeta {
        ItemMeta(createdAt: date, tier: premium ? .premium : .free, isSample: sample)
    }
}

/// The free tier at account level: **50 free pieces per account, on every device, with no server.**
///
/// Every device runs the same pure rule after each sync merge (and after local adds, removals and
/// entitlement changes), so they all reach the same split from the same synced data:
///
/// - Premium: every locked piece unlocks, and every free-tier piece becomes `.premium` (so a later
///   lapse removes nothing).
/// - Not Premium: grandfathered and premium pieces always stay. The free slots left are
///   `50 − that count`; the free-tier pieces and the locked ones are ordered by `createdAt`, then id,
///   and the oldest that fit are unlocked, the rest locked. Sample pieces never count and never lock.
///
/// The result depends only on the set of items (not on the order devices merged them), so two
/// iPhones that each added pieces offline agree once they've synced.
enum AccountAllowance {
    struct Entry: Equatable {
        var id: UUID
        var meta: ItemMeta
        var isLocked: Bool
    }

    struct Plan: Equatable {
        /// Unlocked now, locked by the plan.
        var lock: Set<UUID> = []
        /// Locked now, unlocked by the plan.
        var unlock: Set<UUID> = []
        /// Free-tier pieces that become `.premium`.
        var promote: Set<UUID> = []

        var isEmpty: Bool { lock.isEmpty && unlock.isEmpty && promote.isEmpty }
    }

    /// Oldest first; the id breaks ties so every device sorts identically.
    static func precedes(_ a: Entry, _ b: Entry) -> Bool {
        if a.meta.createdAt != b.meta.createdAt { return a.meta.createdAt < b.meta.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    static func reconcile(_ entries: [Entry], isPremium: Bool,
                          limit: Int = WardrobeAllowance.freeItemLimit) -> Plan {
        var plan = Plan()
        // Samples are never part of the allowance.
        for e in entries where e.meta.isSample && e.isLocked { plan.unlock.insert(e.id) }
        let real = entries.filter { !$0.meta.isSample }

        if isPremium {
            for e in real {
                if e.isLocked { plan.unlock.insert(e.id) }
                if e.isLocked || e.meta.tier == .free { plan.promote.insert(e.id) }
            }
            return plan
        }

        let kept = real.filter { !$0.isLocked && $0.meta.tier != .free }.count
        let allowed = max(0, limit - kept)
        let candidates = real.filter { $0.isLocked || $0.meta.tier == .free }.sorted(by: precedes)
        for (i, e) in candidates.enumerated() {
            let shouldBeUnlocked = i < allowed
            if shouldBeUnlocked && e.isLocked { plan.unlock.insert(e.id) }
            if !shouldBeUnlocked && !e.isLocked { plan.lock.insert(e.id) }
        }
        return plan
    }

    /// The entries after applying a plan (tests and the view model use the same function).
    static func applying(_ plan: Plan, to entries: [Entry]) -> [Entry] {
        entries.map { e in
            var e = e
            if plan.lock.contains(e.id) { e.isLocked = true }
            if plan.unlock.contains(e.id) { e.isLocked = false }
            if plan.promote.contains(e.id) { e.meta.tier = .premium }
            return e
        }
    }

    /// "3 pieces moved to Premium because your other iPhone added items".
    static func movedNotice(_ count: Int) -> String {
        "\(count) piece\(count == 1 ? "" : "s") moved to Premium because your other iPhone added items."
    }
}
