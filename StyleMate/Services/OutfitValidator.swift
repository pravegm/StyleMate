import Foundation

/// Guarantees every outfit we *show* is actually wearable.
///
/// The on-device OutfitEngine already composes by these rules; this is the last
/// line of defence before the UI (and the guard for any look built elsewhere).
/// It runs on the mapped `[Outfit]` and:
///   1. drops physically-impossible duplicates within a look (≤1 bottom / footwear
///      / one-piece / mid-layer / outerwear),
///   2. lets a one-piece cover what it covers (no separate bottom; no separate top
///      unless it's worn over one, like dungarees or a saree),
///   3. auto-repairs a missing core piece (upper, lower, footwear) by inserting the
///      most neutral/solid wardrobe item for that slot — but only for slots the
///      wardrobe actually has, so a shoeless closet doesn't nuke every outfit,
///   4. de-dups the batch so the 5 looks are distinct.
/// Anything that still can't be made complete is dropped.
///
/// Everything is keyed by `OutfitSlot`, not raw category, so an activewear
/// legging counts as a bottom and a saree counts as a full look.
enum OutfitValidator {

    private static let neutralColors: Set<String> = [
        "black", "white", "gray", "grey", "navy", "beige", "cream",
        "tan", "khaki", "denim", "brown", "charcoal", "olive"
    ]

    /// Validate + repair a batch, returning only complete, distinct outfits
    /// (original order preserved — the engine's best look stays first).
    static func validateAndRepair(_ outfits: [Outfit], wardrobe: [WardrobeItem]) -> [Outfit] {
        let slots = Set(wardrobe.compactMap { OutfitSlot.of($0) })
        let hasAnyFootwear = slots.contains(.footwear)
        let hasAnyBottom   = slots.contains(.bottom)
        let hasAnyUpper    = slots.contains(.top)

        var result: [Outfit] = []
        var seen = Set<String>()
        var repairedCount = 0, droppedCount = 0, dupCount = 0

        for outfit in outfits {
            guard let fixed = repair(outfit, wardrobe: wardrobe,
                                     requireUpper: hasAnyUpper,
                                     requireBottom: hasAnyBottom,
                                     requireFootwear: hasAnyFootwear) else {
                droppedCount += 1
                continue
            }
            if fixed.items.map({ $0.id }) != outfit.items.map({ $0.id }) { repairedCount += 1 }

            let key = signature(of: fixed)
            if seen.contains(key) { dupCount += 1; continue }
            seen.insert(key)
            result.append(fixed)
        }

        print("[OutfitValidator] in=\(outfits.count) out=\(result.count) repaired=\(repairedCount) dropped=\(droppedCount) dupes=\(dupCount)")
        return result
    }

    /// Identity of a look for de-duplication. Accessories are "points", not
    /// structural pieces — two looks that differ only by an accessory aren't
    /// meaningfully different, so they're excluded.
    static func signature(of outfit: Outfit) -> String {
        outfit.items
            .filter { OutfitSlot.of($0) != .accessory }
            .map { $0.id.uuidString }
            .sorted()
            .joined(separator: "|")
    }

    // MARK: - Per-outfit repair

    private static func repair(_ outfit: Outfit, wardrobe: [WardrobeItem],
                               requireUpper: Bool, requireBottom: Bool, requireFootwear: Bool) -> Outfit? {
        // 1) Strip impossible doubles (keep the first of each singleton slot).
        var items = dropImpossibleDoubles(outfit.items)

        // 2) A one-piece (dress/jumpsuit/saree) already covers the lower body; a
        // dress also covers the torso, while dungarees and a saree go over a top.
        let onePiece = items.first { OutfitSlot.of($0) == .onePiece }
        if let onePiece {
            items.removeAll { OutfitSlot.of($0) == .bottom }
            if !OutfitSlot.needsTopUnder(onePiece) {
                items.removeAll { OutfitSlot.of($0) == .top }
            }
        }

        var usedIDs = Set(items.map { $0.id })

        // 3) Upper (a one-piece covers it).
        if requireUpper, onePiece == nil, !items.contains(where: { OutfitSlot.of($0) == .top }) {
            guard let top = pickNeutral(.top, from: wardrobe, excluding: usedIDs) else { return nil }
            items.append(top); usedIDs.insert(top.id)
        }

        // 4) Lower (a one-piece covers it).
        if requireBottom, onePiece == nil, !items.contains(where: { OutfitSlot.of($0) == .bottom }) {
            guard let bottom = pickNeutral(.bottom, from: wardrobe, excluding: usedIDs) else { return nil }
            items.append(bottom); usedIDs.insert(bottom.id)
        }

        // 5) Footwear.
        if requireFootwear, !items.contains(where: { OutfitSlot.of($0) == .footwear }) {
            guard let shoe = pickNeutral(.footwear, from: wardrobe, excluding: usedIDs) else { return nil }
            items.append(shoe); usedIDs.insert(shoe.id)
        }

        // Nothing wearable at all (e.g. only accessories) isn't an outfit.
        let hasBody = items.contains { slot in
            let s = OutfitSlot.of(slot)
            return s == .top || s == .onePiece
        }
        guard hasBody || !requireUpper else { return nil }

        return Outfit(items: items, explanation: outfit.explanation)
    }

    /// Keep at most one bottom / footwear / one-piece / mid-layer / outerwear.
    /// Tops are deliberately not singletons: a tee under dungarees or under an
    /// open shirt is valid.
    private static func dropImpossibleDoubles(_ items: [WardrobeItem]) -> [WardrobeItem] {
        var seenSlots = Set<OutfitSlot>()
        var out: [WardrobeItem] = []
        for item in items {
            if let slot = OutfitSlot.of(item), slot.isSingleton {
                if seenSlots.contains(slot) { continue }
                seenSlots.insert(slot)
            }
            out.append(item)
        }
        return out
    }

    /// Pick the most "safe to drop in" item for a slot: prefer everyday categories
    /// (not activewear / ethnic), neutral colours and solid patterns so a repaired
    /// piece doesn't clash with the rest of the look.
    private static func pickNeutral(_ slot: OutfitSlot, from wardrobe: [WardrobeItem], excluding: Set<UUID>) -> WardrobeItem? {
        let candidates = wardrobe.filter { OutfitSlot.of($0) == slot && !excluding.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { score($0) < score($1) }
    }

    private static func score(_ item: WardrobeItem) -> Int {
        var s = 0
        if item.colors.contains(where: { neutralColors.contains($0.lowercased()) }) { s += 2 }
        if item.pattern == .solid { s += 1 }
        if item.category != .activewear && item.category != .ethnicWear { s += 2 }
        return s
    }
}
