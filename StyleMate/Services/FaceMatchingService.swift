import UIKit
import Vision
import CoreML
import Accelerate

class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    private static let matchThreshold: Float = 0.45

    private var referenceEmbedding: [Float]?
    private var mlModel: MLModel?

    // InsightFace canonical 5-point destination for 112x112 alignment.
    // Source: insightface/utils/face_align.py `arcface_dst`
    private static let arcfaceDst: [SIMD2<Float>] = [
        SIMD2<Float>(38.2946, 51.6963),   // left eye center
        SIMD2<Float>(73.5318, 51.5014),   // right eye center
        SIMD2<Float>(56.0252, 71.7366),   // nose tip
        SIMD2<Float>(41.5493, 92.3655),   // left mouth corner
        SIMD2<Float>(70.7299, 92.2041)    // right mouth corner
    ]

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
        print("[FaceMatch] Selfie image: \(Int(image.size.width))x\(Int(image.size.height)) (was orientation \(rawImage.imageOrientation.rawValue))")

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

    // MARK: - Match Result

    struct MatchResult {
        let isMatch: Bool
        let matchedFace: VNFaceObservation?
        let faceCount: Int
        let distance: Float?
    }

    // MARK: - Find User in Photo

    func findUserInPhoto(_ cgImage: CGImage) -> MatchResult {
        guard let reference = referenceEmbedding else {
            print("[FaceMatch] WARNING: No reference embedding loaded, rejecting photo")
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        let faces = detectFacesWithLandmarks(in: cgImage)
        if faces.isEmpty {
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        var bestMatch: VNFaceObservation?
        var bestSimilarity: Float = -.infinity
        var allScores: [Float] = []

        let imgW = cgImage.width
        let imgH = cgImage.height

        for face in faces {
            guard let aligned = alignedFaceCrop(from: cgImage, observation: face,
                                                 imageWidth: imgW, imageHeight: imgH),
                  let embedding = generateEmbedding(for: aligned) else {
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

        print("[FaceMatch] no match all=[\(scoresStr)] faces=\(faces.count)")
        return MatchResult(isMatch: false, matchedFace: nil, faceCount: faces.count, distance: bestSimilarity)
    }

    // MARK: - Generate Embedding from a Full Photo (detect face + align + embed)

    private func generateEmbeddingFromPhoto(_ cgImage: CGImage, label: String) -> [Float]? {
        let faces = detectFacesWithLandmarks(in: cgImage)
        print("[FaceMatch] [\(label)] Detected \(faces.count) face(s)")

        guard let bestFace = faces.first else {
            print("[FaceMatch] [\(label)] No face detected")
            return nil
        }

        let imgW = cgImage.width
        let imgH = cgImage.height

        guard let aligned = alignedFaceCrop(from: cgImage, observation: bestFace,
                                             imageWidth: imgW, imageHeight: imgH) else {
            print("[FaceMatch] [\(label)] Failed to produce aligned face crop")
            return nil
        }

        print("[FaceMatch] [\(label)] Aligned crop: \(aligned.width)x\(aligned.height)")

        guard let embedding = generateEmbedding(for: aligned) else {
            print("[FaceMatch] [\(label)] Failed to generate embedding")
            return nil
        }

        return embedding
    }

    // MARK: - Face Detection

    func detectFacesWithLandmarks(in cgImage: CGImage) -> [VNFaceObservation] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.5 }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Aligned Face Crop (112x112)

    /// Produces an aligned 112x112 face crop for the ML model.
    /// Uses ArcFace 5-point alignment when landmarks are available,
    /// falls back to padded bbox crop otherwise.
    private func alignedFaceCrop(from cgImage: CGImage, observation: VNFaceObservation,
                                  imageWidth: Int, imageHeight: Int) -> CGImage? {
        if let landmarks = observation.landmarks {
            let srcPoints = extractFiveKeypoints(
                landmarks: landmarks,
                boundingBox: observation.boundingBox,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            )

            if let src = srcPoints {
                if let aligned = warpAligned(image: cgImage, srcPoints: src) {
                    return aligned
                }
                print("[FaceMatch] Warp failed, falling back to bbox crop")
            } else {
                print("[FaceMatch] Landmark extraction failed, falling back to bbox crop")
            }
        }

        return bboxCrop(from: cgImage, bbox: observation.boundingBox,
                        imageWidth: imageWidth, imageHeight: imageHeight)
    }

    // MARK: - Landmark Extraction (5 Keypoints)

    /// Extracts the 5 keypoints for ArcFace alignment using Apple's
    /// VNImagePointForFaceLandmarkPoint for coordinate conversion.
    /// Returns points in image pixel coordinates (origin top-left).
    private func extractFiveKeypoints(
        landmarks: VNFaceLandmarks2D,
        boundingBox: CGRect,
        imageWidth: Int,
        imageHeight: Int
    ) -> [SIMD2<Float>]? {
        guard let leftEye = landmarks.leftEye, leftEye.pointCount >= 1,
              let rightEye = landmarks.rightEye, rightEye.pointCount >= 1,
              let nose = landmarks.nose, nose.pointCount >= 1 else {
            print("[FaceMatch] Missing required landmarks (eyes or nose)")
            return nil
        }

        func convertPoint(_ normPt: CGPoint) -> SIMD2<Float> {
            let imgPt = VNImagePointForFaceLandmarkPoint(
                vector_float2(Float(normPt.x), Float(normPt.y)),
                boundingBox,
                imageWidth,
                imageHeight
            )
            // VNImagePointForFaceLandmarkPoint returns coords with origin at bottom-left.
            // CGImage pixel coords have origin at top-left. Flip Y.
            return SIMD2<Float>(Float(imgPt.x), Float(imageHeight) - Float(imgPt.y))
        }

        func center(of region: VNFaceLandmarkRegion2D) -> CGPoint {
            let pts = region.normalizedPoints
            let n = CGFloat(pts.count)
            let sx = pts.reduce(0.0) { $0 + $1.x } / n
            let sy = pts.reduce(0.0) { $0 + $1.y } / n
            return CGPoint(x: sx, y: sy)
        }

        let leftEyeCenter = convertPoint(center(of: leftEye))
        let rightEyeCenter = convertPoint(center(of: rightEye))

        let nosePts = nose.normalizedPoints
        let noseTip = convertPoint(nosePts[nosePts.count - 1])

        // Mouth corners: try outerLips first, fall back to innerLips, then estimate
        var leftMouth: SIMD2<Float>
        var rightMouth: SIMD2<Float>

        if let outerLips = landmarks.outerLips, outerLips.pointCount >= 2 {
            let lipPts = outerLips.normalizedPoints
            leftMouth = convertPoint(lipPts[0])
            let midIdx = outerLips.pointCount / 2
            rightMouth = convertPoint(lipPts[midIdx])
        } else if let innerLips = landmarks.innerLips, innerLips.pointCount >= 2 {
            let lipPts = innerLips.normalizedPoints
            leftMouth = convertPoint(lipPts[0])
            let midIdx = innerLips.pointCount / 2
            rightMouth = convertPoint(lipPts[midIdx])
        } else {
            // Estimate mouth corners from eye positions and nose
            let eyeMidX = (leftEyeCenter.x + rightEyeCenter.x) / 2
            let eyeSpan = rightEyeCenter.x - leftEyeCenter.x
            let mouthY = noseTip.y + (noseTip.y - (leftEyeCenter.y + rightEyeCenter.y) / 2) * 0.6
            leftMouth = SIMD2<Float>(eyeMidX - eyeSpan * 0.35, mouthY)
            rightMouth = SIMD2<Float>(eyeMidX + eyeSpan * 0.35, mouthY)
            print("[FaceMatch] Estimated mouth corners from eye/nose positions")
        }

        let result = [leftEyeCenter, rightEyeCenter, noseTip, leftMouth, rightMouth]

        // Sanity check: all points should be within a reasonable range
        for (i, pt) in result.enumerated() {
            if pt.x < -50 || pt.y < -50 || pt.x > Float(imageWidth + 50) || pt.y > Float(imageHeight + 50) {
                print("[FaceMatch] Keypoint \(i) out of bounds: (\(pt.x), \(pt.y)) for \(imageWidth)x\(imageHeight) image")
                return nil
            }
        }

        return result
    }

    // MARK: - Similarity Transform + Warp (ArcFace Alignment)

    /// Computes a similarity transform from srcPoints to arcfaceDst and warps the image.
    /// Uses pixel-buffer-based inverse warp for precise control.
    private func warpAligned(image: CGImage, srcPoints: [SIMD2<Float>]) -> CGImage? {
        let dst = Self.arcfaceDst
        guard srcPoints.count == 5, dst.count == 5 else { return nil }

        // Solve for the similarity transform that maps src -> dst
        // Using the InsightFace convention: estimate(dst, src) gives the inverse
        // transform (dst->src), which is what warpAffine needs.
        //
        // Similarity transform: [a, -b, tx; b, a, ty]
        // For each point: dx = a*sx - b*sy + tx, dy = b*sx + a*sy + ty
        //
        // We solve the normal equations for [a, b, tx, ty]

        var ata = [Float](repeating: 0, count: 16)
        var atb = [Float](repeating: 0, count: 4)

        for i in 0..<5 {
            let sx = srcPoints[i].x
            let sy = srcPoints[i].y
            let dx = dst[i].x
            let dy = dst[i].y

            // Row for x equation: [sx, -sy, 1, 0] * [a, b, tx, ty]' = dx
            // Row for y equation: [sy, sx, 0, 1] * [a, b, tx, ty]' = dy
            let rows: [[Float]] = [
                [sx, -sy, 1, 0],
                [sy, sx, 0, 1]
            ]
            let rhs: [Float] = [dx, dy]

            for (row, d) in zip(rows, rhs) {
                for r in 0..<4 {
                    for c in 0..<4 {
                        ata[r * 4 + c] += row[r] * row[c]
                    }
                    atb[r] += row[r] * d
                }
            }
        }

        // Solve 4x4 system via Gaussian elimination
        guard gaussianSolve4x4(&ata, &atb) else {
            print("[FaceMatch] Transform solve failed (singular)")
            return nil
        }

        let a = atb[0], b = atb[1], tx = atb[2], ty = atb[3]
        let det = a * a + b * b
        guard det > 1e-6 else {
            print("[FaceMatch] Degenerate transform (det=\(det))")
            return nil
        }

        // Inverse: for output pixel (ox, oy), find source pixel (sx, sy)
        // sx = (a*(ox-tx) + b*(oy-ty)) / det
        // sy = (-b*(ox-tx) + a*(oy-ty)) / det
        let invDet = 1.0 / det

        // Rasterize source image into a pixel buffer (top-left origin)
        let srcW = image.width
        let srcH = image.height
        guard let srcBuffer = imageToPixelBuffer(image) else {
            print("[FaceMatch] Failed to rasterize source image")
            return nil
        }

        let outSize = 112
        let bpp = 4
        let outBytesPerRow = outSize * bpp
        var outPixels = [UInt8](repeating: 0, count: outSize * outBytesPerRow)

        let srcBytesPerRow = srcW * bpp

        for oy in 0..<outSize {
            for ox in 0..<outSize {
                let dxOff = Float(ox) - tx
                let dyOff = Float(oy) - ty
                let sx = (a * dxOff + b * dyOff) * invDet
                let sy = (-b * dxOff + a * dyOff) * invDet

                guard sx >= 0, sy >= 0, sx < Float(srcW - 1), sy < Float(srcH - 1) else { continue }

                // Bilinear interpolation
                let x0 = Int(sx), y0 = Int(sy)
                let x1 = x0 + 1, y1 = y0 + 1
                let fx = sx - Float(x0), fy = sy - Float(y0)

                let outOff = (oy * outSize + ox) * bpp
                for c in 0..<3 {
                    let v00 = Float(srcBuffer[y0 * srcBytesPerRow + x0 * bpp + c])
                    let v10 = Float(srcBuffer[y0 * srcBytesPerRow + x1 * bpp + c])
                    let v01 = Float(srcBuffer[y1 * srcBytesPerRow + x0 * bpp + c])
                    let v11 = Float(srcBuffer[y1 * srcBytesPerRow + x1 * bpp + c])

                    let val = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) +
                              v01 * (1 - fx) * fy + v11 * fx * fy
                    outPixels[outOff + c] = UInt8(min(max(val, 0), 255))
                }
                outPixels[outOff + 3] = 255
            }
        }

        return pixelBufferToImage(outPixels, width: outSize, height: outSize)
    }

    // MARK: - Pixel Buffer Helpers

    /// Rasterizes a CGImage into an RGBA pixel buffer with top-left origin.
    /// Uses UIGraphicsImageRenderer which handles coordinate flipping correctly.
    private func imageToPixelBuffer(_ cgImage: CGImage) -> [UInt8]? {
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

        // CGContext has bottom-left origin. Flip so pixels[0] = top-left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        return pixels
    }

    /// Creates a CGImage from an RGBA pixel buffer (top-left origin).
    private func pixelBufferToImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let bpp = 4
        let bytesPerRow = width * bpp
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }

        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    // MARK: - Fallback: BBox Crop + Resize

    private func bboxCrop(from cgImage: CGImage, bbox: CGRect,
                           imageWidth: Int, imageHeight: Int) -> CGImage? {
        let imgW = CGFloat(imageWidth)
        let imgH = CGFloat(imageHeight)

        // Vision bbox: origin bottom-left, normalized. Convert to CGImage top-left pixels.
        let x = bbox.origin.x * imgW
        let y = (1 - bbox.origin.y - bbox.height) * imgH
        let w = bbox.width * imgW
        let h = bbox.height * imgH

        let padding: CGFloat = 0.3
        let padX = w * padding
        let padY = h * padding

        let cropX = max(0, x - padX)
        let cropY = max(0, y - padY)
        let cropW = min(imgW - cropX, w + 2 * padX)
        let cropH = min(imgH - cropY, h + 2 * padY)

        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard cropW > 10, cropH > 10 else { return nil }

        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        // Resize to 112x112 using UIGraphicsImageRenderer (handles coords correctly)
        let uiImage = UIImage(cgImage: cropped)
        let size = CGSize(width: 112, height: 112)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.cgImage
    }

    // MARK: - Embedding Generation

    private func generateEmbedding(for faceCrop: CGImage) -> [Float]? {
        guard ensureModelLoaded(), let model = mlModel else { return nil }

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

            // L2-normalize
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

    /// Converts a 112x112 CGImage to a [1, 3, 112, 112] Float32 MLMultiArray.
    /// Normalization: (pixel / 127.5) - 1.0 to [-1, 1] range, RGB channel order.
    private func createInputMultiArray(from cgImage: CGImage) -> MLMultiArray? {
        let size = 112

        // Rasterize to pixel buffer (top-left origin, RGBA)
        guard let pixels = imageToPixelBuffer(cgImage) else { return nil }

        // The cgImage should already be 112x112 from alignment, but verify
        let actualW = cgImage.width
        let actualH = cgImage.height

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        ) else { return nil }

        let channelSize = size * size
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * channelSize)
        let bpp = 4
        let srcBytesPerRow = actualW * bpp

        for y in 0..<size {
            for x in 0..<size {
                // Map output (x,y) to source pixel. If sizes don't match, scale.
                let srcX = min(x * actualW / size, actualW - 1)
                let srcY = min(y * actualH / size, actualH - 1)
                let offset = srcY * srcBytesPerRow + srcX * bpp

                let r = Float(pixels[offset]) / 127.5 - 1.0
                let g = Float(pixels[offset + 1]) / 127.5 - 1.0
                let b = Float(pixels[offset + 2]) / 127.5 - 1.0

                let pixelIndex = y * size + x
                ptr[pixelIndex] = r
                ptr[channelSize + pixelIndex] = g
                ptr[2 * channelSize + pixelIndex] = b
            }
        }

        return array
    }

    // MARK: - Dot Product (Cosine Similarity for L2-Normalized Vectors)

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    // MARK: - Gaussian Elimination (4x4)

    private func gaussianSolve4x4(_ a: inout [Float], _ b: inout [Float]) -> Bool {
        let n = 4
        for col in 0..<n {
            var maxVal = abs(a[col * n + col])
            var maxRow = col
            for row in (col + 1)..<n {
                let v = abs(a[row * n + col])
                if v > maxVal { maxVal = v; maxRow = row }
            }
            if maxVal < 1e-8 { return false }

            if maxRow != col {
                for k in 0..<n { a.swapAt(col * n + k, maxRow * n + k) }
                b.swapAt(col, maxRow)
            }

            let pivot = a[col * n + col]
            for row in (col + 1)..<n {
                let factor = a[row * n + col] / pivot
                for k in col..<n { a[row * n + k] -= factor * a[col * n + k] }
                b[row] -= factor * b[col]
            }
        }

        for col in stride(from: n - 1, through: 0, by: -1) {
            for k in (col + 1)..<n { b[col] -= a[col * n + k] * b[k] }
            b[col] /= a[col * n + col]
        }
        return true
    }

    // MARK: - Orientation Normalization

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

    // MARK: - Body Cropping (Multi-Person Photos)

    func cropToUserBody(from cgImage: CGImage, matchResult: MatchResult) -> CGImage? {
        guard matchResult.faceCount > 1, let face = matchResult.matchedFace else {
            return nil
        }

        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)

        // Try Vision body detection first
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
                x: finalX, y: finalY,
                width: min(imageW - finalX, cropW + 2 * padX),
                height: min(imageH - finalY, cropH + padY)
            )

            if cropRect.width >= 200, cropRect.height >= 200 {
                print("[FaceMatch] Body crop via detection: \(Int(cropRect.width))x\(Int(cropRect.height))")
                return cgImage.cropping(to: cropRect)
            }
        }

        // Heuristic fallback: estimate body region from face position
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
            let bb = body.boundingBox
            if bb.contains(CGPoint(x: faceMidX, y: faceMidY)) {
                let area = bb.width * bb.height
                if area > bestArea { bestArea = area; bestBody = bb }
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
            x: cropX, y: bodyTop,
            width: min(imageW - cropX, bodyWidth),
            height: min(imageH - bodyTop, bodyHeight)
        )

        guard cropRect.width >= 200, cropRect.height >= 200 else { return nil }

        print("[FaceMatch] Body crop via heuristic: \(Int(cropRect.width))x\(Int(cropRect.height))")
        return cgImage.cropping(to: cropRect)
    }

    // MARK: - Public State

    var hasReference: Bool { referenceEmbedding != nil }

    func clearReference() {
        referenceEmbedding = nil
        mlModel = nil
    }

    // MARK: - Legacy API Compatibility

    func detectFaces(in cgImage: CGImage) -> [VNFaceObservation] {
        detectFacesWithLandmarks(in: cgImage)
    }

    func cropFace(from cgImage: CGImage, observation: VNFaceObservation, padding: CGFloat) -> CGImage? {
        alignedFaceCrop(from: cgImage, observation: observation,
                        imageWidth: cgImage.width, imageHeight: cgImage.height)
    }

    func photoContainsAnyPerson(_ cgImage: CGImage) -> Bool {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).contains { $0.confidence > 0.5 }
    }
}
