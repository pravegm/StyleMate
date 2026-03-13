import UIKit

struct DuplicateMatch {
    let existingItem: WardrobeItem
    let score: Int
}

class DuplicateDetector {

    static let shared = DuplicateDetector()
    private init() {}

    // MARK: - Public API

    /// Returns the best matching existing item if score >= 60, otherwise nil.
    func findBestMatch(
        category: Category,
        product: String,
        colors: [String],
        pattern: Pattern,
        material: String?,
        fit: Fit?,
        neckline: Neckline?,
        sleeveLength: SleeveLength?,
        existingItems: [WardrobeItem]
    ) -> DuplicateMatch? {
        var bestMatch: WardrobeItem?
        var bestScore = 0

        for existing in existingItems {
            let score = computeScore(
                newCategory: category, newProduct: product, newColors: colors,
                newPattern: pattern, newMaterial: material, newFit: fit,
                newNeckline: neckline, newSleeveLength: sleeveLength,
                existing: existing
            )
            if score > bestScore {
                bestScore = score
                bestMatch = existing
            }
        }

        guard let match = bestMatch, bestScore >= 60 else { return nil }

        return DuplicateMatch(existingItem: match, score: bestScore)
    }

    // MARK: - Scoring (max 95)

    private func computeScore(
        newCategory: Category, newProduct: String, newColors: [String],
        newPattern: Pattern, newMaterial: String?, newFit: Fit?,
        newNeckline: Neckline?, newSleeveLength: SleeveLength?,
        existing: WardrobeItem
    ) -> Int {
        guard newCategory == existing.category else { return 0 }

        var score = 0

        score += productScore(newProduct, existing.product)
        score += colorScore(newColors, existing.colors)
        score += materialScore(newMaterial, existing.material)
        score += necklineScore(newNeckline, existing.neckline)

        if let newFit, let existingFit = existing.fit {
            score += (newFit == existingFit) ? 5 : 0
        } else {
            score += 3
        }

        score += (newPattern == existing.pattern) ? 5 : 0

        if let newSleeveLength, let existingSleeve = existing.sleeveLength {
            score += (newSleeveLength == existingSleeve) ? 5 : 0
        } else {
            score += 3
        }

        return score
    }

    // MARK: - Product (max 30)

    private func productScore(_ a: String, _ b: String) -> Int {
        let la = a.lowercased()
        let lb = b.lowercased()

        if la == lb { return 30 }

        let equivalenceGroups: [[String]] = [
            ["sweaters", "pullovers"],
            ["shirts", "button-down shirts"],
            ["joggers", "sweatpants"],
            ["trousers", "chinos"],
            ["leggings", "active leggings", "yoga pants"],
            ["t-shirts", "graphic tees"],
            ["tank tops", "camisoles"],
            ["boots", "ankle boots", "chelsea boots"],
            ["sandals", "slides"],
            ["flats", "loafers"],
            ["heels", "platform shoes"],
            ["dresses", "wrap dresses", "maxi dresses", "shirt dresses"],
            ["jackets", "leather jackets", "denim jackets", "bomber jackets", "shirt jackets"],
            ["coats", "overcoats", "trench coats"],
            ["handbags", "tote bags", "crossbody bags", "clutches"],
            ["backpacks", "messenger bags", "briefcases"],
            ["underwear", "boxers", "briefs"],
            ["bras", "bralettes"],
            ["kurta", "kurti"],
            ["shorts", "athletic shorts", "running shorts", "cycling shorts"],
            ["sunglasses", "eyeglasses", "reading glasses"],
            ["baseball caps", "beanies", "fedoras", "bucket hats", "sun hats", "visors", "berets"],
            ["rings", "necklaces", "earrings", "pendants", "chains", "bracelets", "anklets", "cufflinks", "brooches"],
            ["scarves", "bandanas"],
            ["fanny packs"],
        ]

        for group in equivalenceGroups {
            let groupLower = group.map { $0.lowercased() }
            if groupLower.contains(la) && groupLower.contains(lb) {
                return 20
            }
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

        if overlap > 0.5 {
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
