import Foundation
import Combine

@MainActor
class HomeViewModel: ObservableObject {
    @Published var todayOutfit: Outfit?
    @Published var isLoading = false
    @Published var showOutfitSheet = false
    @Published var showNoOutfitAlert = false
    private var logic: OutfitLogic?
    
    func suggestTodayOutfit(from items: [WardrobeItem]) {
        isLoading = true
        logic = OutfitLogic(items: items)
        todayOutfit = logic?.generateNextOutfit()
        isLoading = false
        if todayOutfit != nil {
            showOutfitSheet = true
        } else {
            showNoOutfitAlert = true
        }
    }
} 