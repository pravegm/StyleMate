import Foundation
import Combine

@MainActor
class HomeViewModel: ObservableObject {
    @Published var todayOutfit: Outfit?
    @Published var isLoading = false
    @Published var showOutfitSheet = false
    @Published var showNoOutfitAlert = false
    @Published var showNoMoreSuggestions = false
    private var outfitBatch: [Outfit] = []
    private var batchIndex: Int = 0
    
    func suggestTodayOutfit(from items: [WardrobeItem]) {
        Task {
            isLoading = true
            defer { isLoading = false }
            guard let suggestions = await ImageAnalysisService.shared.suggestOutfitBatch(from: items), !suggestions.isEmpty else {
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
                let outerwear = matchedItems.first(where: { $0.category == .seasonalLayering || $0.category == .onePieces })
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
} 