import Foundation
import CoreData
import SwiftUI

@MainActor
class MyOutfitsViewModel: ObservableObject {
    @Published var outfitsByDate: [Date: [DatedOutfit]] = [:]
    private let context: NSManagedObjectContext
    
    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        fetchAllOutfits()
    }
    
    func fetchAllOutfits() {
        let request: NSFetchRequest<DatedOutfit> = DatedOutfit.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        do {
            let results = try context.fetch(request)
            let grouped = Dictionary(grouping: results) { outfit in
                Calendar.current.startOfDay(for: outfit.date ?? Date.distantPast)
            }
            self.outfitsByDate = grouped
        } catch {
            print("Failed to fetch outfits: \(error)")
        }
    }
    
    func addOutfit(date: Date, items: [WardrobeItem], source: String, notes: String? = nil) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        let datedOutfit = DatedOutfit(context: context)
        datedOutfit.id = UUID()
        datedOutfit.date = normalizedDate
        datedOutfit.source = source
        datedOutfit.notes = notes
        let outfitItems = items.map { item -> OutfitItem in
            let oi = OutfitItem(context: context)
            oi.id = item.id
            oi.category = item.category.rawValue
            oi.product = item.product
            oi.colors = item.colors as NSObject // Core Data Transformable
            oi.brand = item.brand
            oi.pattern = item.pattern.rawValue
            oi.imagePath = item.imagePath
            oi.croppedImagePath = item.croppedImagePath
            oi.datedOutfit = datedOutfit
            return oi
        }
        datedOutfit.items = NSSet(array: outfitItems)
        save()
        fetchAllOutfits()
    }
    
    func deleteOutfit(_ outfit: DatedOutfit) {
        context.delete(outfit)
        save()
        fetchAllOutfits()
    }
    
    func updateOutfit(_ outfit: DatedOutfit, items: [WardrobeItem], notes: String?) {
        // Remove old OutfitItems
        if let oldItems = outfit.items as? Set<OutfitItem> {
            for item in oldItems {
                context.delete(item)
            }
        }
        // Add new OutfitItems
        let newOutfitItems = items.map { item -> OutfitItem in
            let oi = OutfitItem(context: context)
            oi.id = item.id
            oi.category = item.category.rawValue
            oi.product = item.product
            oi.colors = item.colors as NSObject
            oi.brand = item.brand
            oi.pattern = item.pattern.rawValue
            oi.imagePath = item.imagePath
            oi.croppedImagePath = item.croppedImagePath
            oi.datedOutfit = outfit
            return oi
        }
        outfit.items = NSSet(array: newOutfitItems)
        outfit.notes = notes
        save()
        fetchAllOutfits()
    }
    
    private func save() {
        do {
            try context.save()
        } catch {
            print("Failed to save Core Data context: \(error)")
        }
    }
} 