import CoreGraphics
import Foundation

/// How a closet item goes on a body.
enum TryOnRole: Int, Comparable {
    /// Drawn in this order (later = on top).
    case bottom = 0, onePiece, top, outer
    case shoes, accessory

    static func < (a: TryOnRole, b: TryOnRole) -> Bool { a.rawValue < b.rawValue }

    /// Same split as `StudioQueue.kind(for:)` (main-actor isolated there, so mirrored here).
    static func of(_ item: WardrobeItem) -> TryOnRole {
        let p = item.product
        switch item.category {
        case .outerwear: return .outer
        case .midLayers:
            return ["Cardigans", "Vests", "Gilets", "Fleece Jackets", "Shrugs", "Ponchos"].contains(p) ? .outer : .top
        case .tops: return .top
        case .onePieces: return .onePiece
        case .bottoms: return .bottom
        case .footwear: return .shoes
        case .innerwear: return .accessory
        case .activewear:
            if p.contains("Shorts") || p.contains("Pants") || p.contains("Leggings") { return .bottom }
            if p.contains("Jacket") { return .outer }
            if p.contains("Dress") || p == "Swimwear" { return .onePiece }
            return .top
        case .ethnicWear:
            if ["Salwar", "Churidar", "Dhoti", "Lungis", "Mundu", "Patiala Pants", "Sharara", "Ghagra", "Lehenga"].contains(p) { return .bottom }
            if ["Saree", "Anarkali", "Palazzo Suit", "Jodhpuri Suit", "Pathani Suit"].contains(p) { return .onePiece }
            if ["Nehru Jacket", "Sherwani", "Bandhgala"].contains(p) { return .outer }
            if p == "Dupatta" { return .accessory }
            return .top
        case .accessories: return .accessory
        }
    }

    /// Pieces the try-on draws on the body (the rest stay as chips beside it).
    var isWorn: Bool { self != .accessory }
}

/// The item facts the compositor uses.
struct TryOnGarmentSpec {
    let id: UUID
    let role: TryOnRole
    let product: String
    let fit: Fit?
    let sleeve: SleeveLength?
    let length: GarmentLength?
    /// The item's image: transparent background (studio render or cutout).
    let image: CGImage

    init(item: WardrobeItem, image: CGImage) {
        id = item.id; role = TryOnRole.of(item); product = item.product
        fit = item.fit; sleeve = item.sleeveLength; length = item.garmentLength
        self.image = image
    }

    init(id: UUID = UUID(), role: TryOnRole, product: String, fit: Fit? = nil, sleeve: SleeveLength? = nil,
         length: GarmentLength? = nil, image: CGImage) {
        self.id = id; self.role = role; self.product = product; self.fit = fit
        self.sleeve = sleeve; self.length = length; self.image = image
    }

    var fitFactor: CGFloat {
        switch fit {
        case .slim: return 1.00
        case .relaxed: return 1.14
        case .oversized: return 1.28
        default: return 1.06
        }
    }
}

/// Geometry read off a garment image's silhouette (garment pixels, y down). Mirrors
/// `analyse_top` / `analyse_bottom` in tryon-lab/tryon.py.
struct TryOnGarmentShape {
    let width: Int, height: Int
    let alpha: [UInt8]
    let y0: Int, y1: Int, x0: Int, x1: Int

    init?(_ image: CGImage, maxSide: Int = 512) {
        let k = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = max(8, Int(CGFloat(image.width) * k)), h = max(8, Int(CGFloat(image.height) * k))
        guard let r = TryOnRaster(image, width: w, height: h) else { return nil }
        var a = [UInt8](repeating: 0, count: w * h)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let v = r.px[(y * w + x) * 4 + 3]
                a[y * w + x] = v
                if v > 128 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX > minX + 4, maxY > minY + 4 else { return nil }
        width = w; height = h; alpha = a
        x0 = minX; x1 = maxX; y0 = minY; y1 = maxY
    }

    func opaque(_ x: Int, _ y: Int) -> Bool { alpha[y * width + x] > 128 }

    /// Opaque runs of one row.
    func runs(_ y: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start = -1
        for x in 0..<width {
            let on = opaque(x, y)
            if on && start < 0 { start = x }
            if !on && start >= 0 { out.append((start, x - 1)); start = -1 }
        }
        if start >= 0 { out.append((start, width - 1)) }
        return out
    }

    struct Top {
        let y0: CGFloat, hem: CGFloat, cx: CGFloat, tw: CGFloat, left: CGFloat, right: CGFloat
        /// Sleeve root and far end per image side (L, R), when the garment has sleeves out to that side.
        let sleeves: [Bool: (root: CGPoint, far: CGPoint)]
    }

    func top() -> Top? {
        let H = y1 - y0 + 1
        var cx = CGFloat(x0 + x1) / 2
        var lefts: [Int] = [], rights: [Int] = []
        for y in (y0 + Int(0.55 * Double(H)))..<(y0 + Int(0.85 * Double(H))) {
            for (a, b) in runs(y) where CGFloat(a) <= cx && cx <= CGFloat(b) {
                lefts.append(a); rights.append(b); break
            }
        }
        guard !lefts.isEmpty else { return nil }
        let l = CGFloat(lefts.sorted()[lefts.count / 2]), r = CGFloat(rights.sorted()[rights.count / 2])
        cx = (l + r) / 2
        let tw = r - l + 1
        // Hem: the lowest opaque row in the central band.
        var hem = y0
        let bx0 = Int(cx - tw * 0.2), bx1 = Int(cx + tw * 0.2)
        for y in y0...y1 where (bx0...bx1).contains(where: { $0 >= 0 && $0 < width && opaque($0, y) }) { hem = y }
        var sleeves: [Bool: (root: CGPoint, far: CGPoint)] = [:]
        let total = alpha.reduce(0) { $0 + ($1 > 128 ? 1 : 0) }
        for left in [true, false] {
            var pts: [CGPoint] = []
            for y in y0...y1 {
                for x in x0...x1 where opaque(x, y) {
                    if left ? CGFloat(x) < l - 0.04 * tw : CGFloat(x) > r + 0.04 * tw { pts.append(CGPoint(x: x, y: y)) }
                }
            }
            guard pts.count >= max(20, total / 100) else { continue }
            let root = CGPoint(x: left ? l : r, y: CGFloat(y0) + 0.08 * CGFloat(H))
            let d = pts.map { TOGeo.dist($0, root) }
            let q = d.sorted()[Int(Double(d.count - 1) * 0.9)]
            let far = zip(pts, d).filter { $0.1 >= q }.map { $0.0 }
            let fx = far.reduce(0) { $0 + $1.x } / CGFloat(far.count), fy = far.reduce(0) { $0 + $1.y } / CGFloat(far.count)
            sleeves[left] = (root: root, far: CGPoint(x: fx, y: fy))
        }
        return Top(y0: CGFloat(y0), hem: CGFloat(hem), cx: cx, tw: tw, left: l, right: r, sleeves: sleeves)
    }

    struct Bottom {
        let y0: CGFloat, y1: CGFloat, cx: CGFloat, waistW: CGFloat, H: CGFloat
        let crotch: CGFloat?
    }

    func bottom() -> Bottom {
        let H = y1 - y0 + 1
        var ww: [Int] = []
        for y in y0...(y0 + Int(0.08 * Double(H))) {
            if let m = runs(y).map({ $0.1 - $0.0 + 1 }).max() { ww.append(m) }
        }
        let waistW = CGFloat(ww.isEmpty ? (x1 - x0) : ww.sorted()[ww.count / 2])
        let cx = CGFloat(x0 + x1) / 2
        var crotch: CGFloat?
        for y in (y0 + Int(0.15 * Double(H)))..<y1 where runs(y).count >= 2 && !opaque(Int(cx), y) {
            crotch = CGFloat(y); break
        }
        return Bottom(y0: CGFloat(y0), y1: CGFloat(y1), cx: cx, waistW: waistW, H: CGFloat(H), crotch: crotch)
    }

    /// Mean of the opaque pixels of one leg (x < cx or x >= cx) between rows.
    func meanPoint(leftOf cx: CGFloat, left: Bool, rows: ClosedRange<Int>) -> CGPoint? {
        var sx: CGFloat = 0, sy: CGFloat = 0, n: CGFloat = 0
        for y in rows where y >= 0 && y < height {
            for x in 0..<width where opaque(x, y) && ((CGFloat(x) < cx) == left) {
                sx += CGFloat(x); sy += CGFloat(y); n += 1
            }
        }
        return n > 0 ? CGPoint(x: sx / n, y: sy / n) : nil
    }
}
