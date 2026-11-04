import Foundation

/// How the user wants to feel today. A mood nudges the engine's scoring —
/// formality, palette, textures, silhouettes — rather than hard-filtering, so even
/// a small wardrobe still produces five looks.
enum OutfitMood: String, CaseIterable, Identifiable, Codable {
    case confident, cozy, relaxed, playful, polished, bold, minimal, romantic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .confident: return "Confident"
        case .cozy: return "Cozy"
        case .relaxed: return "Relaxed"
        case .playful: return "Playful"
        case .polished: return "Polished"
        case .bold: return "Bold"
        case .minimal: return "Minimal"
        case .romantic: return "Romantic"
        }
    }

    var icon: String {
        switch self {
        case .confident: return "flame"
        case .cozy: return "cup.and.saucer"
        case .relaxed: return "leaf"
        case .playful: return "party.popper"
        case .polished: return "sparkle"
        case .bold: return "bolt"
        case .minimal: return "circle"
        case .romantic: return "heart.circle"
        }
    }

    /// Words that signal this mood in a free-text request.
    var keywords: [String] {
        switch self {
        case .confident: return ["confident", "power", "powerful", "boss", "strong", "commanding"]
        case .cozy: return ["cozy", "cosy", "snug", "comfy", "warm and soft", "toasty"]
        case .relaxed: return ["relaxed", "laid back", "laidback", "chill", "easy going", "easygoing", "comfortable", "low key", "lowkey"]
        case .playful: return ["playful", "fun", "quirky", "cheerful", "colourful", "colorful", "whimsical"]
        case .polished: return ["polished", "sharp", "put together", "elegant", "classy", "refined", "sleek", "smart"]
        case .bold: return ["bold", "statement", "loud", "edgy", "daring", "stand out", "eye catching"]
        case .minimal: return ["minimal", "minimalist", "clean", "simple", "understated", "neutral", "neutrals", "muted"]
        case .romantic: return ["romantic", "soft", "feminine", "flirty", "dreamy", "pretty", "delicate"]
        }
    }

    /// Shift applied to the occasion's formality target.
    var formalityShift: Double {
        switch self {
        case .confident: return 0.3
        case .cozy: return -0.4
        case .relaxed: return -0.5
        case .playful: return -0.2
        case .polished: return 0.6
        case .bold, .minimal: return 0
        case .romantic: return 0.2
        }
    }

    /// Short closing note for explanations ("Pared-back and clean.").
    var closer: String {
        switch self {
        case .confident: return "built to own the room"
        case .cozy: return "soft, warm textures all the way"
        case .relaxed: return "easy and unfussy"
        case .playful: return "with a little fun in the mix"
        case .polished: return "clean lines, nothing out of place"
        case .bold: return "turned up, on purpose"
        case .minimal: return "pared-back and clean"
        case .romantic: return "soft and a little romantic"
        }
    }

    // MARK: - Scoring

    /// How well a single garment expresses this mood (roughly -2…+2).
    func itemAffinity(_ p: ItemProfile) -> Double {
        let saturated = p.lead?.isSaturated ?? false
        let leadName = p.lead?.name ?? ""
        let fit = p.item.fit
        var s = 0.0
        switch self {
        case .minimal:
            s += p.isNeutral ? 1.0 : (saturated ? -1.0 : -0.3)
            switch p.patternWeight {
            case .bold: s -= 1.2
            case .subtle: s -= 0.2
            case .solid: s += 0.3
            }
            if p.isStatement { s -= 0.5 }

        case .bold:
            s += saturated ? 1.0 : (p.isNeutral ? -0.2 : 0.3)
            if p.isStatement { s += 0.8 }
            if p.patternWeight == .bold { s += 0.4 }

        case .cozy:
            if p.text.styleContainsAny(["knit", "wool", "cashmere", "fleece", "sherpa", "corduroy", "flannel",
                                        "velvet", "chenille", "mohair", "merino", "boucle"]) { s += 1.0 }
            if ["sweaters", "cardigans", "hoodies", "sweatshirts", "pullovers", "fleece jackets", "joggers",
                "sweatpants", "turtlenecks", "beanies", "scarves", "boots", "ankle boots", "chelsea boots"]
                .contains(p.productKey) { s += 0.7 }
            if fit == .relaxed || fit == .oversized { s += 0.4 }
            if p.lead?.isWarm ?? false { s += 0.3 }
            if p.formality >= 4.2 { s -= 0.6 }

        case .relaxed:
            if fit == .relaxed || fit == .oversized { s += 0.5 }
            if ["t-shirts", "henley", "jeans", "chinos", "sneakers", "linen pants", "shorts", "sandals",
                "sweatshirts", "cardigans", "shirt dresses", "maxi dresses"].contains(p.productKey) { s += 0.5 }
            if p.text.styleContainsAny(["linen", "cotton", "jersey"]) { s += 0.3 }
            if ["blazers", "heels", "formal shoes", "oxford shoes", "ties", "bowties", "corset tops",
                "bustiers", "gowns"].contains(p.productKey) { s -= 0.7 }

        case .playful:
            if [.polkaDot, .stripes, .floral, .geometric, .tieDye, .checks].contains(p.item.pattern) { s += 0.6 }
            if saturated { s += 0.5 }
            if ["graphic tees", "mini skirts", "skorts", "rompers", "playsuits", "crop tops", "sneakers",
                "bucket hats", "platform shoes", "dungarees", "overalls"].contains(p.productKey) { s += 0.5 }
            if p.formality >= 4.4 { s -= 0.5 }

        case .polished:
            if ["blazers", "trousers", "shirts", "button-down shirts", "loafers", "trench coats", "overcoats",
                "turtlenecks", "watches", "belts", "oxford shoes", "chelsea boots", "blouses", "wrap dresses",
                "shirt dresses", "heels", "flats"].contains(p.productKey) { s += 0.7 }
            if fit == .slim || fit == .regular { s += 0.3 }
            if p.isNeutral { s += 0.3 }
            if p.text.styleContainsAny(["distressed", "ripped", "graphic"]) || p.productKey == "graphic tees" { s -= 0.8 }
            if p.isLounge { s -= 0.8 }

        case .confident:
            if ["blazers", "leather jackets", "boots", "chelsea boots", "ankle boots", "heels", "trousers",
                "jumpsuits", "turtlenecks", "trench coats"].contains(p.productKey) { s += 0.7 }
            if leadName == "black" || leadName == "red" { s += 0.3 }
            if fit == .slim { s += 0.3 }
            if p.isLounge { s -= 0.5 }

        case .romantic:
            if p.text.styleContainsAny(["silk", "satin", "lace", "chiffon", "tulle", "velvet", "organza", "ruffle"]) { s += 0.9 }
            if ["dresses", "wrap dresses", "maxi dresses", "blouses", "skirts", "off-shoulder tops", "wrap tops",
                "heels", "flats", "mules", "earrings", "necklaces", "cardigans"].contains(p.productKey) { s += 0.7 }
            if ["pink", "red", "lavender", "cream", "burgundy", "white", "coral"].contains(leadName) { s += 0.5 }
            if p.item.pattern == .floral { s += 0.5 }
            if p.isAthletic || p.isLounge { s -= 0.6 }
        }
        return s
    }

    /// How well a whole look's palette expresses this mood.
    func paletteAffinity(_ palette: PaletteAnalysis) -> Double {
        let families = palette.families.count
        switch self {
        case .minimal:
            switch palette.kind {
            case .neutral: return 1.8
            case .tonal, .singleAccent: return palette.saturatedFamilies == 0 ? 0.3 : -0.6
            default: return -0.8 * Double(max(1, families))
            }
        case .bold:
            var s = palette.kind == .neutral ? -1.2 : 0
            if palette.saturatedFamilies >= 1 { s += 0.8 }
            if palette.kind == .complementary { s += 0.4 }
            return s
        case .playful:
            if palette.kind == .neutral { return -0.6 }
            return (families >= 2 && palette.kind != .clashing) ? 0.6 : 0.2
        case .romantic:
            let soft = palette.families.contains { h in h >= 300 || h < 15 || (h >= 250 && h < 300) }
            return soft ? 0.6 : 0
        case .cozy:
            let warm = palette.families.contains(where: { $0 < 60 || $0 >= 330 })
            return warm ? 0.3 : 0
        case .polished:
            switch palette.kind {
            case .neutral, .tonal: return 0.6
            case .busy, .clashing: return -0.8
            default: return 0
            }
        case .confident:
            return (palette.kind == .tonal || palette.kind == .singleAccent) ? 0.4 : 0
        case .relaxed:
            return 0
        }
    }
}
