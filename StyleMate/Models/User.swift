import Foundation

struct User: Identifiable, Codable {
    var id: String
    var email: String?
    var name: String
    var preferredStyles: [OutfitType]
    var notificationsEnabled: Bool
    var dateCreated: Date
    var gender: String?
    var age: Int?
}
