import Foundation

// MARK: - OutfitEngine
//
// Fully on-device outfit recommender — no network, no cloud model. It replaces
// the old Gemini batch / shuffle / add-a-piece calls with a deterministic stylist:
//
//   1. Profile every garment (slot, formality, warmth, colour, traits).
//   2. Filter per slot by hard rules (activewear/ethnic isolation, heat → no
//      knits or coats, formal → no athleisure when dressier pieces exist…).
//   3. Compose candidates slot by slot: core (top + bottom, or a one-piece) →
//      footwear → optional mid-layer → outerwear (required when it's cold).
//   4. Score each candidate with explicit, tunable components: weather, formality,
//      colour harmony, pattern mixing, mood, preferences, request hints, recency.
//   5. Pick five *different* looks with greedy MMR (score minus overlap with the
//      looks already chosen), then finish each with 0–2 accessories and a short
//      stylist note assembled from the scoring reasons.
//
// Randomness is a seeded SplitMix64 jitter, so "Generate more" gives fresh looks
// while a fixed seed reproduces the same five (tests).

struct OutfitEngine {

    enum Failure: Error, Equatable {
        /// Not enough to dress anyone: needs a top + bottom, or a one-piece.
        case emptyWardrobe
    }

    /// Every scoring component's weight in one place, so the stylist can be
    /// rebalanced without touching the rules.
    struct Weights {
        var formality = 1.6
        var weather = 1.0
        var palette = 1.5
        var pattern = 1.0
        var mood = 1.0
        var recency = 1.0
        var preference = 0.3
        /// MMR penalty per unit of overlap with an already-chosen look.
        var variety = 1.5
        /// Max per-item random nudge; 0 makes the engine fully greedy.
        var jitter = 0.9
    }

    var weights: Weights

    init(weights: Weights = Weights()) {
        self.weights = weights
    }

    // MARK: Suggest

    /// Up to `count` distinct, complete looks (fewer only if the wardrobe truly
    /// can't make more). Locked items appear in every look.
    func suggest(from wardrobe: [WardrobeItem],
                 context: StylingContext,
                 locked: [WardrobeItem] = [],
                 count: Int = 5,
                 seed: UInt64) -> Result<[Outfit], Failure> {
        let pass = StylingPass(wardrobe: wardrobe, extra: locked, context: context, weights: weights, seed: seed)
        guard pass.canDress else { return .failure(.emptyWardrobe) }
        let lockedProfiles = locked.compactMap { pass.profile(for: $0) }
        let candidates = pass.candidates(locked: lockedProfiles)
        let picks = pass.diverseSelection(candidates, count: max(1, count))
        guard !picks.isEmpty else { return .failure(.emptyWardrobe) }
        let looks = picks.enumerated().map { entry in
            pass.finish(entry.element, locked: lockedProfiles, variant: UInt64(entry.offset))
        }
        return .success(looks)
    }

    // MARK: Shuffle one slot

    /// The best-scoring alternative for `item`'s slot given the rest of the look.
    /// Never returns the current item or anything in `excluding` (so repeated taps
    /// walk through the options). nil when there's no alternative at all.
    func shuffle(_ item: WardrobeItem,
                 in outfit: Outfit,
                 wardrobe: [WardrobeItem],
                 context: StylingContext,
                 excluding: Set<UUID> = [],
                 seed: UInt64) -> Outfit? {
        let pass = StylingPass(wardrobe: wardrobe, extra: outfit.items, context: context, weights: weights, seed: seed)
        guard let target = pass.profile(for: item) else { return nil }
        let current = outfit.items.compactMap { pass.profile(for: $0) }
        guard let items = pass.shuffled(target, in: current, excluding: excluding) else { return nil }
        return pass.outfit(from: items, variant: seed)
    }

    // MARK: Add a piece

    /// Adds the best `productType` piece for this look. If the slot is a
    /// singleton that's already filled (a second pair of shoes), it swaps instead.
    func add(category: Category,
             productType: String,
             to outfit: Outfit,
             wardrobe: [WardrobeItem],
             context: StylingContext,
             seed: UInt64) -> Outfit? {
        let pass = StylingPass(wardrobe: wardrobe, extra: outfit.items, context: context, weights: weights, seed: seed)
        let current = outfit.items.compactMap { pass.profile(for: $0) }
        guard let items = pass.adding(category: category, productType: productType, to: current) else { return nil }
        return pass.outfit(from: items, variant: seed)
    }

    /// A fresh stylist note for an arbitrary look (used after manual edits).
    func explanation(for outfit: Outfit, wardrobe: [WardrobeItem], context: StylingContext, seed: UInt64) -> String {
        let pass = StylingPass(wardrobe: wardrobe, extra: outfit.items, context: context, weights: weights, seed: seed)
        let items = outfit.items.compactMap { pass.profile(for: $0) }
        return pass.explain(items, palette: pass.analyzePalette(items), variant: seed)
    }
}

// MARK: - Context

/// Everything about *today* the engine styles for. Plain values so tests can
/// build one directly; the app builds it from live weather + the user's picks.
struct StylingContext {
    var temperatureC: Double?
    var condition: String?
    var isDaytime: Bool
    var occasion: OutfitType?
    var mood: OutfitMood?
    var hints: StyleHints
    var preferredStyles: [OutfitType]
    var gender: String?
    /// Most recent date each wardrobe item was logged as worn (from My Outfits).
    var lastWorn: [UUID: Date]
    var now: Date
    var useFahrenheit: Bool

    init(temperatureC: Double?,
         condition: String? = nil,
         isDaytime: Bool = true,
         occasion: OutfitType? = nil,
         mood: OutfitMood? = nil,
         hints: StyleHints = StyleHints(),
         preferredStyles: [OutfitType] = [],
         gender: String? = nil,
         lastWorn: [UUID: Date] = [:],
         now: Date = Date(),
         useFahrenheit: Bool = false) {
        self.temperatureC = temperatureC
        self.condition = condition
        self.isDaytime = isDaytime
        self.occasion = occasion
        self.mood = mood
        self.hints = hints
        self.preferredStyles = preferredStyles
        self.gender = gender
        self.lastWorn = lastWorn
        self.now = now
        self.useFahrenheit = useFahrenheit
    }

    init(weather: Weather?,
         occasion: OutfitType?,
         mood: OutfitMood?,
         hints: StyleHints,
         user: User?,
         lastWorn: [UUID: Date],
         now: Date = Date(),
         useFahrenheit: Bool = false) {
        self.init(temperatureC: weather?.temperature2m,
                  condition: weather?.displayDescription,
                  isDaytime: weather.map { $0.isDay == 1 } ?? true,
                  occasion: occasion,
                  mood: mood,
                  hints: hints,
                  preferredStyles: user?.preferredStyles ?? [],
                  gender: user?.gender,
                  lastWorn: lastWorn,
                  now: now,
                  useFahrenheit: useFahrenheit)
    }

    // MARK: Derived

    /// The typed request outranks the occasion chip, which outranks the profile.
    var resolvedOccasion: OutfitType { hints.occasion ?? occasion ?? preferredStyles.first ?? .everyday }
    var occasionWasStated: Bool { hints.occasion != nil || occasion != nil }

    /// A temperature named in the request ("cold evening") beats the live reading.
    var temperature: Double? { hints.temperatureC ?? temperatureC }
    var band: TempBand? { temperature.map { TempBand(celsius: $0) } }

    var conditionText: String { (condition ?? "").lowercased() }
    var isRaining: Bool {
        hints.expectsRain || ["rain", "drizzle", "shower", "thunder", "sleet", "storm"].contains { conditionText.contains($0) }
    }
    var isSnowing: Bool { conditionText.contains("snow") || conditionText.contains("sleet") }

    var hour: Int { Calendar.current.component(.hour, from: now) }
    var isDark: Bool { !isDaytime || hints.isEvening || hour >= 19 || hour < 6 }
    var sunglassesWeather: Bool {
        !isDark && !isRaining && !conditionText.contains("fog") && !conditionText.contains("overcast")
    }

    /// The chip mood first, then up to one mood read from the request.
    var moods: [OutfitMood] {
        var list = hints.moods
        if let mood {
            list.removeAll { $0 == mood }
            list.insert(mood, at: 0)
        }
        return Array(list.prefix(2))
    }

    var wantsEthnic: Bool { hints.wantsEthnic || resolvedOccasion == .ethnic }
    var wantsActive: Bool { hints.wantsActive || resolvedOccasion == .sports }

    /// Occasion formality band, shifted by mood and "dressy"/"casual" cues.
    var formalityTarget: ClosedRange<Double> {
        let base = resolvedOccasion.formalityRange
        var shift = hints.formalityBias
        for (i, m) in moods.enumerated() { shift += m.formalityShift * (i == 0 ? 0.7 : 0.4) }
        let lo = min(4.6, max(0.5, base.lowerBound + shift))
        let hi = min(5.0, max(lo + 0.6, base.upperBound + shift))
        return lo...hi
    }
}

/// Temperature bands the layering rules key off (°C).
enum TempBand: Int, Comparable {
    case freezing, cold, cool, mild, warm, hot

    init(celsius t: Double) {
        switch t {
        case ..<3: self = .freezing
        case ..<10: self = .cold
        case ..<16: self = .cool
        case ..<22: self = .mild
        case ..<27: self = .warm
        default: self = .hot
        }
    }

    static func < (lhs: TempBand, rhs: TempBand) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Used when the temperature came from the request rather than a reading.
    var spoken: String {
        switch self {
        case .freezing: return "a freezing day"
        case .cold: return "the cold"
        case .cool: return "a cool day"
        case .mild: return "a mild day"
        case .warm: return "a warm day"
        case .hot: return "the heat"
        }
    }
}

extension OutfitType {
    /// Target formality band on the engine's 0.5–5 scale.
    var formalityRange: ClosedRange<Double> {
        switch self {
        case .everyday: return 1.8...3.2
        case .formal: return 4.0...5.0
        case .date: return 2.8...4.2
        case .sports: return 0.5...1.6
        case .party: return 2.8...4.4
        case .business: return 3.0...4.2
        case .loungewear: return 0.5...2.0
        case .vacation: return 1.6...3.0
        case .ethnic: return 2.6...4.8
        case .streetwear: return 1.4...2.8
        }
    }

    /// Closing note for explanations.
    var stylistPhrase: String {
        switch self {
        case .everyday: return "an easy everyday win"
        case .formal: return "sharp enough for a formal occasion"
        case .date: return "date-night ready"
        case .sports: return "built to move"
        case .party: return "made for a night out"
        case .business: return "office-ready without trying too hard"
        case .loungewear: return "comfort first, still put together"
        case .vacation: return "holiday-easy"
        case .ethnic: return "festive and polished"
        case .streetwear: return "with easy street edge"
        }
    }

    /// Casual occasions get a lighter register in the stylist's notes.
    var isCasualRegister: Bool {
        switch self {
        case .everyday, .loungewear, .vacation, .streetwear, .sports: return true
        case .formal, .date, .party, .business, .ethnic: return false
        }
    }
}

extension OutfitMood {
    /// The mood's closing note in the occasion's register: a confident
    /// Everyday Casual look isn't "built to own the room".
    func closer(for occasion: OutfitType) -> String {
        guard occasion.isCasualRegister else { return closer }
        switch self {
        case .confident: return "easy, with a little swagger"
        case .polished: return "neat without trying too hard"
        case .bold: return "a little louder than usual"
        case .romantic: return "soft and easy"
        case .cozy, .relaxed, .playful, .minimal: return closer
        }
    }
}

// MARK: - Palette analysis

/// How a look's colours sit on the wheel. Neutrals don't count as accents;
/// accents within ~35° are one family.
struct PaletteAnalysis {
    enum Kind { case neutral, singleAccent, tonal, analogous, complementary, triadic, clashing, busy }

    var kind: Kind
    var families: [Double]            // representative hue per accent family
    var accentItems: [ItemProfile]    // items carrying an accent, in look order
    var saturatedFamilies: Int
    var score: Double

    /// Coarse fingerprint (30° buckets) so two looks in the same colours read as similar.
    var familyBuckets: [Int] { families.map { Int($0 / 30) }.sorted() }
}

// MARK: - Seeded randomness

/// SplitMix64: tiny, fast and identical on every run, so a fixed seed reproduces
/// the same looks while a fresh seed reshuffles them.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }

    mutating func choose(_ options: [String]) -> String {
        guard !options.isEmpty else { return "" }
        return options[Int(next() % UInt64(options.count))]
    }
}

// MARK: - Styling pass

/// One styling run: the wardrobe profiled against one context and seed. Holds the
/// per-slot pools and score caches. Not shared across threads.
private final class StylingPass {
    typealias Weights = OutfitEngine.Weights

    struct Candidate {
        let items: [ItemProfile]
        let score: Double
        let palette: PaletteAnalysis
        let signature: String
        let idSet: Set<UUID>

        init(items: [ItemProfile], score: Double, palette: PaletteAnalysis) {
            self.items = items
            self.score = score
            self.palette = palette
            // Same rule as OutfitValidator: accessories don't make a look different.
            let core = items.filter { $0.isClothing }.map { $0.id.uuidString }.sorted()
            self.signature = core.joined(separator: "|")
            self.idSet = Set(items.map { $0.id })
        }
    }

    struct Evaluation {
        let score: Double
        let palette: PaletteAnalysis
    }

    let context: StylingContext
    let weights: Weights
    let seed: UInt64
    let target: ClosedRange<Double>
    let temperature: Double?
    let band: TempBand?
    let moods: [OutfitMood]
    let all: [ItemProfile]

    private var byID: [UUID: ItemProfile] = [:]
    private var unaryCache: [UUID: Double] = [:]
    private var pools: [OutfitSlot: [ItemProfile]] = [:]
    private var accessoryUse: [UUID: Int] = [:]
    private var wantedColors: [ColorSwatch] = []
    private var wantedColorAvailable = false
    private var wantedProductAvailable = false

    init(wardrobe: [WardrobeItem], extra: [WardrobeItem], context: StylingContext, weights: Weights, seed: UInt64) {
        self.context = context
        self.weights = weights
        self.seed = seed
        self.target = context.formalityTarget
        self.temperature = context.temperature
        self.band = context.band
        self.moods = context.moods

        var profiles: [ItemProfile] = []
        var seen = Set<UUID>()
        for (i, item) in (wardrobe + extra).enumerated() where !seen.contains(item.id) {
            seen.insert(item.id)
            if let p = ItemProfile(item, order: i) { profiles.append(p) }
        }
        self.all = profiles

        for p in profiles { byID[p.id] = p }
        wantedColors = context.hints.preferredColors.compactMap { StylePalette.swatch(for: $0) }
        buildPools()
        let clothingPools = [OutfitSlot.top, .bottom, .onePiece, .midLayer, .outerwear].flatMap { pools[$0] ?? [] }
        wantedColorAvailable = clothingPools.contains { matchesWantedColor($0) }
        wantedProductAvailable = OutfitSlot.allCases.flatMap { pools[$0] ?? [] }
            .contains { context.hints.preferredProducts.contains($0.productKey) }
    }

    func profile(for item: WardrobeItem) -> ItemProfile? {
        byID[item.id] ?? ItemProfile(item, order: all.count)
    }

    /// The wardrobe can make at least one complete look.
    var canDress: Bool {
        let slots = Set(all.map { $0.slot })
        let separates = slots.contains(.top) && slots.contains(.bottom)
        let onePiece = all.contains { $0.slot == .onePiece && (!$0.needsTopUnder || slots.contains(.top)) }
        return separates || onePiece
    }

    // MARK: Eligibility & pools

    private func hardAvoided(_ p: ItemProfile) -> Bool {
        if StyleKnowledge.neverAutoPick.contains(p.productKey) { return true }
        if context.hints.avoidedProducts.contains(p.productKey) { return true }
        if let lead = p.lead, context.hints.avoidedColors.contains(lead.name) { return true }
        return false
    }

    private func isEligible(_ p: ItemProfile) -> Bool {
        if p.slot == .accessory { return accessoryEligible(p) }

        // Activewear only for active requests; ethnic wear only when asked for —
        // except a Nehru jacket / bandhgala, a legit smart layer on its own.
        if p.isAthletic && !context.wantsActive { return false }
        if p.isEthnic && !context.wantsEthnic {
            return p.slot == .outerwear && target.lowerBound >= 2.6
        }
        if p.productKey == "slippers" && context.resolvedOccasion != .loungewear { return false }
        if context.isSnowing && p.isOpenShoe { return false }

        if let t = temperature {
            if t >= 27 {
                // Real heat: no knits, no coats. A blazer survives for dressy plans,
                // a light shell for rain.
                if p.slot == .midLayer { return false }
                if p.slot == .outerwear {
                    let dressLayer = p.isTailored && target.lowerBound >= 3.4
                    let rainLayer = context.isRaining && p.isWaterResistant && p.warmth <= 1.6
                    return dressLayer || rainLayer
                }
            }
            if t < 8 && !context.wantsActive {
                if p.showsLegs { return false }
                if p.isOpenShoe { return false }
            }
        }
        return true
    }

    private func accessoryEligible(_ p: ItemProfile) -> Bool {
        guard let kind = p.accessoryKind else { return false }
        let t = temperature ?? 18
        switch kind {
        case .eyewear:
            return p.productKey == "sunglasses" && context.sunglassesWeather && t >= 10
        case .headwear:
            switch p.productKey {
            case "beanies": return t < 10
            case "sun hats", "visors", "bucket hats": return t >= 18 && !context.isDark
            case "baseball caps": return target.lowerBound < 3.0
            case "turbans": return true
            default: return target.lowerBound < 4.4
            }
        case .neckwear:
            return t < 16
        case .tie:
            return target.lowerBound >= 3.0
        case .other:
            if p.productKey == "gloves" { return t < 6 }
            if p.productKey == "dupatta" { return context.wantsEthnic }
            return true
        case .jewelry, .watch, .belt, .bag:
            switch p.productKey {
            case "fanny packs", "backpacks": return target.lowerBound < 3.0
            case "briefcases": return context.resolvedOccasion == .business
            case "cufflinks": return target.lowerBound >= 4.0
            default: return true
            }
        }
    }

    private func rank(_ a: ItemProfile, _ b: ItemProfile) -> Bool {
        let ua = unary(a), ub = unary(b)
        return ua != ub ? ua > ub : a.order < b.order
    }

    private func buildPools() {
        for slot in OutfitSlot.allCases {
            let raw = all.filter { $0.slot == slot && !hardAvoided($0) }
            var eligible = raw.filter { isEligible($0) }

            if slot != .accessory {
                if context.wantsActive && slot == .footwear {
                    let trainers = eligible.filter { $0.isSneaker }
                    if !trainers.isEmpty { eligible = trainers }
                }
                // Dressy plans: drop pieces far below the bar when dressier
                // alternatives exist in the same slot (no joggers at a gala).
                if target.lowerBound >= 3.4 {
                    let floor = target.lowerBound - 1.5
                    let dressy = eligible.filter { $0.formality >= floor }
                    if !dressy.isEmpty { eligible = dressy }
                }
                if eligible.isEmpty && slot == .footwear {
                    // Shoes are non-negotiable: relax rather than go barefoot.
                    eligible = raw.filter { !$0.isAthletic || context.wantsActive }
                    if eligible.isEmpty { eligible = raw }
                }
            }
            pools[slot] = eligible.sorted { rank($0, $1) }
        }

        // Active plans: keep the core athletic when the wardrobe allows it.
        if context.wantsActive {
            for slot in [OutfitSlot.top, .bottom] {
                let athletic = (pools[slot] ?? []).filter { $0.isAthletic }
                if !athletic.isEmpty { pools[slot] = athletic }
            }
            let hasAthleticSeparates = (pools[.top] ?? []).contains { $0.isAthletic }
                && (pools[.bottom] ?? []).contains { $0.isAthletic }
            if hasAthleticSeparates { pools[.onePiece] = (pools[.onePiece] ?? []).filter { $0.isAthletic } }
        }

        // Always leave at least one way to get dressed.
        let tops = pools[.top] ?? [], bottoms = pools[.bottom] ?? [], ones = pools[.onePiece] ?? []
        let separates = !tops.isEmpty && !bottoms.isEmpty
        let onePieceLooks = ones.contains { !$0.needsTopUnder || !tops.isEmpty }
        if !separates && !onePieceLooks {
            for slot in [OutfitSlot.top, .bottom, .onePiece] {
                pools[slot] = all.filter { $0.slot == slot && !hardAvoided($0) }.sorted { rank($0, $1) }
            }
        }
    }

    // MARK: Item scores

    func jitter(_ key: UInt64, salt: UInt64) -> Double {
        var g = SeededGenerator(seed: seed ^ (key &* 0x9E3779B97F4A7C15) ^ (salt &* 0xD1B54A32D192ED03))
        return g.unit()
    }

    /// Everything about one garment that doesn't depend on the rest of the look.
    func unary(_ p: ItemProfile) -> Double {
        if let cached = unaryCache[p.id] { return cached }
        var s = formalityFit(p) * weights.formality
        s += weatherFit(p) * weights.weather
        s += moodFit(p) * weights.mood
        s += preferenceFit(p) * weights.preference
        s += hintFit(p)
        s -= recencyPenalty(p) * weights.recency
        s += jitter(UInt64(truncatingIfNeeded: p.order), salt: 1) * weights.jitter
        unaryCache[p.id] = s
        return s
    }

    private func formalityFit(_ p: ItemProfile) -> Double {
        let f = p.formality, lo = target.lowerBound, hi = target.upperBound
        // Under-dressed is worse than over-dressed.
        let miss = f < lo ? (lo - f) : (f > hi ? (f - hi) * 0.7 : 0)
        let mid = (lo + hi) / 2
        let closeness = max(0, 1 - abs(f - mid) / max(0.5, hi - lo))
        let slotWeight: Double
        switch p.slot {
        case .accessory: slotWeight = 0.4
        case .footwear: slotWeight = 1.1
        case .midLayer, .outerwear: slotWeight = 0.8
        default: slotWeight = 1.0
        }
        return (-miss + 0.3 * closeness) * slotWeight
    }

    private func weatherFit(_ p: ItemProfile) -> Double {
        guard let band else { return 0 }
        var s = 0.0
        let upper = p.slot == .top || p.slot == .onePiece
        switch band {
        case .hot:
            if p.slot == .outerwear { s -= 3 }
            if p.isHeavyFabric { s -= 1.5 }
            if p.isLongSleeve && upper { s -= 0.8 }
            if p.isBoot { s -= 1.5 }
            if p.showsLegs || p.isOpenShoe || p.isBreathable || p.isSleeveless || (p.isShortSleeve && upper) { s += 0.8 }
            if p.slot == .bottom && !p.showsLegs && !p.isBreathable { s -= 0.3 }
        case .warm:
            if p.slot == .midLayer { s -= p.warmth >= 1.5 ? 2.5 : 1.0 }
            if p.slot == .outerwear { s -= p.warmth >= 2.0 ? 3.0 : (p.isTailored ? 0.4 : 1.0) }
            if p.isHeavyFabric { s -= 0.8 }
            if p.isBoot { s -= 0.6 }
            if p.showsLegs || p.isOpenShoe || p.isBreathable { s += 0.4 }
        case .mild:
            if p.slot == .outerwear && p.warmth >= 3 { s -= 2.0 }
            if p.slot == .midLayer && p.warmth >= 2.2 { s -= 0.6 }
            if p.showsLegs { s -= 0.2 }
        case .cool:
            if p.showsLegs { s -= 2.0 }
            if p.isOpenShoe { s -= 1.8 }
            if p.isSleeveless && p.isClothing { s -= 1.0 }
            if p.slot == .outerwear && p.warmth >= 3.4 { s -= 0.8 }
        case .cold, .freezing:
            if p.showsLegs { s -= 3.5 }
            if p.isOpenShoe { s -= 3.5 }
            if p.isSleeveless && p.isClothing { s -= 2.0 }
            if p.isBoot { s += 0.8 }
            if p.isHeavyFabric { s += 0.6 }
            if p.slot == .outerwear { s += p.warmth >= 2.5 ? 1.0 : -0.4 }
            if band == .freezing && p.slot == .outerwear && p.warmth >= 3.0 { s += 0.8 }
        }
        if context.isRaining {
            // Suede and canvas hate rain; boots and proper shells love it.
            if p.isRainSensitive { s -= 2.5 }
            if p.isBoot { s += 1.2 }
            if p.isWaterResistant && p.slot == .outerwear { s += 1.8 }
            if p.isOpenShoe { s -= 1.0 }
        }
        if context.isSnowing && p.isBoot { s += 1.5 }
        return s
    }

    private func moodFit(_ p: ItemProfile) -> Double {
        var s = 0.0
        for (i, m) in moods.enumerated() { s += m.itemAffinity(p) * (i == 0 ? 1.0 : 0.6) }
        return s
    }

    /// Gentle pull toward the styles saved in the profile.
    private func preferenceFit(_ p: ItemProfile) -> Double {
        guard !context.preferredStyles.isEmpty, p.isClothing else { return 0 }
        let fits = context.preferredStyles.contains(where: { $0.formalityRange.contains(p.formality) })
        return fits ? 1.0 : 0
    }

    private func hintFit(_ p: ItemProfile) -> Double {
        var s = 0.0
        if p.isClothing && matchesWantedColor(p) { s += 0.8 }
        if context.hints.preferredProducts.contains(p.productKey) { s += 1.2 }
        return s
    }

    private func matchesWantedColor(_ p: ItemProfile) -> Bool {
        guard !wantedColors.isEmpty else { return false }
        return p.swatches.contains { sw in wantedColors.contains { StylePalette.matches(sw, wanted: $0) } }
    }

    func daysSinceWorn(_ p: ItemProfile) -> Int? {
        guard let worn = context.lastWorn[p.id] else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: worn), to: cal.startOfDay(for: context.now)).day
    }

    /// Worn very recently → push it down so the week doesn't repeat itself.
    private func recencyPenalty(_ p: ItemProfile) -> Double {
        guard let days = daysSinceWorn(p), days >= 0 else { return 0 }   // future = planned, not worn
        let base: Double
        switch days {
        case 0...1: base = 3.0
        case 2...3: base = 2.0
        case 4...7: base = 1.0
        case 8...14: base = 0.3
        default: base = 0
        }
        let slotFactor: Double
        switch p.slot {
        case .footwear: slotFactor = 0.4
        case .accessory: slotFactor = 0.3
        case .outerwear: slotFactor = 0.5
        case .midLayer: slotFactor = 0.7
        default: slotFactor = 1.0
        }
        return base * slotFactor
    }

    // MARK: Look scores

    func evaluate(_ items: [ItemProfile], complete: Bool) -> Evaluation {
        var score = 0.0
        for p in items { score += unary(p) }
        let clothes = items.filter { $0.isClothing }
        let palette = analyzePalette(items)
        score += palette.score * weights.palette
        score += moodPalette(palette) * weights.mood
        score += patternScore(clothes) * weights.pattern
        score += coherenceScore(items)
        score += hintScore(items)
        if complete {
            score += (layeringScore(items) + warmthScore(clothes)) * weights.weather
        }
        return Evaluation(score: score, palette: palette)
    }

    func analyzePalette(_ items: [ItemProfile]) -> PaletteAnalysis {
        struct Family { var hue: Double; var weight: Double; var saturated: Bool; var carriers: Int }
        var families: [Family] = []
        var accentItems: [ItemProfile] = []
        var multi = 0

        for p in items {
            let itemWeight = p.isClothing ? 1.0 : 0.5
            var carriesAccent = false
            for (ci, sw) in p.swatches.prefix(3).enumerated() where !sw.isNeutral {
                carriesAccent = true
                guard let h = sw.hue else { multi += 1; continue }
                let w = itemWeight * (ci == 0 ? 1.0 : 0.5)
                let leadCarrier = ci == 0 && p.isClothing
                if let fi = families.firstIndex(where: { StylePalette.hueDistance($0.hue, h) <= 35 }) {
                    families[fi].weight += w
                    families[fi].saturated = families[fi].saturated || sw.isSaturated
                    if leadCarrier { families[fi].carriers += 1 }
                } else {
                    families.append(Family(hue: h, weight: w, saturated: sw.isSaturated, carriers: leadCarrier ? 1 : 0))
                }
            }
            if carriesAccent { accentItems.append(p) }
        }

        // A secondary colour on an accessory barely registers.
        let significant = families.filter { $0.weight >= 0.5 }
        let hues = significant.map { $0.hue }
        let saturated = significant.filter { $0.saturated }.count
        let n = significant.count + (multi > 0 ? 1 : 0)

        var kind: PaletteAnalysis.Kind
        var score: Double
        switch n {
        case 0:
            kind = .neutral; score = 1.0
        case 1:
            if significant.isEmpty {
                kind = .singleAccent; score = 0.8            // one print on a neutral base
            } else if significant[0].carriers >= 2 {
                kind = .tonal; score = 1.6
            } else {
                kind = .singleAccent; score = 1.5
            }
        case 2:
            if multi > 0 || significant.count < 2 {
                kind = .triadic; score = -0.3                // a print plus another colour
            } else {
                let d = StylePalette.hueDistance(significant[0].hue, significant[1].hue)
                if d <= 55 { kind = .analogous; score = 1.0 }
                else if d >= 145 { kind = .complementary; score = 0.5 }
                else if d >= 95 { kind = .triadic; score = -0.4 }
                else { kind = .clashing; score = -1.2 }
                if saturated >= 2 && kind != .analogous { score -= 0.6 }
            }
        default:
            kind = .busy; score = -1.4 * Double(n - 2) - 0.4
        }
        return PaletteAnalysis(kind: kind, families: hues, accentItems: accentItems,
                               saturatedFamilies: saturated, score: score)
    }

    private func moodPalette(_ palette: PaletteAnalysis) -> Double {
        var s = 0.0
        for (i, m) in moods.enumerated() { s += m.paletteAffinity(palette) * (i == 0 ? 1.0 : 0.6) }
        return s
    }

    /// At most one statement pattern; stripes are semi-neutral.
    private func patternScore(_ clothes: [ItemProfile]) -> Double {
        let bold = clothes.filter { $0.patternWeight == .bold }.count
        let subtle = clothes.filter { $0.patternWeight == .subtle }.count
        var s = 0.0
        if bold >= 2 { s -= 2.5 * Double(bold - 1) }
        if bold >= 1 && subtle >= 1 { s -= 0.6 }
        if subtle >= 2 { s -= 0.7 }
        return s
    }

    private func leatherClash(_ a: ItemProfile, _ b: ItemProfile) -> Bool {
        let dark: Set<String> = ["black", "charcoal"]
        let brown: Set<String> = ["brown", "tan", "camel"]
        guard let x = a.lead?.name, let y = b.lead?.name else { return false }
        return (dark.contains(x) && brown.contains(y)) || (brown.contains(x) && dark.contains(y))
    }

    /// Formality coherence plus the classic never-do-this pairings.
    private func coherenceScore(_ items: [ItemProfile]) -> Double {
        let clothes = items.filter { $0.isClothing }
        guard !clothes.isEmpty else { return 0 }
        var s = 0.0

        let fs = clothes.map { $0.formality }
        let spread = (fs.max() ?? 0) - (fs.min() ?? 0)
        s -= max(0, spread - 2.0) * 1.8
        let mean = fs.reduce(0, +) / Double(fs.count)
        if mean < target.lowerBound { s -= (target.lowerBound - mean) }
        else if mean > target.upperBound { s -= (mean - target.upperBound) * 0.6 }

        let top = clothes.first { $0.slot == .top }
        let bottom = clothes.first { $0.slot == .bottom }
        let mid = clothes.first { $0.slot == .midLayer }
        let outer = clothes.first { $0.slot == .outerwear }
        let shoes = clothes.first { $0.slot == .footwear }
        let tailored = outer?.isTailored ?? false

        if tailored, let b = bottom, StyleKnowledge.loungeBottoms.contains(b.productKey) { s -= 4 }   // blazer + joggers
        if let sh = shoes, StyleKnowledge.dressShoes.contains(sh.productKey),
           (bottom?.showsLegs ?? false) || top?.productKey == "graphic tees" { s -= 3 }                 // oxfords + shorts
        if let sh = shoes, ["slides", "slippers", "clogs"].contains(sh.productKey),
           tailored || bottom?.productKey == "trousers" { s -= 3 }                                     // slides + trousers
        if let m = mid, ["hoodies", "sweatshirts", "fleece jackets"].contains(m.productKey), tailored { s -= 2 } // hoodie under a blazer
        if let o = outer, let b = bottom, o.productKey == "denim jackets", b.productKey == "jeans" { s -= 0.5 }
        if let t = top, let b = bottom, t.isAthletic != b.isAthletic { s -= 2.5 }

        // Ethnic pairings: kurta with churidar/salwar (or jeans/trousers), lehenga with choli.
        if let t = top, t.isEthnic, let b = bottom {
            if b.isEthnic { s += 1.2 }
            else if ["jeans", "trousers", "chinos", "leggings", "palazzo pants"].contains(b.productKey) { s += 0.3 }
            else { s -= 2.5 }
        }
        if let b = bottom, ["lehenga", "sharara", "ghagra"].contains(b.productKey) {
            if let t = top, ["choli", "blouse (saree)", "crop tops", "kurti", "kurta"].contains(t.productKey) { s += 1.5 }
            else { s -= 2.0 }
        }
        if let b = bottom, b.isEthnic, let t = top, !t.isEthnic { s -= 2.0 }

        if let belt = items.first(where: { $0.accessoryKind == .belt }), let shoes, leatherClash(belt, shoes) { s -= 0.8 }
        return s
    }

    private func hintScore(_ items: [ItemProfile]) -> Double {
        var s = 0.0
        let clothes = items.filter { $0.isClothing }
        if !wantedColors.isEmpty {
            if clothes.contains(where: { matchesWantedColor($0) }) { s += 2.5 }
            else if wantedColorAvailable { s -= 1.5 }
        }
        if !context.hints.preferredProducts.isEmpty {
            if items.contains(where: { context.hints.preferredProducts.contains($0.productKey) }) { s += 3 }
            else if wantedProductAvailable { s -= 1 }
        }
        if context.wantsEthnic && clothes.contains(where: { $0.isEthnic && $0.slot != .outerwear }) { s += 5 }
        if context.wantsActive && clothes.contains(where: { $0.isAthletic }) { s += 3 }
        return s
    }

    private func layeringScore(_ items: [ItemProfile]) -> Double {
        guard let band else { return 0 }
        let outer = items.first { $0.slot == .outerwear }
        let hasOuter = outer != nil
        let hasMid = items.contains { $0.slot == .midLayer }
        let outerAvailable = !(pools[.outerwear] ?? []).isEmpty
        let midAvailable = !(pools[.midLayer] ?? []).isEmpty
        var s = 0.0
        switch band {
        case .freezing, .cold:
            if !hasOuter && outerAvailable { s -= 3 }
            if band == .freezing && !hasMid && midAvailable { s -= 1 }
        case .cool:
            if !hasOuter && !hasMid && (outerAvailable || midAvailable) { s -= 1.5 }
        case .mild:
            if hasMid && hasOuter { s -= 0.8 }
        case .warm:
            if hasMid && hasOuter { s -= 2 }
        case .hot:
            if hasMid { s -= 3 }
            if hasOuter { s -= 1 }
        }
        if context.isRaining {
            if let outer {
                if outer.isWaterResistant { s += 1 }
            } else if (pools[.outerwear] ?? []).contains(where: { $0.isWaterResistant }) {
                s -= 1
            }
        }
        return s
    }

    /// Total insulation vs. what the temperature calls for. Over-dressing in the
    /// cold is forgiven (the coat comes off indoors); over-dressing in heat isn't.
    private func warmthScore(_ clothes: [ItemProfile]) -> Double {
        guard let t = temperature else { return 0 }
        var total = 0.0
        for p in clothes { total += p.slot == .footwear ? (p.isBoot ? 0.3 : 0) : p.warmth }
        let goal = min(8.5, max(0.8, 7.4 - 0.25 * t))
        let diff = total - goal
        let excessTolerance = t < 12 ? 2.5 : 1.0
        if diff < -0.6 { return -(-diff - 0.6) * 1.3 }
        if diff > excessTolerance { return -(diff - excessTolerance) * 1.1 }
        return 0.4
    }

    // MARK: Composition

    private func tieKey(_ items: [ItemProfile]) -> String {
        items.map { String($0.order) }.joined(separator: ",")
    }

    /// Deterministic per-look jitter (FNV-1a over item positions — not `Hasher`,
    /// which is randomly seeded per process).
    private func lookJitter(_ items: [ItemProfile]) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for p in items.sorted(by: { $0.order < $1.order }) {
            h = (h ^ UInt64(truncatingIfNeeded: p.order)) &* 0x100000001b3
        }
        return jitter(h, salt: 2) * weights.jitter * 0.6
    }

    /// Best `limit` pool items for `slot` alongside `core`.
    private func best(_ slot: OutfitSlot, for core: [ItemProfile], limit: Int) -> [ItemProfile] {
        let ids = Set(core.map { $0.id })
        let pool = (pools[slot] ?? []).filter { !ids.contains($0.id) }.prefix(10)
        let scored = pool.map { ($0, evaluate(core + [$0], complete: false).score) }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.order < $1.0.order }
            .prefix(limit)
            .map { $0.0 }
    }

    /// The top that belongs under a one-piece that needs one: a saree blouse or
    /// choli under a saree, a plain tee/shirt under dungarees.
    private func bestTop(under onePiece: [ItemProfile], given: [ItemProfile]) -> ItemProfile? {
        guard let one = onePiece.first(where: { $0.needsTopUnder }) else { return nil }
        let ids = Set(given.map { $0.id })
        let pool = (pools[.top] ?? []).isEmpty ? all.filter { $0.slot == .top } : (pools[.top] ?? [])
        let fits = pool.filter { top in
            guard !ids.contains(top.id) else { return false }
            if one.productKey == "saree" { return ["blouse (saree)", "choli"].contains(top.productKey) }
            return !top.isEthnic && !top.isAthletic
        }
        return fits.max { a, b in
            let sa = evaluate(given + [a], complete: false).score
            let sb = evaluate(given + [b], complete: false).score
            return sa != sb ? sa < sb : a.order > b.order
        }
    }

    private func bestFill(_ slot: OutfitSlot, given: [ItemProfile]) -> ItemProfile? {
        let ids = Set(given.map { $0.id })
        var pool = (pools[slot] ?? []).filter { !ids.contains($0.id) }
        if pool.isEmpty { pool = all.filter { $0.slot == slot && !ids.contains($0.id) && !hardAvoided($0) } }
        return pool.max { a, b in
            let sa = evaluate(given + [a], complete: false).score
            let sb = evaluate(given + [b], complete: false).score
            return sa != sb ? sa < sb : a.order > b.order
        }
    }

    func candidates(locked: [ItemProfile]) -> [Candidate] {
        var forced: [OutfitSlot: [ItemProfile]] = [:]
        for p in locked where p.slot != .accessory { forced[p.slot, default: []].append(p) }

        func choices(_ slot: OutfitSlot, limit: Int) -> [[ItemProfile]] {
            if let f = forced[slot] { return [f] }
            return (pools[slot] ?? []).prefix(limit).map { [$0] }
        }

        // 1) Cores: top + bottom, or a one-piece (with a top under it if needed).
        var cores: [[ItemProfile]] = []
        let forcedOnePiece = forced[.onePiece] != nil
        let forcedSeparates = forced[.top] != nil || forced[.bottom] != nil
        if !forcedOnePiece {
            for t in choices(.top, limit: 16) {
                for b in choices(.bottom, limit: 12) { cores.append(t + b) }
            }
        }
        if forcedOnePiece || !forcedSeparates {
            for o in choices(.onePiece, limit: 10) {
                var look = o
                if o.contains(where: { $0.needsTopUnder }) {
                    if let tops = forced[.top] {
                        look += tops
                    } else if let top = bestTop(under: o, given: o) {
                        look.append(top)
                    } else if !o.contains(where: { $0.productKey == "saree" }) {
                        continue   // dungarees with nothing to wear under them
                    }
                }
                cores.append(look)
            }
        }
        guard !cores.isEmpty else { return [] }

        let rankedCores = cores
            .map { ($0, evaluate($0, complete: false).score) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : tieKey($0.0) < tieKey($1.0) }
            .prefix(48)

        // 2) Layering plan: outerwear is mandatory when it's cold (or cool + wet).
        let cold = band.map { $0 <= .cold } ?? false
        let coolAndWet = context.isRaining && (band.map { $0 <= .cool } ?? false)
        let outerRequired = (cold || coolAndWet) && !(pools[.outerwear] ?? []).isEmpty
        let none: [[ItemProfile]] = [[]]

        // 3) Expand each core with shoes, an optional mid-layer and outerwear.
        var result: [Candidate] = []
        for (core, _) in rankedCores {
            var shoes: [[ItemProfile]] = forced[.footwear].map { [$0] } ?? best(.footwear, for: core, limit: 3).map { [$0] }
            if shoes.isEmpty { shoes = none }
            let mids: [[ItemProfile]] = forced[.midLayer].map { [$0] }
                ?? (none + best(.midLayer, for: core, limit: 2).map { [$0] })
            var outers: [[ItemProfile]] = forced[.outerwear].map { [$0] }
                ?? best(.outerwear, for: core, limit: outerRequired ? 3 : 2).map { [$0] }
            if forced[.outerwear] == nil && (!outerRequired || outers.isEmpty) { outers.insert([], at: 0) }

            for s in shoes {
                for m in mids {
                    for o in outers {
                        let items = core + s + m + o
                        let e = evaluate(items, complete: true)
                        result.append(Candidate(items: items, score: e.score + lookJitter(items), palette: e.palette))
                    }
                }
            }
        }
        return result
    }

    // MARK: Diverse selection (MMR)

    private func violatesCaps(_ c: Candidate, _ usage: [UUID: Int]) -> Bool {
        for p in c.items where p.isClothing {
            let cap = p.slot == .footwear ? 3 : 2
            if (usage[p.id] ?? 0) >= cap { return true }
        }
        return false
    }

    private func overlap(_ c: Candidate, _ chosen: [Candidate]) -> Double {
        var total = 0.0
        let buckets = c.palette.familyBuckets
        for o in chosen {
            for p in c.items where o.idSet.contains(p.id) { total += p.slot.overlapWeight }
            if !buckets.isEmpty && buckets == o.palette.familyBuckets { total += 0.3 }
        }
        return total
    }

    /// Greedy maximal-marginal-relevance pick: each next look maximises
    /// score − variety × overlap(with looks already chosen). First pass caps any
    /// garment at two looks (shoes at three); the second relaxes caps for small
    /// wardrobes. Identical cores are never repeated.
    func diverseSelection(_ candidates: [Candidate], count: Int) -> [Candidate] {
        var pool = candidates.sorted { $0.score != $1.score ? $0.score > $1.score : $0.signature < $1.signature }
        if pool.count > 900 { pool = Array(pool.prefix(900)) }
        var chosen: [Candidate] = []
        var signatures = Set<String>()
        var usage: [UUID: Int] = [:]

        for strict in [true, false] {
            while chosen.count < count {
                var bestIndex: Int? = nil
                var bestValue = -Double.infinity
                for (i, c) in pool.enumerated() {
                    if signatures.contains(c.signature) { continue }
                    if strict && violatesCaps(c, usage) { continue }
                    let value = c.score - weights.variety * overlap(c, chosen)
                    if value > bestValue {
                        bestValue = value
                        bestIndex = i
                    }
                }
                guard let index = bestIndex else { break }
                let pick = pool.remove(at: index)
                chosen.append(pick)
                signatures.insert(pick.signature)
                for p in pick.items where p.isClothing { usage[p.id, default: 0] += 1 }
            }
        }
        return chosen
    }

    // MARK: Finishing

    func finish(_ c: Candidate, locked: [ItemProfile], variant: UInt64) -> Outfit {
        var items = c.items
        for p in locked where p.slot == .accessory && !items.contains(where: { $0.id == p.id }) {
            items.append(p)
        }
        let present = items.filter { $0.slot == .accessory }.count
        let extras = pickAccessories(for: items, limit: max(0, 2 - present))
        for e in extras { accessoryUse[e.id, default: 0] += 1 }
        items += extras
        return outfit(from: items, variant: variant)
    }

    func outfit(from items: [ItemProfile], variant: UInt64) -> Outfit {
        let palette = analyzePalette(items)
        let text = explain(items, palette: palette, variant: variant)
        let ordered = items.sorted { $0.slot != $1.slot ? $0.slot < $1.slot : $0.order < $1.order }
        return Outfit(items: ordered.map { $0.item }, explanation: text)
    }

    /// 0–2 finishing pieces that genuinely add something: a belt only with belt
    /// loops (and matching leather), a tie only with a dress shirt, sunglasses
    /// only in daylight, a scarf when it's cold…
    private func pickAccessories(for items: [ItemProfile], limit: Int) -> [ItemProfile] {
        guard limit > 0 else { return [] }
        let ids = Set(items.map { $0.id })
        var kinds = Set(items.compactMap { $0.accessoryKind })
        let base = analyzePalette(items).score
        let top = items.first { $0.slot == .top }
        let bottom = items.first { $0.slot == .bottom }
        let shoes = items.first { $0.slot == .footwear }
        let t = temperature ?? 18

        var scored: [(ItemProfile, Double)] = []
        for a in pools[.accessory] ?? [] where !ids.contains(a.id) {
            guard let kind = a.accessoryKind, !kinds.contains(kind) else { continue }
            var s = unary(a)
            switch kind {
            case .belt:
                guard let b = bottom, StyleKnowledge.beltLoopBottoms.contains(b.productKey) else { continue }
                if let shoes, leatherClash(a, shoes) { s -= 1.5 }
                s += 0.4
            case .tie:
                guard let top, StyleKnowledge.tieTops.contains(top.productKey), target.lowerBound >= 3.4 else { continue }
                s += 1.0
            case .eyewear:
                s += 0.6
            case .neckwear:
                s += t < 10 ? 1.2 : 0
            case .headwear:
                if a.productKey == "beanies" { s += t < 6 ? 1.0 : 0 }
                else if ["sun hats", "visors", "bucket hats"].contains(a.productKey) { s += t >= 25 ? 0.8 : 0 }
            case .watch:
                s += 0.4
            case .bag:
                s += 0.3
            case .jewelry:
                s += moods.contains(where: { $0 == .romantic || $0 == .polished || $0 == .bold }) ? 0.5 : 0.1
            case .other:
                s += (a.productKey == "dupatta" && context.wantsEthnic) ? 1.2 : 0
            }
            s += (analyzePalette(items + [a]).score - base) * weights.palette
            s -= Double(accessoryUse[a.id] ?? 0) * 0.6
            scored.append((a, s))
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.order < $1.0.order }

        var picked: [ItemProfile] = []
        for (a, s) in scored where picked.count < limit && s >= 1.0 {
            guard let kind = a.accessoryKind, !kinds.contains(kind) else { continue }
            kinds.insert(kind)
            picked.append(a)
        }
        return picked
    }

    // MARK: Shuffle / add

    /// Keeps a look physically valid after a swap: one per singleton slot, a
    /// one-piece drops separate bottoms (and tops unless it needs one under it),
    /// separates get any missing half filled.
    func repaired(_ input: [ItemProfile]) -> [ItemProfile] {
        var seenSlots = Set<OutfitSlot>()
        var items: [ItemProfile] = []
        for p in input {
            if p.slot.isSingleton {
                if seenSlots.contains(p.slot) { continue }
                seenSlots.insert(p.slot)
            }
            items.append(p)
        }
        if let one = items.first(where: { $0.slot == .onePiece }) {
            items.removeAll { $0.slot == .bottom }
            if one.needsTopUnder {
                if !items.contains(where: { $0.slot == .top }), let top = bestTop(under: [one], given: items) {
                    items.append(top)
                }
            } else {
                items.removeAll { $0.slot == .top }
            }
        } else {
            if !items.contains(where: { $0.slot == .top }), let top = bestFill(.top, given: items) { items.append(top) }
            if !items.contains(where: { $0.slot == .bottom }), let bottom = bestFill(.bottom, given: items) { items.append(bottom) }
        }
        return items
    }

    func shuffled(_ target: ItemProfile, in outfit: [ItemProfile], excluding: Set<UUID>) -> [ItemProfile]? {
        let rest = outfit.filter { $0.id != target.id }
        let restIDs = Set(rest.map { $0.id })
        func usable(_ p: ItemProfile) -> Bool {
            p.id != target.id && !excluding.contains(p.id) && !restIDs.contains(p.id)
        }

        var options = (pools[target.slot] ?? []).filter(usable)
        if target.slot == .accessory {
            let restKinds = Set(rest.compactMap { $0.accessoryKind })
            let sameKind = options.filter { $0.accessoryKind == target.accessoryKind }
            options = sameKind.isEmpty
                ? options.filter { candidate in
                    guard let kind = candidate.accessoryKind else { return false }
                    return !restKinds.contains(kind)
                }
                : sameKind
        }
        if options.isEmpty {
            // Nothing passes today's filters — any other piece of the slot beats a dead button.
            options = all.filter { $0.slot == target.slot && !hardAvoided($0) && usable($0) }
            if target.slot == .accessory { options = options.filter { $0.accessoryKind == target.accessoryKind } }
        }
        guard !options.isEmpty else { return nil }

        var bestItems: [ItemProfile]? = nil
        var bestScore = -Double.infinity
        for o in options {
            let items = repaired(outfit.map { $0.id == target.id ? o : $0 })
            let score = evaluate(items, complete: true).score + jitter(UInt64(truncatingIfNeeded: o.order), salt: 11) * 0.8
            if score > bestScore {
                bestScore = score
                bestItems = items
            }
        }
        return bestItems
    }

    func adding(category: Category, productType: String, to outfit: [ItemProfile]) -> [ItemProfile]? {
        let ids = Set(outfit.map { $0.id })
        let wanted = productType.lowercased()
        let options = all.filter { $0.item.category == category && $0.productKey == wanted && !ids.contains($0.id) }
        guard !options.isEmpty else { return nil }

        var bestItems: [ItemProfile]? = nil
        var bestScore = -Double.infinity
        for o in options {
            let items = merge(o, into: outfit)
            let score = evaluate(items, complete: true).score + jitter(UInt64(truncatingIfNeeded: o.order), salt: 13) * 0.5
            if score > bestScore {
                bestScore = score
                bestItems = items
            }
        }
        return bestItems
    }

    private func merge(_ new: ItemProfile, into outfit: [ItemProfile]) -> [ItemProfile] {
        var items = outfit
        switch new.slot {
        case .accessory:
            if let kind = new.accessoryKind { items.removeAll { $0.accessoryKind == kind } }
            items.append(new)
            return items
        case .onePiece:
            items.removeAll { $0.slot == .onePiece || $0.slot == .bottom || (!new.needsTopUnder && $0.slot == .top) }
        case .top:
            if let one = items.first(where: { $0.slot == .onePiece }), !one.needsTopUnder {
                items.removeAll { $0.slot == .onePiece }
            }
            items.removeAll { $0.slot == .top }
        case .bottom:
            items.removeAll { $0.slot == .onePiece || $0.slot == .bottom }
        default:
            items.removeAll { $0.slot == new.slot }
        }
        items.append(new)
        return repaired(items)
    }

    // MARK: Explanations

    /// A short stylist note built from the same signals the score used:
    /// "Light layers for 14°C and cloudy — the camel coat warms up the navy knit."
    func explain(_ items: [ItemProfile], palette: PaletteAnalysis, variant: UInt64) -> String {
        var rng = SeededGenerator(seed: seed ^ (variant &* 0x2545F4914F6CDD1D) ^ 0x5DEECE66D)
        let story = colourStory(items, palette: palette, rng: &rng)
        var text: String
        if let lead = weatherLead(items, rng: &rng) {
            text = "\(lead) — \(story)."
        } else {
            text = StyleVocabulary.capitalizedFirst(story) + "."
        }
        if let closer = closingNote(items, rng: &rng) {
            text += " " + StyleVocabulary.capitalizedFirst(closer) + "."
        }
        return text
    }

    private func formattedTemperature(_ t: Double) -> String {
        context.useFahrenheit ? "\(Int((t * 9 / 5 + 32).rounded()))°F" : "\(Int(t.rounded()))°C"
    }

    private var conditionPhrase: String? {
        let c = context.conditionText
        if c.isEmpty || c == "unknown" { return nil }
        if c.contains("thunder") { return "stormy" }
        if c.contains("snow") { return "snowy" }
        if c.contains("sleet") { return "sleety" }
        if c.contains("rain") || c.contains("drizzle") || c.contains("shower") { return "rainy" }
        if c.contains("fog") { return "foggy" }
        if c.contains("partly") { return "partly cloudy" }
        if c.contains("cloud") || c.contains("overcast") { return "cloudy" }
        if c.contains("clear") || c.contains("fair") || c.contains("sun") { return context.isDark ? "clear" : "sunny" }
        return nil
    }

    private func weatherLead(_ items: [ItemProfile], rng: inout SeededGenerator) -> String? {
        guard let t = temperature, let band else { return nil }
        let fromRequest = context.hints.temperatureC != nil
        let label = fromRequest ? band.spoken : formattedTemperature(t)
        let and = (!fromRequest ? conditionPhrase : nil).map { " and \($0)" } ?? ""
        let hasLayer = items.contains { $0.slot == .outerwear || $0.slot == .midLayer }

        if context.isRaining, items.contains(where: { ($0.slot == .outerwear && $0.isWaterResistant) || $0.isBoot }) {
            return rng.choose(["Rain-ready for \(label)\(and)", "Rain-proofed for \(label)"])
        }
        switch band {
        case .hot:
            return rng.choose(["Kept it breezy for \(label)", "Light and airy for \(label)\(and)", "Nothing heavy for \(label)"])
        case .warm:
            return rng.choose(["Easy, light pieces for \(label)\(and)", "Breathable picks for \(label)"])
        case .mild:
            return hasLayer
                ? rng.choose(["A light layer for \(label)\(and)", "Just-right layering for \(label)"])
                : rng.choose(["Easy pieces for \(label)\(and)", "Just right for \(label)\(and)"])
        case .cool:
            return rng.choose(["Light layers for \(label)\(and)", "Layered up for \(label)"])
        case .cold, .freezing:
            return rng.choose(["Bundled up for \(label)\(and)", "Warm layers for \(label)"])
        }
    }

    private func colourStory(_ items: [ItemProfile], palette: PaletteAnalysis, rng: inout SeededGenerator) -> String {
        let clothes = items.filter { $0.isClothing }
        guard let first = clothes.first else { return "a simple, easy look" }
        let outer = clothes.first { $0.slot == .outerwear }
        let mid = clothes.first { $0.slot == .midLayer }
        let base = clothes.first { $0.slot == .top || $0.slot == .onePiece }
        let bottom = clothes.first { $0.slot == .bottom }
        let shoes = clothes.first { $0.slot == .footwear }
        func d(_ p: ItemProfile) -> String { StyleVocabulary.describe(p) }

        // The top layer against what's under it.
        if let outer, let under = mid ?? base, [.neutral, .singleAccent, .tonal].contains(palette.kind) {
            if let o = outer.lead, o.isNeutral, o.isWarm,
               (under.lead?.isCool ?? false) || (under.lead?.isDark ?? false) || under.lead?.hue == nil {
                return "the \(d(outer)) warms up the \(d(under))"
            }
            if let o = outer.lead, o.isDark, outer.formality >= 3.4 {
                return "the \(d(outer)) sharpens the \(d(under))"
            }
        }

        switch palette.kind {
        case .neutral:
            let a = outer ?? mid ?? base ?? first
            if let b = (a.id == base?.id ? (bottom ?? shoes) : base) ?? bottom {
                return rng.choose([
                    "the \(d(a)) and \(d(b)) keep it clean and neutral",
                    "an all-neutral mix anchored by the \(d(a))",
                    "neutral on neutral, the \(d(a)) with the \(d(b))"
                ])
            }
            return "an all-neutral look built on the \(d(a))"
        case .tonal:
            let carrier = palette.accentItems.first(where: { $0.isClothing }) ?? first
            let name = carrier.lead?.name ?? "colour"
            return rng.choose(["head-to-toe \(name) keeps it tonal", "tonal \(name) from the \(d(carrier)) down"])
        case .singleAccent:
            let accent = palette.accentItems.first(where: { $0.isClothing }) ?? palette.accentItems.first ?? first
            if let partner = clothes.first(where: { $0.id != accent.id && $0.isNeutral && $0.slot != .footwear })
                ?? clothes.first(where: { $0.id != accent.id }) {
                return rng.choose([
                    "the \(d(accent)) pops against the \(d(partner))",
                    "the \(d(accent)) does the talking, the \(d(partner)) keeps it grounded",
                    "one hit of colour, the \(d(accent)), with the \(d(partner))"
                ])
            }
            return "the \(d(accent)) brings the colour"
        case .analogous, .complementary:
            let accents = palette.accentItems.filter { $0.isClothing }
            let a = accents.first ?? first
            let b = accents.dropFirst().first ?? clothes.first(where: { $0.id != a.id }) ?? a
            if palette.kind == .analogous {
                return rng.choose(["the \(d(a)) flows into the \(d(b))", "neighbouring shades, \(d(a)) and \(d(b))"])
            }
            return rng.choose(["the \(d(a)) plays off the \(d(b))", "\(d(a)) and \(d(b)) for a confident contrast"])
        case .triadic, .clashing, .busy:
            let lead = palette.accentItems.first(where: { $0.isClothing }) ?? first
            return "a confident colour mix led by the \(d(lead))"
        }
    }

    private func closingNote(_ items: [ItemProfile], rng: inout SeededGenerator) -> String? {
        let clothes = items.filter { $0.isClothing }
        if let wanted = context.hints.preferredColors.first, clothes.contains(where: { matchesWantedColor($0) }) {
            return "with the \(wanted) you asked for"
        }
        var options: [String] = []
        if let mood = moods.first { options.append(mood.closer(for: context.resolvedOccasion)) }
        if context.occasionWasStated { options.append(context.resolvedOccasion.stylistPhrase) }
        if !context.lastWorn.isEmpty,
           clothes.allSatisfy({ (daysSinceWorn($0) ?? 99) > 7 }) {
            options.append("none of it worn in the last week")
        }
        guard let first = options.first else { return nil }
        if options.count > 1 && rng.unit() >= 0.7 { return options[1] }
        return first
    }
}

// MARK: - Vocabulary

/// Natural garment descriptions for explanations ("navy knit", "camel coat").
enum StyleVocabulary {
    private static let nouns: [String: String] = [
        "t-shirts": "tee", "graphic tees": "graphic tee", "polo t-shirts": "polo", "button-down shirts": "shirt",
        "shirts": "shirt", "flannel shirts": "flannel", "tank tops": "tank", "turtlenecks": "turtleneck",
        "sweaters": "sweater", "pullovers": "pullover", "cardigans": "cardigan", "hoodies": "hoodie",
        "sweatshirts": "sweatshirt", "quarter-zips": "quarter-zip", "fleece jackets": "fleece",
        "jeans": "jeans", "trousers": "trousers", "chinos": "chinos", "cargo pants": "cargos",
        "wide-leg pants": "wide-leg trousers", "linen pants": "linen trousers", "palazzo pants": "palazzos",
        "sweatpants": "sweatpants", "joggers": "joggers", "leggings": "leggings", "shorts": "shorts",
        "skirts": "skirt", "mini skirts": "mini skirt", "dresses": "dress", "wrap dresses": "wrap dress",
        "maxi dresses": "maxi dress", "shirt dresses": "shirt dress", "jumpsuits": "jumpsuit",
        "sneakers": "sneakers", "boots": "boots", "ankle boots": "ankle boots", "chelsea boots": "Chelsea boots",
        "sandals": "sandals", "loafers": "loafers", "oxford shoes": "oxfords", "formal shoes": "dress shoes",
        "heels": "heels", "flats": "flats", "coats": "coat", "overcoats": "overcoat", "trench coats": "trench",
        "blazers": "blazer", "parkas": "parka", "puffer jackets": "puffer", "leather jackets": "leather jacket",
        "denim jackets": "denim jacket", "bomber jackets": "bomber", "raincoats": "raincoat",
        "windbreakers": "windbreaker", "jackets": "jacket", "dungarees": "dungarees", "overalls": "overalls"
    ]

    static func noun(for p: ItemProfile) -> String {
        if p.productKey == "sweaters" || p.productKey == "pullovers",
           p.text.styleContainsAny(["knit", "wool", "cashmere", "merino"]) {
            return "knit"
        }
        return nouns[p.productKey] ?? p.item.displayProduct.lowercased()
    }

    static func describe(_ p: ItemProfile) -> String {
        let word = noun(for: p)
        if p.patternWeight == .bold { return "\(p.item.pattern.rawValue.lowercased()) \(word)" }
        guard let colour = p.item.colors.first?.trimmingCharacters(in: .whitespaces).lowercased(),
              !colour.isEmpty, !(p.lead?.isMulti ?? false) else { return word }
        if word.contains(colour) || (colour == "denim" && word == "jeans") { return word }
        return "\(colour) \(word)"
    }

    static func describe(_ item: WardrobeItem) -> String {
        if let p = ItemProfile(item, order: 0) { return describe(p) }
        return item.displayProduct.lowercased()
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.uppercased() + s.dropFirst()
    }
}
