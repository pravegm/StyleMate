import CoreGraphics
import CoreML
import Foundation

/// A detected face: pixel-space box + 5-point landmarks in the canonical ArcFace order
/// (img-left eye, img-right eye, nose tip, img-left mouth corner, img-right mouth corner)
/// + detector confidence. Box and landmarks are in original-image pixels, top-left origin.
struct DetectedFace {
    let boxPixels: CGRect            // top-left origin, image pixels
    let keypoints: [SIMD2<Float>]    // top-left pixels, ArcFace order
    let score: Float

    /// Vision-style normalized box (bottom-left origin) for mask / isolation code.
    func normalizedBox(imageWidth: Int, imageHeight: Int) -> CGRect {
        let w = CGFloat(imageWidth), h = CGFloat(imageHeight)
        guard w > 0, h > 0 else { return .zero }
        return CGRect(x: boxPixels.minX / w,
                      y: 1.0 - (boxPixels.maxY / h),
                      width: boxPixels.width / w,
                      height: boxPixels.height / h)
    }
}

/// A face detector that also returns the 5 alignment landmarks.
protocol FaceDetecting: AnyObject {
    /// `padRetry`: if the first pass finds nothing, look again for a face that fills the whole
    /// frame (selfie frames, face crops). Library / scan photos, where "no face" is the common and
    /// correct answer, pass `false` so they don't pay for a second pass.
    func detect(in cgImage: CGImage, scoreThreshold: Float?, padRetry: Bool) -> [DetectedFace]
}

extension FaceDetecting {
    func detect(in cgImage: CGImage, padRetry: Bool = true) -> [DetectedFace] {
        detect(in: cgImage, scoreThreshold: nil, padRetry: padRetry)
    }
}

/// The active detector (see `FaceModelProfile.active`). Always use this, never a concrete class:
/// landmarks from different detectors must not be mixed with an embedder calibrated on another.
enum FaceDetector {
    static var shared: FaceDetecting {
        switch FaceModelProfile.active.detector {
        case .yunet: return YuNetDetector.shared
        case .scrfd: return SCRFDDetector.shared
        }
    }
}

// MARK: - Shared helpers

enum FaceDetectorSupport {
    /// Loads a bundled Core ML model by resource name (compiled `.mlmodelc`, or an `.mlpackage`
    /// in unit-test bundles). CPU + Neural Engine only: iOS forbids GPU work in the background.
    static func loadModel(_ resource: String, tag: String) -> MLModel? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: resource, withExtension: "mlpackage") else {
            dlog("[\(tag)] ERROR: \(resource) not found in the bundle")
            return nil
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        do {
            let model = try MLModel(contentsOf: url, configuration: cfg)
            dlog("[\(tag)] \(resource) loaded")
            return model
        } catch {
            dlog("[\(tag)] ERROR: failed to load \(resource): \(error)")
            return nil
        }
    }

    /// `cg` resampled to exactly `width` x `height` as an RGBA (noneSkipLast) buffer, top-left
    /// origin. The image fills the whole context, so there is no flip / placement ambiguity.
    /// High-quality interpolation: a box/Lanczos-like filter when shrinking, like cv2.INTER_AREA.
    static func rgbaPixels(_ cg: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            // Drawing into the full context without a flip yields a top-left (upright) buffer.
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    /// Finds the output whose flattened layout is [count, inner], tolerant of leading batch dims.
    static func outputArray(_ out: MLFeatureProvider, name: String? = nil, count: Int, inner: Int) -> MLMultiArray? {
        if let name, let v = out.featureValue(for: name)?.multiArrayValue, v.count == count * inner { return v }
        for n in out.featureNames {
            if let v = out.featureValue(for: n)?.multiArrayValue,
               v.count == count * inner, (v.shape.last?.intValue ?? -1) == inner {
                return v
            }
        }
        return nil
    }

    /// Contiguous Float32 fast path; anything else (Float16 ML-program outputs, strided arrays)
    /// goes through the element accessor, which converts and respects strides.
    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        if a.dataType == .float32, (a.strides.last?.intValue ?? 0) == 1, isContiguous(a) {
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: n)
            return Array(UnsafeBufferPointer(start: p, count: n))
        }
        return (0..<n).map { a[$0].floatValue }
    }

    private static func isContiguous(_ a: MLMultiArray) -> Bool {
        var expected = 1
        for (dim, stride) in zip(a.shape.reversed(), a.strides.reversed()) {
            if dim.intValue > 1 && stride.intValue != expected { return false }
            expected *= dim.intValue
        }
        return true
    }

    static func nms(boxes: [CGRect], scores: [Float], iou: CGFloat) -> [Int] {
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        var keep: [Int] = []
        var removed = Set<Int>()
        for (oi, i) in order.enumerated() {
            if removed.contains(i) { continue }
            keep.append(i)
            for oj in (oi + 1)..<order.count {
                let j = order[oj]
                if removed.contains(j) { continue }
                if overlap(boxes[i], boxes[j]) > iou { removed.insert(j) }
            }
        }
        return keep
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
