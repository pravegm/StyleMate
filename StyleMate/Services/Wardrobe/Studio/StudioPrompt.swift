import Foundation

/// How an item's studio image is made, and the prompts for it.
///
/// Prototyping on real cutouts (scratch experiments, Nov 2026) settled the
/// split:
/// - **Tops, layers, dresses** come out of a worn photo in a body pose (a
///   crossed arm, an open front). Image-to-image keeps that pose and invents a
///   mannequin, so they are *generated* as a catalog flat-lay from their
///   measured description, several candidates, and the one that looks most like
///   the real garment wins.
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

    static let steps = 20
    static let guidance: Float = 7

    private static let baseNegative =
        "person, woman, man, model, mannequin, human, skin, arms, hands, legs, head, face, body, hanger, " +
        "text, watermark, logo text, blurry, lowres, jpeg artifacts, deformed, cropped, cut off, frame, border, " +
        "white patch, blank label square, colour block panel, two-tone"

    static func make(product: String, category: Category, colors: [String], pattern: Pattern,
                     material: String?, sleeve: SleeveLength?, neckline: Neckline?, details: String?,
                     kind: GarmentKind, truncated: Bool) -> StudioPlan {
        let desc = describe(product: product, colors: colors, pattern: pattern, material: material,
                            sleeve: sleeve, neckline: neckline, details: details)
        let label = "\(category.rawValue)|\(product)", solid = pattern == .solid
        let layered: Set<GarmentKind> = [.innerTop, .outerLayer, .onePiece]
        if layered.contains(kind) || truncated {
            let pose: String
            switch kind {
            case .lower: pose = "laid flat, full length, both legs straight"
            case .footwear: pose = "a pair, side view, toes pointing left"
            case .onePiece: pose = "laid flat and neatly arranged, full length"
            default: pose = "laid flat and neatly arranged, sleeves spread"
            }
            return StudioPlan(
                mode: .generate,
                prompt: "flat lay product photo of a single \(desc), \(pose), on a pure white background, top-down view, soft shadow, catalog photography, high detail",
                negativePrompt: baseNegative + ", other clothes, accessories, props, multiple items, folded stack",
                candidates: 3, productLabel: label, isSolid: solid)
        }
        let view: String
        switch kind {
        case .footwear: view = "a pair of \(desc), side view, studio product photo"
        case .bag: view = "a \(desc), front view, studio product photo"
        case .headwear, .eyewear: view = "a \(desc), three-quarter view, studio product photo"
        default: view = "\(desc), front view, laid flat, studio product photo"
        }
        return StudioPlan(
            mode: .refine(strength: kind == .lower ? 0.5 : 0.45),
            prompt: "professional e-commerce photo of \(view), centered, soft studio lighting, pure white background, high detail, sharp focus",
            negativePrompt: baseNegative,
            candidates: 2, productLabel: label, isSolid: solid)
    }

    /// "red and black plaid flannel shirt, long sleeves, collar" from the item's attributes.
    static func describe(product: String, colors: [String], pattern: Pattern, material: String?,
                         sleeve: SleeveLength?, neckline: Neckline?, details: String?) -> String {
        var words: [String] = []
        let names = colors.prefix(2).map(colorWord)
        if !names.isEmpty { words.append(names.joined(separator: " and ")) }
        if pattern != .solid { words.append(pattern.rawValue.lowercased()) }
        if let m = material, !m.isEmpty, !product.lowercased().contains(m.lowercased()) {
            words.append(m.lowercased())
        }
        words.append(singular(product).lowercased())
        var extras: [String] = []
        if let s = sleeve { extras.append(s.rawValue.lowercased().replacingOccurrences(of: "sleeve", with: "sleeves")) }
        if let n = neckline, n != .collared || !product.lowercased().contains("shirt") { extras.append(n.rawValue.lowercased()) }
        if let d = details?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { extras.append(d.lowercased()) }
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
