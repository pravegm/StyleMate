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
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([humans])
        return (humans.results ?? []).contains { $0.confidence > 0.5 }
    }

    /// Full signals for picking the best frame of a burst.
    static func signals(for image: CGImage) -> ThumbnailSignals {
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([humans, faces])
        let people = (humans.results ?? []).filter { $0.confidence > 0.5 }
        guard !people.isEmpty else { return ThumbnailSignals(hasPerson: false) }
        let body = people.map { Double($0.boundingBox.height) }.max() ?? 0
        let face = (faces.results ?? []).map { Double($0.boundingBox.width * $0.boundingBox.height) }.max() ?? 0
        return ThumbnailSignals(hasPerson: true, bodyHeight: body, faceArea: face,
                                sharpness: sharpness(of: image))
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
