import Foundation
import Combine
import CoreLocation

@MainActor
class HomeViewModel: ObservableObject {
    @Published var todayOutfit: Outfit?
    @Published var isLoading = false
    @Published var showOutfitSheet = false
    @Published var showNoOutfitAlert = false
    @Published var showNoMoreSuggestions = false
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
    private var outfitBatch: [Outfit] = []
    private var batchIndex: Int = 0
    private var locationService = LocationService.shared
    private var cancellables = Set<AnyCancellable>()
    
    var isCustomDescriptionValid: Bool {
        guard let desc = customOutfitDescription else { return false }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split into words with at least one letter or digit
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { word in
            word.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil
        }
        return words.count >= 2
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
    }
    
    func suggestTodayOutfit(from items: [WardrobeItem], user: User?) {
        Task {
            isLoading = true
            defer { isLoading = false }
            let typeToUse = selectedOutfitType
            let customDescription = customOutfitDescription
            let weather = self.weather
            if let user = user, let type = typeToUse, !user.preferredStyles.contains(type) {
                todayOutfit = nil
                showNoOutfitAlert = true
                outfitBatch = []
                batchIndex = 0
                return
            }
            guard let suggestions = await ImageAnalysisService.shared.suggestOutfitBatch(from: items, outfitType: typeToUse, customDescription: customDescription, weather: weather, user: user), !suggestions.isEmpty else {
                todayOutfit = nil
                showNoOutfitAlert = true
                outfitBatch = []
                batchIndex = 0
                return
            }
            // Convert Gemini's suggestions to [Outfit]
            let batch: [Outfit] = suggestions.compactMap { suggestion in
                // Try to match Gemini's suggestions to actual WardrobeItem objects
                func match(_ suggestion: ImageAnalysisService.SuggestedOutfitItem) -> WardrobeItem? {
                    for item in items {
                        let categoryMatch = ImageAnalysisService.shared.matchCategory(suggestion.category) == item.category
                        let productMatch = ImageAnalysisService.shared.matchProduct(suggestion.product)?.caseInsensitiveCompare(item.product) == .orderedSame
                        let colorMatch = Set(item.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }) == Set(suggestion.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
                        let patternMatch = item.pattern.rawValue.caseInsensitiveCompare(suggestion.pattern) == .orderedSame
                        let brandMatch = (suggestion.brand == nil || item.brand.caseInsensitiveCompare(suggestion.brand ?? "") == .orderedSame || item.brand.isEmpty)
                        if categoryMatch && productMatch && colorMatch && patternMatch && brandMatch {
                            return item
                        }
                    }
                    return nil
                }
                let matchedItems = suggestion.compactMap { match($0) }
                // Remove the requirement for top, bottom, and footwear. Use whatever Gemini returns.
                let items = matchedItems // Use all matched items as the outfit
                return Outfit(items: items)
            }
            outfitBatch = batch
            batchIndex = 0
            if let first = outfitBatch.first {
                todayOutfit = first
                showOutfitSheet = true
            } else {
                todayOutfit = nil
                showNoOutfitAlert = true
            }
        }
    }

    func shuffleOutfit() {
        guard !outfitBatch.isEmpty else { return }
        batchIndex += 1
        if batchIndex >= outfitBatch.count {
            showNoMoreSuggestions = true
            batchIndex = 0 // Reset to allow cycling
        }
        todayOutfit = outfitBatch[batchIndex]
    }

    func resetShufflePopup() {
        showNoMoreSuggestions = false
    }

    // Shuffle a single item in the current outfit for a given item (not just category)
    func shuffleItemInOutfit(itemToShuffle: WardrobeItem, wardrobe: [WardrobeItem], user: User?) {
        guard let currentOutfit = todayOutfit else { return }
        let category = itemToShuffle.category
        Task {
            isLoading = true
            defer { isLoading = false }
            let availableItems = wardrobe.filter { $0.category == category && $0.id != itemToShuffle.id }
            guard !availableItems.isEmpty else { return }
            let result = await ImageAnalysisService.shared.suggestPartialShuffleWithResult(currentOutfit: currentOutfit, categoryToShuffle: category, availableItems: availableItems, user: user)
            switch result {
            case .success(let newItem):
                // Find the matching WardrobeItem in the wardrobe
                let matched = availableItems.first(where: { item in
                    item.product.caseInsensitiveCompare(newItem.product) == .orderedSame &&
                    Set(item.colors.map { $0.lowercased() }) == Set(newItem.colors.map { $0.lowercased() }) &&
                    item.pattern.rawValue.caseInsensitiveCompare(newItem.pattern) == .orderedSame &&
                    (newItem.brand == nil || item.brand.caseInsensitiveCompare(newItem.brand ?? "") == .orderedSame || item.brand.isEmpty)
                })
                guard let replacement = matched else { return }
                // Build new outfit: replace only the specific item
                var updatedItems = currentOutfit.items.filter { $0.id != itemToShuffle.id }
                updatedItems.append(replacement)
                let updatedOutfit = Outfit(items: updatedItems)
                todayOutfit = updatedOutfit
            case .rateLimited:
                showRateLimitAlert = true
            case .failure:
                break
            }
        }
    }

    func requestWeatherForCurrentLocation() {
        isWeatherLoading = true
        weatherError = nil
        locationService.requestLocation()
    }

    func toggleTemperatureUnit() {
        displayFahrenheit.toggle()
    }

    private func fetchWeather(for loc: CLLocation) {
        Task {
            do {
                let weather = try await WeatherService.shared.fetchWeather(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, useFahrenheit: false)
                await MainActor.run {
                    self.weather = weather
                    self.isWeatherLoading = false
                    self.lastCity = weather.city
                    self.lastCelsius = weather.temperature2m
                    self.lastFahrenheit = (weather.temperature2m * 9.0 / 5.0) + 32.0
                }
            } catch {
                await MainActor.run {
                    self.weatherError = "Failed to fetch weather."
                    self.isWeatherLoading = false
                }
            }
        }
    }

    /// Adds a product type to the current outfit using Gemini and updates todayOutfit.
    func addProductToOutfit(category: Category, productType: String, wardrobe: [WardrobeItem], user: User?) {
        guard let currentOutfit = todayOutfit else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            let availableItems = wardrobe.filter { $0.category == category && $0.product.caseInsensitiveCompare(productType) == .orderedSame }
            guard !availableItems.isEmpty else { return }
            if let suggestion = await ImageAnalysisService.shared.suggestAddProductToOutfit(currentOutfit: currentOutfit, category: category, productType: productType, availableItems: availableItems, user: user) {
                // Try to match Gemini's suggestions to actual WardrobeItem objects
                func match(_ suggestion: ImageAnalysisService.SuggestedOutfitItem) -> WardrobeItem? {
                    for item in wardrobe {
                        let categoryMatch = ImageAnalysisService.shared.matchCategory(suggestion.category) == item.category
                        let productMatch = ImageAnalysisService.shared.matchProduct(suggestion.product)?.caseInsensitiveCompare(item.product) == .orderedSame
                        let colorMatch = Set(item.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }) == Set(suggestion.colors.map { $0.lowercased().trimmingCharacters(in: .whitespaces) })
                        let patternMatch = item.pattern.rawValue.caseInsensitiveCompare(suggestion.pattern) == .orderedSame
                        let brandMatch = (suggestion.brand == nil || item.brand.caseInsensitiveCompare(suggestion.brand ?? "") == .orderedSame || item.brand.isEmpty)
                        if categoryMatch && productMatch && colorMatch && patternMatch && brandMatch {
                            return item
                        }
                    }
                    return nil
                }
                let matchedItems = suggestion.compactMap { match($0) }
                let newOutfit = Outfit(items: matchedItems)
                todayOutfit = newOutfit
            }
        }
    }
} 