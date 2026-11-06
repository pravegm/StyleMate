#if DEBUG
import Foundation
import Photos

/// DEBUG-only UI-test hook (never compiled into Release): `-uiTestStallSomePhotos`.
///
/// Simulator photos are always on the "phone", so CI can't see what a real library still syncing
/// with iCloud does to the scan: a PhotoKit request that is allowed to download waits behind the
/// library's own sync and may never call back ("8 of 3,935 photos" on the founder's Duo, build 112).
/// With this flag, photos whose original file name says so behave like that (the CI library,
/// `scripts/ui_test_library.swift`, names them):
///
/// - `…_stallthumb…`: no copy on the phone. Local-only requests (network off) come back empty at
///   once, as PhotoKit does for an iCloud-only photo; requests that may download (the scan's
///   thumbnail fallback and its full photo) never call back.
/// - `…_stallfull…`: the preview is on the phone but the original is only in iCloud and its
///   download never finishes: full-photo requests never call back.
///
/// Only `PhotoScanService` consults it. Every stalled request must be ended by the scan's own
/// time limits; `RealFirstRunE2ETests` checks the scan gets past them and still adds items.
enum ScanFaultInjection {
    static let argument = "-uiTestStallSomePhotos"

    enum Request {
        /// Network off: answered from what's on the phone.
        case local
        /// Network on: a thumbnail Photos may have to download.
        case downloadThumbnail
        /// Network on: the full photo.
        case fullPhoto
    }

    enum Outcome {
        /// Behave normally.
        case normal
        /// Come back at once with no image (nothing on the phone).
        case empty
        /// Never call back.
        case stall
    }

    static let isActive = ProcessInfo.processInfo.arguments.contains(argument)

    static func outcome(for asset: PHAsset, _ request: Request) -> Outcome {
        guard isActive else { return .normal }
        switch (marker(for: asset), request) {
        case (.plain, _): return .normal
        case (.thumbnail, .local): return .empty
        case (.thumbnail, _): return .stall
        case (.full, .fullPhoto): return .stall
        case (.full, _): return .normal
        }
    }

    private enum Marker { case plain, thumbnail, full }

    private static let lock = NSLock()
    private static var markers: [String: Marker] = [:]

    private static func marker(for asset: PHAsset) -> Marker {
        let id = asset.localIdentifier
        lock.lock()
        if let known = markers[id] { lock.unlock(); return known }
        lock.unlock()
        let names = PHAssetResource.assetResources(for: asset).map { $0.originalFilename.lowercased() }
        let marker: Marker
        if names.contains(where: { $0.contains("_stallthumb") }) { marker = .thumbnail }
        else if names.contains(where: { $0.contains("_stallfull") }) { marker = .full }
        else { marker = .plain }
        lock.lock(); markers[id] = marker; lock.unlock()
        if marker != .plain { print("[UITest] stall hook: \(names.first ?? id) -> \(marker)") }
        return marker
    }
}
#endif
