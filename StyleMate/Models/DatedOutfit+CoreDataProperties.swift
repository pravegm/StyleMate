import Foundation
import CoreData

extension DatedOutfit {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<DatedOutfit> {
        NSFetchRequest<DatedOutfit>(entityName: "DatedOutfit")
    }

    @NSManaged public var date: Date?
    @NSManaged public var id: UUID?
    @NSManaged public var notes: String?
    @NSManaged public var source: String?
    @NSManaged public var items: NSSet?
}

// MARK: Generated accessors for items
extension DatedOutfit {
    @objc(addItemsObject:)
    @NSManaged public func addToItems(_ value: OutfitItem)

    @objc(removeItemsObject:)
    @NSManaged public func removeFromItems(_ value: OutfitItem)

    @objc(addItems:)
    @NSManaged public func addToItems(_ values: NSSet)

    @objc(removeItems:)
    @NSManaged public func removeFromItems(_ values: NSSet)
}

extension DatedOutfit: Identifiable {}

