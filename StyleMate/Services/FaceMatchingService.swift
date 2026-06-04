import UIKit
import Vision
import CoreML
import Accelerate
import CoreImage

/// One detected person in a photo, shown in the "which one is you?" picker.
struct DetectedPerson: Identifiable {
    let id = UUID()
    let face: VNFaceObservation
    let crop: UIImage
    let embedding: [Float]?
}

/// How a photo's "image to analyze" was resolved for identity.
enum IdentityResolution {
    case useWhole               // solo photo / product shot — analyze the whole image
    case isolated(UIImage)      // multi-person, confident match — isolated just the user
    case ambiguous([DetectedPerson])  // multi-person, unsure — ask the user
}

/// On-device face identity matching for the photo-library auto-scan.
///
/// The bundled model is InsightFace `w600k_mbf` (buffalo_s MobileFaceNet), an
/// ArcFace model. ArcFace embeddings are ONLY meaningful when the input face is
/// warped to the canonical 5-point template (eyes / nose / mouth-corners mapped
/// to fixed 112x112 positions). A loose bounding-box crop produces near-random
/// embeddings — which is why matching must align faces before embedding.
///
/// Identity is represented by a *gallery* of embeddings (the onboarding selfie
/// plus any library photos the user later confirms are them), persisted to disk.
/// A candidate face's score is its best cosine similarity against the gallery,
/// turned into a confidence tier rather than a single hard cutoff.
class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    // MARK: - Tunable Thresholds
    //
    // Cosine similarity of L2-normalized ArcFace embeddings. With Vision-landmark
    // alignment (slightly noisier than InsightFace's own detector) sensible
    // starting points are ~0.42 / ~0.30. Tune from device logs ([FaceMatch] lines).
    static var highConfidenceThreshold: Float = 0.42   // auto-add
    static var borderlineThreshold: Float = 0.30        // send to review
    private static let minFaceQuality: Float = 0.30     // skip blurry / poorly-captured faces
    // In a multi-person photo, the best match must beat the next-best face by at
    // least this much to auto-isolate silently. Otherwise two people score too
    // close to be sure, so we ask "which one is you?" instead of guessing.
    static var ambiguityMargin: Float = 0.08

    // InsightFace canonical 5-point destination for 112x112 alignment.
    // Source: insightface/utils/face_align.py `arcface_dst`
    private static let arcfaceDst: [SIMD2<Float>] = [
        SIMD2<Float>(38.2946, 51.6963),   // left eye center
        SIMD2<Float>(73.5318, 51.5014),   // right eye center
        SIMD2<Float>(56.0252, 71.7366),   // nose tip
        SIMD2<Float>(41.5493, 92.3655),   // left mouth corner
        SIMD2<Float>(70.7299, 92.2041)    // right mouth corner
    ]

    private var referenceGallery: [[Float]] = []
    private var loadedUserId: String?
    private var mlModel: MLModel?

    // MARK: - Match Result

    enum Confidence {
        case high        // confidently the user — safe to auto-add
        case borderline  // probably the user — surface for review
        case none        // not the user
    }

    struct MatchResult {
        let confidence: Confidence
        let matchedFace: VNFaceObservation?
        let faceCount: Int
        let similarity: Float?
        /// Best similarity of any OTHER face in the photo. Used to detect the
        /// "two people score close together" case where the pick is uncertain.
        var runnerUpSimilarity: Float? = nil

        /// True when the photo should enter the pipeline at all (high or borderline).
        var isMatch: Bool { confidence == .high || confidence == .borderline }

        /// How far ahead the matched face is from the next-best face. Large = a
        /// confident, unambiguous pick; small = two similar-scoring people.
        var margin: Float {
            guard let best = similarity, let runner = runnerUpSimilarity else { return .greatestFiniteMagnitude }
            return best - runner
        }

        static let noFaces = MatchResult(confidence: .none, matchedFace: nil, faceCount: 0, similarity: nil)
    }

    // MARK: - Model Loading

    private func ensureModelLoaded() -> Bool {
        if mlModel != nil { return true }

        guard let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlpackage") else {
            print("[FaceMatch] ERROR: MobileFaceNet model not found in bundle")
            return false
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            mlModel = try MLModel(contentsOf: url, configuration: config)
            print("[FaceMatch] Model loaded successfully")
            return true
        } catch {
            print("[FaceMatch] ERROR: Failed to load model: \(error)")
            return false
        }
    }

    // MARK: - Reference Gallery (persisted)

    private struct StoredGallery: Codable { var embeddings: [[Float]] }

    private static func galleryURL(forUser userId: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        var dir = appSupport.appendingPathComponent("FaceReference", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? dir.setResourceValues(resourceValues)
        return dir.appendingPathComponent("faceReference_\(userId).json")
    }

    private func persistGallery(forUser userId: String) {
        let stored = StoredGallery(embeddings: referenceGallery)
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: Self.galleryURL(forUser: userId), options: .atomic)
            print("[FaceMatch] Persisted gallery (\(referenceGallery.count) embeddings) for \(userId)")
        }
    }

    /// Loads the reference gallery for a user. If none is persisted yet, bootstraps
    /// it from the onboarding selfie. Returns true if at least one embedding is available.
    @discardableResult
    func loadReference(forUser userId: String) -> Bool {
        if loadedUserId == userId, !referenceGallery.isEmpty { return true }

        // 1. Persisted gallery (selfie anchor + any confirmed library faces)
        if let data = try? Data(contentsOf: Self.galleryURL(forUser: userId)),
           let stored = try? JSONDecoder().decode(StoredGallery.self, from: data),
           !stored.embeddings.isEmpty {
            referenceGallery = stored.embeddings
            loadedUserId = userId
            print("[FaceMatch] Loaded gallery: \(referenceGallery.count) embeddings for \(userId)")
            return true
        }

        // 2. Bootstrap from the selfie image
        guard let anchor = embeddingFromSelfie(forUser: userId) else {
            print("[FaceMatch] ERROR: Could not build reference from selfie for \(userId)")
            return false
        }
        referenceGallery = [anchor]
        loadedUserId = userId
        persistGallery(forUser: userId)
        return true
    }

    /// Backward-compatible alias for existing callers.
    @discardableResult
    func loadSelfieReference(forUser userId: String) -> Bool { loadReference(forUser: userId) }

    private func embeddingFromSelfie(forUser userId: String) -> [Float]? {
        let key = "selfieReferencePath_\(userId)"
        guard let path = UserDefaults.standard.string(forKey: key) else {
            print("[FaceMatch] ERROR: No selfie path stored for user \(userId)")
            return nil
        }
        guard let rawImage = UIImage(contentsOfFile: path) ?? loadFromDocuments(filename: path) else {
            print("[FaceMatch] ERROR: Could not load selfie image at \(path)")
            return nil
        }
        guard let cgImage = renderUpOrientation(rawImage).cgImage,
              let embedding = generateEmbeddingFromPhoto(cgImage, label: "selfie") else {
            print("[FaceMatch] ERROR: Could not generate embedding from selfie")
            return nil
        }
        print("[FaceMatch] Selfie anchor embedding built (\(embedding.count)-dim)")
        return embedding
    }

    /// Adds confirmed library faces to the reference gallery (Phase 2: "tap the
    /// photos that are you"). Each image should contain the user's face; the best
    /// detected face per image is aligned, embedded, and appended. Returns how many
    /// were added.
    @discardableResult
    func addReferenceFaces(from cgImages: [CGImage], forUser userId: String) -> Int {
        loadReference(forUser: userId)
        var added = 0
        for cg in cgImages {
            if let emb = generateEmbeddingFromPhoto(cg, label: "confirm") {
                referenceGallery.append(emb)
                added += 1
            }
        }
        if added > 0 {
            loadedUserId = userId
            persistGallery(forUser: userId)
        }
        print("[FaceMatch] Added \(added) confirmed faces; gallery now \(referenceGallery.count)")
        return added
    }

    // MARK: - Reference Builder ("tap which photos are you")

    /// Evaluates the most prominent face in a candidate library photo for the
    /// reference-builder UI. Returns a display crop (padded, for the grid), the
    /// aligned face embedding (to add to the gallery on confirm), and its
    /// similarity to the current gallery (for ranking; 0 if the gallery is empty).
    func evaluateFaceForReference(in cgImage: CGImage) -> (displayCrop: CGImage, embedding: [Float], similarity: Float)? {
        let faces = detectFacesWithLandmarks(in: cgImage)
        guard !faces.isEmpty else { return nil }

        func embedAndCrop(_ face: VNFaceObservation) -> (crop: CGImage, embedding: [Float])? {
            guard let aligned = alignedFaceCrop(from: cgImage, observation: face,
                                                imageWidth: cgImage.width, imageHeight: cgImage.height),
                  let embedding = generateEmbedding(for: aligned),
                  let crop = paddedFaceCrop(from: cgImage, bbox: face.boundingBox) else { return nil }
            return (crop, embedding)
        }

        // No anchor yet (no selfie): fall back to the largest face.
        if referenceGallery.isEmpty {
            guard let face = faces.max(by: {
                ($0.boundingBox.width * $0.boundingBox.height) < ($1.boundingBox.width * $1.boundingBox.height)
            }), let r = embedAndCrop(face) else { return nil }
            return (r.crop, r.embedding, 0)
        }

        // With a selfie anchor: surface the face that best matches the USER, not
        // just the largest. In a couple photo this returns the user's face (and
        // its similarity), so a partner's larger face can't be mistaken for them.
        var best: (crop: CGImage, embedding: [Float], sim: Float)?
        for face in faces {
            guard let r = embedAndCrop(face) else { continue }
            let sim = bestGallerySimilarity(of: r.embedding)
            if best == nil || sim > best!.sim { best = (r.crop, r.embedding, sim) }
        }
        guard let b = best else { return nil }
        return (b.crop, b.embedding, b.sim)
    }

    /// Appends already-computed embeddings (from evaluateFaceForReference) to the
    /// gallery, skipping near-duplicates to keep it diverse, and caps the size.
    @discardableResult
    func addReferenceEmbeddings(_ embeddings: [[Float]], forUser userId: String) -> Int {
        loadReference(forUser: userId)
        var added = 0
        for emb in embeddings {
            let tooSimilar = referenceGallery.contains { dotProduct($0, emb) > 0.95 }
            if tooSimilar { continue }
            referenceGallery.append(emb)
            added += 1
        }
        let cap = 40
        if referenceGallery.count > cap {
            referenceGallery.removeFirst(referenceGallery.count - cap)
        }
        if added > 0 {
            loadedUserId = userId
            persistGallery(forUser: userId)
        }
        print("[FaceMatch] Added \(added) reference embeddings; gallery now \(referenceGallery.count)")
        return added
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

    func findUserInPhoto(_ cgImage: CGImage) -> MatchResult {
        guard !referenceGallery.isEmpty else {
            print("[FaceMatch] WARNING: No reference gallery loaded, rejecting photo")
            return .noFaces
        }

        let faces = detectFacesWithLandmarks(in: cgImage)
        if faces.isEmpty { return .noFaces }

        let qualityMap = detectFaceQualities(in: cgImage)

        var bestMatch: VNFaceObservation?
        var bestSimilarity: Float = -.infinity
        var secondSimilarity: Float = -.infinity
        var allScores: [Float] = []

        let imgW = cgImage.width
        let imgH = cgImage.height

        for face in faces {
            let quality = qualityForFace(face, qualityMap: qualityMap)
            if quality < Self.minFaceQuality {
                allScores.append(-1)   // marker: skipped for low quality
                continue
            }

            guard let aligned = alignedFaceCrop(from: cgImage, observation: face,
                                                 imageWidth: imgW, imageHeight: imgH),
                  let embedding = generateEmbedding(for: aligned) else {
                allScores.append(-999) // marker: align/embed failed
                continue
            }

            let similarity = bestGallerySimilarity(of: embedding)
            allScores.append(similarity)

            if similarity > bestSimilarity {
                secondSimilarity = bestSimilarity
                bestSimilarity = similarity
                bestMatch = face
            } else if similarity > secondSimilarity {
                secondSimilarity = similarity
            }
        }

        let scoresStr = allScores.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        let confidence: Confidence
        if bestSimilarity >= Self.highConfidenceThreshold {
            confidence = .high
        } else if bestSimilarity >= Self.borderlineThreshold {
            confidence = .borderline
        } else {
            confidence = .none
        }

        print("[FaceMatch] \(confidence) best=\(String(format: "%.3f", bestSimilarity)) all=[\(scoresStr)] faces=\(faces.count) gallery=\(referenceGallery.count)")

        return MatchResult(
            confidence: confidence,
            matchedFace: confidence == .none ? nil : bestMatch,
            faceCount: faces.count,
            similarity: bestSimilarity.isFinite ? bestSimilarity : nil,
            runnerUpSimilarity: secondSimilarity.isFinite ? secondSimilarity : nil
        )
    }

    /// Best cosine similarity of `embedding` against every reference in the gallery.
    private func bestGallerySimilarity(of embedding: [Float]) -> Float {
        var best: Float = -.infinity
        for ref in referenceGallery {
            let s = dotProduct(ref, embedding)
            if s > best { best = s }
        }
        return best
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
        guard let cg = image.cgImage else {
            print("[Identity] No CGImage — using whole photo")
            return .useWhole
        }
        _ = loadReference(forUser: userId)

        let faces = detectFacesWithLandmarks(in: cg)
        let bodies = countPeople(in: cg)
        let peopleCount = max(faces.count, bodies)
        print("[Identity] faces=\(faces.count) bodies=\(bodies) gallery=\(referenceCount)")

        // One person (or none) — just extract.
        if peopleCount <= 1 {
            print("[Identity] -> useWhole (solo/product)")
            return .useWhole
        }

        // Multi-person: try a confident automatic match against the gallery.
        // Require BOTH a high score AND a clear margin over the next-best face —
        // otherwise two people score too close to silently isolate the right one.
        let match = findUserInPhoto(cg)
        let simStr = match.similarity.map { String(format: "%.3f", $0) } ?? "-"
        let marginStr = match.margin == .greatestFiniteMagnitude ? "inf" : String(format: "%.3f", match.margin)
        let confidentPick = match.confidence == .high && match.margin >= Self.ambiguityMargin

        if confidentPick, match.matchedFace != nil,
           let isolated = isolateMatchedPerson(from: cg, matchResult: match) {
            print("[Identity] -> isolated user (high match, sim=\(simStr), margin=\(marginStr))")
            return .isolated(isolated)
        }

        // Unsure (low score, close runner-up, or isolation failed) -> ask the user.
        let people = detectedPeople(in: cg, faces: faces)
        if people.isEmpty {
            print("[Identity] multi-person (\(peopleCount)) but no usable faces -> useWhole")
            return .useWhole
        }
        let reason = !confidentPick && match.confidence == .high
            ? "two people score too close (margin=\(marginStr))"
            : "best conf=\(match.confidence), sim=\(simStr)"
        print("[Identity] -> ambiguous: asking which of \(people.count) is you (\(reason))")
        return .ambiguous(people)
    }

    /// STRICT identity resolution for the background auto-scan. There is no user
    /// in the loop, so anything less than a confident, unambiguous, cleanly-
    /// isolatable match is skipped (returns nil). Returns the image to analyze
    /// (whole for a confident solo match, isolated user for multi-person).
    func resolveIdentityForScan(in cgImage: CGImage, fullImage: UIImage, userId: String) -> UIImage? {
        _ = loadReference(forUser: userId)
        let match = findUserInPhoto(cgImage)
        let simStr = match.similarity.map { String(format: "%.3f", $0) } ?? "-"
        let marginStr = match.margin == .greatestFiniteMagnitude ? "inf" : String(format: "%.3f", match.margin)

        // Must be a high-confidence match that clearly beats any other face.
        guard match.confidence == .high, match.margin >= Self.ambiguityMargin, match.matchedFace != nil else {
            print("[Scan] skip: not confidently the user (conf=\(match.confidence) sim=\(simStr) margin=\(marginStr) faces=\(match.faceCount))")
            return nil
        }

        if match.faceCount > 1 {
            guard let isolated = isolateMatchedPerson(from: cgImage, matchResult: match) else {
                print("[Scan] skip: confident match but couldn't isolate user (\(match.faceCount) people)")
                return nil
            }
            print("[Scan] add: isolated user from \(match.faceCount) people (sim=\(simStr) margin=\(marginStr))")
            return isolated
        }

        print("[Scan] add: confident solo match (sim=\(simStr))")
        return fullImage
    }

    private func detectedPeople(in cgImage: CGImage, faces: [VNFaceObservation]) -> [DetectedPerson] {
        var result: [DetectedPerson] = []
        for face in faces {
            guard let cropCG = personDisplayCrop(from: cgImage, faceBBox: face.boundingBox) else { continue }
            let aligned = alignedFaceCrop(from: cgImage, observation: face,
                                          imageWidth: cgImage.width, imageHeight: cgImage.height)
            let emb = aligned.flatMap { generateEmbedding(for: $0) }
            result.append(DetectedPerson(face: face, crop: UIImage(cgImage: cropCG), embedding: emb))
        }
        return result
    }

    /// Isolates a user-chosen person from a multi-person photo and learns their
    /// face (appends to the gallery so future matches improve).
    func isolateChosenPerson(_ person: DetectedPerson, in image: UIImage,
                             totalFaces: Int, userId: String) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        if let emb = person.embedding {
            addReferenceEmbeddings([emb], forUser: userId)   // active learning
            print("[Identity] User picked a person — learned their face (active learning)")
        }
        let mr = MatchResult(confidence: .high, matchedFace: person.face,
                             faceCount: max(totalFaces, 2), similarity: nil)
        let result = isolateMatchedPerson(from: cg, matchResult: mr)
        print("[Identity] Isolating picked person: \(result != nil ? "ok" : "FAILED -> using whole photo")")
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
        guard let face = matchResult.matchedFace else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let handler = VNImageRequestHandler(ciImage: ciImage)

        let maskRequest = VNGeneratePersonInstanceMaskRequest()
        do {
            try handler.perform([maskRequest])
        } catch {
            print("[FaceMatch] Person instance mask failed: \(error)")
            return nil
        }

        guard let maskObs = maskRequest.results?.first else {
            print("[FaceMatch] No person instance mask results")
            return nil
        }

        let allInstances = maskObs.allInstances
        guard !allInstances.isEmpty else {
            print("[FaceMatch] Instance mask found no people")
            return nil
        }

        if allInstances.count == 1 {
            return extractPerson(maskObs: maskObs, instances: allInstances, handler: handler, ciImage: ciImage)
        }

        // Multiple people: pick the instance whose mask actually covers the
        // matched face. generateMask returns a Float32 soft mask in [0,1].
        guard let idx = instanceCoveringFace(face, in: maskObs) else {
            print("[FaceMatch] Could not map matched face to a person instance")
            return nil
        }
        print("[FaceMatch] Matched face -> person instance \(idx) of \(allInstances.count)")
        return extractPerson(maskObs: maskObs, instances: IndexSet(integer: idx),
                             handler: handler, ciImage: ciImage)
    }

    /// Returns the instance index whose mask best covers the matched face, or nil
    /// if no instance meaningfully covers it. Samples the face center plus a point
    /// toward the chest so a face on a body boundary still maps correctly.
    private func instanceCoveringFace(_ face: VNFaceObservation, in maskObs: VNInstanceMaskObservation) -> Int? {
        let bbox = face.boundingBox
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
            print("[FaceMatch] Person isolated: \(maskedCG.width)x\(maskedCG.height)")
            return UIImage(cgImage: maskedCG)
        } catch {
            print("[FaceMatch] generateMaskedImage failed: \(error)")
            return nil
        }
    }

    // MARK: - Face Detection (with landmarks, required for alignment)

    func detectFacesWithLandmarks(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.5 }
            .sorted { $0.confidence > $1.confidence }
    }

    /// Rectangles-only detection (no landmarks) — used where alignment isn't needed.
    func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.5 }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Face Quality

    private func detectFaceQualities(in cgImage: CGImage) -> [CGRect: Float] {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        var map: [CGRect: Float] = [:]
        for obs in request.results ?? [] {
            map[obs.boundingBox] = obs.faceCaptureQuality ?? 0
        }
        return map
    }

    private func qualityForFace(_ face: VNFaceObservation, qualityMap: [CGRect: Float]) -> Float {
        if let q = qualityMap[face.boundingBox] { return q }
        // Find closest match by IoU
        var bestQ: Float = 1.0
        var bestIoU: CGFloat = 0
        for (rect, q) in qualityMap {
            let intersection = face.boundingBox.intersection(rect)
            if !intersection.isNull {
                let iou = (intersection.width * intersection.height) /
                    (face.boundingBox.width * face.boundingBox.height + rect.width * rect.height - intersection.width * intersection.height)
                if iou > bestIoU { bestIoU = iou; bestQ = q }
            }
        }
        return bestIoU > 0.5 ? bestQ : 1.0
    }

    // MARK: - Embedding from a Full Photo (detect + align + embed best face)

    private func generateEmbeddingFromPhoto(_ cgImage: CGImage, label: String) -> [Float]? {
        let faces = detectFacesWithLandmarks(in: cgImage)
        print("[FaceMatch] [\(label)] Detected \(faces.count) face(s)")

        guard let bestFace = faces.first else {
            print("[FaceMatch] [\(label)] No face detected")
            return nil
        }

        guard let aligned = alignedFaceCrop(from: cgImage, observation: bestFace,
                                             imageWidth: cgImage.width, imageHeight: cgImage.height) else {
            print("[FaceMatch] [\(label)] Failed to produce aligned face crop")
            return nil
        }

        return generateEmbedding(for: aligned)
    }

    // MARK: - Aligned Face Crop (ArcFace 5-point → 112x112)

    /// Produces an aligned 112x112 face crop. Uses ArcFace 5-point alignment when
    /// landmarks are available, falling back to a padded bbox crop otherwise.
    private func alignedFaceCrop(from cgImage: CGImage, observation: VNFaceObservation,
                                  imageWidth: Int, imageHeight: Int) -> CGImage? {
        if let landmarks = observation.landmarks,
           let src = extractFiveKeypoints(landmarks: landmarks,
                                          boundingBox: observation.boundingBox,
                                          imageWidth: imageWidth, imageHeight: imageHeight),
           let aligned = warpAligned(image: cgImage, srcPoints: src) {
            return aligned
        }
        print("[FaceMatch] Alignment unavailable, falling back to bbox crop")
        return bboxCrop(from: cgImage, bbox: observation.boundingBox,
                        imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// Extracts the 5 ArcFace keypoints (eye centers, nose tip, mouth corners) in
    /// image pixel coordinates (top-left origin) using Vision landmarks.
    private func extractFiveKeypoints(
        landmarks: VNFaceLandmarks2D,
        boundingBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> [SIMD2<Float>]? {
        guard let leftEye = landmarks.leftEye, leftEye.pointCount >= 1,
              let rightEye = landmarks.rightEye, rightEye.pointCount >= 1,
              let nose = landmarks.nose, nose.pointCount >= 1 else {
            print("[FaceMatch] Missing required landmarks (eyes or nose)")
            return nil
        }

        // Convert a normalized landmark point to image pixel coords (top-left origin).
        func convertPoint(_ normPt: CGPoint) -> SIMD2<Float> {
            let imgPt = VNImagePointForFaceLandmarkPoint(
                vector_float2(Float(normPt.x), Float(normPt.y)),
                boundingBox, imageWidth, imageHeight
            )
            // VNImagePointForFaceLandmarkPoint returns bottom-left origin; flip Y.
            return SIMD2<Float>(Float(imgPt.x), Float(imageHeight) - Float(imgPt.y))
        }

        func center(of region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = region.normalizedPoints
            let n = CGFloat(pts.count)
            return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n,
                           y: pts.reduce(0) { $0 + $1.y } / n)
        }

        let leftEyeCenter = convertPoint(center(of: leftEye))
        let rightEyeCenter = convertPoint(center(of: rightEye))

        let nosePts = nose.normalizedPoints
        let noseTip = convertPoint(nosePts[nosePts.count - 1])

        // Mouth corners: take the geometric leftmost / rightmost lip points
        // (robust to Vision's point ordering), falling back to an estimate.
        var leftMouth: SIMD2<Float>
        var rightMouth: SIMD2<Float>
        let lipRegion = landmarks.outerLips ?? landmarks.innerLips
        if let lips = lipRegion, lips.pointCount >= 2 {
            let pts = lips.normalizedPoints
            let leftMostNorm = pts.min { $0.x < $1.x }!
            let rightMostNorm = pts.max { $0.x < $1.x }!
            leftMouth = convertPoint(leftMostNorm)
            rightMouth = convertPoint(rightMostNorm)
        } else {
            let eyeMidX = (leftEyeCenter.x + rightEyeCenter.x) / 2
            let eyeSpan = rightEyeCenter.x - leftEyeCenter.x
            let mouthY = noseTip.y + (noseTip.y - (leftEyeCenter.y + rightEyeCenter.y) / 2) * 0.6
            leftMouth = SIMD2<Float>(eyeMidX - eyeSpan * 0.35, mouthY)
            rightMouth = SIMD2<Float>(eyeMidX + eyeSpan * 0.35, mouthY)
            print("[FaceMatch] Estimated mouth corners from eye/nose positions")
        }

        let result = [leftEyeCenter, rightEyeCenter, noseTip, leftMouth, rightMouth]

        for (i, pt) in result.enumerated() {
            if pt.x < -50 || pt.y < -50 || pt.x > Float(imageWidth + 50) || pt.y > Float(imageHeight + 50) {
                print("[FaceMatch] Keypoint \(i) out of bounds: (\(pt.x), \(pt.y))")
                return nil
            }
        }
        return result
    }

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
            print("[FaceMatch] Transform solve failed (singular)")
            return nil
        }

        let a = atb[0], b = atb[1], tx = atb[2], ty = atb[3]
        let det = a * a + b * b
        guard det > 1e-6 else {
            print("[FaceMatch] Degenerate transform (det=\(det))")
            return nil
        }
        let invDet = 1.0 / det

        let srcW = image.width, srcH = image.height
        guard let srcBuffer = imageToPixelBuffer(image) else {
            print("[FaceMatch] Failed to rasterize source image")
            return nil
        }

        let outSize = 112
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
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
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

    // MARK: - Fallback: BBox Crop + Resize

    private func bboxCrop(from cgImage: CGImage, bbox: CGRect,
                           imageWidth: Int, imageHeight: Int) -> CGImage? {
        let imgW = CGFloat(imageWidth), imgH = CGFloat(imageHeight)
        let x = bbox.origin.x * imgW
        let y = (1 - bbox.origin.y - bbox.height) * imgH
        let w = bbox.width * imgW, h = bbox.height * imgH

        let padding: CGFloat = 0.3
        let padX = w * padding, padY = h * padding
        let cropX = max(0, x - padX), cropY = max(0, y - padY)
        let cropW = min(imgW - cropX, w + 2 * padX), cropH = min(imgH - cropY, h + 2 * padY)
        guard cropW > 10, cropH > 10,
              let cropped = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else { return nil }

        let size = CGSize(width: 112, height: 112)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    // MARK: - Embedding Generation

    private func generateEmbedding(for faceCrop: CGImage) -> [Float]? {
        guard ensureModelLoaded(), let model = mlModel else {
            print("[FaceMatch] Model not available")
            return nil
        }
        guard let inputArray = createInputMultiArray(from: faceCrop) else {
            print("[FaceMatch] Failed to create ML input array")
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
                print("[FaceMatch] No MLMultiArray in model output")
                return nil
            }

            let count = multiArray.count
            guard count >= 128 else {
                print("[FaceMatch] Unexpected embedding dimension: \(count)")
                return nil
            }

            let embeddingSize = min(count, 512)
            var embedding = [Float](repeating: 0, count: embeddingSize)
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: embeddingSize)
            for i in 0..<embeddingSize { embedding[i] = ptr[i] }

            var norm: Float = 0
            vDSP_svesq(embedding, 1, &norm, vDSP_Length(embeddingSize))
            norm = sqrt(norm)
            if norm > 0 {
                vDSP_vsdiv(embedding, 1, &norm, &embedding, 1, vDSP_Length(embeddingSize))
            }
            return embedding
        } catch {
            print("[FaceMatch] Model prediction failed: \(error)")
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

    /// Converts a 112x112 CGImage to a [1, 3, 112, 112] Float32 MLMultiArray.
    /// Normalization: (pixel / 127.5) - 1.0, RGB channel order (InsightFace convention).
    private func createInputMultiArray(from cgImage: CGImage) -> MLMultiArray? {
        let size = 112
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

        for y in 0..<size {
            for x in 0..<size {
                let srcX = min(x * actualW / size, actualW - 1)
                let srcY = min(y * actualH / size, actualH - 1)
                let offset = srcY * srcBytesPerRow + srcX * bpp
                let r = Float(pixels[offset]) / 127.5 - 1.0
                let g = Float(pixels[offset + 1]) / 127.5 - 1.0
                let b = Float(pixels[offset + 2]) / 127.5 - 1.0
                let pixelIndex = y * size + x
                ptr[pixelIndex] = r
                ptr[channelSize + pixelIndex] = g
                ptr[2 * channelSize + pixelIndex] = b
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

    private func renderUpOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, image.cgImage != nil else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private func loadFromDocuments(filename: String) -> UIImage? {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docsDir.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
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

    var hasReference: Bool { !referenceGallery.isEmpty }
    var referenceCount: Int { referenceGallery.count }

    /// Clears the in-memory and persisted reference for a user. Call after a selfie
    /// retake so the gallery is rebuilt from the new selfie.
    func clearReference(forUser userId: String? = nil) {
        referenceGallery = []
        mlModel = nil
        if let userId = userId {
            try? FileManager.default.removeItem(at: Self.galleryURL(forUser: userId))
        } else if let loaded = loadedUserId {
            try? FileManager.default.removeItem(at: Self.galleryURL(forUser: loaded))
        }
        loadedUserId = nil
    }
}
