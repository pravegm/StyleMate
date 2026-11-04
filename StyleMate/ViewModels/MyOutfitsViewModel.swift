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

    /// Outfits are scoped to the signed-in user (`DatedOutfit.userID`, model v2). Rows
    /// logged before v2 have no user; they are adopted by the first user who loads them.
    /// Set with `setUser(_:)`; until then the session's auth user id is used, and with no
    /// user at all every row is shown (the pre-v2 behaviour).
    private(set) var userID: String?

    /// Outfit sources stored on `DatedOutfit.source`.
    enum Source {
        static let stylist = "stylist"      // picked from the on-device stylist's suggestions
        static let legacyAI = "gemini"      // older logs, styled by the previous cloud model
        static let manual = "manual"

        static func isStyled(_ source: String?) -> Bool { source == stylist || source == legacyAI }
    }

    private var historyObserver: NSObjectProtocol?

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        self.userID = Self.sessionUserID()
        adoptUnscopedOutfits()
        fetchAllOutfits()
        historyObserver = NotificationCenter.default.addObserver(
            forName: .outfitHistoryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.fetchAllOutfits() }
        }
        snapshotLegacyOutfitImages()
    }

    deinit {
        if let historyObserver { NotificationCenter.default.removeObserver(historyObserver) }
    }

    /// The auth session's user id, if any (AuthService persists it under this key).
    private static func sessionUserID() -> String? {
        let id = UserDefaults.standard.string(forKey: "authUserID")
        return (id?.isEmpty ?? true) ? nil : id
    }

    /// Scopes the calendar to `id` (call when the user changes; nil = no user).
    func setUser(_ id: String?) {
        let id = (id?.isEmpty ?? true) ? nil : id
        guard id != userID else { return }
        userID = id
        adoptUnscopedOutfits()
        fetchAllOutfits()
    }

    private func scopePredicate() -> NSPredicate? {
        guard let userID else { return nil }
        return NSPredicate(format: "userID == %@ OR userID == nil", userID)
    }

    /// Gives pre-v2 rows (no user) to the current user, once.
    private func adoptUnscopedOutfits() {
        guard let userID else { return }
        let request: NSFetchRequest<DatedOutfit> = DatedOutfit.fetchRequest()
        request.predicate = NSPredicate(format: "userID == nil")
        guard let rows = try? context.fetch(request), !rows.isEmpty else { return }
        for row in rows { row.userID = userID }
        save()
    }

    func fetchAllOutfits() {
        let request: NSFetchRequest<DatedOutfit> = DatedOutfit.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        request.predicate = scopePredicate()
        do {
            let results = try context.fetch(request)
            let grouped = Dictionary(grouping: results) { outfit in
                Calendar.current.startOfDay(for: outfit.date ?? Date.distantPast)
            }
            self.outfitsByDate = grouped
        } catch {
            dlog("Failed to fetch outfits: \(error)")
        }
    }

    func addOutfit(date: Date, items: [WardrobeItem], source: String, notes: String? = nil) {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        let datedOutfit = DatedOutfit(context: context)
        datedOutfit.id = UUID()
        datedOutfit.date = normalizedDate
        datedOutfit.source = source
        datedOutfit.notes = notes
        datedOutfit.userID = userID
        datedOutfit.items = NSSet(array: makeOutfitItems(items, for: datedOutfit))
        save()
        fetchAllOutfits()
        lastLoggedDate = normalizedDate
    }

    func deleteOutfit(_ outfit: DatedOutfit) {
        // The relationship's delete rule is Nullify, so delete the snapshot items
        // explicitly or they'd linger as orphans.
        if let items = outfit.items as? Set<OutfitItem> {
            for item in items { deleteSnapshotItem(item) }
        }
        context.delete(outfit)
        save()
        fetchAllOutfits()
    }

    func updateOutfit(_ outfit: DatedOutfit, items: [WardrobeItem], notes: String?) {
        // Remove old OutfitItems
        if let oldItems = outfit.items as? Set<OutfitItem> {
            for item in oldItems { deleteSnapshotItem(item) }
        }
        outfit.items = NSSet(array: makeOutfitItems(items, for: outfit))
        outfit.notes = notes
        save()
        fetchAllOutfits()
    }

    // MARK: - Delete everything

    /// Deletes this user's outfit history (and any pre-v2 rows without a user) with their
    /// picture snapshots. `WardrobeViewModel.deleteAllLocalData(forUser:)` calls this.
    func deleteAllLocalData(forUser userId: String) {
        Self.deleteOutfits(forUser: userId, in: context)
        fetchAllOutfits()
    }

    /// Context-level delete used by `WardrobeViewModel.deleteAllLocalData(forUser:)`; live
    /// view models refresh via `.outfitHistoryDidChange`.
    static func deleteOutfits(forUser userId: String,
                              in context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        let request: NSFetchRequest<DatedOutfit> = DatedOutfit.fetchRequest()
        request.predicate = NSPredicate(format: "userID == %@ OR userID == nil", userId)
        guard let rows = try? context.fetch(request) else { return }
        for outfit in rows {
            if let items = outfit.items as? Set<OutfitItem> {
                for item in items {
                    deleteSnapshotFiles(of: item)
                    context.delete(item)
                }
            }
            context.delete(outfit)
        }
        if context.hasChanges {
            do { try context.save() } catch { context.rollback() }
        }
        NotificationCenter.default.post(name: .outfitHistoryDidChange, object: nil)
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

    /// Snapshot the wardrobe items into Core Data (so the log survives the item being
    /// edited or deleted later). The picture is a private small copy (`outfit_*` file in
    /// the wardrobe folder): deleting, re-photographing or scan-upgrading the item deletes
    /// the item's own files, which used to blank the history.
    private func makeOutfitItems(_ items: [WardrobeItem], for outfit: DatedOutfit) -> [OutfitItem] {
        items.map { item -> OutfitItem in
            let oi = OutfitItem(context: context)
            oi.id = item.id
            oi.category = item.category.rawValue
            oi.product = item.product
            oi.colors = item.colors as NSObject // Core Data Transformable
            oi.brand = item.brand
            oi.pattern = item.pattern.rawValue
            if let snapshot = WardrobeImageFileHelper.makeOutfitSnapshot(
                thumbnailPath: item.thumbnailPath, imagePath: item.croppedImagePath ?? item.imagePath) {
                oi.imagePath = snapshot
                oi.croppedImagePath = snapshot
            } else {
                oi.imagePath = item.imagePath
                oi.croppedImagePath = item.croppedImagePath
            }
            oi.datedOutfit = outfit
            return oi
        }
    }

    private func deleteSnapshotItem(_ item: OutfitItem) {
        Self.deleteSnapshotFiles(of: item)
        context.delete(item)
    }

    private static func deleteSnapshotFiles(of item: OutfitItem) {
        for path in Set([item.imagePath, item.croppedImagePath].compactMap { $0 })
        where WardrobeImageFileHelper.isOutfitSnapshot(path) {
            WardrobeImageFileHelper.deleteImage(at: path)
        }
    }

    /// One-time: gives outfits logged before snapshots existed their own picture copies,
    /// from the referenced file if it still exists, else from the wardrobe item with the
    /// same id. File work runs off the main thread.
    private func snapshotLegacyOutfitImages() {
        let doneKey = "outfitSnapshotMigration_v1"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let request: NSFetchRequest<OutfitItem> = OutfitItem.fetchRequest()
        guard let rows = try? context.fetch(request) else { return }
        let legacy = rows.filter { !WardrobeImageFileHelper.isOutfitSnapshot($0.imagePath) }
        guard !legacy.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }
        var wardrobeByID: [UUID: WardrobeItem] = [:]
        if let user = userID {
            for item in WardrobeViewModel.loadItems(forUser: user) { wardrobeByID[item.id] = item }
        }
        let work: [(objectID: NSManagedObjectID, thumb: String?, image: String?)] = legacy.map { row in
            let current = row.id.flatMap { wardrobeByID[$0] }
            let refImage = row.croppedImagePath ?? row.imagePath
            let refExists = refImage.map { WardrobeImageFileHelper.imageExists(at: $0) } ?? false
            if refExists { return (row.objectID, nil, refImage) }
            return (row.objectID, current?.thumbnailPath, current?.croppedImagePath ?? current?.imagePath)
        }
        Task.detached(priority: .background) { [weak self] in
            var made: [(NSManagedObjectID, String)] = []
            for w in work where w.thumb != nil || w.image != nil {
                if let snap = WardrobeImageFileHelper.makeOutfitSnapshot(thumbnailPath: w.thumb, imagePath: w.image) {
                    made.append((w.objectID, snap))
                }
            }
            let results = made
            await MainActor.run {
                guard let self else {
                    for r in results { WardrobeImageFileHelper.deleteImage(at: r.1) }
                    return
                }
                for (objectID, snap) in results {
                    guard let row = try? self.context.existingObject(with: objectID) as? OutfitItem else {
                        WardrobeImageFileHelper.deleteImage(at: snap)
                        continue
                    }
                    row.imagePath = snap
                    row.croppedImagePath = snap
                }
                self.save()
                UserDefaults.standard.set(true, forKey: doneKey)
                self.fetchAllOutfits()
                dlog("[Outfits] Snapshotted pictures for \(results.count) logged items")
            }
        }
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            dlog("Failed to save Core Data context: \(error)")
            context.rollback()
        }
    }
}

extension Notification.Name {
    /// Posted by the outfit sheet's "View in Calendar"; the tab bar can switch to
    /// the Outfits tab on it.
    static let showOutfitsCalendar = Notification.Name("StyleMate.showOutfitsCalendar")
    /// Posted when outfit history was changed outside a view model (delete everything).
    static let outfitHistoryDidChange = Notification.Name("StyleMate.outfitHistoryDidChange")
}
