import Foundation
import UIKit

class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}
    
    // Gemini 2.5 Flash API Key
    private let geminiAPIKey = "AIzaSyAoq8aUGlzCQzeq1pSKqRjThZ-qeaneQO8"
    private let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-preview-04-17:generateContent?key="
    
    func analyze(image: UIImage) async -> (category: Category?, product: String?, color: String?) {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("[Gemini] Failed to get JPEG data from image.")
            return (nil, nil, nil)
        }
        let base64Image = imageData.base64EncodedString()
        let prompt = "You are a fashion assistant. Given an image of a clothing item, identify: 1) the category (one of: Tops, Bottoms, OnePieces, Footwear, Accessories, Innerwear & Sleepwear, Ethnic/Occasionwear, Seasonal/Layering), 2) the product type (e.g. T-shirts, Jeans, Dresses, etc.), and 3) the main color (e.g. Black, White, Red, etc.). Respond in JSON: {\"category\":..., \"product\":..., \"color\":...}."
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
            ]
        ]
        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            print("[Gemini] Failed to construct URL or HTTP body.")
            return (nil, nil, nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("[Gemini] HTTP status: \(httpResponse.statusCode)")
            }
            if let rawString = String(data: data, encoding: .utf8) {
                print("[Gemini] Raw API response: \n\(rawString)")
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("[Gemini] Non-200 response.")
                return (nil, nil, nil)
            }
            // Parse Gemini response
            if let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let text = result.candidates.first?.content.parts.first?.text {
                print("[Gemini] Extracted text: \n\(text)")
                if let dict = extractAndParseJSON(from: text) {
                    print("[Gemini] Extracted JSON: \n\(dict)")
                    let categoryString = (dict["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let productString = (dict["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let colorString = (dict["color"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let category = matchCategory(categoryString)
                    let product = matchProduct(productString)
                    let color = matchColor(colorString)
                    print("[Gemini] Final mapped values: category=\(String(describing: category)), product=\(String(describing: product)), color=\(String(describing: color))")
                    return (category, product, color)
                } else {
                    print("[Gemini] Failed to extract JSON from text.")
                }
            } else {
                print("[Gemini] Failed to decode GeminiResponse or extract text.")
            }
        } catch {
            print("[Gemini] Error during API call or parsing: \(error)")
            return (nil, nil, nil)
        }
        return (nil, nil, nil)
    }

    // Extract JSON from markdown/code block or extra text
    private func extractAndParseJSON(from text: String) -> [String: Any]? {
        // Try to find the first { ... } block
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        let jsonString = String(text[start...end])
        print("[Gemini] JSON substring to parse: \n\(jsonString)")
        if let data = jsonString.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        return nil
    }

    // Improved category matching (case-insensitive, partial)
    private func matchCategory(_ category: String?) -> Category? {
        guard let category = category else { return nil }
        // Exact match
        if let exact = Category.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(category) == .orderedSame }) {
            return exact
        }
        // Partial match
        let lower = category.lowercased()
        if let partial = Category.allCases.first(where: { lower.contains($0.rawValue.lowercased().replacingOccurrences(of: "/", with: "").replacingOccurrences(of: " ", with: "")) }) {
            return partial
        }
        return nil
    }

    // Improved product matching (case-insensitive, partial, fuzzy)
    private func matchProduct(_ product: String?) -> String? {
        guard let product = product else { return nil }
        // Exact match
        for (_, products) in productTypesByCategory {
            if let match = products.first(where: { $0.caseInsensitiveCompare(product) == .orderedSame }) {
                return match
            }
        }
        // Partial match
        let lower = product.lowercased()
        for (_, products) in productTypesByCategory {
            if let match = products.first(where: { lower.contains($0.lowercased()) || $0.lowercased().contains(lower) }) {
                return match
            }
        }
        // Fuzzy match fallback
        var bestScore = Int.max
        var bestProduct: String? = nil
        for (_, products) in productTypesByCategory {
            for prod in products {
                let score = Self.levenshtein(product.lowercased(), prod.lowercased())
                if score < bestScore {
                    bestScore = score
                    bestProduct = prod
                }
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