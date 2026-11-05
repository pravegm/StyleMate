import CoreGraphics
import Foundation

/// Deterministic warp-and-composite of an outfit's pieces onto a body photo (approach (b) in
/// docs/TRY-ON.md). Each garment image is split into parts (torso, sleeves; hips, legs) by its
/// silhouette, and each part is mapped onto the body's own skeleton (Apple Vision body pose) with an
/// affine transform, so the piece keeps its exact colour, print and texture. Shading comes from the
/// photo; whatever the old outfit showed that the new one doesn't cover becomes skin (on the limbs)
/// or background (filled from around it). Face, hair, hands and accessories are never touched.
///
/// The geometry is identical to `tryon-lab/tryon.py` (the lab reference, measured on CC0 photos).
enum TryOnCompositor {
    struct Output {
        /// Opaque composite at body working resolution.
        var image: TryOnRaster
        /// Coverage of all new garments, 0...1 per pixel.
        var cover: [Float]
        /// Per worn piece: its id and its own coverage (before later layers / protected pixels).
        var items: [(id: UUID, role: TryOnRole, alpha: [Float])]
        /// Old clothing the new outfit doesn't cover, split into limb skin and background.
        var exposedSkin: [Bool]
        var exposedBackground: [Bool]
        /// Face / hair / hands / accessories: copied from the photo unchanged.
        var protected: [Bool]
    }

    static func composite(body: TryOnBodyModel, garments: [TryOnGarmentSpec]) -> Output? {
        let W = body.width, H = body.height
        guard let canvas = TryOnDraw.context(width: W, height: H) else { return nil }
        var items: [(UUID, TryOnRole, [Float])] = []
        for g in garments.filter({ $0.role.isWorn && $0.role != .shoes }).sorted(by: { $0.role < $1.role }) {
            let layers: [Layer]
            switch g.role {
            case .bottom: layers = placeBottom(body, g)
            case .top, .onePiece: layers = placeTop(body, g, layerScale: 1)
            case .outer: layers = placeTop(body, g, layerScale: 1.06)
            default: layers = []
            }
            guard !layers.isEmpty, let solo = TryOnDraw.context(width: W, height: H) else { continue }
            for l in layers {
                TryOnDraw.draw(l.image, in: canvas, transform: l.transform)
                TryOnDraw.draw(l.image, in: solo, transform: l.transform)
            }
            if let r = TryOnDraw.raster(solo) {
                items.append((g.id, g.role, (0..<(W * H)).map { Float(r.px[$0 * 4 + 3]) / 255 }))
            }
        }
        guard let layer = TryOnDraw.raster(canvas) else { return nil }
        let n = W * H
        var out = body.image
        let labels = body.labels

        // Shading from the photo: the lighting (side light, the shadow of an arm), not the old garment's
        // texture or sheen, which must never print through the new piece.
        let Y = TryOnPlane(width: W, height: H, v: body.image.luminance().map { $0 + 8 })
        let sc = Float(max(2, body.shoulderW / 40))
        let fine = Y.blurred(sigma: sc * 2), coarse = Y.blurred(sigma: sc * 10)
        let person = TryOnPlane(width: W, height: H, v: labels.map { $0 == TryOnLabel.background ? 0 : 1 }).blurred(sigma: 3)
        var cover = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = Float(layer.px[i * 4 + 3]) / 255
            cover[i] = a
            guard a > 0 else { continue }
            var s = fine.v[i] / max(1e-3, coarse.v[i])
            s = min(1.04, max(0.80, s))
            s = 1 + (s - 1) * person.v[i] * 0.6
            for c in 0..<3 {
                let g = min(255, Float(layer.px[i * 4 + c]) * s)
                out.px[i * 4 + c] = UInt8(min(255, max(0, Float(out.px[i * 4 + c]) * (1 - a) + g * a)))
            }
        }

        // Exposed old clothing -> skin on the limbs, background elsewhere.
        let protected = labels.map { TryOnLabel.protected.contains($0) }
        var exposed = [Bool](repeating: false, count: n)
        for i in 0..<n where TryOnLabel.clothing.contains(labels[i]) && cover[i] <= 0.4 && !protected[i] { exposed[i] = true }
        let limbs = limbMask(body)
        var skin = [Bool](repeating: false, count: n), bg = [Bool](repeating: false, count: n)
        for i in 0..<n where exposed[i] { if limbs[i] { skin[i] = true } else { bg[i] = true } }
        let tone = skinTone(body)
        for i in 0..<n where skin[i] {
            var s = fine.v[i] / max(1e-3, coarse.v[i])
            s = min(1.1, max(0.75, s))
            out.px[i * 4] = UInt8(min(255, tone.0 * s)); out.px[i * 4 + 1] = UInt8(min(255, tone.1 * s))
            out.px[i * 4 + 2] = UInt8(min(255, tone.2 * s))
        }
        if bg.contains(true) { pyramidFill(&out, holes: bg) }

        // Shoes: recolour the photo's own footwear toward the new pair (shape stays the photo's).
        if let shoes = garments.first(where: { $0.role == .shoes }), let ref = ColorStats(shoes.image) {
            recolourFeet(&out, labels: labels, to: ref)
        }

        // Protected pixels back from the photo, byte for byte.
        for i in 0..<n where protected[i] {
            out.px[i * 4] = body.image.px[i * 4]; out.px[i * 4 + 1] = body.image.px[i * 4 + 1]; out.px[i * 4 + 2] = body.image.px[i * 4 + 2]
        }
        for i in 0..<n { out.px[i * 4 + 3] = 255 }
        return Output(image: out, cover: cover, items: items.map { (id: $0.0, role: $0.1, alpha: $0.2) },
                      exposedSkin: skin, exposedBackground: bg, protected: protected)
    }

    // MARK: - Placing pieces

    struct Layer {
        let image: CGImage
        let transform: CGAffineTransform
    }

    /// Affine map taking segment a->b (garment px) onto c->d (body px); `stretch` scales only along it.
    static func similarity(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, stretch: CGFloat = 1) -> CGAffineTransform {
        let sv = TOGeo.sub(b, a), dv = TOGeo.sub(d, c)
        let ls = max(1e-6, TOGeo.len(sv)), ld = max(1e-6, TOGeo.len(dv))
        let su = TOGeo.scale(sv, 1 / ls), du = TOGeo.scale(dv, 1 / ld)
        let sp = CGVector(dx: -su.dy, dy: su.dx), dp = CGVector(dx: -du.dy, dy: du.dx)
        let along = ld / ls, perp = along / max(1e-3, stretch)
        // M = D * diag(along, perp) * S^T  (S rows = su, sp; D cols = du, dp)
        let m00 = du.dx * along * su.dx + dp.dx * perp * sp.dx
        let m01 = du.dx * along * su.dy + dp.dx * perp * sp.dy
        let m10 = du.dy * along * su.dx + dp.dy * perp * sp.dx
        let m11 = du.dy * along * su.dy + dp.dy * perp * sp.dy
        let tx = c.x - (m00 * a.x + m01 * a.y), ty = c.y - (m10 * a.x + m11 * a.y)
        return CGAffineTransform(a: m00, b: m10, c: m01, d: m11, tx: tx, ty: ty)
    }

    /// Garment x -> body `u` (scale sx), garment y -> body `v` (scale sy), garment `g` -> body `b`.
    static func axisMap(g: CGPoint, b: CGPoint, u: CGVector, v: CGVector, sx: CGFloat, sy: CGFloat) -> CGAffineTransform {
        let m00 = u.dx * sx, m10 = u.dy * sx, m01 = v.dx * sy, m11 = v.dy * sy
        return CGAffineTransform(a: m00, b: m10, c: m01, d: m11,
                                 tx: b.x - m00 * g.x - m01 * g.y, ty: b.y - m10 * g.x - m11 * g.y)
    }

    /// Shoulder line -> hem distance on the body, from the product and its length attribute.
    static func hemLength(_ body: TryOnBodyModel, _ g: TryOnGarmentSpec) -> CGFloat {
        let p = g.product.lowercased()
        let T = body.torsoLen, thigh = body.thigh, shin = body.shin
        let knee = T + thigh
        if p.contains("crop") || g.length == .cropped { return 0.72 * T }
        if g.role == .onePiece || ["dress", "gown", "anarkali", "jumpsuit"].contains(where: { p.contains($0) }) {
            switch g.length {
            case .short: return T + 0.45 * thigh
            case .kneeLength: return knee
            case .midi: return knee + 0.45 * shin
            case .fullLength: return knee + 0.95 * shin
            default: return knee * 0.95
            }
        }
        if ["trench", "overcoat", "parka", "long coat", "sherwani"].contains(where: { p.contains($0) }) { return knee + 0.15 * shin }
        if p.contains("coat") { return knee - 0.05 * thigh }
        if ["kurta", "tunic", "kurti"].contains(where: { p.contains($0) }) { return T + 0.6 * thigh }
        if ["jacket", "bomber", "blouson", "gilet", "vest"].contains(where: { p.contains($0) }) { return 1.0 * T }
        if p.contains("blazer") { return 1.12 * T }
        return 1.12 * T
    }

    /// The analysis-resolution copy of a garment with alpha outside `keep` cleared.
    private static func masked(_ shape: TryOnGarmentShape, _ base: TryOnRaster, keep: (Int, Int) -> Bool) -> CGImage? {
        var r = base
        for y in 0..<r.height {
            for x in 0..<r.width where !keep(x, y) { r.px[(y * r.width + x) * 4 + 3] = 0 }
        }
        return r.cgImage()
    }

    static func placeTop(_ body: TryOnBodyModel, _ g: TryOnGarmentSpec, layerScale: CGFloat) -> [Layer] {
        guard let shape = TryOnGarmentShape(g.image, maxSide: 640), let t = shape.top(),
              let base = TryOnRaster(g.image, width: shape.width, height: shape.height) else { return [] }
        let s = body.chestW * g.fitFactor * layerScale / t.tw
        let gSh = CGPoint(x: t.cx, y: t.y0 + 0.10 * t.tw)
        let bSh = TOGeo.add(body.shoMid, body.v, -0.06 * body.shoulderW)
        let gLen = max(1, t.hem - gSh.y)
        let sy = hemLength(body, g) / gLen
        var layers: [Layer] = []
        let x0 = t.left - 0.04 * t.tw, x1 = t.right + 0.04 * t.tw
        if let torso = masked(shape, base, keep: { x, _ in CGFloat(x) >= x0 && CGFloat(x) <= x1 }) {
            layers.append(Layer(image: torso, transform: axisMap(g: gSh, b: bSh, u: body.u, v: body.v, sx: s, sy: sy)))
        }
        for (left, sl) in t.sleeves {
            let (S, E, Wr) = body.arm(left)
            let sel: (Int) -> Bool = { x in left ? CGFloat(x) < t.left - 0.04 * t.tw : CGFloat(x) > t.right + 0.04 * t.tw }
            let Lg = max(1, TOGeo.dist(sl.far, sl.root))
            var Lb = Lg * s
            let upper = TOGeo.dist(E, S), armLen = upper + TOGeo.dist(Wr, E)
            if (g.sleeve == .longSleeve || g.role == .outer) && Lb > 0.6 * armLen { Lb = armLen * 1.02 }
            if g.sleeve == .sleeveless { continue }
            let outward = TOGeo.unit(TOGeo.sub(S, body.shoMid))
            let rootB = TOGeo.add(S, outward, 0.06 * body.shoulderW)
            let stretch = Lb / (Lg * s)
            if Lb <= upper * 1.05 {
                let end = TOGeo.add(rootB, TOGeo.unit(TOGeo.sub(E, S)), Lb)
                if let img = masked(shape, base, keep: { x, _ in sel(x) }) {
                    layers.append(Layer(image: img, transform: similarity(sl.root, sl.far, rootB, end, stretch: stretch)))
                }
            } else {
                let f = upper / Lb
                let midG = CGPoint(x: sl.root.x + (sl.far.x - sl.root.x) * f, y: sl.root.y + (sl.far.y - sl.root.y) * f)
                let gu = TOGeo.unit(TOGeo.sub(sl.far, sl.root))
                func proj(_ x: Int, _ y: Int) -> CGFloat { TOGeo.dot(CGVector(dx: CGFloat(x) - sl.root.x, dy: CGFloat(y) - sl.root.y), gu) }
                let end2 = TOGeo.add(E, TOGeo.unit(TOGeo.sub(Wr, E)), Lb - upper)
                // Lower part first, so the upper sleeve overlaps it at the elbow.
                if let lo = masked(shape, base, keep: { x, y in sel(x) && proj(x, y) >= f * Lg - 0.03 * Lg }) {
                    layers.append(Layer(image: lo, transform: similarity(midG, sl.far, E, end2, stretch: stretch)))
                }
                if let up = masked(shape, base, keep: { x, y in sel(x) && proj(x, y) <= f * Lg + 0.03 * Lg }) {
                    layers.append(Layer(image: up, transform: similarity(sl.root, midG, rootB, E, stretch: stretch)))
                }
            }
        }
        return layers   // torso first, then sleeves (drawn over the torso edge)
    }

    static let fullLength = ["jeans", "trousers", "pants", "leggings", "joggers", "chinos", "sweatpants", "cargo",
                             "palazzo", "salwar", "churidar", "dhoti", "jeggings", "track"]

    static func placeBottom(_ body: TryOnBodyModel, _ g: TryOnGarmentSpec) -> [Layer] {
        guard let shape = TryOnGarmentShape(g.image, maxSide: 640),
              let base = TryOnRaster(g.image, width: shape.width, height: shape.height) else { return [] }
        let b = shape.bottom()
        let s = body.hipW * g.fitFactor / max(1, b.waistW)
        let bWaist = TOGeo.add(body.hipMid, body.v, -0.18 * body.torsoLen)
        let gWaist = CGPoint(x: b.cx, y: b.y0)
        let p = g.product.lowercased()
        let full = fullLength.contains(where: { p.contains($0) })
        let legged = full || p.contains("short")
        var crotch = b.crotch
        if crotch == nil && legged { crotch = b.y0 + 0.34 * b.H }
        guard let cr = crotch else {
            // A skirt (or shorts that read as one piece): keeps its own shape and length.
            let img = base.cgImage()
            return img.map { [Layer(image: $0, transform: axisMap(g: gWaist, b: bWaist, u: body.u, v: body.v, sx: s, sy: s))] } ?? []
        }
        var layers: [Layer] = []
        let bCrotch = TOGeo.add(body.hipMid, body.v, 0.16 * body.thigh)
        let sy = TOGeo.dot(TOGeo.sub(bCrotch, bWaist), body.v) / max(1, cr - b.y0)
        let hipT = axisMap(g: gWaist, b: bWaist, u: body.u, v: body.v, sx: s, sy: sy)
        if let hips = masked(shape, base, keep: { _, y in CGFloat(y) <= cr + 3 }) {
            layers.append(Layer(image: hips, transform: hipT))
        }
        for left in [true, false] {
            let (Hj, K, A) = body.leg(left)
            let side: (Int) -> Bool = { x in (CGFloat(x) < b.cx) == left }
            guard var root = shape.meanPoint(leftOf: b.cx, left: left, rows: Int(cr)...Int(cr + 0.04 * b.H)),
                  let hem = shape.meanPoint(leftOf: b.cx, left: left, rows: Int(b.y1 - 0.04 * b.H)...Int(b.y1)) else { continue }
            root.y = cr
            let tdir = TOGeo.unit(TOGeo.sub(K, Hj))
            let along = TOGeo.dot(TOGeo.sub(bCrotch, Hj), body.v) / max(1e-3, TOGeo.dot(tdir, body.v))
            let shift = (s * (root.x - b.cx) - TOGeo.dot(TOGeo.sub(Hj, body.hipMid), body.u)) * 0.5
            let rootB = TOGeo.add(TOGeo.add(Hj, tdir, along), body.u, shift)
            let Lg = max(1, TOGeo.dist(hem, root))
            let thigh = TOGeo.dist(K, rootB), shin = TOGeo.dist(A, K)
            var Lb = Lg * s
            if full { Lb = thigh + shin * 0.97 }
            let stretch = Lb / (Lg * s)
            if Lb <= thigh * 1.05 {
                let end = TOGeo.add(rootB, TOGeo.unit(TOGeo.sub(K, rootB)), Lb)
                if let img = masked(shape, base, keep: { x, y in side(x) && CGFloat(y) >= cr - 2 }) {
                    layers.append(Layer(image: img, transform: similarity(root, hem, rootB, end, stretch: stretch)))
                }
            } else {
                let f = thigh / Lb
                let midG = CGPoint(x: root.x + (hem.x - root.x) * f, y: root.y + (hem.y - root.y) * f)
                let gu = TOGeo.unit(TOGeo.sub(hem, root))
                func proj(_ x: Int, _ y: Int) -> CGFloat { TOGeo.dot(CGVector(dx: CGFloat(x) - root.x, dy: CGFloat(y) - root.y), gu) }
                let end2 = TOGeo.add(K, TOGeo.unit(TOGeo.sub(A, K)), Lb - thigh)
                if let lo = masked(shape, base, keep: { x, y in side(x) && CGFloat(y) >= cr - 2 && proj(x, y) >= f * Lg - 0.02 * Lg }) {
                    layers.append(Layer(image: lo, transform: similarity(midG, hem, K, end2, stretch: stretch)))
                }
                if let up = masked(shape, base, keep: { x, y in side(x) && CGFloat(y) >= cr - 2 && proj(x, y) <= f * Lg + 0.02 * Lg }) {
                    layers.append(Layer(image: up, transform: similarity(root, midG, rootB, K, stretch: stretch)))
                }
            }
        }
        return layers
    }

    // MARK: - Skin, background, shoes

    /// Arm and leg capsules from the pose (where uncovered old clothing becomes skin).
    static func limbMask(_ body: TryOnBodyModel) -> [Bool] {
        let W = body.width, H = body.height
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = ctx.data else { return [Bool](repeating: false, count: W * H) }
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        let rad = max(2, 0.11 * body.shoulderW)
        for left in [true, false] {
            let (S, E, Wr) = body.arm(left)
            ctx.setLineWidth(rad)
            ctx.strokeLineSegments(between: [S, E, E, Wr])
            let (Hj, K, A) = body.leg(left)
            ctx.setLineWidth(rad * 1.5)
            ctx.strokeLineSegments(between: [Hj, K, K, A])
        }
        // The neck, chin to the shoulder line (a high collar the new top doesn't have).
        ctx.setLineWidth(max(2, 0.25 * body.shoulderW))
        ctx.strokeLineSegments(between: [body.pose.nose, body.shoMid])
        let p = data.assumingMemoryBound(to: UInt8.self)
        var out = [Bool](repeating: false, count: W * H)
        for y in 0..<H { for x in 0..<W { out[y * W + x] = p[y * ctx.bytesPerRow + x] > 127 } }
        return out
    }

    /// Median colour of the visible skin (face, hands, arms, legs).
    static func skinTone(_ body: TryOnBodyModel) -> (Float, Float, Float) {
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        var n = 0
        for i in 0..<(body.width * body.height) where TryOnLabel.skin.contains(body.labels[i]) {
            for c in 0..<3 { hist[c][Int(body.image.px[i * 4 + c])] += 1 }
            n += 1
        }
        guard n > 50 else { return (200, 160, 140) }
        func median(_ h: [Int]) -> Float {
            var acc = 0
            for (v, c) in h.enumerated() { acc += c; if acc * 2 >= n { return Float(v) } }
            return 128
        }
        return (median(hist[0]), median(hist[1]), median(hist[2]))
    }

    /// Push-pull fill: holes take the weighted average of their surroundings, coarse to fine.
    static func pyramidFill(_ img: inout TryOnRaster, holes: [Bool]) {
        struct Level { var w: Int; var h: Int; var c: [Float]; var wt: [Float] }
        var levels: [Level] = []
        var cur = Level(w: img.width, h: img.height, c: [Float](repeating: 0, count: img.width * img.height * 3),
                        wt: holes.map { $0 ? 0 : 1 })
        for i in 0..<(cur.w * cur.h) where cur.wt[i] > 0 {
            for k in 0..<3 { cur.c[i * 3 + k] = Float(img.px[i * 4 + k]) }
        }
        levels.append(cur)
        while cur.w > 4 && cur.h > 4 && cur.wt.contains(0) {
            let nw = (cur.w + 1) / 2, nh = (cur.h + 1) / 2
            var nx = Level(w: nw, h: nh, c: [Float](repeating: 0, count: nw * nh * 3), wt: [Float](repeating: 0, count: nw * nh))
            for y in 0..<cur.h {
                for x in 0..<cur.w {
                    let i = y * cur.w + x, j = (y / 2) * nw + x / 2
                    let w = cur.wt[i]
                    guard w > 0 else { continue }
                    nx.wt[j] += w
                    for k in 0..<3 { nx.c[j * 3 + k] += cur.c[i * 3 + k] * w }
                }
            }
            for j in 0..<(nw * nh) where nx.wt[j] > 0 {
                for k in 0..<3 { nx.c[j * 3 + k] /= nx.wt[j] }
                nx.wt[j] = min(1, nx.wt[j])
            }
            levels.append(nx)
            cur = nx
        }
        // Pull: fill each level's empty pixels from the coarser one.
        if levels.count > 1 {
            for li in stride(from: levels.count - 2, through: 0, by: -1) {
                let coarse = levels[li + 1]
                var fine = levels[li]
                for y in 0..<fine.h {
                    for x in 0..<fine.w {
                        let i = y * fine.w + x
                        let w = fine.wt[i]
                        guard w < 1 else { continue }
                        let j = min(coarse.h - 1, y / 2) * coarse.w + min(coarse.w - 1, x / 2)
                        for k in 0..<3 { fine.c[i * 3 + k] = fine.c[i * 3 + k] * w + coarse.c[j * 3 + k] * (1 - w) }
                        fine.wt[i] = 1
                    }
                }
                levels[li] = fine
            }
        }
        let top = levels[0]
        for i in 0..<(img.width * img.height) where holes[i] {
            for k in 0..<3 { img.px[i * 4 + k] = UInt8(min(255, max(0, top.c[i * 3 + k]))) }
        }
    }

    /// Moves the photo's footwear pixels toward the new pair's colour statistics (Lab mean / spread),
    /// keeping the photo's shading.
    static func recolourFeet(_ img: inout TryOnRaster, labels: [UInt8], to ref: ColorStats) {
        var idx: [Int] = []
        for i in 0..<labels.count where labels[i] == TryOnLabel.feet { idx.append(i) }
        guard idx.count > 30 else { return }
        var labs: [(Float, Float, Float)] = idx.map {
            ColorNamer.lab(Float(img.px[$0 * 4]) / 255, Float(img.px[$0 * 4 + 1]) / 255, Float(img.px[$0 * 4 + 2]) / 255)
        }
        let n = Float(labs.count)
        let m = labs.reduce((Float(0), Float(0), Float(0))) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let mean = (m.0 / n, m.1 / n, m.2 / n)
        let sL = sqrt(labs.reduce(0) { $0 + pow($1.0 - mean.0, 2) } / n) + 1e-3
        for (k, i) in idx.enumerated() {
            var (L, A, B) = labs[k]
            L = (L - mean.0) * min(1.5, ref.std.0 / sL) * 0.8 + ref.mean.0
            A = (A - mean.1) * 0.3 + ref.mean.1
            B = (B - mean.2) * 0.3 + ref.mean.2
            labs[k] = (L, A, B)
            let (r, g, b) = ColorStats.labToRGB(min(100, max(0, L)), A, B)
            img.px[i * 4] = UInt8(r * 255); img.px[i * 4 + 1] = UInt8(g * 255); img.px[i * 4 + 2] = UInt8(b * 255)
        }
    }
}
