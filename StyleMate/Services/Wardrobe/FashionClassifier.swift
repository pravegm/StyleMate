import CoreGraphics
import UIKit

/// Names an item cutout: category + product, pattern, material, fit, neckline,
/// sleeve and length via FashionSigLIP zero-shot against the bundled
/// vocabulary, and colours by clustering the actual fabric pixels.
enum FashionClassifier {
    struct Attributes {
        let category: Category
        let product: String
        let colors: [String]
        let pattern: Pattern
        let material: String?
        let fit: Fit?
        let neckline: Neckline?
        let sleeveLength: SleeveLength?
        let garmentLength: GarmentLength?
        let embedding: [Float]
        /// The kind the product implies — may differ from the segmentation's
        /// guess (a back-view coat the labeler called a dress).
        var kind: GarmentKind = .innerTop
    }

    /// What the extractor knows about the view that the cutout alone doesn't show.
    struct Context {
        /// An inner top seen only between the halves of an open layer, or cut
        /// off by the photo frame: its silhouette looks sleeveless / strapless
        /// whatever it really is.
        var occluded = false
        var parts: GarmentInstance.PartShares?
        /// Neckwear the segmenter confirmed as a tie (narrow strip below the collar);
        /// otherwise "Ties" / "Bowties" are not on offer.
        var allowTie = true
        static let none = Context()
    }

    /// The likely garments for a top we only see part of.
    static let occludedTops: Set<String> = ["Tops|T-Shirts", "Tops|Tank Tops", "Tops|Shirts", "Tops|Blouses",
                                            "Tops|Turtlenecks", "Mid-Layers|Sweaters"]
    /// Zero-shot over-predicts these (strange shapes of partial views); a small
    /// prior keeps them for clear cases.
    static let priors: [String: Float] = [
        "Tops|Tube Tops": -0.03, "Tops|Halter Tops": -0.03, "Tops|Corset Tops": -0.03, "Tops|Mesh Tops": -0.03,
        "Tops|Bodysuits": -0.03, "Mid-Layers|Shrugs": -0.02, "Outerwear|Capes": -0.02, "Mid-Layers|Ponchos": -0.02,
        "Accessories|Berets": -0.02, "One-Pieces|Gowns": -0.02
    ]
    /// Prints zero-shot hallucinates on plain fabric (distressed denim → tie-dye,
    /// a grey coat → houndstooth): they need a clearer margin over Solid.
    static let rarePrints: Set<String> = ["Tie-Dye", "Camouflage", "Houndstooth", "Paisley", "Animal Print"]

    private static let upperGroups: [(GarmentKind, String)] = [(.innerTop, "upper_inner"), (.outerLayer, "upper_outer"), (.onePiece, "onepiece")]

    static func classify(_ cutout: UIImage, kind: GarmentKind, scene: SceneLight = .neutral, context: Context = .none) -> Attributes? {
        guard let cg = cutout.cgImage else { return nil }
        let ml = WardrobeML.shared
        guard let vocab = ml.vocabulary, let input = onWhite(cg, side: 224),
              let emb = ml.embed(input) else { return nil }

        // Product (also fixes the category: "Mid-Layers|Hoodies").
        var resolvedKind = kind
        var scored: [String: Float] = [:]
        let isUpper = upperGroups.contains { $0.0 == kind }
        if isUpper && !(kind == .innerTop && context.occluded) {
            // Coat vs dress vs top: score all three groups, the segmentation's
            // own group a little ahead, and let a clearly better one win.
            var owner: [String: GarmentKind] = [:]
            for (k, group) in upperGroups {
                for (label, s) in vocab.scores(in: group, for: emb) {
                    let v = s + (k == kind ? 0.02 : 0)
                    if v > (scored[label] ?? -.infinity) { scored[label] = v; owner[label] = k }
                }
            }
            if let parts = context.parts {
                // Hood only with a hood; lapels support tailored coats and blazers.
                if parts.hood < 0.015 { scored["Mid-Layers|Hoodies"] = nil }
                if parts.lapel >= 0.01 {
                    for l in ["Outerwear|Coats", "Outerwear|Overcoats", "Outerwear|Blazers", "Outerwear|Trench Coats"] where scored[l] != nil {
                        scored[l]! += 0.015
                    }
                }
            }
            for (l, p) in priors where scored[l] != nil { scored[l]! += p }
            if let best = scored.max(by: { $0.value < $1.value }) { resolvedKind = owner[best.key] ?? kind }
        } else if let group = kind.vocabularyGroup {
            scored = vocab.scores(in: group, for: emb)
            if kind == .innerTop && context.occluded { scored = scored.filter { occludedTops.contains($0.key) } }
            if kind == .neckwear && !context.allowTie {
                scored["Accessories|Ties"] = nil; scored["Accessories|Bowties"] = nil
            }
            for (l, p) in priors where scored[l] != nil { scored[l]! += p }
        }
        var category: Category = defaultCategory(resolvedKind)
        var product = defaultProduct(resolvedKind)
        if let best = scored.max(by: { $0.value < $1.value }) {
            let parts = best.key.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let c = Category(rawValue: parts[0]) { category = c; product = parts[1] }
        }

        let isGarment = ![GarmentKind.footwear, .eyewear, .headwear, .bag, .belt, .jewelry].contains(resolvedKind)
        var material: String?
        if let allowed = Self.materials(for: resolvedKind),
           let m = vocab.best(in: "material", for: emb, allowed: { allowed.isEmpty || allowed.contains($0) }),
           m.margin > 0.004 {
            material = m.label
        }
        let clusters = ColorNamer.clusters(cg, scene: scene)
        // A print must clearly beat "Solid" — zero-shot happily calls a plain grey
        // jersey "houndstooth" by a hair; rare prints need a bigger margin, and
        // denim's wash and rips are not a print.
        var pattern: Pattern = .solid
        let ps = vocab.scores(in: "pattern", for: emb)
        let denim = material == "Denim" || product.lowercased().contains("jean") || product.lowercased().contains("denim")
        if var solid = ps["Solid"] {
            if denim, let d = ps["Solid Denim"] { solid = max(solid, d) }
            if let best = ps.filter({ $0.key != "Solid" && $0.key != "Solid Denim" }).max(by: { $0.value < $1.value }),
               let p = Pattern(rawValue: best.key),
               best.value - solid > (rarePrints.contains(best.key) ? 0.05 : 0.02) {
                pattern = p
            }
        }
        // One colour family throughout (all sizeable clusters within ΔE 15 of the
        // main one) is plain fabric whatever the encoder thinks.
        if pattern != .solid, let main = clusters.first {
            let sizeable = clusters.filter { $0.share >= 0.1 }
            let spread = sizeable.map { c in
                sqrt(pow(c.lab.0 - main.lab.0, 2) + pow(c.lab.1 - main.lab.1, 2) + pow(c.lab.2 - main.lab.2, 2))
            }.max() ?? 0
            if spread < 15 { pattern = .solid }
        }

        func attr<T: RawRepresentable>(_ group: String, _ type: T.Type, when ok: Bool,
                                       allowed: ((String) -> Bool)? = nil) -> T? where T.RawValue == String {
            guard ok, let b = vocab.best(in: group, for: emb, allowed: allowed), b.margin > 0.003 else { return nil }
            return T(rawValue: b.label)
        }
        let partial = context.occluded && resolvedKind == .innerTop
        let fit: Fit? = attr("fit", Fit.self, when: isGarment && category.supportsFit)
        let noHood = (context.parts?.hood ?? 1) < 0.015
        let neckline: Neckline? = attr("neckline", Neckline.self,
                                       when: category.supportsNeckline && resolvedKind != .outerLayer && !partial,
                                       allowed: { !(noHood && $0 == "Hooded") })
        // Sleeves the labeler can see rule out "sleeveless".
        let hasSleeves = (context.parts?.sleeve ?? 0) >= 0.05
        let sleeve: SleeveLength? = attr("sleeve", SleeveLength.self, when: category.supportsSleeves && !partial,
                                         allowed: { !(hasSleeves && $0 == "Sleeveless") })
        // Trouser-type bottoms have a length by definition; only skirts, dresses
        // and coats really vary, so only they are asked.
        let length: GarmentLength? = {
            guard category.supportsLength else { return nil }
            let p = product.lowercased()
            if p.contains("short") { return .short }
            if ["jeans", "trousers", "chinos", "cargo pants", "wide-leg pants", "palazzo pants", "linen pants",
                "sweatpants", "joggers", "leggings", "track pants", "yoga pants", "salwar", "churidar"].contains(p) {
                return .fullLength
            }
            return attr("length", GarmentLength.self, when: true)
        }()

        let colors = clusters.filter { $0.share >= 0.15 || $0.first }.map { $0.name }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3).map { $0 }
        return Attributes(category: category, product: product, colors: colors.isEmpty ? ["Black"] : colors,
                          pattern: pattern, material: material, fit: fit, neckline: neckline,
                          sleeveLength: sleeve, garmentLength: length, embedding: emb, kind: resolvedKind)
    }

    /// Plausible materials per kind (nil = don't name a material; empty = any).
    private static func materials(for k: GarmentKind) -> Set<String>? {
        switch k {
        case .eyewear, .jewelry: return nil
        case .footwear: return ["Leather", "Faux Leather", "Suede", "Canvas", "Mesh", "Knit", "Nylon"]
        case .bag: return ["Leather", "Faux Leather", "Nylon", "Canvas", "Suede"]
        case .belt: return ["Leather", "Faux Leather", "Canvas"]
        case .headwear: return ["Cotton", "Wool", "Knit", "Canvas", "Denim", "Leather", "Suede", "Nylon", "Fleece"]
        case .neckwear: return ["Silk", "Satin", "Wool", "Knit", "Cotton", "Polyester", "Linen"]
        default: return []
        }
    }

    private static func defaultCategory(_ k: GarmentKind) -> Category {
        switch k {
        case .innerTop: return .tops
        case .outerLayer: return .outerwear
        case .onePiece: return .onePieces
        case .lower: return .bottoms
        case .footwear: return .footwear
        default: return .accessories
        }
    }

    private static func defaultProduct(_ k: GarmentKind) -> String {
        switch k {
        case .innerTop: return "T-Shirts"
        case .outerLayer: return "Jackets"
        case .onePiece: return "Dresses"
        case .lower: return "Trousers"
        case .footwear: return "Sneakers"
        case .eyewear: return "Sunglasses"
        case .headwear: return "Baseball Caps"
        case .bag: return "Handbags"
        case .neckwear: return "Scarves"
        case .belt: return "Belts"
        case .jewelry: return "Watches"
        }
    }

    /// Composites a transparent cutout onto white, centred in a square — the
    /// e-commerce framing the fashion encoder was trained on.
    static func onWhite(_ image: CGImage, side: Int) -> CGImage? {
        let s = CGFloat(side)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let k = s / max(w, h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (s - w * k) / 2, y: (s - h * k) / 2, width: w * k, height: h * k))
        return ctx.makeImage()
    }
}

/// The scene's light, measured once per photo, so a white shirt in warm
/// evening light or a dim corridor is still named for its own colour: a
/// damped white balance from the brightest unclipped pixels, plus a small
/// exposure lift for dark photos (98th-percentile luminance).
struct SceneLight {
    /// Per-channel gain in linear RGB.
    let gain: (Float, Float, Float)
    static let neutral = SceneLight(gain: (1, 1, 1))

    init(gain: (Float, Float, Float)) { self.gain = gain }

    init(photo: CGImage) {
        let w = 96, h = max(1, Int(96 * Double(photo.height) / Double(max(1, photo.width))))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { self.gain = (1, 1, 1); return }
        ctx.interpolationQuality = .medium
        ctx.draw(photo, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { self.gain = (1, 1, 1); return }
        let p = data.assumingMemoryBound(to: UInt8.self)
        var lin: [(Float, Float, Float)] = [], lum: [Float] = [], maxc: [Float] = []
        for i in 0..<(w * h) {
            let r = Float(p[i * 4]) / 255, g = Float(p[i * 4 + 1]) / 255, b = Float(p[i * 4 + 2]) / 255
            let l = (ColorNamer.linear(r), ColorNamer.linear(g), ColorNamer.linear(b))
            lin.append(l); lum.append(0.2126 * l.0 + 0.7152 * l.1 + 0.0722 * l.2); maxc.append(max(r, g, b))
        }
        let sorted = lum.sorted()
        let p95 = sorted[Int(Float(sorted.count - 1) * 0.95)], p98 = sorted[Int(Float(sorted.count - 1) * 0.98)]
        var acc: (Float, Float, Float) = (0, 0, 0), n: Float = 0
        for i in 0..<lin.count where lum[i] >= p95 && maxc[i] < 0.98 {
            acc.0 += lin[i].0; acc.1 += lin[i].1; acc.2 += lin[i].2; n += 1
        }
        var g: (Float, Float, Float) = (1, 1, 1)
        if n >= 20 {
            let ill = (max(acc.0 / n, 1e-4), max(acc.1 / n, 1e-4), max(acc.2 / n, 1e-4))
            let m = (ill.0 + ill.1 + ill.2) / 3
            func damp(_ x: Float) -> Float { min(max(pow(m / x, 0.35), 0.9), 1.12) }
            g = (damp(ill.0), damp(ill.1), damp(ill.2))
        }
        let expo = min(max(0.85 / max(p98, 1e-3), 1), 1.12)
        gain = (g.0 * expo, g.1 * expo, g.2 * expo)
    }
}

/// Measures an item's colours from its fabric pixels (k-means in CIELAB) and
/// names them with the app's colour vocabulary (the names ColorMapping draws).
///
/// Naming goes by hue family (the angle of a/b), then lightness and chroma
/// within it, rather than to the nearest palette swatch: a mid-blue denim is
/// low-chroma (C≈11) and used to lose to Charcoal, a dusty-pink coat to Gray.
/// The anchors the old palette lacked are folded into the families: denim →
/// Blue, dusty pink → Pink, camel → Tan, ivory → Cream.
enum ColorNamer {
    struct Cluster {
        var lab: (Float, Float, Float)
        var count: Int
        var name: String
    }

    /// 1–3 colour names, most dominant first; secondary colours need >= 15% share.
    static func dominantColors(_ image: CGImage, scene: SceneLight = .neutral) -> [String] {
        clusters(image, scene: scene).filter { $0.share >= 0.15 || $0.first }.map { $0.name }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(3).map { $0 }
    }

    /// Merged colour clusters, largest first, with their share of the fabric.
    static func clusters(_ image: CGImage, scene: SceneLight = .neutral) -> [(name: String, lab: (Float, Float, Float), share: Float, first: Bool)] {
        let samples = fabricSamples(image, scene: scene)
        guard samples.count > 30 else { return [] }
        let k = 5
        // k-means, deterministic init from luminance quantiles.
        let sorted = samples.sorted { $0.0 < $1.0 }
        var centers = (0..<k).map { sorted[min(sorted.count - 1, Int((Double($0) + 0.5) / Double(k) * Double(sorted.count)))] }
        var assign = [Int](repeating: 0, count: samples.count)
        for _ in 0..<12 {
            for (i, s) in samples.enumerated() {
                var best = 0, bd = Float.infinity
                for (c, ctr) in centers.enumerated() {
                    let d = dist(s, ctr); if d < bd { bd = d; best = c }
                }
                assign[i] = best
            }
            var acc = [(Float, Float, Float)](repeating: (0, 0, 0), count: k), cnt = [Int](repeating: 0, count: k)
            for (i, s) in samples.enumerated() {
                let c = assign[i]; acc[c].0 += s.0; acc[c].1 += s.1; acc[c].2 += s.2; cnt[c] += 1
            }
            for c in 0..<k where cnt[c] > 0 {
                let m = Float(cnt[c]); centers[c] = (acc[c].0 / m, acc[c].1 / m, acc[c].2 / m)
            }
        }
        var counts = [Int](repeating: 0, count: k)
        for a in assign { counts[a] += 1 }
        var raw = (0..<k).filter { counts[$0] > 0 }.map { Cluster(lab: centers[$0], count: counts[$0], name: name(centers[$0])) }
        raw.sort { $0.count > $1.count }

        // Merge shades of one colour: same name, close in Lab, a shadow of the
        // same hue, or a lighter/darker band of a neutral.
        var merged: [Cluster] = []
        for x in raw {
            var target: Int?
            var chromaMerge = false
            for (j, y) in merged.enumerated() {
                let dE = sqrt(pow(x.lab.0 - y.lab.0, 2) + pow(x.lab.1 - y.lab.1, 2) + pow(x.lab.2 - y.lab.2, 2))
                let c1 = hypot(x.lab.1, x.lab.2), c2 = hypot(y.lab.1, y.lab.2)
                let h1 = atan2(x.lab.2, x.lab.1) * 180 / .pi, h2 = atan2(y.lab.2, y.lab.1) * 180 / .pi
                let dh = abs((h1 - h2 + 540).truncatingRemainder(dividingBy: 360) - 180)
                let dL = abs(x.lab.0 - y.lab.0)
                let chroma = c1 >= 8 && c2 >= 8 && dh < 25 && dL < 30
                let neutral = c1 < 8 && c2 < 8 && dL < 25
                if x.name == y.name || dE < 12 || chroma || neutral {
                    target = j; chromaMerge = c1 >= 8 && c2 >= 8 && dh < 25
                    break
                }
            }
            if let j = target {
                let w = merged[j].count + x.count
                if chromaMerge {   // a shade of the same colour: name the average
                    let a = Float(merged[j].count) / Float(w), b = Float(x.count) / Float(w)
                    merged[j].lab = (merged[j].lab.0 * a + x.lab.0 * b, merged[j].lab.1 * a + x.lab.1 * b, merged[j].lab.2 * a + x.lab.2 * b)
                    merged[j].name = name(merged[j].lab)
                }
                merged[j].count = w
            } else {
                merged.append(x)
            }
        }
        merged.sort { $0.count > $1.count }
        let total = Float(merged.reduce(0) { $0 + $1.count })
        return merged.enumerated().map { (i, c) in (name: c.name, lab: c.lab, share: Float(c.count) / total, first: i == 0) }
    }

    /// Lab samples of solid fabric: alpha > 0.9 and 3 px inside the cutout's
    /// edge (soft edges carry background colour), scene-corrected.
    private static func fabricSamples(_ image: CGImage, scene: SceneLight) -> [(Float, Float, Float)] {
        guard let px = GarmentCutout.rgbaPixels(image) else { return [] }
        let w = image.width, h = image.height
        let step = max(1, Int(sqrt(Double(w * h) / 6000)))
        func solid(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < w, y < h else { return false }
            return px[(y * w + x) * 4 + 3] > 230
        }
        var inner: [(Float, Float, Float)] = [], all: [(Float, Float, Float)] = []
        let e = 3
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) where solid(x, y) {
                let o = (y * w + x) * 4
                let a = Float(px[o + 3]) / 255
                let r = linear(Float(px[o]) / 255 / a) * scene.gain.0
                let g = linear(Float(px[o + 1]) / 255 / a) * scene.gain.1
                let b = linear(Float(px[o + 2]) / 255 / a) * scene.gain.2
                let s = labFromLinear(min(r, 1), min(g, 1), min(b, 1))
                all.append(s)
                if solid(x - e, y) && solid(x + e, y) && solid(x, y - e) && solid(x, y + e)
                    && solid(x - e, y - e) && solid(x + e, y + e) && solid(x - e, y + e) && solid(x + e, y - e) {
                    inner.append(s)
                }
            }
        }
        return inner.count > 200 ? inner : all
    }

    /// The app's colour name for a Lab colour.
    static func name(_ c: (Float, Float, Float)) -> String {
        let L = c.0, C = hypot(c.1, c.2)
        var h = atan2(c.2, c.1) * 180 / .pi
        if h < 0 { h += 360 }
        let warm = h >= 35 && h < 110
        func neutral() -> String {
            switch L {
            case ..<31: return "Black"
            case ..<38: return "Charcoal"
            case ..<62: return "Gray"
            case ..<76: return "Silver"
            default: return "White"
            }
        }
        // How much chroma it takes to count as a colour: cool tints on a grey
        // and colour noise in very dark or very light fabric don't.
        var minC: Float = (h >= 200 && h < 300) ? 9 : (h >= 290 || h < 20) ? 8 : 5
        if L > 70 && !warm { minC = max(minC, 14) }
        if L < 25 { minC = max(minC, 14) }
        if C < 5 || (C < minC && !warm) { return neutral() }
        if warm && C < 8 && L >= 72 { return neutral() }          // off-white
        if warm && C < 20 {                                         // ivory / beige / camel / brown
            if L >= 72 && C < 14 { return "Cream" }
            if L >= 80 { return "Cream" }
            if L >= 66 { return "Beige" }
            if L >= 42 { return "Tan" }
            return L >= 22 ? "Brown" : "Black"
        }
        // Dark blues sit on the blue/purple hue boundary (rgb 20,30,70 is h≈293):
        // navy is one of the commonest wardrobe colours, so it wins there.
        if L < 32 && h >= 240 && h < 305 { return "Navy" }
        switch h {
        case 345..., ..<20:                                         // reds and pinks
            if L < 32 { return C >= 15 ? "Burgundy" : "Charcoal" }
            if L > 50 && C < 30 { return "Pink" }                   // dusty pink
            if L > 62 { return "Pink" }
            return "Red"
        case ..<45:
            if C < 20 { return L < 45 ? "Brown" : "Tan" }
            if L > 62 { return "Coral" }
            if L < 36 { return "Maroon" }
            return h < 32 ? "Red" : "Rust"
        case ..<75:
            if C < 45 { return L < 45 ? "Brown" : L < 72 ? "Tan" : "Beige" }
            return L >= 50 ? "Orange" : "Rust"
        case ..<105:
            if L < 55 { return h > 92 ? "Olive" : "Khaki" }
            return C > 45 ? "Yellow" : h < 92 ? "Gold" : "Khaki"
        case ..<165:
            if L < 45 && h < 125 { return "Olive" }
            return L > 75 ? "Mint" : "Green"
        case ..<200:
            return L < 70 ? "Teal" : "Mint"
        case ..<290:                                                // blues, denim included
            return L < 30 ? "Navy" : L < 58 ? "Blue" : "Light Blue"
        case ..<330:
            return L > 60 ? "Lavender" : "Purple"
        default:
            return L > 50 ? "Pink" : L < 35 ? "Burgundy" : "Purple"
        }
    }

    private static func dist(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let dl = a.0 - b.0, da = a.1 - b.1, db = a.2 - b.2
        return dl * dl * 0.6 + da * da + db * db     // lightness counts less: lighting varies
    }

    static func linear(_ c: Float) -> Float {
        let v = min(max(c, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Linear RGB (0...1) → CIELAB (D65).
    static func labFromLinear(_ R: Float, _ G: Float, _ B: Float) -> (Float, Float, Float) {
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// sRGB (0...1) → CIELAB (D65).
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        labFromLinear(linear(r), linear(g), linear(b))
    }
}
