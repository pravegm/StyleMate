import Foundation
import CloudKit
import UIKit

/// The user's own iCloud backup of the wardrobe (CloudKit private database, custom zone).
///
/// Sync model (Nov 2026 rewrite — the old full-fetch diff deleted local items the cloud
/// didn't have, e.g. any item whose upload failed or was still in flight):
/// - **The phone is the source of truth.** Local items are only ever removed because of a
///   deletion the SERVER reports (another device deleted the record), never because a fetch
///   didn't return them.
/// - **Incremental pulls.** `fetchChanges` asks for the changes since a persisted server
///   change token, without assets (`desiredKeys`). Image assets are downloaded lazily, off
///   the main thread, only for items whose files are missing (`fetchAssets`).
/// - **Durable pushes.** Every local change is recorded in a per-user `SyncLedger`
///   (pending uploads + tombstones for local deletes) before it is sent, and stays there
///   until CloudKit confirms it, so failed uploads/deletes are retried on the next sync.
/// - **Local wins.** A cloud change to an item with a pending local change is ignored (the
///   upload will overwrite it); a cloud copy of a locally deleted item is ignored.
/// - **All-or-nothing.** Any error during a pull returns `.failed`: nothing is applied and
///   the token isn't advanced.
///
/// `WardrobeViewModel` (Models/Category.swift) drives this from `restoreFromCloud()`.
@MainActor
final class CloudKitService: ObservableObject {
    static let shared = CloudKitService()

    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date? = nil

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case success
    }

    private let container = CKContainer.default()
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    nonisolated static let recordType = "WardrobeItem"
    nonisolated static let zoneName = "WardrobeZone"
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitService.zoneName)

    /// Metadata fields fetched on a pull. Assets are deliberately absent: they are fetched
    /// per item, only when the local files are missing.
    nonisolated static let metadataKeys: [CKRecord.FieldKey] = [
        "userID", "category", "product", "colors", "brand", "pattern", "imagePath",
        "croppedImagePath", "thumbnailPath", "material", "fit", "neckline", "sleeveLength",
        "garmentLength", "details"
    ]
    nonisolated static let assetKeys: [CKRecord.FieldKey] = ["imageAsset", "croppedImageAsset"]

    /// Set once we hit a permanent provisioning/schema rejection (e.g. the record type
    /// isn't configured in this build's container, or no iCloud account). Further cloud
    /// calls are short-circuited for the session. Cleared next launch.
    private var cloudUnavailable = false
    private var zoneReady = false

    /// Errors that won't fix themselves by retrying.
    private func isPermanent(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .serverRejectedRequest, .badContainer, .missingEntitlement, .notAuthenticated,
             .managedAccountRestricted, .invalidArguments, .permissionFailure:
            return true
        default:
            return false
        }
    }

    private init() {
        lastSyncDate = UserDefaults.standard.object(forKey: "lastCloudKitSync") as? Date
    }

    // MARK: - Zone Setup

    func setupZone() async {
        guard !cloudUnavailable, !zoneReady else { return }
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await privateDB.save(zone)
            zoneReady = true
        } catch let error as CKError where error.code == .serverRejectedRequest {
            zoneReady = true   // zone already exists
        } catch {
            latchIfPermanent(error, context: "Zone setup")
        }
    }

    // MARK: - Records

    private func makeRecord(for item: WardrobeItem, userID: String) -> CKRecord {
        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: recordID)
        record["userID"] = userID
        record["category"] = item.category.rawValue
        record["product"] = item.product
        record["colors"] = item.colors
        record["brand"] = item.brand
        record["pattern"] = item.pattern.rawValue
        record["imagePath"] = item.imagePath
        record["croppedImagePath"] = item.croppedImagePath
        record["material"] = item.material
        record["fit"] = item.fit?.rawValue
        record["neckline"] = item.neckline?.rawValue
        record["sleeveLength"] = item.sleeveLength?.rawValue
        record["garmentLength"] = item.garmentLength?.rawValue
        record["details"] = item.details
        record["thumbnailPath"] = item.thumbnailPath
        if let imageURL = existingImageURL(item.imagePath) {
            record["imageAsset"] = CKAsset(fileURL: imageURL)
        }
        if let cropped = item.croppedImagePath, cropped != item.imagePath,
           let croppedURL = existingImageURL(cropped) {
            record["croppedImageAsset"] = CKAsset(fileURL: croppedURL)
        }
        return record
    }

    private func existingImageURL(_ filename: String) -> URL? {
        guard !filename.isEmpty else { return nil }
        let url = WardrobeImageFileHelper.fileURL(for: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Upload

    /// Uploads one item. True only when CloudKit confirmed the save.
    @discardableResult
    func uploadItem(_ item: WardrobeItem, userID: String) async -> Bool {
        await uploadBatch([item], userID: userID).contains(item.id)
    }

    /// Uploads items in small batches; returns the ids CloudKit confirmed. Per-record
    /// failures are simply not in the result (they stay pending and are retried).
    func uploadBatch(_ items: [WardrobeItem], userID: String) async -> Set<UUID> {
        guard !cloudUnavailable, !items.isEmpty else { return [] }
        await setupZone()
        guard !cloudUnavailable else { return [] }
        var confirmed: Set<UUID> = []
        var queue: [[WardrobeItem]] = stride(from: 0, to: items.count, by: 20).map {
            Array(items[$0..<min($0 + 20, items.count)])
        }
        while !queue.isEmpty {
            let batch = queue.removeFirst()
            let records = batch.map { makeRecord(for: $0, userID: userID) }
            do {
                let (saveResults, _) = try await privateDB.modifyRecords(
                    saving: records, deleting: [], savePolicy: .changedKeys, atomically: false)
                for (recordID, result) in saveResults {
                    switch result {
                    case .success:
                        if let id = UUID(uuidString: recordID.recordName) { confirmed.insert(id) }
                    case .failure(let error):
                        latchIfPermanent(error, context: "Upload record")
                    }
                }
            } catch let ck as CKError where ck.code == .limitExceeded && batch.count > 1 {
                // Request too large (assets): split and retry the halves.
                let mid = batch.count / 2
                queue.insert(Array(batch[mid...]), at: 0)
                queue.insert(Array(batch[..<mid]), at: 0)
            } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .userDeletedZone {
                zoneReady = false
                break   // the zone is recreated and these retried on the next sync
            } catch {
                latchIfPermanent(error, context: "Upload")
                break   // offline / throttled: the rest stays pending
            }
        }
        return confirmed
    }

    /// Full backup of the given items ("Back up now" in Profile). Returns confirmed ids.
    @discardableResult
    func uploadAll(items: [WardrobeItem], userID: String) async -> Set<UUID> {
        guard !cloudUnavailable else { return [] }
        syncStatus = .syncing
        let confirmed = await uploadBatch(items, userID: userID)
        syncStatus = confirmed.count == items.count ? .success : .error("Some items couldn't be backed up")
        if !confirmed.isEmpty {
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "lastCloudKitSync")
        }
        resetStatusAfterDelay()
        return confirmed
    }

    // MARK: - Delete

    /// Deletes records. Returns the ids confirmed gone (deleted now, or already absent).
    func deleteRecords(ids: [UUID]) async -> Set<UUID> {
        guard !cloudUnavailable, !ids.isEmpty else { return [] }
        var done: Set<UUID> = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let recordIDs = chunk.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zoneID) }
            do {
                let (_, deleteResults) = try await privateDB.modifyRecords(
                    saving: [], deleting: recordIDs, savePolicy: .changedKeys, atomically: false)
                for (recordID, result) in deleteResults {
                    guard let id = UUID(uuidString: recordID.recordName) else { continue }
                    switch result {
                    case .success:
                        done.insert(id)
                    case .failure(let error):
                        if (error as? CKError)?.code == .unknownItem { done.insert(id) }
                    }
                }
            } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .userDeletedZone {
                done.formUnion(chunk)   // the whole zone is gone, so are its records
            } catch {
                latchIfPermanent(error, context: "Delete")
                break
            }
        }
        return done
    }

    @discardableResult
    func deleteItem(id: UUID) async -> Bool {
        await deleteRecords(ids: [id]).contains(id)
    }

    // MARK: - Delete All Data

    /// Deletes the whole wardrobe zone ("Delete Everything"). True when CloudKit confirmed
    /// it (or there was nothing to delete). On failure `WardrobeViewModel` keeps a
    /// `pendingZoneWipe` flag and retries; no pull happens while it is set.
    @discardableResult
    func deleteAllData() async -> Bool {
        guard !cloudUnavailable else { return false }
        dlog("[CloudKit] Deleting all data")
        do {
            try await privateDB.deleteRecordZone(withID: zoneID)
            zoneReady = false
            dlog("[CloudKit] Zone deleted")
            return true
        } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .userDeletedZone {
            zoneReady = false
            return true
        } catch {
            latchIfPermanent(error, context: "Delete all data")
            return false
        }
    }

    // MARK: - Pull (incremental)

    /// What changed on the server since a token. `modified` are metadata-only items (their
    /// image files may not exist on this phone yet); `deleted` are server-side deletions.
    struct CloudChanges {
        var modified: [WardrobeItem] = []
        var deleted: Set<UUID> = []
        var newToken: CKServerChangeToken?
        /// True when this was a full pull (no token): `modified` is then every record.
        var isFullFetch = false
    }

    enum PullResult {
        case changes(CloudChanges)
        /// The zone doesn't exist (nothing backed up yet, or it was deleted). Not an error,
        /// and NEVER a reason to delete anything locally.
        case zoneMissing
        /// Any error: apply nothing.
        case failed
    }

    /// Fetches the changes since `token` (nil = everything), metadata only. Pages are
    /// accumulated and returned only if every page (and every record) succeeded.
    func fetchChanges(userID: String, since token: CKServerChangeToken?) async -> PullResult {
        guard !cloudUnavailable else { return .failed }
        await setupZone()
        guard !cloudUnavailable else { return .failed }
        syncStatus = .syncing

        var result = CloudChanges()
        result.isFullFetch = token == nil
        var cursor = token
        do {
            while true {
                let changes = try await privateDB.recordZoneChanges(
                    inZoneWith: zoneID, since: cursor, desiredKeys: Self.metadataKeys)
                for (_, modification) in changes.modificationResultsByID {
                    switch modification {
                    case .success(let mod):
                        guard (mod.record["userID"] as? String) == userID else { continue }
                        if let item = Self.wardrobeItem(from: mod.record) {
                            result.modified.append(item)
                        }
                    case .failure(let error):
                        throw error   // don't advance past a record we couldn't read
                    }
                }
                for deletion in changes.deletions where deletion.recordType == Self.recordType {
                    if let id = UUID(uuidString: deletion.recordID.recordName) { result.deleted.insert(id) }
                }
                cursor = changes.changeToken
                if !changes.moreComing { break }
            }
            result.newToken = cursor
            syncStatus = .success
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "lastCloudKitSync")
            resetStatusAfterDelay()
            return .changes(result)
        } catch let ck as CKError where ck.code == .changeTokenExpired && token != nil {
            dlog("[CloudKit] Change token expired; doing a full (non-destructive) pull")
            return await fetchChanges(userID: userID, since: nil)
        } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .userDeletedZone {
            zoneReady = false
            syncStatus = .idle
            return .zoneMissing
        } catch {
            latchIfPermanent(error, context: "Fetch")
            syncStatus = cloudUnavailable ? .idle : .error("Could not fetch from iCloud")
            if !cloudUnavailable { resetStatusAfterDelay() }
            return .failed
        }
    }

    /// Compatibility wrapper: every item this app-user has in the cloud (metadata only),
    /// or nil on ANY error — never a partial list.
    func fetchAll(userID: String) async -> [WardrobeItem]? {
        if case .changes(let c) = await fetchChanges(userID: userID, since: nil) { return c.modified }
        return nil
    }

    // MARK: - Assets (lazy, off the main thread)

    /// Local file names written for one item by `fetchAssets`.
    struct FetchedFiles: Sendable {
        var imagePath: String?
        var croppedImagePath: String?
        var thumbnailPath: String?
    }

    /// Downloads the image assets of the given items and writes them into the wardrobe
    /// folder under the file names the items already reference (no decoding: the asset IS
    /// the PNG/JPEG we uploaded), then makes a thumbnail with ImageIO. All file work runs
    /// off the main thread.
    func fetchAssets(for items: [WardrobeItem]) async -> [UUID: FetchedFiles] {
        guard !cloudUnavailable, !items.isEmpty else { return [:] }
        let db = privateDB
        let zone = zoneID
        let wanted: [(id: UUID, image: String, cropped: String?)] = items.map {
            (id: $0.id, image: $0.imagePath, cropped: $0.croppedImagePath)
        }
        return await Task.detached(priority: .utility) { () -> [UUID: FetchedFiles] in
            var out: [UUID: FetchedFiles] = [:]
            for start in stride(from: 0, to: wanted.count, by: 10) {
                let chunk = Array(wanted[start..<min(start + 10, wanted.count)])
                let ids = chunk.map { CKRecord.ID(recordName: $0.id.uuidString, zoneID: zone) }
                guard let results = try? await db.records(for: ids, desiredKeys: CloudKitService.assetKeys) else { break }
                for entry in chunk {
                    let rid = CKRecord.ID(recordName: entry.id.uuidString, zoneID: zone)
                    guard let fetched = results[rid], case .success(let record) = fetched else { continue }
                    var files = FetchedFiles()
                    files.imagePath = CloudKitService.store(record["imageAsset"] as? CKAsset, as: entry.image)
                    if let cropped = entry.cropped, cropped != entry.image {
                        files.croppedImagePath = CloudKitService.store(record["croppedImageAsset"] as? CKAsset, as: cropped)
                    } else {
                        files.croppedImagePath = files.imagePath
                    }
                    if let source = files.croppedImagePath ?? files.imagePath {
                        files.thumbnailPath = WardrobeImageFileHelper.makeThumbnail(fromFile: source)
                    }
                    if files.imagePath != nil || files.croppedImagePath != nil { out[entry.id] = files }
                }
            }
            return out
        }.value
    }

    /// Copies a downloaded asset into the wardrobe folder as `filename` (kept, so the item
    /// record and the cloud agree). Returns the file name, or nil.
    nonisolated static func store(_ asset: CKAsset?, as filename: String) -> String? {
        guard !filename.isEmpty, !filename.contains("/"), let src = asset?.fileURL else { return nil }
        let dst = WardrobeImageFileHelper.fileURL(for: filename)
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { return filename }
        do {
            try fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.protectionKey: LocalStore.fileProtection], ofItemAtPath: dst.path)
            return filename
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    /// Latches `cloudUnavailable` on a permanent (provisioning/auth) error so we stop
    /// retrying for the rest of the session. Transient errors are logged (DEBUG only).
    private func latchIfPermanent(_ error: Error, context: String) {
        if isPermanent(error) {
            if !cloudUnavailable {
                let code = (error as? CKError)?.code.rawValue ?? -1
                dlog("[CloudKit] Cloud unavailable (error \(code)); disabling cloud sync for this session.")
            }
            cloudUnavailable = true
        } else {
            dlog("[CloudKit] \(context) error: \(error.localizedDescription)")
        }
    }

    func checkAccountStatus() async -> Bool {
        do {
            return try await container.accountStatus() == .available
        } catch {
            return false
        }
    }

    private func resetStatusAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if syncStatus != .syncing { syncStatus = .idle }
        }
    }

    /// A metadata-only item from a record. Pure: no disk access. `thumbnailPath` is only a
    /// hint — the caller checks whether the files exist on this phone.
    nonisolated static func wardrobeItem(from record: CKRecord) -> WardrobeItem? {
        guard let categoryStr = record["category"] as? String,
              let category = Category(rawValue: categoryStr),
              let product = record["product"] as? String,
              let colors = record["colors"] as? [String],
              let brand = record["brand"] as? String,
              let patternStr = record["pattern"] as? String,
              let pattern = Pattern(rawValue: patternStr),
              let id = UUID(uuidString: record.recordID.recordName) else {
            return nil
        }
        return WardrobeItem(
            id: id,
            category: category,
            product: product,
            colors: colors,
            brand: brand,
            pattern: pattern,
            imagePath: record["imagePath"] as? String ?? "",
            croppedImagePath: record["croppedImagePath"] as? String,
            thumbnailPath: record["thumbnailPath"] as? String,
            material: record["material"] as? String,
            fit: (record["fit"] as? String).flatMap { Fit(rawValue: $0) },
            neckline: (record["neckline"] as? String).flatMap { Neckline(rawValue: $0) },
            sleeveLength: (record["sleeveLength"] as? String).flatMap { SleeveLength(rawValue: $0) },
            garmentLength: (record["garmentLength"] as? String).flatMap { GarmentLength(rawValue: $0) },
            details: record["details"] as? String
        )
    }
}

// MARK: - Sync ledger

/// Durable per-user sync bookkeeping, persisted in UserDefaults (small: ids + a token).
struct SyncLedger: Codable, Equatable {
    /// Items with local changes CloudKit hasn't confirmed: id -> change generation. A
    /// confirmation only clears the entry if no newer change was made meanwhile.
    var pending: [String: Int] = [:]
    /// Items deleted locally whose server deletion isn't confirmed yet.
    var tombstones: Set<String> = []
    /// Archived `CKServerChangeToken` of the last applied pull.
    var changeToken: Data?
    /// "Delete Everything" ran but the zone deletion isn't confirmed: retry before any pull.
    var pendingZoneWipe = false
    var generation = 0

    @discardableResult
    mutating func markPending(_ id: UUID) -> Int {
        generation += 1
        pending[id.uuidString] = generation
        tombstones.remove(id.uuidString)
        return generation
    }

    /// Clears a pending upload. With a generation, only if no newer change was recorded.
    mutating func confirmUpload(_ id: UUID, generation g: Int? = nil) {
        let key = id.uuidString
        if let g, let current = pending[key], current != g { return }
        pending[key] = nil
    }

    mutating func markDeleted(_ id: UUID) {
        pending[id.uuidString] = nil
        tombstones.insert(id.uuidString)
    }

    mutating func confirmDeleted(_ id: UUID) {
        tombstones.remove(id.uuidString)
    }

    func isPending(_ id: UUID) -> Bool { pending[id.uuidString] != nil }
    func isTombstoned(_ id: UUID) -> Bool { tombstones.contains(id.uuidString) }
    var pendingIDs: [UUID] { pending.keys.compactMap { UUID(uuidString: $0) } }
    var tombstoneIDs: [UUID] { tombstones.compactMap { UUID(uuidString: $0) } }

    var token: CKServerChangeToken? {
        get {
            guard let changeToken else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: changeToken)
        }
        set {
            changeToken = newValue.flatMap {
                try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
            }
        }
    }

    static func key(forUserKey userKey: String) -> String { "cloudSyncLedger_\(userKey)" }

    static func load(userKey: String) -> SyncLedger {
        guard let data = UserDefaults.standard.data(forKey: key(forUserKey: userKey)),
              let ledger = try? JSONDecoder().decode(SyncLedger.self, from: data) else { return SyncLedger() }
        return ledger
    }

    func save(userKey: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(forUserKey: userKey))
        }
    }

    static func remove(userKey: String) {
        UserDefaults.standard.removeObject(forKey: key(forUserKey: userKey))
    }
}

/// The pure merge rules of a pull, separate so they can be unit-tested.
enum CloudMerge {
    struct Outcome {
        var items: [WardrobeItem]
        /// Local items removed because the server reported their deletion.
        var removed: [WardrobeItem] = []
        /// Items that need their image files fetched (new from the cloud, or files missing).
        var needAssets: [WardrobeItem] = []
        /// Tombstones the server confirmed (the record is gone).
        var confirmedDeletions: Set<UUID> = []
        var changed = false
    }

    /// Applies `changes` to `local` under `ledger`. `fileExists` says whether an image
    /// file is on this phone.
    static func apply(_ changes: CloudKitService.CloudChanges, to local: [WardrobeItem],
                      ledger: SyncLedger, fileExists: (String) -> Bool) -> Outcome {
        var out = Outcome(items: local)
        var indexByID: [UUID: Int] = [:]
        for (i, item) in local.enumerated() { indexByID[item.id] = i }

        for cloud in changes.modified {
            if ledger.isTombstoned(cloud.id) || ledger.isPending(cloud.id) { continue }   // local wins
            if let idx = indexByID[cloud.id] {
                let mine = out.items[idx]
                guard metadataDiffers(mine, cloud) else { continue }
                let image = fileExists(mine.imagePath) ? mine.imagePath : cloud.imagePath
                var cropped = cloud.croppedImagePath
                if let c = mine.croppedImagePath, fileExists(c) { cropped = c }
                var thumb: String? = nil
                if let t = mine.thumbnailPath, fileExists(t) { thumb = t }
                let merged = WardrobeItem(
                    id: cloud.id, category: cloud.category, product: cloud.product,
                    colors: cloud.colors, brand: cloud.brand, pattern: cloud.pattern,
                    imagePath: image, croppedImagePath: cropped, thumbnailPath: thumb,
                    material: cloud.material, fit: cloud.fit, neckline: cloud.neckline,
                    sleeveLength: cloud.sleeveLength, garmentLength: cloud.garmentLength,
                    details: cloud.details)
                out.items[idx] = merged
                out.changed = true
                if !fileExists(image) || thumb == nil { out.needAssets.append(merged) }
            } else {
                var thumb: String? = nil
                if let t = cloud.thumbnailPath, fileExists(t) { thumb = t }
                let item = cloud.withImages(imagePath: cloud.imagePath,
                                            croppedImagePath: cloud.croppedImagePath,
                                            thumbnailPath: thumb)
                out.items.append(item)
                indexByID[item.id] = out.items.count - 1
                out.changed = true
                if !fileExists(item.imagePath) || thumb == nil { out.needAssets.append(item) }
            }
        }

        for id in changes.deleted where ledger.isTombstoned(id) { out.confirmedDeletions.insert(id) }
        // Only server-reported deletions remove local items, and never one with a pending
        // local change (it will be re-uploaded).
        let toRemove = Set(changes.deleted.filter { indexByID[$0] != nil && !ledger.isPending($0) })
        if !toRemove.isEmpty {
            out.removed = out.items.filter { toRemove.contains($0.id) }
            out.items.removeAll { toRemove.contains($0.id) }
            out.needAssets.removeAll { toRemove.contains($0.id) }
            out.changed = true
        }
        return out
    }

    static func metadataDiffers(_ a: WardrobeItem, _ b: WardrobeItem) -> Bool {
        a.category != b.category || a.product != b.product || a.colors != b.colors
            || a.brand != b.brand || a.pattern != b.pattern || a.material != b.material
            || a.fit != b.fit || a.neckline != b.neckline || a.sleeveLength != b.sleeveLength
            || a.garmentLength != b.garmentLength || a.details != b.details
    }
}
