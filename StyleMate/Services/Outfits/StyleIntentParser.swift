import Foundation

/// Structured hints pulled out of the free-text request ("something in blue for
/// an outdoor wedding, it'll be chilly"). Every field is optional context — the
/// engine still works with an empty set.
struct StyleHints: Equatable {
    var occasion: OutfitType? = nil
    var moods: [OutfitMood] = []
    var preferredColors: [String] = []      // canonical swatch names ("blue", "navy")
    var avoidedColors: [String] = []
    var preferredProducts: [String] = []    // lowercased product names ("dresses")
    var avoidedProducts: [String] = []
    var temperatureC: Double? = nil         // "cold evening" overrides live weather
    var expectsRain = false
    var isEvening = false
    var formalityBias: Double = 0           // "dressy" +, "casual" −
    var wantsEthnic = false
    var wantsActive = false

    var isEmpty: Bool { self == StyleHints() }

    /// Combine two readings of the same request. `self` wins on conflicting
    /// scalars; lists are unioned.
    func merged(with other: StyleHints) -> StyleHints {
        func union<T: Equatable>(_ a: [T], _ b: [T]) -> [T] { a + b.filter { !a.contains($0) } }
        var m = self
        m.occasion = occasion ?? other.occasion
        m.moods = Array(union(moods, other.moods).prefix(2))
        m.preferredColors = union(preferredColors, other.preferredColors)
        m.avoidedColors = union(avoidedColors, other.avoidedColors)
        m.preferredProducts = union(preferredProducts, other.preferredProducts)
        m.avoidedProducts = union(avoidedProducts, other.avoidedProducts)
        m.temperatureC = temperatureC ?? other.temperatureC
        m.expectsRain = expectsRain || other.expectsRain
        m.isEvening = isEvening || other.isEvening
        m.formalityBias = formalityBias != 0 ? formalityBias : other.formalityBias
        m.wantsEthnic = wantsEthnic || other.wantsEthnic || m.occasion == .ethnic
        m.wantsActive = wantsActive || other.wantsActive || m.occasion == .sports
        // A colour can't be both wanted and avoided.
        m.preferredColors.removeAll { m.avoidedColors.contains($0) }
        m.preferredProducts.removeAll { m.avoidedProducts.contains($0) }
        return m
    }
}

/// Deterministic, on-device keyword reading of the free-text request: occasion
/// words, mood words, colours ("something in blue", "no black"), garments,
/// weather and time cues. The on-device language model (when present) refines
/// this; this parser is always the baseline.
enum StyleIntentParser {

    static func parse(_ raw: String?) -> StyleHints {
        var hints = StyleHints()
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return hints }
        let original = " " + StylePalette.normalize(raw) + " "
        var text = original

        // Order matters: each matched phrase is blanked out so "hot pink" isn't
        // also read as a temperature, and "work from home" isn't read as "work".
        // Formality and time-of-day cues read the untouched text.
        parseColors(&text, into: &hints)
        parseOccasion(&text, into: &hints)
        parseWeather(&text, original: original, into: &hints)
        parseProducts(&text, into: &hints)
        parseMoods(&text, into: &hints)
        parseFormality(original, into: &hints)

        hints.wantsEthnic = hints.wantsEthnic || hints.occasion == .ethnic
        hints.wantsActive = hints.wantsActive || hints.occasion == .sports
        hints.preferredColors.removeAll { hints.avoidedColors.contains($0) }
        return hints
    }

    // MARK: - Matching helpers

    private static let negators: Set<String> = ["no", "not", "without", "avoid", "except", "skip", "never",
                                                "dont", "don", "nothing", "hate", "minus", "zero"]

    /// Finds `phrase` as whole words; blanks it out and reports whether it was
    /// negated by one of the three preceding words.
    private static func take(_ phrase: String, from text: inout String) -> (found: Bool, negated: Bool) {
        let needle = " \(phrase) "
        guard let range = text.range(of: needle) else { return (false, false) }
        let before = text[text.startIndex..<range.lowerBound].split(separator: " ").suffix(3)
        let negated = before.contains { negators.contains(String($0)) }
        text.replaceSubrange(range, with: String(repeating: " ", count: needle.count))
        return (true, negated)
    }

    private static func has(_ phrase: String, in text: String) -> Bool {
        text.contains(" \(phrase) ")
    }

    // MARK: - Colours

    /// Colour words safe to read from conversation ("coffee date", "wine bar" and
    /// "rose gold watch" shouldn't become colour requests).
    private static let conversationalColors: Set<String> = [
        "black", "white", "cream", "ivory", "grey", "gray", "charcoal", "silver", "navy", "navy blue",
        "beige", "tan", "camel", "khaki", "brown", "olive", "olive green", "denim", "gold", "red",
        "maroon", "burgundy", "pink", "blush", "hot pink", "fuchsia", "coral", "orange", "rust",
        "terracotta", "mustard", "yellow", "lime", "green", "emerald", "forest green", "dark green",
        "mint", "sage", "teal", "turquoise", "aqua", "light blue", "sky blue", "baby blue", "blue",
        "dark blue", "cobalt", "royal blue", "lavender", "lilac", "purple", "violet", "plum"
    ]

    private static func parseColors(_ text: inout String, into hints: inout StyleHints) {
        if take("earth tones", from: &text).found || take("earthy", from: &text).found {
            for c in ["brown", "olive", "tan", "rust"] where !hints.preferredColors.contains(c) {
                hints.preferredColors.append(c)
            }
        }
        if take("all black", from: &text).found {
            hints.preferredColors.append("black")
            hints.moods.append(.minimal)
        }
        for (alias, swatch) in StylePalette.aliases where conversationalColors.contains(alias) {
            let hit = take(alias, from: &text)
            guard hit.found else { continue }
            if hit.negated {
                if !hints.avoidedColors.contains(swatch.name) { hints.avoidedColors.append(swatch.name) }
            } else if !hints.preferredColors.contains(swatch.name) {
                hints.preferredColors.append(swatch.name)
            }
        }
    }

    // MARK: - Occasion

    private static let occasionPhrases: [(String, OutfitType)] = {
        let raw: [(String, OutfitType)] = [
            // Ethnic / festive first — "indian wedding" must beat "wedding".
            ("indian wedding", .ethnic), ("desi wedding", .ethnic), ("mehendi", .ethnic), ("mehndi", .ethnic),
            ("sangeet", .ethnic), ("haldi", .ethnic), ("puja", .ethnic), ("pooja", .ethnic), ("diwali", .ethnic),
            ("eid", .ethnic), ("navratri", .ethnic), ("garba", .ethnic), ("ethnic", .ethnic), ("traditional", .ethnic),
            ("kurta", .ethnic), ("saree", .ethnic), ("sari", .ethnic), ("lehenga", .ethnic), ("festive", .ethnic),
            // Everyday — "run errands" must beat "run".
            ("run errands", .everyday), ("errands", .everyday), ("brunch", .everyday), ("coffee", .everyday),
            ("casual", .everyday), ("weekend", .everyday), ("school", .everyday), ("college", .everyday),
            ("class", .everyday), ("shopping", .everyday), ("picnic", .everyday), ("park", .everyday),
            // Lounge — "work from home" must beat "work".
            ("work from home", .loungewear), ("wfh", .loungewear), ("movie night", .loungewear),
            ("lounge", .loungewear), ("lounging", .loungewear), ("at home", .loungewear), ("netflix", .loungewear),
            ("lazy day", .loungewear), ("sofa", .loungewear), ("couch", .loungewear), ("sleepover", .loungewear),
            // Sports — "work out" must beat "work".
            ("work out", .sports), ("workout", .sports), ("gym", .sports), ("training", .sports),
            ("running", .sports), ("run", .sports), ("jog", .sports), ("jogging", .sports), ("yoga", .sports),
            ("pilates", .sports), ("hike", .sports), ("hiking", .sports), ("tennis", .sports),
            ("football", .sports), ("cycling", .sports), ("sports", .sports), ("sport", .sports),
            ("athletic", .sports), ("climbing", .sports),
            // Formal
            ("black tie", .formal), ("gala", .formal), ("formal", .formal), ("cocktail", .formal),
            ("ceremony", .formal), ("funeral", .formal), ("opera", .formal), ("awards", .formal),
            ("banquet", .formal), ("wedding", .formal), ("reception", .formal),
            // Business
            ("job interview", .business), ("interview", .business), ("office", .business), ("work", .business),
            ("meeting", .business), ("presentation", .business), ("conference", .business), ("client", .business),
            ("business", .business), ("corporate", .business), ("networking", .business),
            // Date
            ("date night", .date), ("first date", .date), ("date", .date), ("anniversary", .date),
            ("romantic dinner", .date),
            // Party
            ("night out", .party), ("party", .party), ("club", .party), ("clubbing", .party),
            ("birthday", .party), ("drinks", .party), ("bar", .party), ("concert", .party), ("gig", .party),
            ("festival", .party), ("rave", .party),
            // Vacation
            ("beach", .vacation), ("pool", .vacation), ("vacation", .vacation), ("holiday", .vacation),
            ("resort", .vacation), ("trip", .vacation), ("travel", .vacation), ("sightseeing", .vacation),
            ("cruise", .vacation), ("flight", .vacation),
            // Streetwear
            ("streetwear", .streetwear), ("street style", .streetwear), ("skate", .streetwear),
            ("skating", .streetwear), ("urban", .streetwear)
        ]
        // Longest phrase first, stable within equal lengths.
        return raw.enumerated()
            .sorted { $0.element.0.count != $1.element.0.count ? $0.element.0.count > $1.element.0.count : $0.offset < $1.offset }
            .map { $0.element }
    }()

    private static func parseOccasion(_ text: inout String, into hints: inout StyleHints) {
        for (phrase, type) in occasionPhrases {
            let hit = take(phrase, from: &text)
            guard hit.found, !hit.negated else { continue }
            if hints.occasion == nil { hints.occasion = type }
            // "gym then errands" still wants activewear, whatever wins the occasion.
            if type == .ethnic { hints.wantsEthnic = true }
            if type == .sports { hints.wantsActive = true }
            if ["interview", "job interview"].contains(phrase) { hints.formalityBias = max(hints.formalityBias, 0.4) }
            if ["date night", "club", "clubbing", "night out", "concert", "gig", "drinks", "bar"].contains(phrase) {
                hints.isEvening = true
            }
        }
    }

    // MARK: - Weather & time

    private static func parseWeather(_ text: inout String, original: String, into hints: inout StyleHints) {
        // Bare "hot" / "crisp" / "cool" are left out on purpose: "hot date",
        // "crisp white shirt" and "cool outfit" aren't weather.
        let temps: [(String, Double)] = [
            ("heatwave", 34), ("scorching", 34), ("boiling", 33), ("hot day", 30), ("hot weather", 30),
            ("its hot", 30), ("it s hot", 30), ("humid", 29), ("summer", 28), ("warm day", 25), ("warm weather", 25),
            ("spring", 17), ("autumn", 13), ("chilly", 10), ("cold", 5), ("winter", 4),
            ("freezing", 0), ("snow", 0), ("snowy", 0), ("icy", -1)
        ]
        for (phrase, value) in temps {
            let hit = take(phrase, from: &text)
            if hit.found, !hit.negated, hints.temperatureC == nil { hints.temperatureC = value }
        }
        for word in ["rain", "rainy", "raining", "monsoon", "drizzle", "showers", "storm", "stormy", "wet"] {
            let hit = take(word, from: &text)
            if hit.found, !hit.negated { hints.expectsRain = true }
        }
        for word in ["evening", "night", "tonight", "dinner", "late", "nighttime"] where has(word, in: original) {
            hints.isEvening = true
        }
        if has("dinner", in: original) { hints.formalityBias = max(hints.formalityBias, 0.3) }
    }

    // MARK: - Garments

    /// Spoken forms → wardrobe product names (lowercased).
    private static let productPhrases: [(String, [String])] = {
        var pairs: [(String, [String])] = [
            ("sneakers", ["sneakers"]), ("trainers", ["sneakers"]), ("kicks", ["sneakers"]),
            ("dress", ["dresses", "wrap dresses", "maxi dresses", "shirt dresses"]),
            ("dresses", ["dresses", "wrap dresses", "maxi dresses", "shirt dresses"]),
            ("skirt", ["skirts", "mini skirts"]), ("boots", ["boots", "ankle boots", "chelsea boots"]),
            ("heels", ["heels"]), ("jeans", ["jeans"]), ("denim", ["jeans", "denim jackets"]),
            ("blazer", ["blazers"]), ("suit", ["blazers", "trousers"]), ("shorts", ["shorts"]),
            ("hoodie", ["hoodies"]), ("sweater", ["sweaters", "pullovers"]), ("jumper", ["sweaters", "pullovers"]),
            ("knit", ["sweaters", "cardigans"]), ("coat", ["coats", "overcoats", "trench coats"]),
            ("jacket", ["jackets", "leather jackets", "denim jackets", "bomber jackets"]),
            ("tee", ["t-shirts", "graphic tees"]), ("t shirt", ["t-shirts"]), ("shirt", ["shirts", "button-down shirts"]),
            ("jumpsuit", ["jumpsuits"]), ("trousers", ["trousers"]), ("pants", ["trousers", "chinos"]),
            ("loafers", ["loafers"]), ("sandals", ["sandals"]), ("kurta", ["kurta"]), ("saree", ["saree"]),
            ("sari", ["saree"]), ("leather jacket", ["leather jackets"]), ("cardigan", ["cardigans"]),
            ("turtleneck", ["turtlenecks"]), ("scarf", ["scarves"]),
            ("sunglasses", ["sunglasses"]), ("hat", ["fedoras", "bucket hats", "sun hats", "baseball caps"])
        ]
        // Singulars that are everyday words ("short notice", "watch a film").
        let ambiguousSingulars: Set<String> = ["short", "flat", "tie", "ring", "slide", "jean", "chain",
                                               "watch", "cap", "capri", "vest", "cape", "mule", "visor"]
        // Every catalogue product in its plural and singular spoken form. Sorted
        // so the table is identical on every run.
        for category in Category.allCases {
            for product in productTypesByCategory[category] ?? [] {
                let key = StylePalette.normalize(product)
                pairs.append((key, [product.lowercased()]))
                let singular: String?
                if key.hasSuffix("sses") || key.hasSuffix("shes") || key.hasSuffix("ches") {
                    singular = String(key.dropLast(2))
                } else if key.hasSuffix("s") {
                    singular = String(key.dropLast())
                } else {
                    singular = nil
                }
                if let singular, !ambiguousSingulars.contains(singular) {
                    pairs.append((singular, [product.lowercased()]))
                }
            }
        }
        return pairs.enumerated()
            .sorted { $0.element.0.count != $1.element.0.count ? $0.element.0.count > $1.element.0.count : $0.offset < $1.offset }
            .map { $0.element }
    }()

    /// Product names a spoken garment word refers to (used by the model bridge too).
    static func products(for phrase: String) -> [String] {
        let key = StylePalette.normalize(phrase)
        return productPhrases.first { $0.0 == key }?.1 ?? []
    }

    private static func parseProducts(_ text: inout String, into hints: inout StyleHints) {
        for (phrase, products) in productPhrases {
            let hit = take(phrase, from: &text)
            guard hit.found else { continue }
            for p in products {
                if hit.negated {
                    if !hints.avoidedProducts.contains(p) { hints.avoidedProducts.append(p) }
                } else if !hints.preferredProducts.contains(p) {
                    hints.preferredProducts.append(p)
                }
            }
        }
    }

    // MARK: - Mood & formality

    private static func parseMoods(_ text: inout String, into hints: inout StyleHints) {
        for mood in OutfitMood.allCases {
            for word in mood.keywords {
                let hit = take(word, from: &text)
                if hit.found, !hit.negated, !hints.moods.contains(mood) { hints.moods.append(mood) }
            }
        }
        hints.moods = Array(hints.moods.prefix(2))
    }

    private static func parseFormality(_ text: String, into hints: inout StyleHints) {
        let up: [(String, Double)] = [("dressy", 0.7), ("fancy", 0.8), ("dressed up", 0.8), ("smart", 0.5),
                                      ("formal", 0.6), ("sophisticated", 0.6), ("upscale", 0.7)]
        let down: [(String, Double)] = [("casual", -0.5), ("comfy", -0.3), ("comfortable", -0.3),
                                        ("lazy", -0.6), ("chill", -0.4), ("dressed down", -0.6)]
        for (word, bias) in up where has(word, in: text) { hints.formalityBias = max(hints.formalityBias, bias) }
        for (word, bias) in down where has(word, in: text) {
            hints.formalityBias = hints.formalityBias > 0 ? hints.formalityBias + bias : min(hints.formalityBias, bias)
        }
    }
}
