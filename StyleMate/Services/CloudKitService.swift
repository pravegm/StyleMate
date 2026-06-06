import Foundation
import CloudKit
import UIKit

@MainActor
class CloudKitService: ObservableObject {
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
    private let recordType = "WardrobeItem"
    private let zoneName = "WardrobeZone"
    private lazy var zoneID = CKRecordZone.ID(zoneName: zoneName)

    /// Set once we hit a permanent provisioning/schema rejection (e.g. the
    /// WardrobeItem record type / queryable index isn't configured in this build's
    /// CloudKit container). Further cloud reads are short-circuited so we don't
    /// hammer the server and spam the log on every foreground. Cleared next launch.
    private var cloudUnavailable = false

    /// Errors that won't fix themselves by retrying — they need the CloudKit
    /// container/schema to be set up (or the user to sign into iCloud), not a retry.
    private func isPermanent(_ error: Error) -> Bool {
        guard let ck = error as? CKError else { return false }
        switch ck.code {
        case .serverRejectedRequest, .unknownItem, .badContainer,
             .missingEntitlement, .notAuthenticated, .managedAccountRestricted,
             .invalidArguments:
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
        let zone = CKRecordZone(zoneID: zoneID)
        do {
            _ = try await privateDB.save(zone)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone already exists
        } catch {
            print("[CloudKit] Zone setup error: \(error.localizedDescription)")
        }
    }

    // MARK: - Upload Single Item

    func uploadItem(_ item: WardrobeItem, userID: String) async -> Bool {
        let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)

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

        if let imageURL = imageFileURL(for: item.imagePath) {
            record["imageAsset"] = CKAsset(fileURL: imageURL)
        }
        if let croppedPath = item.croppedImagePath,
           let croppedURL = imageFileURL(for: croppedPath) {
            record["croppedImageAsset"] = CKAsset(fileURL: croppedURL)
        }

        do {
            let (saveResults, _) = try await privateDB.modifyRecords(
                saving: [record],
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            return !saveResults.isEmpty
        } catch {
            print("[CloudKit] Upload error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Upload All Items (Full Sync)

    func uploadAll(items: [WardrobeItem], userID: String) async {
        syncStatus = .syncing
        var successCount = 0

        let batches = stride(from: 0, to: items.count, by: 50).map {
            Array(items[$0..<min($0 + 50, items.count)])
        }

        for batch in batches {
            let records = batch.compactMap { item -> CKRecord? in
                let recordID = CKRecord.ID(recordName: item.id.uuidString, zoneID: zoneID)
                let record = CKRecord(recordType: recordType, recordID: recordID)
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

                if let imageURL = imageFileURL(for: item.imagePath) {
                    record["imageAsset"] = CKAsset(fileURL: imageURL)
                }
                if let croppedPath = item.croppedImagePath,
                   let croppedURL = imageFileURL(for: croppedPath) {
                    record["croppedImageAsset"] = CKAsset(fileURL: croppedURL)
                }
                return record
            }

            do {
                let (saveResults, _) = try await privateDB.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys, atomically: false)
                successCount += saveResults.count
            } catch {
                print("[CloudKit] Batch upload error: \(error.localizedDescription)")
            }
        }

        syncStatus = successCount > 0 ? .success : .error("Failed to upload items")
        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: "lastCloudKitSync")
        resetStatusAfterDelay()
    }

    // MARK: - Fetch All Items

    /// Pulls every wardrobe record from the user's OWN private zone. Uses a
    /// zone-changes fetch (not a CKQuery), so it needs no queryable index in the
    /// CloudKit dashboard — it works as soon as the user is signed into iCloud.
    /// The private database is per-Apple-ID, so all records in the zone are theirs.
    func fetchAll(userID: String) async -> [WardrobeItem] {
        // Already known to be unavailable this session — don't retry / spam the log.
        guard !cloudUnavailable else { return [] }
        syncStatus = .syncing
        await setupZone()   // make sure the zone exists before fetching changes

        var allItems: [WardrobeItem] = []
        var token: CKServerChangeToken? = nil
        do {
            while true {
                let changes = try await privateDB.recordZoneChanges(inZoneWith: zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result,
                       (mod.record["userID"] as? String) == userID,   // this app-account's items
                       let item = wardrobeItem(from: mod.record) {
                        allItems.append(item)
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            }
            syncStatus = .success
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "lastCloudKitSync")
            resetStatusAfterDelay()
        } catch let ck as CKError where ck.code == .zoneNotFound || ck.code == .userDeletedZone {
            // No data backed up yet for this account — not an error.
            syncStatus = .idle
        } catch {
            if isPermanent(error) {
                cloudUnavailable = true
                print("[CloudKit] Cloud sync unavailable (not provisioned / not signed into iCloud): \(error.localizedDescription). Disabling cloud reads for this session.")
                syncStatus = .idle
            } else {
                print("[CloudKit] Fetch error: \(error.localizedDescription)")
                syncStatus = .error("Could not fetch from iCloud")
                resetStatusAfterDelay()
            }
        }

        return allItems
    }

    // MARK: - Delete Item

    func deleteItem(id: UUID) async {
        let recordID = CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
        do {
            try await privateDB.deleteRecord(withID: recordID)
        } catch {
            print("[CloudKit] Delete error: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete All Data

    func deleteAllData() async {
        print("[StyleMate] CloudKit: Deleting all data")
        do {
            try await privateDB.deleteRecordZone(withID: zoneID)
            print("[StyleMate] CloudKit: Zone deleted successfully")
            await setupZone()
            print("[StyleMate] CloudKit: Zone recreated")
        } catch {
            print("[StyleMate] CloudKit: Delete all data error: \(error.localizedDescription)")
        }
    }

    // MARK: - Check iCloud Status

    func checkAccountStatus() async -> Bool {
        do {
            let status = try await container.accountStatus()
            return status == .available
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func resetStatusAfterDelay() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            syncStatus = .idle
        }
    }

    private func imageFileURL(for filename: String) -> URL? {
        let url = WardrobeImageFileHelper.folderURL.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func wardrobeItem(from record: CKRecord) -> WardrobeItem? {
        guard let categoryStr = record["category"] as? String,
              let category = Category(rawValue: categoryStr),
              let product = record["product"] as? String,
              let colors = record["colors"] as? [String],
              let brand = record["brand"] as? String,
              let patternStr = record["pattern"] as? String,
              let pattern = Pattern(rawValue: patternStr) else {
            return nil
        }

        let id = UUID(uuidString: record.recordID.recordName) ?? UUID()

        var imagePath = record["imagePath"] as? String ?? ""
        var croppedImagePath = record["croppedImagePath"] as? String

        if !imagePath.isEmpty && WardrobeImageFileHelper.loadImage(at: imagePath) == nil {
            if let asset = record["imageAsset"] as? CKAsset,
               let fileURL = asset.fileURL,
               let data = try? Data(contentsOf: fileURL),
               let image = UIImage(data: data),
               let savedPath = WardrobeImageFileHelper.saveImage(image) {
                imagePath = savedPath
            }
        }

        if let croppedPath = croppedImagePath,
           WardrobeImageFileHelper.loadImage(at: croppedPath) == nil {
            if let asset = record["croppedImageAsset"] as? CKAsset,
               let fileURL = asset.fileURL,
               let data = try? Data(contentsOf: fileURL),
               let image = UIImage(data: data),
               let savedPath = WardrobeImageFileHelper.saveImage(image) {
                croppedImagePath = savedPath
            }
        }

        // Thumbnails aren't uploaded (they're derived). After a restore the stored
        // thumbnailPath points at a file that doesn't exist here, so regenerate it
        // from the now-local cropped/full image; otherwise the grid shows blanks.
        var thumbnailPath = record["thumbnailPath"] as? String
        if thumbnailPath == nil || WardrobeImageFileHelper.loadImage(at: thumbnailPath!) == nil {
            if let source = WardrobeImageFileHelper.loadImage(at: croppedImagePath ?? imagePath) {
                thumbnailPath = WardrobeImageFileHelper.saveThumbnail(source)
            } else {
                thumbnailPath = nil
            }
        }
        let material = record["material"] as? String
        let fitStr = record["fit"] as? String
        let necklineStr = record["neckline"] as? String
        let sleeveLengthStr = record["sleeveLength"] as? String
        let garmentLengthStr = record["garmentLength"] as? String
        let details = record["details"] as? String

        return WardrobeItem(
            id: id,
            category: category,
            product: product,
            colors: colors,
            brand: brand,
            pattern: pattern,
            imagePath: imagePath,
            croppedImagePath: croppedImagePath,
            thumbnailPath: thumbnailPath,
            material: material,
            fit: fitStr != nil ? Fit(rawValue: fitStr!) : nil,
            neckline: necklineStr != nil ? Neckline(rawValue: necklineStr!) : nil,
            sleeveLength: sleeveLengthStr != nil ? SleeveLength(rawValue: sleeveLengthStr!) : nil,
            garmentLength: garmentLengthStr != nil ? GarmentLength(rawValue: garmentLengthStr!) : nil,
            details: details
        )
    }
}
