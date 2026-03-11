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

        if let imageURL = imageFileURL(for: item.imagePath) {
            record["imageAsset"] = CKAsset(fileURL: imageURL)
        }
        if let croppedPath = item.croppedImagePath,
           let croppedURL = imageFileURL(for: croppedPath) {
            record["croppedImageAsset"] = CKAsset(fileURL: croppedURL)
        }

        do {
            _ = try await privateDB.save(record)
            return true
        } catch let error as CKError where error.code == .serverRecordChanged {
            return true
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
    }

    // MARK: - Fetch All Items

    func fetchAll(userID: String) async -> [WardrobeItem] {
        syncStatus = .syncing
        var allItems: [WardrobeItem] = []

        let predicate = NSPredicate(format: "userID == %@", userID)
        let query = CKQuery(recordType: recordType, predicate: predicate)

        do {
            let (matchResults, _) = try await privateDB.records(matching: query, inZoneWith: zoneID, resultsLimit: CKQueryOperation.maximumResults)

            for (_, result) in matchResults {
                switch result {
                case .success(let record):
                    if let item = wardrobeItem(from: record) {
                        allItems.append(item)
                    }
                case .failure(let error):
                    print("[CloudKit] Record fetch error: \(error.localizedDescription)")
                }
            }

            syncStatus = .success
            lastSyncDate = Date()
            UserDefaults.standard.set(lastSyncDate, forKey: "lastCloudKitSync")
        } catch {
            print("[CloudKit] Fetch error: \(error.localizedDescription)")
            syncStatus = .error("Could not fetch from iCloud")
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

        return WardrobeItem(
            id: id,
            category: category,
            product: product,
            colors: colors,
            brand: brand,
            pattern: pattern,
            imagePath: imagePath,
            croppedImagePath: croppedImagePath
        )
    }
}
