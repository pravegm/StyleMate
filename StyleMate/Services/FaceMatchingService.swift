import UIKit
import Vision
import CoreML
import Accelerate

class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    // With ArcFace-aligned crops + RGB input, same-person cosine
    // similarity is typically 0.5–0.8 and different-person < 0.25.
    private static let matchThreshold: Float = 0.5

    private var referenceEmbedding: [Float]?
    private var mlModel: MLModel?

    // InsightFace canonical 5-point destination for 112x112 alignment.
    // Source: insightface/utils/face_align.py `arcface_dst`.
    private static let arcfaceDst: [(x: CGFloat, y: CGFloat)] = [
        (38.2946, 51.6963),   // left eye
        (73.5318, 51.5014),   // right eye
        (56.0252, 71.7366),   // nose tip
        (41.5493, 92.3655),   // left mouth corner
        (70.7299, 92.2041)    // right mouth corner
    ]

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

    private func findCompiledModel() -> URL? {
        for ext in ["mlmodelc", "mlpackage"] {
            if let url = Bundle.main.url(forResource: "MobileFaceNet", withExtension: ext) {
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

        let faceObservations = detectFacesWithLandmarks(in: cgImage)
        print("[StyleMate] FaceMatch: Detected \(faceObservations.count) face(s) in selfie")

        guard let bestFace = faceObservations.first else {
            print("[StyleMate] FaceMatch: No face detected in selfie")
            return false
        }

        guard let aligned = alignedFaceCrop(from: cgImage, observation: bestFace) else {
            print("[StyleMate] FaceMatch: Could not produce aligned face crop from selfie")
            return false
        }

        print("[StyleMate] FaceMatch: Aligned face crop: \(aligned.width)x\(aligned.height)")

        guard let embedding = generateEmbedding(for: aligned) else {
            print("[StyleMate] FaceMatch: Could not generate embedding from selfie")
            return false
        }

        referenceEmbedding = embedding
        let sqNorm = embedding.reduce(0) { $0 + $1 * $1 }
        print("[StyleMate] FaceMatch: Selfie reference embedding stored (\(embedding.count)-dim, L2 norm²: \(String(format: "%.4f", sqNorm)) -- should be ~1.0)")
        return true
    }

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
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
            print("[StyleMate] FaceMatch: WARNING - no reference embedding, cannot match. Rejecting photo.")
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        let faces = detectFacesWithLandmarks(in: cgImage)
        if faces.isEmpty {
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        var bestMatch: VNFaceObservation?
        var bestSimilarity: Float = -.infinity
        var allScores: [Float] = []

        for face in faces {
            guard let aligned = alignedFaceCrop(from: cgImage, observation: face),
                  let embedding = generateEmbedding(for: aligned) else { continue }

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

    // MARK: - Face Detection with Landmarks

    func detectFacesWithLandmarks(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.5 }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - ArcFace-Aligned Face Crop

    /// Produces an aligned 112x112 face crop. Uses a similarity transform
    /// when landmarks are available, falls back to bbox crop + resize otherwise.
    func alignedFaceCrop(from cgImage: CGImage, observation: VNFaceObservation) -> CGImage? {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        if let landmarks = observation.landmarks,
           let srcPoints = extractFiveKeypoints(landmarks: landmarks,
                                                 boundingBox: observation.boundingBox,
                                                 imageWidth: imgW, imageHeight: imgH) {
            if let aligned = warpAffineAligned(image: cgImage, srcPoints: srcPoints, outputSize: 112) {
                return aligned
            }
        }

        // Fallback: simple bbox crop resized to 112x112
        return bboxCropResized(from: cgImage, observation: observation, outputSize: 112)
    }

    // MARK: - Landmark Extraction

    /// Extracts the 5 keypoints needed for ArcFace alignment in **pixel coordinates**.
    ///
    /// Vision landmark points are normalized (0..1) relative to the face
    /// bounding box, with origin at bottom-left. We convert them to full-image
    /// pixel coordinates with origin at top-left (CGImage convention).
    private func extractFiveKeypoints(
        landmarks: VNFaceLandmarks2D,
        boundingBox: CGRect,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [(x: CGFloat, y: CGFloat)]? {
        guard let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye,
              let nose = landmarks.nose,
              let outerLips = landmarks.outerLips else {
            return nil
        }

        guard leftEye.pointCount >= 1,
              rightEye.pointCount >= 1,
              nose.pointCount >= 1,
              outerLips.pointCount >= 6 else {
            return nil
        }

        func center(of region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = region.normalizedPoints
            let sumX = pts.reduce(0.0) { $0 + $1.x }
            let sumY = pts.reduce(0.0) { $0 + $1.y }
            let n = CGFloat(pts.count)
            return CGPoint(x: sumX / n, y: sumY / n)
        }

        let leftEyeCenter = center(of: leftEye)
        let rightEyeCenter = center(of: rightEye)

        // Nose tip: use the last point in the nose constellation
        let nosePts = nose.normalizedPoints
        let noseTip = nosePts[nosePts.count - 1]

        // Mouth corners: first and last points of outer lips
        let lipPts = outerLips.normalizedPoints
        let leftMouth = lipPts[0]
        let rightMouth = lipPts[lipPts.count / 2]

        let rawPoints: [CGPoint] = [leftEyeCenter, rightEyeCenter,
                                     noseTip, leftMouth, rightMouth]

        // Convert from face-bbox-relative normalized coords to full-image pixel coords.
        // Vision bbox: origin is bottom-left of image, normalized 0..1.
        // Landmark points: normalized 0..1 within the bbox, origin bottom-left.
        let bboxX = boundingBox.origin.x * imageWidth
        let bboxY = boundingBox.origin.y * imageHeight
        let bboxW = boundingBox.width * imageWidth
        let bboxH = boundingBox.height * imageHeight

        var pixelPoints: [(x: CGFloat, y: CGFloat)] = []
        for p in rawPoints {
            let px = bboxX + p.x * bboxW
            // Flip Y: Vision origin is bottom-left, CGImage is top-left
            let py = imageHeight - (bboxY + p.y * bboxH)
            pixelPoints.append((x: px, y: py))
        }

        return pixelPoints
    }

    // MARK: - Similarity Transform + Warp

    /// Estimates a similarity transform from `srcPoints` to `arcfaceDst`
    /// and warps the image to produce an aligned 112x112 face crop.
    ///
    /// A similarity transform has 4 parameters: scale, rotation, tx, ty.
    /// We solve it via least-squares on the 5 point pairs (10 equations, 4 unknowns).
    ///
    /// Uses inverse mapping with bilinear interpolation to avoid CGContext
    /// coordinate system pitfalls (CGContext has bottom-left origin while
    /// our pixel coordinates use top-left origin).
    private func warpAffineAligned(
        image: CGImage,
        srcPoints: [(x: CGFloat, y: CGFloat)],
        outputSize: Int
    ) -> CGImage? {
        let dst = Self.arcfaceDst
        guard srcPoints.count == dst.count, srcPoints.count >= 2 else { return nil }
        let n = srcPoints.count

        // Solve for similarity transform [a, -b, tx; b, a, ty] via least squares.
        // For each point pair (sx, sy) -> (dx, dy):
        //   dx = a*sx - b*sy + tx
        //   dy = b*sx + a*sy + ty

        var ata = [Double](repeating: 0, count: 16)
        var atb = [Double](repeating: 0, count: 4)

        for i in 0..<n {
            let sx = Double(srcPoints[i].x)
            let sy = Double(srcPoints[i].y)
            let dx = Double(dst[i].x)
            let dy = Double(dst[i].y)

            let row1: [Double] = [sx, -sy, 1, 0]
            let row2: [Double] = [sy, sx, 0, 1]

            for r in 0..<4 {
                for c in 0..<4 {
                    ata[r * 4 + c] += row1[r] * row1[c]
                    ata[r * 4 + c] += row2[r] * row2[c]
                }
                atb[r] += row1[r] * dx
                atb[r] += row2[r] * dy
            }
        }

        var nn: __CLAPACK_integer = 4
        var nrhs: __CLAPACK_integer = 1
        var lda: __CLAPACK_integer = 4
        var ipiv = [__CLAPACK_integer](repeating: 0, count: 4)
        var ldb: __CLAPACK_integer = 4
        var info: __CLAPACK_integer = 0

        dgesv_(&nn, &nrhs, &ata, &lda, &ipiv, &atb, &ldb, &info)

        guard info == 0 else {
            print("[StyleMate] FaceMatch: Similarity transform solve failed (info=\(info))")
            return nil
        }

        let a = atb[0]
        let b = atb[1]
        let tx = atb[2]
        let ty = atb[3]

        let det = a * a + b * b
        guard det > 1e-6 else {
            print("[StyleMate] FaceMatch: Degenerate transform (det=\(det))")
            return nil
        }

        // Inverse transform: for each output pixel (ox, oy), find source pixel (sx, sy)
        // Forward: dx = a*sx - b*sy + tx,  dy = b*sx + a*sy + ty
        // Inverse: sx = (a*(dx-tx) + b*(dy-ty)) / det
        //          sy = (a*(dy-ty) - b*(dx-tx)) / det
        let invA = a / det
        let invB = b / det

        // Read source image pixels into a buffer with top-left origin to match
        // the pixel coordinate system used by extractFiveKeypoints (y=0 is top).
        // CGBitmapContext has bottom-left origin, so we flip the CTM before drawing.
        let srcW = image.width
        let srcH = image.height
        let srcBytesPerPixel = 4
        let srcBytesPerRow = srcW * srcBytesPerPixel
        var srcPixels = [UInt8](repeating: 0, count: srcH * srcBytesPerRow)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let srcCtx = CGContext(
            data: &srcPixels,
            width: srcW, height: srcH,
            bitsPerComponent: 8,
            bytesPerRow: srcBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        // Flip to top-left origin: translate up then scale Y by -1
        srcCtx.translateBy(x: 0, y: CGFloat(srcH))
        srcCtx.scaleBy(x: 1, y: -1)
        srcCtx.draw(image, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))

        // Create output buffer
        let outSize = outputSize
        let outBytesPerRow = outSize * srcBytesPerPixel
        var outPixels = [UInt8](repeating: 0, count: outSize * outBytesPerRow)

        // Inverse warp with bilinear interpolation
        for oy in 0..<outSize {
            for ox in 0..<outSize {
                let dxd = Double(ox) - tx
                let dyd = Double(oy) - ty
                let sx = invA * dxd + invB * dyd
                let sy = -invB * dxd + invA * dyd

                guard sx >= 0, sy >= 0, sx < Double(srcW - 1), sy < Double(srcH - 1) else { continue }

                let x0 = Int(sx)
                let y0 = Int(sy)
                let x1 = x0 + 1
                let y1 = y0 + 1
                let fx = Float(sx - Double(x0))
                let fy = Float(sy - Double(y0))

                let outOffset = (oy * outSize + ox) * srcBytesPerPixel
                for c in 0..<3 {
                    let v00 = Float(srcPixels[y0 * srcBytesPerRow + x0 * srcBytesPerPixel + c])
                    let v10 = Float(srcPixels[y0 * srcBytesPerRow + x1 * srcBytesPerPixel + c])
                    let v01 = Float(srcPixels[y1 * srcBytesPerRow + x0 * srcBytesPerPixel + c])
                    let v11 = Float(srcPixels[y1 * srcBytesPerRow + x1 * srcBytesPerPixel + c])

                    let val = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                              v01 * (1 - fx) * fy + v11 * fx * fy
                    outPixels[outOffset + c] = UInt8(min(max(val, 0), 255))
                }
                outPixels[outOffset + 3] = 255
            }
        }

        guard let outCtx = CGContext(
            data: &outPixels,
            width: outSize, height: outSize,
            bitsPerComponent: 8,
            bytesPerRow: outBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        return outCtx.makeImage()
    }

    // MARK: - Fallback: BBox Crop + Resize to 112x112

    private func bboxCropResized(from cgImage: CGImage, observation: VNFaceObservation, outputSize: Int) -> CGImage? {
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        let bbox = observation.boundingBox

        let x = bbox.origin.x * imageWidth
        let y = (1 - bbox.origin.y - bbox.height) * imageHeight
        let w = bbox.width * imageWidth
        let h = bbox.height * imageHeight

        let padding: CGFloat = 0.3
        let padX = w * padding
        let padY = h * padding

        let cropX = max(0, x - padX)
        let cropY = max(0, y - padY)
        let cropRect = CGRect(
            x: cropX, y: cropY,
            width: min(imageWidth - cropX, w + 2 * padX),
            height: min(imageHeight - cropY, h + 2 * padY)
        )

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outputSize, height: outputSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outputSize, height: outputSize))
        return ctx.makeImage()
    }

    // MARK: - Embedding Generation (MobileFaceNet via CoreML)

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

            let embeddingSize = min(count, 512)
            var embedding = [Float](repeating: 0, count: embeddingSize)
            let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: embeddingSize)
            for i in 0..<embeddingSize {
                embedding[i] = ptr[i]
            }

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

    private func firstMultiArrayFeature(from output: MLFeatureProvider) -> MLFeatureValue? {
        for name in output.featureNames {
            if let value = output.featureValue(for: name), value.multiArrayValue != nil {
                return value
            }
        }
        return nil
    }

    /// Resizes a face crop to 112x112, converts to CHW Float32 MLMultiArray
    /// with [-1, 1] normalization in RGB order.
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
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }

        // Flip to top-left origin so pixelData[0] = top-left pixel,
        // matching the row order the ML model expects.
        context.translateBy(x: 0, y: CGFloat(size))
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let array = try? MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float32) else {
            return nil
        }

        let channelSize = size * size
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * channelSize)

        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * bytesPerPixel
                let r = Float(pixelData[offset]) / 127.5 - 1.0
                let g = Float(pixelData[offset + 1]) / 127.5 - 1.0
                let b = Float(pixelData[offset + 2]) / 127.5 - 1.0

                let pixelIndex = y * size + x
                ptr[pixelIndex] = r
                ptr[channelSize + pixelIndex] = g
                ptr[2 * channelSize + pixelIndex] = b
            }
        }

        return array
    }

    // MARK: - Cosine Similarity

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
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
        var bestArea: CGFloat = -1

        for body in bodies where body.confidence > 0.5 {
            let bodyBox = body.boundingBox
            if bodyBox.contains(CGPoint(x: faceMidX, y: faceMidY)) {
                let area = bodyBox.width * bodyBox.height
                if area > bestArea {
                    bestArea = area
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

    // MARK: - Legacy API compatibility

    func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        detectFacesWithLandmarks(in: cgImage)
    }

    func cropFace(from cgImage: CGImage, observation: VNFaceObservation, padding: CGFloat) -> CGImage? {
        alignedFaceCrop(from: cgImage, observation: observation)
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
