import Foundation
import UIKit
import Vision

class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}
    
    /// The Gemini key. Debug test runs (CI) may inject it through the environment
    /// so the real key never has to live in a CI-written Secrets.swift.
    let geminiAPIKey: String = {
        #if DEBUG
        if let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !k.isEmpty { return k }
        #endif
        return Secrets.geminiAPIKey
    }()

    // MARK: - Per-Use-Case Gemini Model Selection
    //
    // Gemini 3.x migration (June 2026). Models + thinking levels are chosen per
    // task to balance quality / latency / cost (see research). IMPORTANT: Gemini 3
    // defaults thinking to "high"; we set thinkingLevel explicitly on EVERY call,
    // or these would silently run max-thinking (expensive + slow). The old
    // thinkingBudget param is replaced by thinkingLevel (minimal/low/medium/high).
    // All model IDs and the thinkingLevel param were verified live against the API.
    private enum GeminiTask {
        case classify     // UC1: multimodal garment classification -> structured JSON
        case batchBBox    // UC2: batch 2D bounding boxes
        case focusedBBox  // UC3: focused small-object bounding box (was gemini-2.5-pro)
        case outfit       // UC4: outfit suggestion (text reasoning)
        case quickEdit    // UC5: trivial swap/add (text reasoning)

        var model: String {
            switch self {
            case .classify:    return "gemini-3.5-flash"
            case .batchBBox:   return "gemini-3-flash-preview"
            case .focusedBBox: return "gemini-3-flash-preview"
            case .outfit:      return "gemini-3.5-flash"
            case .quickEdit:   return "gemini-3.1-flash-lite"
            }
        }

        /// thinkingLevel: minimal for spatial/trivial (Google's spatial guidance
        /// says disable thinking for 2D detection); low where reasoning helps.
        var thinkingLevel: String {
            switch self {
            case .batchBBox, .quickEdit: return "minimal"
            // Tiny accessories (watch, ring, glasses) are the hardest localization
            // task — a little reasoning materially improves the bounding box.
            case .focusedBBox:           return "low"
            // Outfit suggestion has a long rulebook + self-check, but "medium" thinking
            // made generation/shuffle feel slow; "low" keeps it responsive and the
            // prompt self-check + the deterministic validator still guard quality.
            case .classify, .outfit:     return "low"
            }
        }
    }

    private func geminiURL(_ task: GeminiTask) -> URL? {
        URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(task.model):generateContent?key=\(geminiAPIKey)")
    }
    
    struct BoundingBox: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    // MARK: - Segmented Items

    struct SegmentedItem {
        let category: Category?
        let product: String?
        let colors: [String]
        let pattern: Pattern?
        let material: String?
        let fit: Fit?
        let neckline: Neckline?
        let sleeveLength: SleeveLength?
        let garmentLength: GarmentLength?
        let details: String?
        let brand: String
        /// Transparent, square-framed cutout of just this item.
        let maskImage: UIImage?
        /// FashionSigLIP embedding of the cutout — visual duplicate matching.
        var featurePrint: [Float]? = nil
        /// 0...1 quality of this view of the item (see WardrobeExtractor).
        var quality: Float = 0
    }

    // MARK: - On-device Segmentation Pipeline

    /// Finds every garment and accessory in a photo and returns one clean cutout
    /// + attributes per item, entirely on-device (see `WardrobeExtractor`). Runs
    /// off the main thread; safe to call from any task.
    func analyzeAndSegment(image: UIImage, userGender: String? = nil, retryCount: Int = 0) async -> [SegmentedItem] {
        let items = await Task.detached(priority: .utility) {
            WardrobeExtractor.extract(from: image)
        }.value
        return items.map { item in
            let a = item.attributes
            return SegmentedItem(
                category: a.category, product: a.product, colors: a.colors, pattern: a.pattern,
                material: a.material, fit: a.fit, neckline: a.neckline, sleeveLength: a.sleeveLength,
                garmentLength: a.garmentLength, details: nil, brand: "",
                maskImage: item.cutout, featurePrint: a.embedding, quality: item.quality)
        }
    }

    func padToSquare(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        return GarmentCutout.frame(cg)
    }

    // MARK: - Index-Based Outfit Suggestion Structs

    struct SuggestedOutfit: Codable {
        let items: [Int]
        let explanation: String
    }

    struct ShuffleResponse: Codable {
        let index: Int
        let explanation: String
    }

    struct AddProductResponse: Codable {
        let index: Int
    }

    enum OutfitSuggestError: Error {
        case networkError
        case rateLimited
        case parseError
        case emptyWardrobe
    }

    // MARK: - Suggest Outfit Batch (Index-Based)

    func suggestOutfitBatch(from wardrobe: [WardrobeItem], outfitType: OutfitType? = nil, customDescription: String? = nil, weather: Weather? = nil, user: User? = nil, lockedItems: [WardrobeItem] = [], retryCount: Int = 0) async -> Result<[SuggestedOutfit], OutfitSuggestError> {
        guard wardrobe.count >= 3 else {
            print("[StyleMate] suggestOutfitBatch: wardrobe too small (\(wardrobe.count) items)")
            return .failure(.emptyWardrobe)
        }

        let wardrobeSummary = wardrobe.enumerated().map { (idx, item) in
            var desc = "[\(idx)] \(item.category.rawValue) | \(item.product) | \(item.colors.joined(separator: ", ")) | \(item.pattern.rawValue)"
            if !item.brand.isEmpty { desc += " | \(item.brand)" }
            if let m = item.material, !m.isEmpty { desc += " | \(m)" }
            if let f = item.fit { desc += " | \(f.rawValue)" }
            if let n = item.neckline { desc += " | \(n.rawValue)" }
            if let s = item.sleeveLength { desc += " | \(s.rawValue)" }
            if let g = item.garmentLength { desc += " | \(g.rawValue)" }
            if let d = item.details, !d.isEmpty { desc += " | \(d)" }
            return desc
        }.joined(separator: "\n")

        let isEthnicRequest = outfitType == .ethnic
            || (customDescription?.lowercased().contains("ethnic") == true)
            || (customDescription?.lowercased().contains("indian") == true)
            || (customDescription?.lowercased().contains("traditional") == true)
            || (customDescription?.lowercased().contains("kurta") == true)
            || (customDescription?.lowercased().contains("saree") == true)
            || (customDescription?.lowercased().contains("wedding") == true)
            || (customDescription?.lowercased().contains("puja") == true)
            || (customDescription?.lowercased().contains("diwali") == true)
            || (customDescription?.lowercased().contains("festival") == true)

        let isActiveRequest = outfitType == .sports
            || (customDescription?.lowercased().contains("gym") == true)
            || (customDescription?.lowercased().contains("workout") == true)
            || (customDescription?.lowercased().contains("run") == true)
            || (customDescription?.lowercased().contains("sport") == true)
            || (customDescription?.lowercased().contains("athletic") == true)
            || (customDescription?.lowercased().contains("yoga") == true)
            || (customDescription?.lowercased().contains("hike") == true)
            || (customDescription?.lowercased().contains("active") == true)

        let typeInstruction: String
        let trimmedCustom = customDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom = trimmedCustom, !custom.isEmpty {
            var occasionHint = ""
            if let outfitType = outfitType {
                occasionHint = "\n(The user also tapped the \"\(outfitType.rawValue)\" occasion as a hint. The typed request above OUTRANKS it — follow the typed request wherever the two differ.)"
            }
            typeInstruction = """
            ★★★ TOP-PRIORITY USER REQUEST — this outranks every other preference, including the occasion chip and your own defaults: "\(custom)"
            This is the single most important input. ALL 5 outfits MUST directly and specifically serve this request. Read it carefully:
            - A place ("beach", "office", "wedding") → dress for that venue's dress code.
            - An activity ("hiking", "dinner", "interview") → dress for that activity's needs.
            - A mood or style ("edgy", "cozy", "minimalist") → reflect that aesthetic.
            - Weather or season they name ("cold evening", "summer") → layer for it, even if it contradicts the live weather data below.
            - People or formality ("meeting his parents", "casual hangout") → match that social formality.
            Never fall back to generic everyday looks that ignore what the user typed.\(occasionHint)
            """
        } else if let outfitType = outfitType {
            typeInstruction = "The user wants an outfit for: \(outfitType.rawValue). Tailor suggestions for this context."
        } else if let user = user {
            let styles = user.preferredStyles.map { $0.rawValue }.joined(separator: ", ")
            typeInstruction = "The user prefers these styles: \(styles). Suggest outfits that fit one of these styles."
        } else {
            typeInstruction = "The user wants an everyday casual outfit."
        }

        // Lock constraint: when the user has locked pieces, every returned outfit
        // must keep them (referenced by their wardrobe index).
        let lockedIndices = lockedItems.compactMap { locked in
            wardrobe.firstIndex(where: { $0.id == locked.id })
        }
        var lockedInstruction = ""
        if !lockedIndices.isEmpty {
            lockedInstruction = "\n\nLOCKED ITEMS (HARD CONSTRAINT): The user locked these items in. EVERY outfit you return MUST include ALL of these exact indices: \(lockedIndices). Build the rest of each outfit around them while still obeying every rule above."
        }

        var categoryIsolationNote = ""
        if !isEthnicRequest {
            categoryIsolationNote += "\nNOTE: Items from the \"Ethnic Wear\" category are included in the wardrobe list but should NOT be used for this request type. Ignore all Ethnic Wear items."
        }
        if !isActiveRequest {
            categoryIsolationNote += "\nNOTE: Items from the \"Activewear\" category are included in the wardrobe list but should NOT be used for this request type. Ignore all Activewear items."
        }

        let genderInstruction: String
        if let gender = user?.gender, !gender.isEmpty {
            genderInstruction = "The user's gender is: \(gender). Ensure suggestions are appropriate for this gender."
        } else {
            genderInstruction = ""
        }

        let hour = Calendar.current.component(.hour, from: Date())
        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "morning"
        case 12..<17: timeOfDay = "afternoon"
        case 17..<21: timeOfDay = "evening"
        default: timeOfDay = "night"
        }
        let isNight = hour >= 21 || hour < 5
        let isDark = weather?.isDay == 0 || isNight

        var weatherInstruction: String
        if let weather = weather {
            let temp = Int(weather.temperature2m)
            let desc = weather.displayDescription
            let city = weather.city ?? "their location"
            let seasonHint: String
            switch temp {
            case ..<10: seasonHint = "Cold weather. Include long sleeves, sweaters, coats, boots. No shorts, sandals, or tank tops."
            case 10..<18: seasonHint = "Cool weather. Light jackets, sweaters, long pants. Layering is ideal."
            case 18..<25: seasonHint = "Mild weather. T-shirts, light shirts, jeans, sneakers. Light layers optional."
            case 25...: seasonHint = "Hot weather. Short sleeves, shorts, sandals, light fabrics. No jackets, sweaters, or boots."
            default: seasonHint = ""
            }
            weatherInstruction = "Weather in \(city): \(desc), \(temp)°C. \(seasonHint)"
        } else {
            weatherInstruction = "No weather information available. Suggest outfits suitable for a typical day."
        }
        weatherInstruction += " Time of day: \(timeOfDay)."
        if isDark {
            weatherInstruction += " It is dark outside. Do NOT suggest sunglasses."
        }

        let prompt = """
You are an expert fashion stylist creating outfits from a real person's wardrobe. Each item is identified by an index number in square brackets. You MUST reference items ONLY by their index number.

WARDROBE:
\(wardrobeSummary)
\(categoryIsolationNote)\(lockedInstruction)

CONTEXT:
\(typeInstruction)
\(genderInstruction)
\(weatherInstruction)

STYLING RULES (follow ALL of these):

COLOR HARMONY:
- Follow the 3-color rule: each outfit should use at most 3 main color families (excluding black, white, and gray which are neutral and don't count toward the limit).
- Monochromatic outfits (varying shades of one color) are sophisticated and always work.
- Analogous colors (neighbors on the color wheel, e.g., blue + teal, red + orange) create harmonious, easy outfits.
- Complementary colors (opposites on the wheel, e.g., navy + burnt orange, burgundy + forest green) create intentional contrast. Use sparingly and balance with neutrals.
- Neutrals (black, white, gray, beige, cream, navy, brown, tan, khaki, olive, camel) pair with everything and with each other. A full-neutral outfit is perfectly valid.
- Avoid combining more than one bold/saturated non-neutral color unless the overall palette is intentionally triadic.
- Earth tones (brown, olive, rust, tan, beige, terracotta) form their own harmonious family.
- Denim blue is effectively a neutral and pairs with almost everything.

PATTERN MIXING:
- Maximum one statement pattern per outfit. If one item has a strong pattern (floral, animal print, geometric, plaid), the rest should be solid or very subtle.
- Stripes are semi-neutral and can pair with other patterns IF the scale differs (e.g., thin pinstripes with a bold floral).
- Two items with the same pattern type (e.g., two florals, two plaids) should generally be avoided unless they are clearly different scales.
- Solid items are always safe to combine with any pattern.

FORMALITY COHERENCE:
- All items in an outfit should be at a similar formality level. Don't pair a blazer with athletic shorts, or formal shoes with a graphic tee and sweatpants.
- Casual items: T-shirts, graphic tees, hoodies, joggers, sneakers, slides, shorts, tank tops.
- Smart casual: Polo shirts, chinos, button-down shirts, loafers, clean sneakers, cardigans, blazers over casual bottoms.
- Formal: Dress shirts, trousers, blazers, formal shoes, overcoats, ties.
- Activewear: Athletic tops, track pants, running shorts, sports bras, active leggings. Keep activewear together; don't mix with non-active items.
- Ethnic wear: Kurta with churidar/salwar/jeans, saree with blouse, lehenga with choli and dupatta. Ensure culturally complete combinations.

BAD FORMALITY COMBINATIONS (never suggest these):
- Blazer + joggers/sweatpants
- Formal shoes (Oxford, formal) + graphic tee + shorts
- Tie/bowtie + hoodie
- Athletic shorts + button-down shirt
- Flip-flops/slides + trousers/blazer

LAYERING LOGIC:
- An outfit's upper body should have at most ONE item from each layer tier:
  * Base layer (tier 1): T-Shirts, Tank Tops, Camisoles, Bodysuits, Henley, Undershirts, Turtlenecks, Graphic Tees
  * Shirts layer (tier 2): Shirts, Button-Down Shirts, Flannel Shirts, Blouses, Polo T-Shirts
  * Mid-layer (tier 3): Sweaters, Cardigans, Hoodies, Sweatshirts, Pullovers, Vests, Quarter-Zips, Fleece Jackets
  * Outerwear (tier 4): Jackets, Blazers, Coats, Overcoats, Parkas, Windbreakers, Bomber Jackets, Puffer Jackets, Leather Jackets, Denim Jackets, Trench Coats
- You may include at most ONE item per tier. You CANNOT have two mid-layers (e.g., a sweater AND a hoodie) or two base layers (e.g., a turtleneck AND a T-shirt).
- A turtleneck is a BASE LAYER, not a mid-layer. It goes UNDER a sweater or jacket, never over one.
- A shirt (button-down) can go UNDER a sweater/cardigan (the collar peeks out), but NOT under another shirt.
- Typical valid layering combinations:
  * T-shirt + jeans + sneakers (minimal, warm weather)
  * Shirt + sweater + chinos + loafers (smart casual, cool weather)
  * T-shirt + hoodie + jacket + jeans + boots (cold weather, casual)
  * Turtleneck + blazer + trousers + formal shoes (smart, cold weather)
- Invalid layering (NEVER do these):
  * Two sweaters/pullovers/hoodies in one outfit
  * A turtleneck + a shirt + a sweater (three upper body layers from base/shirt/mid is the maximum; adding all three plus outerwear is too much and physically uncomfortable)
  * A hoodie under a slim blazer (fabric bulk doesn't fit)

ETHNIC WEAR ISOLATION:
- Items from the "Ethnic Wear" category (kurta, kurti, saree, lehenga, sherwani, nehru jacket, dhoti, etc.) should ONLY be included in outfits when the user has explicitly requested ethnic wear, cultural outfits, or a specific ethnic occasion (e.g., "Indian wedding", "puja", "Diwali party", "ethnic wear").
- For "Everyday Casual", "Business Casual", "Formal Wear", "Date Night", "Streetwear", "Party", "Loungewear", "Vacation", or "Sports / Active" requests, do NOT include any ethnic wear items unless the user's custom description specifically mentions ethnic or cultural context.
- The only exception is a Nehru jacket, which can be styled as a smart-casual layering piece in non-ethnic outfits if the wardrobe is limited.

ACTIVEWEAR ISOLATION:
- Items from the "Activewear" category (athletic tops, track pants, running shorts, sports bras, active leggings, yoga pants, etc.) should primarily be used for "Sports / Active" outfit requests.
- For non-athletic outfit types, do NOT include activewear items unless the user's description specifically mentions gym, workout, athleisure, or similar.
- The exception is athleisure-friendly pieces like joggers or hoodies from the Mid-Layers category, which CAN cross over into casual outfits.

WEATHER APPROPRIATENESS:
- Cold (<10°C): Long sleeves, sweaters, coats, boots, scarves. No shorts, sandals, tank tops.
- Cool (10-18°C): Light jackets, sweaters, long pants. Layering is ideal.
- Mild (18-25°C): T-shirts, light shirts, jeans, sneakers. Light layers optional.
- Hot (>25°C): Short sleeves, shorts, sandals, light fabrics. No jackets, sweaters, or boots.
- Rain: Avoid suede shoes. Prefer waterproof outerwear if available.

TIME-OF-DAY AWARENESS:
- Sunglasses should ONLY be suggested during daytime (morning or afternoon when it's sunny). NEVER suggest sunglasses for evening or night outfits.
- For evening/night outfits, consider that the user may be going somewhere indoors (restaurants, events) where lighter layers might suffice even in cold weather.

MATERIAL COMPATIBILITY:
- Don't combine very different textures without intention (e.g., silk blouse with cargo pants).
- Denim pairs well with cotton, leather, and knits.
- Leather accessories (belt, shoes, bag) should ideally be the same shade family (all brown or all black, not mixed).
- Wool, cashmere, and knits form a natural textural family for cold weather.

HARD RULE - MINIMUM OUTFIT COMPOSITION:
Every single outfit MUST contain ALL of these:
1. Exactly ONE base top OR one-piece (from Tops, or One-Pieces category)
2. Exactly ONE bottom (from Bottoms category) - UNLESS a one-piece is used
3. Exactly ONE footwear item (from Footwear category)
If any outfit is missing any of these three, it is INVALID. Do not return it.
Mid-layers, outerwear, and accessories are OPTIONAL additions on top of these required items.
- For ethnic wear, ensure the combination is culturally complete (e.g., kurta needs a bottom like churidar, jeans, or salwar).
- Never suggest just accessories + outerwear without a core outfit underneath.

PHYSICALLY IMPOSSIBLE COMBINATIONS — never output an outfit containing any of these:
- Two bottoms (e.g. jeans + trousers, or two skirts), or more than one pair of footwear.
- A one-piece (dress, jumpsuit, romper, gown) together with a SEPARATE bottom — the one-piece already covers the lower body.
- A one-piece together with a separate base top — the one-piece already covers the torso (a jacket or cardigan layered OVER it is fine).
- Two mid-layers at once (e.g. a sweater AND a hoodie), or two pieces of outerwear (two coats / two jackets).

VARIETY:
- Each of the 5 outfits must be meaningfully different from the others: different color palette, different vibe, or different key pieces.
- Try to use a wide range of the wardrobe. Don't reuse the same item in more than 2 outfits.
- If the wardrobe supports it, vary the style across outfits (one casual, one smart casual, etc.) unless the user specified a single occasion.
- Each outfit must differ from the others in at least one CORE piece (the top, the bottom, or the shoes) — swapping only an accessory does NOT count as a different outfit.

SELF-CHECK (run this before you answer): For EACH of the 5 outfits, silently verify every line below and FIX or REPLACE any outfit that fails — return only outfits that pass ALL of them:
- Exactly one top OR one one-piece (never both).
- Exactly one bottom — unless a one-piece is used (then no separate bottom).
- Exactly one pair of footwear.
- At most one item per layer tier (base / shirt / mid-layer / outerwear); at most 3 upper-body layers total.
- At most 3 non-neutral color families, and at most one statement pattern.
- Consistent formality (no blazer with sweatpants; no formal shoes with athletic shorts).
- Appropriate for the temperature and time of day stated above.
- Directly serves the user's request / occasion.
- Differs from the other four in at least one core piece (top, bottom, or shoes).
- Uses only wardrobe indices that actually appear in the list above.

OUTPUT FORMAT:
Return a JSON array of 5 outfit objects. Each object has:
- "items": array of integer indices referencing the wardrobe items above (e.g., [0, 5, 12, 23])
- "explanation": ONE punchy sentence (max ~22 words) in the voice of a sharp, confident stylist friend talking straight to the user ("you"). Specific, vivid, a little witty — never hedging or generic. Naturally weave in the styling/color principle, the temperature/weather if provided, and the occasion/vibe if specified — but it must read like a person, not a checklist.
  BANNED clichés: "effortlessly chic", "perfect for any occasion", "make a statement", "elevate your look", "timeless". Be concrete instead.
  Voice examples:
    * "Monochrome navy with the denim jacket on top — sharp for the date, warm enough for the 12° evening."
    * "Earth tones doing the work here: olive chinos anchor it, the boots mean business."
    * "White tee, dark denim, clean sneakers — the no-brainer that always lands."
    * "Linen shirt + shorts because 31° is no joke; keep the sunglasses on."

Return ONLY the JSON array. Example format:
[
  {"items": [0, 5, 12], "explanation": "All-navy with cotton texture so it breathes — easy in the 20° Mumbai afternoon."},
  {"items": [3, 7, 15, 22], "explanation": "Earth tones built on the olive chinos; relaxed but pulled-together for a weekend out."}
]
"""

        let responseSchema: [String: Any] = [
            "type": "array",
            "items": [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": ["type": "integer"]
                    ],
                    "explanation": ["type": "string"]
                ],
                "required": ["items", "explanation"]
            ]
        ]

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
                "thinkingConfig": [
                    "thinkingLevel": GeminiTask.outfit.thinkingLevel
                ]
            ]
        ]

        guard let url = geminiURL(.outfit),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            print("[StyleMate] suggestOutfitBatch: failed to build request")
            return .failure(.networkError)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[StyleMate] suggestOutfitBatch: no HTTP response")
                return .failure(.networkError)
            }

            if httpResponse.statusCode == 429 {
                if retryCount < 3 {
                    let delay = UInt64(pow(2.0, Double(retryCount + 1))) * 1_000_000_000
                    print("[StyleMate] suggestOutfitBatch: rate limited, waiting \(delay / 1_000_000_000)s (attempt \(retryCount + 1))")
                    try? await Task.sleep(nanoseconds: delay)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, lockedItems: lockedItems, retryCount: retryCount + 1)
                }
                print("[StyleMate] suggestOutfitBatch: rate limited after all retries")
                return .failure(.rateLimited)
            }

            guard httpResponse.statusCode == 200 else {
                print("[StyleMate] suggestOutfitBatch: HTTP \(httpResponse.statusCode)")
                if retryCount < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, lockedItems: lockedItems, retryCount: retryCount + 1)
                }
                return .failure(.networkError)
            }

            guard let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
                  let text = result.candidates.first?.content.parts.first?.text,
                  let arrData = text.data(using: .utf8) else {
                print("[StyleMate] suggestOutfitBatch: failed to extract text from response")
                if retryCount < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, lockedItems: lockedItems, retryCount: retryCount + 1)
                }
                return .failure(.parseError)
            }

            guard let outfits = try? JSONDecoder().decode([SuggestedOutfit].self, from: arrData) else {
                print("[StyleMate] suggestOutfitBatch: JSON decode failed for SuggestedOutfit array")
                if retryCount < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, lockedItems: lockedItems, retryCount: retryCount + 1)
                }
                return .failure(.parseError)
            }

            print("[StyleMate] suggestOutfitBatch: decoded \(outfits.count) outfits")
            return .success(outfits)

        } catch {
            print("[StyleMate] suggestOutfitBatch: network error: \(error.localizedDescription)")
            if retryCount < 1 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, lockedItems: lockedItems, retryCount: retryCount + 1)
            }
            return .failure(.networkError)
        }
    }

    // MARK: - Partial Shuffle (Index-Based)

    enum PartialShuffleResult {
        case success(index: Int, explanation: String)
        case rateLimited
        case failure
    }

    func suggestPartialShuffleWithResult(currentOutfit: Outfit, categoryToShuffle: Category, availableItems: [WardrobeItem], user: User? = nil) async -> PartialShuffleResult {
        let outfitSummary = currentOutfit.items.map { item in
            var desc = "\(item.category.rawValue) | \(item.product) | \(item.colors.joined(separator: ", ")) | \(item.pattern.rawValue)"
            if !item.brand.isEmpty { desc += " | \(item.brand)" }
            if let m = item.material, !m.isEmpty { desc += " | \(m)" }
            if let f = item.fit { desc += " | \(f.rawValue)" }
            if let n = item.neckline { desc += " | \(n.rawValue)" }
            return desc
        }.joined(separator: "\n")

        let availableSummary = availableItems.enumerated().map { (idx, item) in
            var desc = "[\(idx)] \(item.category.rawValue) | \(item.product) | \(item.colors.joined(separator: ", ")) | \(item.pattern.rawValue)"
            if !item.brand.isEmpty { desc += " | \(item.brand)" }
            if let m = item.material, !m.isEmpty { desc += " | \(m)" }
            if let f = item.fit { desc += " | \(f.rawValue)" }
            if let n = item.neckline { desc += " | \(n.rawValue)" }
            return desc
        }.joined(separator: "\n")

        let genderInstruction: String
        if let gender = user?.gender, !gender.isEmpty {
            genderInstruction = "The user's gender is: \(gender). Ensure suggestions are appropriate for this gender."
        } else {
            genderInstruction = ""
        }

        let shuffleHour = Calendar.current.component(.hour, from: Date())
        let shuffleTimeOfDay: String
        switch shuffleHour {
        case 5..<12: shuffleTimeOfDay = "morning"
        case 12..<17: shuffleTimeOfDay = "afternoon"
        case 17..<21: shuffleTimeOfDay = "evening"
        default: shuffleTimeOfDay = "night"
        }
        let shuffleIsDark = shuffleHour >= 21 || shuffleHour < 5
        var timeContext = "Time of day: \(shuffleTimeOfDay)."
        if shuffleIsDark {
            timeContext += " It is dark outside. Do NOT suggest sunglasses."
        }

        let prompt = """
You are an expert fashion stylist. Replace one item in an outfit while maintaining harmony.

CURRENT OUTFIT:
\(outfitSummary)

ITEM TO REPLACE: The \(categoryToShuffle.rawValue) item.

AVAILABLE REPLACEMENTS:
\(availableSummary)

\(genderInstruction)
\(timeContext)

Choose the replacement that best harmonizes with the remaining items. Follow these rules:
- Color harmony: 3-color rule, neutrals pair with everything. Monochromatic and analogous palettes preferred.
- Pattern mixing: max one statement pattern per outfit.
- Formality coherence: don't mix formal and casual extremes.
- Layering compatibility: the replacement must not violate layering tiers:
  * Base layer (tier 1): T-Shirts, Tank Tops, Camisoles, Bodysuits, Henley, Turtlenecks, Graphic Tees
  * Shirts layer (tier 2): Shirts, Button-Down Shirts, Flannel Shirts, Blouses, Polo T-Shirts
  * Mid-layer (tier 3): Sweaters, Cardigans, Hoodies, Sweatshirts, Pullovers, Vests
  * Outerwear (tier 4): Jackets, Blazers, Coats, Overcoats, Parkas, Windbreakers
  Only one item per tier. A turtleneck is tier 1 (base), not tier 3. No two mid-layers, no two base layers.
- Do NOT pick ethnic wear items (kurta, saree, etc.) unless the outfit already contains ethnic wear.
- Do NOT pick activewear items unless the outfit already contains activewear.

Return a JSON object: {"index": N, "explanation": "brief reason"}
where N is the index number from the AVAILABLE REPLACEMENTS list above.
"""

        let responseSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "index": ["type": "integer"],
                "explanation": ["type": "string"]
            ],
            "required": ["index", "explanation"]
        ]

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
                "thinkingConfig": [
                    "thinkingLevel": GeminiTask.quickEdit.thinkingLevel
                ]
            ]
        ]

        guard let url = geminiURL(.quickEdit),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return .failure
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 429 {
                    return .rateLimited
                }
                if httpResponse.statusCode != 200 {
                    print("[StyleMate] suggestPartialShuffle: HTTP \(httpResponse.statusCode)")
                    return .failure
                }
            }

            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text,
               let objData = text.data(using: .utf8),
               let shuffleResp = try? JSONDecoder().decode(ShuffleResponse.self, from: objData) {
                guard shuffleResp.index >= 0, shuffleResp.index < availableItems.count else {
                    print("[StyleMate] suggestPartialShuffle: index \(shuffleResp.index) out of range (0..<\(availableItems.count))")
                    return .failure
                }
                print("[StyleMate] suggestPartialShuffle: selected index \(shuffleResp.index)")
                return .success(index: shuffleResp.index, explanation: shuffleResp.explanation)
            }
        } catch {
            print("[StyleMate] suggestPartialShuffle: error: \(error.localizedDescription)")
        }

        // Fallback: pick the first available item that isn't the current one
        let currentItem = currentOutfit.items.first { $0.category == categoryToShuffle }
        if let currentItem = currentItem,
           let fallbackIdx = availableItems.firstIndex(where: { $0.id != currentItem.id }) {
            return .success(index: fallbackIdx, explanation: "")
        }
        return .failure
    }

    // MARK: - Add Product to Outfit (Index-Based)

    func suggestAddProductToOutfit(currentOutfit: Outfit, category: Category, productType: String, availableItems: [WardrobeItem], user: User? = nil) async -> Int? {
        let outfitSummary = currentOutfit.items.map { item in
            var desc = "\(item.category.rawValue) | \(item.product) | \(item.colors.joined(separator: ", ")) | \(item.pattern.rawValue)"
            if !item.brand.isEmpty { desc += " | \(item.brand)" }
            if let m = item.material, !m.isEmpty { desc += " | \(m)" }
            if let f = item.fit { desc += " | \(f.rawValue)" }
            if let n = item.neckline { desc += " | \(n.rawValue)" }
            return desc
        }.joined(separator: "\n")

        let availableSummary = availableItems.enumerated().map { (idx, item) in
            var desc = "[\(idx)] \(item.category.rawValue) | \(item.product) | \(item.colors.joined(separator: ", ")) | \(item.pattern.rawValue)"
            if !item.brand.isEmpty { desc += " | \(item.brand)" }
            if let m = item.material, !m.isEmpty { desc += " | \(m)" }
            if let f = item.fit { desc += " | \(f.rawValue)" }
            if let n = item.neckline { desc += " | \(n.rawValue)" }
            return desc
        }.joined(separator: "\n")

        let genderInstruction: String
        if let gender = user?.gender, !gender.isEmpty {
            genderInstruction = "The user's gender is: \(gender). Ensure suggestions are appropriate for this gender."
        } else {
            genderInstruction = ""
        }

        let addHour = Calendar.current.component(.hour, from: Date())
        let addTimeOfDay: String
        switch addHour {
        case 5..<12: addTimeOfDay = "morning"
        case 12..<17: addTimeOfDay = "afternoon"
        case 17..<21: addTimeOfDay = "evening"
        default: addTimeOfDay = "night"
        }
        let addIsDark = addHour >= 21 || addHour < 5
        var addTimeContext = "Time of day: \(addTimeOfDay)."
        if addIsDark {
            addTimeContext += " It is dark outside. Do NOT suggest sunglasses."
        }

        let prompt = """
You are an expert fashion stylist. Add one item to an existing outfit.

CURRENT OUTFIT:
\(outfitSummary)

AVAILABLE \(productType.uppercased()) OPTIONS:
\(availableSummary)

\(genderInstruction)
\(addTimeContext)

Choose the option that best complements the existing outfit. Follow these rules:
- Color harmony: must fit the outfit's existing color palette (3-color rule, neutrals pair with everything).
- Pattern mixing: max one statement pattern per outfit. If the outfit already has a bold pattern, pick solid.
- Formality coherence: match the outfit's existing formality level.
- Layering compatibility: ensure the added item doesn't violate layering tiers:
  * Base layer (tier 1): T-Shirts, Tank Tops, Camisoles, Bodysuits, Henley, Turtlenecks, Graphic Tees
  * Shirts layer (tier 2): Shirts, Button-Down Shirts, Flannel Shirts, Blouses, Polo T-Shirts
  * Mid-layer (tier 3): Sweaters, Cardigans, Hoodies, Sweatshirts, Pullovers, Vests
  * Outerwear (tier 4): Jackets, Blazers, Coats, Overcoats, Parkas, Windbreakers
  Only one item per tier. Do not add a second mid-layer if one already exists.

Return a JSON object: {"index": N}
where N is the index number from the AVAILABLE OPTIONS list above.
"""

        let responseSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "index": ["type": "integer"]
            ],
            "required": ["index"]
        ]

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema,
                "thinkingConfig": [
                    "thinkingLevel": GeminiTask.quickEdit.thinkingLevel
                ]
            ]
        ]

        guard let url = geminiURL(.quickEdit),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[StyleMate] suggestAddProduct: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text,
               let objData = text.data(using: .utf8),
               let addResp = try? JSONDecoder().decode(AddProductResponse.self, from: objData) {
                guard addResp.index >= 0, addResp.index < availableItems.count else {
                    print("[StyleMate] suggestAddProduct: index \(addResp.index) out of range")
                    return nil
                }
                print("[StyleMate] suggestAddProduct: selected index \(addResp.index)")
                return addResp.index
            }
        } catch {
            print("[StyleMate] suggestAddProduct: error: \(error.localizedDescription)")
        }
        return nil
    }
}

// MARK: - Gemini API Response Models
struct GeminiResponse: Codable {
    let candidates: [GeminiCandidate]
}
struct GeminiCandidate: Codable {
    let content: GeminiContent
}
struct GeminiContent: Codable {
    let parts: [GeminiPart]
}
struct GeminiPart: Codable {
    let text: String?
} 