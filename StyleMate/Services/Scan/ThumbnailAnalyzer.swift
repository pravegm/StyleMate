import CoreGraphics
import Foundation
import Vision

/// Cheap checks on a library thumbnail (~640 px) before the full photo is
/// loaded: is there a person at all, and — for near-duplicate groups — how good
/// a frame is it (body in view, face size, sharpness).
enum ThumbnailAnalyzer {
    /// Person check only (singletons don't need ranking). Same bar as
    /// `FaceMatchingService.photoContainsAnyPerson`.
    static func hasPerson(_ image: CGImage) -> Bool {
        if let people = people(in: image) { return !people.isEmpty }
        return !fallbackFaces(in: image).isEmpty
    }

    /// Full signals for picking the best frame of a burst.
    static func signals(for image: CGImage) -> ThumbnailSignals {
        guard let people = people(in: image) else {
            let f = fallbackSignals(image)
            return ThumbnailSignals(hasPerson: f.personCount > 0, bodyHeight: f.bodyHeight, faceArea: f.faceArea,
                                    sharpness: f.personCount > 0 ? sharpness(of: image) : 0)
        }
        guard !people.isEmpty else { return ThumbnailSignals(hasPerson: false) }
        let body = people.map { Double($0.boundingBox.height) }.max() ?? 0
        return ThumbnailSignals(hasPerson: true, bodyHeight: body, faceArea: visionFaceArea(image),
                                sharpness: sharpness(of: image))
    }

    /// Signals for the first run's "best outfit photos first" ranking
    /// (`FirstLook`): how many people, how much of the tallest one is in view,
    /// and whether there's a face to recognise. Two cheap Vision requests on a
    /// small thumbnail; documents, food and scenery have no person and drop out.
    static func firstLookSignals(for image: CGImage) -> FirstLookSignals {
        guard let people = people(in: image) else { return fallbackSignals(image) }
        guard !people.isEmpty else { return .none }
        let body = people.map { Double($0.boundingBox.height) }.max() ?? 0
        return FirstLookSignals(personCount: people.count, bodyHeight: body, faceArea: visionFaceArea(image))
    }

    // MARK: - People

    /// People Vision found (confidence > 0.5), or nil when its request couldn't run at all.
    ///
    /// The request can fail (it does on the iOS simulator; a device short of memory or with the Neural
    /// Engine busy can too). Before, `try?` turned that into "nobody in this photo" for every photo: the
    /// scan then looked at thousands of photos, ran not one face check and added nothing
    /// ("Live stats: Nothing measured yet", RealFirstRunE2ETests). Callers fall back to the face detector.
    static func people(in image: CGImage) -> [VNHumanObservation]? {
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([humans])
        } catch {
            noteVisionFailure(error)
            return nil
        }
        guard let results = humans.results else { return nil }
        return results.filter { $0.confidence > 0.5 }
    }

    /// Largest Vision face area as a fraction of the frame (0 when none or the request failed).
    private static func visionFaceArea(_ image: CGImage) -> Double {
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([faces])
        return (faces.results ?? []).map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
    }

    /// Without Vision's body detector: the app's own face detector (YuNet). A visible face stands for a
    /// person; the body height is estimated from the face (a standing adult is ~7.5 heads tall).
    static func fallbackSignals(_ image: CGImage) -> FirstLookSignals {
        let faces = fallbackFaces(in: image)
        guard !faces.isEmpty else { return .none }
        let W = Double(image.width), H = Double(image.height)
        let tallest = faces.map { Double($0.boxPixels.height) }.max() ?? 0
        let area = faces.map { Double($0.boxPixels.width * $0.boxPixels.height) }.max() ?? 0
        return FirstLookSignals(personCount: faces.count, bodyHeight: min(1, 7.5 * tallest / max(H, 1)),
                                faceArea: area / max(W * H, 1))
    }

    static func fallbackFaces(in image: CGImage) -> [DetectedFace] {
        FaceDetector.shared.detect(in: image, padRetry: false)
    }

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var loggedFailure = false

    private static func noteVisionFailure(_ error: Error) {
        failureLock.lock()
        let first = !loggedFailure
        loggedFailure = true
        failureLock.unlock()
        if first { dlog("[Scan] Vision person detection failed (\(error.localizedDescription)); using the face detector instead") }
    }

    // MARK: - Sharpness

    /// 0...1 sharpness: variance of the Laplacian on a small grayscale copy,
    /// squashed so a crisp phone photo lands near 0.8–0.95 and motion blur
    /// near 0.1–0.3.
    static func sharpness(of image: CGImage, longSide: Int = 256) -> Double {
        guard let (pixels, w, h) = grayscale(image, longSide: longSide) else { return 0 }
        let v = laplacianVariance(pixels, width: w, height: h)
        return v / (v + 300)
    }

    /// Variance of the 4-neighbour Laplacian over the interior pixels.
    static func laplacianVariance(_ px: [UInt8], width w: Int, height h: Int) -> Double {
        guard w >= 3, h >= 3, px.count >= w * h else { return 0 }
        var sum = 0.0, sumSq = 0.0, n = 0.0
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                let lap = Double(px[i - 1]) + Double(px[i + 1]) + Double(px[i - w]) + Double(px[i + w])
                    - 4 * Double(px[i])
                sum += lap
                sumSq += lap * lap
                n += 1
            }
        }
        guard n > 0 else { return 0 }
        let mean = sum / n
        return max(0, sumSq / n - mean * mean)
    }

    static func grayscale(_ image: CGImage, longSide: Int) -> ([UInt8], Int, Int)? {
        let iw = image.width, ih = image.height
        guard iw > 0, ih > 0 else { return nil }
        let k = min(1, Double(longSide) / Double(max(iw, ih)))
        let w = max(3, Int((Double(iw) * k).rounded())), h = max(3, Int((Double(ih) * k).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }
}
