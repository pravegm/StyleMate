import Foundation

struct Outfit: Equatable, Hashable {
    var items: [WardrobeItem]
    
    init(items: [WardrobeItem]) {
        self.items = items
    }
} 