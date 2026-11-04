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
/// - **Trousers, shoes, bags, hats** already have a product-like silhouette, so
///   image-to-image from the cutout at ~0.5 strength turns them into a studio
///   shot while keeping their exact look (rips, wash, sole, buckle).
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

    static func negative(for kind: GarmentKind) -> String {
        switch kind {
        case .outerLayer: return baseNegative + ", shirt underneath, white t-shirt, inner layer, sherpa lining, white collar, patch"
        case .innerTop: return baseNegative + ", jacket, layered, second shirt, collar tag"
        case .onePiece: return baseNegative + ", jacket, belt, second garment"
        case .footwear: return baseNegative + ", single shoe, socks, feet, box"
        default: return baseNegative
        }
    }

    /// Use the fabric-filled silhouette as the starting image for generated items.
    static var useTemplates = true
    /// Positive-prompt anchor for text-to-image. Without "flat lay" the model
    /// draws a person wearing the garment ("isolated product photo" and "laid
    /// flat" both did, lab Nov 2026); it's only the fallback when no template fits.
    static let textAnchor = "flat lay product photo, single garment"
    static let templateAnchor = "isolated product photo"

    static func make(product: String, category: Category, colors: [String], pattern: Pattern,
                     material: String?, sleeve: SleeveLength?, neckline: Neckline?, details: String?,
                     kind: GarmentKind, truncated: Bool, cutout: CGImage? = nil, embedding: [Float]? = nil) -> StudioPlan {
        var details = details
        // Rips are what make a pair of jeans that pair: say so when the encoder sees them
        // (lab: ripped jeans +0.033/+0.042 over "plain", all other bottoms <= +0.001).
        if kind == .lower, let e = embedding, let vocab = WardrobeML.shared.vocabulary {
            let s = vocab.scores(in: "lower_details", for: e)
            if let r = s["ripped"], let p = s["plain"], r - p > 0.015 {
                details = ["ripped knees, distressed", details].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            }
        }
        let desc = describe(product: product, colors: colors, pattern: pattern, material: material,
                            sleeve: sleeve, neckline: neckline, details: details)
        let label = "\(category.rawValue)|\(product)", solid = pattern == .solid
        let layered: Set<GarmentKind> = [.innerTop, .outerLayer, .onePiece]
        if layered.contains(kind) || truncated {
            let view: String
            switch kind {
            case .lower: view = "front view, full length"
            case .footwear: view = "a pair, side view"
            default: view = "front view"
            }
            // Template-guided: start from a flat-lay silhouette in the garment's own fabric.
            var template: CGImage?
            if useTemplates, let cutout, let shape = StudioTemplate.shape(product: product, kind: kind, sleeve: sleeve) {
                template = StudioTemplate.render(cutout: cutout, shape: shape, solid: solid)
            }
            return StudioPlan(
                mode: .generate,
                prompt: fit("\(desc), \(template == nil ? textAnchor : templateAnchor), \(view), centered, plain white background, studio lighting"),
                negativePrompt: negative(for: kind),
                candidates: 3, productLabel: label, isSolid: solid, template: template)
        }
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
        let markers = ["laid flat", "isolated product photo", "front view", "side view", "three-quarter view"]
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
        let keep: Set<String> = ["Jeans", "Trousers", "Chinos", "Shorts", "Leggings", "Joggers", "Sweatpants",
                                 "Cargo Pants", "Wide-Leg Pants", "Linen Pants", "Palazzo Pants", "Capris",
                                 "Culottes", "Sunglasses", "Eyeglasses", "Sneakers", "Boots", "Sandals", "Heels",
                                 "Loafers", "Flats", "Slides", "Mules", "Clogs", "Slippers", "Espadrilles",
                                 "Ankle Boots", "Chelsea Boots", "Oxford Shoes", "Formal Shoes", "Platform Shoes"]
        if keep.contains(product) { return product }
        for suffix in ["sses", "ches", "shes", "xes"] where product.hasSuffix(suffix) { return String(product.dropLast(2)) }
        if product.hasSuffix("s") && !product.hasSuffix("ss") { return String(product.dropLast()) }
        return product
    }
}
