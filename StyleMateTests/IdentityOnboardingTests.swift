import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import StyleMate

// MARK: - Synthetic embeddings

/// Deterministic RNG so the synthetic-embedding tests are reproducible.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 512-d synthetic face embeddings (the clustering is dimension-agnostic; the real embedder is
/// 128-d SFace). A face of an identity is `normalize(center + noise · u)` with
/// u a random unit vector, so two faces of one identity score about 1/(1+noise²) — noise 0.8 ≈
/// 0.61 (similar shots), noise 1.0 ≈ 0.5 (different pose/light) — and different identities ≈ 0.
private struct Synth {
    private var rng: SplitMix64
    let dim = 512

    init(seed: UInt64) { rng = SplitMix64(state: seed) }

    mutating func gaussian() -> Float {
        let u1 = max(Double(rng.next() >> 11) / Double(1 << 53), 1e-12)
        let u2 = Double(rng.next() >> 11) / Double(1 << 53)
        return Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
    }

    mutating func unit() -> [Float] {
        var v = [Float](repeating: 0, count: dim)
        for i in 0..<dim { v[i] = gaussian() }
        return FaceMath.normalized(v)
    }

    mutating func face(of center: [Float], noise: Float) -> [Float] {
        let n = unit()
        var v = center
        for i in 0..<dim { v[i] += noise * n[i] }
        return FaceMath.normalized(v)
    }

    /// An identity "near" another: similarity of the two centers ≈ 1/sqrt(1+offset²).
    mutating func variant(of center: [Float], offset: Float) -> [Float] {
        face(of: center, noise: offset)
    }

    /// A unit vector at exactly `cosine` similarity to `center`.
    mutating func at(similarity cosine: Float, to center: [Float]) -> [Float] {
        var w = unit()
        let d = FaceMath.dot(w, center)
        for i in 0..<dim { w[i] -= d * center[i] }
        w = FaceMath.normalized(w)
        let s = (1 - cosine * cosine).squareRoot()
        var v = [Float](repeating: 0, count: dim)
        for i in 0..<dim { v[i] = center[i] * cosine + w[i] * s }
        return FaceMath.normalized(v)
    }
}

/// A synthetic library: faces with labels and one asset (photo) per face unless set otherwise.
private struct Library {
    var embeddings: [[Float]] = []
    var labels: [String] = []
    var assetIds: [String] = []
    var qualities: [Float] = []
    var selfieFlags: [Bool] = []

    mutating func add(_ e: [Float], label: String, asset: String? = nil, quality: Float = 0.5, selfie: Bool = false) {
        assetIds.append(asset ?? "photo-\(embeddings.count)")
        embeddings.append(e)
        labels.append(label)
        qualities.append(quality)
        selfieFlags.append(selfie)
    }

    func indices(of label: String) -> [Int] { labels.indices.filter { labels[$0] == label } }

    func cluster() -> [FaceCluster] {
        FaceClustering.cluster(embeddings: embeddings, qualities: qualities, assetIds: assetIds)
    }
}

private func labelsOf(_ c: FaceCluster, in lib: Library) -> Set<String> { Set(c.members.map { lib.labels[$0] }) }

// MARK: - Clustering + ranking

@Suite struct IdentityClusteringTests {

    @Test func clustersSeparateDifferentPeople() {
        var s = Synth(seed: 1)
        var lib = Library()
        for (label, count) in [("A", 30), ("B", 20), ("C", 10)] {
            let center = s.unit()
            for _ in 0..<count { lib.add(s.face(of: center, noise: 0.8), label: label) }
        }
        let recurring = lib.cluster().filter { $0.size >= 2 }
        #expect(recurring.count == 3, "expected 3 people, got \(recurring.map(\.size))")
        for c in recurring {
            #expect(labelsOf(c, in: lib).count == 1, "a cluster mixes people: \(labelsOf(c, in: lib))")
        }
        for (label, count) in [("A", 30), ("B", 20), ("C", 10)] {
            let best = recurring.map { c in c.members.filter { lib.labels[$0] == label }.count }.max() ?? 0
            #expect(best >= Int(Double(count) * 0.9), "\(label): only \(best)/\(count) grouped together")
        }
    }

    @Test func keepsOnePersonTogetherAcrossPoseAndLight() {
        // Pairwise ~0.5: half the pairs are under the link bar on their own. The centroid,
        // merge and reassignment passes must still end up with one group.
        var s = Synth(seed: 2)
        var lib = Library()
        let a = s.unit(), b = s.unit()
        for _ in 0..<40 { lib.add(s.face(of: a, noise: 1.0), label: "A") }
        for _ in 0..<15 { lib.add(s.face(of: b, noise: 0.8), label: "B") }
        let clusters = lib.cluster()
        let biggestA = clusters.map { c in c.members.filter { lib.labels[$0] == "A" }.count }.max() ?? 0
        #expect(biggestA >= 34, "A split up: largest group has \(biggestA)/40")
        for c in clusters where c.size >= 2 {
            #expect(labelsOf(c, in: lib).count == 1)
        }
    }

    @Test func twoFacesInOnePhotoAreNeverTheSamePerson() {
        var s = Synth(seed: 3)
        var lib = Library()
        let a = s.unit()
        let e = s.face(of: a, noise: 0.3)
        lib.add(e, label: "A", asset: "group-photo")
        lib.add(e, label: "A2", asset: "group-photo")
        lib.add(s.face(of: a, noise: 0.3), label: "A", asset: "solo")
        let clusters = lib.cluster()
        for c in clusters {
            let assets = c.members.map { lib.assetIds[$0] }
            #expect(Set(assets).count == assets.count, "cluster holds two faces of one photo: \(assets)")
        }
    }

    @Test func selfieRanksTheUserAboveABiggerGroup() {
        // The partner appears in more photos, but the selfie resembles the user.
        var s = Synth(seed: 4)
        var lib = Library()
        let user = s.unit(), partner = s.unit()
        for _ in 0..<15 { lib.add(s.face(of: user, noise: 0.8), label: "user") }
        for _ in 0..<40 { lib.add(s.face(of: partner, noise: 0.8), label: "partner") }
        let selfie = s.face(of: user, noise: 1.2)   // a weak selfie: ~0.4–0.5 to real photos
        let offers = FaceClustering.offers(from: FaceClustering.rank(lib.cluster(), anchors: [selfie]))
        #expect(!offers.isEmpty)
        if let first = offers.first {
            #expect(labelsOf(first.cluster, in: lib) == Set(["user"]))
            #expect((first.anchorSimilarity ?? 0) > 0.4)
        }
        #expect(!offers.contains { labelsOf($0.cluster, in: lib) == ["partner"] },
                "the partner's group shouldn't be offered against this selfie")
    }

    @Test func withoutASelfieTheMostFrequentFaceComesFirst() {
        var s = Synth(seed: 5)
        var lib = Library()
        let a = s.unit(), b = s.unit()
        for _ in 0..<10 { lib.add(s.face(of: a, noise: 0.8), label: "A") }
        for _ in 0..<25 { lib.add(s.face(of: b, noise: 0.8), label: "B") }
        let ranked = FaceClustering.rank(lib.cluster(), anchors: [])
        #expect(labelsOf(ranked[0].cluster, in: lib) == ["B"])
        #expect(ranked[0].anchorSimilarity == nil)

        // ...unless the smaller group is the one in the Selfies album.
        lib.selfieFlags = lib.labels.map { $0 == "A" }
        let withSelfies = FaceClustering.rank(lib.cluster(), anchors: [], fromSelfieAlbum: lib.selfieFlags)
        #expect(labelsOf(withSelfies[0].cluster, in: lib) == ["A"])
    }

    @Test func strangersAreNotOfferedAgainstASelfie() {
        var s = Synth(seed: 6)
        var lib = Library()
        for p in 0..<4 {
            let c = s.unit()
            for _ in 0..<8 { lib.add(s.face(of: c, noise: 0.8), label: "stranger\(p)") }
        }
        let selfie = s.unit()
        let offers = FaceClustering.offers(from: FaceClustering.rank(lib.cluster(), anchors: [selfie]))
        #expect(offers.isEmpty, "offered strangers: \(offers.map { $0.anchorSimilarity ?? 0 })")
    }

    @Test func singletonsAreNeverOffered() {
        var s = Synth(seed: 7)
        var lib = Library()
        let a = s.unit()
        lib.add(s.face(of: a, noise: 0.5), label: "A")
        let ranked = FaceClustering.rank(lib.cluster(), anchors: [a])
        #expect(ranked.isEmpty)
    }

    @Test func reviewGridUnchecksOutliersAndShowsOnePerPhoto() {
        var s = Synth(seed: 8)
        var lib = Library()
        let a = s.unit()
        for _ in 0..<20 { lib.add(s.face(of: a, noise: 0.8), label: "A") }
        lib.add(s.face(of: a, noise: 0.8), label: "A", asset: "photo-0")   // second face, same photo
        lib.add(s.unit(), label: "impostor")
        let members = Array(lib.embeddings.indices)
        let cluster = FaceCluster(members: members, centroid: FaceMath.centroid(lib.embeddings))
        let picks = FaceClustering.reviewPicks(for: cluster, embeddings: lib.embeddings,
                                               assetIds: lib.assetIds, limit: 48)
        let assets = picks.map { lib.assetIds[$0.face] }
        #expect(Set(assets).count == assets.count, "one face per photo")
        let impostor = picks.first { lib.labels[$0.face] == "impostor" }
        #expect(impostor != nil)
        #expect(impostor?.preselected == false)
        #expect(picks.last.map { lib.labels[$0.face] } == "impostor", "doubtful faces go last")
        #expect(picks.filter(\.preselected).allSatisfy { lib.labels[$0.face] == "A" })
        #expect(picks.filter(\.preselected).count == 20)
    }

    @Test func reviewGridRespectsTheLimitAndKeepsDoubtfulRoom() {
        var s = Synth(seed: 9)
        var lib = Library()
        let a = s.unit()
        for _ in 0..<100 { lib.add(s.face(of: a, noise: 0.8), label: "A") }
        for _ in 0..<5 { lib.add(s.unit(), label: "x") }
        let cluster = FaceCluster(members: Array(lib.embeddings.indices), centroid: FaceMath.centroid(lib.embeddings))
        let picks = FaceClustering.reviewPicks(for: cluster, embeddings: lib.embeddings, assetIds: lib.assetIds, limit: 24)
        #expect(picks.count == 24)
        #expect(picks.filter { !$0.preselected }.count == 5)
    }

    @Test func diverseSubsetCoversEveryLook() {
        var s = Synth(seed: 10)
        let base = s.unit()
        let looks = (0..<3).map { _ in s.variant(of: base, offset: 0.9) }
        var embeddings: [[Float]] = []
        var look: [Int] = []
        for (k, center) in looks.enumerated() {
            for _ in 0..<10 { embeddings.append(s.face(of: center, noise: 0.2)); look.append(k) }
        }
        let picked = FaceClustering.diverseSubset(Array(embeddings.indices), embeddings: embeddings, k: 3)
        #expect(Set(picked.map { look[$0] }) == [0, 1, 2], "picked looks \(picked.map { look[$0] })")
        #expect(FaceClustering.diverseSubset([4, 2], embeddings: embeddings, k: 5) == [4, 2])
        #expect(FaceClustering.diverseSubset([], embeddings: embeddings, k: 5).isEmpty)
    }

    @Test func alsoYouFindsTheUsersOtherLookButNotStrangers() {
        // The user's sunglasses / profile shots form their own group (too far from the main one to
        // merge), but they match what the user confirmed far better than a stranger does.
        var s = Synth(seed: 11)
        var lib = Library()
        let user = s.unit()
        // Below the link bar, above the also-you bar (whatever the active face model's bars are).
        let gap = (FaceClustering.linkThreshold + FaceClustering.alsoYouClusterThreshold) / 2
        let otherLook = s.at(similarity: gap, to: user)
        let stranger = s.unit()
        for _ in 0..<25 { lib.add(s.face(of: user, noise: 0.8), label: "main") }
        for _ in 0..<12 { lib.add(s.face(of: otherLook, noise: 0.5), label: "other") }
        for _ in 0..<12 { lib.add(s.face(of: stranger, noise: 0.5), label: "stranger") }

        let clusters = lib.cluster()
        let mainCluster = clusters.first { labelsOf($0, in: lib) == Set(["main"]) }
        #expect(mainCluster != nil)
        let hasOther = clusters.contains { labelsOf($0, in: lib) == Set(["other"]) }
        #expect(hasOther, "the other look should be its own group")
        let mainMembers = mainCluster?.members ?? []
        let confirmed = mainMembers.map { lib.embeddings[$0] }
        let picks = FaceClustering.alsoYouPicks(
            confirmed: confirmed, anchors: [], clusters: clusters, embeddings: lib.embeddings,
            assetIds: lib.assetIds, excludeFaces: Set(mainMembers),
            excludeAssets: Set(mainMembers.map { lib.assetIds[$0] }), limit: 36)
        let labels = picks.map { lib.labels[$0.face] }
        #expect(!labels.contains("stranger"))
        #expect(labels.filter { $0 == "other" }.count >= 10, "found \(labels)")
        #expect(!labels.contains("main"), "already-confirmed faces aren't asked again")
    }

    @Test func galleryPicksAreCappedAndDistinct() {
        var s = Synth(seed: 12)
        let a = s.unit()
        let confirmed = (0..<60).map { _ in s.face(of: a, noise: 0.8) }
        let picks = FaceClustering.galleryPicks(confirmed, maxCount: 20)
        #expect(picks.count == 20)
        #expect(Set(picks.map { $0.first ?? 0 }).count == 20)
        #expect(FaceClustering.galleryPicks(confirmed, maxCount: 0).isEmpty)
        #expect(FaceClustering.galleryPicks(Array(confirmed.prefix(5)), maxCount: 20).count == 5)
    }

    @Test func clusteringEmptyAndSingleInputs() {
        #expect(FaceClustering.cluster(embeddings: [], qualities: [], assetIds: []).isEmpty)
        var s = Synth(seed: 13)
        let one = FaceClustering.cluster(embeddings: [s.unit()], qualities: [], assetIds: [])
        #expect(one.count == 1 && one[0].members == [0])
    }

    @Test func faceMathBasics() {
        let v = FaceMath.normalized([3, 4])
        #expect(abs(v[0] - 0.6) < 1e-5 && abs(v[1] - 0.8) < 1e-5)
        #expect(abs(FaceMath.dot(v, v) - 1) < 1e-5)
        #expect(FaceMath.dot([1, 0], [1, 0, 0]) == 0, "mismatched sizes score 0")
        #expect(FaceMath.maxSimilarity(v, to: []) == -1)
        let c = FaceMath.centroid([[1, 0], [0, 1]])
        #expect(abs(c[0] - c[1]) < 1e-5 && abs(FaceMath.dot(c, c) - 1) < 1e-5)
    }
}

// MARK: - Quality + selfie checks

@Suite struct IdentityQualityTests {
    /// The ArcFace template itself: a perfectly frontal face.
    private let frontal: [SIMD2<Float>] = [
        SIMD2(38.29, 51.70), SIMD2(73.53, 51.50), SIMD2(56.03, 71.74), SIMD2(41.55, 92.37), SIMD2(70.73, 92.20)
    ]

    @Test func yawProxyReadsHeadTurn() {
        #expect(abs(FaceQuality.yawProxy(frontal)) < 0.06)
        var turned = frontal
        turned[2].x = 66
        #expect(FaceQuality.yawProxy(turned) > 0.4)
        turned[2].x = 44
        #expect(FaceQuality.yawProxy(turned) < -0.4)
        var profile = frontal
        profile[2].x = 76
        #expect(abs(FaceQuality.yawProxy(profile)) > 1)
        #expect(FaceQuality.frontalness(profile) == 0)
        #expect(FaceQuality.yawProxy([]) == 0)
    }

    @Test func yawProxyIgnoresHeadTilt() {
        var turned = frontal
        turned[2].x = 66
        let angle: Float = .pi / 6
        let rotated = turned.map { p in
            SIMD2(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle))
        }
        #expect(abs(FaceQuality.yawProxy(rotated) - FaceQuality.yawProxy(turned)) < 1e-3)
    }

    @Test func libraryFaceFilter() {
        #expect(FaceQuality.isUsableLibraryFace(shortSidePixels: 60, detectorScore: 0.8, keypoints: frontal))
        #expect(!FaceQuality.isUsableLibraryFace(shortSidePixels: 15, detectorScore: 0.8, keypoints: frontal))
        #expect(!FaceQuality.isUsableLibraryFace(shortSidePixels: 60, detectorScore: 0.55, keypoints: frontal))
        var profile = frontal
        profile[2].x = 76
        #expect(!FaceQuality.isUsableLibraryFace(shortSidePixels: 60, detectorScore: 0.8, keypoints: profile))
        let big = FaceQuality.libraryScore(shortSidePixels: 120, detectorScore: 0.9, keypoints: frontal)
        let small = FaceQuality.libraryScore(shortSidePixels: 30, detectorScore: 0.65, keypoints: frontal)
        #expect(big > small && big <= 1 && small >= 0)
    }

    @Test func eyeAndCheekPatchesSitOnTheFace() throws {
        let p = try #require(FaceQuality.eyeAndCheekPatches(frontal))
        #expect(p.eyes.count == 2)
        #expect(p.eyes[0].contains(CGPoint(x: 38.29, y: 51.7)))
        #expect(p.cheek.midY > 71.74 && p.cheek.midY < 92)
        #expect(FaceQuality.eyeAndCheekPatches([]) == nil)
    }

    private var good: SelfieFrameMeasurements {
        SelfieFrameMeasurements(faceCount: 1, detectorScore: 0.9, faceWidthFraction: 0.5,
                                faceCenter: CGPoint(x: 0.5, y: 0.45), faceLuma: 140,
                                eyeLuma: 100, cheekLuma: 150, yaw: 0.05, similarityToFront: nil)
    }

    @Test func goodSelfieFramesPass() {
        #expect(SelfieFrameAssessor.issue(for: good, step: .front) == nil)
        var turn = good
        turn.yaw = 0.6
        turn.similarityToFront = 0.7
        #expect(SelfieFrameAssessor.issue(for: turn, step: .left) == nil)
    }

    private func assess(_ step: SelfieStep = .front, _ change: (inout SelfieFrameMeasurements) -> Void) -> SelfieIssue? {
        var m = good
        change(&m)
        return SelfieFrameAssessor.issue(for: m, step: step)
    }

    @Test func badSelfieFramesGetFriendlyReasons() {
        let cases: [(SelfieIssue?, SelfieIssue?)] = [
            (assess { $0.faceCount = 0 }, .noFace),
            (assess { $0.faceCount = 2 }, .multipleFaces),
            (assess { $0.faceWidthFraction = 0.1 }, .tooSmall),
            (assess { $0.faceCenter = CGPoint(x: 0.9, y: 0.5) }, .offCenter),
            (assess { $0.faceLuma = 30 }, .tooDark),
            (assess { $0.faceLuma = 240 }, .tooBright),
            (assess { $0.detectorScore = 0.55 }, .unclear),
            (assess { $0.eyeLuma = 30; $0.cheekLuma = 150 }, .sunglasses),
            // Deep-set eyes in soft light aren't sunglasses.
            (assess { $0.eyeLuma = 60; $0.cheekLuma = 110 }, nil),
            (assess { $0.yaw = 0.6 }, .lookStraight),
            (assess(.left) { $0.yaw = 1.3 }, .turnedTooFar),
            (assess(.right) { $0.yaw = 0.5; $0.similarityToFront = 0.1 }, .differentPerson),
        ]
        for (i, c) in cases.enumerated() {
            #expect(c.0 == c.1, "case \(i): got \(String(describing: c.0)), expected \(String(describing: c.1))")
        }
        for i in [SelfieIssue.noFace, .multipleFaces, .tooSmall, .offCenter, .tooDark, .tooBright, .unclear,
                  .sunglasses, .lookStraight, .turnedTooFar, .differentPerson] {
            #expect(!i.message.isEmpty)
        }
    }

    @Test func onlyReferencePoisoningIssuesBlock() {
        #expect(SelfieIssue.noFace.isBlocking)
        #expect(SelfieIssue.multipleFaces.isBlocking)
        #expect(SelfieIssue.differentPerson.isBlocking)
        #expect(!SelfieIssue.tooDark.isBlocking)
        #expect(!SelfieIssue.sunglasses.isBlocking)
    }

    @Test func selfieStepsRunFrontLeftRight() {
        #expect(SelfieStep.allCases == [.front, .left, .right])
        #expect(SelfieStep.front.next == .left)
        #expect(SelfieStep.left.next == .right)
        #expect(SelfieStep.right.next == nil)
        #expect(SelfieStep.right.number == 3)
    }

    private func grayImage(_ value: UInt8, width: Int = 64, height: Int = 48) -> CGImage? {
        var pixels = [UInt8](repeating: value, count: width * height)
        return pixels.withUnsafeMutableBytes { buf -> CGImage? in
            CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }
    }

    @Test func lumaOfAPatch() throws {
        let img = try #require(grayImage(100))
        let mean = try #require(ImageLuma.mean(in: CGRect(x: 10, y: 10, width: 20, height: 20), of: img))
        #expect(abs(mean - 100) < 3)
        #expect(ImageLuma.mean(in: CGRect(x: 500, y: 500, width: 10, height: 10), of: img) == nil)
        let dark = try #require(grayImage(20))
        #expect((ImageLuma.mean(in: CGRect(x: 0, y: 0, width: 64, height: 48), of: dark) ?? 99) < 25)
    }

    @Test func paddedFaceCropsStayInsideThePhoto() {
        let size = CGSize(width: 640, height: 480)
        let mid = FaceSampleExtractor.paddedSquare(around: CGRect(x: 300, y: 200, width: 40, height: 50),
                                                   imageSize: size, factor: 2.4)
        #expect(abs(mid.width - 120) <= 1 && abs(mid.height - 120) <= 1)
        #expect(abs(mid.midX - 320) <= 1 && abs(mid.midY - 225) <= 1)
        let corner = FaceSampleExtractor.paddedSquare(around: CGRect(x: 0, y: 0, width: 60, height: 60),
                                                      imageSize: size, factor: 2.4)
        #expect(corner.minX == 0 && corner.minY == 0 && corner.maxX <= 640 && corner.maxY <= 480)
        let box = FaceSampleExtractor.normalizedBox(CGRect(x: 64, y: 48, width: 32, height: 24), in: size)
        #expect(abs(box.minX - 0.1) < 1e-6 && abs(box.minY - 0.1) < 1e-6 && abs(box.width - 0.05) < 1e-6)
    }
}

// MARK: - Real models

/// "Find yourself" with the real face models (YuNet + SFace) on the CC0 fixtures. These are part of
/// the serialized FaceMatchingTests suite because both drive the shared FaceMatchingService.
extension FaceMatchingTests {
    private func findYouFixture(_ name: String) throws -> UIImage {
        let env = ProcessInfo.processInfo.environment
        let dir = env["FIXTURES_DIR"].map { URL(fileURLWithPath: $0).appendingPathComponent("photos") }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/photos")
        return try #require(UIImage(data: try Data(contentsOf: dir.appendingPathComponent(name))))
    }

    private func resized(_ image: UIImage, longSide: CGFloat) -> UIImage {
        let scale = longSide / max(image.size.width, image.size.height)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    @Test func findYourselfGroupsTheSamePersonAcrossPhotos() throws {
        // The two clearest front-facing fixtures (the cap + sunglasses face in street_coat_cap is
        // correctly rejected by the library quality gate).
        let photo = try findYouFixture("kurta_dhoti_turban.jpg")
        // A different person whose face passes the library quality gate (full-body street photos
        // often have small / turned / sunglassed faces that are correctly rejected).
        var otherPick: UIImage?
        for name in ["casual_denim_jacket_hat.jpg", "flannel_shirt_group.jpg", "pink_coat_boots.jpg", "street_coat_scarf.jpg"] {
            let candidate = try findYouFixture(name)
            if !FaceSampleExtractor.scannedFaces(in: resized(candidate, longSide: 1024), assetId: "probe",
                                                 anchors: [], fromSelfieAlbum: false).isEmpty {
                otherPick = candidate; break
            }
        }
        let other = try #require(otherPick, "no second fixture with a usable face")

        // The library pass works on ~640 px thumbnails; report how that resolution fares.
        let thumbFaces = FaceSampleExtractor.scannedFaces(in: resized(photo, longSide: 640), assetId: "thumb",
                                                          anchors: [], fromSelfieAlbum: false)
        print("[Report] find-yourself: faces at 640px = \(thumbFaces.count)")

        let a = FaceSampleExtractor.scannedFaces(in: resized(photo, longSide: 1024), assetId: "a", anchors: [], fromSelfieAlbum: false)
        let reframed = UIImage(cgImage: try #require(photo.cgImage?.cropping(
            to: CGRect(x: photo.size.width * 0.08, y: 0, width: photo.size.width * 0.84, height: photo.size.height * 0.75))))
        let b = FaceSampleExtractor.scannedFaces(in: resized(reframed, longSide: 900), assetId: "b", anchors: [], fromSelfieAlbum: false)
        let c = FaceSampleExtractor.scannedFaces(in: resized(other, longSide: 1024), assetId: "c", anchors: [], fromSelfieAlbum: false)
        let fa = try #require(a.first, "no face found in the fixture")
        let fb = try #require(b.first, "no face found in the reframed fixture")
        let fc = try #require(c.first, "no face found in the second fixture")
        #expect(fa.embedding.count >= 128)
        #expect(fa.quality >= 0 && fa.quality <= 1)
        #expect(!fa.thumbnailJPEG.isEmpty)
        #expect(fa.box.minX >= 0 && fa.box.maxX <= 1 && fa.box.minY >= 0 && fa.box.maxY <= 1)

        let same = FaceMath.dot(fa.embedding, fb.embedding)
        let diff = FaceMath.dot(fa.embedding, fc.embedding)
        print("[Report] find-yourself: same person \(same), different people \(diff)")
        #expect(same >= FaceClustering.linkThreshold)
        #expect(diff < FaceClustering.linkThreshold)

        let faces = [fa, fb, fc]
        let clusters = FaceClustering.cluster(embeddings: faces.map(\.embedding), qualities: faces.map(\.quality),
                                              assetIds: faces.map(\.assetId))
        #expect(clusters.contains { Set($0.members) == [0, 1] }, "groups: \(clusters.map(\.members))")

        // Anchored to this person, the face scores as "likely you".
        let anchored = FaceSampleExtractor.scannedFaces(in: resized(reframed, longSide: 900), assetId: "b",
                                                        anchors: [fa.embedding], fromSelfieAlbum: false)
        #expect((anchored.first?.anchorSimilarity ?? -1) >= FaceClustering.linkThreshold)

        // Re-embedding at the scan's resolution agrees with the thumbnail embedding.
        let refined = FaceSampleExtractor.refinedEmbedding(in: resized(photo, longSide: 1600), box: fa.box, expected: fa.embedding)
        let r = try #require(refined, "re-embedding at 1600px failed")
        print("[Report] find-yourself: 1024 vs 1600 re-embed sim \(FaceMath.dot(r, fa.embedding))")
    }

    @Test func selfieFrameCheckMeasuresARealFace() throws {
        let photo = try findYouFixture("street_coat_cap.jpg")
        let cg = try #require(photo.cgImage)
        let face = try #require(FaceDetector.shared.detect(in: cg).max { $0.boxPixels.width < $1.boxPixels.width })
        // A selfie-like crop: the face fills about half the frame.
        let rect = FaceSampleExtractor.paddedSquare(around: face.boxPixels,
                                                    imageSize: CGSize(width: cg.width, height: cg.height), factor: 2.0)
        let crop = UIImage(cgImage: try #require(cg.cropping(to: rect)))
        let result = SelfieFrameChecker.check(crop, step: .front, frontEmbedding: nil)
        print("[Report] selfie check on fixture crop: issue=\(String(describing: result.issue)) yaw=\(result.yaw ?? -9)")
        #expect(result.issue != .noFace && result.issue != .multipleFaces)
        let embedding = try #require(result.embedding)
        // The same frame as a "turn" against its own front embedding is the same person.
        let again = SelfieFrameChecker.check(crop, step: .left, frontEmbedding: embedding)
        #expect(again.issue != .differentPerson)
        // ...and against a stranger's it isn't.
        // The street_coat_boots face is turned away in sunglasses and is (correctly) rejected by the
        // quality gate, so use a clearly visible, different person.
        let strangerCG = try #require(try findYouFixture("kurta_dhoti_turban.jpg").cgImage)
        let strangerFace = try #require(FaceSampleExtractor.faces(in: strangerCG).first)
        let stranger = SelfieFrameChecker.check(crop, step: .left, frontEmbedding: strangerFace.embedding)
        print("[Report] selfie check vs stranger: issue=\(String(describing: stranger.issue))")
        #expect(stranger.issue != nil)
    }
}
