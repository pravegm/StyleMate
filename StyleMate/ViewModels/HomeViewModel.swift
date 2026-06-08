import Foundation
import Combine
import CoreLocation

@MainActor
class HomeViewModel: ObservableObject {
    @Published var todayOutfit: Outfit?
    @Published var isLoading = false
    @Published var showOutfitSheet = false
    @Published var showRateLimitAlert = false
    @Published var selectedOutfitType: OutfitType? = .everyday
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

    // MARK: - Suggest Today Outfit (Index-Based)

    func suggestTodayOutfit(from items: [WardrobeItem], user: User?) {
        Task {
            isLoading = true
            defer { isLoading = false }

            outfitError = nil
            savedCount = 0
            skippedCount = 0

            let typeToUse = selectedOutfitType
            let customDescription = customOutfitDescription
            let weather = self.weather

            let result = await ImageAnalysisService.shared.suggestOutfitBatch(
                from: items,
                outfitType: typeToUse,
                customDescription: customDescription,
                weather: weather,
                user: user
            )

            switch result {
            case .success(let suggestions):
                let batch: [Outfit] = suggestions.compactMap { suggestion in
                    let wardrobeItems = suggestion.items.compactMap { index -> WardrobeItem? in
                        guard index >= 0, index < items.count else {
                            print("[StyleMate] suggestTodayOutfit: index \(index) out of range (0..<\(items.count))")
                            return nil
                        }
                        return items[index]
                    }
                    guard !wardrobeItems.isEmpty else { return nil }
                    return Outfit(items: wardrobeItems, explanation: suggestion.explanation)
                }

                // Guarantee every shown look is wearable: complete (upper + lower/
                // one-piece + footwear), no impossible doubles, and distinct.
                let validated = OutfitValidator.validateAndRepair(batch, wardrobe: items)
                outfitBatch = validated
                batchIndex = 0

                if let first = validated.first {
                    todayOutfit = first
                    showOutfitSheet = true
                } else {
                    todayOutfit = nil
                    outfitError = .parseError
                    showOutfitErrorAlert = true
                }

            case .failure(let error):
                todayOutfit = nil
                outfitBatch = []
                batchIndex = 0
                switch error {
                case .emptyWardrobe:
                    outfitError = .emptyWardrobe
                case .rateLimited:
                    showRateLimitAlert = true
                    return
                case .networkError:
                    outfitError = .networkError
                case .parseError:
                    outfitError = .parseError
                }
                showOutfitErrorAlert = true
            }
        }
    }

    // MARK: - Today's Outfit Hero
    //
    // One ready "pick of the day" shown on Home so the app opens on an answer, not
    // a form. Generated once per day when weather is ready, then cached (item IDs +
    // reason) so re-opening is instant and costs nothing.

    @Published var heroOutfit: Outfit?
    @Published var isGeneratingHero = false

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
        if heroOutfit != nil { return }
        if loadHeroFromCache(wardrobe: wardrobe) { return }
        // Wait until weather has resolved one way or another (loaded OR failed), so
        // we don't generate a weather-blind pick while a reading is still incoming.
        guard wardrobe.count >= 3, (weather != nil || weatherError != nil), !isGeneratingHero else { return }
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
        guard !isGeneratingHero, wardrobe.count >= 3 else { return }
        isGeneratingHero = true
        Task {
            defer { isGeneratingHero = false }
            let type = selectedOutfitType ?? user?.preferredStyles.first ?? .everyday
            let result = await ImageAnalysisService.shared.suggestOutfitBatch(
                from: wardrobe, outfitType: type, customDescription: nil, weather: weather, user: user
            )
            guard case .success(let suggestions) = result else { return }
            let batch: [Outfit] = suggestions.compactMap { suggestion in
                let items = suggestion.items.compactMap { idx -> WardrobeItem? in
                    (idx >= 0 && idx < wardrobe.count) ? wardrobe[idx] : nil
                }
                return items.isEmpty ? nil : Outfit(items: items, explanation: suggestion.explanation)
            }
            let validated = OutfitValidator.validateAndRepair(batch, wardrobe: wardrobe)
            if let hero = validated.first {
                heroOutfit = hero
                persistHero(hero)
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
    func openHeroInDeck() {
        guard let hero = heroOutfit else { return }
        savedCount = 0
        skippedCount = 0
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

    // MARK: - Shuffle Single Item (Index-Based)

    func shuffleItemInOutfit(itemToShuffle: WardrobeItem, wardrobe: [WardrobeItem], user: User?) {
        guard let currentOutfit = todayOutfit else { return }
        let category = itemToShuffle.category
        Task {
            isLoading = true
            defer { isLoading = false }
            let availableItems = wardrobe.filter { $0.category == category && $0.id != itemToShuffle.id }
            guard !availableItems.isEmpty else { return }
            let result = await ImageAnalysisService.shared.suggestPartialShuffleWithResult(
                currentOutfit: currentOutfit,
                categoryToShuffle: category,
                availableItems: availableItems,
                user: user
            )
            switch result {
            case .success(let index, let explanation):
                guard index >= 0, index < availableItems.count else { return }
                let replacement = availableItems[index]
                var updatedItems = currentOutfit.items.filter { $0.id != itemToShuffle.id }
                updatedItems.append(replacement)
                let updatedExplanation = explanation.isEmpty ? currentOutfit.explanation : explanation
                let updatedOutfit = Outfit(items: updatedItems, explanation: updatedExplanation)
                todayOutfit = updatedOutfit
                if batchIndex < outfitBatch.count {
                    outfitBatch[batchIndex] = updatedOutfit
                }
            case .rateLimited:
                showRateLimitAlert = true
            case .failure:
                break
            }
        }
    }

    // MARK: - Shuffle Whole Look (Keeping Locked Pieces)

    /// Regenerates the current look, keeping any locked pieces, via one coherent
    /// Gemini call (then re-validated). Replaces just the current card.
    func reshuffleKeepingLocked(lockedIDs: Set<UUID>, wardrobe: [WardrobeItem], user: User?) {
        guard let current = todayOutfit else { return }
        let lockedItems = current.items.filter { lockedIDs.contains($0.id) }
        Task {
            isLoading = true
            defer { isLoading = false }

            let result = await ImageAnalysisService.shared.suggestOutfitBatch(
                from: wardrobe,
                outfitType: selectedOutfitType,
                customDescription: customOutfitDescription,
                weather: weather,
                user: user,
                lockedItems: lockedItems
            )

            switch result {
            case .success(let suggestions):
                let batch: [Outfit] = suggestions.compactMap { suggestion in
                    let items = suggestion.items.compactMap { idx -> WardrobeItem? in
                        (idx >= 0 && idx < wardrobe.count) ? wardrobe[idx] : nil
                    }
                    return items.isEmpty ? nil : Outfit(items: items, explanation: suggestion.explanation)
                }
                let validated = OutfitValidator.validateAndRepair(batch, wardrobe: wardrobe)
                if let fresh = validated.first {
                    todayOutfit = fresh
                    if batchIndex < outfitBatch.count { outfitBatch[batchIndex] = fresh }
                }
            case .failure(.rateLimited):
                showRateLimitAlert = true
            case .failure:
                break
            }
        }
    }

    // MARK: - Add Product to Outfit (Index-Based)

    func addProductToOutfit(category: Category, productType: String, wardrobe: [WardrobeItem], user: User?) {
        guard let currentOutfit = todayOutfit else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            let availableItems = wardrobe.filter { $0.category == category && $0.product.caseInsensitiveCompare(productType) == .orderedSame }
            guard !availableItems.isEmpty else { return }
            if let selectedIndex = await ImageAnalysisService.shared.suggestAddProductToOutfit(
                currentOutfit: currentOutfit,
                category: category,
                productType: productType,
                availableItems: availableItems,
                user: user
            ) {
                guard selectedIndex >= 0, selectedIndex < availableItems.count else { return }
                let newItem = availableItems[selectedIndex]
                var updatedItems = currentOutfit.items
                updatedItems.append(newItem)
                let updatedOutfit = Outfit(items: updatedItems, explanation: currentOutfit.explanation)
                todayOutfit = updatedOutfit
                if batchIndex < outfitBatch.count {
                    outfitBatch[batchIndex] = updatedOutfit
                }
            }
        }
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
