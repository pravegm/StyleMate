import SwiftUI

// Exhaustive enum for all categories
enum Category: String, CaseIterable, Identifiable, Hashable {
    case tops = "Tops"
    case bottoms = "Bottoms"
    case midLayers = "Mid-Layers"
    case outerwear = "Outerwear"
    case onePieces = "One-Pieces"
    case footwear = "Footwear"
    case accessories = "Accessories"
    case innerwear = "Innerwear"
    case activewear = "Activewear"
    case ethnicWear = "Ethnic Wear"
    
    var id: String { self.rawValue }

    var wearingOrder: Int {
        switch self {
        case .accessories:  return 0
        case .outerwear:    return 1
        case .midLayers:    return 2
        case .tops:         return 3
        case .onePieces:    return 3
        case .activewear:   return 3
        case .ethnicWear:   return 3
        case .innerwear:    return 4
        case .bottoms:      return 5
        case .footwear:     return 6
        }
    }

    // MARK: - Which garment attributes apply to this category
    //
    // Single source of truth so classification, display, and the editors all
    // agree. Without this, Gemini occasionally tags an accessory (sunglasses,
    // a bracelet) with garment-only fields like "Short Sleeve" / "Collared",
    // and they get stored and shown — which makes no sense. These gate it out.
    // (Mirrors the picker visibility already used in the edit/review screens.)
    var supportsFit: Bool      { ![.footwear, .accessories].contains(self) }
    var supportsNeckline: Bool { [.tops, .midLayers, .onePieces, .outerwear].contains(self) }
    var supportsSleeves: Bool  { [.tops, .midLayers, .outerwear, .onePieces, .activewear].contains(self) }
    var supportsLength: Bool   { [.bottoms, .onePieces, .outerwear].contains(self) }
}


// Shared wardrobe view model
//
// Threading: `items` is published UI state — mutate it on the main thread. The cloud and
// migration entry points hop to the main actor themselves.
class WardrobeViewModel: ObservableObject {
    @Published var items: [WardrobeItem] = [] {
        didSet {
            if !suspendSaving {
                save(forUser: currentUserEmail)
            }
        }
    }
    private(set) var currentUserEmail: String = ""
    private var suspendSaving = false

    /// The UserDefaults key a user's wardrobe is stored under. Apple ids / emails contain
    /// dots, so the raw id is NOT the key — anything that deletes or reads the wardrobe
    /// outside this class must use this function (or `deleteAllLocalData(forUser:)`).
    static func storageKey(for userId: String) -> String {
        "wardrobe_\(userId.replacingOccurrences(of: "@", with: "_").replacingOccurrences(of: ".", with: "_"))"
    }


    func load(forUser email: String) {
        currentUserEmail = email
        ledger = SyncLedger.load(userKey: WardrobeViewModel.storageKey(for: email))
        items = WardrobeViewModel.loadItems(forUser: email)
    }

    /// Decodes a user's stored wardrobe (empty when there is none).
    static func loadItems(forUser email: String) -> [WardrobeItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey(for: email)),
              let decoded = try? JSONDecoder().decode([WardrobeItemCodable].self, from: data) else {
            return []
        }
        // Sanitize on load: clears garment fields wrongly attached to accessories/footwear
        // in older data. The didSet re-saves the cleaned set, so this self-heals once.
        return decoded.compactMap { $0.toWardrobeItem()?.sanitizedAttributes() }
    }

    func save(forUser email: String) {
        guard !email.isEmpty else { return }
        let key = WardrobeViewModel.storageKey(for: email)
        let codableItems = items.map { WardrobeItemCodable(from: $0) }
        if let data = try? JSONEncoder().encode(codableItems) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clear() {
        flushTask?.cancel()
        flushTask = nil
        suspendSaving = true
        items = []
        suspendSaving = false
        currentUserEmail = ""
        ledger = SyncLedger()
    }

    // MARK: - iCloud Sync
    //
    // See CloudKitService for the model. Every local change goes into the per-user ledger
    // (pending upload / tombstone) first, then a coalesced flush sends it; the ledger entry
    // is cleared only when CloudKit confirms. A pull never deletes a local item unless the
    // server reported that record deleted.

    /// Main-thread only.
    private var ledger = SyncLedger()
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var isSyncing = false
    private var hydrationAttempted = Set<UUID>()

    private func saveLedger() {
        guard !currentUserEmail.isEmpty else { return }
        ledger.save(userKey: WardrobeViewModel.storageKey(for: currentUserEmail))
    }

    private static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Records a local add/edit and schedules its upload.
    func syncItemToCloud(_ item: WardrobeItem) {
        guard !currentUserEmail.isEmpty else { return }
        let user = currentUserEmail
        WardrobeViewModel.onMain { [weak self] in
            guard let self, self.currentUserEmail == user else { return }
            self.ledger.markPending(item.id)
            self.saveLedger()
            self.scheduleFlush()
        }
    }

    /// Records a local delete (tombstone) and schedules the server deletion.
    func deleteItemFromCloud(_ item: WardrobeItem) {
        guard !currentUserEmail.isEmpty else { return }
        let user = currentUserEmail
        WardrobeViewModel.onMain { [weak self] in
            guard let self, self.currentUserEmail == user else { return }
            self.ledger.markDeleted(item.id)
            self.ledger.generation += 1
            self.saveLedger()
            self.scheduleFlush()
        }
    }

    /// "Back up now": everything is re-sent.
    func backupToCloud() {
        guard !currentUserEmail.isEmpty else { return }
        WardrobeViewModel.onMain { [weak self] in
            guard let self else { return }
            for item in self.items { self.ledger.markPending(item.id) }
            self.saveLedger()
            Task { @MainActor [weak self] in await self?.flushPendingChanges() }
        }
    }

    /// Coalesces bursts (a scan adds items one by one) into one batched upload.
    private func scheduleFlush(after seconds: Double = 2) {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            let generationAtStart = self.ledger.generation
            await self.flushPendingChanges()
            self.flushTask = nil
            // Changes made while the flush ran get their own flush; failures wait for the
            // next sync (no retry loop while offline).
            if self.ledger.generation > generationAtStart, !self.currentUserEmail.isEmpty {
                self.scheduleFlush()
            }
        }
    }

    /// Sends tombstones and pending uploads. Entries stay in the ledger unless confirmed.
    @MainActor
    func flushPendingChanges() async {
        guard !currentUserEmail.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        let user = currentUserEmail
        let cloud = CloudKitService.shared

        let dead = ledger.tombstoneIDs
        if !dead.isEmpty {
            let done = await cloud.deleteRecords(ids: dead)
            guard currentUserEmail == user else { return }
            for id in done { ledger.confirmDeleted(id) }
            saveLedger()
        }

        let snapshot = ledger.pending
        guard !snapshot.isEmpty else { return }
        var byID: [UUID: WardrobeItem] = [:]
        for item in items { byID[item.id] = item }
        var toUpload: [WardrobeItem] = []
        for key in snapshot.keys {
            if let id = UUID(uuidString: key), let item = byID[id] {
                toUpload.append(item)
            } else {
                ledger.pending[key] = nil   // no longer in the wardrobe (deleted: tombstoned)
            }
        }
        let confirmed = await cloud.uploadBatch(toUpload, userID: user)
        guard currentUserEmail == user else { return }
        for id in confirmed { ledger.confirmUpload(id, generation: snapshot[id.uuidString]) }
        saveLedger()
        dlog("[Sync] Flushed: \(confirmed.count)/\(toUpload.count) uploads confirmed, \(ledger.pending.count) pending, \(ledger.tombstones.count) tombstones")
    }

    /// Two-way sync: push pending local changes, then pull the server's changes since the
    /// last token and merge them (local wins; only server deletions delete). Safe to call
    /// on every foreground; concurrent calls collapse into one.
    func restoreFromCloud() async {
        await syncWithCloud()
    }

    /// Set by "Delete Everything" until iCloud confirms the zone is gone. Device-wide.
    static let pendingZoneWipeKey = "cloudPendingZoneWipe"

    /// A pull may only run once a requested iCloud wipe is confirmed — for ANY profile on the
    /// phone (pulls restore the whole zone, whatever profile id uploaded it).
    static func mustWipeZoneBeforePull(ledger: SyncLedger, defaults: UserDefaults = .standard) -> Bool {
        ledger.pendingZoneWipe || defaults.bool(forKey: pendingZoneWipeKey)
    }

    @MainActor
    private func syncWithCloud() async {
        guard !currentUserEmail.isEmpty, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        let user = currentUserEmail
        let cloud = CloudKitService.shared

        if WardrobeViewModel.mustWipeZoneBeforePull(ledger: ledger) {
            guard await cloud.deleteAllData(), currentUserEmail == user else { return }
            UserDefaults.standard.removeObject(forKey: WardrobeViewModel.pendingZoneWipeKey)
            ledger.pendingZoneWipe = false
            ledger.token = nil
            saveLedger()
        }

        await flushPendingChanges()
        guard currentUserEmail == user else { return }

        switch await cloud.fetchChanges(userID: user, since: ledger.token) {
        case .failed:
            return

        case .zoneMissing:
            // Nothing in iCloud (never backed up, or the zone was deleted elsewhere). Local
            // items are kept and queued so the backup is rebuilt.
            guard currentUserEmail == user else { return }
            ledger.token = nil
            for item in items where !ledger.isPending(item.id) { ledger.markPending(item.id) }
            saveLedger()
            await flushPendingChanges()

        case .changes(let changes):
            guard currentUserEmail == user else { return }
            // First reconcile on this phone: edits made under the old sync may never have
            // reached iCloud, so differing copies keep the phone's version (and re-send it).
            let reconciledKey = "cloudReconciled_\(WardrobeViewModel.storageKey(for: user))"
            let firstReconcile = changes.isFullFetch && !UserDefaults.standard.bool(forKey: reconciledKey)
            let outcome = CloudMerge.apply(changes, to: items, ledger: ledger, preferLocal: firstReconcile,
                                           fileExists: { WardrobeImageFileHelper.imageExists(at: $0) })
            if outcome.changed { items = outcome.items }   // one write
            for id in outcome.uploadLocal { ledger.markPending(id) }
            if !outcome.removed.isEmpty {
                let doomed = outcome.removed
                ItemEmbeddingStore.shared.remove(doomed.map(\.id))
                Task.detached(priority: .utility) {
                    for item in doomed { WardrobeViewModel.deleteFiles(of: item) }
                }
                dlog("[Sync] Applied \(doomed.count) server-side deletions")
            }
            for id in outcome.confirmedDeletions { ledger.confirmDeleted(id) }
            if changes.isFullFetch {
                // Heal: items only on this phone (e.g. an upload that failed in an older
                // build) are uploaded rather than ever being treated as deleted.
                let cloudIDs = Set(changes.modified.map(\.id))
                for item in items where !cloudIDs.contains(item.id) && !ledger.isPending(item.id) {
                    ledger.markPending(item.id)
                }
            }
            ledger.token = changes.newToken
            saveLedger()
            UserDefaults.standard.set(true, forKey: reconciledKey)
            if !ledger.pending.isEmpty { await flushPendingChanges() }
            guard currentUserEmail == user else { return }
            await hydrateMissingImages(priority: outcome.needAssets, user: user)
        }
    }

    /// Fetches image assets (off-main) for items whose files aren't on this phone — new
    /// items from the cloud, and any earlier download that failed — and makes thumbnails
    /// for items that have images but none.
    @MainActor
    private func hydrateMissingImages(priority: [WardrobeItem], user: String) async {
        let snapshot = items.map { (id: $0.id, image: $0.imagePath, cropped: $0.croppedImagePath, thumb: $0.thumbnailPath) }
        let priorityIDs = Set(priority.map(\.id))
        // Existence checks off the main thread (one stat per item).
        let (missingImage, missingThumb) = await Task.detached(priority: .utility) { () -> ([UUID], [UUID]) in
            var noImage: [UUID] = [], noThumb: [UUID] = []
            for s in snapshot {
                let hasImage = WardrobeImageFileHelper.imageExists(at: s.image)
                    || (s.cropped.map { WardrobeImageFileHelper.imageExists(at: $0) } ?? false)
                if !hasImage {
                    noImage.append(s.id)
                } else if s.thumb.map({ !WardrobeImageFileHelper.imageExists(at: $0) }) ?? true {
                    noThumb.append(s.id)
                }
            }
            return (noImage, noThumb)
        }.value
        guard currentUserEmail == user else { return }
        // Each item is tried once per launch (an item with no asset in iCloud must not
        // cost a download request on every foreground).
        let toDownload = missingImage.filter { !hydrationAttempted.contains($0) }
        let toThumb = missingThumb.filter { !hydrationAttempted.contains($0) }
        guard !(toDownload.isEmpty && toThumb.isEmpty) else { return }

        var updates: [UUID: CloudKitService.FetchedFiles] = [:]
        if !toDownload.isEmpty {
            // New cloud items first; at most 200 per sync (the rest next time).
            let ordered = toDownload.sorted { priorityIDs.contains($0) && !priorityIDs.contains($1) }
            let wanted = Set(ordered.prefix(200))
            hydrationAttempted.formUnion(wanted)
            let toFetch = items.filter { wanted.contains($0.id) && !$0.imagePath.isEmpty }
            updates = await CloudKitService.shared.fetchAssets(for: toFetch)
        }
        if !toThumb.isEmpty {
            let wanted = Set(toThumb)
            hydrationAttempted.formUnion(wanted)
            let sources = items.filter { wanted.contains($0.id) }.map { (id: $0.id, src: $0.croppedImagePath ?? $0.imagePath) }
            let thumbs = await Task.detached(priority: .utility) { () -> [UUID: String] in
                var out: [UUID: String] = [:]
                for s in sources {
                    if let t = WardrobeImageFileHelper.makeThumbnail(fromFile: s.src) { out[s.id] = t }
                }
                return out
            }.value
            for (id, t) in thumbs { updates[id, default: CloudKitService.FetchedFiles()].thumbnailPath = t }
        }
        guard currentUserEmail == user, !updates.isEmpty else { return }
        var copy = items
        for (i, item) in copy.enumerated() {
            guard let f = updates[item.id] else { continue }
            copy[i] = item.withImages(imagePath: f.imagePath ?? item.imagePath,
                                      croppedImagePath: f.croppedImagePath ?? item.croppedImagePath,
                                      thumbnailPath: f.thumbnailPath ?? item.thumbnailPath)
        }
        items = copy
        dlog("[Sync] Restored images for \(updates.count) items")
    }

    private static func deleteFiles(of item: WardrobeItem) {
        WardrobeImageFileHelper.deleteImage(at: item.imagePath)
        if item.croppedImagePath != item.imagePath {
            WardrobeImageFileHelper.deleteImage(at: item.croppedImagePath)
        }
        WardrobeImageFileHelper.deleteImage(at: item.thumbnailPath)
    }

    // MARK: - Delete everything (App Store 5.1.1(v))

    /// Removes everything StyleMate stores on this phone for `userId`: the wardrobe (under
    /// its real storage key), its image files, the item embeddings, the outfit history,
    /// the selfie + face gallery, and the sync ledger. When `includingCloud`, the user's
    /// iCloud zone is deleted too; if that fails (offline) the deletion is remembered and
    /// retried before any later sync could restore the data.
    ///
    /// Call on the main thread, before signing out.
    @MainActor
    func deleteAllLocalData(forUser userId: String, includingCloud: Bool = true) {
        guard !userId.isEmpty else { return }
        let key = WardrobeViewModel.storageKey(for: userId)
        let userItems = currentUserEmail == userId ? items : WardrobeViewModel.loadItems(forUser: userId)

        if currentUserEmail == userId { clear() }
        UserDefaults.standard.removeObject(forKey: key)
        for legacy in ["wardrobe_\(userId)", "wardrobeData_\(userId)"] {
            UserDefaults.standard.removeObject(forKey: legacy)
        }
        for flag in ["thumbnailMigrationComplete_", "thumbnailScaleMigration_v1_", "bgRemovalMigrationComplete_",
                     "zoneCropMigrationComplete_", "hasMigratedBackgroundRemoval_", "hasMigratedThumbnails_",
                     "hasMigratedZoneCrop_"] {
            UserDefaults.standard.removeObject(forKey: flag + userId)
        }

        // Embeddings and studio-render bookkeeping: drop this user's entries in memory and
        // on disk first (the stores would otherwise rewrite them on their next save).
        ItemEmbeddingStore.shared.remove(userItems.map(\.id))
        StudioQueue.shared.cancel()
        StudioStore.shared.remove(userItems.map(\.id))

        // Is anyone else's wardrobe on this phone? If not, wipe the shared folders whole
        // (catches orphaned files too); otherwise delete only this user's files.
        let otherWardrobes = UserDefaults.standard.dictionaryRepresentation().keys.contains {
            $0.hasPrefix("wardrobe_") && $0 != key
        }
        let fm = FileManager.default
        if otherWardrobes {
            for item in userItems { WardrobeViewModel.deleteFiles(of: item) }
        } else {
            try? fm.removeItem(at: WardrobeImageFileHelper.folderURL)
            try? fm.removeItem(at: LocalStore.documents.appendingPathComponent(WardrobeImageFileHelper.folderName))
            ItemEmbeddingStore.shared.removeAll()
            StudioStore.shared.removeAll()
            try? fm.removeItem(at: LocalStore.applicationSupport.appendingPathComponent("WardrobeEmbeddings"))
        }
        WardrobeImageFileHelper.removeAllFromCache()

        // Outfit history (Core Data), scoped to this user (+ legacy unscoped rows).
        MyOutfitsViewModel.deleteOutfits(forUser: userId)

        // Selfie + face gallery.
        FaceMatchingService.shared.clearReference(forUser: userId)
        LocalStore.deleteSelfie(userId: userId)

        // Sync ledger, then the cloud copy.
        SyncLedger.remove(userKey: key)
        UserDefaults.standard.removeObject(forKey: "cloudReconciled_\(key)")
        if includingCloud {
            // Device-wide, not per profile: "Delete Everything" starts a NEW profile id, and
            // pulls aren't filtered by profile, so the new profile must not pull the old
            // wardrobe back before the zone deletion is confirmed.
            UserDefaults.standard.set(true, forKey: WardrobeViewModel.pendingZoneWipeKey)
            Task { @MainActor in
                if await CloudKitService.shared.deleteAllData() {
                    UserDefaults.standard.removeObject(forKey: WardrobeViewModel.pendingZoneWipeKey)
                }
            }
        }
        dlog("[Wardrobe] Deleted all local data (\(userItems.count) items)")
    }

    // MARK: - One-time migrations

    /// Regenerates thumbnails that are missing or oversized. Thumbnails used to be rendered
    /// at the screen scale (3x), so the "480 px" thumbnails were 1440 px — bigger than the
    /// cutouts, and ~8 MB each once decoded. Runs once per user, off the main thread, and
    /// updates items by id (never by index), so it can't race the scan or a delete.
    func migrateThumbnails() {
        let user = currentUserEmail
        guard !user.isEmpty else { return }
        let doneKey = "thumbnailScaleMigration_v1_\(user)"
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }
        let snapshot = items.map { (id: $0.id, src: $0.croppedImagePath ?? $0.imagePath, thumb: $0.thumbnailPath) }
        guard !snapshot.isEmpty else {
            UserDefaults.standard.set(true, forKey: doneKey)
            return
        }

        Task.detached(priority: .background) { [weak self] in
            var made: [(id: UUID, old: String?, new: String)] = []
            for s in snapshot {
                autoreleasepool {
                    guard WardrobeImageFileHelper.thumbnailNeedsRegeneration(s.thumb),
                          let new = WardrobeImageFileHelper.makeThumbnail(fromFile: s.src) else { return }
                    made.append((s.id, s.thumb, new))
                }
            }
            let results = made
            await MainActor.run {
                guard let self, self.currentUserEmail == user else {
                    for r in results { WardrobeImageFileHelper.deleteImage(at: r.new) }
                    return
                }
                var byID: [UUID: (old: String?, new: String)] = [:]
                for r in results { byID[r.id] = (r.old, r.new) }
                var copy = self.items
                var replacedOld: [String] = []
                var applied = Set<UUID>()
                for (i, item) in copy.enumerated() {
                    // Only if the item still has the thumbnail we replaced (not deleted /
                    // re-photographed meanwhile).
                    guard let r = byID[item.id], item.thumbnailPath == r.old else { continue }
                    copy[i] = item.withImages(imagePath: item.imagePath,
                                              croppedImagePath: item.croppedImagePath,
                                              thumbnailPath: r.new)
                    if let old = r.old { replacedOld.append(old) }
                    applied.insert(item.id)
                }
                if !applied.isEmpty { self.items = copy }
                for r in results where !applied.contains(r.id) { WardrobeImageFileHelper.deleteImage(at: r.new) }
                for old in replacedOld { WardrobeImageFileHelper.deleteImage(at: old) }
                UserDefaults.standard.set(true, forKey: doneKey)
                dlog("[Wardrobe] Thumbnail migration: regenerated \(applied.count)")
            }
        }
    }

    /// Retired. The pre-on-device-pipeline background-removal and zone-crop migrations
    /// rewrote items by stale array index from a background task (index-out-of-range
    /// crashes / the wrong item overwritten mid-scan) and turned transparent PNG cutouts
    /// into JPEGs on white. Every cutout the current pipeline makes is already final, so
    /// they are now just marked done. Kept so existing callers compile.
    func migrateBackgroundRemoval() {
        let user = currentUserEmail
        guard !user.isEmpty else { return }
        UserDefaults.standard.set(true, forKey: "bgRemovalMigrationComplete_\(user)")
        UserDefaults.standard.set(true, forKey: "zoneCropMigrationComplete_\(user)")
    }
}

struct WardrobeItemCodable: Codable {
    let id: String
    let category: String
    let product: String
    let colors: [String]
    let brand: String
    let pattern: String
    let imagePath: String
    let croppedImagePath: String?
    let thumbnailPath: String?

    let material: String?
    let fit: String?
    let neckline: String?
    let sleeveLength: String?
    let garmentLength: String?
    let details: String?

    enum CodingKeys: String, CodingKey {
        case id, category, product, colors, brand, pattern, imagePath, croppedImagePath, thumbnailPath
        case material, fit, neckline, sleeveLength, garmentLength, details
    }

    init(from item: WardrobeItem) {
        self.id = item.id.uuidString
        self.category = item.category.rawValue
        self.product = item.product
        self.colors = item.colors
        self.brand = item.brand
        self.pattern = item.pattern.rawValue
        self.imagePath = item.imagePath
        self.croppedImagePath = item.croppedImagePath
        self.thumbnailPath = item.thumbnailPath
        self.material = item.material
        self.fit = item.fit?.rawValue
        self.neckline = item.neckline?.rawValue
        self.sleeveLength = item.sleeveLength?.rawValue
        self.garmentLength = item.garmentLength?.rawValue
        self.details = item.details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        category = try container.decode(String.self, forKey: .category)
        product = try container.decode(String.self, forKey: .product)
        colors = try container.decode([String].self, forKey: .colors)
        brand = try container.decode(String.self, forKey: .brand)
        pattern = try container.decode(String.self, forKey: .pattern)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        croppedImagePath = try container.decodeIfPresent(String.self, forKey: .croppedImagePath)
        thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        material = try container.decodeIfPresent(String.self, forKey: .material)
        fit = try container.decodeIfPresent(String.self, forKey: .fit)
        neckline = try container.decodeIfPresent(String.self, forKey: .neckline)
        sleeveLength = try container.decodeIfPresent(String.self, forKey: .sleeveLength)
        garmentLength = try container.decodeIfPresent(String.self, forKey: .garmentLength)
        details = try container.decodeIfPresent(String.self, forKey: .details)
    }
    
    func toWardrobeItem() -> WardrobeItem? {
        guard let cat = Category(rawValue: category),
              let pat = Pattern(rawValue: pattern) else { return nil }
        return WardrobeItem(
            id: UUID(uuidString: id) ?? UUID(),
            category: cat,
            product: product,
            colors: colors,
            brand: brand,
            pattern: pat,
            imagePath: imagePath,
            croppedImagePath: croppedImagePath,
            thumbnailPath: thumbnailPath,
            material: material,
            fit: fit != nil ? Fit(rawValue: fit!) : nil,
            neckline: neckline != nil ? Neckline(rawValue: neckline!) : nil,
            sleeveLength: sleeveLength != nil ? SleeveLength(rawValue: sleeveLength!) : nil,
            garmentLength: garmentLength != nil ? GarmentLength(rawValue: garmentLength!) : nil,
            details: details
        )
    }
} 