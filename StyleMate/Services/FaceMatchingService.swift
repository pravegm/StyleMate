import UIKit
import Vision
import CoreML
import Accelerate
import CoreImage

class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    private static let matchThreshold: Float = 0.40
    private static let minFaceQuality: Float = 0.35

    private var referenceEmbedding: [Float]?
    private var mlModel: MLModel?

    // MARK: - Match Result

    struct MatchResult {
        let isMatch: Bool
        let matchedFace: VNFaceObservation?
        let faceCount: Int
        let distance: Float?
    }

    // MARK: - Model Loading

    private func ensureModelLoaded() -> Bool {
        if mlModel != nil { return true }

        guard let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlpackage") else {
            print("[FaceMatch] ERROR: MobileFaceNet model not found in bundle")
            return false
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            mlModel = try MLModel(contentsOf: url, configuration: config)
            print("[FaceMatch] Model loaded successfully")
            return true
        } catch {
            print("[FaceMatch] ERROR: Failed to load model: \(error)")
            return false
        }
    }

    // MARK: - Load Selfie Reference

    func loadSelfieReference(forUser userId: String) -> Bool {
        let key = "selfieReferencePath_\(userId)"
        guard let path = UserDefaults.standard.string(forKey: key) else {
            print("[FaceMatch] ERROR: No selfie path stored for user \(userId)")
            return false
        }
        print("[FaceMatch] Loading selfie from: \(path)")

        guard let rawImage = UIImage(contentsOfFile: path) ?? loadFromDocuments(filename: path) else {
            print("[FaceMatch] ERROR: Could not load selfie image file")
            return false
        }

        let image = renderUpOrientation(rawImage)
        guard let cgImage = image.cgImage else {
            print("[FaceMatch] ERROR: Could not get CGImage from selfie")
            return false
        }

        guard let embedding = generateEmbeddingFromPhoto(cgImage, label: "selfie") else {
            print("[FaceMatch] ERROR: Could not generate embedding from selfie")
            return false
        }

        referenceEmbedding = embedding
        let sqNorm = embedding.reduce(0) { $0 + $1 * $1 }
        print("[FaceMatch] Reference embedding stored (\(embedding.count)-dim, L2²=\(String(format: "%.4f", sqNorm)))")
        return true
    }

    // MARK: - Find User in Photo

    func findUserInPhoto(_ cgImage: CGImage) -> MatchResult {
        guard let reference = referenceEmbedding else {
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        let faces = detectFaces(in: cgImage)
        if faces.isEmpty {
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        let qualityMap = detectFaceQualities(in: cgImage)

        var bestMatch: VNFaceObservation?
        var bestSimilarity: Float = -.infinity
        var allScores: [Float] = []

        for face in faces {
            let quality = qualityForFace(face, qualityMap: qualityMap)
            if quality < Self.minFaceQuality {
                allScores.append(-1)
                continue
            }

            guard let crop = cropFace(from: cgImage, bbox: face.boundingBox),
                  let embedding = generateEmbedding(for: crop) else {
                allScores.append(-999)
                continue
            }

            let similarity = dotProduct(reference, embedding)
            allScores.append(similarity)

            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestMatch = face
            }
        }

        let scoresStr = allScores.map { String(format: "%.3f", $0) }.joined(separator: ", ")

        if bestSimilarity >= Self.matchThreshold, let matchedFace = bestMatch {
            print("[FaceMatch] MATCH best=\(String(format: "%.3f", bestSimilarity)) all=[\(scoresStr)] faces=\(faces.count)")
            return MatchResult(isMatch: true, matchedFace: matchedFace, faceCount: faces.count, distance: bestSimilarity)
        }

        print("[FaceMatch] no match (\(faces.count) faces, best: \(String(format: "%.2f", bestSimilarity))) all=[\(scoresStr)]")
        return MatchResult(isMatch: false, matchedFace: nil, faceCount: faces.count, distance: bestSimilarity)
    }

    // MARK: - Person Isolation (Instance Mask)

    /// Extracts just the matched person from a multi-person photo using
    /// VNGeneratePersonInstanceMaskRequest. Returns a UIImage with only the
    /// matched person visible (transparent background), cropped to their extent.
    func isolateMatchedPerson(from cgImage: CGImage, matchResult: MatchResult) -> UIImage? {
        guard let face = matchResult.matchedFace else { return nil }

        let ciImage = CIImage(cgImage: cgImage)
        let handler = VNImageRequestHandler(ciImage: ciImage)

        let maskRequest = VNGeneratePersonInstanceMaskRequest()
        do {
            try handler.perform([maskRequest])
        } catch {
            print("[FaceMatch] Person instance mask failed: \(error)")
            return heuristicBodyCrop(face: face, cgImage: cgImage)
        }

        guard let maskObs = maskRequest.results?.first else {
            print("[FaceMatch] No person instance mask results")
            return heuristicBodyCrop(face: face, cgImage: cgImage)
        }

        let allInstances = maskObs.allInstances
        guard !allInstances.isEmpty else {
            print("[FaceMatch] Instance mask found no people")
            return heuristicBodyCrop(face: face, cgImage: cgImage)
        }

        if allInstances.count == 1 {
            return extractPerson(maskObs: maskObs, instances: allInstances, handler: handler, ciImage: ciImage)
        }

        // Map the matched face center to the correct person instance
        let faceCenterX = face.boundingBox.midX
        let faceCenterY = face.boundingBox.midY
        let faceCenter = CGPoint(x: faceCenterX, y: faceCenterY)

        do {
            let personIndex = try maskObs.instanceAtPoint(faceCenter)
            if personIndex != 0 {
                let personSet = IndexSet(integer: personIndex)
                print("[FaceMatch] Matched face -> person instance \(personIndex)")
                if let result = extractPerson(maskObs: maskObs, instances: personSet, handler: handler, ciImage: ciImage) {
                    return result
                }
            }
        } catch {
            print("[FaceMatch] instanceAtPoint failed: \(error)")
        }

        // Fallback: try each instance, pick the one whose mask covers the face center
        for idx in allInstances {
            do {
                let mask = try maskObs.generateMask(forInstances: IndexSet(integer: idx))
                let maskW = CVPixelBufferGetWidth(mask)
                let maskH = CVPixelBufferGetHeight(mask)
                let px = Int(faceCenterX * CGFloat(maskW))
                let py = Int((1.0 - faceCenterY) * CGFloat(maskH))

                CVPixelBufferLockBaseAddress(mask, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

                if let base = CVPixelBufferGetBaseAddress(mask) {
                    let rowBytes = CVPixelBufferGetBytesPerRow(mask)
                    let ptr = base.assumingMemoryBound(to: UInt8.self)
                    let clampedX = min(max(px, 0), maskW - 1)
                    let clampedY = min(max(py, 0), maskH - 1)
                    let val = ptr[clampedY * rowBytes + clampedX]
                    if val > 128 {
                        print("[FaceMatch] Face center covered by instance \(idx)")
                        let personSet = IndexSet(integer: idx)
                        if let result = extractPerson(maskObs: maskObs, instances: personSet, handler: handler, ciImage: ciImage) {
                            return result
                        }
                    }
                }
            } catch {
                continue
            }
        }

        print("[FaceMatch] Could not map face to any person instance, using heuristic crop")
        return heuristicBodyCrop(face: face, cgImage: cgImage)
    }

    private func extractPerson(maskObs: VNInstanceMaskObservation, instances: IndexSet,
                                handler: VNImageRequestHandler, ciImage: CIImage) -> UIImage? {
        do {
            let maskedBuffer = try maskObs.generateMaskedImage(
                ofInstances: instances,
                from: handler,
                croppedToInstancesExtent: true
            )
            let maskedCI = CIImage(cvPixelBuffer: maskedBuffer)
            let ctx = CIContext()
            guard let maskedCG = ctx.createCGImage(maskedCI, from: maskedCI.extent) else { return nil }
            print("[FaceMatch] Person isolated: \(maskedCG.width)x\(maskedCG.height)")
            return UIImage(cgImage: maskedCG)
        } catch {
            print("[FaceMatch] generateMaskedImage failed: \(error)")
            return nil
        }
    }

    // MARK: - Face Detection

    func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.5 }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Face Quality

    private func detectFaceQualities(in cgImage: CGImage) -> [CGRect: Float] {
        let request = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        var map: [CGRect: Float] = [:]
        for obs in request.results ?? [] {
            map[obs.boundingBox] = obs.faceCaptureQuality ?? 0
        }
        return map
    }

    private func qualityForFace(_ face: VNFaceObservation, qualityMap: [CGRect: Float]) -> Float {
        if let q = qualityMap[face.boundingBox] { return q }
        // Find closest match by IoU
        var bestQ: Float = 1.0
        var bestIoU: CGFloat = 0
        for (rect, q) in qualityMap {
            let intersection = face.boundingBox.intersection(rect)
            if !intersection.isNull {
                let iou = (intersection.width * intersection.height) /
                    (face.boundingBox.width * face.boundingBox.height + rect.width * rect.height - intersection.width * intersection.height)
                if iou > bestIoU { bestIoU = iou; bestQ = q }
            }
        }
        return bestIoU > 0.5 ? bestQ : 1.0
    }

    // MARK: - Face Crop (Padded BBox + Resize to 112x112)

    private func cropFace(from cgImage: CGImage, bbox: CGRect) -> CGImage? {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let x = bbox.origin.x * imgW
        let y = (1 - bbox.origin.y - bbox.height) * imgH
        let w = bbox.width * imgW
        let h = bbox.height * imgH

        let padding: CGFloat = 0.4
        let padX = w * padding
        let padY = h * padding

        let cropX = max(0, x - padX)
        let cropY = max(0, y - padY)
        let cropW = min(imgW - cropX, w + 2 * padX)
        let cropH = min(imgH - cropY, h + 2 * padY)

        guard cropW > 10, cropH > 10 else { return nil }
        guard let cropped = cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cropW, height: cropH)) else { return nil }

        let size = CGSize(width: 112, height: 112)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.cgImage
    }

    // MARK: - Embedding Generation

    private func generateEmbeddingFromPhoto(_ cgImage: CGImage, label: String) -> [Float]? {
        let faces = detectFaces(in: cgImage)
        print("[FaceMatch] [\(label)] Detected \(faces.count) face(s)")

        guard let bestFace = faces.first else {
            print("[FaceMatch] [\(label)] No face detected")
            return nil
        }

        guard let crop = cropFace(from: cgImage, bbox: bestFace.boundingBox) else {
            print("[FaceMatch] [\(label)] Face crop failed")
            return nil
        }

        return generateEmbedding(for: crop)
    }

    private func generateEmbedding(for faceCrop: CGImage) -> [Float]? {
        guard ensureModelLoaded(), let model = mlModel else {
            print("[FaceMatch] Model not available")
            return nil
        }

        guard let inputArray = createInputMultiArray(from: faceCrop) else {
            print("[FaceMatch] Failed to create ML input array")
            return nil
        }

        do {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
            let input = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)]
            )
            let output = try model.prediction(from: input)

            guard let outputFeature = firstMultiArrayOutput(from: output),
                  let multiArray = outputFeature.multiArrayValue else {
                print("[FaceMatch] No MLMultiArray in model output")
                return nil
            }

            let count = multiArray.count
            guard count >= 128 else {
                print("[FaceMatch] Unexpected embedding dimension: \(count)")
                return nil
            }

            let embeddingSize = min(count, 512)
            var embedding = [Float](repeating: 0, count: embeddingSize)
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: embeddingSize)
            for i in 0..<embeddingSize { embedding[i] = ptr[i] }

            var norm: Float = 0
            vDSP_svesq(embedding, 1, &norm, vDSP_Length(embeddingSize))
            norm = sqrt(norm)

            if norm > 0 {
                vDSP_vsdiv(embedding, 1, &norm, &embedding, 1, vDSP_Length(embeddingSize))
            }

            return embedding
        } catch {
            print("[FaceMatch] Model prediction failed: \(error)")
            return nil
        }
    }

    private func firstMultiArrayOutput(from output: MLFeatureProvider) -> MLFeatureValue? {
        for name in output.featureNames {
            if let value = output.featureValue(for: name), value.multiArrayValue != nil {
                return value
            }
        }
        return nil
    }

    /// Converts a 112x112 CGImage to [1, 3, 112, 112] Float32 MLMultiArray.
    /// Normalization: (pixel / 127.5) - 1.0, RGB channel order.
    private func createInputMultiArray(from cgImage: CGImage) -> MLMultiArray? {
        let size = 112
        let w = cgImage.width
        let h = cgImage.height
        let bpp = 4
        let bytesPerRow = w * bpp
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        ) else { return nil }

        let channelSize = size * size
        let arrPtr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * channelSize)

        for y in 0..<size {
            for x in 0..<size {
                let srcX = min(x * w / size, w - 1)
                let srcY = min(y * h / size, h - 1)
                let offset = srcY * bytesPerRow + srcX * bpp

                let r = Float(pixels[offset]) / 127.5 - 1.0
                let g = Float(pixels[offset + 1]) / 127.5 - 1.0
                let b = Float(pixels[offset + 2]) / 127.5 - 1.0

                let pixelIndex = y * size + x
                arrPtr[pixelIndex] = r
                arrPtr[channelSize + pixelIndex] = g
                arrPtr[2 * channelSize + pixelIndex] = b
            }
        }

        return array
    }

    // MARK: - Cosine Similarity

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    // MARK: - Helpers

    private func renderUpOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, image.cgImage != nil else { return image }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private func loadFromDocuments(filename: String) -> UIImage? {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docsDir.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Fallback body crop when instance mask is unavailable
    private func heuristicBodyCrop(face: VNFaceObservation, cgImage: CGImage) -> UIImage? {
        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)
        let bbox = face.boundingBox
        let faceX = bbox.origin.x * imageW
        let faceY = (1 - bbox.origin.y - bbox.height) * imageH
        let faceW = bbox.width * imageW
        let faceH = bbox.height * imageH

        let bodyWidth = faceW * 3.5
        let bodyHeight = faceH * 8.0
        let bodyCenterX = faceX + faceW / 2
        let bodyTop = max(0, faceY - faceH * 0.3)

        let cropX = max(0, bodyCenterX - bodyWidth / 2)
        let cropRect = CGRect(
            x: cropX, y: bodyTop,
            width: min(imageW - cropX, bodyWidth),
            height: min(imageH - bodyTop, bodyHeight)
        )

        guard cropRect.width >= 100, cropRect.height >= 100,
              let cropped = cgImage.cropping(to: cropRect) else { return nil }

        print("[FaceMatch] Body crop via heuristic: \(Int(cropRect.width))x\(Int(cropRect.height))")
        return UIImage(cgImage: cropped)
    }

    // MARK: - Backward-Compatible API

    /// Legacy body crop API - now delegates to isolateMatchedPerson
    func cropToUserBody(from cgImage: CGImage, matchResult: MatchResult) -> CGImage? {
        guard matchResult.faceCount > 1 else { return nil }
        return isolateMatchedPerson(from: cgImage, matchResult: matchResult)?.cgImage
    }

    func photoContainsAnyPerson(_ cgImage: CGImage) -> Bool {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).contains { $0.confidence > 0.5 }
    }

    // MARK: - Public State

    var hasReference: Bool { referenceEmbedding != nil }

    func clearReference() {
        referenceEmbedding = nil
        mlModel = nil
    }
}
