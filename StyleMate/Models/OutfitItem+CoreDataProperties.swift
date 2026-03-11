import Foundation
import CoreData

extension OutfitItem {
    @nonobjc public class func fetchRequest() -> NSFetchRequest<OutfitItem> {
        NSFetchRequest<OutfitItem>(entityName: "OutfitItem")
    }

    @NSManaged public var brand: String?
    @NSManaged public var category: String?
    @NSManaged public var colors: NSObject?
    @NSManaged public var croppedImagePath: String?
    @NSManaged public var id: UUID?
    @NSManaged public var imagePath: String?
    @NSManaged public var pattern: String?
    @NSManaged public var product: String?
    @NSManaged public var datedOutfit: DatedOutfit?
}

extension OutfitItem: Identifiable {}

