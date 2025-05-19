import Foundation

struct User: Identifiable, Codable {
    var id: String? // For local use, can be email or UUID
    let email: String
    var name: String
    var preferredStyles: [OutfitType]
    var notificationsEnabled: Bool
    var dateCreated: Date
    var gender: String? // New field: "Male", "Female", "Other", etc.
    var age: Int? // New field: optional Int
} 