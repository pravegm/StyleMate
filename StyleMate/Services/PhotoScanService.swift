import UIKit
import Photos
import Vision

// MARK: - Scan Date Range

enum ScanDateRange {
    case lastMonth
    case lastSixMonths
    case lastYear
    case custom(from: Date, to: Date)
    case all
}

// MARK: - Scan Progress Persistence

struct ScanProgress: Codable {
    var scannedAssetIDs: Set<String>
    var lastScanDate: Date?
    var scanStartDate: Date?
    var scanEndDate: Date?
    var totalItemsFound: Int
    var lastScanAddedItemIDs: [String] = []
    /// Photos that are probably the user but not certain enough to add silently.
    /// Optional so progress files written before this field still decode.
    var pendingReviews: [PendingFaceReview]?
}

/// One "Is this you?" question queued by the scan.
struct PendingFaceReview: Codable, Identifiable, Hashable {
    var id: String { assetId }
    let assetId: String
    let similarity: Float
    let embedding: [Float]
    /// Normalized face box, Vision convention (bottom-left origin): x, y, w, h.
    let faceBox: [CGFloat]
    let faceCount: Int

    var faceRect: CGRect {
        guard faceBox.count == 4 else { return .zero }
        return CGRect(x: faceBox[0], y: faceBox[1], width: faceBox[2], height: faceBox[3])
    }
}

// MARK: - Scan History Info

struct ScanHistoryInfo {
    let lastScanDate: Date?
    let totalScannedAssets: Int
    let totalItemsFound: Int
}

// MARK: - Photo Scan Service

@MainActor
class PhotoScanService: ObservableObject {
    static let shared = PhotoScanService()

    // MARK: - Published State

    @Published var scanState: ScanState = .idle
    @Published var totalPhotosToScan: Int = 0
    @Published var photosScanned: Int = 0
    @Published var itemsFound: Int = 0
    @Published var currentPhase: String = ""
    @Published var scanAddedItemIDs: [UUID] = []
    /// User-controlled pause. The scan loop parks (without ending) while true.
    @Published var isPaused: Bool = false

    private var lastUIUpdate = ContinuousClock.now
    private var lastScanContext: ScanContext?

    private struct ScanContext {
        let userId: String
        let dateRange: ScanDateRange
        let userGender: String?
    }

    enum ScanState: Equatable {
        case idle
        case scanning
        case completed
        case error(String)

        static func == (lhs: ScanState, rhs: ScanState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.scanning, .scanning), (.completed, .completed): return true
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    private init() {}

    private var isCancelled: Bool {
        scanState != .scanning || Task.isCancelled
    }

    // MARK: - Pause / Resume

    func pauseScan() {
        guard scanState == .scanning, !isPaused else { return }
        isPaused = true
        currentPhase = "Scan paused"
        print("[StyleMate] Auto-scan paused")
    }

    func resumeScan() {
        guard isPaused else { return }
        isPaused = false
        currentPhase = "Scanning your photos..."
        print("[StyleMate] Auto-scan resumed")
    }

    func togglePause() { isPaused ? resumeScan() : pauseScan() }

    /// Parks the loop while paused (without exiting). Returns false if the scan was
    /// cancelled while paused, so the caller can bail out.
    private func awaitWhilePaused() async -> Bool {
        while isPaused && !isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)   // 0.2s
        }
        return !isCancelled
    }

    // MARK: - Progress Persistence (JSON file in Application Support)

    private static func progressFileURL(forUser userId: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var dir = appSupport.appendingPathComponent("ScanProgress", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)

        return dir.appendingPathComponent("scanProgress_\(userId).json")
    }

    func loadProgress(forUser userId: String) -> ScanProgress {
        let fileURL = Self.progressFileURL(forUser: userId)

        // Migrate from UserDefaults if file doesn't exist yet
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let legacyKey = "scanProgress_\(userId)"
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let progress = try? JSONDecoder().decode(ScanProgress.self, from: data) {
                saveProgress(progress, forUser: userId)
                UserDefaults.standard.removeObject(forKey: legacyKey)
                return progress
            }
        }

        guard let data = try? Data(contentsOf: fileURL),
              let progress = try? JSONDecoder().decode(ScanProgress.self, from: data) else {
            return ScanProgress(scannedAssetIDs: [], totalItemsFound: 0)
        }
        return progress
    }

    private func saveProgress(_ progress: ScanProgress, forUser userId: String) {
        let fileURL = Self.progressFileURL(forUser: userId)
        if let data = try? JSONEncoder().encode(progress) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Scan History

    func getScanHistory(forUser userId: String) -> ScanHistoryInfo {
        let progress = loadProgress(forUser: userId)
        return ScanHistoryInfo(
            lastScanDate: progress.lastScanDate,
            totalScannedAssets: progress.scannedAssetIDs.count,
            totalItemsFound: progress.totalItemsFound
        )
    }

    // MARK: - Main Scan

    func startScan(
        forUser userId: String,
        dateRange: ScanDateRange,
        userGender: String?,
        wardrobeViewModel: WardrobeViewModel
    ) async {
        guard scanState != .scanning else {
            print("[StyleMate] Scan already in progress, ignoring")
            return
        }

        scanState = .scanning
        isPaused = false
        photosScanned = 0
        itemsFound = 0
        scanAddedItemIDs = []
        lastScanContext = ScanContext(userId: userId, dateRange: dateRange, userGender: userGender)

        var progress = loadProgress(forUser: userId)

        print("[StyleMate] Auto-scan starting for user: \(userId)")

        currentPhase = "Loading face reference..."
        let hasFaceRef = FaceMatchingService.shared.loadSelfieReference(forUser: userId)
        if hasFaceRef {
            print("[StyleMate] Auto-scan: Face matching active (selfie loaded)")
        } else {
            print("[StyleMate] Auto-scan: No selfie reference loaded -- scan requires a selfie for accurate results")
            scanState = .error("No selfie found. Please take a selfie in Profile to enable scanning.")
            return
        }

        currentPhase = "Preparing your photo library..."
        let allAssets = fetchPhotoAssets(in: dateRange)
        let unscannedAssets = allAssets.filter { !progress.scannedAssetIDs.contains($0.localIdentifier) }
        totalPhotosToScan = unscannedAssets.count
        print("[StyleMate] Auto-scan: \(unscannedAssets.count) unscanned of \(allAssets.count) total")

        if unscannedAssets.isEmpty {
            scanState = .completed
            currentPhase = "No new photos to scan"
            return
        }

        currentPhase = "Scanning your photos..."
        let batchSize = 10
        var internalScannedCount = 0

        for batchStart in stride(from: 0, to: unscannedAssets.count, by: batchSize) {
            guard !isCancelled else { return }

            let batchEnd = min(batchStart + batchSize, unscannedAssets.count)
            let batch = Array(unscannedAssets[batchStart..<batchEnd])

            let thumbnails = await loadThumbnails(for: batch, targetSize: CGSize(width: 640, height: 640))

            for (asset, thumbnail) in zip(batch, thumbnails) {
                guard !isCancelled else { return }
                if isPaused { guard await awaitWhilePaused() else { return } }

                guard let thumbnail = thumbnail, let thumbCG = thumbnail.cgImage else {
                    // Not marked as scanned, so a later scan retries it.
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                // Stage 1: Quick person detection on thumbnail (catches full-body, partial body, faces)
                // .utility priority so the background scan's heavy Vision/CoreML work
                // yields CPU to the UI — otherwise the app stutters while scanning.
                let hasPerson = await Task.detached(priority: .utility) {
                    FaceMatchingService.shared.photoContainsAnyPerson(thumbCG)
                }.value

                guard hasPerson else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                guard !isCancelled else { return }

                // Stage 2: Load full-res image for face matching + Gemini analysis
                guard let fullImage = await loadFullImage(for: asset) else {
                    // Not marked as scanned: it's usually an iCloud download that
                    // failed or timed out (offline), so the next scan retries it.
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                // Stage 3+4: STRICT identity gate — only proceed when we're
                // confidently sure this is the user (and can isolate them in a
                // multi-person photo). Anything uncertain is skipped: a background
                // scan must never silently catalog a stranger's clothes.
                guard let fullCG = fullImage.cgImage else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                let identity: ScanIdentity = await Task.detached(priority: .utility) {
                    autoreleasepool {
                        FaceMatchingService.shared.resolveIdentityForScan(in: fullCG, fullImage: fullImage, userId: userId)
                    }
                }.value

                switch identity {
                case .skip:
                    break
                case let .review(sim, embedding, faceBox, faceCount):
                    var pending = progress.pendingReviews ?? []
                    if !pending.contains(where: { $0.assetId == asset.localIdentifier }) {
                        pending.append(PendingFaceReview(
                            assetId: asset.localIdentifier, similarity: sim, embedding: embedding,
                            faceBox: [faceBox.origin.x, faceBox.origin.y, faceBox.width, faceBox.height],
                            faceCount: faceCount))
                        progress.pendingReviews = pending
                        pendingReviewCount = pending.count
                    }
                case .analyze(let imageToAnalyze):
                    await extractAndAdd(from: imageToAnalyze, userGender: userGender,
                                        wardrobeViewModel: wardrobeViewModel)
                }

                progress.scannedAssetIDs.insert(asset.localIdentifier)
                internalScannedCount += 1
                throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
            }

            saveProgress(progress, forUser: userId)

            let thermal = ProcessInfo.processInfo.thermalState
            if thermal == .serious {
                print("[StyleMate] Auto-scan: Thermal serious, adding delay")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } else if thermal == .critical {
                print("[StyleMate] Auto-scan: Thermal critical, pausing")
                scanState = .error("Paused due to device temperature")
                return
            }
        }

        photosScanned = internalScannedCount

        progress.lastScanDate = Date()
        progress.totalItemsFound += scanAddedItemIDs.count
        progress.lastScanAddedItemIDs = scanAddedItemIDs.map { $0.uuidString }
        saveProgress(progress, forUser: userId)

        scanState = .completed
        currentPhase = "Scan complete!"
        print("[StyleMate] Auto-scan complete: added \(scanAddedItemIDs.count) items from \(photosScanned) photos")
    }

    // MARK: - Extraction

    /// Runs the on-device garment extractor on an image of the user and adds every
    /// new item to the wardrobe (duplicates of items already there are skipped).
    @discardableResult
    func extractAndAdd(from image: UIImage, userGender: String?,
                       wardrobeViewModel: WardrobeViewModel) async -> Int {
        let results = await ImageAnalysisService.shared.analyzeAndSegment(image: image, userGender: userGender)
        var added = 0
        for seg in results {
            guard let cat = seg.category, let prod = seg.product,
                  let pat = seg.pattern, !seg.colors.isEmpty else { continue }

            let isDup = DuplicateDetector.shared.findBestMatch(
                category: cat, product: prod, colors: seg.colors,
                pattern: pat, material: seg.material, fit: seg.fit,
                neckline: seg.neckline, sleeveLength: seg.sleeveLength,
                brand: seg.brand,
                existingItems: wardrobeViewModel.items,
                featurePrint: seg.featurePrint
            )
            if let dup = isDup {
                upgradeImageIfBetter(dup.existingItem, with: seg, wardrobeViewModel: wardrobeViewModel)
                continue
            }

            guard let garmentImage = seg.maskImage else { continue }
            // Disk I/O inside autoreleasepool to release intermediate Data/UIImage refs
            let (imagePath, thumbnailPath) = autoreleasepool {
                let ip = WardrobeImageFileHelper.saveImageAsPNG(garmentImage)
                    ?? WardrobeImageFileHelper.saveImage(garmentImage) ?? ""
                let tp = WardrobeImageFileHelper.saveThumbnail(garmentImage)
                return (ip, tp)
            }

            // Apple Intelligence devices: on-device details + visible brand.
            let notes = await GarmentDescriber.describe(garmentImage, product: prod, colors: seg.colors)
            let wardrobeItem = WardrobeItem(
                category: cat,
                product: prod,
                colors: seg.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                brand: notes?.brand ?? seg.brand,
                pattern: pat,
                imagePath: imagePath,
                croppedImagePath: imagePath,
                thumbnailPath: thumbnailPath,
                material: seg.material,
                fit: seg.fit,
                neckline: seg.neckline,
                sleeveLength: seg.sleeveLength,
                garmentLength: seg.garmentLength,
                details: (notes?.details).flatMap { $0.isEmpty ? nil : $0 } ?? seg.details
            )

            if let fp = seg.featurePrint {
                ItemEmbeddingStore.shared.set(fp, quality: seg.quality, for: wardrobeItem.id)
            }
            wardrobeViewModel.items.append(wardrobeItem)
            wardrobeViewModel.syncItemToCloud(wardrobeItem)
            scanAddedItemIDs.append(wardrobeItem.id)
            itemsFound = scanAddedItemIDs.count
            added += 1
            print("[StyleMate] Auto-scan: Added \(prod) (\(cat.rawValue)) to wardrobe")
        }
        return added
    }

    /// The same garment shows up in many photos. Keep the best view of it: when
    /// this photo's cutout is clearly better (bigger, sharper, less occluded, not
    /// cut off) than the one in the wardrobe, swap the image — the item, its
    /// metadata and any edits the user made stay as they are.
    private func upgradeImageIfBetter(_ existing: WardrobeItem, with seg: ImageAnalysisService.SegmentedItem,
                                      wardrobeViewModel: WardrobeViewModel) {
        guard let cutout = seg.maskImage, let fp = seg.featurePrint else { return }
        let store = ItemEmbeddingStore.shared
        // Items from before the on-device pipeline have no score: any new cutout wins.
        let current = store.quality(for: existing.id) ?? 0
        guard seg.quality > current + 0.08,
              let idx = wardrobeViewModel.items.firstIndex(where: { $0.id == existing.id }) else { return }
        let ip = WardrobeImageFileHelper.saveImageAsPNG(cutout) ?? ""
        guard !ip.isEmpty else { return }
        let tp = WardrobeImageFileHelper.saveThumbnail(cutout)
        WardrobeImageFileHelper.deleteImage(at: existing.imagePath)
        if existing.croppedImagePath != existing.imagePath { WardrobeImageFileHelper.deleteImage(at: existing.croppedImagePath) }
        WardrobeImageFileHelper.deleteImage(at: existing.thumbnailPath)
        let updated = existing.withImages(imagePath: ip, croppedImagePath: ip, thumbnailPath: tp)
        wardrobeViewModel.items[idx] = updated
        wardrobeViewModel.syncItemToCloud(updated)
        store.set(fp, quality: seg.quality, for: existing.id)
        print("[StyleMate] Auto-scan: better photo of \(existing.product) (q \(String(format: "%.2f→%.2f", current, seg.quality)))")
    }

    // MARK: - "Is this you?" review queue

    @Published var pendingReviewCount: Int = 0

    func pendingReviews(forUser userId: String) -> [PendingFaceReview] {
        let list = loadProgress(forUser: userId).pendingReviews ?? []
        pendingReviewCount = list.count
        return list.sorted { $0.similarity > $1.similarity }
    }

    /// Applies the user's answers. Confirmed photos teach the face gallery and are
    /// extracted; rejected ones are dropped. Returns how many items were added.
    func resolveReviews(confirmed: [PendingFaceReview], rejected: [PendingFaceReview],
                        forUser userId: String, userGender: String?,
                        wardrobeViewModel: WardrobeViewModel) async -> Int {
        var progress = loadProgress(forUser: userId)
        let answered = Set((confirmed + rejected).map(\.assetId))
        progress.pendingReviews = (progress.pendingReviews ?? []).filter { !answered.contains($0.assetId) }
        saveProgress(progress, forUser: userId)
        pendingReviewCount = progress.pendingReviews?.count ?? 0

        scanAddedItemIDs = []
        var added = 0
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: confirmed.map(\.assetId), options: nil)
        var byId: [String: PHAsset] = [:]
        assets.enumerateObjects { a, _, _ in byId[a.localIdentifier] = a }

        for review in confirmed {
            guard let asset = byId[review.assetId],
                  let full = await loadFullImage(for: asset), let cg = full.cgImage else { continue }
            let image: UIImage? = await Task.detached(priority: .userInitiated) {
                FaceMatchingService.shared.imageForConfirmedReview(
                    cgImage: cg, fullImage: full, faceBox: review.faceRect,
                    embedding: review.embedding, faceCount: review.faceCount, userId: userId)
            }.value
            guard let image else { continue }
            added += await extractAndAdd(from: image, userGender: userGender, wardrobeViewModel: wardrobeViewModel)
        }

        progress = loadProgress(forUser: userId)
        progress.totalItemsFound += added
        progress.lastScanAddedItemIDs = scanAddedItemIDs.map { $0.uuidString }
        saveProgress(progress, forUser: userId)
        return added
    }

    /// Loads the face crop shown in the review grid.
    func reviewThumbnail(for review: PendingFaceReview) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [review.assetId], options: nil).firstObject,
              let full = await loadFullImage(for: asset, maxDimension: 1200), let cg = full.cgImage else { return nil }
        return FaceMatchingService.shared.reviewFaceCrop(from: cg, faceBox: review.faceRect)
    }

    /// Throttle @Published updates to ~150ms intervals to avoid SwiftUI layout thrashing.
    private func throttleUIUpdate(scanned: Int, total: Int) {
        let now = ContinuousClock.now
        let isLast = scanned >= total
        if isLast || now - lastUIUpdate >= .milliseconds(150) {
            photosScanned = scanned
            lastUIUpdate = now
        }
    }

    // MARK: - Cancel / Dismiss

    func cancelScan() {
        scanState = .idle
        isPaused = false
        currentPhase = ""
        print("[StyleMate] Auto-scan cancelled")
    }

    func dismissCompleted() {
        scanState = .idle
        itemsFound = 0
        photosScanned = 0
        totalPhotosToScan = 0
        currentPhase = ""
    }

    func retryScan(wardrobeViewModel: WardrobeViewModel) async {
        guard let context = lastScanContext else { return }
        await startScan(
            forUser: context.userId,
            dateRange: context.dateRange,
            userGender: context.userGender,
            wardrobeViewModel: wardrobeViewModel
        )
    }

    // MARK: - Persisted Scan Item IDs

    func loadLastScanItemIDs(forUser userId: String) -> [UUID] {
        let progress = loadProgress(forUser: userId)
        return progress.lastScanAddedItemIDs.compactMap { UUID(uuidString: $0) }
    }

    func removeFromLastScanIDs(_ itemId: UUID, forUser userId: String) {
        var progress = loadProgress(forUser: userId)
        progress.lastScanAddedItemIDs.removeAll { $0 == itemId.uuidString }
        saveProgress(progress, forUser: userId)
    }

    func clearLastScanIDs(forUser userId: String) {
        var progress = loadProgress(forUser: userId)
        progress.lastScanAddedItemIDs = []
        saveProgress(progress, forUser: userId)
    }

    /// Resets all scan progress so the next scan re-processes every photo.
    func resetProgress(forUser userId: String) {
        let fresh = ScanProgress(scannedAssetIDs: [], totalItemsFound: 0)
        saveProgress(fresh, forUser: userId)
        print("[StyleMate] Scan progress reset for user \(userId)")
    }

    // MARK: - Photo Count Estimation

    nonisolated func estimatePhotoCount(for dateRange: ScanDateRange) -> Int {
        fetchPhotoAssets(in: dateRange).count
    }

    // MARK: - Photo Library Helpers

    private nonisolated func fetchPhotoAssets(in dateRange: ScanDateRange) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let now = Date()
        switch dateRange {
        case .lastMonth:
            let start = Calendar.current.date(byAdding: .month, value: -1, to: now)!
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        case .lastSixMonths:
            let start = Calendar.current.date(byAdding: .month, value: -6, to: now)!
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        case .lastYear:
            let start = Calendar.current.date(byAdding: .year, value: -1, to: now)!
            options.predicate = NSPredicate(format: "creationDate >= %@", start as NSDate)
        case .custom(let from, let to):
            options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@", from as NSDate, to as NSDate)
        case .all:
            break
        }

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    private func loadThumbnails(for assets: [PHAsset], targetSize: CGSize) async -> [UIImage?] {
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            let manager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            // iCloud-only photos still have a small local preview, but allow the
            // network so a missing one is fetched instead of the photo being lost.
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            for (index, asset) in assets.enumerated() {
                group.addTask { @Sendable in
                    await withCheckedContinuation { continuation in
                        let lock = NSLock()
                        var resumed = false
                        manager.requestImage(
                            for: asset, targetSize: targetSize,
                            contentMode: .aspectFit, options: options
                        ) { image, _ in
                            lock.lock()
                            guard !resumed else { lock.unlock(); return }
                            resumed = true
                            lock.unlock()
                            let normalized = image.flatMap { Self.bakeOrientation($0) }
                            continuation.resume(returning: (index, normalized))
                        }
                    }
                }
            }

            var results = [UIImage?](repeating: nil, count: assets.count)
            for await (index, image) in group {
                results[index] = image
            }
            return results
        }
    }

    /// Loads the photo at up to 2048px with EXIF orientation baked into the pixels.
    /// 2048 (not 1024): face recognition + person isolation need faces large enough
    /// to embed reliably. At 1024 the faces in multi-person photos are too small and
    /// the wrong person can outscore the user.
    ///
    /// Network access is ON: with iCloud Photos' "Optimize iPhone Storage" (the
    /// default for most people) the full-size original of almost every photo
    /// older than a few weeks lives only in iCloud. With network access off, every
    /// one of those came back nil and was silently skipped — the main reason the
    /// scan "couldn't find me" in a real library. A timeout keeps one slow
    /// download from stalling the whole scan.
    private func loadFullImage(for asset: PHAsset, maxDimension: CGFloat = 2048) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.version = .current
        options.isSynchronous = false

        let longSide = CGFloat(max(asset.pixelWidth, asset.pixelHeight))
        let scale = longSide > 0 ? min(maxDimension / longSide, 1.0) : 1.0
        let target = longSide > 0
            ? CGSize(width: (CGFloat(asset.pixelWidth) * scale).rounded(),
                     height: (CGFloat(asset.pixelHeight) * scale).rounded())
            : CGSize(width: maxDimension, height: maxDimension)

        let manager = PHImageManager.default()
        let gate = ResumeGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let requestID = manager.requestImage(for: asset, targetSize: target,
                                                 contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                let baked: UIImage? = autoreleasepool { image.map { Self.bakeOrientation($0, pixelScale: true) } }
                if gate.claim() { continuation.resume(returning: baked) }
            }
            Task {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if gate.claim() {
                    manager.cancelImageRequest(requestID)
                    print("[StyleMate] Auto-scan: full image timed out (iCloud download?) for \(asset.localIdentifier)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Resumes a continuation exactly once across a completion handler and a timeout.
    private final class ResumeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    // MARK: - Orientation Normalization

    /// Renders any UIImage into a new bitmap with .up orientation,
    /// baking EXIF rotation/mirroring into the actual pixel data so
    /// that .cgImage returns correctly-oriented pixels for Vision.
    /// `pixelScale`: render at scale 1 so the output's point size IS its pixel size
    /// (otherwise the renderer uses the screen's 3x scale and the image balloons,
    /// and faces embed differently from the gallery faces).
    private nonisolated static func bakeOrientation(_ image: UIImage, pixelScale: Bool = false) -> UIImage {
        guard image.imageOrientation != .up || (pixelScale && image.scale != 1),
              image.cgImage != nil else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        if pixelScale { format.scale = 1 }
        let size = pixelScale
            ? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            : image.size
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
