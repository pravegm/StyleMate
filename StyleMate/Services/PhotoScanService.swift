import UIKit
import Photos
import Vision

// MARK: - Scanned Item (pre-approval, held in memory until user reviews)

struct ScannedItem: Identifiable {
    let id: UUID = UUID()
    let image: UIImage
    let category: Category
    let product: String
    let colors: [String]
    let brand: String
    let pattern: Pattern
    let material: String?
    let fit: Fit?
    let neckline: Neckline?
    let sleeveLength: SleeveLength?
    let garmentLength: GarmentLength?
    let details: String?
    let sourceAssetID: String
    var isSelected: Bool = true
}

// MARK: - Scan Date Range

enum ScanDateRange {
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
    @Published var foundItems: [ScannedItem] = []

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

    // MARK: - Progress Persistence

    private func loadProgress(forUser userId: String) -> ScanProgress {
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

    // MARK: - Main Scan

    func startScan(
        forUser userId: String,
        dateRange: ScanDateRange,
        userGender: String?,
        existingItems: [WardrobeItem]
    ) async {
        guard scanState != .scanning else {
            print("[StyleMate] Scan already in progress, ignoring")
            return
        }

        scanState = .scanning
        photosScanned = 0
        itemsFound = 0
        foundItems = []

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

        for batchStart in stride(from: 0, to: unscannedAssets.count, by: batchSize) {
            guard scanState == .scanning else { return }

            let batchEnd = min(batchStart + batchSize, unscannedAssets.count)
            let batch = Array(unscannedAssets[batchStart..<batchEnd])

            let thumbnails = await loadImages(for: batch, targetSize: CGSize(width: 640, height: 640))

            for (asset, thumbnail) in zip(batch, thumbnails) {
                guard scanState == .scanning else { return }

                guard let thumbnail = thumbnail else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    photosScanned += 1
                    continue
                }

                guard photoContainsPerson(thumbnail) else {
                    progress.scannedAssetIDs.insert(asset.localIdentifier)
                    photosScanned += 1
                    continue
                }

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
                            existingItems: existingItems
                        )

                        if isDup != nil {
                            print("[StyleMate] Auto-scan: Skipping duplicate \(prod)")
                            continue
                        }

                        let dupInScan = DuplicateDetector.shared.findBestMatch(
                            category: cat, product: prod, colors: seg.colors,
                            pattern: pat, material: seg.material, fit: seg.fit,
                            neckline: seg.neckline, sleeveLength: seg.sleeveLength,
                            existingItems: foundItems.map { scannedItemToWardrobeStub($0) }
                        )

                        if dupInScan != nil {
                            print("[StyleMate] Auto-scan: Skipping scan-internal duplicate \(prod)")
                            continue
                        }

                        let garmentImage = seg.maskImage ?? fullImage

                        let scannedItem = ScannedItem(
                            image: garmentImage,
                            category: cat,
                            product: prod,
                            colors: seg.colors,
                            brand: seg.brand,
                            pattern: pat,
                            material: seg.material,
                            fit: seg.fit,
                            neckline: seg.neckline,
                            sleeveLength: seg.sleeveLength,
                            garmentLength: seg.garmentLength,
                            details: seg.details,
                            sourceAssetID: asset.localIdentifier
                        )

                        foundItems.append(scannedItem)
                        itemsFound = foundItems.count
                        print("[StyleMate] Auto-scan: Found \(prod) (\(cat.rawValue))")
                    }
                }

                progress.scannedAssetIDs.insert(asset.localIdentifier)
                photosScanned += 1
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

        progress.lastScanDate = Date()
        progress.totalItemsFound = foundItems.count
        saveProgress(progress, forUser: userId)

        scanState = .completed
        currentPhase = "Scan complete!"
        print("[StyleMate] Auto-scan complete: found \(foundItems.count) items from \(photosScanned) photos")
    }

    // MARK: - Cancel / Dismiss

    func cancelScan() {
        scanState = .idle
        currentPhase = ""
        print("[StyleMate] Auto-scan cancelled")
    }

    func dismissCompleted() {
        scanState = .idle
        foundItems = []
        itemsFound = 0
        photosScanned = 0
        totalPhotosToScan = 0
        currentPhase = ""
    }

    // MARK: - Stub Conversion for Duplicate Checking

    private func scannedItemToWardrobeStub(_ item: ScannedItem) -> WardrobeItem {
        WardrobeItem(
            category: item.category, product: item.product,
            colors: item.colors, brand: item.brand, pattern: item.pattern,
            imagePath: "", croppedImagePath: nil, thumbnailPath: nil,
            material: item.material, fit: item.fit, neckline: item.neckline,
            sleeveLength: item.sleeveLength, garmentLength: item.garmentLength,
            details: item.details
        )
    }

    // MARK: - Photo Library Helpers

    private nonisolated func fetchPhotoAssets(in dateRange: ScanDateRange) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let now = Date()
        switch dateRange {
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
                        manager.requestImage(
                            for: asset, targetSize: targetSize,
                            contentMode: .aspectFit, options: options
                        ) { image, _ in
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

    private func loadSingleImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset, targetSize: targetSize,
                contentMode: .aspectFit, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
