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

    // MARK: - Classified / Segmented Items

    struct ClassifiedItem {
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
    }

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
        let maskImage: UIImage?
    }

    // MARK: - Segmentation Pipeline

    func analyzeAndSegment(image: UIImage, userGender: String? = nil, retryCount: Int = 0) async -> [SegmentedItem] {
        let normalizedImage = normalizeOrientation(image)
        let classifications = await analyzeMultiple(image: normalizedImage, userGender: userGender)

        guard !classifications.isEmpty else {
            print("[StyleMate] Segmentation: No items classified, returning empty")
            return []
        }

        print("[StyleMate] Segmentation: Pass 1 classified \(classifications.count) items")

        let bgRemovedRaw = await BackgroundRemovalService.shared.removeBackground(from: normalizedImage) ?? normalizedImage
        let bgRemoved = trimWhitespace(bgRemovedRaw)
        print("[StyleMate] Segmentation: BG removed and trimmed: \(Int(bgRemovedRaw.size.width))x\(Int(bgRemovedRaw.size.height)) -> \(Int(bgRemoved.size.width))x\(Int(bgRemoved.size.height))")

        // Use the ORIGINAL image (with background) for bbox detection -- it has full context
        // (floor for shoes, face for glasses, background) that bg-removed images lack.
        let originalForBBox = resizedForAPI(normalizedImage)
        guard let originalData = originalForBBox.jpegData(compressionQuality: 0.7) else { return [] }
        let originalBase64 = originalData.base64EncodedString()
        print("[StyleMate] Segmentation: Original image for bboxes: \(originalData.count) bytes, \(Int(originalForBBox.size.width))x\(Int(originalForBBox.size.height))")

        let validItems = classifications.filter { $0.category != nil && $0.product != nil && $0.pattern != nil && !$0.colors.isEmpty }

        // Split into clothing (batch) vs footwear/accessories (individual focused)
        let clothingCategories: Set<Category> = [.tops, .bottoms, .midLayers, .outerwear, .onePieces, .activewear, .ethnicWear, .innerwear]
        let clothingItems = validItems.filter { clothingCategories.contains($0.category!) }
        let smallItems = validItems.filter { !clothingCategories.contains($0.category!) }

        // Run batch and focused calls in parallel
        async let clothingBoxesTask: [String: [Int]] = {
            let labels = clothingItems.map { "\($0.product!) (\($0.category!.rawValue))" }
            guard !labels.isEmpty else { return [:] }
            return await getAllBoundingBoxes(originalBase64: originalBase64, itemLabels: labels)
        }()

        async let smallItemBoxesTask: [String: [Int]] = {
            guard !smallItems.isEmpty else { return [:] }
            return await withTaskGroup(of: (String, [Int]?).self) { group in
                for item in smallItems {
                    guard let category = item.category, let product = item.product else { continue }
                    let label = "\(product) (\(category.rawValue))"

                    group.addTask {
                        let box = await self.getItemBoundingBoxFocused(
                            originalBase64: originalBase64,
                            product: product,
                            category: category,
                            colors: item.colors,
                            material: item.material,
                            details: item.details
                        )
                        return (label, box)
                    }
                }

                var collected: [String: [Int]] = [:]
                for await (label, box) in group {
                    if let box = box { collected[label] = box }
                }
                return collected
            }
        }()

        let clothingBoxes = await clothingBoxesTask
        let smallItemBoxes = await smallItemBoxesTask

        var allBoxes = clothingBoxes
        allBoxes.merge(smallItemBoxes) { _, new in new }
        print("[StyleMate] Segmentation: Batch got \(clothingBoxes.count) clothing boxes, Focused got \(smallItemBoxes.count) small item boxes")

        // Apply boxes to bgRemovedRaw (same dimensions as original)
        var results: [SegmentedItem] = []
        for item in validItems {
            guard let category = item.category, let product = item.product,
                  let pattern = item.pattern else { continue }

            let label = "\(product) (\(category.rawValue))"
            var garmentImage: UIImage?

            if let box = allBoxes[label] {
                garmentImage = extractGarment(from: bgRemovedRaw, boxNormalized: box)
                if garmentImage != nil {
                    print("[StyleMate] Segmentation: Extracted \(label) via bounding box")
                } else {
                    let cropped = BodyZone.cropToZone(image: bgRemoved, category: category) ?? bgRemoved
                    garmentImage = padToSquare(cropped)
                    print("[StyleMate] Segmentation: BBox extraction failed, fallback for \(label)")
                }
            } else {
                let cropped = BodyZone.cropToZone(image: bgRemoved, category: category) ?? bgRemoved
                garmentImage = padToSquare(cropped)
                print("[StyleMate] Segmentation: No bbox returned, fallback for \(label)")
            }

            results.append(SegmentedItem(
                category: category,
                product: product,
                colors: item.colors,
                pattern: pattern,
                material: item.material,
                fit: item.fit,
                neckline: item.neckline,
                sleeveLength: item.sleeveLength,
                garmentLength: item.garmentLength,
                details: item.details,
                maskImage: garmentImage
            ))
        }

        print("[StyleMate] Segmentation: Returning \(results.count) items")
        return results
    }

    /// Gets bounding boxes for ALL classified items in a single Gemini call using the original image.
    private func getAllBoundingBoxes(
        originalBase64: String,
        itemLabels: [String]
    ) async -> [String: [Int]] {
        let itemList = itemLabels.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let prompt = """
Detect ALL of the following items in this image and return their bounding boxes:
\(itemList)

Output a JSON list where each entry contains:
- "box_2d": bounding box as [y0, x0, y1, x1] normalized to 0-1000
- "label": the EXACT label from the list above

CRITICAL RULES:
- Each item MUST have its own DISTINCT bounding box at the correct location in the image.
- Do NOT return the same bounding box coordinates for multiple items.
- For footwear: the box should be at the BOTTOM of the image around the feet/shoes.
- For eyewear/glasses: the box should be around the eyes/face area.
- For watches: the box should be around the wrist.
- For hats/caps: the box should be at the TOP of the image around the head.
- For necklaces: the box should be around the neck/chest area.
- If you cannot find a specific item, do NOT include it in the response. Do NOT guess or return a box for a different region.
"""

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["inlineData": [
                            "mimeType": "image/jpeg",
                            "data": originalBase64
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

        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return [:]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[StyleMate] AllBBox: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return [:]
            }

            guard let responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = responseJson["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let textPart = parts.first(where: { $0["text"] != nil }),
                  let text = textPart["text"] as? String else {
                print("[StyleMate] AllBBox: bad response structure")
                return [:]
            }

            guard let items = parseSegmentationJSON(text) else {
                print("[StyleMate] AllBBox: JSON parse failed")
                return [:]
            }

            var result: [String: [Int]] = [:]
            for item in items {
                guard let label = item["label"] as? String else { continue }

                let box: [Int]?
                if let boxInts = item["box_2d"] as? [Int], boxInts.count == 4 {
                    box = boxInts
                } else if let boxDoubles = item["box_2d"] as? [Double], boxDoubles.count == 4 {
                    box = boxDoubles.map { Int($0) }
                } else {
                    box = nil
                }

                if let box = box {
                    let matchedLabel = itemLabels.first { requestedLabel in
                        label.lowercased().contains(requestedLabel.lowercased())
                        || requestedLabel.lowercased().contains(label.lowercased())
                    } ?? label
                    result[matchedLabel] = box
                    print("[StyleMate] AllBBox: \(matchedLabel) -> \(box)")
                }
            }

            print("[StyleMate] AllBBox: got \(result.count) boxes for \(itemLabels.count) items")
            return result

        } catch {
            print("[StyleMate] AllBBox: network error: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Gets a bounding box for a single small/peripheral item using hyper-specific spatial hints.
    /// Much more accurate than the batch call for footwear and accessories.
    private func getItemBoundingBoxFocused(
        originalBase64: String,
        product: String,
        category: Category,
        colors: [String],
        material: String?,
        details: String?
    ) async -> [Int]? {
        let colorDesc = colors.isEmpty ? "" : colors.joined(separator: " and ") + " "
        let materialDesc = (material ?? "").isEmpty ? "" : (material ?? "") + " "
        let detailDesc = (details ?? "").isEmpty ? "" : " with \(details!)"
        let itemDesc = "\(colorDesc)\(materialDesc)\(product)\(detailDesc)"

        let spatialHint: String
        switch category {
        case .footwear:
            spatialHint = """
This person is wearing \(itemDesc) on their feet. The shoes/footwear are located at the VERY BOTTOM of the image, on or near the ground level.
Return a bounding box that is in the LOWEST portion of the image, around the feet and shoes ONLY.
The top of the box should be around ankle height. The bottom of the box should be at or near the bottom edge of the image.
Do NOT include the legs, pants, or any clothing above the ankles.
"""
        case .accessories:
            switch product {
            case "Sunglasses", "Eyeglasses", "Reading Glasses":
                spatialHint = """
This person is wearing \(itemDesc) on their face. The glasses sit on the nose bridge across both eyes.
Return a bounding box that is a WIDE HORIZONTAL rectangle across the eye region of the face ONLY.
The box should be in the UPPER portion of the image (head area).
Do NOT include the phone, hands, hair, forehead, or chin. ONLY the glasses frames and lenses on the face.
"""
            case "Watches":
                spatialHint = """
This person is wearing a \(itemDesc) on their wrist. The watch has a dial/face and a strap wrapped around the wrist.
Return a bounding box tightly around the watch face and strap ONLY.
Look carefully at both wrists to find the watch. The watch is a small circular or square object on the wrist.
Do NOT include the phone, hand, fingers, or forearm. ONLY the watch itself.
"""
            case "Rings":
                spatialHint = """
This person is wearing a \(itemDesc) on their finger.
Return a bounding box tightly around the ring ONLY.
Do NOT include the entire hand or fingers. Just the ring.
"""
            case "Necklaces", "Pendants", "Chains":
                spatialHint = """
This person is wearing a \(itemDesc) around their neck.
Return a bounding box around the necklace/chain/pendant on the neck and upper chest area ONLY.
Do NOT include the full torso or face. Just the jewelry around the neck.
"""
            case "Earrings":
                spatialHint = """
This person is wearing \(itemDesc).
Return a bounding box around ONE earring near the ear ONLY.
Do NOT include the full face or head. Just the earring.
"""
            case "Bracelets", "Anklets":
                spatialHint = """
This person is wearing a \(itemDesc).
Return a bounding box tightly around the \(product) ONLY.
Do NOT include the arm or leg. Just the jewelry item.
"""
            case "Belts":
                spatialHint = """
This person is wearing a \(itemDesc) around their waist.
Return a bounding box around the belt at the waistline ONLY.
The belt is a narrow horizontal strip at the waist between the top and bottom garments.
Do NOT include the shirt or pants. Just the belt.
"""
            default:
                if ["Baseball Caps", "Beanies", "Fedoras", "Bucket Hats", "Sun Hats", "Visors", "Bandanas", "Turbans", "Headbands", "Berets"].contains(product) {
                    spatialHint = """
This person is wearing a \(itemDesc) on their head.
Return a bounding box around the hat/headwear at the TOP of the image ONLY.
The box should be in the uppermost portion of the image, around the head.
Do NOT include the face, body, or anything below the forehead.
"""
                } else if ["Handbags", "Tote Bags", "Crossbody Bags", "Backpacks", "Clutches", "Fanny Packs", "Briefcases", "Messenger Bags", "Wallets"].contains(product) {
                    spatialHint = """
This person is carrying a \(itemDesc).
Return a bounding box around the bag ONLY.
Do NOT include the person's body. Just the bag.
"""
                } else {
                    spatialHint = """
This person has a \(itemDesc).
Return a bounding box tightly around this specific accessory ONLY.
Do NOT include the person's body. Just the accessory item.
"""
                }
            }
        default:
            spatialHint = """
Find the \(itemDesc) in this image.
Return a bounding box tightly around this item ONLY.
"""
        }

        let prompt = """
\(spatialHint)
Output a JSON list with ONE entry containing the 2D bounding box in the key "box_2d" as [y0, x0, y1, x1] normalized to 0-1000, and the text label in the key "label".
If you absolutely cannot find this item in the image, return an empty JSON list [].
"""

        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        ["inlineData": [
                            "mimeType": "image/jpeg",
                            "data": originalBase64
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

        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
              let httpBody = try? JSONSerialization.data(withJSONObject: requestBody) else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[StyleMate] FocusedBBox: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(product)")
                return nil
            }

            guard let responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = responseJson["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let textPart = parts.first(where: { $0["text"] != nil }),
                  let text = textPart["text"] as? String else {
                print("[StyleMate] FocusedBBox: bad response for \(product)")
                return nil
            }

            guard let items = parseSegmentationJSON(text), let first = items.first else {
                print("[StyleMate] FocusedBBox: item not found or parse failed for \(product)")
                return nil
            }

            if let boxInts = first["box_2d"] as? [Int], boxInts.count == 4 {
                print("[StyleMate] FocusedBBox: success for \(product): \(boxInts)")
                return boxInts
            } else if let boxDoubles = first["box_2d"] as? [Double], boxDoubles.count == 4 {
                let boxInts = boxDoubles.map { Int($0) }
                print("[StyleMate] FocusedBBox: success for \(product): \(boxInts)")
                return boxInts
            }

            print("[StyleMate] FocusedBBox: no valid box for \(product)")
            return nil

        } catch {
            print("[StyleMate] FocusedBBox: network error for \(product): \(error.localizedDescription)")
            return nil
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

    private func extractGarment(from bgRemovedImage: UIImage, boxNormalized: [Int]) -> UIImage? {
        guard let cgImage = bgRemovedImage.cgImage else { return nil }
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

        let y0 = CGFloat(boxNormalized[0]) / 1000.0 * imgHeight
        let x0 = CGFloat(boxNormalized[1]) / 1000.0 * imgWidth
        let y1 = CGFloat(boxNormalized[2]) / 1000.0 * imgHeight
        let x1 = CGFloat(boxNormalized[3]) / 1000.0 * imgWidth

        let boxWidth = x1 - x0
        let boxHeight = y1 - y0
        guard boxWidth > 0, boxHeight > 0 else { return nil }

        let padX = boxWidth * 0.05
        let padY = boxHeight * 0.05

        let cropRect = CGRect(
            x: max(0, x0 - padX),
            y: max(0, y0 - padY),
            width: min(imgWidth - max(0, x0 - padX), boxWidth + padX * 2),
            height: min(imgHeight - max(0, y0 - padY), boxHeight + padY * 2)
        )

        guard !cropRect.isEmpty,
              let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let result = UIImage(cgImage: cropped, scale: bgRemovedImage.scale, orientation: bgRemovedImage.imageOrientation)
        return padToSquare(result)
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

    /// Renders the UIImage into a new context, applying the orientation transform.
    /// After this, cgImage.width/height matches the visual display dimensions.
    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return normalized
    }

    private func resizedForAPI(_ image: UIImage, maxDimension: CGFloat = 1024) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resized = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return resized
    }

    private func trimWhitespace(_ image: UIImage, threshold: UInt8 = 240) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return image }
        let data = pixelData.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, minY = height, maxX = 0, maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r = data[offset]
                let g = data[offset + 1]
                let b = data[offset + 2]
                let a = data[offset + 3]

                if a < 10 { continue }
                if r >= threshold && g >= threshold && b >= threshold { continue }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard minX < maxX, minY < maxY else { return image }

        let contentWidth = CGFloat(maxX - minX)
        let contentHeight = CGFloat(maxY - minY)
        let padX = contentWidth * 0.03
        let padY = contentHeight * 0.03

        let cropRect = CGRect(
            x: max(0, CGFloat(minX) - padX),
            y: max(0, CGFloat(minY) - padY),
            width: min(CGFloat(width) - max(0, CGFloat(minX) - padX), contentWidth + padX * 2),
            height: min(CGFloat(height) - max(0, CGFloat(minY) - padY), contentHeight + padY * 2)
        )

        guard !cropRect.isEmpty,
              let cropped = cgImage.cropping(to: cropRect) else { return image }

        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Classification Pipeline

    func analyzeMultiple(image: UIImage, userGender: String? = nil, imageIndex: Int? = nil, retryCount: Int = 0) async -> [ClassifiedItem] {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("[StyleMate] Failed to convert image to JPEG")
            return []
        }
        let base64Image = imageData.base64EncodedString()
        print("[StyleMate] Image encoded: \(imageData.count) bytes (attempt \(retryCount + 1))")

        let genderContext: String
        if let gender = userGender, !gender.isEmpty {
            genderContext = "\nThe user is \(gender). Use this to better identify garment types (e.g., distinguish men's kurta vs women's kurti, men's tank top vs camisole)."
        } else {
            genderContext = ""
        }

        let prompt = """
You are an expert fashion assistant. Analyze the clothing items worn by the person in this image.\(genderContext)

Valid categories: Tops, Bottoms, Mid-Layers, Outerwear, One-Pieces, Footwear, Accessories, Innerwear, Activewear, Ethnic Wear

Valid products per category:
- Tops: T-Shirts, Polo T-Shirts, Shirts, Button-Down Shirts, Flannel Shirts, Blouses, Henley, Tank Tops, Camisoles, Crop Tops, Tube Tops, Off-Shoulder Tops, Halter Tops, Bandeau, Peplum Tops, Corset Tops, Wrap Tops, Bustiers, Bodysuits, Graphic Tees, Mesh Tops, Turtlenecks, Tunics
- Bottoms: Jeans, Trousers, Chinos, Cargo Pants, Wide-Leg Pants, Palazzo Pants, Linen Pants, Sweatpants, Joggers, Leggings, Shorts, Capris, Culottes, Skirts, Mini Skirts, Skorts
- Mid-Layers: Hoodies, Sweatshirts, Sweaters, Cardigans, Pullovers, Fleece Jackets, Vests, Gilets, Quarter-Zips, Shrugs, Ponchos
- Outerwear: Jackets, Leather Jackets, Denim Jackets, Bomber Jackets, Puffer Jackets, Coats, Overcoats, Trench Coats, Blazers, Parkas, Windbreakers, Raincoats, Shirt Jackets, Capes
- One-Pieces: Dresses, Wrap Dresses, Maxi Dresses, Shirt Dresses, Gowns, Jumpsuits, Rompers, Playsuits, Dungarees, Overalls
- Footwear: Sneakers, Boots, Ankle Boots, Chelsea Boots, Sandals, Slides, Espadrilles, Loafers, Oxford Shoes, Formal Shoes, Mules, Flats, Heels, Platform Shoes, Clogs, Slippers
- Accessories: Sunglasses, Eyeglasses, Reading Glasses, Baseball Caps, Beanies, Fedoras, Bucket Hats, Sun Hats, Visors, Bandanas, Turbans, Headbands, Berets, Watches, Bracelets, Rings, Necklaces, Earrings, Pendants, Chains, Anklets, Cufflinks, Brooches, Scarves, Ties, Bowties, Gloves, Belts, Suspenders, Pocket Squares, Hair Accessories, Handbags, Tote Bags, Crossbody Bags, Backpacks, Wallets, Clutches, Fanny Packs, Briefcases, Messenger Bags
- Innerwear: Underwear, Boxers, Briefs, Undershirts, Bras, Bralettes, Thongs, Socks, Thermal Wear, Shapewear, Lingerie
- Activewear: Athletic Tops, Athletic Shorts, Running Shorts, Cycling Shorts, Track Pants, Active Jackets, Compression Wear, Rashguards, Sports Bras, Active Leggings, Yoga Pants, Swim Trunks, Swimwear, Tennis Dresses
- Ethnic Wear: Kurta, Sherwani, Nehru Jacket, Dhoti, Lungis, Mundu, Jodhpuri Suit, Pathani Suit, Bandhgala, Angrakha, Kurti, Saree, Blouse (saree), Lehenga, Choli, Dupatta, Salwar, Patiala Pants, Anarkali, Churidar, Palazzo Suit, Sharara, Ghagra

Valid patterns: Solid, Stripes, Checks, Plaid, Polka Dot, Floral, Animal Print, Camouflage, Geometric, Houndstooth, Paisley, Tie-Dye

Valid fits: Slim, Regular, Relaxed, Oversized, Cropped
Valid necklines: Crew Neck, V-Neck, Scoop Neck, Boat Neck, Turtleneck, Mock Neck, Henley, Collared, Hooded, Off-Shoulder, Square Neck, Halter, Strapless, Cowl Neck
Valid sleeve lengths: Sleeveless, Cap Sleeve, Short Sleeve, 3/4 Sleeve, Long Sleeve
Valid garment lengths: Cropped, Short, Knee-Length, Midi, Full-Length

For EACH visible clothing item, return:
- category: one of the valid categories above (exact string)
- product: one of the valid products above (exact string)
- colors: array of color names (MUST have at least one)
- pattern: one of the valid patterns above (exact string)
- material: the fabric/material (e.g. "Cotton", "Denim", "Wool Knit", "Leather", "Silk", "Linen", "Polyester", "Fleece", "Corduroy", "Velvet", "Satin", "Chiffon", "Jersey", "Mesh", "Canvas", "Tweed", "Suede", "Nylon"). Use your best judgment.
- fit: one of the valid fits above, or null if not applicable (footwear, accessories)
- neckline: one of the valid necklines above, or null if not applicable (bottoms, footwear, accessories)
- sleeveLength: one of the valid sleeve lengths above, or null if not applicable (bottoms, footwear, accessories, sleeveless dresses)
- garmentLength: one of the valid garment lengths above, or null if not applicable (tops, footwear, accessories)
- details: a short comma-separated string of distinctive visual features that make this specific item unique (e.g. "cable knit, ribbed cuffs", "distressed wash, raw hem", "front zip, logo on chest", "pleated, high-waisted", "patch pockets, contrast stitching"). Return "" if no notable details.

DEDUPLICATION RULES:
- Each distinct physical item should appear EXACTLY ONCE in your response.
- Do NOT detect the same item under multiple categories or product types.
- Paired items (two shoes, two earrings, two gloves) count as ONE item, not two.

CRITICAL RULES FOR ACCESSORIES:
- A watch is ALWAYS "Watches", never "Jewelry", "Bracelets", or "Rings". A watch has a dial/face and tells time.
- Prescription glasses and clear-lens glasses are "Eyeglasses", NOT "Sunglasses". Only classify as "Sunglasses" if the lenses are visibly tinted or dark.
- Do NOT return the same physical item twice under different product types. Each physical item in the image should appear exactly once.
- If someone wears a PAIR of earrings, return ONE entry for "Earrings", not two separate entries.
- If someone wears a PAIR of sunglasses or eyeglasses, return ONE entry, not two.
- Prefer the most specific product type available. Use "Rings" not "Jewelry" for a ring. Use "Baseball Caps" not "Hats" for a baseball cap. Use "Necklaces" not "Jewelry" for a necklace.
- For eyewear, ALWAYS include the frame shape in the details field (e.g., "aviator frame", "round frame, tortoiseshell", "wayfarer frame, mirrored lens", "cat eye frame", "rectangular frame, thin metal").
- For watches, ALWAYS include the face shape and strap type in details (e.g., "round face, leather strap", "square face, metal bracelet", "digital display, rubber strap", "round face, rose gold case, mesh strap").
- For headwear, ALWAYS include distinguishing style details (e.g., "flat brim, snapback closure", "ribbed knit, folded cuff", "wide brim, straw weave", "structured crown, grosgrain ribbon").

Return a JSON array of objects. Use EXACT strings from the lists above for enum fields.
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
                    "material": ["type": "string"],
                    "fit": ["type": "string"],
                    "neckline": ["type": "string"],
                    "sleeveLength": ["type": "string"],
                    "garmentLength": ["type": "string"],
                    "details": ["type": "string"]
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
                    return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1)
                }
                print("[StyleMate] Rate limited after all retries")
                return []
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[StyleMate] API error \(httpResponse.statusCode): \(errorBody.prefix(500))")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1)
                }
                return []
            }

            guard let responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[StyleMate] Response is not valid JSON: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "nil")")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount)
            }

            guard let candidates = responseJson["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                print("[StyleMate] Unexpected response structure: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount)
            }

            guard let textPart = parts.first(where: { $0["text"] != nil }),
                  let text = textPart["text"] as? String else {
                print("[StyleMate] No text part in response parts: \(parts)")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount)
            }

            print("[StyleMate] Response text: \(text.prefix(500))")

            guard let textData = text.data(using: .utf8),
                  let itemsArray = try? JSONSerialization.jsonObject(with: textData) as? [[String: Any]] else {
                print("[StyleMate] Failed to parse JSON array from response text")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount)
            }

            print("[StyleMate] Parsed \(itemsArray.count) raw items from API")

            var validResults: [ClassifiedItem] = []
            for (i, dict) in itemsArray.enumerated() {
                let catStr = (dict["category"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let prodStr = (dict["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let colorsArr = dict["colors"] as? [String] ?? []
                let patStr = (dict["pattern"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let category = matchCategory(catStr)
                let product = matchProduct(prodStr)
                let colors = colorsArr.map { matchColor($0) ?? $0 }.filter { !$0.isEmpty }
                let pattern = matchPattern(patStr)

                let materialStr = dict["material"] as? String
                let fitStr = (dict["fit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let necklineStr = (dict["neckline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let sleeveLengthStr = (dict["sleeveLength"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let garmentLengthStr = (dict["garmentLength"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let detailsStr = dict["details"] as? String

                let fitVal = matchFit(fitStr)
                let necklineVal = matchNeckline(necklineStr)
                let sleeveLengthVal = matchSleeveLength(sleeveLengthStr)
                let garmentLengthVal = matchGarmentLength(garmentLengthStr)

                if let category = category, let product = product, let pattern = pattern, !colors.isEmpty {
                    validResults.append(ClassifiedItem(
                        category: category,
                        product: product,
                        colors: colors,
                        pattern: pattern,
                        material: materialStr,
                        fit: fitVal,
                        neckline: necklineVal,
                        sleeveLength: sleeveLengthVal,
                        garmentLength: garmentLengthVal,
                        details: detailsStr
                    ))
                    print("[StyleMate] Item \(i): OK - \(category.rawValue) / \(product) / \(colors.joined(separator: ",")) / \(pattern.rawValue)")
                } else {
                    print("[StyleMate] Item \(i): SKIP - raw(cat=\(catStr ?? "nil"), prod=\(prodStr ?? "nil"), pat=\(patStr ?? "nil"), colors=\(colorsArr)) -> matched(cat=\(category?.rawValue ?? "nil"), prod=\(product ?? "nil"), pat=\(pattern?.rawValue ?? "nil"), colors=\(colors.count))")
                }
            }

            if validResults.isEmpty && !itemsArray.isEmpty && retryCount < 2 {
                print("[StyleMate] All \(itemsArray.count) items failed to parse, retrying...")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1)
            }

            print("[StyleMate] Returning \(validResults.count) valid items")
            return validResults

        } catch {
            print("[StyleMate] Network error: \(error.localizedDescription)")
            if retryCount < 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1)
            }
            return []
        }
    }

    private func retryOrEmpty(image: UIImage, userGender: String?, imageIndex: Int?, retryCount: Int) async -> [ClassifiedItem] {
        if retryCount < 2 {
            print("[StyleMate] Retrying (attempt \(retryCount + 2))...")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1)
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

    // MARK: - Fuzzy Matching for New Attributes

    func matchFit(_ raw: String?) -> Fit? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if let exact = Fit(rawValue: raw) { return exact }
        let lower = raw.lowercased()
        for f in Fit.allCases {
            if f.rawValue.lowercased() == lower { return f }
        }
        let normalized = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        for f in Fit.allCases {
            let fNorm = f.rawValue.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if fNorm == normalized || fNorm.contains(normalized) || normalized.contains(fNorm) { return f }
        }
        var bestScore = Int.max
        var bestFit: Fit? = nil
        for f in Fit.allCases {
            let score = Self.levenshtein(lower, f.rawValue.lowercased())
            if score < bestScore { bestScore = score; bestFit = f }
        }
        return bestScore <= 2 ? bestFit : nil
    }

    func matchNeckline(_ raw: String?) -> Neckline? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if let exact = Neckline(rawValue: raw) { return exact }
        let lower = raw.lowercased()
        for n in Neckline.allCases {
            if n.rawValue.lowercased() == lower { return n }
        }
        let normalized = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        for n in Neckline.allCases {
            let nNorm = n.rawValue.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if nNorm == normalized || nNorm.contains(normalized) || normalized.contains(nNorm) { return n }
        }
        var bestScore = Int.max
        var bestNeckline: Neckline? = nil
        for n in Neckline.allCases {
            let score = Self.levenshtein(lower, n.rawValue.lowercased())
            if score < bestScore { bestScore = score; bestNeckline = n }
        }
        return bestScore <= 3 ? bestNeckline : nil
    }

    func matchSleeveLength(_ raw: String?) -> SleeveLength? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if let exact = SleeveLength(rawValue: raw) { return exact }
        let lower = raw.lowercased()
        for s in SleeveLength.allCases {
            if s.rawValue.lowercased() == lower { return s }
        }
        let normalized = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "")
        for s in SleeveLength.allCases {
            let sNorm = s.rawValue.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "/", with: "")
            if sNorm == normalized || sNorm.contains(normalized) || normalized.contains(sNorm) { return s }
        }
        var bestScore = Int.max
        var bestSleeve: SleeveLength? = nil
        for s in SleeveLength.allCases {
            let score = Self.levenshtein(lower, s.rawValue.lowercased())
            if score < bestScore { bestScore = score; bestSleeve = s }
        }
        return bestScore <= 3 ? bestSleeve : nil
    }

    func matchGarmentLength(_ raw: String?) -> GarmentLength? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if let exact = GarmentLength(rawValue: raw) { return exact }
        let lower = raw.lowercased()
        for g in GarmentLength.allCases {
            if g.rawValue.lowercased() == lower { return g }
        }
        let normalized = lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        for g in GarmentLength.allCases {
            let gNorm = g.rawValue.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if gNorm == normalized || gNorm.contains(normalized) || normalized.contains(gNorm) { return g }
        }
        var bestScore = Int.max
        var bestLength: GarmentLength? = nil
        for g in GarmentLength.allCases {
            let score = Self.levenshtein(lower, g.rawValue.lowercased())
            if score < bestScore { bestScore = score; bestLength = g }
        }
        return bestScore <= 3 ? bestLength : nil
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
        let wardrobeSummary = wardrobe.enumerated().map { (idx, item) in
            var desc = "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
            if let m = item.material, !m.isEmpty { desc += ", Material: \(m)" }
            if let f = item.fit { desc += ", Fit: \(f.rawValue)" }
            if let n = item.neckline { desc += ", Neckline: \(n.rawValue)" }
            if let s = item.sleeveLength { desc += ", Sleeve: \(s.rawValue)" }
            if let g = item.garmentLength { desc += ", Length: \(g.rawValue)" }
            return desc
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
            var desc = "Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
            if let m = item.material, !m.isEmpty { desc += ", Material: \(m)" }
            if let f = item.fit { desc += ", Fit: \(f.rawValue)" }
            if let n = item.neckline { desc += ", Neckline: \(n.rawValue)" }
            return desc
        }.joined(separator: "\n")
        let availableSummary = availableItems.enumerated().map { (idx, item) in
            var desc = "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
            if let m = item.material, !m.isEmpty { desc += ", Material: \(m)" }
            if let f = item.fit { desc += ", Fit: \(f.rawValue)" }
            if let n = item.neckline { desc += ", Neckline: \(n.rawValue)" }
            return desc
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
        let outfitSummary = currentOutfit.items.map { item in
            var desc = "Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
            if let m = item.material, !m.isEmpty { desc += ", Material: \(m)" }
            if let f = item.fit { desc += ", Fit: \(f.rawValue)" }
            if let n = item.neckline { desc += ", Neckline: \(n.rawValue)" }
            return desc
        }.joined(separator: "\n")
        let availableSummary = availableItems.enumerated().map { (idx, item) in
            var desc = "\(idx+1). Category: \(item.category.rawValue), Product: \(item.product), Colors: \(item.colors.joined(separator: ", ")), Pattern: \(item.pattern.rawValue), Brand: \(item.brand)"
            if let m = item.material, !m.isEmpty { desc += ", Material: \(m)" }
            if let f = item.fit { desc += ", Fit: \(f.rawValue)" }
            if let n = item.neckline { desc += ", Neckline: \(n.rawValue)" }
            return desc
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