import Foundation

/// The one singulariser for catalogue product names ("Scarves" → "Scarf"). The catalogue
/// stores plurals (`productTypesByCategory`); every place that names ONE piece goes through
/// here: the closet's titles and chips (`ClosetText`), `WardrobeItem.name`, the stylist notes
/// and the studio prompt. Only the last word changes ("Tennis Dresses" → "Tennis Dress").
enum ProductNoun {
    /// Words that stay plural for a single item ("a pair of jeans").
    static let pluralOnly: Set<String> = [
        "jeans", "shorts", "trousers", "sunglasses", "eyeglasses", "glasses", "chinos", "capris",
        "culottes", "slides", "flats", "heels", "leggings", "pants", "sweatpants", "joggers",
        "boxers", "briefs", "overalls", "dungarees", "tights", "trunks", "suspenders", "espadrilles"
    ]

    /// Shoes, which the studio prompt keeps plural ("white sneakers"); the closet names one.
    static let footwearPairs: Set<String> = [
        "sneakers", "boots", "sandals", "loafers", "mules", "clogs", "slippers", "shoes"
    ]

    /// Plurals the suffix rules get wrong.
    static let irregular: [String: String] = [
        "scarves": "scarf",
        "accessories": "accessory"
    ]

    /// Singular form of a catalogue product name: "Watches" → "Watch", "Dresses" → "Dress",
    /// "Scarves" → "Scarf", "T-Shirts" → "T-Shirt", but "Jeans" and "Yoga Pants" stay.
    /// `keepingPairs` also keeps shoes plural.
    static func singular(_ product: String, keepingPairs: Bool = false) -> String {
        let trimmed = product.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.split(separator: " ").last.map(String.init) else { return trimmed }
        let lower = last.lowercased()
        if pluralOnly.contains(lower) || (keepingPairs && footwearPairs.contains(lower)) { return trimmed }
        if let fixed = irregular[lower] {
            let word = last.first?.isUppercase == true ? fixed.prefix(1).uppercased() + fixed.dropFirst() : fixed
            return String(trimmed.dropLast(last.count)) + word
        }
        if !lower.hasSuffix("s") || lower.hasSuffix("ss") || last.count <= 3 { return trimmed }
        let drop = ["ches", "shes", "sses", "xes"].contains { lower.hasSuffix($0) } ? 2 : 1
        return String(trimmed.dropLast(drop))
    }

    /// Singular of one lowercased word, for matching search text against item names (both
    /// sides go through it, so "scarves" finds a scarf). Unlike `singular`, "jeans" → "jean".
    static func singularWord(_ w: String) -> String {
        if let fixed = irregular[w] { return fixed }
        guard w.count > 3 else { return w }
        for suffix in ["ches", "shes", "sses", "xes"] where w.hasSuffix(suffix) {
            return String(w.dropLast(2))
        }
        if w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }
}
