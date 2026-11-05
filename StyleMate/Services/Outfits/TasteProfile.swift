import Foundation

// MARK: - Taste learning (on device, per profile)
//
// The stylist learns what this person actually likes from what they do in the
// deck, and from nothing else:
//
//   Wear today      the look's pieces and colour pairings (+), the formality worn for the occasion
//   Keep (lock)     that piece (+); un-keeping takes it back
//   Swap            the piece swapped out (−, gently)
//   Skip            the look's pairings and pieces (− , weak); "Not my style" makes it a real
//                   signal, "Not today" teaches nothing
//
// The model is a handful of small dictionaries (`TasteProfile`, a few KB), kept in
// UserDefaults under the local profile id. It never leaves the phone: not in the
// iCloud sync, not in any report. Every value is bounded, decays with a 45-day
// half-life and is pruned, so old habits fade and the model can't grow. Profile →
// "Reset style learning" wipes it.
//
// The engine reads it as one bounded term next to the recency penalty
// (`StylingPass.tasteFit`); see `OutfitEngine` for the guard that keeps learning
// from ever promoting a look the stylist wouldn't otherwise rate near the top.

/// What one action in the deck says about taste.
enum TasteSignal: Equatable {
    case wore
    case kept
    case unkept
    case swappedOut
    /// A skip with no answer to "Not my style / Not today".
    case skipped
    case notMyStyle
}

/// The learned preferences of one person. Plain values (tests build one directly).
struct TasteProfile: Codable, Equatable {
    /// Evidence per colour pairing: the two garments' canonical lead colours, sorted
    /// and joined ("gray|navy"). One worn look adds 1 to each pairing in it.
    var pairs: [String: Double] = [:]
    /// Evidence per wardrobe item (UUID string).
    var items: [String: Double] = [:]
    /// The formality actually worn per occasion (`OutfitType.rawValue`).
    var formality: [String: FormalitySample] = [:]
    /// When the evidence was last decayed to.
    var updated: Date
    /// Teaching events so far (Profile shows whether anything has been learned).
    var events: Int = 0

    struct FormalitySample: Codable, Equatable {
        var mean: Double
        var weight: Double
    }

    init(updated: Date = Date()) {
        self.updated = updated
    }

    var isEmpty: Bool { pairs.isEmpty && items.isEmpty && formality.isEmpty }

    // MARK: Rules

    enum Rules {
        /// Evidence halves every 45 days without reinforcement.
        static let halfLifeDays = 45.0
        /// Each value stays within ±6 (six worn looks' worth).
        static let maxEvidence = 6.0
        /// The formality mean keeps adapting: its weight never exceeds this.
        static let maxFormalityWeight = 10.0
        static let maxPairs = 60
        static let maxItems = 160
        /// Values that decayed below this are dropped.
        static let pruneBelow = 0.05
    }

    /// (item evidence, pair evidence) per signal.
    private static func amounts(_ signal: TasteSignal) -> (item: Double, pair: Double) {
        switch signal {
        case .wore: return (1.0, 1.0)
        case .kept: return (0.5, 0)
        case .unkept: return (-0.5, 0)
        case .swappedOut: return (-0.35, -0.2)
        case .skipped: return (-0.1, -0.15)
        case .notMyStyle: return (-0.5, -0.8)
        }
    }

    // MARK: Learning

    /// Folds one action into the profile. `piece` is the kept / un-kept / swapped-out item
    /// (pair evidence for a swap only touches that piece's pairings).
    mutating func learn(_ signal: TasteSignal, look: [WardrobeItem], piece: WardrobeItem? = nil,
                        occasion: OutfitType?, now: Date = Date()) {
        decay(to: now)
        let (itemAmount, pairAmount) = Self.amounts(signal)
        let profiles = look.compactMap { ItemProfile($0, order: 0) }

        switch signal {
        case .kept, .unkept, .swappedOut:
            guard let piece else { return }
            add(itemAmount, toItem: piece.id)
            if pairAmount != 0, let target = ItemProfile(piece, order: 0),
               !Self.pairingPieces([target]).isEmpty {
                for key in Self.pairKeys(profiles).filter({ Self.pair($0, involves: target) }) {
                    add(pairAmount, toPair: key)
                }
            }
        case .wore, .skipped, .notMyStyle:
            for p in profiles {
                add(p.isClothing ? itemAmount : itemAmount * 0.5, toItem: p.id)
            }
            for key in Self.pairKeys(profiles) { add(pairAmount, toPair: key) }
            if signal == .wore, let occasion, let mean = Self.lookFormality(profiles) {
                var sample = formality[occasion.rawValue] ?? FormalitySample(mean: mean, weight: 0)
                let w = min(Rules.maxFormalityWeight, sample.weight + 1)
                sample.mean += (mean - sample.mean) / w
                sample.weight = w
                formality[occasion.rawValue] = sample
            }
        }
        events += 1
        prune()
    }

    /// Exponential decay of every value to `now` (never forward in time from a later date).
    mutating func decay(to now: Date) {
        let days = now.timeIntervalSince(updated) / 86_400
        guard days > 0 else { return }
        let factor = pow(0.5, days / Rules.halfLifeDays)
        pairs = pairs.mapValues { $0 * factor }
        items = items.mapValues { $0 * factor }
        formality = formality.mapValues { FormalitySample(mean: $0.mean, weight: $0.weight * factor) }
        updated = now
        prune()
    }

    /// A copy decayed to `now`.
    func decayed(to now: Date) -> TasteProfile {
        var copy = self
        copy.decay(to: now)
        return copy
    }

    private mutating func add(_ amount: Double, toItem id: UUID) {
        guard amount != 0 else { return }
        let key = id.uuidString
        items[key] = Self.clamp((items[key] ?? 0) + amount)
    }

    private mutating func add(_ amount: Double, toPair key: String) {
        guard amount != 0 else { return }
        pairs[key] = Self.clamp((pairs[key] ?? 0) + amount)
    }

    private static func clamp(_ v: Double) -> Double {
        min(Rules.maxEvidence, max(-Rules.maxEvidence, v))
    }

    private mutating func prune() {
        pairs = pairs.filter { abs($0.value) >= Rules.pruneBelow }
        items = items.filter { abs($0.value) >= Rules.pruneBelow }
        formality = formality.filter { $0.value.weight >= Rules.pruneBelow }
        if pairs.count > Rules.maxPairs { pairs = Self.strongest(pairs, Rules.maxPairs) }
        if items.count > Rules.maxItems { items = Self.strongest(items, Rules.maxItems) }
    }

    /// The `n` entries with the most evidence either way (ties by key, so it's deterministic).
    private static func strongest(_ d: [String: Double], _ n: Int) -> [String: Double] {
        let kept = d.sorted { abs($0.value) != abs($1.value) ? abs($0.value) > abs($1.value) : $0.key < $1.key }
            .prefix(n)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    // MARK: Shared definitions (learning and scoring use the same ones)

    /// Garments whose colours make a pairing: clothing, not shoes or accessories.
    static func pairingPieces(_ items: [ItemProfile]) -> [ItemProfile] {
        items.filter { $0.isClothing && $0.slot != .footwear && $0.lead != nil }
    }

    /// Every pairing of two garments' lead colours in a look, once each.
    static func pairKeys(_ items: [ItemProfile]) -> [String] {
        let pieces = pairingPieces(items)
        var keys: [String] = []
        for i in pieces.indices {
            for j in pieces.indices where j > i {
                guard let a = pieces[i].lead?.name, let b = pieces[j].lead?.name else { continue }
                let key = pairKey(a, b)
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    static func pairKey(_ a: String, _ b: String) -> String {
        a <= b ? "\(a)|\(b)" : "\(b)|\(a)"
    }

    private static func pair(_ key: String, involves p: ItemProfile) -> Bool {
        guard let name = p.lead?.name else { return false }
        return key.split(separator: "|").contains { String($0) == name }
    }

    /// Mean formality of a look's clothing (shoes included, accessories not).
    static func lookFormality(_ items: [ItemProfile]) -> Double? {
        let fs = items.filter { $0.isClothing }.map { $0.formality }
        guard !fs.isEmpty else { return nil }
        return fs.reduce(0, +) / Double(fs.count)
    }

    /// Spoken colour name for a canonical swatch name ("gray" → "grey").
    static func spokenColour(_ name: String) -> String { StyleVocabulary.spokenColour(name) }
}

// MARK: - Store

/// The taste profiles on this iPhone, one per local profile id (UserDefaults, a few KB each).
/// Thread-safe: the deck writes on the main actor, the morning look reads in the background.
final class TasteStore: @unchecked Sendable {
    static let shared = TasteStore()

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(forUser userId: String) -> String { "tasteProfile.v1.\(userId)" }

    /// The profile decayed to `now`, or nil when nothing has been learned yet.
    func profile(forUser userId: String?, now: Date = Date()) -> TasteProfile? {
        guard let userId, !userId.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let stored = read(userId) else { return nil }
        let p = stored.decayed(to: now)
        return p.isEmpty ? nil : p
    }

    /// Teaching events learned so far (0 when nothing is stored).
    func events(forUser userId: String?) -> Int {
        guard let userId, !userId.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return read(userId)?.events ?? 0
    }

    func learn(_ signal: TasteSignal, look: [WardrobeItem], piece: WardrobeItem? = nil,
               occasion: OutfitType?, forUser userId: String?, now: Date = Date()) {
        guard let userId, !userId.isEmpty, !look.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var p = read(userId) ?? TasteProfile(updated: now)
        p.learn(signal, look: look, piece: piece, occasion: occasion, now: now)
        write(p, userId)
    }

    /// Profile → "Reset style learning", and part of "Delete Profile & All Data".
    func reset(forUser userId: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.key(forUser: userId))
    }

    #if DEBUG
    /// UI tests (`-uiTestSeedTaste`): store a ready-made profile.
    func store(_ profile: TasteProfile, forUser userId: String) {
        lock.lock(); defer { lock.unlock() }
        write(profile, userId)
    }
    #endif

    private func read(_ userId: String) -> TasteProfile? {
        guard let data = defaults.data(forKey: Self.key(forUser: userId)) else { return nil }
        return try? JSONDecoder().decode(TasteProfile.self, from: data)
    }

    private func write(_ p: TasteProfile, _ userId: String) {
        guard let data = try? JSONEncoder().encode(p) else { return }
        defaults.set(data, forKey: Self.key(forUser: userId))
    }
}
