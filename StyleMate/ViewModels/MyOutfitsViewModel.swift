import Foundation
import CoreData
import SwiftUI

@MainActor
class MyOutfitsViewModel: ObservableObject {
    @Published var outfitsByDate: [Date: [DatedOutfit]] = [:]
    /// The day most recently logged to (from Home or manually), so the calendar
    /// can jump straight to it.
    @Published var lastLoggedDate: Date? = nil
    private let context: NSManagedObjectContext

    /// Outfit sources stored on `DatedOutfit.source`.
    enum Source {
        static let stylist = "stylist"      // picked from the on-device stylist's suggestions
        static let legacyAI = "gemini"      // older logs, styled by the previous cloud model
        static let manual = "manual"

        static func isStyled(_ source: String?) -> Bool { source == stylist || source == legacyAI }
    }

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
        datedOutfit.items = NSSet(array: makeOutfitItems(items, for: datedOutfit))
        save()
        fetchAllOutfits()
        lastLoggedDate = normalizedDate
    }

    func deleteOutfit(_ outfit: DatedOutfit) {
        // The relationship's delete rule is Nullify, so delete the snapshot items
        // explicitly or they'd linger as orphans.
        if let items = outfit.items as? Set<OutfitItem> {
            for item in items { context.delete(item) }
        }
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
        outfit.items = NSSet(array: makeOutfitItems(items, for: outfit))
        outfit.notes = notes
        save()
        fetchAllOutfits()
    }

    // MARK: - Wear history (feeds the stylist's recency rule)

    /// Most recent day each wardrobe item was logged as worn, within the last
    /// `days` days. Future-dated (planned) outfits don't count as worn.
    func lastWornDates(withinDays days: Int = 30, now: Date = Date()) -> [UUID: Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        guard let earliest = cal.date(byAdding: .day, value: -days, to: today) else { return [:] }
        var result: [UUID: Date] = [:]
        for (day, outfits) in outfitsByDate where day >= earliest && day <= today {
            for outfit in outfits {
                guard let items = outfit.items as? Set<OutfitItem> else { continue }
                for item in items {
                    guard let id = item.id else { continue }
                    if let existing = result[id], existing >= day { continue }
                    result[id] = day
                }
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Snapshot the wardrobe items into Core Data (so the log survives the item
    /// being edited or deleted later).
    private func makeOutfitItems(_ items: [WardrobeItem], for outfit: DatedOutfit) -> [OutfitItem] {
        items.map { item -> OutfitItem in
            let oi = OutfitItem(context: context)
            oi.id = item.id
            oi.category = item.category.rawValue
            oi.product = item.product
            oi.colors = item.colors as NSObject // Core Data Transformable
            oi.brand = item.brand
            oi.pattern = item.pattern.rawValue
            oi.imagePath = item.imagePath
            oi.croppedImagePath = item.croppedImagePath
            oi.datedOutfit = outfit
            return oi
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            print("Failed to save Core Data context: \(error)")
            context.rollback()
        }
    }
}

extension Notification.Name {
    /// Posted by the outfit sheet's "View in Calendar"; the tab bar can switch to
    /// the Outfits tab on it.
    static let showOutfitsCalendar = Notification.Name("StyleMate.showOutfitsCalendar")
}
