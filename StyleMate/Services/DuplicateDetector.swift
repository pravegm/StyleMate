import UIKit

struct DuplicateMatch {
    let existingItem: WardrobeItem
    let score: Int
}

/// Decides whether a newly-detected garment is the same physical item as one
/// already in the wardrobe (to avoid cataloguing it twice during a scan).
///
/// Design: two garments are duplicates only if they could plausibly be the SAME
/// physical item. That is a set of HARD requirements, not a soft point tally —
/// the previous additive-only scorer flagged a blue shirt and a white shirt as
/// duplicates because identical type/material/cut alone cleared the threshold
/// while a total color mismatch only "lost points". Color, product type, pattern
/// and (visible) brand are now gates: fail any one and it is not a duplicate.
/// The remaining attributes are scored only to rank candidates and apply a final
/// confidence threshold.
class DuplicateDetector {

    static let shared = DuplicateDetector()
    private init() {}

    private static let matchThreshold = 55

    // MARK: - Public API

    /// Returns the best matching existing item if it clears the threshold, else nil.
    func findBestMatch(
        category: Category,
        product: String,
        colors: [String],
        pattern: Pattern,
        material: String?,
        fit: Fit?,
        neckline: Neckline?,
        sleeveLength: SleeveLength?,
        brand: String = "",
        existingItems: [WardrobeItem]
    ) -> DuplicateMatch? {
        var bestMatch: WardrobeItem?
        var bestScore = 0

        for existing in existingItems {
            let score = computeScore(
                newCategory: category, newProduct: product, newColors: colors,
                newPattern: pattern, newMaterial: material, newFit: fit,
                newNeckline: neckline, newSleeveLength: sleeveLength, newBrand: brand,
                existing: existing
            )
            if score > bestScore {
                bestScore = score
                bestMatch = existing
            }
        }

        guard let match = bestMatch, bestScore >= Self.matchThreshold else { return nil }
        return DuplicateMatch(existingItem: match, score: bestScore)
    }

    // MARK: - Scoring (gated)

    private func computeScore(
        newCategory: Category, newProduct: String, newColors: [String],
        newPattern: Pattern, newMaterial: String?, newFit: Fit?,
        newNeckline: Neckline?, newSleeveLength: SleeveLength?, newBrand: String,
        existing: WardrobeItem
    ) -> Int {
        // --- HARD GATES: must plausibly be the same physical item ---

        // 1. Same category.
        guard newCategory == existing.category else { return 0 }

        // 2. Same product type (or a genuine label-synonym, e.g. Shirt/Button-Down).
        let pScore = productScore(newProduct, existing.product)
        guard pScore > 0 else { return 0 }

        // 3. Same pattern — a solid item and a floral/striped item are different.
        guard newPattern == existing.pattern else { return 0 }

        // 4. Clearly shared dominant color — THE key fix. Different colors (blue vs
        //    white) means different items even if everything else matches.
        let cScore = colorScore(newColors, existing.colors)
        guard cScore >= 15 else { return 0 }

        // 5. Conflicting visible brands => different physical items.
        let nb = newBrand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let eb = existing.brand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !nb.isEmpty, !eb.isEmpty, nb != eb { return 0 }

        // --- Gates passed: score confirming attributes to rank candidates ---
        var score = pScore + cScore                                   // 35..55
        score += materialScore(newMaterial, existing.material)        // 0..15
        score += necklineScore(newNeckline, existing.neckline)        // 0/3/10

        if let newFit, let existingFit = existing.fit {
            score += (newFit == existingFit) ? 5 : 0
        } else {
            score += 3
        }

        if let newSleeveLength, let existingSleeve = existing.sleeveLength {
            score += (newSleeveLength == existingSleeve) ? 5 : 0
        } else {
            score += 3
        }

        return score
    }

    // MARK: - Product (exact 30 / synonym 20 / else 0)

    private func productScore(_ a: String, _ b: String) -> Int {
        let la = a.lowercased()
        let lb = b.lowercased()

        if la == lb { return 30 }

        // ONLY genuine label-synonyms: cases where the classifier could legitimately
        // tag the SAME physical item with either name. NOT broad category groupings
        // (a ring and a necklace, or a backpack and a tote, are different items).
        let synonymGroups: [[String]] = [
            ["shirts", "button-down shirts", "flannel shirts"],
            ["sweaters", "pullovers"],
            ["t-shirts", "graphic tees"],
            ["hoodies", "sweatshirts"],
            ["joggers", "sweatpants"],
            ["trousers", "chinos"],
            ["boots", "ankle boots", "chelsea boots"],
            ["sandals", "slides"],
            ["coats", "overcoats"],
            ["kurta", "kurti"],
        ]

        for group in synonymGroups where group.contains(la) && group.contains(lb) {
            return 20
        }

        return 0
    }

    // MARK: - Color (max 25)

    private func colorScore(_ a: [String], _ b: [String]) -> Int {
        let normalizedA = Set(a.map { normalizeColor($0) })
        let normalizedB = Set(b.map { normalizeColor($0) })

        guard !normalizedA.isEmpty && !normalizedB.isEmpty else { return 5 }

        if normalizedA == normalizedB { return 25 }

        let intersection = normalizedA.intersection(normalizedB)
        let union = normalizedA.union(normalizedB)
        let overlap = Double(intersection.count) / Double(union.count)

        if overlap >= 0.5 {
            return 15
        } else if !intersection.isEmpty {
            return 5
        }

        return 0
    }

    private func normalizeColor(_ color: String) -> String {
        let lower = color.lowercased().trimmingCharacters(in: .whitespaces)

        let familyMap: [String: String] = [
            "navy": "blue", "cobalt": "blue", "royal blue": "blue",
            "sky blue": "blue", "baby blue": "blue", "denim blue": "blue",
            "indigo": "blue", "steel blue": "blue",
            "maroon": "red", "burgundy": "red", "crimson": "red",
            "wine": "red", "scarlet": "red", "rust": "red",
            "olive": "green", "sage": "green", "emerald": "green",
            "forest green": "green", "mint": "green", "lime": "green",
            "khaki": "green",
            "cream": "white", "ivory": "white", "off-white": "white",
            "eggshell": "white", "pearl": "white",
            "charcoal": "gray", "grey": "gray", "silver": "gray",
            "slate": "gray", "ash": "gray",
            "tan": "brown", "beige": "brown", "camel": "brown",
            "cognac": "brown", "chocolate": "brown", "taupe": "brown",
            "coffee": "brown", "sand": "brown", "nude": "brown",
            "magenta": "pink", "fuchsia": "pink", "rose": "pink",
            "blush": "pink", "coral": "pink", "salmon": "pink",
            "violet": "purple", "lavender": "purple", "plum": "purple",
            "mauve": "purple", "lilac": "purple",
            "gold": "yellow", "mustard": "yellow", "amber": "yellow",
            "lemon": "yellow",
            "peach": "orange", "terracotta": "orange", "copper": "orange",
        ]

        return familyMap[lower] ?? lower
    }

    // MARK: - Material (max 15)

    private func materialScore(_ a: String?, _ b: String?) -> Int {
        guard let a, !a.isEmpty, let b, !b.isEmpty else { return 5 }

        let la = a.lowercased()
        let lb = b.lowercased()

        if la == lb { return 15 }

        let materialFamilies: [[String]] = [
            ["wool", "wool knit", "knit", "cable knit", "merino", "cashmere"],
            ["cotton", "cotton jersey", "jersey", "cotton knit"],
            ["denim", "chambray"],
            ["leather", "suede", "faux leather"],
            ["silk", "satin", "charmeuse"],
            ["linen", "linen blend"],
            ["polyester", "nylon", "synthetic", "poly blend"],
            ["fleece", "sherpa"],
            ["velvet", "velour"],
            ["chiffon", "organza", "tulle"],
            ["mesh", "net"],
            ["corduroy", "cord"],
            ["tweed", "herringbone"],
        ]

        for family in materialFamilies {
            let aInFamily = family.contains { la.contains($0) || $0.contains(la) }
            let bInFamily = family.contains { lb.contains($0) || $0.contains(lb) }
            if aInFamily && bInFamily {
                return 10
            }
        }

        return 0
    }

    // MARK: - Neckline (max 10)

    private func necklineScore(_ a: Neckline?, _ b: Neckline?) -> Int {
        guard let a, let b else { return 3 }
        return (a == b) ? 10 : 0
    }
}
