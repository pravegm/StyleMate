import UIKit
import Vision
import CoreML
import Accelerate

class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    // Cosine similarity threshold for MobileFaceNet 512-dim embeddings (BGR input).
    // With correct channel order: same person typically 0.4–0.8, different person < 0.2.
    // 0.3 balances recall vs precision for photo library scanning.
    private static let matchThreshold: Float = 0.3

    private var referenceEmbedding: [Float]?
    private var mlModel: MLModel?

    // MARK: - Model Loading

    private func ensureModelLoaded() -> Bool {
        if mlModel != nil { return true }

        guard let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: "mlmodelc")
                ?? findCompiledModel() else {
            print("[StyleMate] FaceMatch: MobileFaceNet.mlmodelc not found in bundle")
            return false
        }

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            mlModel = try MLModel(contentsOf: url, configuration: config)
            print("[StyleMate] FaceMatch: MobileFaceNet model loaded")
            return true
        } catch {
            print("[StyleMate] FaceMatch: Failed to load model: \(error.localizedDescription)")
            return false
        }
    }

    /// Search for compiled model variants that Xcode may produce from .mlpackage
    private func findCompiledModel() -> URL? {
        let bundle = Bundle.main
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = bundle.url(forResource: "MobileFaceNet", withExtension: ext) {
                return url
            }
        }
        return nil
    }

    // MARK: - Load Selfie Reference

    func loadSelfieReference(forUser userId: String) -> Bool {
        let key = "selfieReferencePath_\(userId)"
        guard let path = UserDefaults.standard.string(forKey: key) else {
            print("[StyleMate] FaceMatch: No selfie path found for user")
            return false
        }

        guard let rawImage = UIImage(contentsOfFile: path) ?? loadFromDocuments(filename: path) else {
            print("[StyleMate] FaceMatch: Could not load selfie image at path: \(path)")
            return false
        }

        let image = Self.normalizeOrientation(rawImage)
        print("[StyleMate] FaceMatch: Selfie loaded (\(Int(image.size.width))x\(Int(image.size.height)), orientation: \(rawImage.imageOrientation.rawValue) -> normalized)")

        guard let cgImage = image.cgImage else {
            print("[StyleMate] FaceMatch: Could not get CGImage from selfie")
            return false
        }

        let faceObservations = detectFaces(in: cgImage)
        print("[StyleMate] FaceMatch: Detected \(faceObservations.count) face(s) in selfie")

        guard let bestFace = faceObservations.first else {
            print("[StyleMate] FaceMatch: No face detected in selfie")
            return false
        }

        guard let faceCrop = cropFace(from: cgImage, observation: bestFace, padding: 0.2) else {
            print("[StyleMate] FaceMatch: Could not crop face from selfie")
            return false
        }

        print("[StyleMate] FaceMatch: Face crop size: \(faceCrop.width)x\(faceCrop.height)")

        guard let embedding = generateEmbedding(for: faceCrop) else {
            print("[StyleMate] FaceMatch: Could not generate embedding from selfie")
            return false
        }

        referenceEmbedding = embedding
        print("[StyleMate] FaceMatch: Selfie reference embedding stored (\(embedding.count)-dim, norm: \(String(format: "%.4f", embedding.reduce(0) { $0 + $1 * $1 })))")
        return true
    }

    /// Renders a UIImage into a new context with identity orientation,
    /// baking any rotation/mirroring into the actual pixel data.
    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let size = image.size
        UIGraphicsBeginImageContextWithOptions(size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return normalized ?? image
    }

    private func loadFromDocuments(filename: String) -> UIImage? {
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docsDir.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - Match Result

    struct MatchResult {
        let isMatch: Bool
        let matchedFace: VNFaceObservation?
        let faceCount: Int
        let distance: Float?
    }

    // MARK: - Check if Photo Contains the User

    func findUserInPhoto(_ cgImage: CGImage) -> MatchResult {
        guard let reference = referenceEmbedding else {
            let hasPerson = photoContainsAnyPerson(cgImage)
            return MatchResult(isMatch: hasPerson, matchedFace: nil, faceCount: hasPerson ? 1 : 0, distance: nil)
        }

        let faces = detectFaces(in: cgImage)
        if faces.isEmpty {
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        var bestMatch: VNFaceObservation?
        var bestSimilarity: Float = -.infinity
        var allScores: [Float] = []

        for face in faces {
            guard let faceCrop = cropFace(from: cgImage, observation: face, padding: 0.2),
                  let embedding = generateEmbedding(for: faceCrop) else { continue }

            let similarity = Self.cosineSimilarity(reference, embedding)
            allScores.append(similarity)

            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestMatch = face
            }
        }

        let scoresStr = allScores.map { String(format: "%.3f", $0) }.joined(separator: ", ")

        if bestSimilarity >= Self.matchThreshold, let matchedFace = bestMatch {
            print("[StyleMate] FaceMatch: MATCH (best: \(String(format: "%.3f", bestSimilarity)), all: [\(scoresStr)], \(faces.count) faces)")
            return MatchResult(isMatch: true, matchedFace: matchedFace, faceCount: faces.count, distance: bestSimilarity)
        }

        print("[StyleMate] FaceMatch: no match (all: [\(scoresStr)], \(faces.count) faces)")
        return MatchResult(isMatch: false, matchedFace: nil, faceCount: faces.count, distance: bestSimilarity)
    }

    // MARK: - Embedding Generation (MobileFaceNet via CoreML)

    /// Generates a 128-dimensional face embedding from a cropped face CGImage.
    private func generateEmbedding(for faceCrop: CGImage) -> [Float]? {
        guard ensureModelLoaded(), let model = mlModel else { return nil }

        guard let inputArray = createInputMultiArray(from: faceCrop, size: 112) else {
            print("[StyleMate] FaceMatch: Failed to create input array")
            return nil
        }

        do {
            let inputName = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
            let input = try MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(multiArray: inputArray)]
            )
            let output = try model.prediction(from: input)

            guard let outputFeature = firstMultiArrayFeature(from: output),
                  let multiArray = outputFeature.multiArrayValue else {
                print("[StyleMate] FaceMatch: No MLMultiArray in model output")
                return nil
            }

            let count = multiArray.count
            guard count >= 128 else {
                print("[StyleMate] FaceMatch: Unexpected embedding dimension: \(count)")
                return nil
            }

            // Extract floats (use only first 128 if model returns more)
            let embeddingSize = min(count, 512)
            var embedding = [Float](repeating: 0, count: embeddingSize)
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: embeddingSize)
            for i in 0..<embeddingSize {
                embedding[i] = ptr[i]
            }

            // L2-normalize the embedding
            var norm: Float = 0
            vDSP_svesq(embedding, 1, &norm, vDSP_Length(embeddingSize))
            norm = sqrt(norm)
            if norm > 0 {
                vDSP_vsdiv(embedding, 1, &norm, &embedding, 1, vDSP_Length(embeddingSize))
            }

            return embedding
        } catch {
            print("[StyleMate] FaceMatch: Model prediction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Extracts the first MLMultiArray feature from model output regardless of key name.
    private func firstMultiArrayFeature(from output: MLFeatureProvider) -> MLFeatureValue? {
        for name in output.featureNames {
            if let value = output.featureValue(for: name), value.multiArrayValue != nil {
                return value
            }
        }
        return nil
    }

    /// Resizes a face crop to 112x112, converts to CHW Float32 MLMultiArray
    /// with [-1, 1] normalization. InsightFace models expect BGR channel order.
    private func createInputMultiArray(from cgImage: CGImage, size: Int) -> MLMultiArray? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * size
        var pixelData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32) else {
            return nil
        }

        let channelSize = size * size
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * channelSize)

        // RGBA -> BGR CHW, normalized to [-1, 1]: (pixel / 127.5) - 1.0
        // InsightFace w600k_mbf was trained with OpenCV BGR convention
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * bytesPerPixel
                let r = Float(pixelData[offset]) / 127.5 - 1.0
                let g = Float(pixelData[offset + 1]) / 127.5 - 1.0
                let b = Float(pixelData[offset + 2]) / 127.5 - 1.0

                let pixelIndex = y * size + x
                ptr[pixelIndex] = b                     // B channel first
                ptr[channelSize + pixelIndex] = g       // G channel
                ptr[2 * channelSize + pixelIndex] = r   // R channel last
            }
        }

        return array
    }

    // MARK: - Cosine Similarity

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        // Vectors are already L2-normalized, so dot product = cosine similarity
        return dot
    }

    // MARK: - Crop to User's Body Region (Multi-Person Photos)

    func cropToUserBody(from cgImage: CGImage, matchResult: MatchResult) -> CGImage? {
        guard matchResult.faceCount > 1,
              let face = matchResult.matchedFace else {
            return nil
        }

        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)

        if let bodyRect = findBodyForFace(face, in: cgImage) {
            let cropX = bodyRect.origin.x * imageW
            let cropY = (1 - bodyRect.origin.y - bodyRect.height) * imageH
            let cropW = bodyRect.width * imageW
            let cropH = bodyRect.height * imageH

            let padX = cropW * 0.1
            let padY = cropH * 0.05
            let finalX = max(0, cropX - padX)
            let finalY = max(0, cropY - padY)
            let cropRect = CGRect(
                x: finalX,
                y: finalY,
                width: min(imageW - finalX, cropW + 2 * padX),
                height: min(imageH - finalY, cropH + padY)
            )

            guard cropRect.width >= 200, cropRect.height >= 200 else {
                return heuristicBodyCrop(face: face, imageW: imageW, imageH: imageH, cgImage: cgImage)
            }

            print("[StyleMate] FaceMatch: Cropped via body detection: \(Int(cropRect.width))x\(Int(cropRect.height))")
            return cgImage.cropping(to: cropRect)
        }

        return heuristicBodyCrop(face: face, imageW: imageW, imageH: imageH, cgImage: cgImage)
    }

    private func findBodyForFace(_ face: VNFaceObservation, in cgImage: CGImage) -> CGRect? {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let bodies = request.results, !bodies.isEmpty else { return nil }

        let faceMidX = face.boundingBox.midX
        let faceMidY = face.boundingBox.midY

        var bestBody: CGRect?
        var bestOverlap: CGFloat = -1

        for body in bodies where body.confidence > 0.5 {
            let bodyBox = body.boundingBox
            if bodyBox.contains(CGPoint(x: faceMidX, y: faceMidY)) {
                let overlap = face.boundingBox.intersection(bodyBox).width * face.boundingBox.intersection(bodyBox).height
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestBody = bodyBox
                }
            }
        }

        return bestBody
    }

    private func heuristicBodyCrop(face: VNFaceObservation, imageW: CGFloat, imageH: CGFloat, cgImage: CGImage) -> CGImage? {
        let bbox = face.boundingBox
        let faceX = bbox.origin.x * imageW
        let faceY = (1 - bbox.origin.y - bbox.height) * imageH
        let faceW = bbox.width * imageW
        let faceH = bbox.height * imageH

        let bodyWidth = faceW * 3.0
        let bodyHeight = faceH * 7.5
        let bodyCenterX = faceX + faceW / 2
        let bodyTop = max(0, faceY - faceH * 0.3)

        let cropX = max(0, bodyCenterX - bodyWidth / 2)
        let cropRect = CGRect(
            x: cropX,
            y: bodyTop,
            width: min(imageW - cropX, bodyWidth),
            height: min(imageH - bodyTop, bodyHeight)
        )

        guard cropRect.width >= 200, cropRect.height >= 200 else {
            return nil
        }

        print("[StyleMate] FaceMatch: Cropped via heuristic fallback: \(Int(cropRect.width))x\(Int(cropRect.height))")
        return cgImage.cropping(to: cropRect)
    }

    var hasReference: Bool { referenceEmbedding != nil }

    func clearReference() {
        referenceEmbedding = nil
        mlModel = nil
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

    // MARK: - Face Cropping

    func cropFace(from cgImage: CGImage, observation: VNFaceObservation, padding: CGFloat) -> CGImage? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        let bbox = observation.boundingBox
        let x = bbox.origin.x * imageWidth
        let y = (1 - bbox.origin.y - bbox.height) * imageHeight
        let w = bbox.width * imageWidth
        let h = bbox.height * imageHeight

        let padX = w * padding
        let padY = h * padding

        let cropX = max(0, x - padX)
        let cropY = max(0, y - padY)
        let cropRect = CGRect(
            x: cropX,
            y: cropY,
            width: min(imageWidth - cropX, w + 2 * padX),
            height: min(imageHeight - cropY, h + 2 * padY)
        )

        return cgImage.cropping(to: cropRect)
    }

    // MARK: - Fallback: Any Person Detection

    func photoContainsAnyPerson(_ cgImage: CGImage) -> Bool {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).contains { $0.confidence > 0.5 }
    }
}
