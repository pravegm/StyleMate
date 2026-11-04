import UIKit
import Photos

/// One face in an "Is this you?" grid.
struct FaceCandidate: Identifiable {
    /// Index of the face in the library pass.
    let id: Int
    let assetId: String
    let thumbnail: UIImage
    let embedding: [Float]
    /// Confidence it belongs with the group (cluster centroid / confirmed-face similarity).
    let similarity: Float
    var isSelected: Bool
}

/// Drives "Find yourself": an on-device pass over the most recent library photos that finds
/// every face (SCRFD on ~640 px thumbnails, AdaFace embeddings), groups faces of the same person,
/// ranks the groups against the selfie, and asks "Is this you?" about the best one — then
/// "Also you?" about faces that match what was confirmed. Confirmed faces are re-embedded at the
/// scan's ~1600 px resolution and added to the reference gallery. Nothing leaves the phone.
@MainActor
final class FaceReferenceViewModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case noPermission
        case scanning
        case reviewing
        case saving
        case finished
        /// Faces were found but none was confirmed (or none looked like a person who recurs).
        case nothingFound
        /// The library (or the Limited selection) has no photos.
        case emptyLibrary
    }

    enum Round: Equatable { case isThisYou, alsoYou }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var round: Round = .isThisYou
    @Published var candidates: [FaceCandidate] = []
    @Published private(set) var progress: Double = 0
    @Published private(set) var scannedCount = 0
    @Published private(set) var totalToScan = 0
    @Published private(set) var likelyYouCount = 0
    @Published private(set) var likelyYouPreview: [UIImage] = []
    @Published private(set) var isLimitedAccess = false
    @Published private(set) var canStopEarly = false
    @Published private(set) var hasSelfieAnchor = false
    @Published private(set) var addedCount = 0
    @Published private(set) var confirmedCount = 0
    /// 1-based index of the group being asked about (for "Not me" copy).
    @Published private(set) var offerNumber = 1

    static let scanLimit = LibraryFaceScanner.defaultLimit
    static let gridLimit = 48
    static let alsoYouLimit = 36
    /// A face this close to the selfie shows up in the live "found you" strip.
    static let likelyYouThreshold: Float = 0.35
    /// Stop early once the selfie has clearly found plenty of you.
    static let earlyStopMinPhotos = 400
    static let earlyStopStrongFaces = 60

    var selectedCount: Int { candidates.filter(\.isSelected).count }

    private var userId = ""
    private var faces: [ScannedFace] = []
    private var clusters: [FaceCluster] = []
    private var offers: [RankedCluster] = []
    private var offerIndex = 0
    private var offeredFaces = Set<Int>()
    private var confirmed: [Int] = []
    private var anchors: [[Float]] = []
    private var refined: [Int: [Float]] = [:]
    private var refineTask: Task<Void, Never>?
    private var stopRequested = false
    private var running = false
    private let imageManager = PHCachingImageManager()

    // MARK: - Scan

    func start(forUser userId: String) async {
        guard phase == .idle else { return }
        await scan(forUser: userId)
    }

    func scan(forUser userId: String) async {
        guard !running else { return }
        running = true
        defer { running = false }
        self.userId = userId
        reset()

        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            dlog("[FindYou] Photo access not granted (status=\(status.rawValue))")
            phase = .noPermission
            return
        }
        isLimitedAccess = status == .limited
        phase = .scanning

        // The selfie step rebuilds the identity in the background; rank against the new one.
        await IdentityBuild.waitUntilIdle()
        let uid = userId
        anchors = await IdentityWorker.shared.run { SelfieReferenceStore.prepareAnchors(forUser: uid) }
        hasSelfieAnchor = !anchors.isEmpty

        let (assets, selfieIds) = LibraryFaceScanner.fetchCandidateAssets(limit: Self.scanLimit)
        totalToScan = assets.count
        dlog("[FindYou] Looking at \(assets.count) photos (limited=\(isLimitedAccess), anchors=\(anchors.count))")
        guard !assets.isEmpty else {
            phase = .emptyLibrary
            return
        }

        let manager = imageManager
        let side = LibraryFaceScanner.thumbnailSide
        let cacheSize = CGSize(width: side, height: side)
        let cacheOptions = LibraryFaceScanner.requestOptions(network: false)
        let window = 40
        var cachedUpTo = 0
        func cacheAhead(from i: Int) {
            let end = min(assets.count, i + window)
            guard end > cachedUpTo else { return }
            let start = max(i, cachedUpTo)
            manager.startCachingImages(for: Array(assets[start..<end]), targetSize: cacheSize,
                                       contentMode: .aspectFit, options: cacheOptions)
            if start > window {
                manager.stopCachingImages(for: Array(assets[max(0, start - 2 * window)..<(start - window)]),
                                          targetSize: cacheSize, contentMode: .aspectFit, options: cacheOptions)
            }
            cachedUpTo = end
        }
        func load(_ index: Int) -> Task<UIImage?, Never> {
            let asset = assets[index]
            return Task { await LibraryFaceScanner.loadImage(asset, manager: manager, side: side, network: false, timeout: 4) }
        }

        let started = Date()
        let anchorsCopy = anchors
        var strong = 0
        var next: Task<UIImage?, Never>? = load(0)
        cacheAhead(from: 0)

        for i in assets.indices {
            if Task.isCancelled { next?.cancel(); manager.stopCachingImagesForAllAssets(); return }
            if stopRequested { break }
            let image = await next?.value
            next = i + 1 < assets.count ? load(i + 1) : nil
            if i + window / 2 >= cachedUpTo { cacheAhead(from: i + 1) }

            if let image {
                let assetId = assets[i].localIdentifier
                let isSelfie = selfieIds.contains(assetId)
                let found = await IdentityWorker.shared.run {
                    FaceSampleExtractor.scannedFaces(in: image, assetId: assetId, anchors: anchorsCopy, fromSelfieAlbum: isSelfie)
                }
                for f in found {
                    faces.append(f)
                    if f.anchorSimilarity >= Self.likelyYouThreshold {
                        strong += 1
                        likelyYouCount = strong
                        if let thumb = UIImage(data: f.thumbnailJPEG) {
                            likelyYouPreview.append(thumb)
                            if likelyYouPreview.count > 8 { likelyYouPreview.removeFirst() }
                        }
                    }
                }
            }
            scannedCount = i + 1
            progress = Double(i + 1) / Double(assets.count)
            if !canStopEarly, !faces.isEmpty, i >= 150 || Date().timeIntervalSince(started) > 12 {
                canStopEarly = true
            }
            if hasSelfieAnchor, i + 1 >= Self.earlyStopMinPhotos, strong >= Self.earlyStopStrongFaces {
                dlog("[FindYou] Early stop: \(strong) strong matches after \(i + 1) photos")
                break
            }
        }
        next?.cancel()
        manager.stopCachingImagesForAllAssets()
        dlog("[FindYou] Pass done: \(faces.count) faces in \(scannedCount) photos, \(strong) close to the selfie, \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        await buildOffers()
    }

    /// "Show me what you found": stop the pass and group what's been seen so far.
    func finishScanningNow() {
        stopRequested = true
    }

    private func reset() {
        phase = .idle
        round = .isThisYou
        candidates = []
        progress = 0
        scannedCount = 0
        totalToScan = 0
        likelyYouCount = 0
        likelyYouPreview = []
        canStopEarly = false
        addedCount = 0
        confirmedCount = 0
        offerNumber = 1
        faces = []
        clusters = []
        offers = []
        offerIndex = 0
        offeredFaces = []
        confirmed = []
        refined = [:]
        refineTask?.cancel()
        refineTask = nil
        stopRequested = false
    }

    // MARK: - Group + rank

    private func buildOffers() async {
        guard !faces.isEmpty else {
            phase = .nothingFound
            return
        }
        let embeddings = faces.map(\.embedding)
        let qualities = faces.map(\.quality)
        let assetIds = faces.map(\.assetId)
        let selfieFlags = faces.map(\.fromSelfieAlbum)
        let anchorsCopy = anchors
        let result = await Task.detached(priority: .userInitiated) { () -> ([FaceCluster], [RankedCluster]) in
            let clusters = FaceClustering.cluster(embeddings: embeddings, qualities: qualities, assetIds: assetIds)
            let ranked = FaceClustering.rank(clusters, anchors: anchorsCopy, fromSelfieAlbum: selfieFlags)
            return (clusters, ranked)
        }.value
        clusters = result.0
        offers = FaceClustering.offers(from: result.1)
        let summary = offers.map { "\($0.cluster.size)@\($0.anchorSimilarity.map { String(format: "%.2f", $0) } ?? "-")" }
        dlog("[FindYou] \(clusters.count) groups (\(clusters.filter { $0.size >= 2 }.count) recurring); offers: \(summary)")
        offerIndex = 0
        if offers.isEmpty {
            phase = .nothingFound
        } else {
            presentOffer()
        }
    }

    private func presentOffer() {
        let offer = offers[offerIndex]
        offerNumber = offerIndex + 1
        let picks = FaceClustering.reviewPicks(for: offer.cluster, embeddings: faces.map(\.embedding),
                                               assetIds: faces.map(\.assetId), limit: Self.gridLimit)
        offeredFaces.formUnion(offer.cluster.members)
        show(picks, round: .isThisYou)
    }

    private func show(_ picks: [ReviewPick], round: Round) {
        candidates = picks.map { p in
            let f = faces[p.face]
            return FaceCandidate(id: p.face, assetId: f.assetId, thumbnail: UIImage(data: f.thumbnailJPEG) ?? UIImage(),
                                 embedding: f.embedding, similarity: p.confidence, isSelected: p.preselected)
        }
        self.round = round
        phase = .reviewing
        startRefining(picks.map(\.face))
    }

    // MARK: - Review actions

    func toggle(_ id: Int) {
        guard let idx = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[idx].isSelected.toggle()
    }

    func setAll(selected: Bool) {
        for i in candidates.indices { candidates[i].isSelected = selected }
    }

    /// "Yes, that's me" / "Add these".
    func confirmSelection() {
        let selected = candidates.filter(\.isSelected).map(\.id)
        guard !selected.isEmpty else { return }
        confirmed.append(contentsOf: selected)
        // Faces shown but left unchecked are someone else: never offer them again.
        offeredFaces.formUnion(candidates.map(\.id))

        if round == .isThisYou {
            let picks = FaceClustering.alsoYouPicks(
                confirmed: confirmed.map { faces[$0].embedding }, anchors: anchors, clusters: clusters,
                embeddings: faces.map(\.embedding), assetIds: faces.map(\.assetId),
                excludeFaces: offeredFaces, excludeAssets: Set(confirmed.map { faces[$0].assetId }),
                limit: Self.alsoYouLimit)
            dlog("[FindYou] Confirmed \(selected.count); \(picks.count) 'also you?' candidates")
            if !picks.isEmpty {
                offeredFaces.formUnion(picks.map(\.face))
                show(picks, round: .alsoYou)
                return
            }
        }
        Task { await save() }
    }

    /// "Not me": try the next group, or end without adding anything.
    func rejectGroup() {
        guard round == .isThisYou else {
            Task { await save() }
            return
        }
        offerIndex += 1
        if offerIndex < offers.count {
            presentOffer()
        } else {
            refineTask?.cancel()
            candidates = []
            phase = confirmed.isEmpty ? .nothingFound : .saving
            if !confirmed.isEmpty { Task { await save() } }
        }
    }

    /// "Skip" on the "Also you?" round.
    func skipAlsoYou() {
        Task { await save() }
    }

    // MARK: - Re-embed at the scan's resolution

    private func startRefining(_ ids: [Int]) {
        refineTask?.cancel()
        let targets = ids.filter { refined[$0] == nil }.map { (id: $0, face: faces[$0]) }
        guard !targets.isEmpty else { return }
        let manager = imageManager
        refineTask = Task { [weak self] in
            for t in targets {
                if Task.isCancelled { return }
                let emb = await LibraryFaceScanner.refinedEmbedding(assetId: t.face.assetId, box: t.face.box,
                                                                    expected: t.face.embedding, manager: manager)
                if let emb { self?.refined[t.id] = emb }
            }
        }
    }

    private func save() async {
        phase = .saving
        candidates = []
        refineTask?.cancel()
        await refineTask?.value
        refineTask = nil

        // Finish re-embedding what the user confirmed, within a short budget. Anything left keeps
        // its thumbnail embedding, which is still a confirmed face of the user.
        let deadline = Date().addingTimeInterval(8)
        for id in confirmed where refined[id] == nil {
            if Date() > deadline { break }
            let f = faces[id]
            if let e = await LibraryFaceScanner.refinedEmbedding(assetId: f.assetId, box: f.box,
                                                                 expected: f.embedding, manager: imageManager) {
                refined[id] = e
            }
        }
        let embeddings = confirmed.map { refined[$0] ?? faces[$0].embedding }
        let refinedCount = confirmed.filter { refined[$0] != nil }.count
        let uid = userId
        let added = await IdentityWorker.shared.run { () -> Int in
            let current = FaceMatchingService.shared.loadReference(forUser: uid) ? FaceMatchingService.shared.referenceCount : 0
            // Leave room for faces the scan learns, but always add a solid set: when a re-run
            // finds the gallery full, the oldest learned faces make way (selfie anchors stay).
            let room = min(48, max(20, FaceMatchingService.galleryCap - 2 - current))
            let picks = FaceClustering.galleryPicks(embeddings, maxCount: room)
            return FaceMatchingService.shared.addReferenceEmbeddings(picks, forUser: uid)
        }
        confirmedCount = confirmed.count
        addedCount = added
        dlog("[FindYou] Saved: \(confirmed.count) confirmed (\(refinedCount) re-embedded at \(Int(LibraryFaceScanner.refineSide))px), \(added) added to the gallery")
        phase = .finished
    }

    // MARK: - Limited access

    func shareMorePhotos() {
        let uid = userId
        LibraryFaceScanner.presentLimitedLibraryPicker { [weak self] in
            Task { @MainActor in await self?.scan(forUser: uid) }
        }
    }
}
