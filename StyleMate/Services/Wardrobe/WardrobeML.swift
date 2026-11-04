import CoreML
import CoreGraphics
import Foundation

/// Loads the bundled on-device wardrobe models once and hands out raw outputs.
///
/// Three Core ML models (built by `scripts/convert_wardrobe_models.py`, bundled
/// from `StyleMate/ML/`):
/// - **GarmentParser** (FASHN human parser): which pixels are clothing vs body,
///   and coarse region (top / dress / skirt / pants / feet / bag / hat / scarf /
///   glasses / belt / jewelry). Softmax on a 576x384 grid.
/// - **GarmentLabeler** (Fashionpedia SegFormer): garment *type* per pixel, which
///   splits a jacket from the shirt under it. Logits for 27 classes, same grid.
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

    private let lock = NSLock()
    private var parser: MLModel?
    private var labeler: MLModel?
    private var encoder: MLModel?
    private(set) var vocabulary: FashionVocabulary?
    private var loadAttempted = false

    /// True when all three models and the vocabulary are in the bundle.
    var isAvailable: Bool {
        loadIfNeeded()
        return parser != nil && labeler != nil && encoder != nil && vocabulary != nil
    }

    private func loadIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !loadAttempted else { return }
        loadAttempted = true
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
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
        parser = load("GarmentParser")
        labeler = load("GarmentLabeler")
        encoder = load("FashionEncoder")
        if let url = Bundle.main.url(forResource: "FashionVocabulary", withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            vocabulary = try? JSONDecoder().decode(FashionVocabulary.self, from: data)
        }
        if vocabulary == nil { print("[Wardrobe] ERROR: FashionVocabulary.json missing or invalid") }
    }

    // MARK: - Inference

    /// Parser argmax label per grid pixel (18 FASHN classes) plus the per-pixel
    /// max probability, for a 384x576 RGB image.
    func parse(_ image: CGImage) -> (labels: [UInt8], confidence: [Float])? {
        loadIfNeeded()
        guard let model = parser,
              let out = predict(model, image: image, width: Self.gridW, height: Self.gridH, output: "probs") else { return nil }
        let c = out.shape[1].intValue
        var labels = [UInt8](repeating: 0, count: Self.gridCount)
        var conf = [Float](repeating: 0, count: Self.gridCount)
        Self.forEachChannel(out, channels: c) { ch, idx, v in
            if v > conf[idx] { conf[idx] = v; labels[idx] = UInt8(ch) }
        }
        return (labels, conf)
    }

    /// Labeler logits, channel-major `[27][gridCount]`, for a 512x512 RGB image
    /// (the same crop as the parser, stretched square as in training).
    func label(_ image: CGImage) -> [Float]? {
        loadIfNeeded()
        guard let model = labeler,
              let out = predict(model, image: image, width: 512, height: 512, output: "logits") else { return nil }
        let c = out.shape[1].intValue
        var logits = [Float](repeating: 0, count: c * Self.gridCount)
        Self.forEachChannel(out, channels: c) { ch, idx, v in logits[ch * Self.gridCount + idx] = v }
        return logits
    }

    /// L2-normalized 768-d embedding of a 224x224 item image.
    func embed(_ image: CGImage) -> [Float]? {
        loadIfNeeded()
        guard let model = encoder,
              let out = predict(model, image: image, width: 224, height: 224, output: "embedding") else { return nil }
        var v = [Float](repeating: 0, count: out.count)
        if out.dataType == .float16 {
            out.withUnsafeBufferPointer(ofType: Float16.self) { p in for i in 0..<out.count { v[i] = Float(p[i]) } }
        } else {
            out.withUnsafeBufferPointer(ofType: Float.self) { p in for i in 0..<out.count { v[i] = p[i] } }
        }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    private func predict(_ model: MLModel, image: CGImage, width: Int, height: Int, output: String) -> MLMultiArray? {
        do {
            let value = try MLFeatureValue(cgImage: image, pixelsWide: width, pixelsHigh: height,
                                           pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
            let input = try MLDictionaryFeatureProvider(dictionary: ["image": value])
            let result = try model.prediction(from: input)
            return result.featureValue(for: output)?.multiArrayValue
        } catch {
            print("[Wardrobe] prediction failed (\(output)): \(error)")
            return nil
        }
    }

    /// Visits every (channel, gridIndex, value) of a [1, C, H, W] array,
    /// honouring its strides (Core ML may pad rows for the Neural Engine).
    private static func forEachChannel(_ a: MLMultiArray, channels: Int, _ body: (Int, Int, Float) -> Void) {
        let st = a.strides.map { $0.intValue }
        let h = a.shape[2].intValue, w = a.shape[3].intValue
        guard h == gridH, w == gridW else {
            print("[Wardrobe] unexpected output shape \(a.shape)")
            return
        }
        if a.dataType == .float16 {
            a.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for c in 0..<channels {
                    for y in 0..<h {
                        let base = c * st[1] + y * st[2]
                        for x in 0..<w { body(c, y * w + x, Float(p[base + x * st[3]])) }
                    }
                }
            }
        } else {
            a.withUnsafeBufferPointer(ofType: Float.self) { p in
                for c in 0..<channels {
                    for y in 0..<h {
                        let base = c * st[1] + y * st[2]
                        for x in 0..<w { body(c, y * w + x, p[base + x * st[3]]) }
                    }
                }
            }
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
