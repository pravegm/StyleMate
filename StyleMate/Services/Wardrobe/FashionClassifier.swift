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
    }

    static func classify(_ cutout: UIImage, kind: GarmentKind) -> Attributes? {
        guard let cg = cutout.cgImage else { return nil }
        let ml = WardrobeML.shared
        guard let vocab = ml.vocabulary, let input = onWhite(cg, side: 224),
              let emb = ml.embed(input) else { return nil }

        // Product (also fixes the category: "Mid-Layers|Hoodies").
        var category: Category = defaultCategory(kind)
        var product = defaultProduct(kind)
        if let group = kind.vocabularyGroup, let best = vocab.best(in: group, for: emb) {
            let parts = best.label.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2, let c = Category(rawValue: parts[0]) { category = c; product = parts[1] }
        }

        let isGarment = ![GarmentKind.footwear, .eyewear, .headwear, .bag, .belt, .jewelry].contains(kind)
        let pattern = vocab.best(in: "pattern", for: emb)
            .flatMap { $0.margin > 0.004 || $0.label == "Solid" ? Pattern(rawValue: $0.label) : nil } ?? .solid
        let material: String? = [.eyewear, .jewelry].contains(kind) ? nil
            : vocab.best(in: "material", for: emb).map { $0.label }

        func attr<T: RawRepresentable>(_ group: String, _ type: T.Type, when ok: Bool) -> T? where T.RawValue == String {
            guard ok, let b = vocab.best(in: group, for: emb), b.margin > 0.003 else { return nil }
            return T(rawValue: b.label)
        }
        let fit: Fit? = attr("fit", Fit.self, when: isGarment && category.supportsFit)
        let neckline: Neckline? = attr("neckline", Neckline.self, when: category.supportsNeckline && kind != .outerLayer)
        let sleeve: SleeveLength? = attr("sleeve", SleeveLength.self, when: category.supportsSleeves)
        let length: GarmentLength? = attr("length", GarmentLength.self, when: category.supportsLength)

        let colors = ColorNamer.dominantColors(cg)
        return Attributes(category: category, product: product, colors: colors.isEmpty ? ["Black"] : colors,
                          pattern: pattern, material: material, fit: fit, neckline: neckline,
                          sleeveLength: sleeve, garmentLength: length, embedding: emb)
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

/// Measures an item's colours from its fabric pixels (k-means in CIELAB) and
/// names them with the app's colour vocabulary (the names ColorMapping draws).
enum ColorNamer {
    private struct Named { let name: String; let lab: (Float, Float, Float) }

    // Reference colours tuned for real fabric under everyday light.
    private static let palette: [Named] = [
        ("Black", 20, 20, 22), ("Charcoal", 58, 60, 64), ("Gray", 128, 128, 130), ("Silver", 192, 192, 196),
        ("White", 244, 244, 240), ("Cream", 240, 232, 210), ("Beige", 214, 196, 164), ("Tan", 196, 160, 116),
        ("Khaki", 168, 152, 104), ("Brown", 110, 72, 44), ("Rust", 170, 78, 36), ("Orange", 236, 128, 40),
        ("Gold", 206, 170, 60), ("Yellow", 236, 210, 60), ("Olive", 108, 112, 52), ("Green", 52, 130, 70),
        ("Mint", 160, 220, 180), ("Teal", 30, 128, 128), ("Light Blue", 150, 186, 222), ("Blue", 46, 96, 180),
        ("Navy", 30, 40, 80), ("Lavender", 184, 160, 216), ("Purple", 110, 56, 140), ("Pink", 236, 150, 180),
        ("Coral", 240, 118, 96), ("Red", 196, 34, 44), ("Burgundy", 110, 26, 44), ("Maroon", 96, 20, 24)
    ].map { Named(name: $0.0, lab: lab(Float($0.1) / 255, Float($0.2) / 255, Float($0.3) / 255)) }

    /// 1–3 colour names, most dominant first; secondary colours need >= 15% share.
    static func dominantColors(_ image: CGImage) -> [String] {
        guard let px = GarmentCutout.rgbaPixels(image) else { return [] }
        let n = image.width * image.height
        let step = max(1, Int(sqrt(Double(n) / 6000)))
        var samples: [(Float, Float, Float)] = []
        for y in stride(from: 0, to: image.height, by: step) {
            for x in stride(from: 0, to: image.width, by: step) {
                let o = (y * image.width + x) * 4
                let a = Float(px[o + 3]) / 255
                guard a > 0.9 else { continue }
                samples.append(lab(Float(px[o]) / 255 / a, Float(px[o + 1]) / 255 / a, Float(px[o + 2]) / 255 / a))
            }
        }
        guard samples.count > 30 else { return [] }

        // k-means, k = 3, deterministic init from luminance quantiles.
        let sorted = samples.sorted { $0.0 < $1.0 }
        var centers = [sorted[sorted.count / 6], sorted[sorted.count / 2], sorted[sorted.count * 5 / 6]]
        var assign = [Int](repeating: 0, count: samples.count)
        for _ in 0..<10 {
            for (i, s) in samples.enumerated() {
                var best = 0, bd = Float.infinity
                for (c, ctr) in centers.enumerated() {
                    let d = dist(s, ctr); if d < bd { bd = d; best = c }
                }
                assign[i] = best
            }
            for c in 0..<3 {
                let members = samples.indices.filter { assign[$0] == c }
                guard !members.isEmpty else { continue }
                var acc: (Float, Float, Float) = (0, 0, 0)
                for i in members { acc.0 += samples[i].0; acc.1 += samples[i].1; acc.2 += samples[i].2 }
                let m = Float(members.count)
                centers[c] = (acc.0 / m, acc.1 / m, acc.2 / m)
            }
        }
        var share = [Int](repeating: 0, count: 3)
        for a in assign { share[a] += 1 }
        let order = (0..<3).sorted { share[$0] > share[$1] }
        var names: [String] = []
        for c in order {
            let frac = Float(share[c]) / Float(samples.count)
            guard names.isEmpty || frac >= 0.15 else { continue }
            let name = nearest(centers[c])
            if !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(3))
    }

    private static func nearest(_ c: (Float, Float, Float)) -> String {
        let chroma = sqrt(c.1 * c.1 + c.2 * c.2)
        // Near-neutral: decide by lightness so shadows on a grey coat stay "Gray".
        if chroma < 7 {
            switch c.0 {
            case ..<24: return "Black"
            case ..<40: return "Charcoal"
            case ..<72: return "Gray"
            case ..<88: return "Silver"
            default: return "White"
            }
        }
        var best = "Gray", bd = Float.infinity
        for p in palette {
            let d = dist(c, p.lab); if d < bd { bd = d; best = p.name }
        }
        return best
    }

    private static func dist(_ a: (Float, Float, Float), _ b: (Float, Float, Float)) -> Float {
        let dl = a.0 - b.0, da = a.1 - b.1, db = a.2 - b.2
        return dl * dl * 0.6 + da * da + db * db     // lightness counts less: lighting varies
    }

    /// sRGB (0...1) → CIELAB (D65).
    static func lab(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let R = lin(min(max(r, 0), 1)), G = lin(min(max(g, 0), 1)), B = lin(min(max(b, 0), 1))
        let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047
        let y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1 / 3) : 7.787 * t + 16 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
