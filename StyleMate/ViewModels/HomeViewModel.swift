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
    }

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

                outfitBatch = batch
                batchIndex = 0

                if let first = batch.first {
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
}
