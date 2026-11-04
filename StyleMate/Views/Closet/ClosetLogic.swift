import Foundation

// MARK: - Closet logic (pure, unit-tested in ClosetTests)
//
// Everything the closet screen decides — which shelf an item sits on, what a
// filter or search keeps, how a sort orders things, wear counts from the outfit
// log, and which attribute chips an item shows — lives here as plain functions
// so it can be tested without SwiftUI.

/// The shelves of the closet, in display order. Mapped from `Category` plus the
/// product name, so bags and jewelry get their own shelves out of the broad
/// "Accessories" category and activewear / ethnic wear / innerwear land on the
/// shelf a person would look for them on.
enum ClosetSection: String, CaseIterable, Identifiable, Hashable {
    case tops
    case bottoms
    case dresses
    case footwear
    case bags
    case accessories
    case jewelry

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tops:        return "Tops & layers"
        case .bottoms:     return "Bottoms"
        case .dresses:     return "Dresses & one-pieces"
        case .footwear:    return "Footwear"
        case .bags:        return "Bags"
        case .accessories: return "Accessories"
        case .jewelry:     return "Jewelry"
        }
    }

    /// Short label for filter chips.
    var chipTitle: String {
        switch self {
        case .tops:        return "Tops"
        case .bottoms:     return "Bottoms"
        case .dresses:     return "Dresses"
        case .footwear:    return "Footwear"
        case .bags:        return "Bags"
        case .accessories: return "Accessories"
        case .jewelry:     return "Jewelry"
        }
    }

    var iconName: String {
        switch self {
        case .tops:        return "tshirt"
        case .bottoms:     return "figure.walk"
        case .dresses:     return "figure.dress.line.vertical.figure"
        case .footwear:    return "shoe"
        case .bags:        return "bag"
        case .accessories: return "eyeglasses"
        case .jewelry:     return "sparkles"
        }
    }

    static func of(_ item: WardrobeItem) -> ClosetSection {
        of(category: item.category, product: item.product)
    }

    static func of(category: Category, product: String) -> ClosetSection {
        let words = ClosetText.words(product)
        func has(_ set: Set<String>) -> Bool { !words.isDisjoint(with: set) }

        switch category {
        case .tops, .midLayers, .outerwear:
            return .tops
        case .bottoms:
            return .bottoms
        case .onePieces:
            return .dresses
        case .footwear:
            return .footwear
        case .accessories:
            if has(bagWords) { return .bags }
            if has(jewelryWords) { return .jewelry }
            return .accessories
        case .innerwear:
            if has(["sock"]) { return .footwear }
            if has(["underwear", "boxer", "brief", "thong", "trunk"]) { return .bottoms }
            return .tops
        case .activewear:
            if has(["dress", "swimwear", "swimsuit", "leotard", "unitard"]) { return .dresses }
            if has(bottomWords) { return .bottoms }
            return .tops
        case .ethnicWear:
            if has(["blouse", "choli", "kurta", "kurti"]) { return .tops }
            if has(["saree", "sari", "anarkali", "gown"]) { return .dresses }
            if has(["dhoti", "lungi", "mundu", "salwar", "patiala", "churidar", "sharara",
                    "ghagra", "lehenga", "pant", "skirt"]) { return .bottoms }
            if has(["dupatta", "stole", "shawl", "turban", "pagri"]) { return .accessories }
            return .tops
        }
    }

    private static let bagWords: Set<String> = [
        "bag", "handbag", "tote", "clutch", "backpack", "wallet", "purse", "briefcase",
        "satchel", "pack", "duffel", "duffle", "pouch", "crossbody"
    ]
    private static let jewelryWords: Set<String> = [
        "ring", "earring", "necklace", "pendant", "chain", "anklet", "cufflink", "brooch",
        "bracelet", "bangle", "watch", "jewelry", "jewellery", "choker", "stud", "locket"
    ]
    private static let bottomWords: Set<String> = [
        "short", "pant", "legging", "trouser", "jogger", "trunk", "skirt", "skort", "tight"
    ]
}

// MARK: - Text helpers

enum ClosetText {
    /// Lower-cased, singularised words of a string: "Crossbody Bags" → {crossbody, bag},
    /// "Watches" → {watch}. Used for product mapping and search.
    static func words(_ text: String) -> Set<String> {
        Set(wordList(text))
    }

    static func wordList(_ text: String) -> [String] {
        text.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { singular(String($0)) }
    }

    /// Words that stay plural for a single item ("a pair of jeans").
    private static let pluralOnly: Set<String> = [
        "jeans", "shorts", "trousers", "sunglasses", "eyeglasses", "glasses", "chinos", "capris",
        "culottes", "slides", "flats", "heels", "leggings", "pants", "sweatpants", "joggers",
        "boxers", "briefs", "overalls", "dungarees", "tights", "trunks", "suspenders", "espadrilles"
    ]

    /// Singular display form of a product name: "Watches" → "Watch", "Dresses" →
    /// "Dress", "T-Shirts" → "T-Shirt", but "Jeans" and "Yoga Pants" stay.
    /// (`WardrobeItem.displayProduct` just drops a trailing "s", giving "Watche".)
    static func displayProduct(_ product: String) -> String {
        let trimmed = product.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.split(separator: " ").last.map(String.init) else { return trimmed }
        let lower = last.lowercased()
        if pluralOnly.contains(lower) || !lower.hasSuffix("s") || lower.hasSuffix("ss") || last.count <= 3 {
            return trimmed
        }
        let drop = ["ches", "shes", "sses", "xes"].contains { lower.hasSuffix($0) } ? 2 : 1
        return String(trimmed.dropLast(drop))
    }

    /// `item.name` with its product word in the proper singular form.
    static func displayName(_ item: WardrobeItem) -> String {
        let name = item.name
        let rough = item.displayProduct
        let good = displayProduct(item.product)
        guard rough != good, name.hasSuffix(rough) else { return name }
        return String(name.dropLast(rough.count)) + good
    }

    static func singular(_ w: String) -> String {
        guard w.count > 3 else { return w }
        for suffix in ["ches", "shes", "sses", "xes"] where w.hasSuffix(suffix) {
            return String(w.dropLast(2))
        }
        if w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }
}

// MARK: - Colors

enum ClosetColor {
    /// The on-device colour namer's palette (FashionClassifier), in a pleasing
    /// spectrum order: neutrals, earth tones, warm, greens, blues, purples, reds.
    static let order: [String] = [
        "Black", "Charcoal", "Gray", "Silver", "White", "Cream", "Beige", "Tan", "Khaki",
        "Brown", "Rust", "Orange", "Gold", "Yellow", "Olive", "Green", "Mint", "Teal",
        "Light Blue", "Blue", "Navy", "Lavender", "Purple", "Pink", "Coral", "Red",
        "Burgundy", "Maroon"
    ]
    private static let rankByName: [String: Int] = {
        var d: [String: Int] = [:]
        for (i, n) in order.enumerated() { d[n.lowercased()] = i }
        return d
    }()

    /// Canonical display form: trimmed, title-cased, "Grey" → "Gray".
    static func normalize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let fixed = trimmed.replacingOccurrences(of: "grey", with: "gray", options: .caseInsensitive)
        return fixed.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    /// Position in the spectrum; unknown names fall back to their last word
    /// ("Dark Green" → Green), then sort after every known colour.
    static func rank(_ name: String) -> Int {
        let n = normalize(name).lowercased()
        if let r = rankByName[n] { return r }
        if let last = n.split(separator: " ").last, let r = rankByName[String(last)] { return r }
        return order.count
    }

    /// Distinct colours across the items, in spectrum order (for the swatch row).
    static func swatches(for items: [WardrobeItem]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items {
            for c in item.colors {
                let n = normalize(c)
                guard !n.isEmpty, seen.insert(n).inserted else { continue }
                out.append(n)
            }
        }
        return out.sorted { (rank($0), $0) < (rank($1), $1) }
    }
}

// MARK: - Wear stats

struct WearStat: Equatable {
    var count: Int
    var lastWorn: Date?
}

enum ClosetWear {
    /// One entry per logged outfit: its date and the wardrobe item ids in it.
    typealias Log = (date: Date, itemIDs: [UUID])

    /// Times each item was worn (once per logged outfit) and when it was last worn.
    static func stats(from logs: [Log]) -> [UUID: WearStat] {
        var out: [UUID: WearStat] = [:]
        for log in logs {
            for id in Set(log.itemIDs) {
                var s = out[id] ?? WearStat(count: 0, lastWorn: nil)
                s.count += 1
                if s.lastWorn.map({ log.date > $0 }) ?? true { s.lastWorn = log.date }
                out[id] = s
            }
        }
        return out
    }
}

// MARK: - Sort

enum ClosetSort: String, CaseIterable, Identifiable {
    case newest, oldest, color, mostWorn, leastWorn, recentlyWorn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest:       return "Newest"
        case .oldest:       return "Oldest"
        case .color:        return "Color"
        case .mostWorn:     return "Most worn"
        case .leastWorn:    return "Least worn"
        case .recentlyWorn: return "Recently worn"
        }
    }

    var iconName: String {
        switch self {
        case .newest:       return "clock"
        case .oldest:       return "clock.arrow.circlepath"
        case .color:        return "paintpalette"
        case .mostWorn:     return "flame"
        case .leastWorn:    return "moon.zzz"
        case .recentlyWorn: return "calendar"
        }
    }

    var usesWearLog: Bool { [.mostWorn, .leastWorn, .recentlyWorn].contains(self) }
}

// MARK: - Filter

struct ClosetFilter: Equatable {
    var section: ClosetSection? = nil
    /// Normalised colour names; an item matches if it has any of them.
    var colors: Set<String> = []
    var patterns: Set<Pattern> = []
    var query: String = ""

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isActive: Bool {
        section != nil || !colors.isEmpty || !patterns.isEmpty || !trimmedQuery.isEmpty
    }

    /// Facet filters only (section / colour / pattern), ignoring the search text.
    var hasFacets: Bool { section != nil || !colors.isEmpty || !patterns.isEmpty }

    func matches(_ item: WardrobeItem) -> Bool {
        if let section, ClosetSection.of(item) != section { return false }
        if !colors.isEmpty, !item.colors.contains(where: { colors.contains(ClosetColor.normalize($0)) }) {
            return false
        }
        if !patterns.isEmpty, !patterns.contains(item.pattern) { return false }
        return ClosetSearch.matches(item, query: trimmedQuery)
    }
}

enum ClosetSearch {
    /// Every query word must be the start of some word in the item's name,
    /// product, shelf, category, colours, brand, material, pattern or details —
    /// so "red" finds red items but not "embroidered" ones, and "light blue
    /// denim" narrows as you type.
    static func matches(_ item: WardrobeItem, query: String) -> Bool {
        let terms = ClosetText.wordList(query)
        guard !terms.isEmpty else { return true }
        let haystack = searchWords(for: item)
        return terms.allSatisfy { term in haystack.contains { $0.hasPrefix(term) } }
    }

    static func searchWords(for item: WardrobeItem) -> Set<String> {
        var fields: [String] = [item.name, item.product, item.category.rawValue,
                                ClosetSection.of(item).title, item.brand, item.pattern.rawValue]
        fields.append(contentsOf: item.colors)
        if let m = item.material { fields.append(m) }
        if let d = item.details { fields.append(d) }
        // Raw lower-cased words too, so plural queries ("jeans") still match.
        var out = Set<String>()
        for f in fields {
            out.formUnion(ClosetText.wordList(f))
            out.formUnion(f.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        return out
    }
}

// MARK: - Engine

struct ClosetGroup: Identifiable, Equatable {
    let section: ClosetSection
    let items: [WardrobeItem]
    var id: ClosetSection { section }
}

enum ClosetEngine {
    /// Filters then sorts. `items` must be in wardrobe order (oldest first — the
    /// wardrobe only ever appends), which is what "Newest" / "Oldest" use.
    static func apply(_ items: [WardrobeItem], filter: ClosetFilter, sort: ClosetSort,
                      wear: [UUID: WearStat] = [:]) -> [WardrobeItem] {
        let kept = items.enumerated().filter { filter.matches($0.element) }
        func count(_ i: WardrobeItem) -> Int { wear[i.id]?.count ?? 0 }
        func last(_ i: WardrobeItem) -> Date? { wear[i.id]?.lastWorn }

        let sorted = kept.sorted { a, b in
            let x = a.element, y = b.element
            let newer = a.offset > b.offset
            switch sort {
            case .newest:
                return newer
            case .oldest:
                return a.offset < b.offset
            case .color:
                let kx = colorKey(x), ky = colorKey(y)
                if kx != ky { return kx.lexicographicallyPrecedes(ky) }
                return newer
            case .mostWorn:
                if count(x) != count(y) { return count(x) > count(y) }
                if last(x) != last(y) { return (last(x) ?? .distantPast) > (last(y) ?? .distantPast) }
                return newer
            case .leastWorn:
                if count(x) != count(y) { return count(x) < count(y) }
                if last(x) != last(y) { return (last(x) ?? .distantPast) < (last(y) ?? .distantPast) }
                return newer
            case .recentlyWorn:
                switch (last(x), last(y)) {
                case let (dx?, dy?) where dx != dy: return dx > dy
                case (nil, _?): return false                 // never-worn sink to the end
                case (_?, nil): return true
                default: return newer
                }
            }
        }
        return sorted.map(\.element)
    }

    /// Items grouped onto shelves in shelf order, keeping each shelf's item order.
    static func grouped(_ items: [WardrobeItem]) -> [ClosetGroup] {
        var buckets: [ClosetSection: [WardrobeItem]] = [:]
        for item in items { buckets[ClosetSection.of(item), default: []].append(item) }
        return ClosetSection.allCases.compactMap { s in
            guard let list = buckets[s], !list.isEmpty else { return nil }
            return ClosetGroup(section: s, items: list)
        }
    }

    static func counts(_ items: [WardrobeItem]) -> [ClosetSection: Int] {
        var out: [ClosetSection: Int] = [:]
        for item in items { out[ClosetSection.of(item), default: 0] += 1 }
        return out
    }

    /// Patterns that occur in the wardrobe, in enum order.
    static func patterns(in items: [WardrobeItem]) -> [Pattern] {
        let present = Set(items.map(\.pattern))
        return Pattern.allCases.filter { present.contains($0) }
    }

    private static func colorKey(_ item: WardrobeItem) -> [Int] {
        let ranks = item.colors.map(ClosetColor.rank)
        return ranks.isEmpty ? [Int.max] : ranks
    }
}

// MARK: - Attribute chips

struct ClosetAttribute: Hashable, Identifiable {
    let label: String
    let value: String
    let icon: String
    var id: String { label }
}

enum ClosetAttributes {
    /// The tidy attribute chips shown on an item's detail page, in reading order.
    /// Garment-only attributes are gated by the category (no "Sleeve" on a watch).
    static func chips(for item: WardrobeItem) -> [ClosetAttribute] {
        var out: [ClosetAttribute] = [
            ClosetAttribute(label: "Category", value: item.category.rawValue, icon: "square.grid.2x2"),
            ClosetAttribute(label: "Type", value: ClosetText.displayProduct(item.product), icon: "tag"),
            ClosetAttribute(label: "Pattern", value: item.pattern.rawValue, icon: "circle.hexagongrid"),
        ]
        if let m = item.material?.trimmingCharacters(in: .whitespaces), !m.isEmpty {
            out.append(ClosetAttribute(label: "Material", value: m, icon: "scribble.variable"))
        }
        if let fit = item.fit, item.category.supportsFit {
            out.append(ClosetAttribute(label: "Fit", value: fit.rawValue, icon: "ruler"))
        }
        if let sleeve = item.sleeveLength, item.category.supportsSleeves {
            out.append(ClosetAttribute(label: "Sleeve", value: sleeve.rawValue, icon: "hand.raised"))
        }
        if let neck = item.neckline, item.category.supportsNeckline {
            out.append(ClosetAttribute(label: "Neckline", value: neck.rawValue, icon: "person.crop.circle"))
        }
        if let length = item.garmentLength, item.category.supportsLength {
            out.append(ClosetAttribute(label: "Length", value: length.rawValue, icon: "arrow.up.and.down"))
        }
        let brand = item.brand.trimmingCharacters(in: .whitespaces)
        if !brand.isEmpty {
            out.append(ClosetAttribute(label: "Brand", value: brand, icon: "seal"))
        }
        return out
    }

    /// "Worn 3 times · last on 12 Oct" / "Not worn yet".
    static func wearSummary(_ stat: WearStat?, now: Date = Date()) -> String {
        guard let stat, stat.count > 0 else { return "Not logged in an outfit yet" }
        let times = stat.count == 1 ? "Worn once" : "Worn \(stat.count) times"
        guard let last = stat.lastWorn else { return times }
        let f = DateFormatter()
        f.locale = Locale.current
        let sameYear = Calendar.current.isDate(last, equalTo: now, toGranularity: .year)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "d MMM" : "d MMM yyyy")
        return "\(times) · last on \(f.string(from: last))"
    }
}
