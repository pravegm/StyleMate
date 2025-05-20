// This file now only contains the Outfit struct for use with AI-powered outfit suggestions.
// The old OutfitLogic class and manual outfit generation logic have been removed.
import Foundation
import UIKit

struct Outfit: Equatable, Hashable {
    var items: [WardrobeItem]
    
    init(items: [WardrobeItem]) {
        self.items = items
    }
}

extension WardrobeItem {
    var isPatterned: Bool {
        // Simple heuristic: if brand or product contains "pattern" or "print" or "stripe" or "dot" or "floral"
        let patterns = ["pattern", "print", "stripe", "dot", "floral", "plaid", "check", "animal", "camouflage"]
        let text = (brand + " " + product).lowercased()
        return patterns.contains { text.contains($0) }
    }
} 