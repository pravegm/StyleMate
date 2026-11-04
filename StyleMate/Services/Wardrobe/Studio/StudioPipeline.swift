import CoreGraphics
import CoreImage
import UIKit
import Vision

/// The on-device image generator the studio pipeline drives (Stable Diffusion
/// on the Neural Engine — `StudioRenderer`). A protocol so the pipeline can be
/// tested and so nothing here depends on how the model is packaged.
protocol StudioImageGenerating: AnyObject {
    var isAvailable: Bool { get }
    /// `startingImage` nil = text-to-image; otherwise image-to-image at `strength`.
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seed: UInt32) -> CGImage?
    /// Frees the ~1 GB pipeline after a batch.
    func unload()
}

/// Turns a wardrobe item into a lifelike catalog image, fully on-device:
///   1. plan (generate a flat-lay from the description, or refine the cutout),
///   2. render a few candidates with the on-device diffusion model,
///   3. cut each candidate out of its white background (largest object only —
///      drops props the model sometimes adds), colour-match it to the real
///      garment, and score it: FashionSigLIP similarity to the user's actual
///      item, minus penalties for any body/mannequin and for being cut off,
///   4. keep the best — or nothing, if no candidate is convincingly the same
///      item (the clean cutout then stays as the item's image).
enum StudioPipeline {
    static var generator: StudioImageGenerating?

    struct Result {
        let image: UIImage
        let score: Float
        let similarity: Float
    }

    /// Below this FashionSigLIP similarity to the real item, a render is a
    /// different garment and is rejected (experiments: good renders 0.68–0.80).
    static var minSimilarity: Float = 0.6

    static func studioImage(cutout: UIImage, embedding: [Float], plan: StudioPlan, seedBase: UInt32) -> Result? {
        guard let gen = generator, gen.isAvailable, let cg = cutout.cgImage,
              let start = FashionClassifier.onWhite(cg, side: 512) else { return nil }
        let reference = ColorStats(cg)
        var best: Result?
        for k in 0..<max(1, plan.candidates) {
            let seed = seedBase &+ UInt32(k) &* 7919
            let raw: CGImage?
            switch plan.mode {
            case .generate:
                raw = gen.render(startingImage: nil, prompt: plan.prompt, negativePrompt: plan.negativePrompt,
                                 strength: 1, steps: StudioPlan.steps, guidance: StudioPlan.guidance, seed: seed)
            case .refine(let strength):
                raw = gen.render(startingImage: start, prompt: plan.prompt, negativePrompt: plan.negativePrompt,
                                 strength: strength, steps: StudioPlan.steps, guidance: StudioPlan.guidance, seed: seed)
            }
            guard let raw, let candidate = autoreleasepool(invoking: { evaluate(raw, reference: reference, embedding: embedding) })
            else { continue }
            print("[Studio] candidate \(k): score=\(String(format: "%.3f", candidate.score)) sim=\(String(format: "%.3f", candidate.similarity))")
            if best == nil || candidate.score > best!.score { best = candidate }
        }
        guard let b = best, b.similarity >= minSimilarity else {
            print("[Studio] no convincing render (best sim \(best.map { String(format: "%.3f", $0.similarity) } ?? "-")); keeping the cutout")
            return nil
        }
        return b
    }

    // MARK: - Candidate evaluation

    static func evaluate(_ render: CGImage, reference: ColorStats?, embedding: [Float]) -> Result? {
        guard let cut = isolateProduct(render) else { return nil }
        var image = cut.image
        if let ref = reference, let matched = ColorStats.match(image, to: ref) { image = matched }
        let framed = GarmentCutout.frame(image)
        guard let fcg = framed.cgImage, let onWhite = FashionClassifier.onWhite(fcg, side: 224),
              let e = WardrobeML.shared.embed(onWhite) else { return nil }
        let sim = WardrobeExtractor.cosine(e, embedding)
        let body = bodyFraction(render)
        let score = sim - 0.6 * body - (cut.touchesFrame ? 0.12 : 0)
        return Result(image: framed, score: score, similarity: sim)
    }

    /// The product, without its white background: Vision's foreground instance
    /// mask on device (largest instance only), or white-keying where Vision
    /// isn't available (simulator).
    static func isolateProduct(_ render: CGImage) -> (image: CGImage, touchesFrame: Bool)? {
        let w = render.width, h = render.height
        guard var px = GarmentCutout.rgbaPixels(render) else { return nil }
        var alpha = visionMask(render) ?? whiteKeyMask(px, w: w, h: h)
        keepLargestComponent(&alpha, w: w, h: h)
        var any = false, touches = false
        for y in 0..<h {
            for x in 0..<w {
                let a = alpha[y * w + x]
                guard a > 0 else { continue }
                any = true
                if a > 128 && (x <= 1 || y <= 1 || x >= w - 2 || y >= h - 2) { touches = true }
            }
        }
        guard any else { return nil }
        for i in 0..<(w * h) {
            let a = Float(alpha[i]) / 255
            px[i * 4] = UInt8(Float(px[i * 4]) * a)
            px[i * 4 + 1] = UInt8(Float(px[i * 4 + 1]) * a)
            px[i * 4 + 2] = UInt8(Float(px[i * 4 + 2]) * a)
            px[i * 4 + 3] = alpha[i]
        }
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let img = ctx.makeImage() else { return nil }
        return (img, touches)
    }

    private static func visionMask(_ image: CGImage) -> [UInt8]? {
        #if targetEnvironment(simulator)
        return nil   // Vision's foreground masks need the Neural Engine
        #else
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let obs = request.results?.first,
              let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) else { return nil }
        let w = image.width, h = image.height
        guard CVPixelBufferGetWidth(buffer) == w, CVPixelBufferGetHeight(buffer) == h else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.stride
        let p = base.assumingMemoryBound(to: Float32.self)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { out[y * w + x] = UInt8(min(max(p[y * stride + x], 0), 1) * 255) } }
        return out
        #endif
    }

    /// Background = near-white pixels connected to the image border.
    static func whiteKeyMask(_ px: [UInt8], w: Int, h: Int) -> [UInt8] {
        func isBG(_ i: Int) -> Bool { px[i * 4] > 232 && px[i * 4 + 1] > 232 && px[i * 4 + 2] > 232 }
        var bg = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        for x in 0..<w { stack.append(x); stack.append((h - 1) * w + x) }
        for y in 0..<h { stack.append(y * w); stack.append(y * w + w - 1) }
        while let i = stack.popLast() {
            guard !bg[i], isBG(i) else { continue }
            bg[i] = true
            let x = i % w, y = i / w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if y > 0 { stack.append(i - w) }
            if y < h - 1 { stack.append(i + w) }
        }
        return bg.map { $0 ? 0 : 255 }
    }

    private static func keepLargestComponent(_ alpha: inout [UInt8], w: Int, h: Int) {
        let bin = alpha.map { $0 > 128 ? UInt8(1) : UInt8(0) }
        let (comp, sizes) = GarmentSegmenter.components(bin, w: w, h: h)
        guard let largest = sizes.max(), let id = sizes.firstIndex(of: largest).map({ $0 + 1 }) else { return }
        // Keep the main object and anything at least a third its size (the second
        // shoe of a pair); drop props.
        let keep = Set(sizes.enumerated().filter { $0.offset + 1 == id || $0.element * 3 >= largest }.map { $0.offset + 1 })
        for i in 0..<(w * h) where bin[i] == 1 && !keep.contains(comp[i]) { alpha[i] = 0 }
    }

    /// Share of person/mannequin pixels (face, hair, arms, hands, legs, torso)
    /// relative to clothing pixels in a render, from the garment parser.
    static func bodyFraction(_ render: CGImage) -> Float {
        let gw = WardrobeML.gridW, gh = WardrobeML.gridH
        guard let ctx = CGContext(data: nil, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return 0 }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: gw, height: gh))
        let side = CGFloat(gw)
        ctx.draw(render, in: CGRect(x: 0, y: (CGFloat(gh) - side) / 2, width: side, height: side))
        guard let img = ctx.makeImage(), let parsed = WardrobeML.shared.parse(img) else { return 0 }
        let body: Set<UInt8> = [1, 2, 12, 13, 14, 16]   // face, hair, arms, hands, legs, torso
        var b = 0, c = 0
        for l in parsed.labels where l != 0 { if body.contains(l) { b += 1 } else { c += 1 } }
        return c + b == 0 ? 0 : Float(b) / Float(b + c)
    }
}

/// Lab colour statistics of an item's opaque pixels, for matching a render's
/// colours to the real garment (a prompt says "burgundy"; the shirt is its own
/// exact red).
struct ColorStats {
    let mean: (Float, Float, Float)
    let std: (Float, Float, Float)

    init?(_ image: CGImage) {
        guard let px = GarmentCutout.rgbaPixels(image) else { return nil }
        var s: [(Float, Float, Float)] = []
        let n = image.width * image.height
        let step = max(1, n / 20000)
        var i = 0
        while i < n {
            let a = Float(px[i * 4 + 3]) / 255
            if a > 0.9 { s.append(ColorNamer.lab(Float(px[i * 4]) / 255 / a, Float(px[i * 4 + 1]) / 255 / a, Float(px[i * 4 + 2]) / 255 / a)) }
            i += step
        }
        guard s.count > 50 else { return nil }
        let m = s.reduce((Float(0), Float(0), Float(0))) { ($0.0 + $1.0, $0.1 + $1.1, $0.2 + $1.2) }
        let c = Float(s.count)
        mean = (m.0 / c, m.1 / c, m.2 / c)
        let v = s.reduce((Float(0), Float(0), Float(0))) {
            ($0.0 + pow($1.0 - m.0 / c, 2), $0.1 + pow($1.1 - m.1 / c, 2), $0.2 + pow($1.2 - m.2 / c, 2))
        }
        std = (sqrt(v.0 / c) + 1e-3, sqrt(v.1 / c) + 1e-3, sqrt(v.2 / c) + 1e-3)
    }

    /// Shifts (and partly rescales) the image's Lab statistics toward `ref`.
    /// Chroma moves most, lightness least (a render's studio light is the point).
    static func match(_ image: CGImage, to ref: ColorStats) -> CGImage? {
        guard let src = ColorStats(image), var px = GarmentCutout.rgbaPixels(image) else { return nil }
        let w = image.width, h = image.height
        let kL: Float = 0.35, kAB: Float = 0.75
        for i in 0..<(w * h) {
            let a = Float(px[i * 4 + 3]) / 255
            guard a > 0.01 else { continue }
            var (L, A, B) = ColorNamer.lab(Float(px[i * 4]) / 255 / a, Float(px[i * 4 + 1]) / 255 / a, Float(px[i * 4 + 2]) / 255 / a)
            let tL = (L - src.mean.0) * (ref.std.0 / src.std.0) + ref.mean.0
            let tA = (A - src.mean.1) * min(2, ref.std.1 / src.std.1) + ref.mean.1
            let tB = (B - src.mean.2) * min(2, ref.std.2 / src.std.2) + ref.mean.2
            L += (tL - L) * kL; A += (tA - A) * kAB; B += (tB - B) * kAB
            let (r, g, b) = labToRGB(L, A, B)
            px[i * 4] = UInt8(min(max(r * a * 255, 0), 255))
            px[i * 4 + 1] = UInt8(min(max(g * a * 255, 0), 255))
            px[i * 4 + 2] = UInt8(min(max(b * a * 255, 0), 255))
        }
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        return ctx.makeImage()
    }

    static func labToRGB(_ L: Float, _ A: Float, _ B: Float) -> (Float, Float, Float) {
        let fy = (L + 16) / 116, fx = fy + A / 500, fz = fy - B / 200
        func finv(_ t: Float) -> Float { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16 / 116) / 7.787 }
        let x = finv(fx) * 0.95047, y = finv(fy), z = finv(fz) * 1.08883
        var r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        var g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        var b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        func gam(_ c: Float) -> Float { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055 }
        r = gam(r); g = gam(g); b = gam(b)
        return (min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1))
    }
}
