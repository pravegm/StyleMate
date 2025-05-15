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
    func analyzeMultiple(image: UIImage) async -> [(category: Category?, product: String?, colors: [String], pattern: Pattern?, boundingBox: BoundingBox?)] {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            return []
        }
        let base64Image = imageData.base64EncodedString()
        // Provide Gemini with the valid categories, products, and patterns, and instruct it to select only from these lists
        let prompt = """
You are an expert fashion assistant. Here are the only valid clothing categories: [Tops, Bottoms, OnePieces, Footwear, Accessories, Innerwear & Sleepwear, Ethnic/Occasionwear, Seasonal/Layering].
For each category, here are the only valid products:
- Tops: T-shirts, Shirts, Polo shirts, Tank tops, Blouses, Crop tops, Sweaters, Sweatshirts, Hoodies, Jackets, Blazers, Cardigans, Vests, Kurtas, Shackets
- Bottoms: Jeans, Trousers, Chinos, Shorts, Skirts, Leggings, Joggers, Track pants, Cargo pants, Dhotis, Salwars
- OnePieces: Dresses, Jumpsuits, Rompers, Sarees, Gowns, Overalls
- Footwear: Sneakers, Formal shoes, Loafers, Boots, Sandals, Flip flops, Heels, Flats, Slippers, Mojaris/Juttis
- Accessories: Watches, Sunglasses, Spectacles, Belts, Hats, Caps, Scarves, Necklaces, Earrings, Bracelets, Bangles, Rings, Ties, Cufflinks, Backpacks, Handbags, Clutches, Wallets
- Innerwear & Sleepwear: Undergarments, Bras, Boxers/Briefs, Night suits, Loungewear, Slips, Thermals
- Ethnic/Occasionwear: Sherwanis, Lehenga cholis, Anarkalis, Nehru jackets, Dupattas, Kurta sets, Blouse (ethnic), Dhoti sets
- Seasonal/Layering: Raincoats, Windcheaters, Overcoats, Thermal inners, Gloves, Beanies
Here are the only valid patterns: [Solid, Stripes, Checks, Plaid, Polka Dot, Floral, Animal Print, Camouflage, Geometric, Houndstooth, Paisley, Tie-Dye].

IMPORTANT: For each clothing item you detect in the image, you MUST select the category, product, and pattern string **EXACTLY** as provided in the above lists. Do not change the spelling, do not use singular or plural forms that are not in the list, do not use synonyms, and do not invent new words. If you are unsure, pick the closest valid string from the list. Your answer must use the exact string from the list, character for character, including spaces, hyphens, and capitalization.

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
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return []
            }
            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text,
               let arrData = text.data(using: .utf8) {
                if let arr = try? JSONSerialization.jsonObject(with: arrData) as? [[String: Any]] {
                    let mapped = arr.map { dict in
                        let categoryString = (dict["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let productString = (dict["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let colorsArray = dict["colors"] as? [String] ?? []
                        let patternString = (dict["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let category = Category(rawValue: categoryString ?? "")
                        let product = productString
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
                        return (category, product, colors, pattern, boundingBox)
                    }
                    return mapped
                } else {
                    return []
                }
            } else {
                return []
            }
        } catch {
            return []
        }
        return []
    }

    // Improved category matching (case-insensitive, partial, with synonyms)
    private func matchCategory(_ category: String?) -> Category? {
        guard let category = category?.lowercased() else { return nil }
        let mapping: [String: Category] = [
            "apparel": .tops,
            "clothing": .tops,
            "top": .tops,
            "tops": .tops,
            "bottom": .bottoms,
            "bottoms": .bottoms,
            "footwear": .footwear,
            "shoes": .footwear,
            "pants": .bottoms,
            "jeans": .bottoms,
            "trousers": .bottoms,
            "shorts": .bottoms,
            "outerwear": .seasonalLayering,
            "jacket": .seasonalLayering,
            "coat": .seasonalLayering,
            "dress": .onePieces,
            "skirt": .bottoms,
            // add more as needed, always use valid Category cases
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
    private func matchProduct(_ product: String?) -> String? {
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
    
    func suggestOutfitBatch(from wardrobe: [WardrobeItem]) async -> [[SuggestedOutfitItem]]? {
        // 1. Summarize the wardrobe
        let wardrobeSummary = wardrobe.enumerated().map { (idx, item) in
            "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        
        // 2. Create the improved prompt for 5 suggestions
        let prompt = """
You are an expert fashion stylist. Given the following wardrobe items, suggest 5 different, stylish, harmonious, and practical outfits for today. Each outfit should:
- Follow established fashion rules and color theory (complementary, analogous, neutral, and triadic color schemes).
- Only combine items that make sense together (e.g., one top, one bottom, one pair of footwear, optionally one accessory and one outerwear).
- Avoid clashing colors, too many patterns, or inappropriate combinations (e.g., no sandals with winter coats, no more than one statement pattern).
- Prefer color harmony: neutrals go with anything, but bold colors should be paired thoughtfully.
- Do not repeat the same product type (e.g., two tops).
- Be distinct from each other (no duplicate combinations).
- Only use items from the provided list. Do not invent or hallucinate new items.
- For each item in the outfit, specify: category, product, colors (array), pattern, and brand (optional).
Return your answer as a JSON array of 5 arrays, where each inner array is an outfit (array of objects with: category, product, colors, pattern, and brand).

Here is the wardrobe:
\n\(wardrobeSummary)\n
Return only the JSON array, no extra text.
"""
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