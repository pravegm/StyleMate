import Foundation
import Combine

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
    private var outfitBatch: [Outfit] = []
    private var batchIndex: Int = 0
    
    var isCustomDescriptionValid: Bool {
        guard let desc = customOutfitDescription else { return false }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split into words with at least one letter or digit
        let words = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { word in
            word.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil
        }
        return words.count >= 2
    }
    
    func suggestTodayOutfit(from items: [WardrobeItem]) {
        Task {
            isLoading = true
            defer { isLoading = false }
            let typeToUse = selectedOutfitType
            let customDescription = customOutfitDescription
            guard let suggestions = await ImageAnalysisService.shared.suggestOutfitBatch(from: items, outfitType: typeToUse, customDescription: customDescription), !suggestions.isEmpty else {
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
                    return items.first(where: { item in
                        item.category.rawValue.caseInsensitiveCompare(suggestion.category) == .orderedSame &&
                        item.product.caseInsensitiveCompare(suggestion.product) == .orderedSame &&
                        Set(item.colors.map { $0.lowercased() }) == Set(suggestion.colors.map { $0.lowercased() }) &&
                        item.pattern.rawValue.caseInsensitiveCompare(suggestion.pattern) == .orderedSame &&
                        (suggestion.brand == nil || item.brand.caseInsensitiveCompare(suggestion.brand ?? "") == .orderedSame || item.brand.isEmpty)
                    })
                }
                let matchedItems = suggestion.compactMap { match($0) }
                let top = matchedItems.first(where: { $0.category == .tops })
                let bottom = matchedItems.first(where: { $0.category == .bottoms })
                let footwear = matchedItems.first(where: { $0.category == .footwear })
                let accessory = matchedItems.first(where: { $0.category == .accessories })
                let outerwear = matchedItems.first(where: { $0.category == .outerwear || $0.category == .midLayers || $0.category == .onePieces })
                if let top = top, let bottom = bottom, let footwear = footwear {
                    return Outfit(top: top, bottom: bottom, footwear: footwear, accessory: accessory, outerwear: outerwear)
                } else {
                    return nil
                }
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

    // Shuffle a single item in the current outfit for a given category
    func shuffleItemInOutfit(category: Category, wardrobe: [WardrobeItem]) {
        guard let currentOutfit = todayOutfit else { return }
        Task {
            isLoading = true
            defer { isLoading = false }
            // Get all items in the category
            let availableItems = wardrobe.filter { $0.category == category }
            // If only one item, nothing to shuffle
            guard availableItems.count > 1 else { return }
            // Call Gemini for a new suggestion
            let result = await ImageAnalysisService.shared.suggestPartialShuffleWithResult(currentOutfit: currentOutfit, categoryToShuffle: category, availableItems: availableItems)
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
                // Build new outfit
                let updatedOutfit: Outfit
                switch category {
                case .tops:
                    updatedOutfit = Outfit(top: replacement, bottom: currentOutfit.bottom, footwear: currentOutfit.footwear, accessory: currentOutfit.accessory, outerwear: currentOutfit.outerwear)
                case .bottoms:
                    updatedOutfit = Outfit(top: currentOutfit.top, bottom: replacement, footwear: currentOutfit.footwear, accessory: currentOutfit.accessory, outerwear: currentOutfit.outerwear)
                case .footwear:
                    updatedOutfit = Outfit(top: currentOutfit.top, bottom: currentOutfit.bottom, footwear: replacement, accessory: currentOutfit.accessory, outerwear: currentOutfit.outerwear)
                case .accessories:
                    updatedOutfit = Outfit(top: currentOutfit.top, bottom: currentOutfit.bottom, footwear: currentOutfit.footwear, accessory: replacement, outerwear: currentOutfit.outerwear)
                case .outerwear, .midLayers, .onePieces:
                    updatedOutfit = Outfit(top: currentOutfit.top, bottom: currentOutfit.bottom, footwear: currentOutfit.footwear, accessory: currentOutfit.accessory, outerwear: replacement)
                default:
                    // For categories not in the outfit, do nothing
                    return
                }
                todayOutfit = updatedOutfit
            case .rateLimited:
                showRateLimitAlert = true
            case .failure:
                break
            }
        }
    }
} 