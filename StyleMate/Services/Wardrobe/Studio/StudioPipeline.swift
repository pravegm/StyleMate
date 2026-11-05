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
    /// Several seeds with one model load (much faster than one call per seed).
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seeds: [UInt32]) -> [CGImage?]
    /// Frees the ~1 GB pipeline after a batch.
    func unload()
    /// Stops in-flight renders as soon as possible (they return nil).
    func cancelRenders()
}

extension StudioImageGenerating {
    func cancelRenders() {}
    func render(startingImage: CGImage?, prompt: String, negativePrompt: String,
                strength: Float, steps: Int, guidance: Float, seeds: [UInt32]) -> [CGImage?] {
        seeds.map { render(startingImage: startingImage, prompt: prompt, negativePrompt: negativePrompt,
                           strength: strength, steps: steps, guidance: guidance, seed: $0) }
    }
}

/// The real on-device diffusion renderer (Services/Studio/StudioRenderer).
extension StudioRenderer: StudioImageGenerating {}

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
    /// The bundled on-device renderer; tests swap in a fake.
    static var generator: StudioImageGenerating? = StudioRenderer.shared

    struct Result {
        let image: UIImage
        let score: Float
        let similarity: Float
    }

    /// Everything measured about one render, accepted or not (logged, and saved
    /// by the tests for review).
    struct Candidate {
        /// The isolated, colour-matched, framed product.
        let image: UIImage
        let score: Float
        let similarity: Float
        let body: Float
        /// Zero-shot score of the planned product label (and of "Solid" for plain items).
        let product: Float
        let plain: Float
        /// Best "this is a bad render" prompt minus the product prompt (> 0 = looks like a failure).
        let qcMargin: Float
        let touchesFrame: Bool
        let coverage: Float
        /// Second-largest separate object relative to the product.
        let secondObject: Float
        /// Largest near-white blob inside the product, as a share of it.
        let whitePanel: Float
        /// The render's own colour (before colour matching) against the item's:
        /// mean lightness difference and mean a/b distance in CIELAB.
        var colourDriftL: Float = 0
        var colourDriftAB: Float = 0
        /// The render's top zero-shot product in the planned product's group.
        var bestProduct: String = ""
        var bestProductScore: Float = 0
        /// Why it can't be used (nil = acceptable).
        let rejection: String?

        var summary: [String: Any] {
            ["score": score, "similarity": similarity, "body": body, "product": product, "plain": plain,
             "qcMargin": qcMargin, "touchesFrame": touchesFrame, "coverage": coverage,
             "secondObject": secondObject, "whitePanel": whitePanel, "colourDriftL": colourDriftL,
             "colourDriftAB": colourDriftAB, "bestProduct": bestProduct, "bestProductScore": bestProductScore,
             "rejection": rejection ?? ""]
        }
    }

    enum Outcome {
        case rendered(Result)
        /// Renders were made but none is convincingly the same item (keep the cutout).
        case rejected(bestSimilarity: Float?)
        /// Nothing was rendered (models missing, cancelled, inference error): try again later.
        case failed
    }

    /// FashionSigLIP similarity to the real item a render must reach. Measured
    /// on the lab sheets: failed tees 0.646–0.669, good renders 0.69–0.78
    /// (text-to-image); a refine starts from the cutout itself, so it must stay
    /// much closer to it. Similarity alone doesn't catch a person wearing the
    /// garment (0.75 in the lab) — the body check does.
    static var minSimilarityGenerate: Float = 0.70
    static var minSimilarityRefine: Float = 0.80
    /// Template-guided renders already carry the garment's own fabric and
    /// layout. Against the worn, partly hidden cutout, good template renders
    /// scored 0.59–0.74 (13 lab renders, Nov 2026: coats 0.59, a tee seen
    /// between jacket halves 0.63), so their bar only rules out a different
    /// garment; the hard checks (body, second object, panel, frame) gate.
    static var minSimilarityTemplate: Float = 0.55

    /// Reject a generated render whose best "failed render" prompt (a person
    /// wearing it, a stack, a flat lay with props, a white panel) comes within
    /// this of the product prompt. Lab calibration (Nov 2026): renders of a
    /// person -0.050…-0.031, good catalog renders -0.110…-0.061.
    static var qcMarginReject: Float = -0.045

    /// A product-shot template render (shoes, hats, trousers) starts from the
    /// item's own fabric, so its colour stays close (lab, Nov 2026: |ΔL| ≤ 13, Δab ≤ 7 over shoes, a cap, trousers).
    /// FashionSigLIP similarity barely sees colour between a single side-view
    /// shoe and a worn pair (a black-sneaker render scored higher against a
    /// white sneaker than against its own), so a render that drifted this far
    /// is rejected rather than trusted to colour matching.
    static var maxColourDriftL: Float = 28
    static var maxColourDriftAB: Float = 16

    static func minSimilarity(for plan: StudioPlan) -> Float {
        if case .generate = plan.mode { return plan.template == nil ? minSimilarityGenerate : minSimilarityTemplate }
        return minSimilarityRefine
    }

    /// Back-compat wrapper: the accepted render, or nil.
    static func studioImage(cutout: UIImage, embedding: [Float], plan: StudioPlan, seedBase: UInt32) -> Result? {
        if case .rendered(let r) = studioOutcome(cutout: cutout, embedding: embedding, plan: plan, seedBase: seedBase) { return r }
        return nil
    }

    /// Renders `plan.candidates` images and returns the best acceptable one.
    /// `onCandidate` sees every raw render and its evaluation (nil = nothing separable).
    static func studioOutcome(cutout: UIImage, embedding: [Float], plan: StudioPlan, seedBase: UInt32,
                              onCandidate: ((Int, CGImage, Candidate?) -> Void)? = nil) -> Outcome {
        guard let gen = generator, gen.isAvailable, let cg = cutout.cgImage,
              let start = FashionClassifier.onWhite(cg, side: 512) else { return .failed }
        let reference = ColorStats(cg)
        let seeds = (0..<max(1, plan.candidates)).map { seedBase &+ UInt32($0) &* 7919 }
        let renders: [CGImage?]
        switch plan.mode {
        case .generate:
            renders = gen.render(startingImage: plan.template, prompt: plan.prompt, negativePrompt: plan.negativePrompt,
                                 strength: plan.template == nil ? 1 : plan.templateStrength, steps: StudioPlan.steps,
                                 guidance: StudioPlan.guidance, seeds: seeds)
        case .refine(let strength):
            renders = gen.render(startingImage: start, prompt: plan.prompt, negativePrompt: plan.negativePrompt,
                                 strength: strength, steps: StudioPlan.steps, guidance: StudioPlan.guidance, seeds: seeds)
        }
        guard renders.contains(where: { $0 != nil }) else { return .failed }
        let minSim = minSimilarity(for: plan)
        var best: Candidate?, bestSim: Float?
        for (k, raw) in renders.enumerated() {
            guard let raw else { continue }
            let c = autoreleasepool(invoking: { evaluate(raw, reference: reference, embedding: embedding, plan: plan, minSimilarity: minSim) })
            onCandidate?(k, raw, c)
            guard let c else {
                print("[Studio] candidate \(k): nothing separable")
                continue
            }
            print("[Studio] candidate \(k): score=\(String(format: "%.3f", c.score)) sim=\(String(format: "%.3f", c.similarity))" +
                  (c.rejection.map { " REJECT \($0)" } ?? ""))
            bestSim = max(bestSim ?? -1, c.similarity)
            guard c.rejection == nil else { continue }
            if best == nil || c.score > best!.score { best = c }
        }
        guard let b = best else {
            print("[Studio] no convincing render (best sim \(bestSim.map { String(format: "%.3f", $0) } ?? "-")); keeping the cutout")
            return .rejected(bestSimilarity: bestSim)
        }
        return .rendered(Result(image: b.image, score: b.score, similarity: b.similarity))
    }

    // MARK: - Candidate evaluation

    /// Renders whose product is two separate objects: a pair of shoes refined
    /// from the worn pair. A shoe template asks for ONE shoe, so a second shoe
    /// there is a second object (the closet keeps one look).
    private static func isPaired(_ plan: StudioPlan) -> Bool { plan.productLabel.hasPrefix("Footwear|") && plan.template == nil }

    /// Returns the measured candidate (with a `rejection` reason when it fails a
    /// hard check), or nil when nothing is separable from the background.
    static func evaluate(_ render: CGImage, reference: ColorStats?, embedding: [Float], plan: StudioPlan? = nil,
                         minSimilarity: Float = 0) -> Candidate? {
        guard let cut = isolateProduct(render, keepPairs: plan.map(isPaired) ?? true) else { return nil }
        var image = cut.image
        var driftL: Float = 0, driftAB: Float = 0
        if let ref = reference, let own = ColorStats(cut.image) {
            driftL = own.mean.0 - ref.mean.0
            driftAB = hypot(own.mean.1 - ref.mean.1, own.mean.2 - ref.mean.2)
        }
        if let ref = reference, let matched = ColorStats.match(image, to: ref) { image = matched }
        let framed = GarmentCutout.frame(image)
        guard let fcg = framed.cgImage, let onWhite = FashionClassifier.onWhite(fcg, side: 224),
              let e = WardrobeML.shared.embed(onWhite) else { return nil }
        let sim = WardrobeExtractor.cosine(e, embedding)
        let body = bodyFraction(render)
        var score = sim - 0.6 * body
        // Does it read as the right kind of product (and, for plain items, as
        // plain)? Zero-shot against the bundled vocabulary.
        var product: Float = 0, plain: Float = 0, qcMargin: Float = -1
        var bestProduct = "", bestProductScore: Float = 0
        if let plan, let vocab = WardrobeML.shared.vocabulary {
            for group in ["upper_inner", "upper_outer", "lower", "onepiece", "footwear", "bag", "headwear", "eyewear", "neckwear", "jewelry"] {
                let scores = vocab.scores(in: group, for: e)
                if let s = scores[plan.productLabel] {
                    product = s
                    if let top = scores.max(by: { $0.value < $1.value }) { bestProduct = top.key; bestProductScore = top.value }
                    break
                }
            }
            score += 0.25 * product
            if plan.isSolid, let solid = vocab.scores(in: "pattern", for: e)["Solid"] { plain = solid; score += 0.15 * solid }
            // Known failure looks (a person wearing it, a stack of tees, a flat
            // lay with props, a white panel) must stay well below the product.
            if let worst = vocab.scores(in: "render_qc", for: e).values.max(), product > 0 { qcMargin = worst - product }
        }
        // A light garment legitimately has white areas; only check darker ones.
        let lightGarment = (reference?.mean.0 ?? 50) > 72
        var isGenerate = false
        if let plan, case .generate = plan.mode { isGenerate = true }
        let productShot = isGenerate && plan?.template != nil && plan?.productShot == true
        let whitePanel = lightGarment ? 0 : interiorWhiteBlob(cut.image)

        var rejection: String?
        if cut.coverage >= 0.85 { rejection = "full-bleed (coverage \(String(format: "%.2f", cut.coverage)))" }
        else if cut.touchesFrame { rejection = "touches the frame" }
        else if cut.secondObject >= 0.15 { rejection = "second object (\(String(format: "%.2f", cut.secondObject)))" }
        else if whitePanel >= 0.03 { rejection = "white panel (\(String(format: "%.3f", whitePanel)))" }
        else if body > 0.25 { rejection = "body / mannequin (\(String(format: "%.2f", body)))" }
        else if productShot, abs(driftL) > maxColourDriftL || driftAB > maxColourDriftAB {
            rejection = "colour drift (ΔL \(String(format: "%+.0f", driftL)), Δab \(String(format: "%.0f", driftAB)))"
        }
        else if isGenerate, qcMargin > qcMarginReject { rejection = "looks like a failed render (qc +\(String(format: "%.3f", qcMargin)))" }
        else if sim < minSimilarity { rejection = "not the same item (sim \(String(format: "%.3f", sim)) < \(minSimilarity))" }
        return Candidate(image: framed, score: score, similarity: sim, body: body, product: product, plain: plain,
                         qcMargin: qcMargin, touchesFrame: cut.touchesFrame, coverage: cut.coverage,
                         secondObject: cut.secondObject, whitePanel: whitePanel,
                         colourDriftL: driftL, colourDriftAB: driftAB, bestProduct: bestProduct,
                         bestProductScore: bestProductScore, rejection: rejection)
    }

    /// The product, without its white background: Vision's foreground instance
    /// mask on device (every instance, so a second object is measured, then the
    /// largest kept), or white-keying where Vision isn't available (simulator).
    static func isolateProduct(_ render: CGImage, keepPairs: Bool = true)
        -> (image: CGImage, touchesFrame: Bool, coverage: Float, secondObject: Float)? {
        let w = render.width, h = render.height
        guard var px = GarmentCutout.rgbaPixels(render) else { return nil }
        var alpha = visionMask(render) ?? whiteKeyMask(px, w: w, h: h)
        let second = keepLargestComponent(&alpha, w: w, h: h, keepPairs: keepPairs)
        var any = false, touches = false, opaque = 0
        for y in 0..<h {
            for x in 0..<w {
                let a = alpha[y * w + x]
                guard a > 0 else { continue }
                any = true
                if a > 128 { opaque += 1 }
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
        return (img, touches, Float(opaque) / Float(w * h), second)
    }

    /// Share of the product covered by its largest enclosed near-white blob — a
    /// blank label square or a white panel the model painted on a dark garment.
    static func interiorWhiteBlob(_ product: CGImage) -> Float {
        let side = 128
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        let k = CGFloat(side) / CGFloat(max(product.width, product.height))
        let dw = CGFloat(product.width) * k, dh = CGFloat(product.height) * k
        ctx.draw(product, in: CGRect(x: (CGFloat(side) - dw) / 2, y: (CGFloat(side) - dh) / 2, width: dw, height: dh))
        let p = data.assumingMemoryBound(to: UInt8.self)
        let n = side * side
        var inside = [UInt8](repeating: 0, count: n), white = [UInt8](repeating: 0, count: n)
        var area = 0
        for i in 0..<n {
            let a = Int(p[i * 4 + 3])
            guard a > 128 else { continue }
            inside[i] = 1; area += 1
            let r = Int(p[i * 4]) * 255 / a, g = Int(p[i * 4 + 1]) * 255 / a, b = Int(p[i * 4 + 2]) * 255 / a
            if min(r, g, b) > 222 && max(r, g, b) - min(r, g, b) < 18 { white[i] = 1 }
        }
        // Holes in the silhouette that are white count too (white-keyed renders
        // leave an enclosed white panel as a hole only if it touches nothing).
        guard area > 50 else { return 0 }
        let (_, sizes) = GarmentSegmenter.components(white, w: side, h: side)
        return Float(sizes.max() ?? 0) / Float(area)
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

    /// Background = pixels connected to the image border that are near-white,
    /// or, on a grey backdrop (light products), close to the border's own grey.
    static func whiteKeyMask(_ px: [UInt8], w: Int, h: Int) -> [UInt8] {
        var border: [[Int]] = [[], [], []]
        for x in stride(from: 0, to: w, by: 4) { for i in [x, (h - 1) * w + x] { for c in 0..<3 { border[c].append(Int(px[i * 4 + c])) } } }
        for y in stride(from: 0, to: h, by: 4) { for i in [y * w, y * w + w - 1] { for c in 0..<3 { border[c].append(Int(px[i * 4 + c])) } } }
        let key = border.map { $0.sorted()[$0.count / 2] }
        let white = key.allSatisfy { $0 > 232 }
        func isBG(_ i: Int) -> Bool {
            if white { return px[i * 4] > 232 && px[i * 4 + 1] > 232 && px[i * 4 + 2] > 232 }
            return abs(Int(px[i * 4]) - key[0]) < 22 && abs(Int(px[i * 4 + 1]) - key[1]) < 22 && abs(Int(px[i * 4 + 2]) - key[2]) < 22
        }
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

    /// Keeps the main object (plus the second shoe of a pair when `keepPairs`)
    /// and drops the rest; returns the largest dropped object's size relative
    /// to the main one (specks under 1% of the image don't count).
    @discardableResult
    private static func keepLargestComponent(_ alpha: inout [UInt8], w: Int, h: Int, keepPairs: Bool) -> Float {
        let bin = alpha.map { $0 > 128 ? UInt8(1) : UInt8(0) }
        let (comp, sizes) = GarmentSegmenter.components(bin, w: w, h: h)
        guard let largest = sizes.max(), largest > 0, let id = sizes.firstIndex(of: largest).map({ $0 + 1 }) else { return 0 }
        var keep: Set<Int> = [id]
        if keepPairs {
            // The second shoe: at least a third of the first.
            for (i, s) in sizes.enumerated() where i + 1 != id && s * 3 >= largest { keep.insert(i + 1) }
        }
        let speck = w * h / 100
        let second = sizes.enumerated().filter { !keep.contains($0.offset + 1) && $0.element >= speck }.map { $0.element }.max() ?? 0
        for i in 0..<(w * h) where bin[i] == 1 && !keep.contains(comp[i]) { alpha[i] = 0 }
        return Float(second) / Float(largest)
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
