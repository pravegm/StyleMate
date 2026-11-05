import CoreGraphics
import Foundation

/// How an item's studio image is made, and the prompts for it.
///
/// Prototyping on real cutouts (scratch experiments, Nov 2026) settled the
/// split:
/// - **Tops, layers, dresses** come out of a worn photo in a body pose (a
///   crossed arm, an open front). Image-to-image from the cutout keeps that pose
///   and invents a mannequin, so they are *generated*: image-to-image from a
///   flat-lay silhouette filled with the garment's own fabric (`StudioTemplate`)
///   when one fits, else text-to-image from the measured description. Several
///   candidates; the one that looks most like the real garment wins.
/// - **Trousers, shoes, hats** (not low shoes or caps, see `StudioTemplate.shape`) are generated from a product template too
///   (front view full length; one shoe from the side, toe left; a hat in
///   three-quarter view — `StudioTemplate`). Refining the worn cutout at
///   0.45–0.5 mostly reproduced it: bent knees, a coat hem across the hips, a
///   pair of shoes at street angles in street light (studio coverage lab, Nov 2026).
/// - **Bags, eyewear, belts, jewelry, skirts, shorts, turbans** have no template:
///   image-to-image from the cutout at ~0.45–0.5, which keeps their exact look.
/// - Anything cut off by the photo frame is generated (a render can't invent the
///   missing half faithfully from a partial cutout).
struct StudioPlan {
    enum Mode { case generate, refine(strength: Float) }
    let mode: Mode
    let prompt: String
    let negativePrompt: String
    let candidates: Int
    /// "Category|Product" — the FashionVocabulary label the render must look like.
    var productLabel: String = ""
    /// Plain items: penalise renders that add colour blocks / panels / prints.
    var isSolid: Bool = false
    /// Generate only: a flat-lay silhouette filled with the garment's own fabric
    /// to start image-to-image from (locks layout and colour); nil = text-to-image.
    var template: CGImage? = nil
    var templateStrength: Float = 0.65
    /// Drawn from a shoe / hat / trousers product template (gated on colour drift too).
    var productShot: Bool = false
    /// The template's shape (product shots: where the product is expected).
    var templateShape: StudioTemplate.Shape? = nil

    static let steps = 20
    static let guidance: Float = 7

    /// The CLIP text encoder reads 77 tokens; prompts are kept well under it
    /// (~60) so nothing that matters is cut off.
    static let maxPromptTokens = 60

    /// Words that make the model draw people, mannequins, extra garments,
    /// props or "knolling" layouts — never in a positive prompt
    /// ("flat lay", "top-down", "neatly arranged" triggered knolled props).
    private static let baseNegative =
        "person, model, mannequin, body, skin, hands, face, hanger, multiple items, stack, folded, props, " +
        "accessories, text, watermark, logo, label, white patch, cropped, cut off, frame, border, blurry, deformed"

    /// `productShot`: drawn from a product template (one shoe, side view; a hat
    /// on its own; trousers laid out full length). Its words go FIRST: CLIP reads
    /// 77 tokens and the base list alone is ~60, so words appended after it were
    /// cut off (CI, Nov 2026: "back view" appended did nothing, jeans came out
    /// from the back).
    static func negative(for kind: GarmentKind, productShot: Bool = false) -> String {
        switch kind {
        case .outerLayer: return baseNegative + ", shirt underneath, white t-shirt, inner layer, sherpa lining, white collar, patch"
        case .innerTop: return baseNegative + ", jacket, layered, second shirt, collar tag"
        case .onePiece: return baseNegative + ", jacket, belt, second garment"
        case .footwear:
            return productShot ? "pair, two shoes, brand logo, socks, feet, legs, " + baseNegative : baseNegative + ", single shoe, socks, feet, box"
        case .headwear: return productShot ? "head, hair, brand logo, emblem, " + baseNegative : baseNegative
        case .lower: return productShot ? "back view, back pockets, legs, feet, shoes, top, " + baseNegative : baseNegative
        default: return baseNegative
        }
    }

    /// A shoe named for a one-shoe prompt ("black leather chelsea boot, single shoe").
    static func singleShoe(_ product: String) -> String {
        switch product {
        case "Heels": return "high heel pump"
        case "Flats": return "ballet flat"
        case "Slides": return "slide sandal"
        default:
            let p = product.lowercased()
            return p.hasSuffix("s") ? String(p.dropLast()) : p
        }
    }

    /// Use the fabric-filled silhouette as the starting image for generated items.
    static var useTemplates = true
    /// Positive-prompt anchor for text-to-image. Without "flat lay" the model
    /// draws a person wearing the garment ("isolated product photo" and "laid
    /// flat" both did, lab Nov 2026); it's only the fallback when no template fits.
    static let textAnchor = "flat lay product photo, single garment"
    static let templateAnchor = "isolated product photo"

    /// Kinds drawn from a product template when one fits (instead of refined
    /// from the worn cutout, which mostly reproduced the street photo).
    static let productShotKinds: Set<GarmentKind> = [.lower, .footwear, .headwear]

    /// The cutout reads as a low shoe rather than a boot (`footwear_height` zero-shot;
    /// CI fixtures: boat shoes −0.036, patent boots +0.083).
    static func isLowShoe(_ embedding: [Float]) -> Bool {
        guard let s = WardrobeML.shared.vocabulary?.scores(in: "footwear_height", for: embedding),
              let boot = s["Boot"], let low = s["Low"] else { return false }
        return boot - low < 0
    }

    static func make(product: String, category: Category, colors: [String], pattern: Pattern,
                     material: String?, sleeve: SleeveLength?, neckline: Neckline?, details: String?,
                     kind: GarmentKind, truncated: Bool, cutout: CGImage? = nil, embedding: [Float]? = nil,
                     fit itemFit: Fit? = nil) -> StudioPlan {
        var details = details
        // Rips are what make a pair of jeans that pair: say so when the encoder sees them
        // (lab: ripped jeans +0.033/+0.042 over "plain", all other bottoms <= +0.001).
        if kind == .lower, let e = embedding, let vocab = WardrobeML.shared.vocabulary {
            let s = vocab.scores(in: "lower_details", for: e)
            if let r = s["ripped"], let p = s["plain"], r - p > 0.015 {
                details = ["ripped knees, distressed", details].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
        }
        let label = "\(category.rawValue)|\(product)", solid = pattern == .solid
        let layered: Set<GarmentKind> = [.innerTop, .outerLayer, .onePiece]
        // Template-guided: start from a product silhouette in the item's own fabric.
        var template: CGImage?, strength: Float = 0.65, templateShape: StudioTemplate.Shape?
        // A boot template for a low shoe drew a tall suede boot for boat shoes named "Boots"
        // (CI, Nov 2026): the encoder judges the cutout's height itself, and a low shoe is
        // refined from its cutout like every low shoe (see `StudioTemplate.shape`).
        let lowShoeNamedBoot = kind == .footwear && !truncated && product.lowercased().contains("boot")
            && (embedding.map(isLowShoe) ?? false)
        if useTemplates, let cutout, layered.contains(kind) || truncated || productShotKinds.contains(kind), !lowShoeNamedBoot,
           let shape = StudioTemplate.shape(product: product, kind: kind, sleeve: sleeve, fit: itemFit) {
            template = StudioTemplate.render(cutout: cutout, shape: shape, solid: solid)
            strength = StudioTemplate.strength(shape)
            templateShape = shape
        }
        if layered.contains(kind) || truncated || template != nil {
            let productShot = template != nil && productShotKinds.contains(kind)
            let name = kind == .footwear && template != nil ? singleShoe(product) : product
            var desc = describe(product: name, colors: colors, pattern: pattern, material: material,
                                sleeve: sleeve, neckline: neckline, details: details)
            // Shoes and caps grew invented brand marks (a swoosh, a crest): ask for a plain one.
            if productShot, solid, kind == .footwear || kind == .headwear { desc += ", plain unbranded" }
            let anchor = template == nil ? textAnchor : templateAnchor
            let prompt: String
            switch kind {
            case .footwear:
                prompt = "\(desc), \(template == nil ? "a pair, side view" : "single shoe, side view"), \(anchor)"
            case .headwear:
                prompt = "\(desc), three-quarter view, \(anchor)"
            case .lower:
                prompt = "\(desc), \(anchor), front view, full length"
            default:
                prompt = "\(desc), \(anchor), front view"
            }
            return StudioPlan(
                mode: .generate,
                prompt: fit(prompt + ", centered, plain white background, studio lighting"),
                negativePrompt: negative(for: kind, productShot: productShot),
                candidates: 3, productLabel: label, isSolid: solid, template: template, templateStrength: strength,
                productShot: productShot, templateShape: template == nil ? nil : templateShape)
        }
        let desc = describe(product: product, colors: colors, pattern: pattern, material: material,
                            sleeve: sleeve, neckline: neckline, details: details)
        let view: String
        switch kind {
        case .footwear: view = "a pair of \(desc), side view"
        case .bag: view = "\(desc), front view"
        case .headwear, .eyewear: view = "\(desc), three-quarter view"
        default: view = "\(desc), front view"
        }
        return StudioPlan(
            mode: .refine(strength: kind == .lower ? 0.5 : 0.45),
            prompt: fit("\(view), isolated product photo, centered, plain white background, studio lighting, sharp focus"),
            negativePrompt: negative(for: kind),
            candidates: 2, productLabel: label, isSolid: solid)
    }

    /// Rough CLIP token count: BPE gives ~1 token per short word, more for long
    /// ones, plus one per punctuation mark.
    static func estimatedTokens(_ text: String) -> Int {
        var n = 0
        for word in text.split(whereSeparator: { $0 == " " }) {
            let letters = word.filter { $0.isLetter || $0.isNumber }.count
            n += max(1, (letters + 5) / 6) + word.filter { $0.isPunctuation }.count
        }
        return n
    }

    /// Drops trailing description clauses until the prompt fits `maxPromptTokens`
    /// (the product and colour come first, the framing words last but short).
    static func fit(_ prompt: String) -> String {
        var parts = prompt.components(separatedBy: ", ")
        // The framing tail ("isolated product photo, ...") must survive: trim
        // from the description clauses just before it.
        let markers = ["laid flat", "isolated product photo", "flat lay product photo", "front view", "side view",
                       "three-quarter view", "single shoe", "a pair"]
        let tailStart = parts.firstIndex { p in markers.contains { p.hasPrefix($0) } } ?? parts.count
        var cut = tailStart
        while estimatedTokens(parts.joined(separator: ", ")) > maxPromptTokens, cut > 1 {
            cut -= 1
            parts.remove(at: cut)
        }
        return parts.joined(separator: ", ")
    }

    /// "red and black plaid flannel shirt, long sleeves, collar" from the item's attributes.
    static func describe(product: String, colors: [String], pattern: Pattern, material: String?,
                         sleeve: SleeveLength?, neckline: Neckline?, details: String?) -> String {
        var words: [String] = []
        // A plain garment gets only its main colour: "blue and black denim jacket"
        // (a shadow cluster) painted dark patchy sleeves in CI.
        let names = colors.prefix(pattern == .solid ? 1 : 2).map(colorWord)
        if !names.isEmpty { words.append(names.joined(separator: " and ")) }
        if pattern != .solid { words.append(pattern.rawValue.lowercased()) }
        if let m = material, !m.isEmpty, !product.lowercased().contains(m.lowercased()) {
            words.append(m.lowercased())
        }
        words.append(singular(product).lowercased())
        var extras: [String] = []
        if let s = sleeve { extras.append(s.rawValue.lowercased().replacingOccurrences(of: "sleeve", with: "sleeves")) }
        if let n = neckline, n != .collared || !product.lowercased().contains("shirt") { extras.append(n.rawValue.lowercased()) }
        if let d = details?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            // At most ~6 words of details: long describer lines push the framing out of the prompt.
            extras.append(d.lowercased().split(separator: " ").prefix(6).joined(separator: " "))
        }
        return ([words.joined(separator: " ")] + extras).joined(separator: ", ")
    }

    /// The app's colour names, phrased the way an image model understands them.
    static func colorWord(_ name: String) -> String {
        switch name.lowercased() {
        case "charcoal": return "charcoal grey"
        case "gray", "grey": return "grey"
        case "silver": return "light grey"
        case "light blue": return "light blue"
        case "navy": return "navy blue"
        case "tan": return "tan"
        case "khaki": return "khaki"
        case "cream": return "cream"
        case "burgundy": return "burgundy red"
        case "maroon": return "maroon"
        default: return name.lowercased()
        }
    }

    private static func singular(_ product: String) -> String {
        ProductNoun.singular(product, keepingPairs: true)
    }
}
