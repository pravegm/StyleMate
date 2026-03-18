import UIKit
import Vision

class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    // Revision 1 (iOS 16): 2048-dim non-normalized, distances 0–40
    // Revision 2 (iOS 17+): 768-dim normalized, distances 0–2.0
    // VNFeaturePrint is a general image similarity tool, not a face identity system,
    // so thresholds must be permissive to tolerate lighting/angle/expression changes.
    private static let thresholdRevision1: Float = 20.0
    private static let thresholdRevision2: Float = 1.2

    private var referenceFacePrint: VNFeaturePrintObservation?
    private var activeThreshold: Float = thresholdRevision1

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

        // The front-camera selfie is saved with .leftMirrored orientation.
        // UIImage.cgImage does NOT apply orientation transforms, so Vision
        // receives a rotated/mirrored image. Render into a normalized bitmap.
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

        guard let faceCrop = cropFace(from: cgImage, observation: bestFace, padding: 0.3) else {
            print("[StyleMate] FaceMatch: Could not crop face from selfie")
            return false
        }

        print("[StyleMate] FaceMatch: Face crop size: \(faceCrop.width)x\(faceCrop.height)")

        guard let result = generateFeaturePrint(for: faceCrop) else {
            print("[StyleMate] FaceMatch: Could not generate feature print from selfie")
            return false
        }

        referenceFacePrint = result.observation
        activeThreshold = result.requestRevision >= 2 ? Self.thresholdRevision2 : Self.thresholdRevision1
        print("[StyleMate] FaceMatch: Selfie reference loaded (revision: \(result.requestRevision), threshold: \(activeThreshold))")
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
        guard let reference = referenceFacePrint else {
            let hasPerson = photoContainsAnyPerson(cgImage)
            return MatchResult(isMatch: hasPerson, matchedFace: nil, faceCount: hasPerson ? 1 : 0, distance: nil)
        }

        let faces = detectFaces(in: cgImage)
        if faces.isEmpty {
            return MatchResult(isMatch: false, matchedFace: nil, faceCount: 0, distance: nil)
        }

        var bestMatch: VNFaceObservation?
        var bestDistance: Float = .infinity

        for face in faces {
            guard let faceCrop = cropFace(from: cgImage, observation: face, padding: 0.3),
                  let result = generateFeaturePrint(for: faceCrop) else { continue }

            var distance: Float = .infinity
            do { try reference.computeDistance(&distance, to: result.observation) } catch { continue }

            if distance < bestDistance {
                bestDistance = distance
                bestMatch = face
            }
        }

        if bestDistance < activeThreshold, let matchedFace = bestMatch {
            print("[StyleMate] FaceMatch: Match (distance: \(String(format: "%.2f", bestDistance)), \(faces.count) faces)")
            return MatchResult(isMatch: true, matchedFace: matchedFace, faceCount: faces.count, distance: bestDistance)
        }

        print("[StyleMate] FaceMatch: No match (\(faces.count) faces, best: \(String(format: "%.2f", bestDistance)))")
        return MatchResult(isMatch: false, matchedFace: nil, faceCount: faces.count, distance: bestDistance)
    }

    // MARK: - Crop to User's Body Region (Multi-Person Photos)

    /// Attempts to crop the image to the matched user's body using VNDetectHumanRectanglesRequest
    /// to find real body bounding boxes, then spatially matches the user's face to a body.
    /// Falls back to a face-proportional heuristic if no body rectangle overlaps the face.
    func cropToUserBody(from cgImage: CGImage, matchResult: MatchResult) -> CGImage? {
        guard matchResult.faceCount > 1,
              let face = matchResult.matchedFace else {
            return nil
        }

        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)

        // Try VNDetectHumanRectanglesRequest first (pose-adaptive, handles sitting/standing)
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

    /// Detects human body rectangles and returns the one whose bounding box best overlaps the given face.
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

    /// Fallback heuristic when VNDetectHumanRectanglesRequest doesn't find a body for the face.
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

    var hasReference: Bool { referenceFacePrint != nil }

    func clearReference() { referenceFacePrint = nil }

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

    // MARK: - Feature Print Generation

    struct FeaturePrintResult {
        let observation: VNFeaturePrintObservation
        let requestRevision: Int
    }

    func generateFeaturePrint(for cgImage: CGImage) -> FeaturePrintResult? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let obs = request.results?.first else { return nil }
        return FeaturePrintResult(observation: obs, requestRevision: request.revision)
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
