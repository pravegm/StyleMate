import UIKit
import Vision
import CoreML
import Accelerate
import CoreImage

/// One detected person in a photo, shown in the "which one is you?" picker.
struct DetectedPerson: Identifiable {
    let id = UUID()
    let faceBox: CGRect      // normalized, bottom-left (Vision convention)
    let crop: UIImage
    let embedding: [Float]?
}

/// How a photo's "image to analyze" was resolved for identity.
enum IdentityResolution {
    case useWhole               // solo photo / product shot — analyze the whole image
    case isolated(UIImage)      // multi-person, confident match — isolated just the user
    case ambiguous([DetectedPerson])  // multi-person, unsure — ask the user
}

/// What the background scan should do with one photo.
enum ScanIdentity {
    case analyze(UIImage)       // confidently the user — extract (whole photo or isolated user)
    case review(sim: Float, embedding: [Float], faceBox: CGRect, faceCount: Int)  // probably the user — ask
    case skip                   // not the user / can't isolate
}

/// On-device face identity matching for the photo-library auto-scan.
///
/// Models (see `FaceModelProfile.active`, docs/MODEL-LICENSING.md): faces are detected and
/// 5-point-landmarked by **YuNet** (`YuNetDetector`, MIT), warped to the canonical ArcFace
/// 112x112 template, and embedded by **SFace** (Apache-2.0, 128-d, RGB raw 0…255 in; it
/// normalizes inside the graph) with flip test-time augmentation. Like every ArcFace-family
/// model, its embeddings are ONLY meaningful when the face is warped to that template, so the
/// landmarks must come from the detector, never from Apple Vision (Vision's landmarks collapsed
/// same-person similarity from 0.988 to ~0.2 in Nov 2026).
///
/// Identity is represented by a *gallery* of embeddings (the onboarding selfie frames plus any
/// library photos the user later confirms are them), persisted to disk. A candidate face's
/// score is its best cosine similarity against the gallery, turned into a confidence tier rather
/// than a single hard cutoff. Every bar comes from the profile, because similarity scales are
/// model-specific.
class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    // MARK: - Tunable Thresholds
    //
    // Cosine of L2-normalized embeddings of the active model (`FaceModelProfile.active`). The
    // values, and how they were calibrated (equal false-accept rate to the AdaFace bars they
    // replaced, measured on LFW), are documented on the profile and in docs/MODEL-LICENSING.md.
    // `var` so tests can probe edge cases; production never changes them.
    static var highConfidenceThreshold: Float = FaceModelProfile.active.highConfidence   // auto-add (solo photos)
    static var borderlineThreshold: Float = FaceModelProfile.active.borderline           // send to review
    // Multi-person photos need a higher bar: a borderline match plus an imperfect
    // person-instance mask can extract the wrong body (a partner standing next to the user).
    static var multiPersonThreshold: Float = FaceModelProfile.active.multiPerson
    // In a multi-person photo, the best match must beat the next-best face by at
    // least this much to auto-isolate silently. Otherwise two people score too
    // close to be sure, so we ask "which one is you?" instead of guessing.
    static var ambiguityMargin: Float = FaceModelProfile.active.ambiguityMargin

    // InsightFace canonical 5-point destination for 112x112 alignment.
    // Source: insightface/utils/face_align.py `arcface_dst`
    private static let arcfaceDst: [SIMD2<Float>] = [
        SIMD2<Float>(38.2946, 51.6963),   // left eye center
        SIMD2<Float>(73.5318, 51.5014),   // right eye center
        SIMD2<Float>(56.0252, 71.7366),   // nose tip
        SIMD2<Float>(41.5493, 92.3655),   // left mouth corner
        SIMD2<Float>(70.7299, 92.2041)    // right mouth corner
    ]

    // MARK: - State (thread-safe)
    //
    // The service is called concurrently from the scan (background tasks), manual add,
    // the reference builder and onboarding. All gallery state lives behind `stateLock`
    // (recursive: public methods call each other) and every reader works on a snapshot,
    // so a racing append can never be observed mid-mutation. Core ML access (lazy load +
    // prediction) is serialized by `modelLock`, so `clearReference` can't drop the model
    // under a running prediction. Long work (detection, embedding, Vision) never runs
    // while `stateLock` is held.

    private let stateLock = NSRecursiveLock()
    private let modelLock = NSLock()
    private var gallery: [GalleryEntry] = []
    private var loadedUserId: String?
    /// Bumped by `clearReference`; a gallery built from before a clear is discarded.
    private var stateGeneration = 0
    private var mlModel: MLModel?

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    /// Snapshot of the gallery embeddings (for matching).
    private var referenceEmbeddings: [[Float]] { withState { gallery.map(\.embedding) } }

    // MARK: - Match Result

    enum Confidence {
        case high        // confidently the user — safe to auto-add
        case borderline  // probably the user — surface for review
        case none        // not the user
    }

    struct MatchResult {
        let confidence: Confidence
        let matchedFaceBox: CGRect?    // normalized, bottom-left — for person isolation
        let faceCount: Int
        /// The matched face's gallery score: the mean of its `galleryConsensus` best gallery
        /// similarities (the single one while the gallery has fewer entries). Decides `.high`.
        let similarity: Float?
        /// Best score of any OTHER face in the photo (same measure). Used to detect the
        /// "two people score close together" case where the pick is uncertain.
        var runnerUpSimilarity: Float? = nil
        /// The matched face's embedding — used to grow the gallery from confident
        /// scan matches and from faces the user confirms in review.
        var matchedEmbedding: [Float]? = nil
        /// The matched face's single best gallery similarity. Decides `.borderline` (review).
        var bestSingleSimilarity: Float? = nil

        /// True when the photo should enter the pipeline at all (high or borderline).
        var isMatch: Bool { confidence == .high || confidence == .borderline }

        /// How far ahead the matched face is from the next-best face. Large = a
        /// confident, unambiguous pick; small = two similar-scoring people.
        var margin: Float {
            guard let best = similarity, let runner = runnerUpSimilarity else { return .greatestFiniteMagnitude }
            return best - runner
        }

        static let noFaces = MatchResult(confidence: .none, matchedFaceBox: nil, faceCount: 0, similarity: nil)
    }

    // MARK: - Model Loading

    /// Call with `modelLock` held.
    private func ensureModelLoadedLocked() -> MLModel? {
        if let mlModel { return mlModel }

        mlModel = FaceDetectorSupport.loadModel(Self.profile.embedderResource, tag: "FaceMatch")
        return mlModel
    }

    // MARK: - Reference Gallery (persisted)

    /// Where a gallery embedding came from. Selfie anchors and faces the user confirmed
    /// are never evicted; learned faces (added by the scan on its own) are capped and are
    /// the first to go.
    enum GallerySource: String, Codable {
        case selfie      // the onboarding selfie (upright + mirror)
        case confirmed   // the user said "this is me" (reference builder, review, picker)
        case learned     // the scan was very sure on its own
    }

    struct GalleryEntry: Codable, Equatable {
        var embedding: [Float]
        var source: GallerySource
        var addedAt: Date
    }

    /// v2 (Nov 2026): per-entry provenance. v1 was `{ embeddings: [[Float]], modelVersion }`
    /// with the two selfie anchors first; it is migrated on load (`migrateLegacyGallery`).
    private static let galleryFormatVersion = 2

    private struct StoredGallery: Codable {
        var formatVersion: Int?
        var modelVersion: String?
        var entries: [GalleryEntry]?
        var embeddings: [[Float]]?      // v1
    }

    /// The active face models (detector + embedder + every bar tuned to them).
    static let profile = FaceModelProfile.active

    /// Identifies which face models produced the persisted embeddings. Embeddings
    /// are model-specific (an SFace vector is meaningless against an AdaFace one), so
    /// a gallery tagged with a different version is discarded and rebuilt from the
    /// selfie when the models change. Was "adaface_ir101_upright" (SCRFD + AdaFace)
    /// until Nov 2026.
    static let modelVersion = profile.modelVersion

    private static func galleryURL(forUser userId: String) -> URL {
        LocalStore.directory("FaceReference").appendingPathComponent("faceReference_\(userId).json")
    }

    /// Call with `stateLock` held (writes are serialized with the mutations they persist).
    private func persistGalleryLocked(forUser userId: String) {
        let stored = StoredGallery(formatVersion: Self.galleryFormatVersion, modelVersion: Self.modelVersion,
                                   entries: gallery, embeddings: nil)
        if let data = try? JSONEncoder().encode(stored) {
            LocalStore.write(data, to: Self.galleryURL(forUser: userId))
            dlog("[FaceMatch] Persisted gallery (\(gallery.count) embeddings: \(Self.describe(gallery)))")
        }
    }

    private static func describe(_ entries: [GalleryEntry]) -> String {
        let s = entries.filter { $0.source == .selfie }.count
        let c = entries.filter { $0.source == .confirmed }.count
        let l = entries.filter { $0.source == .learned }.count
        return "\(s) selfie, \(c) confirmed, \(l) learned"
    }

    /// Loads the reference gallery for a user. If none is persisted yet, bootstraps
    /// it from the onboarding selfie. Returns true if at least one embedding is available.
    @discardableResult
    func loadReference(forUser userId: String) -> Bool {
        // A `clearReference` racing the build discards it (it may have read the old
        // selfie); one retry then builds from the current one.
        if loadReferenceAttempt(forUser: userId) { return true }
        return loadReferenceAttempt(forUser: userId)
    }

    private func loadReferenceAttempt(forUser userId: String) -> Bool {
        let generation: Int? = withState { () -> Int? in
            (loadedUserId == userId && !gallery.isEmpty) ? nil : stateGeneration
        }
        guard let generation else { return true }

        // 1. Persisted gallery.
        let url = Self.galleryURL(forUser: userId)
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredGallery.self, from: data) {
            if stored.modelVersion == Self.modelVersion {
                if let entries = stored.entries, !entries.isEmpty {
                    if commit(entries, forUser: userId, generation: generation, persist: false) {
                        dlog("[FaceMatch] Loaded gallery: \(entries.count) embeddings (\(Self.describe(entries)))")
                        return true
                    }
                    return withState { loadedUserId == userId && !gallery.isEmpty }
                }
                if let legacy = stored.embeddings, !legacy.isEmpty {
                    let migrated = migrateLegacyGallery(legacy, forUser: userId)
                    if !migrated.isEmpty, commit(migrated, forUser: userId, generation: generation, persist: true) {
                        dlog("[FaceMatch] Migrated v1 gallery (\(legacy.count)) -> v2 (\(Self.describe(migrated)))")
                        return true
                    }
                }
            } else {
                // Persisted with a different face model — those embeddings can't be
                // compared against the current model. Discard and rebuild from the selfie.
                dlog("[FaceMatch] Gallery model mismatch ('\(stored.modelVersion ?? "-")' != '\(Self.modelVersion)'); rebuilding from selfie")
                try? FileManager.default.removeItem(at: url)
            }
        }

        // 2. Bootstrap from the selfie image (both orientations; see selfieAnchors).
        guard let anchors = selfieAnchors(forUser: userId), !anchors.isEmpty else {
            dlog("[FaceMatch] ERROR: Could not build reference from selfie")
            return withState { loadedUserId == userId && !gallery.isEmpty }
        }
        let now = Date()
        let entries = anchors.map { GalleryEntry(embedding: $0, source: .selfie, addedAt: now) }
        if commit(entries, forUser: userId, generation: generation, persist: true) {
            dlog("[FaceMatch] Bootstrapped gallery with \(anchors.count) selfie anchors")
            return true
        }
        return withState { loadedUserId == userId && !gallery.isEmpty }
    }

    /// Installs a freshly built gallery unless another thread already loaded this user's
    /// gallery (which may already hold newer entries) or the reference was cleared since
    /// the build started. Returns true when `entries` became the gallery.
    private func commit(_ entries: [GalleryEntry], forUser userId: String, generation: Int, persist: Bool) -> Bool {
        withState {
            if loadedUserId == userId, !gallery.isEmpty { return false }
            guard stateGeneration == generation else { return false }
            gallery = entries
            loadedUserId = userId
            if persist { persistGalleryLocked(forUser: userId) }
            return true
        }
    }

    /// v1 galleries had no provenance: `[selfie, selfie-mirror, confirmed/learned...]`.
    /// The selfie anchors are rebuilt from the selfie (or, if it is gone, taken from the
    /// front of the list); every other entry is kept only if it plausibly is the user —
    /// similarity to the SELFIE anchors at least the review bar — and kept as `confirmed`.
    /// Entries a drifted v1 gallery learned from someone else score at impostor level
    /// against the selfie and are dropped.
    private func migrateLegacyGallery(_ embeddings: [[Float]], forUser userId: String) -> [GalleryEntry] {
        let now = Date()
        var anchors = selfieAnchors(forUser: userId) ?? []
        var rest: [[Float]] = embeddings
        if anchors.isEmpty {
            let k = min(Self.anchorCount, embeddings.count)
            anchors = Array(embeddings.prefix(k))
            rest = Array(embeddings.dropFirst(k))
        }
        var entries = anchors.map { GalleryEntry(embedding: $0, source: .selfie, addedAt: now) }
        var dropped = 0
        for (i, e) in rest.enumerated() {
            if anchors.contains(where: { dotProduct($0, e) > Self.profile.galleryDuplicate }) { continue }   // an old anchor
            let selfieSim = anchors.map { dotProduct($0, e) }.max() ?? -1
            guard selfieSim >= Self.borderlineThreshold else { dropped += 1; continue }
            // Keep their order: older entries get earlier timestamps.
            entries.append(GalleryEntry(embedding: e, source: .confirmed,
                                        addedAt: now.addingTimeInterval(Double(i - rest.count))))
        }
        Self.enforceCaps(&entries)
        if dropped > 0 { dlog("[FaceMatch] Migration dropped \(dropped) gallery faces that don't match the selfie") }
        return entries
    }

    /// Backward-compatible alias for existing callers.
    @discardableResult
    func loadSelfieReference(forUser userId: String) -> Bool { loadReference(forUser: userId) }

    /// Builds selfie anchor embeddings in BOTH orientations (upright + mirrored),
    /// since the captured selfie is mirrored but library/scan faces usually aren't.
    private func selfieAnchors(forUser userId: String) -> [[Float]]? {
        guard let stored = UserDefaults.standard.string(forKey: LocalStore.selfieKey(userId)) else {
            dlog("[FaceMatch] ERROR: No selfie path stored")
            return nil
        }
        // Moves a legacy Documents/ selfie into Application Support on the way.
        guard let path = LocalStore.resolveSelfiePath(stored, userId: userId),
              let rawImage = UIImage(contentsOfFile: path),
              let cgImage = renderUpOrientation(rawImage).cgImage else {
            dlog("[FaceMatch] ERROR: Could not load selfie image")
            return nil
        }
        var anchors: [[Float]] = []
        if let e = generateEmbeddingFromPhoto(cgImage, label: "selfie") { anchors.append(e) }
        // Flip-averaged embeddings are already mirror-invariant: the mirror anchor would be a copy.
        if !Self.profile.flipAverage, let flipped = horizontallyFlipped(cgImage),
           let m = generateEmbeddingFromPhoto(flipped, label: "selfie-mirror") { anchors.append(m) }
        guard !anchors.isEmpty else { return nil }
        // The onboarding head-turn frames (`selfieTurnFrames_<userId>`) are selfie anchors
        // too: protected from eviction, part of the learning gate's reference, and rebuilt
        // with the front frame whenever the gallery is (model-version bump, migration).
        let frontCount = anchors.count
        for (i, frame) in SelfieReferenceStore.turnFrames(userId: userId).enumerated() {
            guard let cg = renderUpOrientation(frame).cgImage else { continue }
            let mirror: [Float]? = Self.profile.flipAverage ? nil
                : horizontallyFlipped(cg).flatMap { generateEmbeddingFromPhoto($0, label: "selfie-turn\(i + 1)-mirror") }
            for e in [generateEmbeddingFromPhoto(cg, label: "selfie-turn\(i + 1)"), mirror]
                .compactMap({ $0 })
            where !anchors.contains(where: { dotProduct($0, e) > Self.profile.galleryDuplicate }) {
                anchors.append(e)
            }
        }
        dlog("[FaceMatch] Selfie anchors built: \(frontCount) front + \(anchors.count - frontCount) head-turn (upright + mirror)")
        return anchors
    }

    /// Mirrors a CGImage left-to-right.
    private func horizontallyFlipped(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Adds confirmed library faces to the reference gallery (Phase 2: "tap the
    /// photos that are you"). Each image should contain the user's face; the best
    /// detected face per image is aligned, embedded, and appended. Returns how many
    /// were added.
    @discardableResult
    func addReferenceFaces(from cgImages: [CGImage], forUser userId: String) -> Int {
        let embeddings = cgImages.compactMap { generateEmbeddingFromPhoto($0, label: "confirm") }
        return addReferenceEmbeddings(embeddings, forUser: userId)
    }

    // MARK: - Reference Builder ("tap which photos are you")

    /// Evaluates the most prominent face in a candidate library photo for the
    /// reference-builder UI. Returns a display crop (padded, for the grid), the
    /// aligned face embedding (to add to the gallery on confirm), and its
    /// similarity to the current gallery (for ranking; 0 if the gallery is empty).
    func evaluateFaceForReference(in cgImage: CGImage) -> (displayCrop: CGImage, embedding: [Float], similarity: Float)? {
        // Candidate crops can be frame-filling faces, so the padded retry stays on here.
        let faces = FaceDetector.shared.detect(in: cgImage, padRetry: true)
        guard !faces.isEmpty else { return nil }
        let imgW = cgImage.width, imgH = cgImage.height
        let refs = referenceEmbeddings

        func embedAndCrop(_ face: DetectedFace) -> (crop: CGImage, embedding: [Float])? {
            guard let aligned = warpAligned(image: cgImage, srcPoints: face.keypoints),
                  let embedding = generateEmbedding(for: aligned),
                  let crop = paddedFaceCrop(from: cgImage,
                                            bbox: face.normalizedBox(imageWidth: imgW, imageHeight: imgH)) else { return nil }
            return (crop, embedding)
        }

        // No anchor yet (no selfie): fall back to the largest face.
        if refs.isEmpty {
            guard let face = faces.max(by: {
                ($0.boxPixels.width * $0.boxPixels.height) < ($1.boxPixels.width * $1.boxPixels.height)
            }), let r = embedAndCrop(face) else { return nil }
            return (r.crop, r.embedding, 0)
        }

        // With a selfie anchor: surface the face that best matches the USER, not
        // just the largest. In a couple photo this returns the user's face (and
        // its similarity), so a partner's larger face can't be mistaken for them.
        var best: (crop: CGImage, embedding: [Float], sim: Float)?
        for face in faces {
            guard let r = embedAndCrop(face) else { continue }
            let sim = Self.bestMatch(of: r.embedding, in: refs).sim
            if best == nil || sim > best!.sim { best = (r.crop, r.embedding, sim) }
        }
        guard let b = best else { return nil }
        return (b.crop, b.embedding, b.sim)
    }

    /// Appends faces the user CONFIRMED (reference builder, "Is this you?" review, "which
    /// one is you?" pick, selfie head-turn frames) to the gallery, skipping near-duplicates.
    /// Confirmed entries are never evicted; at the gallery cap, learned entries make room
    /// and once the gallery is all selfie/confirmed further faces are not added.
    @discardableResult
    func addReferenceEmbeddings(_ embeddings: [[Float]], forUser userId: String) -> Int {
        guard !embeddings.isEmpty else { return 0 }
        loadReference(forUser: userId)
        return withState {
            if loadedUserId != userId { gallery = []; loadedUserId = userId }
            var added = 0
            let now = Date()
            for emb in embeddings {
                let protectedCount = gallery.filter { $0.source != .learned }.count
                guard protectedCount < Self.galleryCap else { break }
                if gallery.contains(where: { dotProduct($0.embedding, emb) > Self.profile.galleryDuplicate }) { continue }
                gallery.append(GalleryEntry(embedding: emb, source: .confirmed, addedAt: now))
                added += 1
            }
            Self.enforceCaps(&gallery)
            if added > 0 { persistGalleryLocked(forUser: userId) }
            dlog("[FaceMatch] Added \(added) confirmed embeddings; gallery now \(gallery.count) (\(Self.describe(gallery)))")
            return added
        }
    }

    /// The selfie anchors (upright + mirror).
    private static let anchorCount = 2
    static let galleryCap = 60
    /// Learned entries may be at most this share of the gallery (the rest is selfie +
    /// confirmed), so the scan's own picks can never outvote what the user confirmed.
    static let maxLearnedShare: Double = 0.5

    /// Caps the gallery without ever dropping selfie or confirmed entries: learned faces
    /// over their share, or over the total cap, go oldest first.
    static func enforceCaps(_ entries: inout [GalleryEntry]) {
        func learnedIndices() -> [Int] {
            entries.indices.filter { entries[$0].source == .learned }
                .sorted { entries[$0].addedAt < entries[$1].addedAt }
        }
        let protectedCount = entries.filter { $0.source != .learned }.count
        let share = maxLearnedShare
        let maxLearned = max(0, Int((Double(protectedCount) * share / (1 - share)).rounded(.down)))
        var learned = learnedIndices()
        var drop = Set<Int>()
        if learned.count > maxLearned {
            drop.formUnion(learned.prefix(learned.count - maxLearned))
        }
        let overflow = entries.count - drop.count - galleryCap
        if overflow > 0 {
            learned = learned.filter { !drop.contains($0) }
            drop.formUnion(learned.prefix(overflow))
        }
        guard !drop.isEmpty else { return }
        entries = entries.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    // MARK: - Self-learning during the scan
    //
    // A single selfie only covers one angle and one lighting. Faces the scan is *very*
    // sure about are added to the gallery so each confident match teaches the next angle.
    // Gate (all must hold), so one impostor can't get in and then pull in their own photos:
    // - the match against the whole gallery is very high (`autoLearnThreshold`), AND
    // - the face matches the SELFIE anchors themselves (`autoLearnSelfieThreshold`) —
    //   a learned or wrongly confirmed face can't vouch for the next one, AND
    // - in a group photo it beats every other face by a clear margin (`autoLearnMargin`).
    // Learned entries are capped (`maxLearnedShare`) and evicted oldest-first.
    static var autoLearnThreshold: Float = FaceModelProfile.active.autoLearn
    static var autoLearnSelfieThreshold: Float = FaceModelProfile.active.autoLearnSelfie
    static var autoLearnMargin: Float = FaceModelProfile.active.autoLearnMargin

    /// Adds a confidently-matched face from the scan. Skips near-duplicates.
    /// `margin` is the match's lead over the next-best face in the photo (solo: infinite).
    @discardableResult
    func learnFromScan(_ embedding: [Float], similarity: Float,
                       margin: Float = .greatestFiniteMagnitude, userId: String) -> Bool {
        guard similarity >= Self.autoLearnThreshold, margin >= Self.autoLearnMargin else { return false }
        loadReference(forUser: userId)
        return withState {
            guard loadedUserId == userId else { return false }
            let anchors = gallery.filter { $0.source == .selfie }.map(\.embedding)
            guard !anchors.isEmpty else { return false }
            let selfieSim = anchors.map { dotProduct($0, embedding) }.max() ?? -1
            guard selfieSim >= Self.autoLearnSelfieThreshold else {
                dlog("[FaceMatch] Not learning: selfie sim \(String(format: "%.3f", selfieSim)) < \(Self.autoLearnSelfieThreshold)")
                return false
            }
            if gallery.contains(where: { dotProduct($0.embedding, embedding) > Self.profile.learnedDuplicate }) { return false }
            let entry = GalleryEntry(embedding: embedding, source: .learned, addedAt: Date())
            gallery.append(entry)
            Self.enforceCaps(&gallery)
            guard gallery.contains(entry) else { return false }   // no room for learned faces
            persistGalleryLocked(forUser: userId)
            dlog("[FaceMatch] Learned a new view of the user (sim=\(String(format: "%.3f", similarity)), selfie=\(String(format: "%.3f", selfieSim))); gallery now \(gallery.count)")
            return true
        }
    }

    /// Gallery composition (diagnostics / tests).
    func gallerySummary() -> (selfie: Int, confirmed: Int, learned: Int) {
        withState {
            (gallery.filter { $0.source == .selfie }.count,
             gallery.filter { $0.source == .confirmed }.count,
             gallery.filter { $0.source == .learned }.count)
        }
    }

    /// A square, padded crop around a face for display in the reference grid.
    private func paddedFaceCrop(from cgImage: CGImage, bbox: CGRect) -> CGImage? {
        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        let x = bbox.origin.x * imgW
        let y = (1 - bbox.origin.y - bbox.height) * imgH
        let w = bbox.width * imgW, h = bbox.height * imgH
        let cx = x + w / 2, cy = y + h / 2
        let side = max(w, h) * 1.6
        let cropX = max(0, cx - side / 2)
        let cropY = max(0, cy - side / 2)
        let cropW = min(imgW - cropX, side)
        let cropH = min(imgH - cropY, side)
        guard cropW > 20, cropH > 20 else { return nil }
        return cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH))
    }

    // MARK: - Find User in Photo

    /// Matches every face in a photo against the gallery. `padRetry` (re-detecting on a
    /// padded copy when nothing is found) is only for frame-filling faces such as selfie
    /// crops — library photos without a face would otherwise pay a second, larger pass.
    func findUserInPhoto(_ cgImage: CGImage, padRetry: Bool = false) -> MatchResult {
        let refs = referenceEmbeddings
        guard !refs.isEmpty else {
            dlog("[FaceMatch] WARNING: No reference gallery loaded, rejecting photo")
            return .noFaces
        }

        let faces = FaceDetector.shared.detect(in: cgImage, padRetry: padRetry)
        if faces.isEmpty { return .noFaces }

        var bestBox: CGRect?
        var bestSimilarity: Float = -.infinity
        var bestSingle: Float = -.infinity
        var secondSimilarity: Float = -.infinity
        var bestRefIndex = -1
        var bestEmbedding: [Float]?
        var allScores: [Float] = []

        let imgW = cgImage.width
        let imgH = cgImage.height

        for face in faces {
            guard let aligned = warpAligned(image: cgImage, srcPoints: face.keypoints),
                  let embedding = generateEmbedding(for: aligned) else {
                allScores.append(-999) // marker: align/embed failed
                continue
            }

            let (similarity, single, refIdx) = Self.bestMatch(of: embedding, in: refs)
            allScores.append(similarity)

            if similarity > bestSimilarity {
                secondSimilarity = bestSimilarity
                bestSimilarity = similarity
                bestSingle = single
                bestBox = face.normalizedBox(imageWidth: imgW, imageHeight: imgH)
                bestRefIndex = refIdx
                bestEmbedding = embedding
            } else if similarity > secondSimilarity {
                secondSimilarity = similarity
            }
        }

        // Auto-add needs the gallery's consensus (two entries agree); review needs one entry.
        // With a big gallery a single-entry max admits strangers far more often: on LFW with a
        // 10-photo gallery, TAR at FAR 1e-5 was 87% for the max and 99% for the top-2 mean
        // (docs/MODEL-LICENSING.md §8).
        let confidence: Confidence
        if bestSimilarity >= Self.highConfidenceThreshold {
            confidence = .high
        } else if bestSingle >= Self.borderlineThreshold {
            confidence = .borderline
        } else {
            confidence = .none
        }

        dlog("[FaceMatch] \(confidence) best=\(String(format: "%.3f", bestSimilarity)) single=\(String(format: "%.3f", bestSingle)) galleryIdx=\(bestRefIndex) all=[\(allScores.map { String(format: "%.3f", $0) }.joined(separator: ", "))] faces=\(faces.count) gallery=\(refs.count)")

        return MatchResult(
            confidence: confidence,
            matchedFaceBox: confidence == .none ? nil : bestBox,
            faceCount: faces.count,
            similarity: bestSimilarity.isFinite ? bestSimilarity : nil,
            runnerUpSimilarity: secondSimilarity.isFinite ? secondSimilarity : nil,
            matchedEmbedding: bestEmbedding,
            bestSingleSimilarity: bestSingle.isFinite ? bestSingle : nil
        )
    }

    /// A face's gallery score (`sim`: the mean of its `galleryConsensus` best similarities, or
    /// fewer while the gallery is smaller), its single best similarity, and which gallery slot
    /// produced that. The index lets us spot a polluted reference: if the same slot keeps winning
    /// matches for different people, that slot is probably not the user.
    static func bestMatch(of embedding: [Float], in refs: [[Float]]) -> (sim: Float, single: Float, index: Int) {
        let k = max(1, profile.galleryConsensus)
        var top = [Float](repeating: -.infinity, count: k)   // descending
        var idx = -1
        for (i, ref) in refs.enumerated() {
            let s = dot(ref, embedding)
            if s > top[0] { idx = i }
            if s > top[k - 1] {
                var j = k - 1
                while j > 0 && top[j - 1] < s { top[j] = top[j - 1]; j -= 1 }
                top[j] = s
            }
        }
        let used = top.filter { $0.isFinite }
        guard !used.isEmpty else { return (-.infinity, -.infinity, -1) }
        return (used.reduce(0, +) / Float(used.count), used[0], idx)
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }


    // MARK: - Identity Resolution (upload flow: "extract only my clothes")

    /// Counts people (bodies) in a photo, so a bystander whose face isn't visible
    /// (back turned) still makes the photo "multi-person".
    func countPeople(in cgImage: CGImage) -> Int {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.5 }.count
    }

    /// Decides, for an uploaded photo, which image to actually analyze:
    /// - solo / product photo  -> analyze the whole image (trust the user)
    /// - multi-person, confident face match -> isolate just the user (silent)
    /// - multi-person, unsure  -> ask the user "which one is you?"
    func resolveIdentity(in image: UIImage, userId: String) -> IdentityResolution {
        // Bake EXIF orientation: a picked/captured UIImage carries its rotation in
        // metadata, and raw .cgImage drops it — feeding the detector a sideways
        // image (same class of bug we fixed for the scan/builder). The scan path
        // bakes via loadFullImage; do the same here.
        guard let cg = renderUpOrientation(image).cgImage else {
            dlog("[Identity] No CGImage — using whole photo")
            return .useWhole
        }
        _ = loadReference(forUser: userId)

        let faces = FaceDetector.shared.detect(in: cg, padRetry: false)   // library-style photo
        let bodies = countPeople(in: cg)
        let peopleCount = max(faces.count, bodies)
        dlog("[Identity] faces=\(faces.count) bodies=\(bodies) gallery=\(referenceCount)")

        // One person (or none) — just extract.
        if peopleCount <= 1 {
            dlog("[Identity] -> useWhole (solo/product)")
            return .useWhole
        }

        // Multi-person: try a confident automatic match against the gallery.
        // Require BOTH a high score AND a clear margin over the next-best face —
        // otherwise two people score too close to silently isolate the right one.
        let match = findUserInPhoto(cg)
        let simStr = match.similarity.map { String(format: "%.3f", $0) } ?? "-"
        let marginStr = match.margin == .greatestFiniteMagnitude ? "inf" : String(format: "%.3f", match.margin)
        let confidentPick = match.confidence == .high && match.margin >= Self.ambiguityMargin

        if confidentPick, match.matchedFaceBox != nil,
           let isolated = isolateMatchedPerson(from: cg, matchResult: match) {
            dlog("[Identity] -> isolated user (high match, sim=\(simStr), margin=\(marginStr))")
            return .isolated(isolated)
        }

        // Unsure (low score, close runner-up, or isolation failed) -> ask the user.
        let people = detectedPeople(in: cg, faces: faces)
        if people.isEmpty {
            dlog("[Identity] multi-person (\(peopleCount)) but no usable faces -> useWhole")
            return .useWhole
        }
        let reason = !confidentPick && match.confidence == .high
            ? "two people score too close (margin=\(marginStr))"
            : "best conf=\(match.confidence), sim=\(simStr)"
        dlog("[Identity] -> ambiguous: asking which of \(people.count) is you (\(reason))")
        return .ambiguous(people)
    }

    /// STRICT identity resolution for the background auto-scan. There is no user
    /// in the loop, so anything less than a confident, unambiguous, cleanly-
    /// isolatable match is skipped (returns nil). Returns the image to analyze
    /// (whole for a confident solo match, isolated user for multi-person).
    func resolveIdentityForScan(in cgImage: CGImage, fullImage: UIImage, userId: String) -> ScanIdentity {
        let perf = PerfLog.begin(.faceIdentity); defer { perf.end() }
        _ = loadReference(forUser: userId)
        let match = findUserInPhoto(cgImage)
        let sim = match.similarity ?? -1
        let simStr = match.similarity.map { String(format: "%.3f", $0) } ?? "-"
        let marginStr = match.margin == .greatestFiniteMagnitude ? "inf" : String(format: "%.3f", match.margin)

        // "Probably you": ask instead of silently dropping it. Before, every photo
        // between the borderline and high bars was skipped — which is most real
        // photos when the gallery is just the selfie.
        func review(_ why: String) -> ScanIdentity {
            guard let box = match.matchedFaceBox, let emb = match.matchedEmbedding else { return .skip }
            dlog("[Scan] review: \(why) (sim=\(simStr) margin=\(marginStr) faces=\(match.faceCount))")
            return .review(sim: sim, embedding: emb, faceBox: box, faceCount: match.faceCount)
        }

        guard match.confidence != .none, match.matchedFaceBox != nil else {
            dlog("[Scan] skip: not the user (sim=\(simStr) faces=\(match.faceCount))")
            return .skip
        }
        guard match.confidence == .high else { return review("borderline match") }
        guard match.margin >= Self.ambiguityMargin else { return review("two faces score too close") }

        if match.faceCount > 1 {
            // Stricter bar for multi-person photos: a borderline match here, plus an
            // imperfect person-instance mask, risks extracting the wrong person's
            // clothes (e.g. a partner standing next to the user).
            guard sim >= Self.multiPersonThreshold else { return review("multi-person match below the multi-person bar") }
            guard let isolated = isolateMatchedPerson(from: cgImage, matchResult: match) else {
                dlog("[Scan] skip: confident match but couldn't isolate user (\(match.faceCount) people)")
                return .skip
            }
            if let emb = match.matchedEmbedding { learnFromScan(emb, similarity: sim, margin: match.margin, userId: userId) }
            dlog("[Scan] add: isolated user from \(match.faceCount) people (sim=\(simStr) margin=\(marginStr))")
            return .analyze(isolated)
        }

        if let emb = match.matchedEmbedding { learnFromScan(emb, similarity: sim, margin: match.margin, userId: userId) }
        dlog("[Scan] add: confident solo match (sim=\(simStr))")
        return .analyze(fullImage)
    }

    /// For a photo the user confirmed in scan review: learn the face, and return
    /// the image to analyze (the isolated person when others are in the shot).
    func imageForConfirmedReview(cgImage: CGImage, fullImage: UIImage, faceBox: CGRect,
                                 embedding: [Float], faceCount: Int, userId: String) -> UIImage? {
        addReferenceEmbeddings([embedding], forUser: userId)
        guard faceCount > 1 else { return fullImage }
        let mr = MatchResult(confidence: .high, matchedFaceBox: faceBox,
                             faceCount: faceCount, similarity: nil)
        return isolateMatchedPerson(from: cgImage, matchResult: mr)
    }

    /// Padded square face crop for the "Is this you?" review grid.
    func reviewFaceCrop(from cgImage: CGImage, faceBox: CGRect) -> UIImage? {
        paddedFaceCrop(from: cgImage, bbox: faceBox).map { UIImage(cgImage: $0) }
    }

    private func detectedPeople(in cgImage: CGImage, faces: [DetectedFace]) -> [DetectedPerson] {
        let imgW = cgImage.width, imgH = cgImage.height
        var result: [DetectedPerson] = []
        for face in faces {
            let nbox = face.normalizedBox(imageWidth: imgW, imageHeight: imgH)
            guard let cropCG = personDisplayCrop(from: cgImage, faceBBox: nbox) else { continue }
            let aligned = warpAligned(image: cgImage, srcPoints: face.keypoints)
            let emb = aligned.flatMap { generateEmbedding(for: $0) }
            result.append(DetectedPerson(faceBox: nbox, crop: UIImage(cgImage: cropCG), embedding: emb))
        }
        return result
    }

    /// Isolates a user-chosen person from a multi-person photo and learns their
    /// face (appends to the gallery so future matches improve).
    func isolateChosenPerson(_ person: DetectedPerson, in image: UIImage,
                             totalFaces: Int, userId: String) -> UIImage? {
        guard let cg = renderUpOrientation(image).cgImage else { return nil }
        if let emb = person.embedding {
            addReferenceEmbeddings([emb], forUser: userId)   // active learning
            dlog("[Identity] User picked a person — learned their face (active learning)")
        }
        let mr = MatchResult(confidence: .high, matchedFaceBox: person.faceBox,
                             faceCount: max(totalFaces, 2), similarity: nil)
        let result = isolateMatchedPerson(from: cg, matchResult: mr)
        dlog("[Identity] Isolating picked person: \(result != nil ? "ok" : "FAILED -> using whole photo")")
        return result
    }

    /// A head-and-shoulders crop around a face for the "which one is you?" cards.
    private func personDisplayCrop(from cgImage: CGImage, faceBBox: CGRect) -> CGImage? {
        let imgW = CGFloat(cgImage.width), imgH = CGFloat(cgImage.height)
        let fx = faceBBox.origin.x * imgW
        let fy = (1 - faceBBox.origin.y - faceBBox.height) * imgH
        let fw = faceBBox.width * imgW, fh = faceBBox.height * imgH
        let cx = fx + fw / 2
        let w = fw * 2.4
        let x = max(0, cx - w / 2)
        let y = max(0, fy - fh * 0.6)
        let cropW = min(imgW - x, w)
        let cropH = min(imgH - y, fh * 3.6)
        guard cropW > 20, cropH > 20,
              let c = cgImage.cropping(to: CGRect(x: x, y: y, width: cropW, height: cropH)) else { return nil }
        return c
    }

    // MARK: - Person Isolation (Instance Mask)

    /// Extracts just the matched person from a multi-person photo using
    /// VNGeneratePersonInstanceMaskRequest. Returns a UIImage with only the
    /// matched person visible (transparent background), cropped to their extent.
    func isolateMatchedPerson(from cgImage: CGImage, matchResult: MatchResult) -> UIImage? {
        guard let faceBox = matchResult.matchedFaceBox else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let handler = VNImageRequestHandler(ciImage: ciImage)

        let maskRequest = VNGeneratePersonInstanceMaskRequest()
        do {
            try handler.perform([maskRequest])
        } catch {
            dlog("[FaceMatch] Person instance mask failed: \(error)")
            return nil
        }

        guard let maskObs = maskRequest.results?.first else {
            dlog("[FaceMatch] No person instance mask results")
            return nil
        }

        let allInstances = maskObs.allInstances
        guard !allInstances.isEmpty else {
            dlog("[FaceMatch] Instance mask found no people")
            return nil
        }

        if allInstances.count == 1 {
            return extractPerson(maskObs: maskObs, instances: allInstances, handler: handler, ciImage: ciImage)
        }

        // Multiple people: pick the instance whose mask actually covers the
        // matched face. generateMask returns a Float32 soft mask in [0,1].
        guard let idx = instanceCoveringFace(faceBox, in: maskObs) else {
            dlog("[FaceMatch] Could not map matched face to a person instance")
            return nil
        }
        dlog("[FaceMatch] Matched face -> person instance \(idx) of \(allInstances.count)")
        return extractPerson(maskObs: maskObs, instances: IndexSet(integer: idx),
                             handler: handler, ciImage: ciImage)
    }

    /// Returns the instance index whose mask best covers the matched face, or nil
    /// if no instance meaningfully covers it. Samples the face center plus a point
    /// toward the chest so a face on a body boundary still maps correctly.
    private func instanceCoveringFace(_ bbox: CGRect, in maskObs: VNInstanceMaskObservation) -> Int? {
        // Vision normalized coords (bottom-left origin): face center, and below the
        // chin toward the chest.
        let samples: [(CGFloat, CGFloat)] = [
            (bbox.midX, bbox.midY),
            (bbox.midX, max(0, bbox.minY - bbox.height * 0.4))
        ]

        var bestIdx: Int?
        var bestCoverage: Float = 0

        for idx in maskObs.allInstances {
            guard let mask = try? maskObs.generateMask(forInstances: IndexSet(integer: idx)) else { continue }
            let w = CVPixelBufferGetWidth(mask)
            let h = CVPixelBufferGetHeight(mask)

            CVPixelBufferLockBaseAddress(mask, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(mask) else { continue }
            let rowFloats = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float32>.stride
            let ptr = base.assumingMemoryBound(to: Float32.self)

            var coverage: Float = 0
            for (nx, ny) in samples {
                let px = min(max(Int(nx * CGFloat(w)), 0), w - 1)
                let py = min(max(Int((1.0 - ny) * CGFloat(h)), 0), h - 1)
                coverage += ptr[py * rowFloats + px]
            }
            if coverage > bestCoverage {
                bestCoverage = coverage
                bestIdx = idx
            }
        }

        // Require the face to be solidly inside the chosen person mask.
        return bestCoverage > 0.5 ? bestIdx : nil
    }

    private func extractPerson(maskObs: VNInstanceMaskObservation, instances: IndexSet,
                                handler: VNImageRequestHandler, ciImage: CIImage) -> UIImage? {
        do {
            let maskedBuffer = try maskObs.generateMaskedImage(
                ofInstances: instances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let maskedCI = CIImage(cvPixelBuffer: maskedBuffer)
            let ctx = CIContext()
            guard let maskedCG = ctx.createCGImage(maskedCI, from: maskedCI.extent) else { return nil }
            dlog("[FaceMatch] Person isolated: \(maskedCG.width)x\(maskedCG.height)")
            return UIImage(cgImage: maskedCG)
        } catch {
            dlog("[FaceMatch] generateMaskedImage failed: \(error)")
            return nil
        }
    }

    // MARK: - Embedding from a Full Photo (detect + align + embed best face)

    private func generateEmbeddingFromPhoto(_ cgImage: CGImage, label: String) -> [Float]? {
        let faces = FaceDetector.shared.detect(in: cgImage, padRetry: true)   // selfie / confirm crops can fill the frame
        dlog("[FaceMatch] [\(label)] Detected \(faces.count) face(s)")

        // Largest (most prominent) face — for a selfie/confirm crop there's one.
        guard let bestFace = faces.max(by: {
            ($0.boxPixels.width * $0.boxPixels.height) < ($1.boxPixels.width * $1.boxPixels.height)
        }) else {
            dlog("[FaceMatch] [\(label)] No face detected")
            return nil
        }

        guard let aligned = warpAligned(image: cgImage, srcPoints: bestFace.keypoints) else {
            dlog("[FaceMatch] [\(label)] Failed to produce aligned face crop")
            return nil
        }

        return generateEmbedding(for: aligned)
    }

    // MARK: - Aligned Face Crop (ArcFace 5-point → 112x112)

    /// Computes a similarity transform mapping srcPoints → arcfaceDst and warps the
    /// source image into a 112x112 aligned face via bilinear inverse sampling.
    private func warpAligned(image: CGImage, srcPoints: [SIMD2<Float>]) -> CGImage? {
        let dst = Self.arcfaceDst
        guard srcPoints.count == 5, dst.count == 5 else { return nil }

        // Similarity transform [a, -b, tx; b, a, ty] solved via normal equations.
        // For each point: dx = a*sx - b*sy + tx,  dy = b*sx + a*sy + ty
        var ata = [Float](repeating: 0, count: 16)
        var atb = [Float](repeating: 0, count: 4)

        for i in 0..<5 {
            let sx = srcPoints[i].x, sy = srcPoints[i].y
            let dx = dst[i].x, dy = dst[i].y
            let rows: [[Float]] = [[sx, -sy, 1, 0], [sy, sx, 0, 1]]
            let rhs: [Float] = [dx, dy]
            for (row, d) in zip(rows, rhs) {
                for r in 0..<4 {
                    for c in 0..<4 { ata[r * 4 + c] += row[r] * row[c] }
                    atb[r] += row[r] * d
                }
            }
        }

        guard gaussianSolve4x4(&ata, &atb) else {
            dlog("[FaceMatch] Transform solve failed (singular)")
            return nil
        }

        let a = atb[0], b = atb[1], tx = atb[2], ty = atb[3]
        let det = a * a + b * b
        guard det > 1e-6 else {
            dlog("[FaceMatch] Degenerate transform (det=\(det))")
            return nil
        }
        let invDet = 1.0 / det

        let srcW = image.width, srcH = image.height
        guard let srcBuffer = imageToPixelBuffer(image) else {
            dlog("[FaceMatch] Failed to rasterize source image")
            return nil
        }

        let outSize = Self.profile.embedderInputSize
        let bpp = 4
        let outBytesPerRow = outSize * bpp
        var outPixels = [UInt8](repeating: 0, count: outSize * outBytesPerRow)
        let srcBytesPerRow = srcW * bpp

        for oy in 0..<outSize {
            for ox in 0..<outSize {
                let dxOff = Float(ox) - tx
                let dyOff = Float(oy) - ty
                let sx = (a * dxOff + b * dyOff) * invDet
                let sy = (-b * dxOff + a * dyOff) * invDet
                guard sx >= 0, sy >= 0, sx < Float(srcW - 1), sy < Float(srcH - 1) else { continue }

                let x0 = Int(sx), y0 = Int(sy)
                let x1 = x0 + 1, y1 = y0 + 1
                let fx = sx - Float(x0), fy = sy - Float(y0)
                let outOff = (oy * outSize + ox) * bpp
                for c in 0..<3 {
                    let v00 = Float(srcBuffer[y0 * srcBytesPerRow + x0 * bpp + c])
                    let v10 = Float(srcBuffer[y0 * srcBytesPerRow + x1 * bpp + c])
                    let v01 = Float(srcBuffer[y1 * srcBytesPerRow + x0 * bpp + c])
                    let v11 = Float(srcBuffer[y1 * srcBytesPerRow + x1 * bpp + c])
                    let val = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                              v01 * (1 - fx) * fy + v11 * fx * fy
                    outPixels[outOff + c] = UInt8(min(max(val, 0), 255))
                }
                outPixels[outOff + 3] = 255
            }
        }

        return pixelBufferToImage(outPixels, width: outSize, height: outSize)
    }

    // MARK: - Pixel Buffer Helpers

    /// Rasterizes a CGImage into an RGBA pixel buffer with top-left origin.
    private func imageToPixelBuffer(_ cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width, h = cgImage.height
        let bpp = 4
        let bytesPerRow = w * bpp
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        // NO vertical flip. Verified with CoreGraphics: drawing a CGImage into a
        // bitmap context without a flip yields a TOP-LEFT (upright) buffer. The old
        // flip produced an upside-down buffer, so warpAligned's sampled keypoints
        // were Y-inverted vs the upright arcfaceDst template — every aligned face
        // crop came out upside down, and every embedding was of an upside-down face.
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return pixels
    }

    private func pixelBufferToImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: - Embedding Generation

    /// Embeds an aligned face, L2-normalized so the dot product is cosine similarity.
    /// With `flipAverage` (SFace) the face and its mirror image are embedded and summed: on LFW
    /// this raised TAR at a fixed false-accept rate (docs/MODEL-LICENSING.md §8) and makes the
    /// embedding mirror-invariant, so mirrored front-camera selfies match unmirrored photos.
    /// Gallery-building and matching both go through here, so reference and query embeddings
    /// stay consistent.
    private func generateEmbedding(for faceCrop: CGImage) -> [Float]? {
        guard var embedding = rawEmbedding(for: faceCrop) else { return nil }
        if Self.profile.flipAverage {
            guard let mirror = horizontallyFlipped(faceCrop), let m = rawEmbedding(for: mirror),
                  m.count == embedding.count else { return nil }
            vDSP_vadd(embedding, 1, m, 1, &embedding, 1, vDSP_Length(embedding.count))
        }
        var norm: Float = 0
        vDSP_svesq(embedding, 1, &norm, vDSP_Length(embedding.count))
        norm = sqrt(norm)
        if norm > 0 {
            vDSP_vsdiv(embedding, 1, &norm, &embedding, 1, vDSP_Length(embedding.count))
        }
        return embedding
    }

    /// Single forward pass of the model, returning the RAW (un-normalized) embedding.
    private func rawEmbedding(for faceCrop: CGImage) -> [Float]? {
        guard let inputArray = createInputMultiArray(from: faceCrop) else {
            dlog("[FaceMatch] Failed to create ML input array")
            return nil
        }
        // Load + predict + copy out under one lock: the model can't be loaded twice by
        // racing callers, nor released (clearReference) mid-prediction.
        modelLock.lock()
        defer { modelLock.unlock() }
        guard let model = ensureModelLoadedLocked() else {
            dlog("[FaceMatch] Model not available")
            return nil
        }
        do {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
            let input = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)]
            )
            let output = try model.prediction(from: input)

            guard let outputFeature = firstMultiArrayOutput(from: output),
                  let multiArray = outputFeature.multiArrayValue else {
                dlog("[FaceMatch] No MLMultiArray in model output")
                return nil
            }
            let dim = Self.profile.embeddingDimension
            guard multiArray.count >= dim else {
                dlog("[FaceMatch] Unexpected embedding dimension: \(multiArray.count) (want \(dim))")
                return nil
            }
            // Element accessor: correct for Float16 / strided ML-program outputs too.
            return Array(FaceDetectorSupport.floats(multiArray).prefix(dim))
        } catch {
            dlog("[FaceMatch] Model prediction failed: \(error)")
            return nil
        }
    }


    private func firstMultiArrayOutput(from output: MLFeatureProvider) -> MLFeatureValue? {
        for name in output.featureNames {
            if let value = output.featureValue(for: name), value.multiArrayValue != nil {
                return value
            }
        }
        return nil
    }

    /// Converts the aligned face to the embedder's [1, 3, S, S] Float32 input:
    /// value = (px - inputMean) * inputScale, in the profile's channel order. SFace takes RGB raw
    /// 0…255 (it normalizes inside the graph); the buffalo_l R50 takes RGB (px-127.5)/127.5. The
    /// pixel buffer is RGBA, so BGR models get B in plane 0 and R in plane 2.
    private func createInputMultiArray(from cgImage: CGImage) -> MLMultiArray? {
        let p = Self.profile
        let size = p.embedderInputSize
        guard let pixels = imageToPixelBuffer(cgImage) else { return nil }
        let actualW = cgImage.width, actualH = cgImage.height

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        ) else { return nil }

        let channelSize = size * size
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * channelSize)
        let bpp = 4
        let srcBytesPerRow = actualW * bpp
        let (rPlane, bPlane) = p.channelOrder == .rgb ? (0, 2) : (2, 0)
        let mean = p.inputMean, scale = p.inputScale

        for y in 0..<size {
            for x in 0..<size {
                let srcX = min(x * actualW / size, actualW - 1)
                let srcY = min(y * actualH / size, actualH - 1)
                let offset = srcY * srcBytesPerRow + srcX * bpp
                let pixelIndex = y * size + x
                ptr[rPlane * channelSize + pixelIndex] = (Float(pixels[offset]) - mean) * scale
                ptr[channelSize + pixelIndex] = (Float(pixels[offset + 1]) - mean) * scale
                ptr[bPlane * channelSize + pixelIndex] = (Float(pixels[offset + 2]) - mean) * scale
            }
        }
        return array
    }

    // MARK: - Cosine Similarity (dot product of L2-normalized vectors)

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    // MARK: - Gaussian Elimination (4x4)

    private func gaussianSolve4x4(_ a: inout [Float], _ b: inout [Float]) -> Bool {
        let n = 4
        for col in 0..<n {
            var maxVal = abs(a[col * n + col])
            var maxRow = col
            for row in (col + 1)..<n {
                let v = abs(a[row * n + col])
                if v > maxVal { maxVal = v; maxRow = row }
            }
            if maxVal < 1e-8 { return false }
            if maxRow != col {
                for k in 0..<n { a.swapAt(col * n + k, maxRow * n + k) }
                b.swapAt(col, maxRow)
            }
            let pivot = a[col * n + col]
            for row in (col + 1)..<n {
                let factor = a[row * n + col] / pivot
                for k in col..<n { a[row * n + k] -= factor * a[col * n + k] }
                b[row] -= factor * b[col]
            }
        }
        for col in stride(from: n - 1, through: 0, by: -1) {
            for k in (col + 1)..<n { b[col] -= a[col * n + k] * b[k] }
            b[col] /= a[col * n + col]
        }
        return true
    }

    // MARK: - Helpers

    /// Bakes EXIF orientation into the pixels, at the image's own pixel size. (The default
    /// renderer format uses the screen scale: a 12 MP photo became a 108 MP bitmap.)
    private func renderUpOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, image.cgImage != nil else { return image }
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return ImageDownsampler.render(size: px) { _ in image.draw(in: CGRect(origin: .zero, size: px)) }
    }

    // MARK: - Backward-Compatible API

    /// Legacy body crop API - delegates to isolateMatchedPerson.
    func cropToUserBody(from cgImage: CGImage, matchResult: MatchResult) -> CGImage? {
        guard matchResult.faceCount > 1 else { return nil }
        return isolateMatchedPerson(from: cgImage, matchResult: matchResult)?.cgImage
    }

    func photoContainsAnyPerson(_ cgImage: CGImage) -> Bool {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).contains { $0.confidence > 0.5 }
    }

    // MARK: - Public State

    var hasReference: Bool { withState { !gallery.isEmpty } }
    var referenceCount: Int { withState { gallery.count } }

    /// Clears the in-memory and persisted reference for a user. Call after a selfie
    /// retake so the gallery is rebuilt from the new selfie. Safe while other threads are
    /// matching: they finish on their snapshot, and a gallery being built from before the
    /// clear is discarded instead of installed.
    func clearReference(forUser userId: String? = nil) {
        withState {
            let target = userId ?? loadedUserId
            stateGeneration += 1
            if userId == nil || userId == loadedUserId {
                gallery = []
                loadedUserId = nil
            }
            if let target {
                try? FileManager.default.removeItem(at: Self.galleryURL(forUser: target))
            }
        }
        // Free the embedder. Waits for a running prediction to finish.
        modelLock.lock()
        mlModel = nil
        modelLock.unlock()
    }
}

// MARK: - Batch face embedding (one detector pass)

/// A detected face (box in image pixels, 5 ArcFace keypoints, detector score)
/// with its aligned face embedding and a padded display crop.
struct EmbeddedFace {
    let face: DetectedFace
    let embedding: [Float]
    let displayCrop: CGImage
}

extension FaceMatchingService {
    /// Every face in the image, detected once and embedded from the full image
    /// (keypoint-aligned, so no per-face crop and no second detector pass —
    /// `evaluateFaceForReference` re-detects internally). Largest first.
    /// `padRetry: false` for library photos (see `FaceDetecting.detect`).
    func embedFaces(in cgImage: CGImage, padRetry: Bool = true, maxFaces: Int = .max) -> [EmbeddedFace] {
        let faces = FaceDetector.shared.detect(in: cgImage, padRetry: padRetry)
            .sorted { $0.boxPixels.width * $0.boxPixels.height > $1.boxPixels.width * $1.boxPixels.height }
        return embed(faces: Array(faces.prefix(maxFaces)), in: cgImage)
    }

    /// Embeds faces already detected in `cgImage` (in the given order).
    func embed(faces: [DetectedFace], in cgImage: CGImage) -> [EmbeddedFace] {
        let w = cgImage.width, h = cgImage.height
        return faces.compactMap { face in
            guard let aligned = warpAligned(image: cgImage, srcPoints: face.keypoints),
                  let embedding = generateEmbedding(for: aligned),
                  let crop = paddedFaceCrop(from: cgImage, bbox: face.normalizedBox(imageWidth: w, imageHeight: h))
            else { return nil }
            return EmbeddedFace(face: face, embedding: embedding, displayCrop: crop)
        }
    }
}
