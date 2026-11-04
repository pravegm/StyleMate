import Foundation
import CoreData

/// The Core Data stack for the outfit calendar (`DatedOutfit` + `OutfitItem`).
///
/// Loading never crashes the app (it used to `fatalError`, so a full disk or a damaged
/// store meant a crash on every launch):
/// - a store that can't be opened because it is damaged or from an incompatible model is
///   moved aside to `Application Support/CoreDataBackups/` (kept, not deleted) and a fresh
///   store is created;
/// - any other failure (e.g. disk full, file locked/protected) leaves the file untouched and
///   runs this session on an in-memory store, so the history is back on the next launch.
struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentContainer
    /// True when this session runs on a throwaway in-memory store (see above).
    let isTemporaryStore: Bool
    /// True when a damaged store was moved aside at launch.
    let didResetStore: Bool

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "StyleMateDataModel")
        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
            _ = Self.load(container)
            isTemporaryStore = true
            didResetStore = false
            Self.configure(container)
            return
        }
        if let description = container.persistentStoreDescriptions.first {
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject,
                                  forKey: NSPersistentStoreFileProtectionKey)
        }

        var temporary = false
        var reset = false
        if let error = Self.load(container) {
            dlog("[CoreData] Store failed to load: \(error.domain) \(error.code)")
            if Self.isUnrecoverable(error), let url = container.persistentStoreDescriptions.first?.url {
                Self.moveStoreAside(at: url)
                reset = true
                if let again = Self.load(container) {
                    dlog("[CoreData] Fresh store failed too (\(again.code)); using memory for this session")
                    Self.useInMemoryStore(container)
                    temporary = true
                }
            } else {
                Self.useInMemoryStore(container)
                temporary = true
            }
        }
        isTemporaryStore = temporary
        didResetStore = reset
        Self.configure(container)
    }

    private static func configure(_ container: NSPersistentContainer) {
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Loads the container's stores synchronously; returns the first error, if any.
    private static func load(_ container: NSPersistentContainer) -> NSError? {
        var failure: NSError?
        container.loadPersistentStores { _, error in
            if let error = error as NSError?, failure == nil { failure = error }
        }
        return failure
    }

    private static func useInMemoryStore(_ container: NSPersistentContainer) {
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        _ = load(container)
    }

    /// Damaged or incompatible stores — the only cases where moving the file aside helps.
    static func isUnrecoverable(_ error: NSError) -> Bool {
        let incompatible: Set<Int> = [
            NSPersistentStoreIncompatibleVersionHashError, NSPersistentStoreIncompatibleSchemaError,
            NSMigrationError, NSMigrationMissingSourceModelError, NSMigrationMissingMappingModelError,
            NSMigrationManagerSourceStoreError, NSMigrationManagerDestinationStoreError,
            NSEntityMigrationPolicyError, NSInferredMappingModelError, NSFileReadCorruptFileError
        ]
        if error.domain == NSCocoaErrorDomain, incompatible.contains(error.code) { return true }
        // SQLITE_CORRUPT (11) / SQLITE_NOTADB (26), reported directly or as the underlying error.
        let sqliteCodes: Set<Int> = [11, 26]
        if error.domain == NSSQLiteErrorDomain, sqliteCodes.contains(error.code) { return true }
        if let code = error.userInfo[NSSQLiteErrorDomain] as? Int, sqliteCodes.contains(code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== error {
            return isUnrecoverable(underlying)
        }
        return false
    }

    /// Moves the SQLite store and its -wal / -shm siblings into a dated backup folder.
    private static func moveStoreAside(at storeURL: URL) {
        let fm = FileManager.default
        let backups = LocalStore.directory("CoreDataBackups")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = backups.appendingPathComponent("\(stamp)-\(src.lastPathComponent)")
            if (try? fm.moveItem(at: src, to: dst)) == nil {
                try? fm.removeItem(at: src)   // couldn't move: it must still go, or the reload fails again
            }
        }
        dlog("[CoreData] Damaged store moved to CoreDataBackups")
    }
}
