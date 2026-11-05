import Foundation

/// Retention loop B — the calendar fills itself. When the scan finds a recent
/// photo of the user (new photos are picked up automatically), the garments in
/// it are matched to closet items (`DuplicateDetector` on the FashionSigLIP
/// embeddings) and StyleMate offers: "Wore this on Tue? Camel coat + navy
/// cardigan — Log it". One tap logs a `DatedOutfit` for that day through
/// `MyOutfitsViewModel.addOutfit`, which also feeds the stylist's recency rule.
///
/// Suggestions persist per profile in UserDefaults; answered photos are never
/// asked about again.
@MainActor
final class WearLogSuggestions: ObservableObject {
    static let shared = WearLogSuggestions()

    /// `DatedOutfit.source` for looks logged from a photo.
    nonisolated static let source = "photo"
    /// Only photos this recent are worth asking about.
    nonisolated static let maxAgeDays = 7
    nonisolated static let maxPending = 5

    struct Suggestion: Codable, Identifiable, Equatable {
        var id: String { photoID }
        let photoID: String
        let date: Date
        var itemIDs: [UUID]
    }

    @Published private(set) var pending: [Suggestion] = []
    private var userId = ""
    private var answered: Set<String> = []

    private init() {}

    private func pendingKey(_ u: String) -> String { "wearLogSuggestions_\(u)" }
    private func answeredKey(_ u: String) -> String { "wearLogAnswered_\(u)" }

    func load(forUser userId: String) {
        guard self.userId != userId else { return }
        self.userId = userId
        let d = UserDefaults.standard
        pending = (d.data(forKey: pendingKey(userId)).flatMap { try? JSONDecoder().decode([Suggestion].self, from: $0) }) ?? []
        answered = Set(d.stringArray(forKey: answeredKey(userId)) ?? [])
    }

    private func save() {
        guard !userId.isEmpty else { return }
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(pending) { d.set(data, forKey: pendingKey(userId)) }
        d.set(Array(answered.suffix(500)), forKey: answeredKey(userId))
    }

    func forget(forUser userId: String) {
        UserDefaults.standard.removeObject(forKey: pendingKey(userId))
        UserDefaults.standard.removeObject(forKey: answeredKey(userId))
        if self.userId == userId { pending = []; answered = []; self.userId = "" }
    }

    // MARK: Scan side

    /// A photo of the user was just extracted: `itemIDs` are the closet items
    /// it shows (new or matched). Queues a suggestion when it looks like a
    /// whole outfit from the last week.
    func consider(photoID: String, date: Date, itemIDs: [UUID], wardrobe: [WardrobeItem], userId: String,
                  now: Date = Date()) {
        load(forUser: userId)
        guard !answered.contains(photoID), !pending.contains(where: { $0.photoID == photoID }) else { return }
        let byID = Dictionary(wardrobe.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = Self.unique(itemIDs).compactMap { byID[$0] }
        guard Self.isWorthAsking(items: items, date: date, now: now) else { return }

        let cal = Calendar.current
        if let i = pending.firstIndex(where: { cal.isDate($0.date, inSameDayAs: date) }) {
            // One question per day: keep the photo that shows more of the outfit.
            guard items.count > pending[i].itemIDs.count else { return }
            answered.insert(pending[i].photoID)
            pending[i] = Suggestion(photoID: photoID, date: date, itemIDs: items.map(\.id))
        } else {
            pending.append(Suggestion(photoID: photoID, date: date, itemIDs: items.map(\.id)))
            pending.sort { $0.date > $1.date }
            if pending.count > Self.maxPending { pending.removeLast(pending.count - Self.maxPending) }
        }
        save()
        print("[StyleMate] Wear log: suggesting \(items.count) items on \(date)")
    }

    // MARK: User side

    /// The suggestion to show now: the newest one whose day isn't logged yet.
    func next(loggedDays: Set<Date>, now: Date = Date()) -> Suggestion? {
        let cal = Calendar.current
        return pending.first { s in
            Self.ageInDays(s.date, now: now) <= Self.maxAgeDays && !loggedDays.contains(cal.startOfDay(for: s.date))
        }
    }

    func log(_ s: Suggestion, wardrobe: [WardrobeItem], outfits: MyOutfitsViewModel) {
        let ids = Set(s.itemIDs)
        let items = wardrobe.filter { ids.contains($0.id) }
        if !items.isEmpty {
            outfits.addOutfit(date: s.date, items: items, source: Self.source, notes: "Logged from your photo")
        }
        resolve(s)
    }

    func dismiss(_ s: Suggestion) { resolve(s) }

    private func resolve(_ s: Suggestion) {
        answered.insert(s.photoID)
        pending.removeAll { $0.photoID == s.photoID }
        save()
    }

    // MARK: Rules + copy (pure, tested)

    nonisolated static func unique(_ ids: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }
    }

    nonisolated static func ageInDays(_ date: Date, now: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? .max
    }

    /// A whole-ish outfit (2+ pieces, one of them a main garment) from the last week.
    nonisolated static func isWorthAsking(items: [WardrobeItem], date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        let age = ageInDays(date, now: now, calendar: calendar)
        guard age >= 0, age <= maxAgeDays, items.count >= 2 else { return false }
        let main: Set<Category> = [.tops, .bottoms, .onePieces, .outerwear, .midLayers, .ethnicWear, .activewear]
        return items.contains { main.contains($0.category) } && Set(items.map(\.category)).count >= 2
    }

    /// "Wore this on Tue?" / "Wore this today?" / "Wore this yesterday?"
    nonisolated static func question(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        switch ageInDays(date, now: now, calendar: calendar) {
        case 0: return "Wore this today?"
        case 1: return "Wore this yesterday?"
        default:
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE"
            return "Wore this on \(f.string(from: date))?"
        }
    }

    /// "Camel coat + navy cardigan": the two most visible pieces.
    nonisolated static func summary(of items: [WardrobeItem]) -> String {
        let rank: [Category: Int] = [.outerwear: 0, .onePieces: 1, .midLayers: 2, .ethnicWear: 2, .tops: 3,
                                     .activewear: 3, .bottoms: 4, .footwear: 5, .accessories: 6, .innerwear: 7]
        let top = items.sorted { (rank[$0.category] ?? 9) < (rank[$1.category] ?? 9) }.prefix(2)
        let names = top.map(shortName)
        guard let first = names.first else { return "" }
        let joined = names.joined(separator: " + ")
        return first.prefix(1).uppercased() + joined.dropFirst()
    }

    /// "navy cardigan": first colour + singular product, lower-cased.
    nonisolated static func shortName(_ item: WardrobeItem) -> String {
        let product = ClosetText.displayProduct(item.product).lowercased()
        guard let color = item.colors.first?.trimmingCharacters(in: .whitespaces), !color.isEmpty else { return product }
        return "\(color.lowercased()) \(product)"
    }
}
