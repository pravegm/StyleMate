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
    /// Separate pieces kept (an open jacket's halves, two shoes; >1 for a
    /// one-piece garment means a fragmented mask).
    var parts: Int = 1

    /// Part evidence for upper-body garments (share of the mask).
    struct PartShares { let hood: Float; let collar: Float; let lapel: Float; let sleeve: Float }
    var partShares: PartShares?
}

/// Turns one GarmentNet map into per-item masks.
///
/// GarmentNet labels every grid pixel with a Fashionpedia garment class, "body" (the
/// person's skin or hair) or the scene, so skin never leaks into a garment. Pixels
/// are grouped by region (all upper-body garments, one-pieces, bottoms, shoes, bag,
/// headwear, neckwear, glasses, belt, watch); inside a region the per-pixel classes
/// vote. The one allowed split inside the upper body is an open outer layer
/// (jacket, coat, cardigan, vest) over an inner top; a one-piece whose top and
/// bottom halves look like a top over trousers (by the low-res probabilities) is two
/// garments.
enum GarmentSegmenter {
    /// Coarse region of a Fashionpedia class (what the FASHN parser used to supply).
    enum Region: CaseIterable {
        case top, dress, skirt, pants, feet, bag, hat, scarf, glasses, belt, jewelry
    }

    // Fashionpedia whole-garment classes (GarmentNet channels 1..26).
    static let fpNames: [Int: String] = [
        1: "shirt", 2: "top", 3: "sweater", 4: "cardigan", 5: "jacket", 6: "vest", 7: "pants", 8: "shorts", 9: "skirt",
        10: "coat", 11: "dress", 12: "jumpsuit", 13: "cape", 14: "glasses", 15: "hat", 16: "headband", 17: "tie",
        18: "glove", 19: "watch", 20: "belt", 21: "leg warmer", 22: "tights", 23: "sock", 24: "shoe", 25: "bag", 26: "scarf"]

    static func region(_ c: UInt8) -> Region? {
        switch c {
        case 1, 2, 3, 4, 5, 6, 10, 13: return .top
        case 11, 12: return .dress
        case 9: return .skirt
        case 7, 8, 21, 22: return .pants
        case 23, 24: return .feet
        case 25: return .bag
        case 15, 16: return .hat
        case 17, 26: return .scarf
        case 14: return .glasses
        case 20: return .belt
        case 19: return .jewelry
        default: return nil
        }
    }

    static let upperClasses: Set<UInt8> = [1, 2, 3, 4, 5, 6, 10, 13]

    private static func kind(forClass c: Int) -> GarmentKind {
        switch c {
        case 4, 5, 6, 10, 13: return .outerLayer
        case 1, 2, 3: return .innerTop
        case 11, 12: return .onePiece
        case 7, 8, 9, 21, 22: return .lower
        case 23, 24: return .footwear
        case 14: return .eyewear
        case 15, 16: return .headwear
        case 25: return .bag
        case 17, 26: return .neckwear
        case 20: return .belt
        case 19: return .jewelry
        default: return .innerTop
        }
    }

    /// A garment split over two regions or classes (trousers / shorts / tights; shoes / socks)
    /// is merged back into one.
    private static func family(_ c: Int) -> Int {
        switch c {
        case 7, 8, 21, 22: return 7
        case 23, 24: return 24
        default: return c
        }
    }

    /// Mean colour (0...1 RGB) of grid pixels, from the crop the map was made on.
    typealias ColourOf = ([Int]) -> (Float, Float, Float)?

    static func segment(_ map: GarmentMap, colour: ColourOf? = nil) -> [GarmentInstance] {
        let n = WardrobeML.gridCount
        let labels = map.classes
        guard labels.count == n else { return [] }

        var byRegion: [Region: [Int]] = [:]
        for i in 0..<n { if let r = region(labels[i]) { byRegion[r, default: []].append(i) } }
        absorbSlivers(&byRegion, labels: labels, map: map)

        var pending: [(kind: GarmentKind, cls: Int, pixels: [Int])] = []
        for r in Region.allCases {
            guard let idx = byRegion[r] else { continue }
            let small = [.glasses, .jewelry, .belt, .hat].contains(r)
            guard idx.count >= Int(Double(n) * (small ? 0.0004 : 0.002)) else { continue }
            let pixelClass = idx.map { Int(labels[$0]) }
            var groups: [Int: [Int]] = [:]
            let maj = majority(pixelClass)
            if r == .top, let split = layerSplit(idx: idx, pixelClass: pixelClass, map: map) {
                groups[split.outerClass] = split.outer
                groups[split.innerClass] = split.inner
            } else if r == .dress, let split = topBottomSplit(idx: idx, map: map) {
                // A black top over black jeans reads as one "jumpsuit".
                groups[split.topClass] = split.top
                groups[split.bottomClass] = split.bottom
            } else {
                groups[maj] = idx
            }
            // A "tie" in a scarf region is usually a dark drape, a shawl end or a
            // shadow: keep it a tie only if it looks like one, otherwise it's the scarf.
            if r == .scarf, let tie = groups[17], !isPlausibleTie(tie, labels: labels) {
                groups[17] = nil
                groups[26, default: []] += tie
            }
            for (cls, pixels) in groups where !pixels.isEmpty {
                pending.append((kind(forClass: cls), cls, pixels))
            }
        }

        // A long coat whose hem GarmentNet reads as a "dress" (or vest / gilet, the commonest
        // misreads on the fixtures) is one garment: a one-piece directly below an outer layer
        // or top in the same colour joins it. A dress under a coat is normally another colour.
        if let colour {
            func close(_ a: [Int], _ b: [Int]) -> Bool {
                guard let ca = colour(a), let cb = colour(b) else { return false }
                let la = ColorNamer.lab(ca.0, ca.1, ca.2), lb = ColorNamer.lab(cb.0, cb.1, cb.2)
                let d = sqrt(pow(la.0 - lb.0, 2) + pow(la.1 - lb.1, 2) + pow(la.2 - lb.2, 2))
                return d < 12
            }
            let w = WardrobeML.gridW
            func meanY(_ px: [Int]) -> Int { px.reduce(0) { $0 + $1 / w } / max(1, px.count) }
            while let d = pending.firstIndex(where: { $0.kind == .onePiece }),
                  let u = pending.firstIndex(where: { [.outerLayer, .innerTop].contains($0.kind)
                      && meanY($0.pixels) < meanY(pending[d].pixels) && close($0.pixels, pending[d].pixels) }) {
                let keepUpper = pending[u]
                pending[u] = (keepUpper.kind, keepUpper.cls, keepUpper.pixels + pending[d].pixels)
                pending.remove(at: d)
            }
        }

        // A tunic / kurta / shirt-dress read as a top over a dress is one long garment
        // (a dress worn under a plain top is rare; under an open jacket it stays two).
        if !pending.contains(where: { $0.kind == .outerLayer }),
           let d = pending.firstIndex(where: { $0.kind == .onePiece }),
           let tIdx = pending.firstIndex(where: { $0.kind == .innerTop }) {
            let top = pending[tIdx], dress = pending[d]
            let w = WardrobeML.gridW
            let ty = top.pixels.reduce(0) { $0 + $1 / w } / max(1, top.pixels.count)
            let dy = dress.pixels.reduce(0) { $0 + $1 / w } / max(1, dress.pixels.count)
            if ty <= dy {
                let big = top.pixels.count > dress.pixels.count ? top : dress
                pending[d] = (big.kind, big.cls, dress.pixels + top.pixels)
                pending.remove(at: tIdx)
            }
        }

        // Merge same-family groups of one-per-person kinds (bottoms, shoes).
        var merged: [(kind: GarmentKind, cls: Int, pixels: [Int])] = []
        for g in pending {
            if [.lower, .footwear].contains(g.kind),
               let j = merged.firstIndex(where: { $0.kind == g.kind && family($0.cls) == family(g.cls) }) {
                if g.pixels.count > merged[j].pixels.count { merged[j].cls = g.cls }
                merged[j].pixels += g.pixels
            } else {
                merged.append(g)
            }
        }

        var instances: [GarmentInstance] = []
        for g in merged {
            if var inst = makeInstance(kind: g.kind, cls: g.cls, pixels: g.pixels, labels: labels) {
                if [.innerTop, .outerLayer, .onePiece].contains(g.kind) {
                    inst.partShares = partShares(mask: inst.mask, map: map)
                }
                instances.append(inst)
            }
        }
        // Largest first: the hero garments lead the review list.
        return instances.sorted { $0.pixelCount > $1.pixelCount }
    }

    /// A main-garment region far smaller than the person's biggest one (a coat's hem read
    /// as "skirt", a few "pants" pixels at a dress's edge) is a misread of a neighbour:
    /// its pixels go to their most likely other main garment when the model gives that a
    /// fair chance. Small accessories are small by nature and are left alone.
    private static func absorbSlivers(_ byRegion: inout [Region: [Int]], labels: [UInt8], map: GarmentMap) {
        let main: [Region] = [.top, .dress, .skirt, .pants]
        let largest = main.map { byRegion[$0]?.count ?? 0 }.max() ?? 0
        guard largest > 0 else { return }
        for r in main {
            guard let idx = byRegion[r], !idx.isEmpty, idx.count * 100 < largest * 8 else { continue }
            var moved: [Region: [Int]] = [:], kept: [Int] = []
            for i in idx {
                var best = 0, bestV: Float = 0.1
                for c in 1..<27 {
                    guard let rc = region(UInt8(c)), rc != r, main.contains(rc) else { continue }
                    let v = map.prob(c, i)
                    if v > bestV { bestV = v; best = c }
                }
                if best > 0, let rc = region(UInt8(best)), (byRegion[rc]?.count ?? 0) > idx.count {
                    moved[rc, default: []].append(i)
                } else {
                    kept.append(i)
                }
            }
            byRegion[r] = kept.isEmpty ? nil : kept
            for (rc, px) in moved { byRegion[rc, default: []] += px }
        }
    }

    /// Top edge (grid y) of the upper-body garments, or nil.
    static func upperTop(_ labels: [UInt8]) -> Int? {
        let w = WardrobeML.gridW
        for (i, l) in labels.enumerated() where upperClasses.contains(l) || l == 11 || l == 12 { return i / w }
        return nil
    }

    /// A necktie: a narrow vertical strip (at least 2.5x taller than wide) starting at
    /// the collar, centred on the torso, called a tie for most of its pixels.
    static func isPlausibleTie(_ pixels: [Int], labels: [UInt8]) -> Bool {
        let n = WardrobeML.gridCount, w = WardrobeML.gridW
        guard Double(pixels.count) >= Double(n) * 0.001 else { return false }
        var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0, agree = 0
        for i in pixels {
            let x = i % w, y = i / w
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1)
            if labels[i] == 17 { agree += 1 }
        }
        let tw = x1 - x0, th = y1 - y0
        guard th * 2 >= tw * 5, Float(agree) >= Float(pixels.count) * 0.6 else { return false }
        // Starts at or below the collar (the top of the upper garments), centred on them.
        var tx0 = Int.max, tx1 = 0
        for (i, l) in labels.enumerated() where upperClasses.contains(l) || l == 11 {
            tx0 = min(tx0, i % w); tx1 = max(tx1, i % w + 1)
        }
        if let top = upperTop(labels), y0 < top - WardrobeML.gridH / 50 { return false }
        guard tx1 > tx0 else { return false }
        let cx = Double(x0 + x1) / 2, torsoCx = Double(tx0 + tx1) / 2
        return abs(cx - torsoCx) <= 0.15 * Double(tx1 - tx0)
    }

    /// When the low-res probabilities, one-pieces set aside, see a top over trousers
    /// inside one one-piece region (each >= 25% of it, the top above), it is two garments.
    private static func topBottomSplit(idx: [Int], map: GarmentMap)
        -> (topClass: Int, top: [Int], bottomClass: Int, bottom: [Int])? {
        let w = WardrobeML.gridW
        let tops: Set<Int> = [1, 2, 3], bottoms: Set<Int> = [7, 8, 22]
        var top: [Int] = [], bottom: [Int] = [], other: [Int] = []
        var topCounts: [Int: Int] = [:], bottomCounts: [Int: Int] = [:]
        for i in idx {
            var best = 1, bestV = -Float.infinity
            for c in 1..<27 where c != 11 && c != 12 {
                let v = map.prob(c, i)
                if v > bestV { bestV = v; best = c }
            }
            if tops.contains(best) { top.append(i); topCounts[best, default: 0] += 1 }
            else if bottoms.contains(best) { bottom.append(i); bottomCounts[best, default: 0] += 1 }
            else { other.append(i) }
        }
        guard top.count * 4 >= idx.count, bottom.count * 4 >= idx.count else { return nil }
        let ty = top.reduce(0) { $0 + $1 / w } / top.count, by = bottom.reduce(0) { $0 + $1 / w } / bottom.count
        guard ty < by else { return nil }
        let line = (ty + by) / 2
        for i in other { if i / w < line { top.append(i) } else { bottom.append(i) } }
        let tc = topCounts.max { $0.value < $1.value }?.key ?? 2
        let bc = bottomCounts.max { $0.value < $1.value }?.key ?? 7
        return (tc, top, bc, bottom)
    }

    /// Share of an upper-body garment's pixels GarmentNet's part channels call
    /// hood / collar / lapel / sleeve (sampled every 3rd pixel).
    private static func partShares(mask: [UInt8], map: GarmentMap) -> GarmentInstance.PartShares {
        var hood = 0, collar = 0, lapel = 0, sleeve = 0, total = 0
        for i in stride(from: 0, to: mask.count, by: 3) where mask[i] != 0 {
            total += 1
            if map.part(0, i) > 0.5 { hood += 1 }
            if map.part(1, i) > 0.5 { collar += 1 }
            if map.part(2, i) > 0.5 { lapel += 1 }
            if map.part(3, i) > 0.5 { sleeve += 1 }
        }
        let t = Float(max(1, total))
        return .init(hood: Float(hood) / t, collar: Float(collar) / t, lapel: Float(lapel) / t, sleeve: Float(sleeve) / t)
    }

    /// The head: body pixels above the upper garments (hair, or a turban / headscarf
    /// GarmentNet took for hair), to check by its look whether it is headwear.
    static func headInstance(labels: [UInt8]) -> GarmentInstance? {
        let w = WardrobeML.gridW
        let limit = upperTop(labels) ?? WardrobeML.gridH / 3
        var px: [Int] = []
        for i in 0..<min(labels.count, limit * w) where labels[i] == GarmentMap.body || labels[i] == 15 || labels[i] == 16 { px.append(i) }
        guard Double(px.count) >= Double(WardrobeML.gridCount) * 0.002 else { return nil }
        return makeInstance(kind: .headwear, cls: 16, pixels: px, labels: labels)
    }

    /// Layer rank of an upper-body class: what can be worn over what.
    private static func layerRank(_ c: Int) -> Int {
        switch c {
        case 5, 10, 13: return 3      // jacket, coat, cape
        case 4, 6: return 2           // cardigan, vest
        case 1, 3: return 1           // shirt (worn open over a tee), sweater
        default: return 0             // top / t-shirt
        }
    }

    /// Class pairs GarmentNet confuses on ONE garment far more often than people wear
    /// them together: a coat / jacket / cape read partly as a vest, a cardigan partly as
    /// a sweater (benchmark: phantom "Vests" next to coats, a coat as cardigan + sweater).
    private static func oneGarment(_ a: Int, _ b: Int) -> Bool {
        let pair = Set([a, b])
        return (pair.contains(6) && !pair.isDisjoint(with: [5, 10, 13])) || pair == [3, 4]
    }

    /// Splits the upper-body region into an outer and an inner layer when it holds two
    /// substantial garments of different layer rank — an open coat over a knit, a
    /// flannel shirt over a tee. Small stray blobs (a sleeve patch misread) are moved
    /// to the layer they touch.
    private static func layerSplit(idx: [Int], pixelClass: [Int], map: GarmentMap)
        -> (outerClass: Int, outer: [Int], innerClass: Int, inner: [Int])? {
        let n = WardrobeML.gridCount
        var counts: [Int: Int] = [:]
        for c in pixelClass { counts[c, default: 0] += 1 }
        let ranked = counts.sorted { $0.value > $1.value }
        // An open coat usually dwarfs the strip of top showing under it, so the
        // smaller layer only needs to be a real garment-sized area.
        let minPart = max(idx.count / 20, Int(Double(n) * 0.004))
        guard let a = ranked.first, a.value >= minPart,
              let b = ranked.dropFirst().first(where: { layerRank($0.key) != layerRank(a.key) && $0.value >= minPart
                                                       && !oneGarment(a.key, $0.key) })
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
        // An open layer flanks what it is worn over: it has fabric on both sides of the
        // inner top's centre line (a coat's two halves, a shirt's two fronts / sleeves).
        // Without that it is one garment the model was unsure about.
        let w = WardrobeML.gridW
        let icx = inner.reduce(0) { $0 + $1 % w } / inner.count
        let left = outer.reduce(0) { $0 + ($1 % w < icx ? 1 : 0) }
        guard min(left, outer.count - left) * 5 >= outer.count else { return nil }
        // Sleeves are not an inner top: when most of the "inner" layer is sleeve (part map),
        // it is the outer garment's own arms read as another class (coats then came out as
        // sleeveless "Vests" / "Gilets").
        let sleeve = inner.reduce(0) { $0 + (map.part(3, $1) > 0.5 ? 1 : 0) }
        guard sleeve * 2 < inner.count else { return nil }
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

    private static func makeInstance(kind: GarmentKind, cls: Int, pixels: [Int], labels: [UInt8]) -> GarmentInstance? {
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
            .prefix(kind == .belt ? 1 : 4).map { $0.offset + 1 })   // a belt is one piece
        // A tie is one solid piece; several small dark fragments labelled "tie"
        // are hair or a shadow (seen in the e2e gallery test).
        if cls == 17, keep.count > 1 || Double(largest) < Double(n) * 0.002 { return nil }
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
        // GarmentNet's 1/4-res outline runs ~1 grid px into the scene: peel that rim (only
        // where the garment meets the scene, not body or another garment) so pavement and
        // walls don't tint the cutout's edge colours.
        if !kind.isSmall {
            var peel: [Int] = []
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * w + x
                    guard mask[i] != 0 else { continue }
                    if (x > 0 && labels[i - 1] == 0 && mask[i - 1] == 0) || (x < w - 1 && labels[i + 1] == 0 && mask[i + 1] == 0)
                        || (y > 0 && labels[i - w] == 0 && mask[i - w] == 0) || (y < h - 1 && labels[i + w] == 0 && mask[i + w] == 0) {
                        peel.append(i)
                    }
                }
            }
            if peel.count * 4 < count { for i in peel { mask[i] = 0 }; count -= peel.count }
        }

        // Amodal completion: the parts of the garment hidden behind something — a
        // hand, an arm, hair, a bag or strap, a belt, a scarf, or (for an open
        // jacket/shirt) the top showing between its halves — are filled with the
        // garment's own fabric so the cutout (and the studio render made from it)
        // shows the WHOLE garment, not one with a hand-shaped hole. Candidates:
        // pixels enclosed by the garment, or within a morphological closing of it,
        // labelled as an occluder. Background is never filled, and body pixels only
        // where they are hands / arms / hair, not exposed skin: never in the neckline
        // (top centre of an upper garment), and on bottoms only in the upper part of
        // the legs (the hand-on-thigh notch, not the gap between bare legs).
        var holes = [UInt8](repeating: 0, count: n)
        var holeCount = 0
        if !kind.isSmall {
            let outside = floodOutside(mask, w: w, h: h, x0: x0, y0: y0, x1: x1, y1: y1)
            var occluders: Set<UInt8> = [GarmentMap.body, 25, 20, 19, 26, 17, 18]
            // Other clothing in front of / between this garment: the inner top
            // between an open jacket's halves, a shirt overhanging trousers.
            switch kind {
            case .outerLayer, .innerTop: occluders.formUnion(upperClasses.union([11, 12]))
            case .lower: occluders.formUnion(upperClasses.union([11, 12]))
            case .onePiece: occluders.formUnion(upperClasses)
            default: break
            }
            occluders.remove(UInt8(cls))
            let bw = x1 - x0, bh = y1 - y0
            let cx = (x0 + x1) / 2
            func bodyOK(_ x: Int, _ y: Int) -> Bool {
                switch kind {
                case .innerTop, .outerLayer, .onePiece:
                    return !(y < y0 + bh * 35 / 100 && abs(x - cx) < bw * 3 / 10)
                case .lower:
                    return y < y0 + bh * 6 / 10
                default:
                    return true
                }
            }
            // Closing of the mask with a (2r+1)^2 square, computed on the item's box plus
            // a margin only (the full-grid version was most of the extraction time).
            let radius = kind == .lower ? 5 : 10
            let sx0 = max(0, x0 - radius - 1), sy0 = max(0, y0 - radius - 1)
            let sx1 = min(w, x1 + radius + 1), sy1 = min(h, y1 + radius + 1)
            let sw = sx1 - sx0, sh = sy1 - sy0
            var sub = [UInt8](repeating: 0, count: sw * sh)
            for y in sy0..<sy1 { for x in sx0..<sx1 { sub[(y - sy0) * sw + (x - sx0)] = mask[y * w + x] } }
            let hull = square(square(sub, w: sw, h: sh, r: radius, dilate: true), w: sw, h: sh, r: radius, dilate: false)
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * w + x
                    guard mask[i] == 0, outside[i] == 0 || hull[(y - sy0) * sw + (x - sx0)] != 0 else { continue }
                    let l = labels[i]
                    guard occluders.contains(l), l != GarmentMap.body || bodyOK(x, y) else { continue }
                    holes[i] = 1; holeCount += 1
                }
            }
            // Trousers: a hand resting on the thigh bites a notch into the leg's
            // outline that the small closing misses. Fill row runs bounded by the
            // garment on both sides that are entirely body / bag, in the upper legs.
            if kind == .lower {
                let hand: Set<UInt8> = [GarmentMap.body, 25, 18]
                for y in y0..<(y0 + bh * 6 / 10) {
                    var x = x0
                    while x < x1 {
                        guard mask[y * w + x] != 0 else { x += 1; continue }
                        var e = x + 1
                        while e < x1 && mask[y * w + e] != 0 { e += 1 }
                        var g = e
                        while g < x1 && mask[y * w + g] == 0 && hand.contains(labels[y * w + g]) { g += 1 }
                        if g > e, g < x1, mask[y * w + g] != 0, g - e <= bw / 3 {
                            for xx in e..<g where holes[y * w + xx] == 0 { holes[y * w + xx] = 1; holeCount += 1 }
                        }
                        x = g > e ? g : e
                    }
                }
            }
            // Only credible completions: an open jacket's gap can be large; for
            // anything else a "hole" over a third of the garment is a different
            // garment or a body part, not an occlusion.
            let limit = kind == .outerLayer ? 0.6 : 0.33
            if Double(holeCount) > Double(count) * limit { holes = [UInt8](repeating: 0, count: n); holeCount = 0 }
        }

        return GarmentInstance(
            kind: kind, labelerClass: cls, mask: mask, holes: holes,
            pixelCount: count, holeCount: holeCount, box: (x0, y0, x1, y1),
            touchesEdge: (top: y0 <= 1, bottom: y1 >= h - 1, left: x0 <= 1, right: x1 >= w - 1),
            parts: keep.count)
    }

    /// Morphological close with a 3x3 element (fills 1-px cracks along seams).
    private static func close(_ m: [UInt8], w: Int, h: Int) -> [UInt8] {
        square(square(m, w: w, h: h, r: 1, dilate: true), w: w, h: h, r: 1, dilate: false)
    }

    /// Binary dilation (any set pixel in the window) or erosion (all set) with a
    /// (2r+1) x (2r+1) square, as two separable sliding-window passes. Pixels past the
    /// buffer's edge are ignored (the edge neither grows nor erodes), as in the
    /// iterated 3x3 version this replaced.
    static func square(_ m: [UInt8], w: Int, h: Int, r: Int, dilate: Bool) -> [UInt8] {
        guard r > 0, w > 0, h > 0 else { return m }
        var tmp = [UInt8](repeating: 0, count: w * h)
        var out = [UInt8](repeating: 0, count: w * h)
        m.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { t in
                for y in 0..<h {
                    let row = y * w
                    var count = 0
                    for x in 0..<min(r, w) { count += Int(src[row + x]) }
                    for x in 0..<w {
                        if x + r < w { count += Int(src[row + x + r]) }
                        if x - r - 1 >= 0 { count -= Int(src[row + x - r - 1]) }
                        let len = min(w - 1, x + r) - max(0, x - r) + 1
                        t[row + x] = dilate ? (count > 0 ? 1 : 0) : (count == len ? 1 : 0)
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { o in
                for x in 0..<w {
                    var count = 0
                    for y in 0..<min(r, h) { count += Int(src[y * w + x]) }
                    for y in 0..<h {
                        if y + r < h { count += Int(src[(y + r) * w + x]) }
                        if y - r - 1 >= 0 { count -= Int(src[(y - r - 1) * w + x]) }
                        let len = min(h - 1, y + r) - max(0, y - r) + 1
                        o[y * w + x] = dilate ? (count > 0 ? 1 : 0) : (count == len ? 1 : 0)
                    }
                }
            }
        }
        return out
    }

    /// 8-connected component labels (1-based) and each component's size.
    static func components(_ m: [UInt8], w: Int, h: Int) -> ([Int], [Int]) {
        var label = [Int](repeating: 0, count: w * h)
        var sizes: [Int] = []
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        m.withUnsafeBufferPointer { mp in
            label.withUnsafeMutableBufferPointer { lp in
                for start in 0..<(w * h) where mp[start] != 0 && lp[start] == 0 {
                    let id = sizes.count + 1
                    var size = 0
                    stack.append(start); lp[start] = id
                    while let i = stack.popLast() {
                        size += 1
                        let x = i % w, y = i / w
                        let ya = max(0, y - 1), yb = min(h - 1, y + 1), xa = max(0, x - 1), xb = min(w - 1, x + 1)
                        for yy in ya...yb {
                            for xx in xa...xb {
                                let j = yy * w + xx
                                if mp[j] != 0 && lp[j] == 0 { lp[j] = id; stack.append(j) }
                            }
                        }
                    }
                    sizes.append(size)
                }
            }
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
