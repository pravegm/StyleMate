import Foundation

struct Outfit: Equatable, Hashable {
    var items: [WardrobeItem]
    var explanation: String
    /// One line on what the user's own choices taught the stylist, when that shaped this look
    /// ("Picked because you often wear navy with grey"). nil when taste played no part.
    var tasteNote: String?

    init(items: [WardrobeItem], explanation: String = "", tasteNote: String? = nil) {
        self.items = items
        self.explanation = explanation
        self.tasteNote = tasteNote
    }
}
