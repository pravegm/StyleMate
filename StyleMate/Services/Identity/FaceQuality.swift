import CoreGraphics
import Foundation
import simd

/// Face quality signals from the face detection: box size, detector score and head pose
/// estimated from the 5 landmarks (img-left eye, img-right eye, nose, img-left mouth, img-right mouth).
/// Pure functions, unit-tested.
enum FaceQuality {
    // Library faces (measured on the ~960 px thumbnails used for the "Find yourself" pass).
    // 32 px at 960 is 21 px at the old 640: a little more inclusive than before, since the
    // bigger thumbnail gives those faces enough pixels to embed.
    static let minLibraryFacePixels: Float = 32
    static let minLibraryDetectorScore: Float = FaceModelProfile.active.minLibraryDetectorScore
    /// Past ~40° of yaw the 5-point alignment degrades and embeddings stop being reliable.
    static let maxLibraryYaw: Float = 0.9

    /// Signed head-yaw proxy: where the nose sits between the eyes, along the eye line.
    /// 0 = frontal; about ±0.4 at 20° of turn; ±1 when the nose is over an eye (strong profile).
    static func yawProxy(_ kp: [SIMD2<Float>]) -> Float {
        guard kp.count == 5 else { return 0 }
        let axis = kp[1] - kp[0]
        let span = simd_length(axis)
        guard span > 1e-3 else { return 1 }
        let t = simd_dot(kp[2] - kp[0], axis / span) / span
        return 2 * t - 1
    }

    /// 1 for a frontal face, falling to 0 at a strong profile.
    static func frontalness(_ kp: [SIMD2<Float>]) -> Float {
        max(0, 1 - abs(yawProxy(kp)))
    }

    /// 0…1: bigger, sharper (higher detector score) and more frontal faces seed clusters and
    /// are preferred in the review grid.
    static func libraryScore(shortSidePixels: Float, detectorScore: Float, keypoints: [SIMD2<Float>]) -> Float {
        let size = min(1, max(0, (shortSidePixels - 20) / 80))
        let det = min(1, max(0, (detectorScore - 0.5) / 0.4))
        return 0.4 * size + 0.3 * det + 0.3 * frontalness(keypoints)
    }

    /// Faces too small, too uncertain or too turned to embed reliably are left out of clustering.
    static func isUsableLibraryFace(shortSidePixels: Float, detectorScore: Float, keypoints: [SIMD2<Float>]) -> Bool {
        shortSidePixels >= minLibraryFacePixels
            && detectorScore >= minLibraryDetectorScore
            && abs(yawProxy(keypoints)) <= maxLibraryYaw
    }

    /// Small patches over each eye and over the cheek/nose area (image pixels, top-left origin),
    /// used to spot sunglasses: dark lenses make the eyes far darker than the skin below them.
    static func eyeAndCheekPatches(_ kp: [SIMD2<Float>]) -> (eyes: [CGRect], cheek: CGRect)? {
        guard kp.count == 5 else { return nil }
        let eyeDist = simd_length(kp[1] - kp[0])
        guard eyeDist > 4 else { return nil }
        func square(_ c: SIMD2<Float>, _ half: Float) -> CGRect {
            CGRect(x: CGFloat(c.x - half), y: CGFloat(c.y - half), width: CGFloat(2 * half), height: CGFloat(2 * half))
        }
        let eyeHalf = eyeDist * 0.16
        let mouthMid = (kp[3] + kp[4]) / 2
        let cheekCenter = kp[2] + (mouthMid - kp[2]) * 0.2
        return ([square(kp[0], eyeHalf), square(kp[1], eyeHalf)], square(cheekCenter, eyeDist * 0.2))
    }
}

// MARK: - Selfie capture

/// The three reference frames the selfie step captures.
enum SelfieStep: Int, CaseIterable {
    case front, left, right

    var next: SelfieStep? { SelfieStep(rawValue: rawValue + 1) }
    var number: Int { rawValue + 1 }

    var prompt: String {
        switch self {
        case .front: return "Look straight at the camera"
        case .left: return "Now turn your head slightly left"
        case .right: return "And slightly to the right"
        }
    }

    var label: String {
        switch self {
        case .front: return "Straight"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// Why a captured selfie frame isn't a good reference, with friendly copy.
enum SelfieIssue: Equatable {
    case noFace, multipleFaces, tooSmall, offCenter, tooDark, tooBright, unclear
    case sunglasses, lookStraight, turnedTooFar, differentPerson

    var message: String {
        switch self {
        case .noFace: return "We couldn't see your face. Fill the oval and try again."
        case .multipleFaces: return "Someone else is in the shot. Just you this time."
        case .tooSmall: return "Come a little closer so your face fills the oval."
        case .offCenter: return "Center your face in the oval."
        case .tooDark: return "It's a bit dark. Face a window or a lamp."
        case .tooBright: return "Too much glare. Step out of direct light."
        case .unclear: return "That one came out blurry. Hold still for a moment."
        case .sunglasses: return "Take off sunglasses or anything covering your eyes."
        case .lookStraight: return "Look straight at the camera for this one."
        case .turnedTooFar: return "A slight turn is plenty. Not quite so far."
        case .differentPerson: return "That didn't look like the same person. Make sure it's only you."
        }
    }

    /// Issues that would poison the reference. These are never accepted, even after retries.
    var isBlocking: Bool {
        switch self {
        case .noFace, .multipleFaces, .differentPerson: return true
        default: return false
        }
    }
}

/// What we measured on one captured frame.
struct SelfieFrameMeasurements: Equatable {
    var faceCount: Int
    var detectorScore: Float
    /// Face box width as a fraction of the frame width.
    var faceWidthFraction: Float
    /// Face box centre, normalized 0…1, top-left origin.
    var faceCenter: CGPoint
    /// Mean luma (0…255) inside the face box.
    var faceLuma: Float
    var eyeLuma: Float?
    var cheekLuma: Float?
    var yaw: Float
    /// Face-embedding similarity to the accepted front frame (turn frames only).
    var similarityToFront: Float?
}

/// Decides whether a captured frame is a good identity reference.
enum SelfieFrameAssessor {
    static let minWidthFraction: Float = 0.22
    static let minDetectorScore: Float = FaceModelProfile.active.minSelfieDetectorScore
    static let darkLuma: Float = 55
    static let brightLuma: Float = 225
    static let maxFrontYaw: Float = 0.45
    static let maxTurnYaw: Float = 1.0
    /// Same session, same light, slight turn: the user's own frames score far above this.
    static let minSimilarityToFront: Float = FaceModelProfile.active.selfieTurnMinSimilarity

    static func issue(for m: SelfieFrameMeasurements, step: SelfieStep) -> SelfieIssue? {
        if m.faceCount == 0 { return .noFace }
        if m.faceCount > 1 { return .multipleFaces }
        if m.faceWidthFraction < minWidthFraction { return .tooSmall }
        if m.faceCenter.x < 0.2 || m.faceCenter.x > 0.8 || m.faceCenter.y < 0.15 || m.faceCenter.y > 0.85 {
            return .offCenter
        }
        if m.faceLuma < darkLuma { return .tooDark }
        if m.faceLuma > brightLuma { return .tooBright }
        if m.detectorScore < minDetectorScore { return .unclear }
        if let eye = m.eyeLuma, let cheek = m.cheekLuma, cheek > 40, eye < 70, eye / cheek < 0.4 {
            return .sunglasses
        }
        if step == .front, abs(m.yaw) > maxFrontYaw { return .lookStraight }
        if abs(m.yaw) > maxTurnYaw { return .turnedTooFar }
        if let s = m.similarityToFront, s < minSimilarityToFront { return .differentPerson }
        return nil
    }
}

// MARK: - Luma

enum ImageLuma {
    /// Mean luma (0…255) of `rect` (image pixels, top-left origin) in `image`. Downsamples to at
    /// most 32×32 so it's cheap. Nil when the rect is outside the image.
    static func mean(in rect: CGRect, of image: CGImage) -> Float? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1, let crop = image.cropping(to: r) else { return nil }
        let w = max(1, min(32, crop.width)), h = max(1, min(32, crop.height))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let total = pixels.reduce(0) { $0 + Int($1) }
        return Float(total) / Float(w * h)
    }
}
