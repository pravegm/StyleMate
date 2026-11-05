import CoreGraphics
import CoreML
import Foundation

/// YuNet 2023mar face detector (OpenCV Zoo, MIT licence), Core ML.
///
/// - Input: [1, 3, 640, 640] float, **BGR**, raw 0…255 (no normalization), the image letterboxed
///   into the top-left with black padding. (OpenCV's FaceDetectorYN contract.)
/// - Output, per stride 8 / 16 / 32 (one prior per cell, anchor-free): `cls_s`, `obj_s` [N, 1],
///   `bbox_s` [N, 4] = (dx, dy, log w, log h) in stride units, `kps_s` [N, 10] = 5 (dx, dy).
///   Score = sqrt(cls · obj).
/// - Landmarks come out as right eye, left eye, nose tip, right mouth corner, left mouth corner
///   of the *subject*, i.e. image-left first: already the canonical ArcFace order `warpAligned`
///   expects (OpenCV's `FaceRecognizerSF.alignCrop` feeds them to the same template).
/// - Trained for faces of about 10–300 px at the input scale. A face that fills a 640 px frame
///   is bigger than that, so the selfie retry shrinks the image into a smaller part of the input.
final class YuNetDetector: FaceDetecting {
    static let shared = YuNetDetector()

    private let inputSize = 640
    private let strides = [8, 16, 32]
    private var model: MLModel?   // guarded by `lock`
    /// Serializes the lazy load and every prediction (scan, manual add, onboarding run concurrently).
    private let lock = NSLock()

    private init() {}

    private var profile: FaceModelProfile { .active }

    /// Library photos at least this big also get the small-face tile pass.
    static let tileMinSide = 1100

    func detect(in cgImage: CGImage, scoreThreshold: Float?, padRetry: Bool) -> [DetectedFace] {
        let threshold = scoreThreshold ?? profile.detectorThreshold
        let faces = detectCore(in: cgImage, fit: inputSize, threshold: threshold)
        if !padRetry {
            // Library / scan photo. A 1600 px photo letterboxed to 640 shrinks a 48 px face to
            // 19 px, at the edge of YuNet's range: look again at four overlapping 60% tiles, each
            // at the full input (faces ~2.5x bigger). On LFW faces pasted into 1600 px frames this
            // took misses from 5.6% to 0% and TAR at FAR 1e-5 from 79% to 94%
            // (docs/MODEL-LICENSING.md §8). Faces found twice are merged by NMS.
            guard max(cgImage.width, cgImage.height) >= Self.tileMinSide else { return faces }
            return mergeWithTiles(faces, in: cgImage, threshold: threshold)
        }
        if !faces.isEmpty { return faces }
        // A frame-filling face (selfie frame, tight face crop) is over YuNet's ~300 px range at
        // 640: place the image in a smaller square of the input (the rest stays black, which is
        // the same as padding it) and look again.
        for fit in [352, 224] {
            let retry = detectCore(in: cgImage, fit: fit, threshold: threshold)
            if !retry.isEmpty { return retry }
        }
        return []
    }

    private func mergeWithTiles(_ full: [DetectedFace], in cgImage: CGImage, threshold: Float) -> [DetectedFace] {
        let w = cgImage.width, h = cgImage.height
        let tw = w * 3 / 5, th = h * 3 / 5
        var extra: [DetectedFace] = []
        for (ox, oy) in [(0, 0), (w - tw, 0), (0, h - th), (w - tw, h - th)] {
            let tileRect = CGRect(x: ox, y: oy, width: tw, height: th)
            guard let tile = cgImage.cropping(to: tileRect) else { continue }
            let dx = Float(ox), dy = Float(oy)
            // Inner tile edges (not the photo's own edges): a face cut there is a partial view; the
            // overlapping tile or the full pass sees it whole.
            let inner = tileRect.insetBy(dx: 2, dy: 2)
            for f in detectCore(in: tile, fit: inputSize, threshold: threshold) {
                let box = f.boxPixels.offsetBy(dx: CGFloat(ox), dy: CGFloat(oy))
                let cutLeft = box.minX < inner.minX && tileRect.minX > 0
                let cutTop = box.minY < inner.minY && tileRect.minY > 0
                let cutRight = box.maxX > inner.maxX && tileRect.maxX < CGFloat(w)
                let cutBottom = box.maxY > inner.maxY && tileRect.maxY < CGFloat(h)
                if cutLeft || cutTop || cutRight || cutBottom { continue }
                extra.append(DetectedFace(boxPixels: box,
                                          keypoints: f.keypoints.map { SIMD2<Float>($0.x + dx, $0.y + dy) },
                                          score: f.score))
            }
        }
        // One face seen by the full pass and a tile is merged by NMS, keeping the higher score:
        // usually the tile's, whose landmarks come from 2.5x the pixels (keeping the full pass's
        // instead cost 10 points of TAR on small faces). A face must never count twice: it would
        // be its own "runner-up" in a group photo. Cut faces are already gone (above).
        let all = full + extra
        let keep = FaceDetectorSupport.nms(boxes: all.map(\.boxPixels), scores: all.map(\.score), iou: 0.3)
        return keep.map { all[$0] }
    }

    /// Letterboxes `cgImage` into the top-left `fit` x `fit` of the 640 input and decodes.
    private func detectCore(in cgImage: CGImage, fit: Int, threshold: Float) -> [DetectedFace] {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return [] }
        let scale = min(Float(fit) / Float(w), Float(fit) / Float(h))
        let nw = max(1, min(fit, Int((Float(w) * scale).rounded())))
        let nh = max(1, min(fit, Int((Float(h) * scale).rounded())))
        guard let input = makeInput(cgImage, width: nw, height: nh) else { return [] }   // outside the lock

        lock.lock()
        let out: MLFeatureProvider? = {
            if model == nil { model = FaceDetectorSupport.loadModel(profile.detectorResource, tag: "YuNet") }
            guard let model,
                  let provider = try? MLDictionaryFeatureProvider(
                    dictionary: [inputName(model): MLFeatureValue(multiArray: input)]) else { return nil }
            return try? model.prediction(from: provider)
        }()
        lock.unlock()
        guard let out else {
            dlog("[YuNet] prediction failed")
            return []
        }

        // Scale factors from the letterboxed input back to the original image.
        let sx = Float(w) / Float(nw), sy = Float(h) / Float(nh)
        var boxes: [CGRect] = []
        var kpss: [[SIMD2<Float>]] = []
        var scores: [Float] = []
        for s in strides {
            let cols = inputSize / s
            let n = cols * cols
            guard let clsA = FaceDetectorSupport.outputArray(out, name: "cls_\(s)", count: n, inner: 1),
                  let objA = FaceDetectorSupport.outputArray(out, name: "obj_\(s)", count: n, inner: 1),
                  let bbA = FaceDetectorSupport.outputArray(out, name: "bbox_\(s)", count: n, inner: 4),
                  let kpA = FaceDetectorSupport.outputArray(out, name: "kps_\(s)", count: n, inner: 10) else {
                dlog("[YuNet] stride \(s): outputs not found")
                continue
            }
            let cls = FaceDetectorSupport.floats(clsA), obj = FaceDetectorSupport.floats(objA)
            let bb = FaceDetectorSupport.floats(bbA), kp = FaceDetectorSupport.floats(kpA)
            let fs = Float(s)
            for i in 0..<n {
                let score = (min(max(cls[i], 0), 1) * min(max(obj[i], 0), 1)).squareRoot()
                guard score >= threshold else { continue }
                let r = Float(i / cols), c = Float(i % cols)
                let cx = (c + bb[i * 4]) * fs, cy = (r + bb[i * 4 + 1]) * fs
                let bw = exp(bb[i * 4 + 2]) * fs, bh = exp(bb[i * 4 + 3]) * fs
                boxes.append(CGRect(x: CGFloat((cx - bw / 2) * sx), y: CGFloat((cy - bh / 2) * sy),
                                    width: CGFloat(bw * sx), height: CGFloat(bh * sy)))
                var pts: [SIMD2<Float>] = []
                pts.reserveCapacity(5)
                for j in 0..<5 {
                    pts.append(SIMD2<Float>((kp[i * 10 + 2 * j] + c) * fs * sx,
                                            (kp[i * 10 + 2 * j + 1] + r) * fs * sy))
                }
                kpss.append(pts)
                scores.append(score)
            }
        }
        let keep = FaceDetectorSupport.nms(boxes: boxes, scores: scores, iou: 0.3)
        return keep.map { DetectedFace(boxPixels: boxes[$0], keypoints: kpss[$0], score: scores[$0]) }
    }

    private func inputName(_ model: MLModel) -> String {
        model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
    }

    /// [1, 3, 640, 640] BGR raw 0…255, the image resampled to `width` x `height` at the top-left,
    /// zeros elsewhere.
    private func makeInput(_ cg: CGImage, width: Int, height: Int) -> MLMultiArray? {
        let S = inputSize
        guard let src = FaceDetectorSupport.rgbaPixels(cg, width: width, height: height),
              let arr = try? MLMultiArray(shape: [1, 3, NSNumber(value: S), NSNumber(value: S)], dataType: .float32)
        else { return nil }
        let plane = S * S
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * plane)
        p.initialize(repeating: 0, count: 3 * plane)
        for y in 0..<height {
            let srcRow = y * width * 4
            let dstRow = y * S
            for x in 0..<width {
                let o = srcRow + x * 4
                let idx = dstRow + x
                p[idx]             = Float(src[o + 2])   // B
                p[plane + idx]     = Float(src[o + 1])   // G
                p[2 * plane + idx] = Float(src[o])       // R
            }
        }
        return arr
    }
}
