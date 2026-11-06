import Foundation

/// Can the closet make a whole outfit yet, and if not, what's missing?
///
/// A whole outfit is a top and a bottom (or a dress / jumpsuit, with a top under it when
/// it needs one) plus shoes. Below that Home shows "Almost ready: Add 1 more bottom and
/// shoes to get outfits" instead of a Today's look card (`AlmostReadyCard`). Pure, so
/// `WardrobeInsightsTests` covers it.
enum OutfitReadiness {
    enum Need: String, CaseIterable, Identifiable {
        case top, bottom, shoes
        var id: String { rawValue }

        var label: String {
            switch self {
            case .top: return "Top"
            case .bottom: return "Bottom"
            case .shoes: return "Shoes"
            }
        }

        var icon: String {
            switch self {
            case .top: return "tshirt"
            case .bottom: return "figure.walk"
            case .shoes: return "shoe"
            }
        }
    }

    struct Status: Equatable {
        /// What the closet already has, per need.
        var has: [Need: Bool]
        /// Still missing, in display order.
        var missing: [Need]
        var isReady: Bool { missing.isEmpty }
        /// Only a top-and-bottom gap can be closed by one dress.
        var dressWouldHelp: Bool { missing.contains(.top) && missing.contains(.bottom) }
    }

    static func status(of items: [WardrobeItem]) -> Status {
        var tops = 0, bottoms = 0, shoes = 0
        var onePieces: [WardrobeItem] = []
        for item in items {
            switch OutfitSlot.of(item) {
            case .top?: tops += 1
            case .bottom?: bottoms += 1
            case .footwear?: shoes += 1
            case .onePiece?: onePieces.append(item)
            default: break
            }
        }
        // A dress covers both halves; dungarees or a saree still need a top under them.
        let onePieceDresses = onePieces.contains { !OutfitSlot.needsTopUnder($0) || tops > 0 }
        let coreReady = (tops > 0 && bottoms > 0) || onePieceDresses
        var missing: [Need] = []
        if !coreReady {
            if tops == 0 { missing.append(.top) }
            // A one-piece that needs a top under it covers the bottom half.
            if bottoms == 0 && onePieces.isEmpty { missing.append(.bottom) }
        }
        if shoes == 0 { missing.append(.shoes) }
        let has: [Need: Bool] = [.top: tops > 0 || onePieceDresses,
                                 .bottom: bottoms > 0 || !onePieces.isEmpty,
                                 .shoes: shoes > 0]
        return Status(has: has, missing: missing)
    }

    static func isReady(_ items: [WardrobeItem]) -> Bool { status(of: items).isReady }

    /// "Add 1 more bottom and shoes to get outfits"; nil when ready.
    static func message(for status: Status) -> String? {
        guard !status.isReady else { return nil }
        let both = status.missing.contains(.top) && status.missing.contains(.bottom)
        let parts: [String] = status.missing.map { need in
            switch need {
            case .top: return both ? "a top" : "1 more top"
            case .bottom: return both ? "a bottom" : "1 more bottom"
            case .shoes: return "shoes"
            }
        }
        return "Add \(spokenList(parts)) to get outfits"
    }

    private static func spokenList(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }
}
