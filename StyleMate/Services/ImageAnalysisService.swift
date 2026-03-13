import Foundation
import UIKit
import Vision

class ImageAnalysisService {
    static let shared = ImageAnalysisService()
    private init() {}
    
    private let geminiAPIKey = Secrets.geminiAPIKey
    private let geminiEndpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key="
    private var geminiProEndpoint: String {
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key="
    }
    
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
        let brand: String
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
        let brand: String
        let maskImage: UIImage?
    }

    // MARK: - Photo Mode Detection

    enum PhotoMode {
        case wornOnPerson
        case productPhoto
    }

    private func detectPhotoMode(_ image: UIImage) async -> PhotoMode {
        guard let cgImage = image.cgImage else { return .productPhoto }

        return await withCheckedContinuation { continuation in
            let request = VNDetectHumanRectanglesRequest { request, error in
                if let results = request.results as? [VNHumanObservation],
                   !results.isEmpty {
                    continuation.resume(returning: .wornOnPerson)
                } else {
                    continuation.resume(returning: .productPhoto)
                }
            }
            request.upperBodyOnly = false

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[StyleMate] Person detection failed: \(error.localizedDescription)")
                continuation.resume(returning: .productPhoto)
            }
        }
    }

    // MARK: - Segmentation Pipeline

    func analyzeAndSegment(image: UIImage, userGender: String? = nil, retryCount: Int = 0) async -> [SegmentedItem] {
        let normalizedImage = normalizeOrientation(image)

        let photoMode = await detectPhotoMode(normalizedImage)
        print("[StyleMate] Segmentation: Photo mode = \(photoMode)")

        switch photoMode {
        case .wornOnPerson:
            return await analyzeWornOnPerson(normalizedImage: normalizedImage, userGender: userGender)
        case .productPhoto:
            return await analyzeProductPhoto(normalizedImage: normalizedImage, userGender: userGender)
        }
    }

    private func analyzeWornOnPerson(normalizedImage: UIImage, userGender: String?) async -> [SegmentedItem] {
        let classifications = await analyzeMultiple(image: normalizedImage, userGender: userGender)

        guard !classifications.isEmpty else {
            print("[StyleMate] Segmentation: No items classified, returning empty")
            return []
        }

        print("[StyleMate] Segmentation: Pass 1 classified \(classifications.count) items")

        let bgRemovedRaw = await BackgroundRemovalService.shared.removeBackground(from: normalizedImage) ?? normalizedImage
        let bgRemoved = trimWhitespace(bgRemovedRaw)
        print("[StyleMate] Segmentation: BG removed and trimmed: \(Int(bgRemovedRaw.size.width))x\(Int(bgRemovedRaw.size.height)) -> \(Int(bgRemoved.size.width))x\(Int(bgRemoved.size.height))")

        let originalForBBox = resizedForAPI(normalizedImage, maxDimension: 1536)
        guard let originalData = originalForBBox.jpegData(compressionQuality: 0.8) else { return [] }
        let originalBase64 = originalData.base64EncodedString()
        print("[StyleMate] Segmentation: Original image for bboxes: \(originalData.count) bytes, \(Int(originalForBBox.size.width))x\(Int(originalForBBox.size.height))")

        let validItems = classifications.filter { $0.category != nil && $0.product != nil && $0.pattern != nil && !$0.colors.isEmpty }

        let clothingCategories: Set<Category> = [.tops, .bottoms, .midLayers, .outerwear, .onePieces, .activewear, .ethnicWear, .innerwear]
        let clothingItems = validItems.filter { clothingCategories.contains($0.category!) }
        let smallItems = validItems.filter { !clothingCategories.contains($0.category!) }

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

        var results: [SegmentedItem] = []
        for item in validItems {
            guard let category = item.category, let product = item.product,
                  let pattern = item.pattern else { continue }

            let label = "\(product) (\(category.rawValue))"
            var garmentImage: UIImage?

            if let box = allBoxes[label] {
                print("[StyleMate] Segmentation: Applying box \(box) for \(label) to bgRemovedRaw \(Int(bgRemovedRaw.size.width))x\(Int(bgRemovedRaw.size.height))")
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
                brand: item.brand,
                maskImage: garmentImage
            ))
        }

        print("[StyleMate] Segmentation: Returning \(results.count) items")
        return results
    }

    private func analyzeProductPhoto(normalizedImage: UIImage, userGender: String?) async -> [SegmentedItem] {
        let classifications = await analyzeMultiple(image: normalizedImage, userGender: userGender, isProductPhoto: true)
        guard !classifications.isEmpty else {
            print("[StyleMate] ProductPhoto: No items classified, returning empty")
            return []
        }

        print("[StyleMate] ProductPhoto: Classified \(classifications.count) items")

        let trimmed = trimWhitespace(normalizedImage)

        if classifications.count == 1, let item = classifications.first,
           let category = item.category, let product = item.product,
           let pattern = item.pattern, !item.colors.isEmpty {
            let finalImage = padToSquare(trimmed)
            return [SegmentedItem(
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
                brand: item.brand,
                maskImage: finalImage
            )]
        }

        let validItems = classifications.filter { $0.category != nil && $0.product != nil && $0.pattern != nil && !$0.colors.isEmpty }
        let resizedForBBox = resizedForAPI(normalizedImage, maxDimension: 1536)
        guard let bboxData = resizedForBBox.jpegData(compressionQuality: 0.8) else { return [] }
        let bboxBase64 = bboxData.base64EncodedString()

        let labels = validItems.map { "\($0.product!) (\($0.category!.rawValue))" }
        let boxes = await getAllBoundingBoxes(originalBase64: bboxBase64, itemLabels: labels)

        var results: [SegmentedItem] = []
        for item in validItems {
            guard let category = item.category, let product = item.product,
                  let pattern = item.pattern else { continue }
            let label = "\(product) (\(category.rawValue))"
            var garmentImage: UIImage?

            if let box = boxes[label] {
                garmentImage = extractGarment(from: normalizedImage, boxNormalized: box)
            }

            if garmentImage == nil {
                garmentImage = padToSquare(trimmed)
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
                brand: item.brand,
                maskImage: garmentImage
            ))
        }

        print("[StyleMate] ProductPhoto: Returning \(results.count) items")
        return results
    }

    /// Gets bounding boxes for ALL classified items in a single Gemini call using the original image.
    private func getAllBoundingBoxes(
        originalBase64: String,
        itemLabels: [String]
    ) async -> [String: [Int]] {
        let itemList = itemLabels.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")

        let prompt = """
Detect the 2D bounding boxes of the following clothing items in this image:
\(itemList)

The box_2d should be [ymin, xmin, ymax, xmax] normalized to 0-1000.

Output a JSON list where each entry contains:
- "box_2d": bounding box as [ymin, xmin, ymax, xmax] normalized to 0-1000
- "label": the EXACT label from the list above

RULES:
- Each item MUST have its own DISTINCT bounding box at the correct location.
- Do NOT return the same coordinates for multiple items.
- If you cannot find a specific item, do NOT include it. Do NOT guess.
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
Detect the 2D bounding box of ONLY this specific item. The box_2d should be [ymin, xmin, ymax, xmax] normalized to 0-1000.
Output a JSON list with exactly ONE entry: [{"box_2d": [ymin, xmin, ymax, xmax], "label": "ITEM_NAME"}]
If you absolutely cannot find this item, return an empty list: []
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
                    "thinkingBudget": 128
                ]
            ]
        ]

        guard let url = URL(string: geminiProEndpoint + geminiAPIKey),
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

        print("[StyleMate] extractGarment: UIImage size=\(Int(bgRemovedImage.size.width))x\(Int(bgRemovedImage.size.height)), scale=\(bgRemovedImage.scale), orientation=\(bgRemovedImage.imageOrientation.rawValue)")
        print("[StyleMate] extractGarment: CGImage width=\(cgImage.width), height=\(cgImage.height)")
        print("[StyleMate] extractGarment: box=\(boxNormalized)")

        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

        let y0 = CGFloat(boxNormalized[0]) / 1000.0 * imgHeight
        let x0 = CGFloat(boxNormalized[1]) / 1000.0 * imgWidth
        let y1 = CGFloat(boxNormalized[2]) / 1000.0 * imgHeight
        let x1 = CGFloat(boxNormalized[3]) / 1000.0 * imgWidth

        print("[StyleMate] extractGarment: mapped to pixels x0=\(Int(x0)), y0=\(Int(y0)), x1=\(Int(x1)), y1=\(Int(y1)) in \(Int(imgWidth))x\(Int(imgHeight)) image")

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

    func analyzeMultiple(image: UIImage, userGender: String? = nil, imageIndex: Int? = nil, retryCount: Int = 0, isProductPhoto: Bool = false) async -> [ClassifiedItem] {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("[StyleMate] Failed to convert image to JPEG")
            return []
        }
        let base64Image = imageData.base64EncodedString()
        print("[StyleMate] Image encoded: \(imageData.count) bytes (attempt \(retryCount + 1))")

        let genderContext: String
        if isProductPhoto {
            genderContext = ""
        } else if let gender = userGender, !gender.isEmpty {
            genderContext = "\nThe user is \(gender). Use this to better identify garment types (e.g., distinguish men's kurta vs women's kurti, men's tank top vs camisole)."
        } else {
            genderContext = ""
        }

        let openingLine = isProductPhoto
            ? "You are an expert fashion assistant. Analyze the clothing items visible in this product/flat-lay photo. The items are NOT being worn by a person — they may be laid flat, hung on a rack, displayed on a mannequin, or shown as an e-commerce product shot."
            : "You are an expert fashion assistant. Analyze the clothing items worn by the person in this image."

        let prompt = """
\(openingLine)\(genderContext)

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
- brand: If a brand logo, wordmark, or brand name is CLEARLY visible on the garment (e.g. Nike swoosh, Adidas three stripes, visible text like "ZARA", "H&M", a Ralph Lauren polo horse, Lacoste crocodile), return the brand name as a string. If no brand is clearly identifiable, return "". Do NOT guess the brand from the style or cut alone — only return a brand if you can actually SEE a logo, wordmark, emblem, or brand text on the item.

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
                    "details": ["type": "string"],
                    "brand": ["type": "string"]
                ],
                "required": ["category", "product", "colors", "pattern", "brand"]
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
                    return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1, isProductPhoto: isProductPhoto)
                }
                print("[StyleMate] Rate limited after all retries")
                return []
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "no body"
                print("[StyleMate] API error \(httpResponse.statusCode): \(errorBody.prefix(500))")
                if retryCount < 2 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1, isProductPhoto: isProductPhoto)
                }
                return []
            }

            guard let responseJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[StyleMate] Response is not valid JSON: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "nil")")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount, isProductPhoto: isProductPhoto)
            }

            guard let candidates = responseJson["candidates"] as? [[String: Any]],
                  let firstCandidate = candidates.first,
                  let content = firstCandidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                print("[StyleMate] Unexpected response structure: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "nil")")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount, isProductPhoto: isProductPhoto)
            }

            guard let textPart = parts.first(where: { $0["text"] != nil }),
                  let text = textPart["text"] as? String else {
                print("[StyleMate] No text part in response parts: \(parts)")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount, isProductPhoto: isProductPhoto)
            }

            print("[StyleMate] Response text: \(text.prefix(500))")

            guard let textData = text.data(using: .utf8),
                  let itemsArray = try? JSONSerialization.jsonObject(with: textData) as? [[String: Any]] else {
                print("[StyleMate] Failed to parse JSON array from response text")
                return await retryOrEmpty(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount, isProductPhoto: isProductPhoto)
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
                let brandStr = (dict["brand"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
                        details: detailsStr,
                        brand: brandStr
                    ))
                    print("[StyleMate] Item \(i): OK - \(category.rawValue) / \(product) / \(colors.joined(separator: ",")) / \(pattern.rawValue)")
                } else {
                    print("[StyleMate] Item \(i): SKIP - raw(cat=\(catStr ?? "nil"), prod=\(prodStr ?? "nil"), pat=\(patStr ?? "nil"), colors=\(colorsArr)) -> matched(cat=\(category?.rawValue ?? "nil"), prod=\(product ?? "nil"), pat=\(pattern?.rawValue ?? "nil"), colors=\(colors.count))")
                }
            }

            if validResults.isEmpty && !itemsArray.isEmpty && retryCount < 2 {
                print("[StyleMate] All \(itemsArray.count) items failed to parse, retrying...")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1, isProductPhoto: isProductPhoto)
            }

            print("[StyleMate] Returning \(validResults.count) valid items")
            return validResults

        } catch {
            print("[StyleMate] Network error: \(error.localizedDescription)")
            if retryCount < 2 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1, isProductPhoto: isProductPhoto)
            }
            return []
        }
    }

    private func retryOrEmpty(image: UIImage, userGender: String?, imageIndex: Int?, retryCount: Int, isProductPhoto: Bool = false) async -> [ClassifiedItem] {
        if retryCount < 2 {
            print("[StyleMate] Retrying (attempt \(retryCount + 2))...")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return await analyzeMultiple(image: image, userGender: userGender, imageIndex: imageIndex, retryCount: retryCount + 1, isProductPhoto: isProductPhoto)
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

    func suggestOutfitBatch(from wardrobe: [WardrobeItem], outfitType: OutfitType? = nil, customDescription: String? = nil, weather: Weather? = nil, user: User? = nil, retryCount: Int = 0) async -> Result<[SuggestedOutfit], OutfitSuggestError> {
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
        if let custom = customDescription, !custom.isEmpty {
            typeInstruction = """
            PRIORITY INSTRUCTION: The user has specifically described what they need: "\(custom)"
            This is the MOST IMPORTANT context for your suggestions. Every outfit must be appropriate for this specific scenario. Interpret the user's words carefully:
            - If they mention a place (e.g., "beach", "office", "wedding"), dress for that venue's dress code.
            - If they mention an activity (e.g., "hiking", "dinner", "interview"), dress for that activity's requirements.
            - If they mention a mood or style (e.g., "edgy", "cozy", "minimalist"), reflect that aesthetic.
            - If they mention weather or season (e.g., "cold evening", "summer"), layer accordingly even if it contradicts the current weather data.
            - If they mention people or formality (e.g., "meeting parents", "casual hangout"), match the social formality.
            All 5 outfit suggestions must directly serve this description. Do not suggest generic everyday outfits that ignore what the user typed.
            """
        } else if let outfitType = outfitType {
            typeInstruction = "The user wants an outfit for: \(outfitType.rawValue). Tailor suggestions for this context."
        } else if let user = user {
            let styles = user.preferredStyles.map { $0.rawValue }.joined(separator: ", ")
            typeInstruction = "The user prefers these styles: \(styles). Suggest outfits that fit one of these styles."
        } else {
            typeInstruction = "The user wants an everyday casual outfit."
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

        let weatherInstruction: String
        if let weather = weather {
            let temp = Int(weather.temperature2m)
            let desc = WeatherService.weatherDescription(for: weather.weathercode)
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

        let prompt = """
You are an expert fashion stylist creating outfits from a real person's wardrobe. Each item is identified by an index number in square brackets. You MUST reference items ONLY by their index number.

WARDROBE:
\(wardrobeSummary)
\(categoryIsolationNote)

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

VARIETY:
- Each of the 5 outfits must be meaningfully different from the others: different color palette, different vibe, or different key pieces.
- Try to use a wide range of the wardrobe. Don't reuse the same item in more than 2 outfits.
- If the wardrobe supports it, vary the style across outfits (one casual, one smart casual, etc.) unless the user specified a single occasion.

OUTPUT FORMAT:
Return a JSON array of 5 outfit objects. Each object has:
- "items": array of integer indices referencing the wardrobe items above (e.g., [0, 5, 12, 23])
- "explanation": a 1-2 sentence explanation of why this outfit works. MUST include:
  * The color or styling principle used (e.g., "monochromatic navy", "earth-tone layers", "complementary contrast").
  * A reference to the weather/location context if weather was provided (e.g., "Light layers perfect for the 22°C mild afternoon in London", "Cozy wool layers to handle the 5°C chill in Delhi").
  * A reference to the occasion/vibe if one was specified (e.g., "polished enough for a date night", "relaxed for an everyday weekend").
  Keep it conversational, specific, and useful. The user should feel that the AI understood their situation.

Return ONLY the JSON array. Example format:
[
  {"items": [0, 5, 12], "explanation": "Monochromatic navy palette with textural contrast — light cotton layers ideal for the 20°C afternoon in Mumbai..."},
  {"items": [3, 7, 15, 22], "explanation": "Earth-tone layers built around the olive chinos, perfect for a relaxed weekend outing..."}
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
                "responseSchema": responseSchema
            ]
        ]

        guard let url = URL(string: geminiEndpoint + geminiAPIKey),
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
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, retryCount: retryCount + 1)
                }
                print("[StyleMate] suggestOutfitBatch: rate limited after all retries")
                return .failure(.rateLimited)
            }

            guard httpResponse.statusCode == 200 else {
                print("[StyleMate] suggestOutfitBatch: HTTP \(httpResponse.statusCode)")
                if retryCount < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, retryCount: retryCount + 1)
                }
                return .failure(.networkError)
            }

            guard let result = try? JSONDecoder().decode(GeminiResponse.self, from: data),
                  let text = result.candidates.first?.content.parts.first?.text,
                  let arrData = text.data(using: .utf8) else {
                print("[StyleMate] suggestOutfitBatch: failed to extract text from response")
                if retryCount < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, retryCount: retryCount + 1)
                }
                return .failure(.parseError)
            }

            guard let outfits = try? JSONDecoder().decode([SuggestedOutfit].self, from: arrData) else {
                print("[StyleMate] suggestOutfitBatch: JSON decode failed for SuggestedOutfit array")
                if retryCount < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, retryCount: retryCount + 1)
                }
                return .failure(.parseError)
            }

            print("[StyleMate] suggestOutfitBatch: decoded \(outfits.count) outfits")
            return .success(outfits)

        } catch {
            print("[StyleMate] suggestOutfitBatch: network error: \(error.localizedDescription)")
            if retryCount < 1 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await suggestOutfitBatch(from: wardrobe, outfitType: outfitType, customDescription: customDescription, weather: weather, user: user, retryCount: retryCount + 1)
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

        let prompt = """
You are an expert fashion stylist. Replace one item in an outfit while maintaining harmony.

CURRENT OUTFIT:
\(outfitSummary)

ITEM TO REPLACE: The \(categoryToShuffle.rawValue) item.

AVAILABLE REPLACEMENTS:
\(availableSummary)

\(genderInstruction)

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
                "responseSchema": responseSchema
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

        let prompt = """
You are an expert fashion stylist. Add one item to an existing outfit.

CURRENT OUTFIT:
\(outfitSummary)

AVAILABLE \(productType.uppercased()) OPTIONS:
\(availableSummary)

\(genderInstruction)

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
                "responseSchema": responseSchema
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