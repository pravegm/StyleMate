import CoreML
import CoreGraphics
import Foundation

/// A face detected by SCRFD: pixel-space box + 5-point landmarks (in the canonical
/// ArcFace order img-left-eye, img-right-eye, nose, img-left-mouth, img-right-mouth)
/// + detector confidence. Landmarks are in original-image pixel coords (top-left).
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

/// InsightFace SCRFD-10G face detector (Core ML). Replaces Apple Vision's
/// landmarks, which were too imprecise for ArcFace/AdaFace alignment. Verified
/// offline: SCRFD landmarks → AdaFace same-person 0.988 (vs ~0.2 with Vision).
final class SCRFDDetector {
    static let shared = SCRFDDetector()

    private let inputSize = 640
    private let strides = [8, 16, 32]
    private let numAnchors = 2
    private var model: MLModel?
    private var anchorCenters: [Int: [(Float, Float)]] = [:]

    private init() {
        for s in strides { anchorCenters[s] = Self.makeAnchors(stride: s, size: inputSize) }
    }

    private static func makeAnchors(stride: Int, size: Int) -> [(Float, Float)] {
        let hw = size / stride
        var centers: [(Float, Float)] = []
        centers.reserveCapacity(hw * hw * 2)
        for y in 0..<hw {
            for x in 0..<hw {
                let cx = Float(x * stride), cy = Float(y * stride)
                centers.append((cx, cy))   // anchor 0
                centers.append((cx, cy))   // anchor 1 (2 anchors per location)
            }
        }
        return centers
    }

    private func ensureLoaded() -> Bool {
        if model != nil { return true }
        guard let url = Bundle.main.url(forResource: "SCRFD10G", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "SCRFD10G", withExtension: "mlpackage") else {
            print("[SCRFD] ERROR: SCRFD10G model not found in bundle")
            return false
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try? MLModel(contentsOf: url, configuration: cfg)
        if model == nil { print("[SCRFD] ERROR: failed to load model") }
        else { print("[SCRFD] detector loaded") }
        return model != nil
    }

    /// Detect faces. Returns each with 5 ArcFace-ordered landmarks in image pixels.
    func detect(in cgImage: CGImage, scoreThreshold: Float = 0.5) -> [DetectedFace] {
        guard ensureLoaded(), let model else { return [] }
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return [] }
        let scale = min(Float(inputSize) / Float(w), Float(inputSize) / Float(h))
        guard let input = makeInput(cgImage, scale: scale) else { return [] }
        guard let out = try? model.prediction(from: try! MLDictionaryFeatureProvider(
            dictionary: [inputName(model): MLFeatureValue(multiArray: input)])) else { return [] }

        var boxes: [CGRect] = []
        var kpss: [[SIMD2<Float>]] = []
        var scores: [Float] = []

        for s in strides {
            let n = (inputSize / s) * (inputSize / s) * numAnchors
            guard let scArr = outputArray(out, count: n, inner: 1),
                  let bbArr = outputArray(out, count: n, inner: 4),
                  let kpArr = outputArray(out, count: n, inner: 10) else { continue }
            let sc = floats(scArr), bb = floats(bbArr), kp = floats(kpArr)
            let ac = anchorCenters[s]!
            let fs = Float(s)
            for i in 0..<n where sc[i] >= scoreThreshold {
                let (cx, cy) = ac[i]
                let x1 = (cx - bb[i*4+0]*fs) / scale
                let y1 = (cy - bb[i*4+1]*fs) / scale
                let x2 = (cx + bb[i*4+2]*fs) / scale
                let y2 = (cy + bb[i*4+3]*fs) / scale
                var pts: [SIMD2<Float>] = []
                pts.reserveCapacity(5)
                for j in 0..<5 {
                    let px = (cx + kp[i*10+j*2]   * fs) / scale
                    let py = (cy + kp[i*10+j*2+1] * fs) / scale
                    pts.append(SIMD2<Float>(px, py))
                }
                boxes.append(CGRect(x: CGFloat(x1), y: CGFloat(y1),
                                    width: CGFloat(x2-x1), height: CGFloat(y2-y1)))
                kpss.append(pts)
                scores.append(sc[i])
            }
        }

        let keep = nms(boxes: boxes, scores: scores, iou: 0.4)
        return keep.map { DetectedFace(boxPixels: boxes[$0], keypoints: kpss[$0], score: scores[$0]) }
    }

    // MARK: - Input

    private func inputName(_ model: MLModel) -> String {
        model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
    }

    /// 640x640 letterboxed (top-left, zero-pad) RGB tensor, normalized (x-127.5)/128.
    private func makeInput(_ cg: CGImage, scale: Float) -> MLMultiArray? {
        let S = inputSize
        let nw = Int((Float(cg.width)  * scale).rounded())
        let nh = Int((Float(cg.height) * scale).rounded())
        let bytesPerRow = S * 4
        var buf = [UInt8](repeating: 0, count: S * bytesPerRow)
        let made: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: S, height: S, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            // CG draws bottom-left origin; flip so (0,0) lands at the buffer's TOP-left.
            ctx.translateBy(x: 0, y: CGFloat(S))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(nw), height: CGFloat(nh)))
            return true
        }
        guard made,
              let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)],
                                          dataType: .float32) else { return nil }
        let plane = S * S
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        for y in 0..<S {
            let row = y * bytesPerRow
            for x in 0..<S {
                let o = row + x * 4
                let idx = y * S + x
                p[idx]           = (Float(buf[o])     - 127.5) / 128.0   // R
                p[plane + idx]   = (Float(buf[o + 1]) - 127.5) / 128.0   // G
                p[2*plane + idx] = (Float(buf[o + 2]) - 127.5) / 128.0   // B
            }
        }
        return arr
    }

    // MARK: - Output helpers

    private func outputArray(_ out: MLFeatureProvider, count: Int, inner: Int) -> MLMultiArray? {
        for name in out.featureNames {
            if let v = out.featureValue(for: name)?.multiArrayValue,
               v.shape.count == 2, v.shape[0].intValue == count, v.shape[1].intValue == inner {
                return v
            }
        }
        return nil
    }

    private func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.bindMemory(to: Float.self, capacity: n)
            return Array(UnsafeBufferPointer(start: p, count: n))
        case .float16:
            let p = a.dataPointer.bindMemory(to: Float16.self, capacity: n)
            return (0..<n).map { Float(p[$0]) }
        default:
            return (0..<n).map { a[$0].floatValue }
        }
    }

    // MARK: - NMS

    private func nms(boxes: [CGRect], scores: [Float], iou: CGFloat) -> [Int] {
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        var keep: [Int] = []
        var removed = Set<Int>()
        for (oi, i) in order.enumerated() {
            if removed.contains(i) { continue }
            keep.append(i)
            for oj in (oi+1)..<order.count {
                let j = order[oj]
                if removed.contains(j) { continue }
                if overlap(boxes[i], boxes[j]) > iou { removed.insert(j) }
            }
        }
        return keep
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}
