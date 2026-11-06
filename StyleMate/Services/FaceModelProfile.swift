import Foundation

/// Which face detector + embedder pair the app runs. Only `.openCVZoo` ships.
///
/// Every embedding comparison in the app (matching, clustering, the selfie checks, the scan's
/// self-learning) reads its bar from the active `FaceModelProfile`, because similarity scales are
/// model-specific: 0.55 means "certainly you" for one embedder and "a stranger" for another.
/// Swapping models is therefore one profile plus the two model files; see
/// docs/MODEL-LICENSING.md §7 for the exact steps.
enum FaceModelSet: String {
    /// YuNet 2023mar (MIT) detector + 5 landmarks, SFace 2021dec (Apache-2.0) 128-d embedder.
    /// Both from OpenCV Zoo. Commercially usable; this is what ships.
    case openCVZoo
    /// InsightFace `buffalo_l`: SCRFD-10G + ArcFace w600k_r50. **Non-commercial** unless InsightFace
    /// grants a licence (recognition-oss-pack@insightface.ai). Not built, not bundled. Kept as a
    /// ready plug-in on the Swift side; the build has no path to these weights on purpose (the
    /// manual steps after a signed licence are in docs/MODEL-LICENSING.md §7).
    case insightFaceBuffaloL
}

/// The face models' I/O contract and every similarity bar tuned to them.
struct FaceModelProfile {
    enum Detector { case yunet, scrfd }
    enum ChannelOrder { case rgb, bgr }

    let set: FaceModelSet
    /// Tags persisted galleries. A gallery stored under another version is discarded and rebuilt
    /// from the selfie (embeddings of different models can't be compared).
    let modelVersion: String

    // MARK: Models
    let detector: Detector
    /// Bundle resource names (compiled `.mlmodelc`; the `.mlpackage`s live in StyleMate/FaceModels/).
    let detectorResource: String
    let embedderResource: String
    /// Embedder input: `inputSize`² aligned face, NCHW float, value = (px - inputMean) * inputScale.
    let embedderInputSize: Int
    let channelOrder: ChannelOrder
    let inputMean: Float
    let inputScale: Float
    let embeddingDimension: Int
    /// Embed the aligned face and its mirror image and average them (flip test-time augmentation).
    let flipAverage: Bool

    // MARK: Matching (FaceMatchingService)
    /// A face's gallery score is the mean of its this-many best gallery similarities (fewer while
    /// the gallery is smaller). 1 = plain max. The max over a big gallery admits strangers more
    /// often the more entries it holds; a consensus of two does not (docs/MODEL-LICENSING.md §8).
    /// `.high` / `multiPerson` / `autoLearn` / the margin use this score; `borderline` uses the
    /// single best similarity, so a face that matches only one stored view still reaches review.
    let galleryConsensus: Int
    /// Auto-add a solo photo.
    let highConfidence: Float
    /// Send to "Is this you?" review.
    let borderline: Float
    /// Auto-isolate the user in a multi-person photo (stricter than solo).
    let multiPerson: Float
    /// The match must beat the next face in the photo by this much to act without asking.
    let ambiguityMargin: Float
    /// Self-learning gate: gallery match, match to the selfie anchors themselves, lead over others.
    let autoLearn: Float
    let autoLearnSelfie: Float
    let autoLearnMargin: Float
    /// Gallery entries this similar are the same view; don't store both.
    let galleryDuplicate: Float
    /// A learned face this similar to an existing entry adds nothing.
    let learnedDuplicate: Float

    // MARK: Find yourself (FaceClustering, LibraryFaceScanner, FaceReferenceViewModel)
    let clusterLink: Float
    let offerFloor: Float
    let preselect: Float
    let alsoYouCluster: Float
    let alsoYouMember: Float
    let alsoYouSingle: Float
    let alsoYouPreselect: Float
    /// Live "found you" strip during the library pass.
    let likelyYou: Float
    /// Two detections of one face in one photo (overlapping boxes).
    let sameFaceInPhoto: Float
    /// The 1600 px re-embedding must agree with the thumbnail's at least this much.
    let refineAgreement: Float

    // MARK: Selfie capture (SelfieFrameAssessor)
    /// A head-turn frame below this vs the front frame is "a different person".
    let selfieTurnMinSimilarity: Float

    // MARK: Detector gates (FaceQuality, SelfieFrameAssessor)
    /// Detections below this are dropped by the detector.
    let detectorThreshold: Float
    /// Library faces below this detector score are left out of clustering.
    let minLibraryDetectorScore: Float
    /// Selfie frames below this detector score are "unclear".
    let minSelfieDetectorScore: Float
}

extension FaceModelProfile {
    /// The profile the app runs. Change only together with the bundled models (build_face_models.sh).
    static let active: FaceModelProfile = .openCVZoo

    /// YuNet + SFace. Every bar is calibrated on LFW (evaluation only; docs/MODEL-LICENSING.md §8:
    /// 610 identities, 3- and 10-photo galleries, 2.7M impostor comparisons). SFace scores
    /// strangers higher than AdaFace did (mean 0.10, 1 in 1,000 above 0.37) and the user's own
    /// photos about as high (median 0.70), so the bars that keep strangers out moved up:
    /// - auto-add 0.58 on the top-2 consensus: no LFW stranger above it except label errors
    ///   (FAR <= 7.5e-7 with 3 gallery photos), TAR 94% (3 photos) / 98% (10 photos);
    /// - review 0.45 on the single best match: FAR 9e-5 (3 photos) / 4e-4 (10), i.e. a few
    ///   strangers per 10,000 library faces reach "Is this you?";
    /// - learning 0.65 consensus + 0.55 against the selfie itself + 0.15 lead;
    /// - the clustering link stays 0.5 (pairwise FAR 8e-6), the offer floor rises to 0.25.
    static let openCVZoo = FaceModelProfile(
        set: .openCVZoo,
        modelVersion: "yunet2023mar_sface2021dec_flip",
        detector: .yunet,
        detectorResource: "FaceDetectYuNet",
        embedderResource: "FaceEmbedSFace",
        embedderInputSize: 112,
        channelOrder: .rgb,
        inputMean: 0, inputScale: 1,          // SFace normalizes inside the graph: (x - 127.5) / 128
        embeddingDimension: 128,
        flipAverage: true,
        galleryConsensus: 2,
        highConfidence: 0.58, borderline: 0.45, multiPerson: 0.62, ambiguityMargin: 0.08,
        autoLearn: 0.65, autoLearnSelfie: 0.55, autoLearnMargin: 0.15,
        galleryDuplicate: 0.95, learnedDuplicate: 0.90,
        clusterLink: 0.5, offerFloor: 0.25, preselect: 0.45,
        alsoYouCluster: 0.40, alsoYouMember: 0.33, alsoYouSingle: 0.48, alsoYouPreselect: 0.52,
        likelyYou: 0.45, sameFaceInPhoto: 0.85, refineAgreement: 0.5,
        selfieTurnMinSimilarity: 0.35,
        detectorThreshold: 0.6, minLibraryDetectorScore: 0.75, minSelfieDetectorScore: 0.8)

    /// InsightFace buffalo_l (SCRFD-10G + w600k_r50). Only with a signed InsightFace licence.
    /// w600k_r50 is RGB, (px - 127.5) / 127.5, 512-d. Bars from the same LFW protocol
    /// (docs/MODEL-LICENSING.md §8): strangers mean 0.005, 99.9th pct 0.21 (like AdaFace), so
    /// auto-add 0.50 top-2 (TAR 98.4%, FAR at the label-error floor), review 0.35 single (FAR 4e-6).
    /// Re-check on the CI fixture benchmark before shipping.
    static let insightFaceBuffaloL = FaceModelProfile(
        set: .insightFaceBuffaloL,
        modelVersion: "scrfd10g_w600k_r50_flip",
        detector: .scrfd,
        detectorResource: "FaceDetectSCRFD",
        embedderResource: "FaceEmbedArcFaceR50",
        embedderInputSize: 112,
        channelOrder: .rgb,
        inputMean: 127.5, inputScale: 1 / 127.5,
        embeddingDimension: 512,
        flipAverage: true,
        galleryConsensus: 2,
        highConfidence: 0.50, borderline: 0.35, multiPerson: 0.55, ambiguityMargin: 0.08,
        autoLearn: 0.60, autoLearnSelfie: 0.50, autoLearnMargin: 0.15,
        galleryDuplicate: 0.95, learnedDuplicate: 0.90,
        clusterLink: 0.5, offerFloor: 0.15, preselect: 0.40,
        alsoYouCluster: 0.40, alsoYouMember: 0.30, alsoYouSingle: 0.45, alsoYouPreselect: 0.50,
        likelyYou: 0.35, sameFaceInPhoto: 0.85, refineAgreement: 0.45,
        selfieTurnMinSimilarity: 0.30,
        detectorThreshold: 0.5, minLibraryDetectorScore: 0.6, minSelfieDetectorScore: 0.65)
}
