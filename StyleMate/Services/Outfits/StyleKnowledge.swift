import Foundation

// MARK: - Style knowledge
//
// The stylist rulebook the outfit engine reasons with, encoded as data instead of
// a prompt: which structural slot a garment fills, how formal and how warm it is,
// what its colours are on the wheel, and a handful of material/product traits
// (rain-sensitive suede, open-toe shoes, belt loops…). Everything here is pure and
// deterministic so the engine stays fast and unit-testable.

// MARK: - Outfit slots

/// The structural role a garment plays in a look. Category alone isn't enough: an
/// "Activewear" item can be a top or a bottom, a saree is a whole look, a Nehru
/// jacket is a layer. Composition, validation and shuffling all key off this.
enum OutfitSlot: Int, CaseIterable, Comparable {
    case top, bottom, onePiece, midLayer, outerwear, footwear, accessory

    static func < (lhs: OutfitSlot, rhs: OutfitSlot) -> Bool { lhs.rawValue < rhs.rawValue }

    /// At most one of these per look. Tops are not: dungarees or a saree carry a
    /// top underneath, and a tee under a shirt is valid layering.
    var isSingleton: Bool {
        switch self {
        case .top, .accessory: return false
        default: return true
        }
    }

    /// Short noun for UI copy ("That's your only pair of shoes that works here").
    var noun: String {
        switch self {
        case .top: return "top"
        case .bottom: return "bottom"
        case .onePiece: return "one-piece"
        case .midLayer: return "layer"
        case .outerwear: return "jacket"
        case .footwear: return "pair of shoes"
        case .accessory: return "accessory"
        }
    }

    /// How much sharing this slot between two looks makes them feel "the same".
    var overlapWeight: Double {
        switch self {
        case .top: return 1.0
        case .bottom: return 0.9
        case .onePiece: return 1.6
        case .midLayer: return 0.6
        case .outerwear: return 0.7
        case .footwear: return 0.35
        case .accessory: return 0
        }
    }

    /// nil = never styled into a look (innerwear).
    static func of(_ item: WardrobeItem) -> OutfitSlot? {
        switch item.category {
        case .tops: return .top
        case .bottoms: return .bottom
        case .onePieces: return .onePiece
        case .midLayers: return .midLayer
        case .outerwear: return .outerwear
        case .footwear: return .footwear
        case .accessories: return .accessory
        case .innerwear: return nil
        case .activewear:
            switch item.product.lowercased() {
            case "athletic shorts", "running shorts", "cycling shorts", "track pants",
                 "active leggings", "yoga pants", "swim trunks":
                return .bottom
            case "active jackets": return .outerwear
            case "swimwear", "tennis dresses": return .onePiece
            default: return .top
            }
        case .ethnicWear:
            switch item.product.lowercased() {
            case "dhoti", "lungis", "mundu", "salwar", "patiala pants", "churidar",
                 "sharara", "ghagra", "lehenga":
                return .bottom
            case "saree", "anarkali", "jodhpuri suit", "pathani suit", "palazzo suit":
                return .onePiece
            case "nehru jacket", "bandhgala": return .outerwear
            case "dupatta": return .accessory
            default: return .top   // kurta, kurti, sherwani, angrakha, choli, saree blouse
            }
        }
    }

    /// One-pieces that are worn over a top (dungarees, overalls) or with a blouse
    /// (saree). Every other one-piece covers the torso on its own.
    static func needsTopUnder(_ item: WardrobeItem) -> Bool {
        ["dungarees", "overalls", "saree"].contains(item.product.lowercased())
    }
}

// MARK: - Pattern weight

enum PatternWeight {
    case solid, subtle, bold

    init(_ pattern: Pattern) {
        switch pattern {
        case .solid: self = .solid
        case .stripes, .checks, .houndstooth: self = .subtle
        default: self = .bold
        }
    }
}

enum AccessoryKind {
    case eyewear, headwear, jewelry, watch, neckwear, tie, belt, bag, other
}

// MARK: - Colour

/// A garment colour placed on the colour wheel. Neutrals (black, white, grey,
/// navy, beige, denim, olive…) pair with everything and don't count as accents.
struct ColorSwatch: Equatable {
    let name: String          // canonical family, e.g. "navy", "light blue"
    let hue: Double?          // degrees 0..<360; nil = achromatic or multi
    let saturation: Double    // 0...1
    let lightness: Double     // 0...1
    let isNeutral: Bool

    var isSaturated: Bool { !isNeutral && saturation >= 0.6 }
    var isMulti: Bool { name == "multi" }
    /// Reds, oranges, yellows and the warm browns.
    var isWarm: Bool {
        guard let h = hue else { return false }
        return h < 70 || h >= 330
    }
    var isCool: Bool {
        guard let h = hue else { return false }
        return h >= 160 && h < 300
    }
    var isDark: Bool { lightness < 0.32 }
}

enum StylePalette {

    /// Alias → swatch. Matched longest-alias-first so "navy blue" beats "blue".
    private static let entries: [(String, ColorSwatch)] = {
        func s(_ name: String, _ hue: Double?, _ sat: Double, _ light: Double, neutral: Bool = false) -> ColorSwatch {
            ColorSwatch(name: name, hue: hue, saturation: sat, lightness: light, isNeutral: neutral)
        }
        let black = s("black", nil, 0, 0.05, neutral: true)
        let white = s("white", nil, 0, 0.98, neutral: true)
        let cream = s("cream", 45, 0.15, 0.92, neutral: true)
        let gray = s("gray", nil, 0, 0.55, neutral: true)
        let charcoal = s("charcoal", nil, 0, 0.25, neutral: true)
        let silver = s("silver", nil, 0, 0.75, neutral: true)
        let navy = s("navy", 225, 0.5, 0.2, neutral: true)
        let beige = s("beige", 40, 0.25, 0.82, neutral: true)
        let tan = s("tan", 35, 0.35, 0.65, neutral: true)
        let camel = s("camel", 33, 0.45, 0.55, neutral: true)
        let khaki = s("khaki", 50, 0.3, 0.6, neutral: true)
        let brown = s("brown", 25, 0.5, 0.28, neutral: true)
        let taupe = s("taupe", 30, 0.15, 0.5, neutral: true)
        let olive = s("olive", 70, 0.4, 0.35, neutral: true)
        let denim = s("denim", 215, 0.4, 0.45, neutral: true)
        let gold = s("gold", 45, 0.6, 0.55, neutral: true)
        let red = s("red", 0, 0.9, 0.5)
        let burgundy = s("burgundy", 345, 0.55, 0.25)
        let pink = s("pink", 345, 0.45, 0.78)
        let hotPink = s("hot pink", 322, 0.9, 0.55)
        let coral = s("coral", 12, 0.75, 0.66)
        let orange = s("orange", 30, 0.9, 0.55)
        let rust = s("rust", 18, 0.62, 0.38)
        let mustard = s("mustard", 46, 0.68, 0.5)
        let yellow = s("yellow", 55, 0.88, 0.62)
        let lime = s("lime", 90, 0.85, 0.6)
        let green = s("green", 125, 0.7, 0.4)
        let emerald = s("emerald", 145, 0.7, 0.35)
        let forest = s("forest", 135, 0.45, 0.24)
        let mint = s("mint", 150, 0.32, 0.78)
        let teal = s("teal", 180, 0.6, 0.38)
        let turquoise = s("turquoise", 175, 0.7, 0.55)
        let lightBlue = s("light blue", 205, 0.45, 0.78)
        let blue = s("blue", 220, 0.8, 0.5)
        let lavender = s("lavender", 270, 0.35, 0.8)
        let purple = s("purple", 280, 0.62, 0.4)
        let plum = s("plum", 305, 0.4, 0.3)
        let multi = s("multi", nil, 0.7, 0.5)

        let table: [(String, ColorSwatch)] = [
            ("black", black), ("jet black", black), ("onyx", black),
            ("white", white), ("optic white", white), ("snow", white),
            ("off white", cream), ("offwhite", cream), ("ivory", cream), ("cream", cream), ("ecru", cream), ("oatmeal", cream),
            ("grey", gray), ("gray", gray), ("light grey", gray), ("light gray", gray), ("heather grey", gray), ("heather gray", gray), ("ash", gray),
            ("charcoal", charcoal), ("dark grey", charcoal), ("dark gray", charcoal), ("slate", charcoal), ("graphite", charcoal),
            ("silver", silver), ("metallic", silver),
            ("navy", navy), ("navy blue", navy), ("midnight blue", navy), ("dark blue", navy), ("midnight", navy),
            ("beige", beige), ("sand", beige), ("stone", beige), ("nude", beige),
            ("tan", tan), ("camel", camel), ("cognac", camel), ("khaki", khaki),
            ("brown", brown), ("chocolate", brown), ("coffee", brown), ("mocha", brown), ("chestnut", brown), ("dark brown", brown),
            ("taupe", taupe),
            ("olive", olive), ("olive green", olive), ("army green", olive), ("military green", olive),
            ("denim", denim), ("light wash", denim), ("dark wash", denim), ("indigo", denim), ("chambray", denim),
            ("gold", gold), ("rose gold", gold), ("bronze", gold),
            ("red", red), ("scarlet", red), ("cherry", red), ("crimson", red),
            ("maroon", burgundy), ("burgundy", burgundy), ("wine", burgundy), ("oxblood", burgundy),
            ("pink", pink), ("rose", pink), ("dusty pink", pink), ("blush", pink), ("baby pink", pink), ("light pink", pink), ("pastel pink", pink),
            ("hot pink", hotPink), ("fuchsia", hotPink), ("magenta", hotPink),
            ("coral", coral), ("salmon", coral), ("peach", coral), ("apricot", coral),
            ("orange", orange), ("tangerine", orange), ("burnt orange", rust),
            ("rust", rust), ("terracotta", rust), ("copper", rust), ("brick", rust),
            ("mustard", mustard), ("ochre", mustard),
            ("yellow", yellow), ("lemon", yellow), ("butter yellow", yellow), ("pastel yellow", yellow),
            ("lime", lime), ("neon green", lime), ("chartreuse", lime),
            ("green", green), ("kelly green", green),
            ("emerald", emerald), ("jade", emerald),
            ("forest green", forest), ("bottle green", forest), ("dark green", forest), ("hunter green", forest),
            ("mint", mint), ("sage", mint), ("pistachio", mint), ("seafoam", mint),
            ("teal", teal), ("petrol", teal),
            ("turquoise", turquoise), ("aqua", turquoise), ("cyan", turquoise),
            ("light blue", lightBlue), ("sky blue", lightBlue), ("baby blue", lightBlue), ("powder blue", lightBlue), ("pastel blue", lightBlue), ("ice blue", lightBlue),
            ("blue", blue), ("cobalt", blue), ("royal blue", blue), ("electric blue", blue), ("bright blue", blue),
            ("lavender", lavender), ("lilac", lavender), ("periwinkle", lavender),
            ("purple", purple), ("violet", purple), ("eggplant", purple), ("aubergine", purple),
            ("plum", plum), ("mauve", plum),
            ("multicolor", multi), ("multicolour", multi), ("multi", multi), ("rainbow", multi), ("multicolored", multi)
        ]
        // Longest alias first; ties keep table order so matching is identical every run.
        return table.enumerated()
            .sorted { $0.element.0.count != $1.element.0.count ? $0.element.0.count > $1.element.0.count : $0.offset < $1.offset }
            .map { $0.element }
    }()

    private static let exact: [String: ColorSwatch] =
        Dictionary(entries, uniquingKeysWith: { first, _ in first })

    /// Every alias, longest first (used by the free-text parser).
    static var aliases: [(alias: String, swatch: ColorSwatch)] {
        entries.map { (alias: $0.0, swatch: $0.1) }
    }

    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let mapped = lowered.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : " "
        }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    /// Place a colour name ("Light Blue", "navy", "Dusty Rose") on the wheel.
    static func swatch(for raw: String) -> ColorSwatch? {
        let name = normalize(raw)
        guard !name.isEmpty else { return nil }
        if let hit = exact[name] { return hit }
        let padded = " \(name) "
        guard let base = entries.first(where: { padded.contains(" \($0.0) ") })?.1 else { return nil }
        // Modifiers shift a chromatic colour lighter/darker/louder.
        guard !base.isNeutral, base.hue != nil else { return base }
        var sat = base.saturation, light = base.lightness
        if ["light", "pale", "pastel", "baby", "soft", "dusty"].contains(where: { padded.contains(" \($0) ") }) {
            sat *= 0.6; light = max(light, 0.75)
        }
        if ["dark", "deep"].contains(where: { padded.contains(" \($0) ") }) { light *= 0.6 }
        if ["neon", "bright", "electric", "vivid", "hot"].contains(where: { padded.contains(" \($0) ") }) { sat = max(sat, 0.9) }
        return ColorSwatch(name: base.name, hue: base.hue, saturation: sat, lightness: light, isNeutral: false)
    }

    /// Unknown names are treated as neutral so they never trigger clash penalties.
    static func isNeutral(_ raw: String) -> Bool { swatch(for: raw)?.isNeutral ?? true }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    /// Two swatches read as "the same colour" for a request like "something in blue".
    static func matches(_ swatch: ColorSwatch, wanted: ColorSwatch) -> Bool {
        if swatch.name == wanted.name { return true }
        guard !wanted.isNeutral, let a = swatch.hue, let b = wanted.hue else { return false }
        // Navy counts as blue; denim does not count as a colour request.
        if swatch.name == "denim" { return false }
        return hueDistance(a, b) <= 28 && (swatch.saturation >= 0.3 || swatch.name == "navy")
    }
}

// MARK: - Item profile

/// Everything the engine needs to know about one garment, derived once per pass.
struct ItemProfile {
    let item: WardrobeItem
    let order: Int                // wardrobe position — deterministic tie-breaks
    let slot: OutfitSlot
    let productKey: String        // lowercased product
    let formality: Double         // 0.5 (lounge) … 5 (black tie)
    let warmth: Double            // ~0 (sandals) … ~4.5 (wool parka)
    let swatches: [ColorSwatch]
    let patternWeight: PatternWeight
    let accessoryKind: AccessoryKind?
    let text: String              // product + material + details, lowercased

    let isAthletic: Bool
    let isEthnic: Bool
    let isLounge: Bool
    let isTailored: Bool          // blazer-like layer that belongs with dressier looks
    let isOpenShoe: Bool
    let isBoot: Bool
    let isSneaker: Bool
    let isRainSensitive: Bool
    let isWaterResistant: Bool
    let isHeavyFabric: Bool
    let isBreathable: Bool
    let showsLegs: Bool
    let isSleeveless: Bool
    let isShortSleeve: Bool
    let isLongSleeve: Bool
    let needsTopUnder: Bool
    let isStatement: Bool

    var id: UUID { item.id }
    var lead: ColorSwatch? { swatches.first }
    var isNeutral: Bool { swatches.allSatisfy { $0.isNeutral } }
    var isClothing: Bool { slot != .accessory }

    init?(_ item: WardrobeItem, order: Int) {
        guard let slot = OutfitSlot.of(item) else { return nil }
        let product = item.product.lowercased()
        let fabric = ((item.material ?? "") + " " + (item.details ?? "")).lowercased()
        let text = product + " " + fabric

        var swatches = item.colors.compactMap { StylePalette.swatch(for: $0) }
        // Blue denim reads as a neutral to any stylist ("blue jeans go with everything").
        if product == "jeans" || fabric.contains("denim") || fabric.contains("chambray") {
            swatches = swatches.map { (sw: ColorSwatch) -> ColorSwatch in
                guard !sw.isNeutral, let h = sw.hue, h >= 190, h <= 245 else { return sw }
                return StylePalette.swatch(for: "denim") ?? sw
            }
        }
        let patternWeight = PatternWeight(item.pattern)

        self.item = item
        self.order = order
        self.slot = slot
        self.productKey = product
        self.text = text
        self.swatches = swatches
        self.patternWeight = patternWeight

        let athletic = item.category == .activewear
        let heavy = fabric.styleContainsAny(StyleKnowledge.heavyFabrics)
        let breathable = fabric.styleContainsAny(StyleKnowledge.lightFabrics)
        self.isAthletic = athletic
        self.isEthnic = item.category == .ethnicWear
        self.isHeavyFabric = heavy
        self.isBreathable = breathable || ["linen pants", "tank tops", "camisoles"].contains(product)
        self.isLounge = StyleKnowledge.loungeProducts.contains(product) || fabric.styleContainsAny(["terry", "sweat"])
        self.isTailored = ["blazers", "nehru jacket", "bandhgala"].contains(product)
        self.isOpenShoe = slot == .footwear && StyleKnowledge.openShoes.contains(product)
        self.isBoot = slot == .footwear && product.contains("boot")
        self.isSneaker = slot == .footwear && (product.contains("sneaker") || product.contains("trainer"))
        self.isRainSensitive = (slot == .footwear || slot == .outerwear)
            && (fabric.styleContainsAny(StyleKnowledge.rainSensitiveFabrics) || ["espadrilles", "slides", "mules"].contains(product))
        self.isWaterResistant = StyleKnowledge.waterResistantProducts.contains(product)
            || fabric.styleContainsAny(StyleKnowledge.waterResistantFabrics)
            || (slot == .footwear && product.contains("boot") && fabric.styleContainsAny(["leather", "rubber"]))
        let lengthShort = item.garmentLength == .short || item.garmentLength == .cropped
        self.showsLegs = StyleKnowledge.legBaring.contains(product)
            || (lengthShort && (slot == .bottom || slot == .onePiece))
        self.isSleeveless = item.sleeveLength == .sleeveless
            || ["tank tops", "camisoles", "tube tops", "halter tops", "bandeau", "bustiers"].contains(product)
        self.isShortSleeve = item.sleeveLength == .shortSleeve || item.sleeveLength == .capSleeve
            || (item.sleeveLength == nil && ["t-shirts", "polo t-shirts", "graphic tees"].contains(product))
        self.isLongSleeve = item.sleeveLength == .longSleeve
            || (item.sleeveLength == nil && ["turtlenecks", "flannel shirts", "button-down shirts"].contains(product))
        self.needsTopUnder = slot == .onePiece && OutfitSlot.needsTopUnder(item)
        self.accessoryKind = slot == .accessory ? StyleKnowledge.accessoryKind(for: product) : nil

        // Formality: product baseline, nudged by fabric and finish.
        var f = StyleKnowledge.formality[product] ?? StyleKnowledge.categoryFormality(item.category)
        if fabric.styleContainsAny(StyleKnowledge.luxeFabrics) { f += 0.3 }
        if !athletic && fabric.styleContainsAny(StyleKnowledge.sportyFabrics) { f -= 0.3 }
        if fabric.contains("denim") && product != "jeans" { f -= 0.2 }
        if fabric.styleContainsAny(["ripped", "distressed", "frayed"]) { f -= 0.4 }
        if item.pattern == .camouflage || item.pattern == .tieDye { f -= 0.6 }
        self.formality = min(5, max(0.5, f))

        // Warmth: product baseline, then sleeves, length and fabric.
        var w = StyleKnowledge.warmth[product] ?? StyleKnowledge.categoryWarmth(item.category)
        if slot == .top || slot == .onePiece || slot == .midLayer {
            switch item.sleeveLength {
            case .sleeveless?: w -= 0.25
            case .threeQuarterSleeve?: w += 0.15
            case .longSleeve?: w += 0.35
            default: break
            }
        }
        if slot == .bottom || slot == .onePiece {
            switch item.garmentLength {
            case .short?, .cropped?: w -= 0.3
            case .kneeLength?: w -= 0.1
            case .midi?: w += 0.1
            case .fullLength?: w += 0.2
            default: break
            }
        }
        if heavy { w = w * 1.2 + 0.15 } else if breathable { w *= 0.75 }
        self.warmth = max(0, w)

        let saturatedLead = swatches.first?.isSaturated ?? false
        self.isStatement = patternWeight == .bold
            || fabric.styleContainsAny(["sequin", "embellish", "glitter", "metallic", "statement", "feather"])
            || StyleKnowledge.statementProducts.contains(product)
            || (saturatedLead && slot != .accessory && slot != .footwear)
    }
}

// MARK: - Tables

enum StyleKnowledge {

    private static func table(_ pairs: [(String, Double)]) -> [String: Double] {
        Dictionary(pairs.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { first, _ in first })
    }

    /// 0.5 lounge · 1 athletic · 2 casual · 3 smart casual · 4 business/smart · 5 black tie
    static let formality: [String: Double] = table([
        // Tops
        ("T-Shirts", 2.0), ("Polo T-Shirts", 2.8), ("Shirts", 3.6), ("Button-Down Shirts", 3.4),
        ("Flannel Shirts", 2.3), ("Blouses", 3.4), ("Henley", 2.4), ("Tank Tops", 1.6),
        ("Camisoles", 2.6), ("Crop Tops", 2.0), ("Tube Tops", 2.2), ("Off-Shoulder Tops", 2.8),
        ("Halter Tops", 2.6), ("Bandeau", 2.0), ("Peplum Tops", 3.2), ("Corset Tops", 3.0),
        ("Wrap Tops", 3.0), ("Bustiers", 3.0), ("Bodysuits", 2.8), ("Graphic Tees", 1.6),
        ("Mesh Tops", 2.2), ("Turtlenecks", 3.4), ("Tunics", 2.6),
        // Bottoms
        ("Jeans", 2.2), ("Trousers", 3.8), ("Chinos", 3.0), ("Cargo Pants", 1.8),
        ("Wide-Leg Pants", 3.2), ("Palazzo Pants", 2.8), ("Linen Pants", 2.8), ("Sweatpants", 1.0),
        ("Joggers", 1.3), ("Leggings", 1.5), ("Shorts", 1.8), ("Capris", 2.2), ("Culottes", 2.8),
        ("Skirts", 3.0), ("Mini Skirts", 2.6), ("Skorts", 2.0),
        // Mid-layers
        ("Hoodies", 1.4), ("Sweatshirts", 1.7), ("Sweaters", 2.9), ("Cardigans", 3.0),
        ("Pullovers", 2.6), ("Fleece Jackets", 1.6), ("Vests", 3.2), ("Gilets", 2.4),
        ("Quarter-Zips", 2.6), ("Shrugs", 3.0), ("Ponchos", 2.2),
        // Outerwear
        ("Jackets", 2.6), ("Leather Jackets", 2.8), ("Denim Jackets", 2.2), ("Bomber Jackets", 2.3),
        ("Puffer Jackets", 1.9), ("Coats", 3.6), ("Overcoats", 4.2), ("Trench Coats", 3.9),
        ("Blazers", 4.0), ("Parkas", 2.0), ("Windbreakers", 1.6), ("Raincoats", 2.2),
        ("Shirt Jackets", 2.5), ("Capes", 3.4),
        // One-pieces
        ("Dresses", 3.2), ("Wrap Dresses", 3.4), ("Maxi Dresses", 3.0), ("Shirt Dresses", 3.0),
        ("Gowns", 5.0), ("Jumpsuits", 3.2), ("Rompers", 2.2), ("Playsuits", 2.2),
        ("Dungarees", 1.9), ("Overalls", 1.8),
        // Footwear
        ("Sneakers", 2.0), ("Boots", 2.8), ("Ankle Boots", 3.1), ("Chelsea Boots", 3.4),
        ("Sandals", 1.9), ("Slides", 1.0), ("Espadrilles", 2.4), ("Loafers", 3.6),
        ("Oxford Shoes", 4.4), ("Formal Shoes", 4.6), ("Mules", 3.0), ("Flats", 3.0),
        ("Heels", 4.0), ("Platform Shoes", 2.8), ("Clogs", 1.8), ("Slippers", 0.6),
        // Accessories
        ("Ties", 4.6), ("Bowties", 4.8), ("Cufflinks", 4.8), ("Pocket Squares", 4.4),
        ("Baseball Caps", 1.5), ("Beanies", 1.8), ("Bucket Hats", 1.7), ("Visors", 1.4),
        ("Bandanas", 1.8), ("Sun Hats", 2.4), ("Fedoras", 3.4), ("Berets", 3.0),
        ("Fanny Packs", 1.5), ("Backpacks", 1.8), ("Clutches", 4.2), ("Briefcases", 4.0),
        ("Handbags", 3.4), ("Tote Bags", 2.6), ("Crossbody Bags", 2.8), ("Messenger Bags", 2.6),
        ("Watches", 3.2), ("Belts", 3.2), ("Suspenders", 3.6), ("Sunglasses", 2.6),
        ("Necklaces", 3.2), ("Earrings", 3.2), ("Bracelets", 3.0), ("Rings", 3.2),
        ("Pendants", 3.0), ("Chains", 2.6), ("Brooches", 3.8), ("Scarves", 3.0),
        // Activewear
        ("Active Jackets", 1.3), ("Tennis Dresses", 1.5),
        // Ethnic wear
        ("Kurta", 3.0), ("Sherwani", 4.8), ("Nehru Jacket", 3.8), ("Dhoti", 3.0), ("Lungis", 1.5),
        ("Mundu", 2.5), ("Jodhpuri Suit", 4.8), ("Pathani Suit", 3.4), ("Bandhgala", 4.6),
        ("Angrakha", 3.8), ("Kurti", 2.6), ("Saree", 4.0), ("Blouse (saree)", 3.8),
        ("Lehenga", 4.6), ("Choli", 4.0), ("Dupatta", 3.4), ("Salwar", 2.8),
        ("Patiala Pants", 2.8), ("Anarkali", 4.0), ("Churidar", 3.2), ("Palazzo Suit", 3.2),
        ("Sharara", 4.2), ("Ghagra", 4.2)
    ])

    /// Rough insulation of the garment on its own (a cotton tee ≈ 0.5).
    static let warmth: [String: Double] = table([
        ("T-Shirts", 0.5), ("Polo T-Shirts", 0.55), ("Graphic Tees", 0.5), ("Shirts", 0.8),
        ("Button-Down Shirts", 0.8), ("Flannel Shirts", 1.3), ("Blouses", 0.6), ("Henley", 0.7),
        ("Tank Tops", 0.25), ("Camisoles", 0.2), ("Crop Tops", 0.3), ("Tube Tops", 0.2),
        ("Halter Tops", 0.25), ("Bandeau", 0.15), ("Off-Shoulder Tops", 0.4), ("Bodysuits", 0.5),
        ("Mesh Tops", 0.2), ("Turtlenecks", 1.2), ("Tunics", 0.7), ("Corset Tops", 0.4),
        ("Jeans", 1.0), ("Trousers", 0.9), ("Chinos", 0.9), ("Cargo Pants", 1.0),
        ("Wide-Leg Pants", 0.8), ("Palazzo Pants", 0.6), ("Linen Pants", 0.55), ("Sweatpants", 1.2),
        ("Joggers", 1.1), ("Leggings", 0.8), ("Shorts", 0.2), ("Capris", 0.5), ("Culottes", 0.6),
        ("Skirts", 0.5), ("Mini Skirts", 0.25), ("Skorts", 0.3),
        ("Hoodies", 1.8), ("Sweatshirts", 1.6), ("Sweaters", 2.0), ("Cardigans", 1.5),
        ("Pullovers", 1.9), ("Fleece Jackets", 2.1), ("Vests", 0.9), ("Gilets", 1.2),
        ("Quarter-Zips", 1.6), ("Shrugs", 0.6), ("Ponchos", 1.6),
        ("Jackets", 1.8), ("Leather Jackets", 2.0), ("Denim Jackets", 1.4), ("Bomber Jackets", 1.8),
        ("Puffer Jackets", 3.6), ("Coats", 3.0), ("Overcoats", 3.2), ("Trench Coats", 2.0),
        ("Blazers", 1.2), ("Parkas", 3.8), ("Windbreakers", 1.0), ("Raincoats", 1.2),
        ("Shirt Jackets", 1.2), ("Capes", 1.8),
        ("Dresses", 0.7), ("Wrap Dresses", 0.7), ("Maxi Dresses", 0.8), ("Shirt Dresses", 0.8),
        ("Gowns", 0.9), ("Jumpsuits", 1.3), ("Rompers", 0.5), ("Playsuits", 0.5),
        ("Dungarees", 1.2), ("Overalls", 1.2),
        ("Sneakers", 0.3), ("Boots", 0.8), ("Ankle Boots", 0.6), ("Chelsea Boots", 0.6),
        ("Sandals", 0), ("Slides", 0), ("Espadrilles", 0.1), ("Mules", 0.1), ("Clogs", 0.2),
        ("Loafers", 0.3), ("Oxford Shoes", 0.3), ("Formal Shoes", 0.3), ("Flats", 0.2), ("Heels", 0.2),
        ("Kurta", 0.8), ("Kurti", 0.7), ("Sherwani", 1.8), ("Saree", 0.8), ("Lehenga", 1.0),
        ("Anarkali", 1.0), ("Nehru Jacket", 1.0), ("Bandhgala", 1.6)
    ])

    static func categoryFormality(_ category: Category) -> Double {
        switch category {
        case .tops, .bottoms, .midLayers: return 2.4
        case .onePieces: return 3.0
        case .outerwear: return 2.8
        case .footwear: return 2.6
        case .accessories: return 3.0
        case .activewear: return 1.0
        case .ethnicWear: return 3.4
        case .innerwear: return 1.0
        }
    }

    static func categoryWarmth(_ category: Category) -> Double {
        switch category {
        case .tops: return 0.6
        case .bottoms: return 0.9
        case .onePieces: return 0.8
        case .midLayers: return 1.7
        case .outerwear: return 2.0
        case .footwear: return 0.3
        case .accessories: return 0
        case .activewear: return 0.5
        case .ethnicWear: return 0.9
        case .innerwear: return 0.2
        }
    }

    static func accessoryKind(for product: String) -> AccessoryKind {
        switch product {
        case "sunglasses", "eyeglasses", "reading glasses": return .eyewear
        case "baseball caps", "beanies", "fedoras", "bucket hats", "sun hats", "visors",
             "bandanas", "turbans", "headbands", "berets":
            return .headwear
        case "watches": return .watch
        case "bracelets", "rings", "necklaces", "earrings", "pendants", "chains",
             "anklets", "cufflinks", "brooches":
            return .jewelry
        case "scarves": return .neckwear
        case "ties", "bowties", "pocket squares": return .tie
        case "belts", "suspenders": return .belt
        case "handbags", "tote bags", "crossbody bags", "backpacks", "clutches",
             "fanny packs", "briefcases", "messenger bags", "wallets":
            return .bag
        default: return .other
        }
    }

    static let heavyFabrics = ["wool", "cashmere", "fleece", "sherpa", "shearling", "corduroy", "tweed",
                               "velvet", "down", "quilted", "mohair", "flannel", "knit", "alpaca",
                               "merino", "boucle", "padded"]
    static let lightFabrics = ["linen", "chiffon", "mesh", "seersucker", "voile", "gauze", "eyelet",
                               "crochet", "rayon", "viscose", "poplin", "georgette"]
    static let luxeFabrics = ["silk", "satin", "velvet", "cashmere", "tweed", "wool", "lace", "brocade",
                              "crepe", "organza"]
    static let sportyFabrics = ["fleece", "jersey", "terry", "spandex", "lycra", "nylon", "sweat"]
    static let rainSensitiveFabrics = ["suede", "canvas", "satin", "silk", "mesh", "nubuck", "raffia",
                                       "straw", "velvet"]
    static let waterResistantFabrics = ["waterproof", "water resistant", "water-resistant", "gore",
                                        "rubber", "pvc", "waxed"]

    static let waterResistantProducts: Set<String> = ["raincoats", "trench coats", "windbreakers", "parkas",
                                                      "puffer jackets", "active jackets"]
    static let openShoes: Set<String> = ["sandals", "slides", "espadrilles", "mules", "clogs", "slippers"]
    static let loungeProducts: Set<String> = ["sweatpants", "joggers", "hoodies", "sweatshirts", "slides",
                                              "slippers", "leggings", "lungis", "fleece jackets"]
    static let legBaring: Set<String> = ["shorts", "mini skirts", "skorts", "rompers", "playsuits",
                                         "athletic shorts", "running shorts", "cycling shorts",
                                         "swim trunks", "tennis dresses"]
    static let beltLoopBottoms: Set<String> = ["jeans", "trousers", "chinos", "shorts", "cargo pants",
                                               "linen pants", "wide-leg pants"]
    static let tieTops: Set<String> = ["shirts", "button-down shirts"]
    static let statementProducts: Set<String> = ["leather jackets", "capes", "corset tops", "bustiers",
                                                 "platform shoes", "gowns"]
    static let loungeBottoms: Set<String> = ["sweatpants", "joggers", "track pants"]
    static let dressShoes: Set<String> = ["oxford shoes", "formal shoes"]
    /// Pieces that never go in an auto-styled look (functional, not styling).
    static let neverAutoPick: Set<String> = ["wallets", "eyeglasses", "reading glasses"]
}

extension String {
    /// True if any of the needles occurs in the string (plain substring match).
    func styleContainsAny(_ needles: [String]) -> Bool {
        needles.contains { !$0.isEmpty && self.contains($0) }
    }
}
