import Foundation

struct Outfit: Equatable, Hashable {
    var items: [WardrobeItem]
    var explanation: String

    init(items: [WardrobeItem], explanation: String = "") {
        self.items = items
        self.explanation = explanation
    }
} 