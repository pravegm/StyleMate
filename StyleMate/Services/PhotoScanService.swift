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

                guard let thumbnail = thumbnail, let thumbCG = thumbnail.cgImage else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                // Stage 1: Quick person detection on thumbnail (catches full-body, partial body, faces)
                let hasPerson = await Task.detached {
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
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                // Stage 3: Face matching on full-res image where faces are large enough
                guard let fullCG = fullImage.cgImage else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                let matchResult = await Task.detached {
                    FaceMatchingService.shared.findUserInPhoto(fullCG)
                }.value

                guard matchResult.isMatch else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                // Stage 4: Crop to user's body in multi-person photos
                let imageForGemini: UIImage
                if matchResult.faceCount > 1 {
                    let cropped: UIImage? = autoreleasepool {
                        if let croppedBody = FaceMatchingService.shared.cropToUserBody(from: fullCG, matchResult: matchResult) {
                            return UIImage(cgImage: croppedBody)
                        }
                        return nil
                    }

                    if let cropped {
                        imageForGemini = cropped
                        print("[StyleMate] Auto-scan: Multi-person photo (\(matchResult.faceCount) people) - cropped to user")
                    } else {
                        imageForGemini = fullImage
                        print("[StyleMate] Auto-scan: Multi-person photo - crop failed, using full image")
                    }
                } else {
                    imageForGemini = fullImage
                }

                let results = await ImageAnalysisService.shared.analyzeAndSegment(
                    image: imageForGemini,
                    userGender: userGender
                )

                for seg in results {
                    guard let cat = seg.category, let prod = seg.product,
                          let pat = seg.pattern, !seg.colors.isEmpty else { continue }

                    let isDup = DuplicateDetector.shared.findBestMatch(
                        category: cat, product: prod, colors: seg.colors,
                        pattern: pat, material: seg.material, fit: seg.fit,
                        neckline: seg.neckline, sleeveLength: seg.sleeveLength,
                        existingItems: wardrobeViewModel.items
                    )

                    if isDup != nil {
                        print("[StyleMate] Auto-scan: Skipping duplicate \(prod)")
                        continue
                    }

                    let garmentImage = seg.maskImage ?? imageForGemini

                    // Disk I/O inside autoreleasepool to release intermediate Data/UIImage refs
                    let (imagePath, thumbnailPath) = autoreleasepool {
                        let ip = WardrobeImageFileHelper.saveImageAsPNG(garmentImage)
                            ?? WardrobeImageFileHelper.saveImage(garmentImage) ?? ""
                        let tp = WardrobeImageFileHelper.saveThumbnail(garmentImage)
                        return (ip, tp)
                    }

                    let wardrobeItem = WardrobeItem(
                        category: cat,
                        product: prod,
                        colors: seg.colors.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                        brand: seg.brand,
                        pattern: pat,
                        imagePath: imagePath,
                        croppedImagePath: imagePath,
                        thumbnailPath: thumbnailPath,
                        material: seg.material,
                        fit: seg.fit,
                        neckline: seg.neckline,
                        sleeveLength: seg.sleeveLength,
                        garmentLength: seg.garmentLength,
                        details: seg.details
                    )

                    wardrobeViewModel.items.append(wardrobeItem)
                    wardrobeViewModel.syncItemToCloud(wardrobeItem)

                    scanAddedItemIDs.append(wardrobeItem.id)
                    itemsFound = scanAddedItemIDs.count

                    let distanceStr = matchResult.distance.map { String(format: " [dist: %.1f]", $0) } ?? ""
                    print("[StyleMate] Auto-scan: Added \(prod) (\(cat.rawValue)) to wardrobe\(distanceStr)")
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
            options.isNetworkAccessAllowed = false
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

    /// Uses requestImageDataAndOrientation which is guaranteed to call its handler exactly once.
    private func loadFullImage(for asset: PHAsset, maxDimension: CGFloat = 1024) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                let result: UIImage? = autoreleasepool {
                    guard let data, let fullImage = UIImage(data: data) else { return nil }
                    // Always render through UIGraphicsImageRenderer to bake EXIF
                    // orientation into pixels. Without this, .cgImage returns the
                    // raw rotated bitmap and Vision face coordinates are wrong.
                    let targetSize: CGSize
                    let scale = min(maxDimension / max(fullImage.size.width, fullImage.size.height), 1.0)
                    if scale < 1.0 {
                        targetSize = CGSize(width: fullImage.size.width * scale,
                                            height: fullImage.size.height * scale)
                    } else {
                        targetSize = fullImage.size
                    }
                    let renderer = UIGraphicsImageRenderer(size: targetSize)
                    return renderer.image { _ in
                        fullImage.draw(in: CGRect(origin: .zero, size: targetSize))
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Orientation Normalization

    /// Renders any UIImage into a new bitmap with .up orientation,
    /// baking EXIF rotation/mirroring into the actual pixel data so
    /// that .cgImage returns correctly-oriented pixels for Vision.
    private nonisolated static func bakeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, image.cgImage != nil else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
