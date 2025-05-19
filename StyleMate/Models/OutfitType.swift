import Foundation
import SwiftUI

enum OutfitType: String, CaseIterable, Identifiable, Codable {
    case everyday = "Everyday Casual"
    case formal = "Formal Wear"
    case date = "Date Night"
    case sports = "Sports / Active"
    case party = "Party"
    case business = "Business Casual"
    case loungewear = "Loungewear"
    case vacation = "Vacation"
    case ethnic = "Ethnic Wear"
    case streetwear = "Streetwear"

    var id: String { self.rawValue }
    var icon: String {
        switch self {
        case .everyday: return "tshirt"
        case .formal: return "person.fill"
        case .date: return "heart"
        case .sports: return "figure.run"
        case .party: return "sparkles"
        case .business: return "briefcase"
        case .loungewear: return "bed.double"
        case .vacation: return "sun.max"
        case .ethnic: return "sparkles.tv"
        case .streetwear: return "figure.walk"
        }
    }
} 