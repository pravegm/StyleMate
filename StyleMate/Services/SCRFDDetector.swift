import CoreML
import CoreGraphics
import Foundation

/// InsightFace SCRFD-10G face detector (Core ML), from `buffalo_l`.
///
/// **Not bundled.** InsightFace's models are licensed for non-commercial research only; this is
/// the plug-in for `FaceModelSet.insightFaceBuffaloL`, to be used only with a signed InsightFace
/// licence (docs/MODEL-LICENSING.md §7). The shipping detector is `YuNetDetector`.
/// Input RGB, (px-127.5)/128, 640x640 letterboxed top-left; outputs 5 landmarks in ArcFace order.
final class SCRFDDetector: FaceDetecting {
    static let shared = SCRFDDetector()

    private let inputSize = 640
    private let strides = [8, 16, 32]
    private let numAnchors = 2
    private var model: MLModel?   // guarded by `lock`
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

    /// Serializes the lazy model load and every prediction: the detector is shared by the
    /// scan, manual add, the reference builder and onboarding, which run concurrently.
    private let lock = NSLock()

    /// Call with `lock` held.
    private func ensureLoadedLocked() -> MLModel? {
        if let model { return model }
        model = FaceDetectorSupport.loadModel(FaceModelProfile.insightFaceBuffaloL.detectorResource, tag: "SCRFD")
        return model
    }

    /// Detect faces. Returns each with 5 ArcFace-ordered landmarks in image pixels.
    ///
    /// `padRetry`: if the first pass finds nothing, retry on a margin-padded copy — a face
    /// that fills the whole frame (e.g. a tight selfie crop) is invisible to SCRFD, which
    /// needs the face to be a sub-region. (Verified offline: face-fills-frame crop → 0
    /// detections; +40% margin → detected.) The retry costs a second pass on a 3.2x larger
    /// image, so library / scan photos (where "no face" is the common, correct answer)
    /// must pass `padRetry: false`; keep it on for selfie frames and face crops.
    func detect(in cgImage: CGImage, scoreThreshold: Float?, padRetry: Bool) -> [DetectedFace] {
        let scoreThreshold = scoreThreshold ?? FaceModelProfile.insightFaceBuffaloL.detectorThreshold
        let faces = detectCore(in: cgImage, scoreThreshold: scoreThreshold)
        if !faces.isEmpty || !padRetry { return faces }

        let mw = max(1, cgImage.width * 2 / 5)
        let mh = max(1, cgImage.height * 2 / 5)
        guard let padded = paddedImage(cgImage, marginX: mw, marginY: mh) else { return [] }
        let padFaces = detectCore(in: padded, scoreThreshold: scoreThreshold)
        guard !padFaces.isEmpty else { return [] }
        let dx = Float(mw), dy = Float(mh)
        return padFaces.map {
            DetectedFace(boxPixels: $0.boxPixels.offsetBy(dx: -CGFloat(mw), dy: -CGFloat(mh)),
                         keypoints: $0.keypoints.map { SIMD2<Float>($0.x - dx, $0.y - dy) },
                         score: $0.score)
        }
    }

    private func detectCore(in cgImage: CGImage, scoreThreshold: Float) -> [DetectedFace] {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return [] }
        let scale = min(Float(inputSize) / Float(w), Float(inputSize) / Float(h))
        guard let input = makeInput(cgImage, scale: scale) else { return [] }   // CPU work, outside the lock
        lock.lock()
        let out: MLFeatureProvider? = {
            guard let model = ensureLoadedLocked(),
                  let provider = try? MLDictionaryFeatureProvider(
                    dictionary: [inputName(model): MLFeatureValue(multiArray: input)]) else { return nil }
            return try? model.prediction(from: provider)
        }()
        lock.unlock()
        guard let out else {
            dlog("[SCRFD] prediction failed")
            return []
        }

        var boxes: [CGRect] = []
        var kpss: [[SIMD2<Float>]] = []
        var scores: [Float] = []

        for s in strides {
            let n = (inputSize / s) * (inputSize / s) * numAnchors
            guard let scArr = FaceDetectorSupport.outputArray(out, count: n, inner: 1),
                  let bbArr = FaceDetectorSupport.outputArray(out, count: n, inner: 4),
                  let kpArr = FaceDetectorSupport.outputArray(out, count: n, inner: 10) else {
                dlog("[SCRFD] stride \(s): outputs not matched (need score[\(n),1] bbox[\(n),4] kps[\(n),10])")
                continue
            }
            let sc = FaceDetectorSupport.floats(scArr), bb = FaceDetectorSupport.floats(bbArr), kp = FaceDetectorSupport.floats(kpArr)
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

        let keep = FaceDetectorSupport.nms(boxes: boxes, scores: scores, iou: 0.4)
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

    /// Centers `cg` in a larger canvas with a zero (black) border, so a
    /// frame-filling face becomes a detectable sub-region.
    private func paddedImage(_ cg: CGImage, marginX: Int, marginY: Int) -> CGImage? {
        let w = cg.width + 2 * marginX, h = cg.height + 2 * marginY
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        // NO vertical flip: drawing a CGImage into a bitmap context WITHOUT a flip
        // already yields a top-left (upright) buffer (verified). The previous flip
        // produced upside-down images. Symmetric margins put the face at top-left
        // offset (marginX, marginY), which detect() subtracts back off.
        ctx.draw(cg, in: CGRect(x: marginX, y: marginY, width: cg.width, height: cg.height))
        return ctx.makeImage()
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
        // NO flip — see paddedImage. Drawing without a flip gives a top-left buffer;
        // the old flip made SCRFD's input upside down (low scores, garbage landmarks).
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        return pixels
    }
}
