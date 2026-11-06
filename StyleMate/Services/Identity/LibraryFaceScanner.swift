import UIKit
import Photos

/// One face found in the library during "Find yourself".
struct ScannedFace {
    let assetId: String
    /// L2-normalized face embedding (from the ~960 px thumbnail).
    let embedding: [Float]
    /// 0…1 (size, detector score, pose); see `FaceQuality.libraryScore`.
    let quality: Float
    /// Face box, normalized 0…1, top-left origin, in the photo's frame.
    let box: CGRect
    /// Small JPEG of the padded face crop for the review grid (kept compressed: a library pass
    /// can find a thousand faces).
    let thumbnailJPEG: Data
    /// Best similarity to the selfie anchors; -1 without a selfie.
    let anchorSimilarity: Float
    let fromSelfieAlbum: Bool
}

/// Face detection + embedding for one image, through the same detector + embedder as the scan.
/// Call on IdentityWorker.
enum FaceSampleExtractor {
    static let maxFacesPerPhoto = 6
    /// Crop side relative to the face box when a photo has several faces.
    static let cropFactor: CGFloat = 2.4

    static func scannedFaces(in image: UIImage, assetId: String, anchors: [[Float]],
                             fromSelfieAlbum: Bool) -> [ScannedFace] {
        guard let cg = LibraryFaceScanner.uprightCGImage(image) else { return [] }
        return faces(in: cg).compactMap { (f: Extracted) -> ScannedFace? in
            guard let jpeg = jpegThumbnail(f.displayCrop) else { return nil }
            return ScannedFace(assetId: assetId, embedding: f.embedding, quality: f.quality, box: f.box,
                               thumbnailJPEG: jpeg,
                               anchorSimilarity: anchors.isEmpty ? -1 : FaceMath.maxSimilarity(f.embedding, to: anchors),
                               fromSelfieAlbum: fromSelfieAlbum)
        }
    }

    struct Extracted {
        let box: CGRect
        let quality: Float
        let embedding: [Float]
        let displayCrop: CGImage
    }

    /// Every usable face in the image. Detected once (no padded retry: library photos rarely
    /// have a face filling the frame, and most have no face at all) and each face embedded
    /// from its own keypoints in the full image, so we get all of them, not just the one that
    /// best matches the gallery, without a second detector pass per face.
    static func faces(in image: CGImage) -> [Extracted] {
        let detected = FaceDetector.shared.detect(in: image, padRetry: false)   // library photo: no padded retry
        guard !detected.isEmpty else { return [] }
        let size = CGSize(width: image.width, height: image.height)
        let usable = detected
            .filter {
                FaceQuality.isUsableLibraryFace(shortSidePixels: Float(min($0.boxPixels.width, $0.boxPixels.height)),
                                                detectorScore: $0.score, keypoints: $0.keypoints)
            }
            .sorted { $0.boxPixels.width * $0.boxPixels.height > $1.boxPixels.width * $1.boxPixels.height }
            .prefix(maxFacesPerPhoto)

        var out: [Extracted] = []
        for r in FaceMatchingService.shared.embed(faces: Array(usable), in: image) {
            let face = r.face
            // Overlapping detections of one face: keep one copy.
            if out.contains(where: { FaceMath.dot($0.embedding, r.embedding) > FaceModelProfile.active.sameFaceInPhoto }) { continue }
            let shortSide = Float(min(face.boxPixels.width, face.boxPixels.height))
            out.append(Extracted(
                box: normalizedBox(face.boxPixels, in: size),
                quality: FaceQuality.libraryScore(shortSidePixels: shortSide, detectorScore: face.score,
                                                  keypoints: face.keypoints),
                embedding: r.embedding,
                displayCrop: r.displayCrop))
        }
        return out
    }

    /// Re-embeds a face found on the thumbnail from a ~1600 px copy of the same photo, which
    /// is the resolution the background scan matches at. Returns nil if the face there doesn't
    /// agree with the thumbnail's (then the thumbnail embedding is kept).
    static func refinedEmbedding(in image: UIImage, box: CGRect, expected: [Float]) -> [Float]? {
        guard let cg = LibraryFaceScanner.uprightCGImage(image) else { return nil }
        let size = CGSize(width: cg.width, height: cg.height)
        let px = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                        width: box.width * size.width, height: box.height * size.height)
        let rect = paddedSquare(around: px, imageSize: size, factor: cropFactor)
        // The crop holds the face at ~40% of its side: no padded retry needed. Of the faces in
        // it (a neighbour may be partly in), take the one that agrees with the thumbnail's.
        guard let crop = cg.cropping(to: rect),
              let r = FaceMatchingService.shared.embedFaces(in: crop, padRetry: false)
                .max(by: { FaceMath.dot($0.embedding, expected) < FaceMath.dot($1.embedding, expected) })
        else { return nil }
        return FaceMath.dot(r.embedding, expected) >= FaceModelProfile.active.refineAgreement ? r.embedding : nil
    }

    /// A square of `factor` × the face's longer side, centred on it, clamped to the image.
    static func paddedSquare(around box: CGRect, imageSize: CGSize, factor: CGFloat) -> CGRect {
        let side = max(box.width, box.height) * factor
        let r = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side).integral
        return r.intersection(CGRect(origin: .zero, size: imageSize))
    }

    static func normalizedBox(_ box: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: box.minX / size.width, y: box.minY / size.height,
                      width: box.width / size.width, height: box.height / size.height)
    }

    static func jpegThumbnail(_ cg: CGImage, maxSide: CGFloat = 200) -> Data? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.8)
    }
}

/// PhotoKit side of "Find yourself": which photos to look at and how to load them.
enum LibraryFaceScanner {
    static let defaultLimit = 1500
    /// 960 (was 640): a distant face in a group / full-body shot gets 1.5x the pixels to embed.
    /// On LFW faces of ~24 px at 640 (~36 px at 960) this raised SFace's TAR at FAR 1e-5 a lot
    /// (docs/MODEL-LICENSING.md §8.2). The detector still makes one 640 pass (no tiles below
    /// 1100 px); the PhotoKit cache window shrinks to keep the cached bytes about the same.
    static let thumbnailSide: CGFloat = 960
    /// Photos PhotoKit decodes ahead of the pass, sized to ~40 thumbnails at 640 px.
    static var cacheWindow: Int { max(12, Int((40 * 640 * 640 / (thumbnailSide * thumbnailSide)).rounded())) }
    static let refineSide: CGFloat = 1600
    /// Older Selfies-album photos added on top of the recent window, for age / look variety.
    static let extraSelfies = 150

    /// Most recent photos (no screenshots), plus older selfies, and which of them are in the
    /// Selfies album.
    static func fetchCandidateAssets(limit: Int = defaultLimit) -> (assets: [PHAsset], selfieIds: Set<String>) {
        var selfieIds = Set<String>()
        var selfieAssets: [PHAsset] = []
        let albums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumSelfPortraits, options: nil)
        albums.enumerateObjects { collection, _, _ in
            let opts = PHFetchOptions()
            opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            opts.fetchLimit = 600
            PHAsset.fetchAssets(in: collection, options: opts).enumerateObjects { asset, _, _ in
                if selfieIds.insert(asset.localIdentifier).inserted { selfieAssets.append(asset) }
            }
        }

        // Screenshots are skipped here, not in a fetch predicate: PhotoKit evaluated
        // "(mediaSubtypes & screenshot) == 0" as true for almost nothing (RealFirstRunE2ETests: 1 of 267
        // photos, so "Find yourself" never saw the user and said "We couldn't spot you yet"). The fetch
        // result is lazy, so walking it newest first and stopping at the limit stays cheap.
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let recentLimit = max(0, limit - min(extraSelfies, selfieAssets.count))
        var assets: [PHAsset] = []
        var seen = Set<String>()
        var screenshots = 0
        PHAsset.fetchAssets(with: .image, options: opts).enumerateObjects { asset, _, stop in
            guard assets.count < recentLimit else { stop.pointee = true; return }
            guard !asset.mediaSubtypes.contains(.photoScreenshot) else { screenshots += 1; return }
            if seen.insert(asset.localIdentifier).inserted { assets.append(asset) }
        }
        dlog("[FindYou] \(assets.count) recent photos (\(screenshots) screenshots skipped), \(selfieAssets.count) in Selfies")
        for asset in selfieAssets where assets.count < limit {
            if seen.insert(asset.localIdentifier).inserted { assets.append(asset) }
        }
        return (assets, selfieIds)
    }

    static func requestOptions(network: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        options.isSynchronous = false
        options.version = .current
        return options
    }

    /// Loads one image, giving up after `timeout` (an iCloud download can stall when offline).
    static func loadImage(_ asset: PHAsset, manager: PHImageManager, side: CGFloat,
                          network: Bool, timeout: TimeInterval) async -> UIImage? {
        let options = requestOptions(network: network)
        let once = ResumeOnce()
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            let id = manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                          contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if once.claim() { cont.resume(returning: image) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() {
                    manager.cancelImageRequest(id)
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Re-embeds one face at the scan's resolution (see `FaceSampleExtractor.refinedEmbedding`).
    static func refinedEmbedding(assetId: String, box: CGRect, expected: [Float],
                                 manager: PHImageManager) async -> [Float]? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject,
              let image = await loadImage(asset, manager: manager, side: refineSide, network: true, timeout: 6)
        else { return nil }
        return await IdentityWorker.shared.run {
            FaceSampleExtractor.refinedEmbedding(in: image, box: box, expected: expected)
        }
    }

    /// The image's pixels with EXIF orientation baked in. `.cgImage` alone drops orientation,
    /// which would feed rotated faces to the detector.
    static func uprightCGImage(_ image: UIImage?) -> CGImage? {
        guard let image else { return nil }
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: fmt).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }

    /// Opens the system picker to share more photos when access is Limited.
    @MainActor
    static func presentLimitedLibraryPicker(completion: @escaping () -> Void) {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
        guard var top = root else { completion(); return }
        while let presented = top.presentedViewController { top = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top) { _ in
            DispatchQueue.main.async { completion() }
        }
    }
}

/// Makes a continuation resume exactly once when two callbacks race (result vs timeout).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
