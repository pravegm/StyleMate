import Foundation

/// Guarantees every outfit we *show* is actually wearable.
///
/// Gemini is asked to obey a composition rulebook, but nothing enforced it — a
/// returned look could be missing a bottom or shoes, contain two pairs of pants,
/// or duplicate another look. This layer runs on the mapped `[Outfit]` before it
/// reaches the UI and:
///   1. drops physically-impossible duplicates within a look (≤1 bottom / footwear
///      / one-piece),
///   2. auto-repairs a missing core piece (upper, lower, footwear) by inserting the
///      most neutral/solid wardrobe item of that category — but only for categories
///      the wardrobe actually has, so a shoeless closet doesn't nuke every outfit,
///   3. de-dups the batch so the 5 looks are distinct.
/// Anything that still can't be made complete is dropped.
enum OutfitValidator {

    /// Categories that can serve as the upper "base" of an outfit.
    private static let upperBaseCategories: Set<Category> = [.tops, .onePieces, .ethnicWear, .activewear]

    /// At most one of each of these may appear in a single outfit. Bottoms /
    /// footwear / one-piece are physical singletons; mid-layers and outerwear are
    /// the "≤1 per layer tier" rule (two sweaters or two coats at once is wrong).
    /// NOTE: .tops is deliberately NOT here — a base tee under a button-down is a
    /// valid two-item upper layering.
    private static let singletonCategories: Set<Category> = [.bottoms, .footwear, .onePieces, .midLayers, .outerwear]

    /// Accessories are "points", not structural pieces — two looks that differ only
    /// by an accessory aren't meaningfully different, so they're excluded from the
    /// de-dup signature.
    private static let coreRoleExclusions: Set<Category> = [.accessories]

    private static let neutralColors: Set<String> = [
        "black", "white", "gray", "grey", "navy", "beige", "cream",
        "tan", "khaki", "denim", "brown", "charcoal", "olive"
    ]

    /// Validate + repair a batch, returning only complete, distinct outfits
    /// (original order preserved — Gemini's best suggestion stays first).
    static func validateAndRepair(_ outfits: [Outfit], wardrobe: [WardrobeItem]) -> [Outfit] {
        let hasAnyFootwear = wardrobe.contains { $0.category == .footwear }
        let hasAnyBottom   = wardrobe.contains { $0.category == .bottoms }
        let hasAnyUpper    = wardrobe.contains { upperBaseCategories.contains($0.category) }

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
            if fixed.items.count != outfit.items.count { repairedCount += 1 }

            let key = dedupKey(fixed)
            if seen.contains(key) { dupCount += 1; continue }
            seen.insert(key)
            result.append(fixed)
        }

        print("[OutfitValidator] in=\(outfits.count) out=\(result.count) repaired=\(repairedCount) dropped=\(droppedCount) dupes=\(dupCount)")
        return result
    }

    // MARK: - Per-outfit repair

    private static func repair(_ outfit: Outfit, wardrobe: [WardrobeItem],
                               requireUpper: Bool, requireBottom: Bool, requireFootwear: Bool) -> Outfit? {
        // 1) Strip impossible doubles (keep the first of each singleton category).
        var items = dropImpossibleDoubles(outfit.items)

        // 1b) A one-piece (dress/jumpsuit) already covers the lower body — a separate
        // bottom alongside it is invalid, so drop any bottoms when a one-piece exists.
        if items.contains(where: { $0.category == .onePieces }) {
            items.removeAll { $0.category == .bottoms }
        }

        var usedIDs = Set(items.map { $0.id })

        // 2) Upper base (skip if a one-piece is present — it covers the torso).
        let hasOnePiece = items.contains { $0.category == .onePieces }
        if requireUpper, !hasOnePiece, !items.contains(where: { upperBaseCategories.contains($0.category) }) {
            guard let top = pickNeutral(.tops, from: wardrobe, excluding: usedIDs) else { return nil }
            items.append(top); usedIDs.insert(top.id)
        }

        // 3) Lower (skip if a one-piece covers it).
        let hasOnePieceNow = items.contains { $0.category == .onePieces }
        if requireBottom, !hasOnePieceNow, !items.contains(where: { $0.category == .bottoms }) {
            guard let bottom = pickNeutral(.bottoms, from: wardrobe, excluding: usedIDs) else { return nil }
            items.append(bottom); usedIDs.insert(bottom.id)
        }

        // 4) Footwear.
        if requireFootwear, !items.contains(where: { $0.category == .footwear }) {
            guard let shoe = pickNeutral(.footwear, from: wardrobe, excluding: usedIDs) else { return nil }
            items.append(shoe); usedIDs.insert(shoe.id)
        }

        return Outfit(items: items, explanation: outfit.explanation)
    }

    /// Keep at most one bottom / footwear / one-piece (two pants is not an outfit).
    private static func dropImpossibleDoubles(_ items: [WardrobeItem]) -> [WardrobeItem] {
        var seenSingleton = Set<Category>()
        var out: [WardrobeItem] = []
        for item in items {
            if singletonCategories.contains(item.category) {
                if seenSingleton.contains(item.category) { continue }
                seenSingleton.insert(item.category)
            }
            out.append(item)
        }
        return out
    }

    /// Pick the most "safe to drop in" item of a category: prefer neutral colors and
    /// solid patterns so a repaired piece doesn't clash with the rest of the look.
    private static func pickNeutral(_ category: Category, from wardrobe: [WardrobeItem], excluding: Set<UUID>) -> WardrobeItem? {
        let candidates = wardrobe.filter { $0.category == category && !excluding.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        return candidates.max { score($0) < score($1) }
    }

    private static func score(_ item: WardrobeItem) -> Int {
        var s = 0
        if item.colors.contains(where: { neutralColors.contains($0.lowercased()) }) { s += 2 }
        if item.pattern == .solid { s += 1 }
        return s
    }

    private static func dedupKey(_ outfit: Outfit) -> String {
        outfit.items
            .filter { !coreRoleExclusions.contains($0.category) }   // ignore accessories
            .map { $0.id.uuidString }
            .sorted()
            .joined(separator: "|")
    }
}
