import UIKit

/// Runs identity work (SCRFD + AdaFace through `FaceMatchingService`) one job at a time, off the
/// main thread. The face service keeps its gallery in plain arrays, so the onboarding flow never
/// lets two of its own jobs touch it at once.
actor IdentityWorker {
    static let shared = IdentityWorker()

    func run<T>(_ work: @Sendable () -> T) -> T {
        autoreleasepool { work() }
    }
}

/// The selfie step rebuilds the identity in the background so its "Use these" tap stays instant.
/// The "Find yourself" step waits on it before ranking against the new selfie.
@MainActor
enum IdentityBuild {
    private static var pending: Task<Void, Never>?

    static func start(_ work: @escaping @Sendable () -> Void) {
        let previous = pending
        pending = Task.detached(priority: .userInitiated) {
            await previous?.value
            await IdentityWorker.shared.run(work)
        }
    }

    static func waitUntilIdle() async {
        await pending?.value
    }
}

/// Persistence for the selfie reference frames.
///
/// Contract with `FaceMatchingService.selfieAnchors`: the front frame lives at the path stored
/// under `selfieReferencePath_<userId>` (Documents/selfie_reference_<userId>.jpg); the service
/// bootstraps its upright + mirror anchors from it. The two head-turn frames are extra: they're
/// stored under `selfieTurnFrames_<userId>` (file names in Documents) and added to the gallery
/// through `addReferenceEmbeddings`, in both orientations like the front frame.
enum SelfieReferenceStore {
    static func primaryKey(_ userId: String) -> String { "selfieReferencePath_\(userId)" }
    static func turnFramesKey(_ userId: String) -> String { "selfieTurnFrames_\(userId)" }

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    /// Writes the front frame exactly where FaceMatchingService reads it.
    @discardableResult
    static func savePrimary(_ image: UIImage, userId: String) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return false }
        let url = documents.appendingPathComponent("selfie_reference_\(userId).jpg")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Identity] Could not save selfie: \(error)")
            return false
        }
        UserDefaults.standard.set(url.path, forKey: primaryKey(userId))
        print("[Identity] Selfie saved for \(userId)")
        return true
    }

    /// Replaces the head-turn frames.
    static func saveTurnFrames(_ images: [UIImage], userId: String) {
        removeTurnFrames(userId: userId)
        var names: [String] = []
        for (i, image) in images.enumerated() {
            guard let data = image.jpegData(compressionQuality: 0.92) else { continue }
            let name = "selfie_reference_\(userId)_turn\(i + 1).jpg"
            if (try? data.write(to: documents.appendingPathComponent(name), options: .atomic)) != nil {
                names.append(name)
            }
        }
        UserDefaults.standard.set(names, forKey: turnFramesKey(userId))
    }

    static func removeTurnFrames(userId: String) {
        for name in UserDefaults.standard.stringArray(forKey: turnFramesKey(userId)) ?? [] {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
        }
        UserDefaults.standard.removeObject(forKey: turnFramesKey(userId))
    }

    static func primaryFrame(userId: String) -> UIImage? {
        guard let path = UserDefaults.standard.string(forKey: primaryKey(userId)) else { return nil }
        if let img = UIImage(contentsOfFile: path) { return img }
        // The app container path changes across reinstalls; fall back to the file name.
        return UIImage(contentsOfFile: documents.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path)
    }

    static func turnFrames(userId: String) -> [UIImage] {
        (UserDefaults.standard.stringArray(forKey: turnFramesKey(userId)) ?? []).compactMap {
            UIImage(contentsOfFile: documents.appendingPathComponent($0).path)
        }
    }

    // MARK: Identity (call on IdentityWorker)

    /// Embeddings of a frame upright and mirrored. Front-camera frames are mirrored while most
    /// library photos aren't, and AdaFace isn't mirror-invariant, so both go in.
    static func embeddingsBothWays(_ image: UIImage) -> [[Float]] {
        guard let cg = LibraryFaceScanner.uprightCGImage(image) else { return [] }
        var out: [[Float]] = []
        if let e = FaceMatchingService.shared.evaluateFaceForReference(in: cg)?.embedding { out.append(e) }
        if let flipped = mirrored(cg), let e = FaceMatchingService.shared.evaluateFaceForReference(in: flipped)?.embedding {
            out.append(e)
        }
        return out
    }

    /// After a new selfie: drop the old gallery, bootstrap the anchors from the front frame,
    /// then add the turn frames. Returns the gallery size.
    @discardableResult
    static func rebuildIdentity(forUser userId: String) -> Int {
        FaceMatchingService.shared.clearReference(forUser: userId)
        guard FaceMatchingService.shared.loadReference(forUser: userId) else {
            print("[Identity] Rebuild: no usable face in the front selfie")
            return 0
        }
        let turns = turnFrames(userId: userId).flatMap { embeddingsBothWays($0) }
        let added = FaceMatchingService.shared.addReferenceEmbeddings(turns, forUser: userId)
        print("[Identity] Rebuilt identity: \(added) turn embeddings added, gallery \(FaceMatchingService.shared.referenceCount)")
        return FaceMatchingService.shared.referenceCount
    }

    /// Selfie anchors for ranking library faces (front + turns, both orientations). Also puts the
    /// turn frames back into the gallery when it was rebuilt from the front selfie alone (e.g.
    /// after a face-model version bump discarded the stored gallery).
    static func prepareAnchors(forUser userId: String) -> [[Float]] {
        let hasGallery = FaceMatchingService.shared.loadReference(forUser: userId)
        var anchors: [[Float]] = []
        if let front = primaryFrame(userId: userId) { anchors += embeddingsBothWays(front) }
        let turns = turnFrames(userId: userId).flatMap { embeddingsBothWays($0) }
        anchors += turns
        if hasGallery, !turns.isEmpty, FaceMatchingService.shared.referenceCount <= 2 {
            FaceMatchingService.shared.addReferenceEmbeddings(turns, forUser: userId)
        }
        print("[Identity] Anchors ready: \(anchors.count) (gallery \(FaceMatchingService.shared.referenceCount))")
        return anchors
    }

    static func mirrored(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

// MARK: - Frame check

struct SelfieFrameResult {
    let issue: SelfieIssue?
    let embedding: [Float]?
    let yaw: Float?
}

/// Measures a captured selfie frame with the same detector + embedder the scan uses, then lets
/// `SelfieFrameAssessor` decide. Call on IdentityWorker.
enum SelfieFrameChecker {
    static func check(_ image: UIImage, step: SelfieStep, frontEmbedding: [Float]?) -> SelfieFrameResult {
        guard let cg = LibraryFaceScanner.uprightCGImage(image) else {
            return SelfieFrameResult(issue: .noFace, embedding: nil, yaw: nil)
        }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        // Ignore tiny faces far behind the user (posters, passers-by).
        let faces = SCRFDDetector.shared.detect(in: cg).filter { $0.boxPixels.width >= W * 0.08 }
        guard let face = faces.max(by: { $0.boxPixels.width * $0.boxPixels.height < $1.boxPixels.width * $1.boxPixels.height }) else {
            return SelfieFrameResult(issue: .noFace, embedding: nil, yaw: nil)
        }
        var m = SelfieFrameMeasurements(
            faceCount: faces.count,
            detectorScore: face.score,
            faceWidthFraction: Float(face.boxPixels.width / W),
            faceCenter: CGPoint(x: face.boxPixels.midX / W, y: face.boxPixels.midY / H),
            faceLuma: ImageLuma.mean(in: face.boxPixels, of: cg) ?? 128,
            eyeLuma: nil, cheekLuma: nil,
            yaw: FaceQuality.yawProxy(face.keypoints),
            similarityToFront: nil)
        if let patches = FaceQuality.eyeAndCheekPatches(face.keypoints) {
            let eyes = patches.eyes.compactMap { ImageLuma.mean(in: $0, of: cg) }
            if !eyes.isEmpty { m.eyeLuma = eyes.reduce(0, +) / Float(eyes.count) }
            m.cheekLuma = ImageLuma.mean(in: patches.cheek, of: cg)
        }
        let embedding = faces.count == 1 ? FaceMatchingService.shared.evaluateFaceForReference(in: cg)?.embedding : nil
        if let f = frontEmbedding, let e = embedding { m.similarityToFront = FaceMath.dot(f, e) }
        var issue = SelfieFrameAssessor.issue(for: m, step: step)
        if issue == nil, embedding == nil { issue = .unclear }
        print("[Identity] Selfie frame \(step.label): faces=\(m.faceCount) w=\(String(format: "%.2f", m.faceWidthFraction)) det=\(String(format: "%.2f", m.detectorScore)) luma=\(Int(m.faceLuma)) yaw=\(String(format: "%.2f", m.yaw)) simFront=\(m.similarityToFront.map { String(format: "%.2f", $0) } ?? "-") -> \(issue.map { "\($0)" } ?? "ok")")
        return SelfieFrameResult(issue: issue, embedding: embedding, yaw: m.yaw)
    }
}
