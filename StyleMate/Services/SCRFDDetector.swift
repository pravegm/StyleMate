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
    private var loggedDiagnostics = false

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
        guard let provider = try? MLDictionaryFeatureProvider(
                dictionary: [inputName(model): MLFeatureValue(multiArray: input)]),
              let out = try? model.prediction(from: provider) else {
            print("[SCRFD] prediction failed")
            return []
        }

        let diagLogged = loggedDiagnostics
        if !diagLogged {
            loggedDiagnostics = true
            let dims = out.featureNames.compactMap { n -> String? in
                guard let a = out.featureValue(for: n)?.multiArrayValue else { return nil }
                return "\(n):\(a.shape.map{$0.intValue})/\(a.dataType.rawValue)"
            }
            print("[SCRFD] input \(cgImage.width)x\(cgImage.height) scale \(scale) | outputs \(dims)")
        }

        var boxes: [CGRect] = []
        var kpss: [[SIMD2<Float>]] = []
        var scores: [Float] = []

        for s in strides {
            let n = (inputSize / s) * (inputSize / s) * numAnchors
            guard let scArr = outputArray(out, count: n, inner: 1),
                  let bbArr = outputArray(out, count: n, inner: 4),
                  let kpArr = outputArray(out, count: n, inner: 10) else {
                print("[SCRFD] stride \(s): outputs not matched (need score[\(n),1] bbox[\(n),4] kps[\(n),10])")
                continue
            }
            let sc = floats(scArr), bb = floats(bbArr), kp = floats(kpArr)
            if !diagLogged { print("[SCRFD] stride \(s): maxScore \(sc.max() ?? -1)") }
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
    /// Rasterizes the full image with the proven top-left method, then resizes +
    /// places it at the top-left of the tensor (matching the Python reference). The
    /// prior version drew a partial-height image into a full-height flipped context,
    /// which mispositioned it in the letterbox -> SCRFD saw no face.
    private func makeInput(_ cg: CGImage, scale: Float) -> MLMultiArray? {
        let S = inputSize
        let sw = cg.width, sh = cg.height
        guard let src = rasterizeTopLeft(cg) else { return nil }
        let srcBytesPerRow = sw * 4
        let nw = min(S, Int((Float(sw) * scale).rounded()))
        let nh = min(S, Int((Float(sh) * scale).rounded()))
        guard let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)],
                                          dataType: .float32) else { return nil }
        let plane = S * S
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        // Pad value = normalized 0 px = (0-127.5)/128 (matches the Python zero canvas).
        let pad: Float = (0 - 127.5) / 128.0
        for i in 0..<(3 * plane) { p[i] = pad }
        for y in 0..<nh {
            let sy = min(Int(Float(y) / scale), sh - 1)
            let srcRow = sy * srcBytesPerRow
            let dstRow = y * S
            for x in 0..<nw {
                let sx = min(Int(Float(x) / scale), sw - 1)
                let o = srcRow + sx * 4
                let idx = dstRow + x
                p[idx]           = (Float(src[o])     - 127.5) / 128.0   // R
                p[plane + idx]   = (Float(src[o + 1]) - 127.5) / 128.0   // G
                p[2*plane + idx] = (Float(src[o + 2]) - 127.5) / 128.0   // B
            }
        }
        return arr
    }

    /// Full-size RGBA pixel buffer, top-left origin (same proven method the
    /// embedder's warp uses).
    private func rasterizeTopLeft(_ cg: CGImage) -> [UInt8]? {
        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return pixels
    }

    // MARK: - Output helpers

    /// Finds the output whose flattened layout is [count, inner], tolerant of any
    /// leading batch dims (e.g. [N,inner] or [1,N,inner]). The (count, inner) pair
    /// is unique per output even when totals collide (e.g. 12800x1 vs 3200x4).
    private func outputArray(_ out: MLFeatureProvider, count: Int, inner: Int) -> MLMultiArray? {
        for name in out.featureNames {
            if let v = out.featureValue(for: name)?.multiArrayValue,
               v.count == count * inner, (v.shape.last?.intValue ?? -1) == inner {
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
