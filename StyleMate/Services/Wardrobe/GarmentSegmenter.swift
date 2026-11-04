import CoreGraphics
import Foundation

/// What kind of item a segmented region is, before fine classification.
enum GarmentKind: String, CaseIterable {
    case innerTop, outerLayer, onePiece, lower, footwear, eyewear, headwear, bag, neckwear, belt, jewelry

    /// FashionVocabulary group used to name the product.
    var vocabularyGroup: String? {
        switch self {
        case .innerTop: return "upper_inner"
        case .outerLayer: return "upper_outer"
        case .onePiece: return "onepiece"
        case .lower: return "lower"
        case .footwear: return "footwear"
        case .eyewear: return "eyewear"
        case .headwear: return "headwear"
        case .bag: return "bag"
        case .neckwear: return "neckwear"
        case .jewelry: return "jewelry"
        case .belt: return nil
        }
    }

    /// Small items get lower minimum-area bars and are never hole-filled.
    var isSmall: Bool { [.eyewear, .jewelry, .belt].contains(self) }
    /// Items that come in mirrored pairs whose two halves are separate blobs.
    var allowsManyParts: Bool { true }
}

/// One item found in a person crop, on the 384x576 analysis grid.
struct GarmentInstance {
    let kind: GarmentKind
    /// Fashionpedia class that won the vote (e.g. 5 = jacket), for logging/tests.
    let labelerClass: Int
    /// 0/1 mask on the grid (row-major, gridW x gridH).
    var mask: [UInt8]
    /// Enclosed pixels covered by hands/arms/hair/bag/belt — filled in the cutout.
    var holes: [UInt8]
    let pixelCount: Int
    let holeCount: Int
    /// Grid-space bounding box (x0, y0, x1, y1), inclusive-exclusive.
    let box: (Int, Int, Int, Int)
    /// Mask touches the grid edge on these sides (garment may be cut off by the frame).
    let touchesEdge: (top: Bool, bottom: Bool, left: Bool, right: Bool)
}

/// Fuses the two segmentation maps into per-item masks.
///
/// - The **parser** decides *which pixels are clothing* (it has explicit face /
///   hair / arms / hands / legs / torso classes, so skin never leaks into a
///   garment) and the coarse region.
/// - The **labeler** decides *what each region is*, by a restricted majority vote
///   inside the region. The one allowed split is an open outer layer (jacket,
///   coat, cardigan, vest) over an inner top — the classic case the parser merges.
enum GarmentSegmenter {
    // FASHN parser classes.
    enum P: UInt8 {
        case background = 0, face, hair, top, dress, skirt, pants, belt, bag, hat, scarf, glasses, arms, hands, legs, feet, torso, jewelry
    }

    // Fashionpedia whole-garment classes (labeler channels 0..26).
    static let fpNames: [Int: String] = [
        1: "shirt", 2: "top", 3: "sweater", 4: "cardigan", 5: "jacket", 6: "vest", 7: "pants", 8: "shorts", 9: "skirt",
        10: "coat", 11: "dress", 12: "jumpsuit", 13: "cape", 14: "glasses", 15: "hat", 16: "headband", 17: "tie",
        18: "glove", 19: "watch", 20: "belt", 21: "leg warmer", 22: "tights", 23: "sock", 24: "shoe", 25: "bag", 26: "scarf"]

    /// Region → classes the labeler may assign inside it.
    private static let allowed: [(P, [Int])] = [
        (.top, [1, 2, 3, 4, 5, 6, 10, 13, 11, 12]),
        (.dress, [11, 12, 10, 13]),
        (.skirt, [9, 11]),
        (.pants, [7, 8, 22, 12]),
        (.feet, [24, 23]),
        (.bag, [25]),
        (.hat, [15, 16]),
        (.scarf, [26, 17]),
        (.glasses, [14]),
        (.belt, [20]),
        (.jewelry, [19])
    ]

    private static func kind(forLabelerClass c: Int, region: P) -> GarmentKind {
        switch c {
        case 4, 5, 6, 10, 13: return .outerLayer
        case 1, 2, 3: return .innerTop
        case 11, 12: return .onePiece
        case 7, 8, 9, 22: return .lower
        case 23, 24: return .footwear
        case 14: return .eyewear
        case 15, 16: return .headwear
        case 25: return .bag
        case 17, 26: return .neckwear
        case 20: return .belt
        default: return region == .jewelry ? .jewelry : .innerTop
        }
    }

    static func segment(parser labels: [UInt8], labelerLogits logits: [Float]) -> [GarmentInstance] {
        let n = WardrobeML.gridCount
        guard labels.count == n, logits.count >= 27 * n else { return [] }

        var instances: [GarmentInstance] = []
        for (region, classes) in allowed {
            var idx: [Int] = []
            for i in 0..<n where labels[i] == region.rawValue { idx.append(i) }
            let small = [.glasses, .jewelry, .belt, .hat].contains(region)
            guard idx.count >= Int(Double(n) * (small ? 0.0004 : 0.002)) else { continue }

            // Per-pixel restricted argmax, plus a probability check for feet: the
            // parser's "feet" also covers bare feet, so require the labeler to
            // actually see a shoe there.
            var pixelClass = [Int](repeating: 0, count: idx.count)
            var shoeEvidence: Float = 0
            for (k, i) in idx.enumerated() {
                var best = classes[0], bestV = -Float.infinity
                for c in classes {
                    let v = logits[c * n + i]
                    if v > bestV { bestV = v; best = c }
                }
                pixelClass[k] = best
                if region == .feet {
                    let bg = logits[i]   // channel 0 = background / skin
                    shoeEvidence += bestV > bg ? 1 : 0
                }
            }
            if region == .feet, shoeEvidence < Float(idx.count) * 0.35 { continue }

            // Group pixels into items.
            var groups: [Int: [Int]] = [:]    // labeler class → grid indices
            if region == .top, let split = layerSplit(idx: idx, pixelClass: pixelClass) {
                groups[split.outerClass] = split.outer
                groups[split.innerClass] = split.inner
            } else if region == .top {
                groups[majority(pixelClass)] = idx
            } else {
                groups[majority(pixelClass)] = idx
            }

            for (cls, pixels) in groups {
                let k = kind(forLabelerClass: cls, region: region)
                if let inst = makeInstance(kind: k, labelerClass: cls, pixels: pixels, parser: labels) {
                    instances.append(inst)
                }
            }
        }
        // Largest first: the hero garments lead the review list.
        return instances.sorted { $0.pixelCount > $1.pixelCount }
    }

    /// Layer rank of an upper-body class: what can be worn over what.
    private static func layerRank(_ c: Int) -> Int {
        switch c {
        case 5, 10, 13: return 3      // jacket, coat, cape
        case 4, 6: return 2           // cardigan, vest
        case 1, 3: return 1           // shirt (worn open over a tee), sweater
        default: return 0             // top / t-shirt, dress, jumpsuit
        }
    }

    /// Splits the parser's single "top" region into an outer and an inner layer
    /// when the labeler sees two substantial garments of different layer rank —
    /// an open coat over a knit, a flannel shirt over a tee. Small stray blobs
    /// (a sleeve patch the labeler got wrong) are moved to the layer they touch.
    private static func layerSplit(idx: [Int], pixelClass: [Int])
        -> (outerClass: Int, outer: [Int], innerClass: Int, inner: [Int])? {
        let n = WardrobeML.gridCount
        var counts: [Int: Int] = [:]
        for c in pixelClass { counts[c, default: 0] += 1 }
        let ranked = counts.sorted { $0.value > $1.value }
        // An open coat usually dwarfs the strip of top showing under it, so the
        // smaller layer only needs to be a real garment-sized area.
        let minPart = max(idx.count / 20, Int(Double(n) * 0.004))
        guard let a = ranked.first, a.value >= minPart,
              let b = ranked.dropFirst().first(where: { layerRank($0.key) != layerRank(a.key) && $0.value >= minPart })
        else { return nil }
        let (outerClass, innerClass) = layerRank(a.key) > layerRank(b.key) ? (a.key, b.key) : (b.key, a.key)
        let innerRank = layerRank(innerClass)
        var isOuter = [UInt8](repeating: 0, count: n), isInner = [UInt8](repeating: 0, count: n)
        for (k, i) in idx.enumerated() {
            if layerRank(pixelClass[k]) > innerRank { isOuter[i] = 1 } else { isInner[i] = 1 }
        }
        absorbStrays(&isInner, into: &isOuter)
        absorbStrays(&isOuter, into: &isInner)
        let outer = idx.filter { isOuter[$0] != 0 }, inner = idx.filter { isInner[$0] != 0 }
        guard outer.count >= minPart, inner.count >= minPart else { return nil }
        return (outerClass, outer, innerClass, inner)
    }

    /// Moves components of `a` smaller than 20% of a's largest component into
    /// `b` when they touch `b`.
    private static func absorbStrays(_ a: inout [UInt8], into b: inout [UInt8]) {
        let w = WardrobeML.gridW, h = WardrobeML.gridH
        let (comp, sizes) = components(a, w: w, h: h)
        guard let largest = sizes.max(), sizes.count > 1 else { return }
        var touches = [Bool](repeating: false, count: sizes.count + 1)
        for i in 0..<(w * h) where comp[i] != 0 {
            let x = i % w, y = i / w
            if (x > 0 && b[i - 1] != 0) || (x < w - 1 && b[i + 1] != 0) || (y > 0 && b[i - w] != 0) || (y < h - 1 && b[i + w] != 0) {
                touches[comp[i]] = true
            }
        }
        for i in 0..<(w * h) where comp[i] != 0 {
            let id = comp[i]
            if sizes[id - 1] < largest / 5 && touches[id] { a[i] = 0; b[i] = 1 }
        }
    }

    private static func majority(_ xs: [Int]) -> Int {
        var counts: [Int: Int] = [:]
        for x in xs { counts[x, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? 0
    }

    // MARK: - Mask cleanup

    private static func makeInstance(kind: GarmentKind, labelerClass: Int, pixels: [Int], parser: [UInt8]) -> GarmentInstance? {
        let w = WardrobeML.gridW, h = WardrobeML.gridH, n = w * h
        var mask = [UInt8](repeating: 0, count: n)
        for i in pixels { mask[i] = 1 }
        mask = close(mask, w: w, h: h)

        // Keep the main blob plus any sizeable parts (an open jacket's two halves,
        // two shoes); drop specks.
        let (comp, sizes) = components(mask, w: w, h: h)
        guard let largest = sizes.max(), largest > 0 else { return nil }
        let minArea = Double(n) * (kind.isSmall || kind == .headwear ? 0.0004 : 0.004)
        guard Double(largest) >= minArea else { return nil }
        let keep = Set(sizes.enumerated()
            .filter { Double($0.element) >= Double(largest) * 0.12 }
            .sorted { $0.element > $1.element }
            .prefix(4).map { $0.offset + 1 })
        var count = 0
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for i in 0..<n {
            if keep.contains(comp[i]) {
                mask[i] = 1; count += 1
                let x = i % w, y = i / w
                x0 = min(x0, x); x1 = max(x1, x + 1); y0 = min(y0, y); y1 = max(y1, y + 1)
            } else {
                mask[i] = 0
            }
        }
        guard count > 0 else { return nil }

        // Enclosed holes covered by an occluder (hands, arms, hair, a bag strap, a
        // belt, jewelry). Skin that's legitimately exposed (face/torso/legs) and
        // other garments are never filled.
        var holes = [UInt8](repeating: 0, count: n)
        var holeCount = 0
        if !kind.isSmall {
            let outside = floodOutside(mask, w: w, h: h, x0: x0, y0: y0, x1: x1, y1: y1)
            let occluders: Set<UInt8> = [P.hands.rawValue, P.arms.rawValue, P.hair.rawValue,
                                         P.bag.rawValue, P.belt.rawValue, P.jewelry.rawValue, P.scarf.rawValue]
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * w + x
                    if mask[i] == 0, outside[i] == 0, occluders.contains(parser[i]) { holes[i] = 1; holeCount += 1 }
                }
            }
            // A "hole" bigger than a third of the garment isn't an occlusion we
            // can credibly paint over (e.g. a crossed arm over most of a top).
            if Double(holeCount) > Double(count) * 0.33 { holes = [UInt8](repeating: 0, count: n); holeCount = 0 }
        }

        return GarmentInstance(
            kind: kind, labelerClass: labelerClass, mask: mask, holes: holes,
            pixelCount: count, holeCount: holeCount, box: (x0, y0, x1, y1),
            touchesEdge: (top: y0 <= 1, bottom: y1 >= h - 1, left: x0 <= 1, right: x1 >= w - 1))
    }

    /// Morphological close with a 3x3 element (fills 1-px cracks along seams).
    private static func close(_ m: [UInt8], w: Int, h: Int) -> [UInt8] {
        erode(dilate(m, w: w, h: h), w: w, h: h)
    }

    private static func dilate(_ m: [UInt8], w: Int, h: Int) -> [UInt8] {
        var o = m
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] == 0 {
                var hit = false
                for dy in -1...1 where !hit {
                    let yy = y + dy; if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx; if xx < 0 || xx >= w { continue }
                        if m[yy * w + xx] != 0 { hit = true; break }
                    }
                }
                if hit { o[y * w + x] = 1 }
            }
        }
        return o
    }

    private static func erode(_ m: [UInt8], w: Int, h: Int) -> [UInt8] {
        var o = m
        for y in 0..<h {
            for x in 0..<w where m[y * w + x] != 0 {
                var miss = false
                for dy in -1...1 where !miss {
                    let yy = y + dy; if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx; if xx < 0 || xx >= w { continue }
                        if m[yy * w + xx] == 0 { miss = true; break }
                    }
                }
                if miss { o[y * w + x] = 0 }
            }
        }
        return o
    }

    /// 8-connected component labels (1-based) and each component's size.
    static func components(_ m: [UInt8], w: Int, h: Int) -> ([Int], [Int]) {
        var label = [Int](repeating: 0, count: w * h)
        var sizes: [Int] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where m[start] != 0 && label[start] == 0 {
            let id = sizes.count + 1
            var size = 0
            stack.append(start); label[start] = id
            while let i = stack.popLast() {
                size += 1
                let x = i % w, y = i / w
                for dy in -1...1 {
                    let yy = y + dy; if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx; if xx < 0 || xx >= w { continue }
                        let j = yy * w + xx
                        if m[j] != 0 && label[j] == 0 { label[j] = id; stack.append(j) }
                    }
                }
            }
            sizes.append(size)
        }
        return (label, sizes)
    }

    /// Marks non-mask pixels reachable from outside the item's box (4-connected).
    private static func floodOutside(_ m: [UInt8], w: Int, h: Int, x0: Int, y0: Int, x1: Int, y1: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        var stack: [Int] = []
        func push(_ x: Int, _ y: Int) {
            let i = y * w + x
            if m[i] == 0 && out[i] == 0 { out[i] = 1; stack.append(i) }
        }
        for x in x0..<x1 { push(x, y0); push(x, y1 - 1) }
        for y in y0..<y1 { push(x0, y); push(x1 - 1, y) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > x0 { push(x - 1, y) }
            if x < x1 - 1 { push(x + 1, y) }
            if y > y0 { push(x, y - 1) }
            if y < y1 - 1 { push(x, y + 1) }
        }
        return out
    }
}
