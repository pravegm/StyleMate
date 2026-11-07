import CoreML
import CoreGraphics
import Foundation
import Vision

/// Loads the bundled on-device wardrobe models once and hands out raw outputs.
///
/// Two Core ML models (built by `scripts/convert_wardrobe_models.py`, bundled
/// from `StyleMate/ML/`), both licensed for commercial use (docs/MODEL-LICENSING.md):
/// - **GarmentNet** (StyleMate's own: frozen DINOv2 ViT-S/14 backbone, Apache-2.0,
///   + a head trained on Fashionpedia and COCO people, CC BY 4.0): per grid pixel,
///   which Fashionpedia garment it is (shirt, jacket, coat, pants, shoe, bag,
///   glasses, watch...) or whether it is the person's skin / hair or the scene,
///   plus low-res garment probabilities (close-up triggers, split evidence) and
///   hood / collar / lapel / sleeve part maps.
/// - **FashionEncoder** (Marqo-FashionSigLIP): a 768-d embedding of an item
///   cutout, compared against precomputed text embeddings
///   (`FashionVocabulary.json`) for zero-shot product / pattern / material, and
///   against other items for duplicate detection.
///
/// Nothing leaves the device.
final class WardrobeML {
    static let shared = WardrobeML()
    private init() {}

    static let gridW = 384, gridH = 576
    static var gridCount: Int { gridW * gridH }
    /// GarmentNet's input (same 2:3 aspect as the grid).
    static let inputW = 448, inputH = 672

    private let lock = NSLock()
    private var segmenter: MLModel?
    private var encoder: MLModel?
    private(set) var vocabulary: FashionVocabulary?
    private var loadAttempted = false

    /// True when both models and the vocabulary are in the bundle.
    var isAvailable: Bool {
        loadIfNeeded()
        return segmenter != nil && encoder != nil && vocabulary != nil
    }

    private func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loadAttempted else { return }
        loadAttempted = true
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine   // no GPU: iOS forbids GPU work in the background (overnight scan)
        func load(_ name: String) -> MLModel? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                print("[Wardrobe] ERROR: \(name).mlmodelc missing from the bundle")
                return nil
            }
            do { return try MLModel(contentsOf: url, configuration: cfg) } catch {
                print("[Wardrobe] ERROR: failed to load \(name): \(error)")
                return nil
            }
        }
        segmenter = load("GarmentNet")
        encoder = load("FashionEncoder")
        if let url = Bundle.main.url(forResource: "FashionVocabulary", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            vocabulary = try? JSONDecoder().decode(FashionVocabulary.self, from: data)
        }
        if vocabulary == nil { print("[Wardrobe] ERROR: FashionVocabulary.json missing or invalid") }
    }

    // MARK: - Inference

    /// One GarmentNet pass over an image (any size; best at 448x672, the 2:3 grid aspect).
    func segment(_ image: CGImage) -> GarmentMap? {
        loadIfNeeded()
        guard let model = segmenter,
              let out = predict(model, image: image, width: Self.inputW, height: Self.inputH, stage: "segment"),
              let cls = out.featureValue(for: "classes")?.multiArrayValue,
              let probs = out.featureValue(for: "probs")?.multiArrayValue,
              let aux = out.featureValue(for: "aux")?.multiArrayValue else { return nil }
        let td = Date()
        defer { record("decode", Date().timeIntervalSince(td)) }
        guard let c = Self.read(cls, h: Self.gridH, w: Self.gridW),
              let p = Self.read(probs, h: GarmentMap.lowH, w: GarmentMap.lowW),
              let a = Self.read(aux, h: GarmentMap.lowH, w: GarmentMap.lowW) else { return nil }
        var classes = [UInt8](repeating: 0, count: Self.gridCount)
        for i in 0..<Self.gridCount { classes[i] = UInt8(max(0, min(27, c[i].rounded()))) }
        // Only confident body: the person channel's soft rim just outside a garment is scene.
        for i in 0..<Self.gridCount where classes[i] == GarmentMap.body && a[4 * GarmentMap.lowCount + GarmentMap.low(i)] < 0.6 {
            classes[i] = 0
        }
        return GarmentMap(classes: classes, probs: p, aux: a)
    }

    /// FASHN-parser-style labels (the regions some callers still count): 0 background,
    /// 3 top, 4 dress, 5 skirt, 6 pants, 7 belt, 8 bag, 9 hat, 10 scarf, 11 glasses,
    /// 15 feet, 16 body (skin / hair: GarmentNet has no finer body parts), 17 jewelry.
    func parse(_ image: CGImage) -> (labels: [UInt8], confidence: [Float])? {
        guard let map = segment(image) else { return nil }
        // Only confident body: the person channel's soft rim around a garment is not skin.
        var labels = [UInt8](repeating: 0, count: map.classes.count)
        for (i, c) in map.classes.enumerated() { labels[i] = GarmentMap.parserRegion(c) }
        // A person or mannequin is a sizeable area (>= 5% of the grid); confident "body" cells on a plain
        // product (GarmentNet sees no garment in a flat colour swatch) are not one.
        let bodyCount = labels.reduce(0) { $0 + ($1 == 16 ? 1 : 0) }
        if bodyCount * 20 < labels.count {
            for i in 0..<labels.count where labels[i] == 16 { labels[i] = 0 }
        } else {
            let face = Self.faceBox(image)
            // GarmentNet's 1/4-res collar line runs up the neck: under the face, a top is skin
            // (the try-on otherwise "invents" a neck where it removes the old top).
            if let f = face {
                let gw = Self.gridW, gh = Self.gridH
                let fw = f.2 - f.0, fh = f.3 - f.1
                let x0 = max(0, f.0 - fw / 6), x1 = min(gw, f.2 + fw / 6)
                let y1 = min(gh, f.3 + fh * 45 / 100)
                for y in max(0, f.1)..<y1 {
                    for x in x0..<x1 where labels[y * gw + x] == 3 || labels[y * gw + x] == 4 {
                        labels[y * gw + x] = y < f.3 ? GarmentSegmenter.P.face.rawValue : GarmentSegmenter.P.torso.rawValue
                    }
                }
            }
            Self.splitBody(&labels, face: face)
        }
        return (labels, [Float](repeating: 1, count: labels.count))
    }

    /// GarmentNet has one "body" class; callers of the FASHN-style labels (try-on) also want face,
    /// hair, arms, hands and legs. Split body pixels by where they sit relative to the garments:
    /// above the upper garments = head (face inside Vision's face box, else hair); beside the
    /// upper garment = arms, their lowest part (near the hem) hands; below the upper garment =
    /// legs (beside the bottoms' top half: hands); the rest torso.
    static func splitBody(_ labels: inout [UInt8], face: (Int, Int, Int, Int)?) {
        typealias P = GarmentSegmenter.P
        let w = gridW, h = gridH
        var uTop = h, uBot = -1, lBot = -1
        var uL = [Int](repeating: Int.max, count: h), uR = [Int](repeating: -1, count: h)
        var lL = [Int](repeating: Int.max, count: h), lR = [Int](repeating: -1, count: h)
        for y in 0..<h {
            for x in 0..<w {
                let l = labels[y * w + x]
                if l == P.top.rawValue || l == P.dress.rawValue {
                    uTop = min(uTop, y); uBot = max(uBot, y); uL[y] = min(uL[y], x); uR[y] = max(uR[y], x)
                } else if l == P.pants.rawValue || l == P.skirt.rawValue {
                    lBot = max(lBot, y); lL[y] = min(lL[y], x); lR[y] = max(lR[y], x)
                }
            }
        }
        let hasUpper = uBot >= 0
        let uH = max(1, uBot - uTop)
        var lTop = h
        for y in 0..<h where lR[y] >= 0 { lTop = y; break }
        for y in 0..<h {
            for x in 0..<w where labels[y * w + x] == P.torso.rawValue {
                let i = y * w + x
                if !hasUpper || y < uTop {
                    if let f = face, x >= f.0, x < f.2, y >= f.1, y < f.3 { labels[i] = P.face.rawValue }
                    else if hasUpper { labels[i] = P.hair.rawValue }
                    else { labels[i] = y < lTop ? P.hair.rawValue : P.legs.rawValue }
                } else if y <= uBot {
                    let inside = uR[y] >= 0 && x >= uL[y] && x <= uR[y]
                    if !inside { labels[i] = y > uBot - uH / 6 ? P.hands.rawValue : P.arms.rawValue }
                } else {
                    let besideBottoms = lR[y] >= 0 && (x < lL[y] || x > lR[y])
                    labels[i] = besideBottoms && y < lTop + (lBot - lTop) / 2 ? P.hands.rawValue : P.legs.rawValue
                }
            }
        }
    }

    /// Vision's largest face box on the grid (x0, y0, x1, y1), or nil.
    static func faceBox(_ image: CGImage) -> (Int, Int, Int, Int)? {
        // Never longer than 10 s: a Vision request can block for good on a device (the Duo's did).
        HangGuard.run("face box (Vision)", seconds: 10) { faceBoxUnguarded(image) }
    }

    private static func faceBoxUnguarded(_ image: CGImage) -> (Int, Int, Int, Int)? {
        let request = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        let b = face.boundingBox   // normalised, bottom-left origin
        let x0 = Int(b.minX * CGFloat(gridW)), x1 = Int(b.maxX * CGFloat(gridW))
        let y0 = Int((1 - b.maxY) * CGFloat(gridH)), y1 = Int((1 - b.minY) * CGFloat(gridH))
        return (max(0, x0), max(0, y0), min(gridW, x1), min(gridH, y1))
    }

    /// L2-normalized 768-d embedding of a 224x224 item image.
    func embed(_ image: CGImage) -> [Float]? {
        loadIfNeeded()
        guard let model = encoder,
              let res = predict(model, image: image, width: 224, height: 224, stage: "embed"),
              let out = res.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var v = [Float](repeating: 0, count: out.count)
        if out.dataType == .float16 {
            out.withUnsafeBufferPointer(ofType: Float16.self) { p in for i in 0..<out.count { v[i] = Float(p[i]) } }
        } else {
            out.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<out.count { v[i] = p[i] } }
        }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    // MARK: - Timing (CI reports seconds per model per photo)

    private let timingLock = NSLock()
    private var timing: [String: (seconds: Double, count: Int)] = [:]

    /// Adds `seconds` to a named stage ("parse", "label", "embed", "cutout"...).
    func record(_ stage: String, _ seconds: Double) {
        timingLock.lock(); defer { timingLock.unlock() }
        let t = timing[stage] ?? (0, 0)
        timing[stage] = (t.seconds + seconds, t.count + 1)
    }

    /// The stages recorded since the last call, as "parse 3x 4.1s, ...", and resets them.
    func takeTiming() -> String {
        timingLock.lock(); defer { timingLock.unlock() }
        let s = timing.sorted { $0.value.seconds > $1.value.seconds }
            .map { "\($0.key) \($0.value.count)x \(String(format: "%.1f", $0.value.seconds))s" }.joined(separator: ", ")
        timing = [:]
        return s
    }

    private func predict(_ model: MLModel, image: CGImage, width: Int, height: Int, stage: String) -> MLFeatureProvider? {
        let t0 = Date()
        defer { record(stage, Date().timeIntervalSince(t0)) }
        do {
            let value = try MLFeatureValue(cgImage: image, pixelsWide: width, pixelsHigh: height,
                                           pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": value])
            return try model.prediction(from: input)
        } catch {
            print("[Wardrobe] prediction failed (\(stage)): \(error)")
            return nil
        }
    }

    /// A [1, C, h, w] output as channel-major floats, honouring its strides (Core ML
    /// may pad rows for the Neural Engine).
    private static func read(_ a: MLMultiArray, h: Int, w: Int) -> [Float]? {
        guard a.shape.count == 4, a.shape[2].intValue == h, a.shape[3].intValue == w else {
            print("[Wardrobe] unexpected output shape \(a.shape)")
            return nil
        }
        let c = a.shape[1].intValue
        let st = a.strides.map { $0.intValue }
        var out = [Float](repeating: 0, count: c * h * w)
        out.withUnsafeMutableBufferPointer { o in
            if a.dataType == .float16 {
                a.withUnsafeBufferPointer(ofType: Float16.self) { p in
                    for ch in 0..<c {
                        for y in 0..<h {
                            let src = ch * st[1] + y * st[2], dst = (ch * h + y) * w
                            for x in 0..<w { o[dst + x] = Float(p[src + x * st[3]]) }
                        }
                    }
                }
            } else {
                a.withUnsafeBufferPointer(ofType: Float.self) { p in
                    for ch in 0..<c {
                        for y in 0..<h {
                            let src = ch * st[1] + y * st[2], dst = (ch * h + y) * w
                            for x in 0..<w { o[dst + x] = p[src + x * st[3]] }
                        }
                    }
                }
            }
        }
        return out
    }
}

/// One GarmentNet pass on the 384x576 analysis grid.
struct GarmentMap {
    static let lowW = 96, lowH = 144
    static var lowCount: Int { lowW * lowH }
    /// Person, no garment: skin, hair (and anything worn that isn't a Fashionpedia garment).
    static let body: UInt8 = 27

    /// Per grid pixel: 0 scene, 1...26 Fashionpedia whole garment (GarmentSegmenter.fpNames), 27 body.
    var classes: [UInt8]
    /// Garment softmax on the 96x144 low-res grid, channel-major [27][lowCount] (0 = no garment).
    let probs: [Float]
    /// Sigmoid on the low-res grid, channel-major [5][lowCount]: hood, collar, lapel, sleeve, person.
    let aux: [Float]

    /// Low-res index of a grid pixel.
    @inline(__always) static func low(_ gridIndex: Int) -> Int {
        let x = (gridIndex % WardrobeML.gridW) / 4, y = (gridIndex / WardrobeML.gridW) / 4
        return y * lowW + x
    }
    @inline(__always) func prob(_ c: Int, _ gridIndex: Int) -> Float { probs[c * Self.lowCount + Self.low(gridIndex)] }
    @inline(__always) func part(_ k: Int, _ gridIndex: Int) -> Float { aux[k * Self.lowCount + Self.low(gridIndex)] }

    /// Highest summed probability of `classes` inside a grid box (x0, y0, x1, y1), and where (grid px).
    func peak(_ classes: [Int], in box: (Int, Int, Int, Int)) -> (p: Float, x: Int, y: Int) {
        let lx0 = max(0, box.0 / 4), ly0 = max(0, box.1 / 4)
        let lx1 = min(Self.lowW, (box.2 + 3) / 4), ly1 = min(Self.lowH, (box.3 + 3) / 4)
        var best: (p: Float, x: Int, y: Int) = (0, 0, 0)
        guard lx1 > lx0, ly1 > ly0 else { return best }
        for y in ly0..<ly1 {
            for x in lx0..<lx1 {
                var v: Float = 0
                for c in classes { v += probs[c * Self.lowCount + y * Self.lowW + x] }
                if v > best.p { best = (v, x * 4 + 2, y * 4 + 2) }
            }
        }
        return best
    }

    /// Grid box of the low-res cells where `classes` sum to at least `threshold`,
    /// restricted to `within` (grid box), with the cell count.
    func blob(_ classes: [Int], threshold: Float, within: (Int, Int, Int, Int)) -> (box: (Int, Int, Int, Int), cells: Int)? {
        let lx0 = max(0, within.0 / 4), ly0 = max(0, within.1 / 4)
        let lx1 = min(Self.lowW, (within.2 + 3) / 4), ly1 = min(Self.lowH, (within.3 + 3) / 4)
        guard lx1 > lx0, ly1 > ly0 else { return nil }
        var x0 = Int.max, y0 = Int.max, x1 = 0, y1 = 0, n = 0
        for y in ly0..<ly1 {
            for x in lx0..<lx1 {
                var v: Float = 0
                for c in classes { v += probs[c * Self.lowCount + y * Self.lowW + x] }
                if v >= threshold { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1); n += 1 }
            }
        }
        return n > 0 ? ((x0 * 4, y0 * 4, x1 * 4, y1 * 4), n) : nil
    }

    /// The FASHN parser region a GarmentNet class falls in (for code that counts regions).
    static func parserRegion(_ c: UInt8) -> UInt8 {
        switch c {
        case 1, 2, 3, 4, 5, 6, 10, 13: return 3      // top
        case 11, 12: return 4                        // dress
        case 9: return 5                             // skirt
        case 7, 8, 21, 22: return 6                  // pants
        case 20: return 7                            // belt
        case 25: return 8                            // bag
        case 15, 16: return 9                        // hat
        case 17, 26: return 10                       // scarf
        case 14: return 11                           // glasses
        case 18: return 17                           // glove: an accessory, not skin
        case 23, 24: return 15                       // feet
        case 19: return 17                           // jewelry (watch)
        case body: return 16                         // body
        default: return 0
        }
    }
}

/// Precomputed FashionSigLIP text embeddings, grouped (e.g. "lower", "pattern").
struct FashionVocabulary: Decodable {
    struct Group: Decodable {
        let labels: [String]
        let embeddings: [[Float]]
    }
    let model: String
    let groups: [String: Group]

    /// Each label's best cosine score in a group.
    func scores(in group: String, for embedding: [Float]) -> [String: Float] {
        guard let g = groups[group] else { return [:] }
        var byLabel: [String: Float] = [:]
        for (label, e) in zip(g.labels, g.embeddings) {
            var s: Float = 0
            for i in 0..<min(e.count, embedding.count) { s += e[i] * embedding[i] }
            byLabel[label] = max(byLabel[label] ?? -.infinity, s)
        }
        return byLabel
    }

    /// Best label in a group for an image embedding, with its margin over the
    /// runner-up (a cosine gap; > ~0.01 is a meaningful preference for SigLIP).
    func best(in group: String, for embedding: [Float], allowed: ((String) -> Bool)? = nil) -> (label: String, margin: Float)? {
        guard let g = groups[group] else { return nil }
        var scores: [(String, Float)] = []
        for (label, e) in zip(g.labels, g.embeddings) where allowed?(label) ?? true {
            var s: Float = 0
            for i in 0..<min(e.count, embedding.count) { s += e[i] * embedding[i] }
            scores.append((label, s))
        }
        // Several prompts may share one label (e.g. "Scarves"): keep each label's best.
        var byLabel: [String: Float] = [:]
        for (l, s) in scores { byLabel[l] = max(byLabel[l] ?? -.infinity, s) }
        let ranked = byLabel.sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        let margin = ranked.count > 1 ? top.value - ranked[1].value : 1
        return (top.key, margin)
    }
}
