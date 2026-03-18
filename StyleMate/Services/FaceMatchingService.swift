import UIKit
import Vision

class FaceMatchingService {
    static let shared = FaceMatchingService()
    private init() {}

    private static let matchThreshold: Float = 14.0

    private var referenceFacePrint: VNFeaturePrintObservation?

    // MARK: - Load Selfie Reference

    func loadSelfieReference(forUser userId: String) -> Bool {
        let key = "selfieReferencePath_\(userId)"
        guard let path = UserDefaults.standard.string(forKey: key) else {
            print("[StyleMate] FaceMatch: No selfie path found for user")
            return false
        }

        guard let image = UIImage(contentsOfFile: path) ?? loadFromDocuments(filename: path) else {
            print("[StyleMate] FaceMatch: Could not load selfie image at path: \(path)")
            return false
        }

        guard let cgImage = image.cgImage else {
            print("[StyleMate] FaceMatch: Could not get CGImage from selfie")
            return false
        }

        let faceObservations = detectFaces(in: cgImage)
        guard let bestFace = faceObservations.first else {
            print("[StyleMate] FaceMatch: No face detected in selfie")
            return false
        }

        guard let faceCrop = cropFace(from: cgImage, observation: bestFace, padding: 0.3) else {
            print("[StyleMate] FaceMatch: Could not crop face from selfie")
            return false
        }

        referenceFacePrint = generateFeaturePrint(for: faceCrop)

        if referenceFacePrint != nil {
            print("[StyleMate] FaceMatch: Selfie reference loaded successfully")
            return true
        } else {
            print("[StyleMate] FaceMatch: Could not generate feature print from selfie")
            return false
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
                  let facePrint = generateFeaturePrint(for: faceCrop) else { continue }

            var distance: Float = .infinity
            do { try reference.computeDistance(&distance, to: facePrint) } catch { continue }

            if distance < bestDistance {
                bestDistance = distance
                bestMatch = face
            }
        }

        if bestDistance < Self.matchThreshold, let matchedFace = bestMatch {
            print("[StyleMate] FaceMatch: Match (distance: \(String(format: "%.2f", bestDistance)), \(faces.count) faces)")
            return MatchResult(isMatch: true, matchedFace: matchedFace, faceCount: faces.count, distance: bestDistance)
        }

        print("[StyleMate] FaceMatch: No match (\(faces.count) faces, best: \(String(format: "%.2f", bestDistance)))")
        return MatchResult(isMatch: false, matchedFace: nil, faceCount: faces.count, distance: bestDistance)
    }

    // MARK: - Crop to User's Body Region (Multi-Person Photos)

    func cropToUserBody(from cgImage: CGImage, matchResult: MatchResult) -> CGImage? {
        guard matchResult.faceCount > 1,
              let face = matchResult.matchedFace else {
            return nil
        }

        let imageW = CGFloat(cgImage.width)
        let imageH = CGFloat(cgImage.height)
        let bbox = face.boundingBox

        let faceX = bbox.origin.x * imageW
        let faceY = (1 - bbox.origin.y - bbox.height) * imageH
        let faceW = bbox.width * imageW
        let faceH = bbox.height * imageH

        let bodyWidth = faceW * 2.5
        let bodyHeight = faceH * 5.5
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

        print("[StyleMate] FaceMatch: Cropped to user body: \(Int(cropRect.width))x\(Int(cropRect.height))")
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

    func generateFeaturePrint(for cgImage: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results?.first
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
