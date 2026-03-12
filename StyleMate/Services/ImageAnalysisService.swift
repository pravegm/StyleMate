import Foundation
import UIKit

class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}
    
    private let geminiAPIKey = Secrets.geminiAPIKey
    private let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key="
    
    struct BoundingBox: Codable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    // MARK: - Segmentation Pipeline

    struct SegmentedItem {
        let category: Category?
        let product: String?
        let colors: [String]
        let pattern: Pattern?
        let maskImage: UIImage?
    }

    func analyzeAndSegment(image: UIImage, retryCount: Int = 0) async -> [SegmentedItem] {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("[StyleMate] Segmentation: Failed to convert image to JPEG")
            return []
        }
        let base64Image = imageData.base64EncodedString()
        print("[StyleMate] Segmentation: Image encoded: \(imageData.count) bytes (attempt \(retryCount + 1))")

        let validCategories = Category.allCases.map(\.rawValue).joined(separator: ", ")
        let validPatterns = Pattern.allCases.map(\.rawValue).joined(separator: ", ")
        let validProducts = productTypesByCategory.map { cat, prods in
            "- \(cat.rawValue): \(prods.joined(separator: ", "))"
        }.joined(separator: "\n")

        let prompt = """
You are an expert fashion assistant. Analyze the clothing items worn by the person in this image.

For EACH visible clothing item (including partially visible ones), provide:
- category: one of [\(validCategories)]
- product: one of the valid products for that category
- colors: array of color names
- pattern: one of [\(validPatterns)]
- label: a short description of the item

Valid products per category:
\(validProducts)

Also provide segmentation data:
- box_2d: bounding box as [y0, x0, y1, x1] normalized to 0-1000
- mask: segmentation mask for JUST the clothing item (no skin, no face, no hair, no other garments)

Output a JSON list of segmentation masks where each entry contains the 2D bounding box in the key "box_2d", the segmentation mask in key "mask", and the text label in the key "label".

Also include "category", "product", "colors", and "pattern" keys for each item.

IMPORTANT: The mask should cover ONLY the fabric/material of that specific garment. Do NOT include any skin, face, hair, hands, or other body parts in the mask. Do NOT include other garments that overlap.
"""

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
                "temperature": 0.5,
                "thinkingConfig": [
                    "thinkingBudget": 0
                ]
            ]
        ]

        guard let url = URL(string: geminiEndpoint + geminiAPIKey) else {
            print("[StyleMate] Segmentation: Invalid API URL")
            return []
        }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            print("[StyleMate] Segmentation: Failed to serialize request body")
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 90

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[StyleMate] Segmentation: No HTTP response received")
                return []
            }
            print("[StyleMate] Segmentation: HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 429 {
                if retryCount < 3 {
                    let delay = UInt64(pow(2.0, Double(retryCount + 1))) * 1_000_000_000
                    print("[StyleMate] Segmentation: Rate limited, waiting \(delay / 1_000_000_000)s before retry...")
                    try? await Task.sleep(nanoseconds: delay)
                    return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
                }
                print("[StyleMate] Segmentation: Rate limited after all retries")
                return []
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[StyleMate] Segmentation: API error \(httpResponse.statusCode): \(errorBody.prefix(500))")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
                }
                return []
            }

            guard let responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = responseJson["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                print("[StyleMate] Segmentation: Unexpected response structure")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
                }
                return []
            }

            guard let textPart = parts.first(where: { $0["text"] != nil }),
                  let text = textPart["text"] as? String else {
                print("[StyleMate] Segmentation: No text part in response")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
                }
                return []
            }

            print("[StyleMate] Segmentation: Response text length: \(text.count)")

            guard let itemsArray = parseSegmentationJSON(text) else {
                print("[StyleMate] Segmentation: Failed to parse JSON from response")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
                }
                return []
            }

            print("[StyleMate] Segmentation: Parsed \(itemsArray.count) items")

            var results: [SegmentedItem] = []
            for (i, dict) in itemsArray.enumerated() {
                let catStr = (dict["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let prodStr = (dict["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let colorsArr = dict["colors"] as? [String] ?? []
                let patStr = (dict["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let category = matchCategory(catStr)
                let product = matchProduct(prodStr)
                let colors = colorsArr.map { matchColor($0) ?? $0 }.filter { !$0.isEmpty }
                let pattern = matchPattern(patStr)

                guard let category = category, let product = product, let pattern = pattern, !colors.isEmpty else {
                    print("[StyleMate] Segmentation item \(i): SKIP - parsing failed (cat=\(catStr ?? "nil"), prod=\(prodStr ?? "nil"))")
                    continue
                }

                var garmentImage: UIImage? = nil

                if let box = dict["box_2d"] as? [Int], box.count == 4,
                   let maskBase64 = dict["mask"] as? String {
                    garmentImage = extractGarment(from: image, boxNormalized: box, maskBase64: maskBase64)
                    if garmentImage != nil {
                        print("[StyleMate] Segmentation item \(i): Mask extracted successfully for \(category.rawValue)/\(product)")
                    } else {
                        print("[StyleMate] Segmentation item \(i): Mask extraction failed, falling back for \(category.rawValue)/\(product)")
                    }
                } else {
                    let boxRaw = dict["box_2d"]
                    if let boxDoubles = boxRaw as? [Double], boxDoubles.count == 4 {
                        let boxInts = boxDoubles.map { Int($0) }
                        if let maskBase64 = dict["mask"] as? String {
                            garmentImage = extractGarment(from: image, boxNormalized: boxInts, maskBase64: maskBase64)
                        }
                    }
                    if garmentImage == nil {
                        print("[StyleMate] Segmentation item \(i): No valid box_2d/mask, falling back for \(category.rawValue)/\(product)")
                    }
                }

                if garmentImage == nil {
                    let bgRemoved = await BackgroundRemovalService.shared.removeBackground(from: image)
                    let cropped = BodyZone.cropToZone(image: bgRemoved ?? image, category: category) ?? bgRemoved ?? image
                    garmentImage = padToSquare(cropped)
                    print("[StyleMate] Segmentation item \(i): Fallback pipeline used for \(category.rawValue)/\(product)")
                }

                results.append(SegmentedItem(
                    category: category,
                    product: product,
                    colors: colors,
                    pattern: pattern,
                    maskImage: garmentImage
                ))
                print("[StyleMate] Segmentation item \(i): OK - \(category.rawValue) / \(product) / \(colors.joined(separator: ",")) / \(pattern.rawValue)")
            }

            if results.isEmpty && !itemsArray.isEmpty && retryCount < 2 {
                print("[StyleMate] Segmentation: All \(itemsArray.count) items failed to parse, retrying...")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
            }

            print("[StyleMate] Segmentation: Returning \(results.count) segmented items")
            return results

        } catch {
            print("[StyleMate] Segmentation: Network error: \(error.localizedDescription)")
            if retryCount < 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await analyzeAndSegment(image: image, retryCount: retryCount + 1)
            }
            return []
        }
    }

    private func parseSegmentationJSON(_ text: String) -> [[String: Any]]? {
        var cleanText = text
        if cleanText.contains("```json") {
            cleanText = cleanText.components(separatedBy: "```json").last ?? cleanText
            cleanText = cleanText.components(separatedBy: "```").first ?? cleanText
        } else if cleanText.contains("```") {
            let parts = cleanText.components(separatedBy: "```")
            if parts.count >= 2 {
                cleanText = parts[1]
            }
        }
        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleanText.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return array
    }

    private func extractGarment(from originalImage: UIImage, boxNormalized: [Int], maskBase64: String) -> UIImage? {
        guard let cgImage = originalImage.cgImage else { return nil }
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

        let y0 = CGFloat(boxNormalized[0]) / 1000.0 * imgHeight
        let x0 = CGFloat(boxNormalized[1]) / 1000.0 * imgWidth
        let y1 = CGFloat(boxNormalized[2]) / 1000.0 * imgHeight
        let x1 = CGFloat(boxNormalized[3]) / 1000.0 * imgWidth

        let boxWidth = x1 - x0
        let boxHeight = y1 - y0
        guard boxWidth > 0, boxHeight > 0 else { return nil }

        var cleanBase64 = maskBase64
        if let range = cleanBase64.range(of: "base64,") {
            cleanBase64 = String(cleanBase64[range.upperBound...])
        }

        guard let maskData = Data(base64Encoded: cleanBase64),
              let maskUIImage = UIImage(data: maskData),
              let maskCG = maskUIImage.cgImage else { return nil }

        let maskSize = CGSize(width: boxWidth, height: boxHeight)
        UIGraphicsBeginImageContextWithOptions(maskSize, false, 1.0)
        guard let maskContext = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }
        maskContext.draw(maskCG, in: CGRect(origin: .zero, size: maskSize))
        guard let resizedMaskCG = maskContext.makeImage() else {
            UIGraphicsEndImageContext()
            return nil
        }
        UIGraphicsEndImageContext()

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let binaryContext = CGContext(
            data: nil,
            width: Int(boxWidth),
            height: Int(boxHeight),
            bitsPerComponent: 8,
            bytesPerRow: Int(boxWidth),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        binaryContext.draw(resizedMaskCG, in: CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight))

        guard let pixelData = binaryContext.data else { return nil }
        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: Int(boxWidth * boxHeight))
        for i in 0..<Int(boxWidth * boxHeight) {
            buffer[i] = buffer[i] > 127 ? 255 : 0
        }
        guard let binarizedMaskCG = binaryContext.makeImage() else { return nil }

        let cropRect = CGRect(x: x0, y: y0, width: boxWidth, height: boxHeight)
        guard let croppedCG = cgImage.cropping(to: cropRect) else { return nil }

        let outputSize = CGSize(width: boxWidth, height: boxHeight)
        UIGraphicsBeginImageContextWithOptions(outputSize, false, originalImage.scale)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        ctx.translateBy(x: 0, y: boxHeight)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: CGRect(origin: .zero, size: outputSize), mask: binarizedMaskCG)
        ctx.draw(croppedCG, in: CGRect(origin: .zero, size: outputSize))

        let garmentImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let garment = garmentImage else { return nil }
        return padToSquare(garment)
    }

    func padToSquare(_ image: UIImage) -> UIImage {
        let maxDimension = max(image.size.width, image.size.height)
        let padding = maxDimension * 0.05
        let canvasSize = maxDimension + padding * 2

        UIGraphicsBeginImageContextWithOptions(
            CGSize(width: canvasSize, height: canvasSize),
            false,
            image.scale
        )
        let x = (canvasSize - image.size.width) / 2
        let y = (canvasSize - image.size.height) / 2
        image.draw(in: CGRect(x: x, y: y, width: image.size.width, height: image.size.height))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()

        return result
    }

    // MARK: - Classification Pipeline (legacy)

    func analyzeMultiple(image: UIImage, imageIndex: Int? = nil, retryCount: Int = 0) async -> [(category: Category?, product: String?, colors: [String], pattern: Pattern?)] {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("[StyleMate] Failed to convert image to JPEG")
            return []
        }
        let base64Image = imageData.base64EncodedString()
        print("[StyleMate] Image encoded: \(imageData.count) bytes (attempt \(retryCount + 1))")

        let prompt = """
You are an expert fashion assistant. Analyze the clothing items worn by the person in this image.

Valid categories: Tops, Bottoms, Mid-Layers, Outerwear, One-Pieces, Footwear, Accessories, Innerwear, Activewear, Ethnic Wear

Valid products per category:
- Tops: T-Shirts, Polo T-Shirts, Shirts, Blouses, Tank Tops, Tube Tops, Camisoles, Crop Tops, Off-Shoulder Tops, Bodysuits, Graphic Tees, Mesh Tops, Turtlenecks
- Bottoms: Jeans, Trousers, Leggings, Joggers, Cargo Pants, Shorts, Skirts, Skorts, Palazzo Pants
- Mid-Layers: Hoodies, Sweatshirts, Sweaters, Cardigans, Pullovers, Fleece Jackets, Vests, Shrugs, Gilets
- Outerwear: Jackets, Coats, Puffer Jackets, Trench Coats, Blazers, Overcoats, Raincoats
- One-Pieces: Dresses, Jumpsuits, Rompers, Playsuits, Dungarees, Overalls
- Footwear: Sneakers, Boots, Heels, Flats, Sandals, Slippers, Loafers, Formal shoes
- Accessories: Hats, Scarves, Gloves, Belts, Handbags, Jewelry, Watches, Sunglasses, Hair Accessories, Ties, Bowties
- Innerwear: Bras, Underwear, Boxers, Thongs, Socks, Thermal Wear, Shapewear, Lingerie
- Activewear: Sports Bras, Active Leggings, Athletic Tops, Track Pants, Athletic Shorts, Active Jackets, Compression Wear, Swimwear, Tennis Dresses
- Ethnic Wear: Kurta, Kurti, Sherwani, Nehru Jacket, Dupatta, Saree, Blouse (saree), Lehenga, Choli, Salwar, Patiala Pants, Anarkali, Angrakha, Dhoti, Lungis, Mundu, Jodhpuri Suit

Valid patterns: Solid, Stripes, Checks, Plaid, Polka Dot, Floral, Animal Print, Camouflage, Geometric, Houndstooth, Paisley, Tie-Dye

For EACH visible clothing item, return:
- category: one of the valid categories above (exact string)
- product: one of the valid products above (exact string)
- colors: array of color names (MUST have at least one, e.g. [\"Blue\", \"White\"])
- pattern: one of the valid patterns above (exact string)

Return a JSON array of objects. Use EXACT strings from the lists above.
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
                    "pattern": ["type": "string"]
                ],
                "required": ["category", "product", "colors", "pattern"]
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

        guard let url = URL(string: geminiEndpoint + geminiAPIKey) else {
            print("[StyleMate] Invalid API URL")
            return []
        }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            print("[StyleMate] Failed to serialize request body")
            return []
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[StyleMate] No HTTP response received")
                return []
            }
            print("[StyleMate] HTTP \(httpResponse.statusCode)")

            if httpResponse.statusCode == 429 {
                if retryCount < 3 {
                    let delay = UInt64(pow(2.0, Double(retryCount + 1))) * 1_000_000_000
                    print("[StyleMate] Rate limited, waiting \(delay / 1_000_000_000)s before retry...")
                    try? await Task.sleep(nanoseconds: delay)
                    return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
                }
                print("[StyleMate] Rate limited after all retries")
                return []
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[StyleMate] API error \(httpResponse.statusCode): \(errorBody.prefix(500))")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
                }
                return []
            }

            // Parse the Gemini response manually for robustness
            guard let responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[StyleMate] Response is not valid JSON: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "nil")")
                return await retryOrEmpty(image: image, imageIndex: imageIndex, retryCount: retryCount)
            }

            guard let candidates = responseJson["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                print("[StyleMate] Unexpected response structure: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
                return await retryOrEmpty(image: image, imageIndex: imageIndex, retryCount: retryCount)
            }

            // Find the text part (skip thinking parts if present with 2.5 Flash)
            guard let textPart = parts.first(where: { $0["text"] != nil }),
                  let text = textPart["text"] as? String else {
                print("[StyleMate] No text part in response parts: \(parts)")
                return await retryOrEmpty(image: image, imageIndex: imageIndex, retryCount: retryCount)
            }

            print("[StyleMate] Response text: \(text.prefix(300))")

            guard let textData = text.data(using: .utf8),
                  let itemsArray = try? JSONSerialization.jsonObject(with: textData) as? [[String: Any]] else {
                print("[StyleMate] Failed to parse JSON array from response text")
                return await retryOrEmpty(image: image, imageIndex: imageIndex, retryCount: retryCount)
            }

            print("[StyleMate] Parsed \(itemsArray.count) raw items from API")

            // Parse each item with fuzzy matching
            var validResults: [(Category?, String?, [String], Pattern?)] = []
            for (i, dict) in itemsArray.enumerated() {
                let catStr = (dict["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let prodStr = (dict["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let colorsArr = dict["colors"] as? [String] ?? []
                let patStr = (dict["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let category = matchCategory(catStr)
                let product = matchProduct(prodStr)
                let colors = colorsArr.map { matchColor($0) ?? $0 }.filter { !$0.isEmpty }
                let pattern = matchPattern(patStr)

                if let category = category, let product = product, let pattern = pattern, !colors.isEmpty {
                    validResults.append((category, product, colors, pattern))
                    print("[StyleMate] Item \(i): OK - \(category.rawValue) / \(product) / \(colors.joined(separator: ",")) / \(pattern.rawValue)")
                } else {
                    print("[StyleMate] Item \(i): SKIP - raw(cat=\(catStr ?? "nil"), prod=\(prodStr ?? "nil"), pat=\(patStr ?? "nil"), colors=\(colorsArr)) -> matched(cat=\(category?.rawValue ?? "nil"), prod=\(product ?? "nil"), pat=\(pattern?.rawValue ?? "nil"), colors=\(colors.count))")
                }
            }

            // Retry only if the API returned items but ALL failed parsing
            if validResults.isEmpty && !itemsArray.isEmpty && retryCount < 2 {
                print("[StyleMate] All \(itemsArray.count) items failed to parse, retrying...")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
            }

            print("[StyleMate] Returning \(validResults.count) valid items")
            return validResults

        } catch {
            print("[StyleMate] Network error: \(error.localizedDescription)")
            if retryCount < 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
            }
            return []
        }
    }

    private func retryOrEmpty(image: UIImage, imageIndex: Int?, retryCount: Int) async -> [(category: Category?, product: String?, colors: [String], pattern: Pattern?)] {
        if retryCount < 2 {
            print("[StyleMate] Retrying (attempt \(retryCount + 2))...")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return await analyzeMultiple(image: image, imageIndex: imageIndex, retryCount: retryCount + 1)
        }
        print("[StyleMate] All retries exhausted, returning empty")
        return []
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

    func matchPattern(_ pattern: String?) -> Pattern? {
        guard let pattern = pattern?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty else { return nil }
        if let exact = Pattern(rawValue: pattern) { return exact }
        let lower = pattern.lowercased()
        for p in Pattern.allCases {
            if p.rawValue.lowercased() == lower { return p }
        }
        let normalized = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        for p in Pattern.allCases {
            let pNorm = p.rawValue.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if pNorm == normalized || pNorm.contains(normalized) || normalized.contains(pNorm) { return p }
        }
        var bestScore = Int.max
        var bestPattern: Pattern? = nil
        for p in Pattern.allCases {
            let score = Self.levenshtein(lower, p.rawValue.lowercased())
            if score < bestScore { bestScore = score; bestPattern = p }
        }
        return bestScore <= 3 ? bestPattern : nil
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
        // Add gender context if available
        let genderInstruction: String
        if let gender = user?.gender, !gender.isEmpty {
            genderInstruction = "The user's gender is: \(gender). Please ensure your suggestions are appropriate for this gender."
        } else {
            genderInstruction = ""
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
- Each outfit must be a complete, wearable look for going out in public, using items from the wardrobe. Do not suggest incomplete outfits (e.g., just outerwear and accessories).
- If a one-piece item (like a dress, jumpsuit, or ethnic set) is used, a separate top or bottom is not needed.
- For ethnic or cultural outfits, ensure the look is complete and appropriate as per cultural norms (e.g., a kurta with a bottom, a sari with a blouse and petticoat, etc.).
- Never suggest an outfit that would leave the wearer inappropriately dressed (e.g., only a cardigan, shoes, and sunglasses).
- Use your knowledge of fashion to ensure every outfit is practical, stylish, and something a person could actually wear outside.
- Ensure each outfit is appropriate for the weather context provided.
\(typeInstruction)
\(genderInstruction)
\(weatherInstruction)
Return your answer as a JSON array of 5 arrays, where each inner array is an outfit (array of objects with: category, product, colors, pattern, and brand).

Here is the wardrobe:
\n\(wardrobeSummary)\n
Return only the JSON array, no extra text.
"""
        // Prepare Gemini API request
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

    enum PartialShuffleResult {
        case success(ImageAnalysisService.SuggestedOutfitItem)
        case rateLimited
        case failure
    }

    func suggestPartialShuffleWithResult(currentOutfit: Outfit, categoryToShuffle: Category, availableItems: [WardrobeItem], user: User? = nil) async -> PartialShuffleResult {
        let outfitSummary = currentOutfit.items.map { item in
            "Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        let availableSummary = availableItems.enumerated().map { (idx, item) in
            "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        let genderInstruction: String
        if let gender = user?.gender, !gender.isEmpty {
            genderInstruction = "The user's gender is: \(gender). Please ensure your suggestions are appropriate for this gender."
        } else {
            genderInstruction = ""
        }
        let prompt = """
You are an expert fashion stylist. Given the following information, suggest a new item for a specific category to improve today's outfit, while keeping all other items unchanged.\n\n**Current Outfit:**\n\(outfitSummary)\n\n**Category to Shuffle:** \(categoryToShuffle.rawValue)\n\n**Available Items in This Category:**\n\(availableSummary)\n\n\(genderInstruction)\n**Instructions:**\n- Suggest a new item for the category \"\(categoryToShuffle.rawValue)\" from the available items in that category.\n- The new item must be different from the current one in the outfit.\n- The new item must harmonize with the rest of the outfit, following established fashion rules and color theory (complementary, analogous, neutral, and triadic color schemes).\n- Only combine items that make sense together (e.g., seasonally appropriate, no clashing colors, no more than one statement pattern, no sandals with winter coats, etc.).\n- Prefer color harmony: neutrals go with anything, but bold colors should be paired thoughtfully.\n- Avoid inappropriate combinations (e.g., no sandals with winter coats, no more than one statement pattern).\n- Do not repeat the same product type (e.g., two tops).\n- Only use items from the provided list. Do not invent or hallucinate new items.\n- Do not change any other items in the outfit.\n- If you cannot find a perfect match, return the closest possible match from the available items. You must always return a result.\n- Return your answer as a JSON object with the following fields: category, product, colors (array), pattern, brand.\n- Return only the JSON object, no extra text.\n"
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

    /// Suggests a new outfit by adding a product of the given type (from availableItems) to the current outfit using Gemini.
    /// Returns the new suggested outfit as an array of SuggestedOutfitItem (or nil on failure).
    func suggestAddProductToOutfit(currentOutfit: Outfit, category: Category, productType: String, availableItems: [WardrobeItem], user: User? = nil) async -> [SuggestedOutfitItem]? {
        // 1. Summarize the current outfit
        let outfitSummary = currentOutfit.items.map { item in
            "Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        // 2. Summarize the available items for the product type
        let availableSummary = availableItems.enumerated().map { (idx, item) in
            "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
        }.joined(separator: "\n")
        let genderInstruction: String
        if let gender = user?.gender, !gender.isEmpty {
            genderInstruction = "The user's gender is: \(gender). Please ensure your suggestions are appropriate for this gender."
        } else {
            genderInstruction = ""
        }
        // 3. Build the prompt
        let prompt = """
You are an expert fashion stylist. The user has an outfit and wants to add a \(productType) (category: \(category.rawValue)) to it.

Here is the current outfit:
\(outfitSummary)

Here are the \(productType) options from the user's wardrobe (choose only from these):
\(availableSummary)

\(genderInstruction)
Guidelines:
- Follow established fashion rules and color theory (complementary, analogous, neutral, and triadic color schemes).
- Only combine items that make sense together (e.g., appropriate layering, no duplicate product types unless it makes sense, seasonally appropriate, etc.).
- Avoid clashing colors, too many patterns, or inappropriate combinations (e.g., no sandals with winter coats, no more than one statement pattern).
- Prefer color harmony: neutrals go with anything, but bold colors should be paired thoughtfully.
- Be distinct and practical.
- Only use items from the provided lists. Do not invent or hallucinate new items.
- Do not remove any existing items unless absolutely necessary for style or practicality.

Please update the outfit by adding the best \(productType) from the list above, ensuring the new outfit is stylish, harmonious, and practical.

Return the new outfit as a JSON array of objects, where each object has: category, product, colors (array), pattern, and brand. Return only the JSON array, no extra text.
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
                if let arr = try? decoder.decode([SuggestedOutfitItem].self, from: arrData) {
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