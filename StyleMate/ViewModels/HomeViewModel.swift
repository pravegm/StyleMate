import Foundation
import Combine
import CoreLocation
import SwiftUI

@MainActor
class HomeViewModel: ObservableObject {
    @Published var todayOutfit: Outfit?
    @Published var isLoading = false
    @Published var showOutfitSheet = false
    @Published var showRateLimitAlert = false
    @Published var selectedOutfitType: OutfitType? = .everyday
    @Published var selectedMood: OutfitMood? = nil
    @Published var customOutfitDescription: String? = nil
    @Published var weather: Weather?
    @Published var weatherError: String?
    @Published var isWeatherLoading: Bool = false
    @Published var location: CLLocation?
    @Published var locationStatus: CLAuthorizationStatus = .notDetermined
    @Published var useFahrenheit: Bool = false
    @Published var lastCity: String? = nil
    @Published var displayFahrenheit: Bool = false
    @Published var lastCelsius: Double? = nil
    @Published var lastFahrenheit: Double? = nil

    /// Short, transient message from the stylist ("That's your only pair of shoes
    /// that works here"). The outfit sheet shows it as a toast and clears it.
    @Published var stylistNotice: String? = nil

    // Error handling
    enum OutfitError: Equatable {
        case emptyWardrobe
        case networkError
        case parseError
    }
    @Published var outfitError: OutfitError?
    @Published var showOutfitErrorAlert = false

    // Batch state for swipe UI
    @Published var outfitBatch: [Outfit] = []
    @Published var batchIndex: Int = 0
    @Published var savedCount: Int = 0
    @Published var skippedCount: Int = 0

    private var locationService = LocationService.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - On-device stylist

    /// Fully on-device recommender (no network). See Services/Outfits.
    private let engine = OutfitEngine()
    /// The outfit log, for recency ("don't repeat what you wore yesterday").
    private weak var wearLog: MyOutfitsViewModel?
    /// The context the current batch was styled for, reused by shuffle / add so
    /// edits stay consistent with the request (and skip re-reading the text).
    private var lastContext: StylingContext?
    /// Bumped per batch so late on-device rewrites never land on a newer batch.
    private var batchToken = 0
    /// Per card + slot: pieces already shown by shuffle, so taps walk through
    /// the alternatives instead of bouncing between two.
    private var shuffleHistory: [String: Set<UUID>] = [:]

    var isCustomDescriptionValid: Bool {
        guard let desc = customOutfitDescription else { return false }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { word in
            word.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil
        }
        return words.count >= 2
    }

    var allOutfitsSeen: Bool {
        batchIndex >= outfitBatch.count && !outfitBatch.isEmpty
    }

    init() {
        locationService.$location
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loc in
                guard let self = self, let loc = loc else { return }
                self.fetchWeather(for: loc)
            }
            .store(in: &cancellables)

        locationService.$locationError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.weatherError = "Unable to get location: \(error.localizedDescription)"
                    self?.isWeatherLoading = false
                }
            }
            .store(in: &cancellables)

        locationService.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.locationStatus = status
            }
            .store(in: &cancellables)

        // Show last-known weather immediately so a transient open-meteo outage
        // doesn't blank the home screen while a fresh fetch is attempted.
        if let data = UserDefaults.standard.data(forKey: Self.weatherCacheKey),
           let cached = try? JSONDecoder().decode(Weather.self, from: data) {
            weather = cached
            lastCity = cached.city
            lastCelsius = cached.temperature2m
            lastFahrenheit = (cached.temperature2m * 9.0 / 5.0) + 32.0
        }
    }

    private static let weatherCacheKey = "cachedWeather"

    /// Hook up the outfit log so recently worn pieces are de-prioritised.
    func attachWearLog(_ log: MyOutfitsViewModel) {
        wearLog = log
    }

    // MARK: - Styling context

    /// Today's context from live state. Free text is read by the on-device
    /// keyword parser; `modelHints` (from the on-device language model, when
    /// available) refine it.
    private func makeContext(user: User?, occasion: OutfitType?, description: String?,
                             mood: OutfitMood?, modelHints: StyleHints? = nil) -> StylingContext {
        var hints = StyleIntentParser.parse(description)
        if let modelHints { hints = hints.merged(with: modelHints) }
        return StylingContext(
            weather: weather,
            occasion: occasion,
            mood: mood,
            hints: hints,
            user: user,
            lastWorn: wearLog?.lastWornDates() ?? [:],
            now: Date(),
            useFahrenheit: displayFahrenheit
        )
    }

    /// The batch's context for edits, refreshed with the latest weather / log.
    private func editingContext(user: User?) -> StylingContext {
        guard var context = lastContext else {
            return makeContext(user: user, occasion: selectedOutfitType,
                               description: customOutfitDescription, mood: selectedMood)
        }
        context.lastWorn = wearLog?.lastWornDates() ?? context.lastWorn
        context.useFahrenheit = displayFahrenheit
        context.now = Date()
        return context
    }

    private static func freshSeed() -> UInt64 { UInt64.random(in: UInt64.min...UInt64.max) }

    // MARK: - Suggest Today Outfit

    func suggestTodayOutfit(from items: [WardrobeItem], user: User?) {
        guard !isLoading else { return }
        Task {
            isLoading = true
            defer { isLoading = false }

            outfitError = nil
            savedCount = 0
            skippedCount = 0
            let started = Date()

            let description = customOutfitDescription
            var modelHints: StyleHints? = nil
            if let text = description, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Never blocks for long: times out to the keyword reading.
                modelHints = await OnDeviceStylist.interpret(text)
            }
            let context = makeContext(user: user, occasion: selectedOutfitType, description: description,
                                      mood: selectedMood, modelHints: modelHints)
            lastContext = context

            let engine = self.engine
            let seed = Self.freshSeed()
            let result = await Task.detached(priority: .userInitiated) {
                engine.suggest(from: items, context: context, seed: seed)
            }.value

            // A short, deliberate styling beat so the sequence reads as intentional
            // rather than a flash (the engine itself takes milliseconds).
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 0.7 {
                try? await Task.sleep(nanoseconds: UInt64((0.7 - elapsed) * 1_000_000_000))
            }

            switch result {
            case .success(let looks):
                // Belt and braces: every shown look is complete and distinct.
                let validated = OutfitValidator.validateAndRepair(looks, wardrobe: items)
                batchToken += 1
                shuffleHistory.removeAll()
                outfitBatch = validated
                batchIndex = 0

                if let first = validated.first {
                    todayOutfit = first
                    showOutfitSheet = true
                    polishExplanations(validated, context: context)
                } else {
                    todayOutfit = nil
                    outfitError = .parseError
                    showOutfitErrorAlert = true
                }

            case .failure:
                todayOutfit = nil
                outfitBatch = []
                batchIndex = 0
                outfitError = .emptyWardrobe
                showOutfitErrorAlert = true
            }
        }
    }

    // MARK: - On-device rewrite of the notes

    /// Rewrites each note in a warmer voice with the on-device model, swapping
    /// them in as they arrive. Silently does nothing when the model is absent.
    private func polishExplanations(_ looks: [Outfit], context: StylingContext) {
        guard OnDeviceStylist.isAvailable else { return }
        let token = batchToken
        Task {
            for look in looks {
                guard token == batchToken else { return }
                let note = StylistNote(outfit: look, context: context)
                guard let text = await OnDeviceStylist.polish(note) else { continue }
                applyPolished(text, toLookWith: look.items.map { $0.id }, token: token)
            }
        }
    }

    private func polishSingle(_ look: Outfit) {
        guard OnDeviceStylist.isAvailable, let context = lastContext else { return }
        let token = batchToken
        Task {
            guard let text = await OnDeviceStylist.polish(StylistNote(outfit: look, context: context)) else { return }
            applyPolished(text, toLookWith: look.items.map { $0.id }, token: token)
        }
    }

    private func applyPolished(_ text: String, toLookWith ids: [UUID], token: Int) {
        guard token == batchToken else { return }
        guard let index = outfitBatch.firstIndex(where: { $0.items.map { $0.id } == ids }) else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            outfitBatch[index].explanation = text
            if index == batchIndex { todayOutfit = outfitBatch[index] }
        }
    }

    // MARK: - Today's Outfit Hero
    //
    // One ready "pick of the day" shown on Home so the app opens on an answer, not
    // a form. Generated once per day when weather is ready, then cached (item IDs +
    // reason) so re-opening is instant and costs nothing.

    @Published var heroOutfit: Outfit?
    @Published var isGeneratingHero = false

    /// The wardrobe must be this rich before we surface a "Today's Outfit" on Home.
    static let minItemsForHero = 30

    private static let heroCacheKey = "todayHeroOutfit"

    private struct HeroCache: Codable {
        let dayKey: Double          // startOfDay reference time — one hero per calendar day
        let itemIDs: [String]
        let explanation: String
    }

    private var todayKey: Double {
        Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
    }

    /// Loads today's cached hero (if any) and, if none exists yet, generates one —
    /// but only when we have enough wardrobe and a weather reading. Safe to call on
    /// every Home appear; it no-ops once a hero is set for the day.
    func ensureHero(wardrobe: [WardrobeItem], user: User?) {
        // Don't surface a Today's Outfit until the wardrobe is rich enough to style
        // from — below the threshold, hide it entirely.
        guard wardrobe.count >= Self.minItemsForHero else { heroOutfit = nil; return }
        if heroOutfit != nil { return }
        if loadHeroFromCache(wardrobe: wardrobe) { return }
        // Wait until weather has resolved one way or another (loaded OR failed), so
        // we don't generate a weather-blind pick while a reading is still incoming.
        guard (weather != nil || weatherError != nil), !isGeneratingHero else { return }
        generateHero(wardrobe: wardrobe, user: user)
    }

    @discardableResult
    private func loadHeroFromCache(wardrobe: [WardrobeItem]) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.heroCacheKey),
              let cache = try? JSONDecoder().decode(HeroCache.self, from: data),
              cache.dayKey == todayKey else { return false }
        let byID = Dictionary(wardrobe.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let items = cache.itemIDs.compactMap { byID[$0] }
        guard items.count == cache.itemIDs.count, !items.isEmpty else { return false }
        heroOutfit = Outfit(items: items, explanation: cache.explanation)
        return true
    }

    /// Force a fresh pick of the day (e.g. a "regenerate" tap).
    func generateHero(wardrobe: [WardrobeItem], user: User?) {
        guard !isGeneratingHero, wardrobe.count >= Self.minItemsForHero else { return }
        isGeneratingHero = true
        let type = selectedOutfitType ?? user?.preferredStyles.first ?? .everyday
        let context = makeContext(user: user, occasion: type, description: nil, mood: nil)
        // Seeded by the day: the same pick all day, a new one tomorrow.
        let seed = UInt64(bitPattern: Int64(todayKey))
        let engine = self.engine
        Task {
            defer { isGeneratingHero = false }
            let result = await Task.detached(priority: .utility) {
                engine.suggest(from: wardrobe, context: context, count: 1, seed: seed)
            }.value
            guard case .success(let looks) = result,
                  let hero = OutfitValidator.validateAndRepair(looks, wardrobe: wardrobe).first else { return }
            heroOutfit = hero
            persistHero(hero)
            // Warmer wording when the on-device model is around.
            if OnDeviceStylist.isAvailable,
               let text = await OnDeviceStylist.polish(StylistNote(outfit: hero, context: context)),
               heroOutfit?.items.map({ $0.id }) == hero.items.map({ $0.id }) {
                heroOutfit?.explanation = text
                if let updated = heroOutfit { persistHero(updated) }
            }
        }
    }

    private func persistHero(_ outfit: Outfit) {
        let cache = HeroCache(dayKey: todayKey,
                              itemIDs: outfit.items.map { $0.id.uuidString },
                              explanation: outfit.explanation)
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: Self.heroCacheKey)
        }
    }

    /// Opens the hero look in the swipe sheet so the user can refine (lock/shuffle)
    /// and save it.
    func openHeroInDeck(user: User? = nil) {
        guard let hero = heroOutfit else { return }
        savedCount = 0
        skippedCount = 0
        batchToken += 1
        shuffleHistory.removeAll()
        lastContext = makeContext(user: user, occasion: selectedOutfitType ?? .everyday,
                                  description: nil, mood: nil)
        outfitBatch = [hero]
        batchIndex = 0
        todayOutfit = hero
        showOutfitSheet = true
    }

    // MARK: - Swipe Navigation

    func advanceToNextOutfit() {
        batchIndex += 1
        if batchIndex < outfitBatch.count {
            todayOutfit = outfitBatch[batchIndex]
        }
    }

    func skipCurrentOutfit() {
        skippedCount += 1
        advanceToNextOutfit()
    }

    func saveCurrentOutfit() {
        savedCount += 1
    }

    private func replaceCurrent(with outfit: Outfit) {
        withAnimation(DS.Motion.smooth) {
            todayOutfit = outfit
            if batchIndex < outfitBatch.count { outfitBatch[batchIndex] = outfit }
        }
    }

    // MARK: - Shuffle Single Item

    /// Swaps one piece for the best alternative in the same slot, given the rest
    /// of the look. Instant (on-device), so no loading state. Repeated taps walk
    /// through the alternatives before looping.
    func shuffleItemInOutfit(itemToShuffle: WardrobeItem, wardrobe: [WardrobeItem], user: User?) {
        guard let current = todayOutfit else { return }
        let context = editingContext(user: user)
        let slot = OutfitSlot.of(itemToShuffle)
        let key = "\(batchIndex)-\(slot?.rawValue ?? -1)"
        var seen = shuffleHistory[key] ?? []
        seen.insert(itemToShuffle.id)

        var updated = engine.shuffle(itemToShuffle, in: current, wardrobe: wardrobe, context: context,
                                     excluding: seen, seed: Self.freshSeed())
        if updated == nil && seen.count > 1 {
            // Every alternative has had a turn — start the loop again.
            seen = [itemToShuffle.id]
            updated = engine.shuffle(itemToShuffle, in: current, wardrobe: wardrobe, context: context,
                                     excluding: seen, seed: Self.freshSeed())
        }
        guard let updated else {
            Haptics.warning()
            stylistNotice = "That's your only \(slot?.noun ?? "piece") that works here"
            return
        }
        let currentIDs = Set(current.items.map { $0.id })
        for item in updated.items where !currentIDs.contains(item.id) { seen.insert(item.id) }
        shuffleHistory[key] = seen
        replaceCurrent(with: updated)
        polishSingle(updated)
    }

    // MARK: - Shuffle Whole Look (Keeping Locked Pieces)

    /// Restyles the current look around any locked pieces. Replaces just the
    /// current card, never with a look already in the deck.
    func reshuffleKeepingLocked(lockedIDs: Set<UUID>, wardrobe: [WardrobeItem], user: User?) {
        guard let current = todayOutfit else { return }
        let locked = current.items.filter { lockedIDs.contains($0.id) }
        let context = editingContext(user: user)
        let inDeck = Set(outfitBatch.map { OutfitValidator.signature(of: $0) })
        let currentSignature = OutfitValidator.signature(of: current)

        guard case .success(let looks) = engine.suggest(from: wardrobe, context: context, locked: locked,
                                                        count: 6, seed: Self.freshSeed()) else {
            stylistNotice = "Add a few more pieces to restyle this look"
            return
        }
        let validated = OutfitValidator.validateAndRepair(looks, wardrobe: wardrobe)
        let fresh = validated.first(where: { !inDeck.contains(OutfitValidator.signature(of: $0)) })
            ?? validated.first(where: { OutfitValidator.signature(of: $0) != currentSignature })
        guard let fresh else {
            Haptics.warning()
            stylistNotice = locked.isEmpty
                ? "That's every look your wardrobe makes for this"
                : "Those pieces only work one way right now"
            return
        }
        shuffleHistory = shuffleHistory.filter { !$0.key.hasPrefix("\(batchIndex)-") }
        replaceCurrent(with: fresh)
        polishSingle(fresh)
    }

    // MARK: - Add Product to Outfit

    func addProductToOutfit(category: Category, productType: String, wardrobe: [WardrobeItem], user: User?) {
        guard let current = todayOutfit else { return }
        let context = editingContext(user: user)
        guard let updated = engine.add(category: category, productType: productType, to: current,
                                       wardrobe: wardrobe, context: context, seed: Self.freshSeed()) else {
            stylistNotice = "Couldn't find a \(productType.lowercased()) that works with this look"
            return
        }
        replaceCurrent(with: updated)
        polishSingle(updated)
    }

    // MARK: - Weather

    func requestWeatherForCurrentLocation() {
        isWeatherLoading = true
        weatherError = nil
        locationService.requestLocation()
    }

    func toggleTemperatureUnit() {
        displayFahrenheit.toggle()
    }

    private var weatherFetchInFlight = false
    private var lastWeatherFetchLocation: CLLocation?

    private func fetchWeather(for loc: CLLocation) {
        // CLLocationManager.requestLocation delivers several refined fixes in a
        // row; without these guards each one kicked off a full weather fetch
        // (the "5x met.no fetch" seen in logs). Coalesce them.
        if weatherFetchInFlight { return }
        if weather != nil, let last = lastWeatherFetchLocation, loc.distance(from: last) < 1000 {
            isWeatherLoading = false
            return
        }
        weatherFetchInFlight = true
        Task {
            do {
                let weather = try await WeatherService.shared.fetchWeather(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, useFahrenheit: false)
                await MainActor.run {
                    self.weather = weather
                    self.weatherError = nil
                    self.isWeatherLoading = false
                    self.weatherFetchInFlight = false
                    self.lastWeatherFetchLocation = loc
                    self.lastCity = weather.city
                    self.lastCelsius = weather.temperature2m
                    self.lastFahrenheit = (weather.temperature2m * 9.0 / 5.0) + 32.0
                    if let data = try? JSONEncoder().encode(weather) {
                        UserDefaults.standard.set(data, forKey: Self.weatherCacheKey)
                    }
                }
            } catch {
                print("[Weather] fetchWeather failed: \(error)")
                await MainActor.run {
                    self.weatherError = "Failed to fetch weather."
                    self.isWeatherLoading = false
                    self.weatherFetchInFlight = false
                }
            }
        }
    }
}
