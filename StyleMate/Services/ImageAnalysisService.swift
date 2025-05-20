import Foundation
import UIKit

class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}
    
    // Gemini 2.5 Flash API Key
    private let geminiAPIKey = "AIzaSyAoq8aUGlzCQzeq1pSKqRjThZ-qeaneQO8"
    private let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key="
    
    // New: Analyze multiple items in an image
    struct BoundingBox: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }
    func analyzeMultiple(image: UIImage, imageIndex: Int? = nil, retryCount: Int = 0) async -> [(category: Category?, product: String?, colors: [String], pattern: Pattern?, boundingBox: BoundingBox?)] {
        if let idx = imageIndex {
            //             print("[Gemini] Starting analysis for image #\(idx), attempt #\(retryCount+1)")
        } else {
            //             print("[Gemini] Starting analysis for image (no index), attempt #\(retryCount+1)")
        }
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            //             print("[Gemini] Failed to get JPEG data for image")
            return []
        }
        let base64Image = imageData.base64EncodedString()
        // Provide Gemini with the valid categories, products, and patterns, and instruct it to select only from these lists
        let prompt = """
You are an expert fashion assistant. Here are the only valid clothing categories: [Tops, Bottoms, Mid-Layers, Outerwear, One-Pieces, Footwear, Accessories, Innerwear, Activewear, Ethnic Wear].
For each category, here are the only valid products:
- Tops: T-Shirts, Shirts, Blouses, Tank Tops, Tube Tops, Camisoles, Crop Tops, Off-Shoulder Tops, Bodysuits, Graphic Tees, Mesh Tops, Turtlenecks
- Bottoms: Jeans, Trousers, Leggings, Joggers, Cargo Pants, Shorts, Skirts, Skorts, Palazzo Pants
- Mid-Layers: Hoodies, Sweatshirts, Sweaters, Cardigans, Pullovers, Fleece Jackets, Vests, Shrugs, Gilets
- Outerwear: Jackets, Coats, Puffer Jackets, Trench Coats, Blazers, Overcoats, Raincoats
- One-Pieces: Dresses, Jumpsuits, Rompers, Playsuits, Dungarees, Overalls
- Footwear: Sneakers, Boots, Heels, Flats, Sandals, Slippers, Loafers, Formal shoes
- Accessories: Hats, Scarves, Gloves, Belts, Handbags, Jewelry, Watches, Sunglasses, Hair Accessories, Ties, Bowties
- Innerwear: Bras, Underwear, Boxers, Thongs, Socks, Thermal Wear, Shapewear, Lingerie
- Activewear: Sports Bras, Active Leggings, Athletic Tops, Track Pants, Athletic Shorts, Active Jackets, Compression Wear, Swimwear, Tennis Dresses
- Ethnic Wear: Kurta, Kurti, Sherwani, Nehru Jacket, Dupatta, Saree, Blouse (saree), Lehenga, Choli, Salwar, Patiala Pants, Anarkali, Angrakha, Dhoti, Lungis, Mundu, Jodhpuri Suit
Here are the only valid patterns: [Solid, Stripes, Checks, Plaid, Polka Dot, Floral, Animal Print, Camouflage, Geometric, Houndstooth, Paisley, Tie-Dye].

IMPORTANT: For each clothing item you detect in the image, you MUST select the category, product, and pattern string **EXACTLY** as provided in the above lists.
- Do not change the spelling, do not use singular or plural forms that are not in the list, do not use synonyms, and do not invent new words.
- Your answer must use the exact string from the list, character for character, including spaces, hyphens, and capitalization.
- If you do not use the exact string, your answer will be rejected.
- **For each detected item, you MUST return at least one color in the colors array. The colors array must NEVER be empty. If you are unsure, make your best guess, but do not leave it empty.**

Examples:
- If the valid product is \"T-shirts\", you must return \"T-shirts\" (not \"Tshirt\", \"Tee shirt\", or \"t-shirts\").
- If the valid pattern is \"Polka Dot\", you must return \"Polka Dot\" (not \"polka dot\", \"Polka Dots\", or \"dots\").
- If you detect a black t-shirt, you must return colors: [\"Black\"] (not [] or [\"\"]).

If you are unsure, copy and paste the string from the list above.

For each item, also return the bounding box as {\"x\": <left>, \"y\": <top>, \"width\": <width>, \"height\": <height>} where all values are normalized between 0 and 1 relative to the image size. Only use the provided categories, products, and patterns. Do not invent new ones.

Return only the JSON array, no extra text.
"""
        let responseSchema: [String: Any] = [
            "type": "array",
            "items": [
                "type": "object",
                "properties": [
                    "category": ["type": "string"],
                    "product": ["type": "string"],
                    "colors": [
                        "type": "array",
                        "items": ["type": "string"]
                    ],
                    "pattern": ["type": "string"],
                    "boundingBox": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"]
                        ],
                        "required": ["x", "y", "width", "height"]
                    ]
                ],
                "required": ["category", "product", "colors", "pattern", "boundingBox"],
                "propertyOrdering": ["category", "product", "colors", "pattern", "boundingBox"]
            ]
        ]
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["inlineData": [
                            "mimeType": "image/jpeg",
                            "data": base64Image
                        ]]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseSchema": responseSchema
            ]
        ]
        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            //             print("[Gemini] Invalid URL or request body")
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode != 200 {
                    if httpResponse.statusCode == 429 {
                        let delay: UInt64 = retryCount == 0 ? 2_000_000_000 : 4_000_000_000
                        if retryCount < 2 {
                            try? await Task.sleep(nanoseconds: delay)
                            return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
                        } else {
                            return []
                        }
                    } else if retryCount < 2 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
                    } else {
                        return []
                    }
                }
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text,
               let arrData = text.data(using: .utf8) {
                if let arr = try? JSONSerialization.jsonObject(with: arrData) as? [[String: Any]] {
                    let mapped = arr.compactMap { dict in
                        let categoryString = (dict["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let productString = (dict["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let colorsArray = dict["colors"] as? [String] ?? []
                        let patternString = (dict["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let category = Category(rawValue: categoryString ?? "")
                        let product = matchProduct(productString)
                        let colors = colorsArray.map { matchColor($0) ?? $0 }.filter { !$0.isEmpty }
                        let pattern = Pattern(rawValue: patternString ?? "")
                        var boundingBox: BoundingBox? = nil
                        if let bboxDict = dict["boundingBox"] as? [String: Any],
                           let x = bboxDict["x"] as? Double,
                           let y = bboxDict["y"] as? Double,
                           let width = bboxDict["width"] as? Double,
                           let height = bboxDict["height"] as? Double {
                            boundingBox = BoundingBox(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
                        }
                        if let product = product {
                            return (category, product, colors, pattern, boundingBox)
                        } else {
                            return nil
                        }
                    }
                    let hasEmpty = mapped.contains { $0.0 == nil || $0.1 == nil || $0.2.isEmpty || $0.3 == nil }
                    if hasEmpty && retryCount < 2 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
                    } else if hasEmpty {
                        return []
                    }
                    return mapped
                } else {
                    return []
                }
            } else {
                return []
            }
        } catch {
            if retryCount < 2 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
            } else {
                return []
            }
        }
    }

    // Improved category matching (case-insensitive, partial, with synonyms)
    func matchCategory(_ category: String?) -> Category? {
        guard let category = category?.lowercased() else { return nil }
        let mapping: [String: Category] = [
            "top": .tops,
            "tops": .tops,
            "bottom": .bottoms,
            "bottoms": .bottoms,
            "mid-layer": .midLayers,
            "midlayers": .midLayers,
            "midlayer": .midLayers,
            "mid layers": .midLayers,
            "outerwear": .outerwear,
            "outer": .outerwear,
            "one-piece": .onePieces,
            "onepieces": .onePieces,
            "one piece": .onePieces,
            "footwear": .footwear,
            "shoes": .footwear,
            "accessory": .accessories,
            "accessories": .accessories,
            "innerwear": .innerwear,
            "activewear": .activewear,
            "ethnicwear": .ethnicWear,
            "ethnic wear": .ethnicWear
        ]
        if let mapped = mapping[category] {
            return mapped
        }
        // fallback to existing logic
        if let exact = Category.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(category) == .orderedSame }) {
            return exact
        }
        let lower = category.replacingOccurrences(of: "/", with: "").replacingOccurrences(of: " ", with: "")
        if let partial = Category.allCases.first(where: { lower.contains($0.rawValue.lowercased().replacingOccurrences(of: "/", with: "").replacingOccurrences(of: " ", with: "")) }) {
            return partial
        }
        return nil
    }

    // Improved product matching (case-insensitive, partial, fuzzy, prefer exact/singular/plural)
    func matchProduct(_ product: String?) -> String? {
        guard let product = product, !product.isEmpty else { return nil }
        let lowerProduct = product.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Build a set of all valid products (lowercased, singular/plural forms)
        var allProducts: [String: String] = [:] // lowercased -> canonical
        for (_, products) in productTypesByCategory {
            for prod in products {
                let canonical = prod
                let lower = prod.lowercased()
                allProducts[lower] = canonical
                // Add singular/plural variants
                if lower.hasSuffix("s") {
                    let singular = String(lower.dropLast())
                    allProducts[singular] = canonical
                } else {
                    let plural = lower + "s"
                    allProducts[plural] = canonical
                }
            }
        }
        // 1. Exact match (case-insensitive, singular/plural)
        if let match = allProducts[lowerProduct] {
            return match
        }
        // 2. Try capitalized
        if let match = allProducts[lowerProduct.capitalized] {
            return match
        }
        // 3. Prefix match (e.g. 'overcoat' -> 'Overcoats')
        if let match = allProducts.first(where: { lowerProduct.hasPrefix($0.key) || $0.key.hasPrefix(lowerProduct) })?.value {
            return match
        }
        // 4. Partial match
        if let match = allProducts.first(where: { lowerProduct.contains($0.key) || $0.key.contains(lowerProduct) })?.value {
            return match
        }
        // 5. Fuzzy match fallback (Levenshtein)
        var bestScore = Int.max
        var bestProduct: String? = nil
        for (key, canonical) in allProducts {
            let score = Self.levenshtein(lowerProduct, key)
            if score < bestScore {
                bestScore = score
                bestProduct = canonical
            }
        }
        return bestScore <= 3 ? bestProduct : nil
    }

    // Improved color matching (accept more names, fallback to Gemini value)
    private func matchColor(_ color: String?) -> String? {
        guard let color = color, !color.isEmpty else { return nil }
        let knownColors = ["black", "white", "gray", "beige", "brown", "navy", "red", "green", "blue", "yellow", "orange", "purple", "pink", "gold", "silver", "cream", "maroon", "olive", "teal", "cyan"]
        let lower = color.lowercased()
        if let match = knownColors.first(where: { lower == $0 || lower.contains($0) || $0.contains(lower) }) {
            return match.capitalized
        }
        // Accept Gemini's value as fallback
        return color.capitalized
    }

    // Levenshtein distance for fuzzy matching
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        var dist = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { dist[i][0] = i }
        for j in 0...b.count { dist[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i-1] == b[j-1] {
                    dist[i][j] = dist[i-1][j-1]
                } else {
                    dist[i][j] = min(dist[i-1][j-1], dist[i][j-1], dist[i-1][j]) + 1
                }
            }
        }
        return dist[a.count][b.count]
    }

    // Suggest an outfit using Gemini based on the current wardrobe
    struct SuggestedOutfitItem: Codable {
        let category: String
        let product: String
        let colors: [String]
        let pattern: String
        let brand: String?
    }
    
    func suggestOutfitBatch(from wardrobe: [WardrobeItem], outfitType: OutfitType? = nil, customDescription: String? = nil, weather: Weather? = nil, user: User? = nil) async -> [[SuggestedOutfitItem]]? {
        // 1. Summarize the wardrobe
        let wardrobeSummary = wardrobe.enumerated().map { (idx, item) in
            "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        
        // 2. Create the improved prompt for 5 suggestions
        let typeInstruction: String
        if let custom = customDescription, !custom.isEmpty {
            typeInstruction = "The user described their event or outfit as: \"\(custom)\". Please tailor your suggestions for this context."
        } else if let outfitType = outfitType {
            typeInstruction = "The user wants an outfit for: \(outfitType.rawValue). Please tailor your suggestions for this context."
        } else if let user = user {
            let styles = user.preferredStyles.map { $0.rawValue }.joined(separator: ", ")
            typeInstruction = "The user prefers these styles: \(styles). Suggest outfits that fit one of these styles."
        } else {
            typeInstruction = "The user wants an everyday casual outfit."
        }
        // Add weather context if available
        let weatherInstruction: String
        if let weather = weather {
            let temp = Int(weather.temperature2m)
            let desc = WeatherService.weatherDescription(for: weather.weathercode)
            let city = weather.city ?? "their location"
            let seasonHint: String
            switch temp {
            case ..<5: seasonHint = "It is very cold (winter-like). Suggest warm, layered, insulated outfits. Avoid summer wear." // <5°C
            case 5..<15: seasonHint = "It is cool (spring/fall-like). Suggest light jackets, sweaters, or layers. Avoid heavy winter or summer-only outfits."
            case 15..<25: seasonHint = "It is mild and pleasant. Suggest comfortable, breathable outfits. Avoid heavy winter clothing."
            case 25...: seasonHint = "It is hot (summer-like). Suggest light, breathable, sun-protective outfits. Avoid heavy or warm clothing."
            default: seasonHint = ""
            }
            weatherInstruction = "The current weather in \(city) is: \(desc), temperature: \(temp)°C. \(seasonHint)"
        } else {
            weatherInstruction = "No weather information is available. Suggest outfits suitable for a typical day."
        }
        let prompt = """
You are an expert fashion stylist. Given the following wardrobe items, suggest 5 different, stylish, harmonious, and practical outfits for today. Each outfit should:
- Follow established fashion rules and color theory (complementary, analogous, neutral, and triadic color schemes).
- Only combine items that make sense together (e.g., appropriate layering, no duplicate product types unless it makes sense, etc.).
- Avoid clashing colors, too many patterns, or inappropriate combinations (e.g., no sandals with winter coats, no more than one statement pattern).
- Prefer color harmony: neutrals go with anything, but bold colors should be paired thoughtfully.
- Be distinct from each other (no duplicate combinations).
- Only use items from the provided list. Do not invent or hallucinate new items.
- For each item in the outfit, specify: category, product, colors (array), pattern, and brand (optional).
\(typeInstruction)
\(weatherInstruction)
Return your answer as a JSON array of 5 arrays, where each inner array is an outfit (array of objects with: category, product, colors, pattern, and brand).

Here is the wardrobe:
\n\(wardrobeSummary)\n
Return only the JSON array, no extra text.
"""
        // DEBUG: Print the prompt being sent
        //         print("\n--- GEMINI OUTFIT SUGGESTION PROMPT ---\n\(prompt)\n--- END PROMPT ---\n")
        // 3. Prepare Gemini API request
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]
        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text,
               let arrData = text.data(using: .utf8) {
                // DEBUG: Print the raw Gemini response
                //         print("\n--- GEMINI RAW RESPONSE ---\n\(text)\n--- END RESPONSE ---\n")
                let decoder = JSONDecoder()
                if let arr = try? decoder.decode([[SuggestedOutfitItem]].self, from: arrData) {
                    return arr
                } else {
                    return nil
                }
            } else {
                return nil
            }
        } catch {
            return nil
        }
    }

    enum PartialShuffleResult {
        case success(ImageAnalysisService.SuggestedOutfitItem)
        case rateLimited
        case failure
    }

    func suggestPartialShuffleWithResult(currentOutfit: Outfit, categoryToShuffle: Category, availableItems: [WardrobeItem]) async -> PartialShuffleResult {
        let outfitSummary = currentOutfit.items.map { item in
            "Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        let availableSummary = availableItems.enumerated().map { (idx, item) in
            "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        let prompt = """
You are an expert fashion stylist. Given the following information, suggest a new item for a specific category to improve today's outfit, while keeping all other items unchanged.\n\n**Current Outfit:**\n\(outfitSummary)\n\n**Category to Shuffle:** \(categoryToShuffle.rawValue)\n\n**Available Items in This Category:**\n\(availableSummary)\n\n**Instructions:**\n- Suggest a new item for the category \"\(categoryToShuffle.rawValue)\" from the available items in that category.\n- The new item must be different from the current one in the outfit.\n- The new item must harmonize with the rest of the outfit, following established fashion rules and color theory (complementary, analogous, neutral, and triadic color schemes).\n- Only combine items that make sense together (e.g., seasonally appropriate, no clashing colors, no more than one statement pattern, no sandals with winter coats, etc.).\n- Prefer color harmony: neutrals go with anything, but bold colors should be paired thoughtfully.\n- Avoid inappropriate combinations (e.g., no sandals with winter coats, no more than one statement pattern).\n- Do not repeat the same product type (e.g., two tops).\n- Only use items from the provided list. Do not invent or hallucinate new items.\n- Do not change any other items in the outfit.\n- If you cannot find a perfect match, return the closest possible match from the available items. You must always return a result.\n- Return your answer as a JSON object with the following fields: category, product, colors (array), pattern, brand.\n- Return only the JSON object, no extra text.\n"
"""
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json"
            ]
        ]
        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return .failure
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 429 {
                    return .rateLimited
                }
                if httpResponse.statusCode != 200 {
                    return .failure
                }
            }
            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text,
               let objData = text.data(using: .utf8) {
                let decoder = JSONDecoder()
                if let item = try? decoder.decode(SuggestedOutfitItem.self, from: objData) {
                    return .success(item)
                }
            }
        } catch {
            // No print, just fail
        }
        // Fallback: return the first available item that is not the current one
        let currentItem = currentOutfit.items.first { $0.category == categoryToShuffle }
        if let currentItem = currentItem {
            if let fallback = availableItems.first(where: { $0.id != currentItem.id }) {
                return .success(SuggestedOutfitItem(
                    category: fallback.category.rawValue,
                    product: fallback.product,
                    colors: fallback.colors,
                    pattern: fallback.pattern.rawValue,
                    brand: fallback.brand
                ))
            }
            return .success(SuggestedOutfitItem(
                category: currentItem.category.rawValue,
                product: currentItem.product,
                colors: currentItem.colors,
                pattern: currentItem.pattern.rawValue,
                brand: currentItem.brand
            ))
        }
        return .failure
    }

    // For backward compatibility
    func suggestPartialShuffle(currentOutfit: Outfit, categoryToShuffle: Category, availableItems: [WardrobeItem]) async -> SuggestedOutfitItem? {
        let result = await suggestPartialShuffleWithResult(currentOutfit: currentOutfit, categoryToShuffle: categoryToShuffle, availableItems: availableItems)
        if case let .success(item) = result {
            return item
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