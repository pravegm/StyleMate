import UIKit
import Photos

/// One candidate face surfaced from the user's library for the "tap which photos
/// are you" reference builder.
struct FaceCandidate: Identifiable {
    let id = UUID()
    let assetId: String
    let thumbnail: UIImage
    let embedding: [Float]
    let similarity: Float
    var isSelected: Bool
}

/// Drives the reference-gallery builder: scans the user's Selfies + Portrait
/// photos on-device, ranks the detected faces by similarity to the current
/// reference (the onboarding selfie anchor), and lets the user confirm which
/// ones are them. Confirmed faces' embeddings are appended to the gallery.
@MainActor
final class FaceReferenceViewModel: ObservableObject {

    enum Phase {
        case idle, noPermission, scanning, ready, empty
    }

    @Published var phase: Phase = .idle
    @Published var candidates: [FaceCandidate] = []
    @Published var progress: Double = 0
    @Published var addedCount: Int = 0

    private let candidateLimit = 120
    /// A library face must match the selfie anchor at least this much to even be
    /// offered as "you". With the R50 model a different person scores ~0.00, so
    /// this floor (well above that) keeps other people out while still surfacing
    /// your own face across varied poses/lighting (which score 0.30+).
    static let referenceFloor: Float = 0.24

    var selectedCount: Int { candidates.filter { $0.isSelected }.count }
    var hasAnchorRanking: Bool { candidates.contains { $0.similarity > 0 } }

    // MARK: - Scan

    func scan(forUser userId: String) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard newStatus == .authorized || newStatus == .limited else {
                print("[FaceRef] Photo permission denied")
                phase = .noPermission; return
            }
        } else if status != .authorized && status != .limited {
            print("[FaceRef] Photo permission not granted (status=\(status.rawValue))")
            phase = .noPermission; return
        }

        phase = .scanning
        progress = 0
        candidates = []

        // Ensure the selfie anchor is loaded so similarity ranking has a reference.
        let hasAnchor = FaceMatchingService.shared.loadReference(forUser: userId)
        print("[FaceRef] Scanning library (Selfies + Portraits); anchor loaded=\(hasAnchor), gallery=\(FaceMatchingService.shared.referenceCount)")

        let assets = Self.fetchCandidateAssets(limit: candidateLimit)
        print("[FaceRef] Found \(assets.count) candidate photos")
        guard !assets.isEmpty else {
            print("[FaceRef] No Selfies/Portrait photos found -> empty state")
            phase = .empty; return
        }

        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        var results: [FaceCandidate] = []
        for (index, asset) in assets.enumerated() {
            let image = await loadImage(asset, manager: manager, options: options,
                                        targetSize: CGSize(width: 600, height: 600))
            progress = Double(index + 1) / Double(assets.count)

            guard let cg = image?.cgImage else { continue }

            // Face detect + embed off the main thread (CoreML is CPU-heavy).
            let eval: (UIImage, [Float], Float)? = await Task.detached(priority: .userInitiated) {
                guard let r = FaceMatchingService.shared.evaluateFaceForReference(in: cg) else { return nil }
                return (UIImage(cgImage: r.displayCrop), r.embedding, r.similarity)
            }.value

            if let eval {
                results.append(FaceCandidate(assetId: asset.localIdentifier,
                                             thumbnail: eval.0, embedding: eval.1,
                                             similarity: eval.2, isSelected: false))
            }
        }

        guard !results.isEmpty else {
            print("[FaceRef] No usable faces detected in \(assets.count) candidates -> empty state")
            phase = .empty; return
        }

        // With a selfie anchor, KEEP ONLY faces that plausibly are the user. A
        // different person (e.g. a partner — even more so a different gender)
        // scores far below this floor, so this stops the gallery being polluted
        // with someone else's face. The selfie just taken is the ground truth.
        if hasAnchor {
            let before = results.count
            results = results.filter { $0.similarity >= Self.referenceFloor }
            print("[FaceRef] Kept \(results.count)/\(before) faces matching your selfie (>= \(Self.referenceFloor))")
            guard !results.isEmpty else {
                print("[FaceRef] No library faces matched your selfie strongly enough -> empty")
                phase = .empty; return
            }
        }

        // Rank best-first, then drop near-identical faces (burst shots / very
        // similar selfies) so the grid shows distinct photos and the gallery
        // isn't stuffed with redundant copies of the same face.
        results.sort { $0.similarity > $1.similarity }
        var deduped: [FaceCandidate] = []
        for cand in results {
            let isNearDup = deduped.contains { Self.cosine($0.embedding, cand.embedding) > 0.90 }
            if !isNearDup { deduped.append(cand) }
        }
        let removed = results.count - deduped.count
        results = deduped

        // Everything shown passed the match floor, so pre-select it all.
        for i in results.indices { results[i].isSelected = hasAnchor }
        candidates = results
        phase = .ready
        let top = results.first?.similarity ?? 0
        let bottom = results.last?.similarity ?? 0
        print("[FaceRef] Ready: \(results.count) distinct faces (\(removed) near-dupes removed), sim [\(String(format: "%.3f", bottom))..\(String(format: "%.3f", top))], pre-selected \(selectedCount)\(hasAnchor ? "" : " (no selfie anchor)")")
    }

    /// Cosine similarity of two L2-normalized embeddings (a dot product).
    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for i in 0..<a.count { sum += a[i] * b[i] }
        return sum
    }

    // MARK: - Selection

    func toggle(_ id: UUID) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].isSelected.toggle()
    }

    // MARK: - Confirm

    @discardableResult
    func confirm(forUser userId: String) -> Int {
        let embeddings = candidates.filter { $0.isSelected }.map { $0.embedding }
        guard !embeddings.isEmpty else {
            print("[FaceRef] Confirm tapped with 0 selected")
            return 0
        }
        let added = FaceMatchingService.shared.addReferenceEmbeddings(embeddings, forUser: userId)
        addedCount = added
        print("[FaceRef] Confirmed \(embeddings.count) faces; \(added) new added; gallery now \(FaceMatchingService.shared.referenceCount)")
        return added
    }

    // MARK: - Library Fetch

    /// Candidate photos likely to contain the user, best-prior first: Selfies
    /// album, then Portrait-mode photos, then recent general library photos. The
    /// general-library fill is what surfaces the user across varied poses (not
    /// just front-facing selfies); the selfie-match floor filters out everyone else.
    private nonisolated static func fetchCandidateAssets(limit: Int) -> [PHAsset] {
        var assets: [PHAsset] = []
        var seen = Set<String>()

        func collect(_ result: PHFetchResult<PHAsset>) {
            result.enumerateObjects { asset, _, stop in
                if !seen.contains(asset.localIdentifier) {
                    seen.insert(asset.localIdentifier)
                    assets.append(asset)
                }
                if assets.count >= limit { stop.pointee = true }
            }
        }

        // 1. Selfies album.
        let selfieAlbums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
        selfieAlbums.enumerateObjects { collection, _, _ in
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            collect(PHAsset.fetchAssets(in: collection, options: opts))
        }

        // 2. Portrait-mode photos.
        if assets.count < limit {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0",
                                         PHAssetMediaSubtype.photoDepthEffect.rawValue)
            collect(PHAsset.fetchAssets(with: .image, options: opts))
        }

        // 3. Recent general-library photos. Selfies/Portraits alone are too narrow
        //    (a user with few selfies sees almost nothing), so fill the rest of the
        //    budget with recent photos. The selfie-match floor downstream keeps only
        //    the ones that are actually the user, across varied poses.
        if assets.count < limit {
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = limit * 6   // over-fetch; most won't contain the user
            collect(PHAsset.fetchAssets(with: .image, options: opts))
        }

        return Array(assets.prefix(limit))
    }

    private func loadImage(_ asset: PHAsset, manager: PHImageManager,
                           options: PHImageRequestOptions, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            manager.requestImage(for: asset, targetSize: targetSize,
                                 contentMode: .aspectFit, options: options) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }
                lock.lock(); defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
