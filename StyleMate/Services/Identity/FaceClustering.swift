import Foundation
import Accelerate

// MARK: - Vector helpers

/// Helpers for L2-normalized face embeddings, where cosine similarity is a dot product.
enum FaceMath {
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
        return r
    }

    static func normalized(_ v: [Float]) -> [Float] {
        guard !v.isEmpty else { return v }
        var sq: Float = 0
        vDSP_svesq(v, 1, &sq, vDSP_Length(v.count))
        var norm = sqrt(sq)
        guard norm > 1e-8 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsdiv(v, 1, &norm, &out, 1, vDSP_Length(v.count))
        return out
    }

    /// Adds `v` into `sum` element-wise (sizes must match).
    static func accumulate(_ sum: inout [Float], _ v: [Float]) {
        guard sum.count == v.count else { return }
        for i in 0..<sum.count { sum[i] += v[i] }
    }

    /// Normalized mean direction of a set of embeddings. Empty in, empty out.
    static func centroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for v in vectors { accumulate(&sum, v) }
        return normalized(sum)
    }

    /// Best similarity of `v` against any of `refs`; -1 when there are no refs.
    static func maxSimilarity(_ v: [Float], to refs: [[Float]]) -> Float {
        var best: Float = -1
        for r in refs { best = max(best, dot(v, r)) }
        return best
    }
}

// MARK: - Clusters

/// A group of library faces that look like the same person.
struct FaceCluster: Equatable {
    /// Indices into the face list that was clustered, most central first.
    var members: [Int]
    /// Normalized mean embedding of the members.
    var centroid: [Float]

    var size: Int { members.count }
}

/// A cluster with its "is this the user?" score.
struct RankedCluster: Equatable {
    let cluster: FaceCluster
    /// Centroid similarity to the closest selfie anchor; nil when there's no selfie.
    let anchorSimilarity: Float?
    /// Fraction of members that came from the Selfies album (a prior for "this is the owner").
    let selfieAlbumFraction: Float
    let score: Float
}

/// One face to show in an "Is this you?" grid.
struct ReviewPick: Equatable {
    let face: Int
    /// How sure we are this face belongs with the rest (centroid / reference similarity).
    let confidence: Float
    /// Pre-checked in the grid. Unsure faces are shown unchecked so a single tap confirms only good ones.
    let preselected: Bool
}

/// Pure clustering + ranking for the onboarding "Find yourself" step. No PhotoKit, no Core ML:
/// everything here works on embeddings so it is unit-tested with synthetic vectors.
///
/// AdaFace (SCRFD-aligned) calibration this is tuned against: same person 0.6–0.99 for similar
/// shots, 0.30–0.55 across pose / light / sunglasses; different people ~0.03 (max ~0.18).
/// Similarity to the normalized centroid of many same-person faces runs higher than pairwise
/// similarity (roughly its square root), which is why centroid bars sit above pairwise ones.
enum FaceClustering {
    /// A face joins a cluster when its similarity to the cluster centroid reaches this.
    static let linkThreshold: Float = 0.5
    /// Clusters smaller than this are noise (one-off strangers) and are never offered.
    static let minClusterSize = 2
    /// With a selfie, a cluster must resemble it at least this much to be offered as "you".
    /// Strangers' centroids sit near 0.05; the user's own cluster well above 0.3.
    static let offerFloor: Float = 0.15
    /// Most "Is this you?" groups we'll offer before giving up.
    static let maxOffers = 3
    /// A member closer than this to its own cluster centroid is pre-checked.
    static let preselectThreshold: Float = 0.40
    /// "Also you?" thresholds against the confirmed faces.
    static let alsoYouClusterThreshold: Float = 0.40
    static let alsoYouMemberThreshold: Float = 0.30
    static let alsoYouSingleThreshold: Float = 0.45
    static let alsoYouPreselect: Float = 0.50
    /// Merge pass only considers the largest multi-face clusters (keeps it cheap on big libraries).
    private static let mergeCandidateLimit = 300

    // MARK: Cluster

    /// Greedy centroid clustering in quality order, then a merge pass and one reassignment pass.
    /// Two faces from the same photo are never put in the same cluster (they are different people).
    static func cluster(embeddings: [[Float]], qualities: [Float], assetIds: [String],
                        threshold: Float = linkThreshold) -> [FaceCluster] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        let quality: (Int) -> Float = { qualities.indices.contains($0) ? qualities[$0] : 0 }
        let asset: (Int) -> String = { assetIds.indices.contains($0) ? assetIds[$0] : "face-\($0)" }

        var sums: [[Float]] = []
        var centroids: [[Float]] = []
        var members: [[Int]] = []
        var assets: [Set<String>] = []

        // 1. Leader pass: best faces seed clusters, so a blurry face can't define a person.
        let order = (0..<n).sorted { a, b in
            let qa = quality(a), qb = quality(b)
            return qa != qb ? qa > qb : a < b
        }
        for i in order {
            let e = embeddings[i]
            var best = -1
            var bestSim: Float = -.infinity
            for c in centroids.indices where !assets[c].contains(asset(i)) {
                let s = FaceMath.dot(e, centroids[c])
                if s > bestSim { bestSim = s; best = c }
            }
            if best >= 0, bestSim >= threshold {
                FaceMath.accumulate(&sums[best], e)
                centroids[best] = FaceMath.normalized(sums[best])
                members[best].append(i)
                assets[best].insert(asset(i))
            } else {
                sums.append(e)
                centroids.append(FaceMath.normalized(e))
                members.append([i])
                assets.append([asset(i)])
            }
        }

        // 2. Merge pass: early seeds of the same person can end up as two clusters whose
        //    centroids converge once both have grown. Merge the closest pair until none qualify.
        var alive = Array(repeating: true, count: centroids.count)
        let candidates = members.indices
            .filter { members[$0].count >= 2 }
            .sorted { members[$0].count > members[$1].count }
            .prefix(mergeCandidateLimit)
        let pool = Array(candidates)
        while true {
            var pair: (Int, Int)?
            var pairSim = threshold
            for x in 0..<pool.count {
                let a = pool[x]
                guard alive[a] else { continue }
                for y in (x + 1)..<pool.count {
                    let b = pool[y]
                    guard alive[b], assets[a].isDisjoint(with: assets[b]) else { continue }
                    let s = FaceMath.dot(centroids[a], centroids[b])
                    if s >= pairSim { pairSim = s; pair = (a, b) }
                }
            }
            guard let best = pair else { break }
            let (a, b) = best
            FaceMath.accumulate(&sums[a], sums[b])
            centroids[a] = FaceMath.normalized(sums[a])
            members[a].append(contentsOf: members[b])
            assets[a].formUnion(assets[b])
            members[b] = []
            assets[b] = []
            alive[b] = false
        }

        // 3. Reassignment: a face that matured clusters now fit better moves once. This is what
        //    pulls early singletons into the person they belong to.
        var owner = [Int](repeating: -1, count: n)
        for c in members.indices where alive[c] { for i in members[c] { owner[i] = c } }
        let targets = members.indices.filter { alive[$0] && members[$0].count >= 2 }
        var moved = false
        for i in 0..<n {
            let cur = owner[i]
            guard cur >= 0 else { continue }
            let curSim = FaceMath.dot(embeddings[i], centroids[cur])
            var best = cur
            var bestSim = curSim
            for c in targets where c != cur && !assets[c].contains(asset(i)) {
                let s = FaceMath.dot(embeddings[i], centroids[c])
                if s >= threshold, s > bestSim + 0.03 { best = c; bestSim = s }
            }
            if best != cur {
                members[cur].removeAll { $0 == i }
                if !members[cur].contains(where: { asset($0) == asset(i) }) { assets[cur].remove(asset(i)) }
                members[best].append(i)
                assets[best].insert(asset(i))
                owner[i] = best
                moved = true
            }
        }

        // 4. Final centroids, members most-central first, biggest clusters first.
        var out: [FaceCluster] = []
        for c in members.indices where alive[c] && !members[c].isEmpty {
            let cent = moved ? FaceMath.centroid(members[c].map { embeddings[$0] }) : centroids[c]
            let sorted = members[c].sorted { a, b in
                let sa = FaceMath.dot(embeddings[a], cent), sb = FaceMath.dot(embeddings[b], cent)
                return sa != sb ? sa > sb : a < b
            }
            out.append(FaceCluster(members: sorted, centroid: cent))
        }
        out.sort { $0.size != $1.size ? $0.size > $1.size : ($0.members.first ?? 0) < ($1.members.first ?? 0) }
        return out
    }

    // MARK: Rank

    /// Orders clusters by how likely they are to be the user.
    /// - With selfie anchors: resemblance to the selfie dominates; size and Selfies-album share only break ties.
    /// - Without (selfie skipped): the most frequent face in your own library, boosted by the Selfies album.
    static func rank(_ clusters: [FaceCluster], anchors: [[Float]], fromSelfieAlbum: [Bool] = [],
                     minSize: Int = minClusterSize) -> [RankedCluster] {
        let ranked: [RankedCluster] = clusters.compactMap { (c: FaceCluster) -> RankedCluster? in
            guard c.size >= minSize else { return nil }
            let selfieShare = c.members.isEmpty ? 0 :
                Float(c.members.filter { fromSelfieAlbum.indices.contains($0) && fromSelfieAlbum[$0] }.count) / Float(c.size)
            let sizeTerm = log2(Float(c.size) + 1)
            if anchors.isEmpty {
                return RankedCluster(cluster: c, anchorSimilarity: nil, selfieAlbumFraction: selfieShare,
                                     score: sizeTerm + 2 * selfieShare)
            }
            let anchorSim = FaceMath.maxSimilarity(c.centroid, to: anchors)
            return RankedCluster(cluster: c, anchorSimilarity: anchorSim, selfieAlbumFraction: selfieShare,
                                 score: anchorSim + 0.02 * sizeTerm + 0.05 * selfieShare)
        }
        return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.cluster.size > $1.cluster.size }
    }

    /// The groups worth asking "Is this you?" about, best first.
    static func offers(from ranked: [RankedCluster], limit: Int = maxOffers) -> [RankedCluster] {
        Array(ranked.filter { r in
            guard let s = r.anchorSimilarity else { return true }
            return s >= offerFloor
        }.prefix(limit))
    }

    // MARK: Review grid

    /// Picks up to `limit` faces of a cluster for the grid: one per photo, a diverse spread of the
    /// confident members first (pre-checked), then the doubtful ones last and unchecked.
    static func reviewPicks(for cluster: FaceCluster, embeddings: [[Float]], assetIds: [String],
                            limit: Int) -> [ReviewPick] {
        guard limit > 0 else { return [] }
        var bestPerAsset: [String: (face: Int, conf: Float)] = [:]
        for m in cluster.members where embeddings.indices.contains(m) {
            let conf = FaceMath.dot(embeddings[m], cluster.centroid)
            let key = assetIds.indices.contains(m) ? assetIds[m] : "face-\(m)"
            if let cur = bestPerAsset[key], cur.conf >= conf { continue }
            bestPerAsset[key] = (m, conf)
        }
        let all = bestPerAsset.values.sorted { $0.conf != $1.conf ? $0.conf > $1.conf : $0.face < $1.face }
        let confident = all.filter { $0.conf >= preselectThreshold }
        let doubtful = all.filter { $0.conf < preselectThreshold }

        let doubtfulRoom = min(doubtful.count, max(limit / 4, limit - confident.count))
        let confidentRoom = max(0, limit - doubtfulRoom)
        let spread = diverseSubset(confident.map(\.face), embeddings: embeddings, k: confidentRoom)
        let conf = Dictionary(uniqueKeysWithValues: all.map { ($0.face, $0.conf) })

        var picks = spread.map { ReviewPick(face: $0, confidence: conf[$0] ?? 0, preselected: true) }
        for d in doubtful.prefix(max(0, limit - picks.count)) {
            picks.append(ReviewPick(face: d.face, confidence: d.conf, preselected: false))
        }
        return picks
    }

    /// Farthest-point sampling: starts from the first candidate (pass them most-central first),
    /// then repeatedly takes the face least like anything already taken. Covers angles, light and
    /// looks instead of 15 copies of the same selfie.
    static func diverseSubset(_ candidates: [Int], embeddings: [[Float]], k: Int) -> [Int] {
        guard k > 0, !candidates.isEmpty else { return [] }
        if candidates.count <= k { return candidates }
        var chosen = [candidates[0]]
        var taken = Set([0])
        var closest = candidates.map { FaceMath.dot(embeddings[$0], embeddings[candidates[0]]) }
        while chosen.count < k {
            var pick = -1
            var lowest: Float = .infinity
            for p in candidates.indices where !taken.contains(p) && closest[p] < lowest {
                lowest = closest[p]
                pick = p
            }
            guard pick >= 0 else { break }
            taken.insert(pick)
            chosen.append(candidates[pick])
            let e = embeddings[candidates[pick]]
            for p in candidates.indices where !taken.contains(p) {
                closest[p] = max(closest[p], FaceMath.dot(embeddings[candidates[p]], e))
            }
        }
        return chosen
    }

    // MARK: Also you?

    /// After the user confirms their main group: other faces that match what they confirmed —
    /// typically the same person with sunglasses, in profile, or years apart, which the first
    /// cluster's bar split off. Whole clusters close to the confirmed centroid come in, plus
    /// stray single faces that are individually close.
    static func alsoYouPicks(confirmed: [[Float]], anchors: [[Float]], clusters: [FaceCluster],
                             embeddings: [[Float]], assetIds: [String],
                             excludeFaces: Set<Int>, excludeAssets: Set<String>, limit: Int) -> [ReviewPick] {
        guard limit > 0, !confirmed.isEmpty else { return [] }
        let reference = FaceMath.centroid(confirmed)
        func score(_ i: Int) -> Float {
            max(FaceMath.dot(embeddings[i], reference), FaceMath.maxSimilarity(embeddings[i], to: anchors))
        }
        var scored: [Int: Float] = [:]
        for c in clusters {
            let fresh = c.members.filter { !excludeFaces.contains($0) }
            guard !fresh.isEmpty else { continue }
            let clusterClose = c.size >= minClusterSize && FaceMath.dot(c.centroid, reference) >= alsoYouClusterThreshold
            for m in fresh where embeddings.indices.contains(m) {
                let s = score(m)
                if (clusterClose && s >= alsoYouMemberThreshold) || s >= alsoYouSingleThreshold {
                    scored[m] = s
                }
            }
        }
        var bestPerAsset: [String: (face: Int, score: Float)] = [:]
        for (face, s) in scored {
            let key = assetIds.indices.contains(face) ? assetIds[face] : "face-\(face)"
            guard !excludeAssets.contains(key) else { continue }
            if let cur = bestPerAsset[key], cur.score > s || (cur.score == s && cur.face < face) { continue }
            bestPerAsset[key] = (face, s)
        }
        return bestPerAsset.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.face < $1.face }
            .prefix(limit)
            .map { ReviewPick(face: $0.face, confidence: $0.score, preselected: $0.score >= alsoYouPreselect) }
    }

    // MARK: Gallery

    /// Which confirmed embeddings to add to the reference gallery: a diverse spread, most
    /// central first, capped so the gallery keeps room for faces learned during the scan.
    static func galleryPicks(_ confirmed: [[Float]], maxCount: Int) -> [[Float]] {
        guard maxCount > 0, !confirmed.isEmpty else { return [] }
        let center = FaceMath.centroid(confirmed)
        let order = confirmed.indices.sorted { a, b in
            let sa = FaceMath.dot(confirmed[a], center), sb = FaceMath.dot(confirmed[b], center)
            return sa != sb ? sa > sb : a < b
        }
        return diverseSubset(order, embeddings: confirmed, k: maxCount).map { confirmed[$0] }
    }
}
