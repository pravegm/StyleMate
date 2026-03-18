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

    // MARK: - Progress Persistence

    func loadProgress(forUser userId: String) -> ScanProgress {
        let key = "scanProgress_\(userId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let progress = try? JSONDecoder().decode(ScanProgress.self, from: data) else {
            return ScanProgress(scannedAssetIDs: [], totalItemsFound: 0)
        }
        return progress
    }

    private func saveProgress(_ progress: ScanProgress, forUser userId: String) {
        let key = "scanProgress_\(userId)"
        if let data = try? JSONEncoder().encode(progress) {
            UserDefaults.standard.set(data, forKey: key)
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

        var progress = loadProgress(forUser: userId)

        print("[StyleMate] Auto-scan starting for user: \(userId)")

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

            let thumbnails = await loadImages(for: batch, targetSize: CGSize(width: 640, height: 640))

            for (asset, thumbnail) in zip(batch, thumbnails) {
                guard !isCancelled else { return }

                guard let thumbnail = thumbnail else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                guard photoContainsPerson(thumbnail) else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    internalScannedCount += 1
                    throttleUIUpdate(scanned: internalScannedCount, total: unscannedAssets.count)
                    continue
                }

                guard !isCancelled else { return }

                if let fullImage = await loadSingleImage(for: asset, targetSize: CGSize(width: 1024, height: 1024)) {
                    let results = await ImageAnalysisService.shared.analyzeAndSegment(
                        image: fullImage,
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

                        let garmentImage = seg.maskImage ?? fullImage

                        let imagePath = WardrobeImageFileHelper.saveImageAsPNG(garmentImage)
                            ?? WardrobeImageFileHelper.saveImage(garmentImage) ?? ""
                        let thumbnailPath = WardrobeImageFileHelper.saveThumbnail(garmentImage)

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

                        print("[StyleMate] Auto-scan: Added \(prod) (\(cat.rawValue)) to wardrobe")
                    }
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
        saveProgress(progress, forUser: userId)

        scanState = .completed
        currentPhase = "Scan complete!"
        print("[StyleMate] Auto-scan complete: added \(scanAddedItemIDs.count) items from \(photosScanned) photos")
    }

    /// Throttle @Published updates to ~100ms intervals to avoid SwiftUI layout thrashing.
    private func throttleUIUpdate(scanned: Int, total: Int) {
        let now = ContinuousClock.now
        let isLast = scanned >= total
        if isLast || now - lastUIUpdate >= .milliseconds(100) {
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
        scanAddedItemIDs = []
        itemsFound = 0
        photosScanned = 0
        totalPhotosToScan = 0
        currentPhase = ""
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

    private nonisolated func photoContainsPerson(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observations = request.results as? [VNHumanObservation] else { return false }
        return observations.contains { $0.confidence > 0.5 }
    }

    private func loadImages(for assets: [PHAsset], targetSize: CGSize) async -> [UIImage?] {
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
                        var resumed = false
                        manager.requestImage(
                            for: asset, targetSize: targetSize,
                            contentMode: .aspectFit, options: options
                        ) { image, info in
                            let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                            if isDegraded { return }
                            guard !resumed else { return }
                            resumed = true
                            continuation.resume(returning: (index, image))
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
    private func loadSingleImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                guard let data, let fullImage = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                let maxDim = max(targetSize.width, targetSize.height)
                let scale = min(maxDim / max(fullImage.size.width, fullImage.size.height), 1.0)
                if scale < 1.0 {
                    let newSize = CGSize(width: fullImage.size.width * scale, height: fullImage.size.height * scale)
                    let renderer = UIGraphicsImageRenderer(size: newSize)
                    let resized = renderer.image { _ in fullImage.draw(in: CGRect(origin: .zero, size: newSize)) }
                    continuation.resume(returning: resized)
                } else {
                    continuation.resume(returning: fullImage)
                }
            }
        }
    }
}
