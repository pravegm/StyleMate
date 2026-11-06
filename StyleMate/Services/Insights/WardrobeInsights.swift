import Foundation

/// The single switch for Wardrobe insights. Everyone has it today; making it a Premium perk is
/// a one-line change here: `static var isAvailable: Bool { PremiumStore.shared.isPremium }`
/// (Profile then shows the row with a Premium badge that opens the paywall).
enum InsightsAvailability {
    static var isAvailable: Bool { true }
}

// MARK: - Wardrobe insights (pure, unit-tested in WardrobeInsightsTests)
//
// What the closet and the outfit log say together: what gets worn, what doesn't, what's
// new, the colour and shelf balance, and near-duplicates ("You have 9 black tees"). Built
// on the phone from the wardrobe and the outfit calendar; nothing is sent anywhere.
// There is no price field on an item, so there is no cost-per-wear.

struct WardrobeInsights: Equatable {
    /// "Not worn in 60 days".
    static let windowDays = 60

    struct Worn: Identifiable, Equatable {
        let item: WardrobeItem
        let count: Int
        let lastWorn: Date?
        var id: UUID { item.id }
    }

    struct Share: Identifiable, Equatable {
        let name: String
        let count: Int
        let fraction: Double
        var id: String { name }
    }

    struct Shelf: Identifiable, Equatable {
        let section: ClosetSection
        let count: Int
        let fraction: Double
        var id: ClosetSection { section }
    }

    struct Duplicate: Identifiable, Equatable {
        /// "You have 9 black tees".
        let title: String
        let items: [WardrobeItem]
        var id: String { title }
    }

    var total: Int
    /// Up to six, most worn first (only pieces worn at least once).
    var mostWorn: [Worn]
    /// Pieces with no logged wear in the window, never-worn and longest-unworn first.
    var notWorn: [WardrobeItem]
    /// Pieces worn at least once in the window.
    var wornInWindow: Int
    /// The first logged outfit, if any.
    var logStart: Date?
    /// The log reaches back the whole window, so "not worn in 60 days" is literally true.
    var logCoversWindow: Bool
    /// The newest pieces (the wardrobe only ever appends), newest first.
    var recent: [WardrobeItem]
    /// Lead colours, biggest first; anything past the sixth folds into "Other".
    var colours: [Share]
    /// Share of pieces whose lead colour is a neutral (black, white, grey, navy, beige, denim…).
    var neutralShare: Double
    var shelves: [Shelf]
    /// "About 3 tops for every bottom", when the core is lopsided.
    var balanceNote: String?
    /// Three or more of the same colour and kind, biggest first.
    var duplicates: [Duplicate]

    var hasWearLog: Bool { logStart != nil }
    var wornShare: Double { total == 0 ? 0 : Double(wornInWindow) / Double(total) }

    static func compute(items: [WardrobeItem], logs: [ClosetWear.Log], now: Date = Date(),
                        calendar: Calendar = .current) -> WardrobeInsights {
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: today) ?? today
        // Planned (future-dated) outfits don't count as worn.
        let past = logs.filter { calendar.startOfDay(for: $0.date) <= today }
        let stats = ClosetWear.stats(from: past)
        let logStart = past.map { calendar.startOfDay(for: $0.date) }.min()

        // Most worn.
        let order = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let worn = items.compactMap { item -> Worn? in
            guard let s = stats[item.id], s.count > 0 else { return nil }
            return Worn(item: item, count: s.count, lastWorn: s.lastWorn)
        }
        let mostWorn = worn.sorted { a, b in
            if a.count != b.count { return a.count > b.count }
            if a.lastWorn != b.lastWorn { return (a.lastWorn ?? .distantPast) > (b.lastWorn ?? .distantPast) }
            return (order[a.item.id] ?? 0) < (order[b.item.id] ?? 0)
        }

        // Not worn in the window: never worn first, then the longest since.
        func lastWorn(_ item: WardrobeItem) -> Date? { stats[item.id]?.lastWorn }
        let notWorn = items.filter { item in
            guard let last = lastWorn(item) else { return true }
            return calendar.startOfDay(for: last) < windowStart
        }.sorted { a, b in
            switch (lastWorn(a), lastWorn(b)) {
            case (nil, _?): return true
            case (_?, nil): return false
            case let (x?, y?) where x != y: return x < y
            default: return (order[a.id] ?? 0) < (order[b.id] ?? 0)
            }
        }

        // Colours (lead colour per piece).
        var colourCounts: [String: Int] = [:]
        var neutral = 0, coloured = 0
        for item in items {
            guard let raw = item.colors.first, case let name = ClosetColor.normalize(raw), !name.isEmpty else { continue }
            colourCounts[name, default: 0] += 1
            coloured += 1
            if StylePalette.isNeutral(name) { neutral += 1 }
        }
        let sortedColours = colourCounts.sorted { $0.value != $1.value ? $0.value > $1.value : ClosetColor.rank($0.key) < ClosetColor.rank($1.key) }
        var colours = sortedColours.prefix(6).map {
            Share(name: $0.key, count: $0.value, fraction: Double($0.value) / Double(max(1, coloured)))
        }
        let rest = sortedColours.dropFirst(6).reduce(0) { $0 + $1.value }
        if rest > 0 { colours.append(Share(name: "Other", count: rest, fraction: Double(rest) / Double(max(1, coloured)))) }

        // Shelves.
        let counts = ClosetEngine.counts(items)
        let shelves = ClosetSection.allCases.compactMap { s -> Shelf? in
            guard let n = counts[s], n > 0 else { return nil }
            return Shelf(section: s, count: n, fraction: Double(n) / Double(max(1, items.count)))
        }

        return WardrobeInsights(
            total: items.count,
            mostWorn: Array(mostWorn.prefix(6)),
            notWorn: notWorn,
            wornInWindow: items.count - notWorn.count,
            logStart: logStart,
            logCoversWindow: logStart.map { $0 <= windowStart } ?? false,
            recent: Array(items.reversed().prefix(8)),
            colours: colours,
            neutralShare: coloured == 0 ? 0 : Double(neutral) / Double(coloured),
            shelves: shelves,
            balanceNote: balanceNote(items),
            duplicates: duplicates(items)
        )
    }

    // MARK: Balance

    /// Outfits need a top and a bottom: say so when one side outnumbers the other 3 : 1.
    static func balanceNote(_ items: [WardrobeItem]) -> String? {
        let tops = items.filter { OutfitSlot.of($0) == .top }.count
        let bottoms = items.filter { OutfitSlot.of($0) == .bottom }.count
        guard tops > 0, bottoms > 0 else { return nil }
        if tops >= bottoms * 3 {
            let ratio = Int((Double(tops) / Double(bottoms)).rounded())
            return "About \(ratio) tops for every bottom: another bottom adds the most new outfits."
        }
        if bottoms >= tops * 3 {
            let ratio = Int((Double(bottoms) / Double(tops)).rounded())
            return "About \(ratio) bottoms for every top: another top adds the most new outfits."
        }
        return nil
    }

    // MARK: Duplicates

    /// Three or more pieces of the same kind in the same lead colour ("You have 9 black tees").
    static func duplicates(_ items: [WardrobeItem], minimum: Int = 3) -> [Duplicate] {
        var groups: [String: [WardrobeItem]] = [:]
        var keys: [String] = []
        for item in items {
            guard let raw = item.colors.first, case let colour = ClosetColor.normalize(raw), !colour.isEmpty else { continue }
            let key = colour.lowercased() + "|" + item.product.lowercased()
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(item)
        }
        return keys.compactMap { key -> Duplicate? in
            guard let group = groups[key], group.count >= minimum, let first = group.first else { return nil }
            let colour = StyleVocabulary.spokenColour(ClosetColor.normalize(first.colors.first ?? "").lowercased())
            return Duplicate(title: "You have \(counted(group.count, colour: colour, of: first))", items: group)
        }
        .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.title < $1.title }
    }

    /// "9 black tees", "3 white dresses", "4 pairs of blue jeans".
    static func counted(_ n: Int, colour: String, of item: WardrobeItem) -> String {
        let profile = ItemProfile(item, order: 0)
        let noun = profile.map { StyleVocabulary.noun(for: $0) } ?? ClosetText.displayProduct(item.product).lowercased()
        let pairNoun = profile.map { StyleVocabulary.isPlural($0) } ?? false
            || ["jeans", "shorts", "trousers", "leggings", "pants", "sunglasses", "tights"].contains { noun.hasSuffix($0) }
        // The noun may already carry the colour ("denim jacket" for a denim piece).
        let described = noun.contains(colour) ? noun : "\(colour) \(noun)"
        if pairNoun { return "\(n) pair\(n == 1 ? "" : "s") of \(described)" }
        for suffix in ["s", "x", "sh", "ch"] where noun.hasSuffix(suffix) { return "\(n) \(described)es" }
        return "\(n) \(described)s"
    }
}
