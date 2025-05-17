import Foundation
import SwiftUI

enum OutfitType: String, CaseIterable, Identifiable {
    case everyday = "Everyday Casual"
    case formal = "Formal Wear"
    case date = "Date Night"
    case sports = "Sports/Active"
    case party = "Party"
    case business = "Business Casual"

    var id: String { self.rawValue }
    var icon: String {
        switch self {
        case .everyday: return "tshirt"
        case .formal: return "person.fill"
        case .date: return "heart"
        case .sports: return "figure.run"
        case .party: return "sparkles"
        case .business: return "briefcase"
        }
    }
} 