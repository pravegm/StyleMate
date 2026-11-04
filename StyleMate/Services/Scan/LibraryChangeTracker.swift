import Foundation
import Photos

/// Finds photos added to the library since the last check, using PhotoKit's
/// persistent change history (survives relaunches). This catches photos whose
/// creation date is old — AirDrops, imports, saved shares — which a purely
/// date-based "newer than the last scan" check would miss.
enum LibraryChangeTracker {
    /// The library's current change token, archived for `ScanProgress`.
    static func currentToken() -> Data? {
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    /// Local identifiers of assets inserted since `tokenData`, or nil when there
    /// is no usable token (first run, or the history expired) — callers then
    /// rely on the date-based coverage scan alone.
    static func insertedAssetIDs(since tokenData: Data?) -> Set<String>? {
        guard let tokenData,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self,
                                                                  from: tokenData) else { return nil }
        do {
            let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
            var ids = Set<String>()
            for change in changes {
                if let details = try? change.changeDetails(for: .asset) {
                    ids.formUnion(details.insertedLocalIdentifiers)
                }
            }
            return ids
        } catch {
            print("[StyleMate] Library change history unavailable: \(error.localizedDescription)")
            return nil
        }
    }
}
